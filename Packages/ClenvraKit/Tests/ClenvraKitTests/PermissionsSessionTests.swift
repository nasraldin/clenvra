import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Stands in for the installed helper: records each reset and runs `effect` before answering.
private final class PermissionHelper: PrivilegedOperations {
    struct Call: Sendable {
        let service: String
        let bundleID: String
    }

    let answer: PermissionReset
    let effect: @Sendable () -> Void
    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }

    init(answer: PermissionReset, effect: @escaping @Sendable () -> Void) {
        self.answer = answer
        self.effect = effect
    }

    func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse { throw .unavailable }
    func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError? { throw .unavailable }
    func removeOrphanedLaunchItem(_ item: DeletionItem, operationID: UUID) async throws(HelperClientError)
        -> ActivityRecord.Outcome
    { throw .unavailable }
    func deleteLocalSnapshot(date: String) async throws(HelperClientError) -> SnapshotDeletion { throw .unavailable }
    func resetPermission(service: String, bundleID: String) async throws(HelperClientError) -> PermissionReset {
        recorded.withLock { $0.append(Call(service: service, bundleID: bundleID)) }
        effect()
        return answer
    }
}

@MainActor
@Suite("Permissions session")
struct PermissionsSessionTests {
    private let folder: TemporaryDirectory
    private let userPath: String
    private let systemPath: String

    init() throws {
        folder = try TemporaryDirectory()
        userPath = folder.url.appending(path: "user.db").path(percentEncoded: false)
        systemPath = folder.url.appending(path: "system.db").path(percentEncoded: false)
    }

    private func writeBoth() throws {
        try TCCFixture.write(
            [
                .init(service: "kTCCServiceMicrophone", client: "us.zoom.xos", clientType: 0, authValue: 2),
                .init(service: "kTCCServiceCamera", client: "us.zoom.xos", clientType: 0, authValue: 2),
                .init(service: "kTCCServiceCamera", client: "com.denied", clientType: 0, authValue: 0),
                .init(service: "kTCCServiceCamera", client: "/usr/local/bin/tool", clientType: 1, authValue: 2),
            ], to: userPath)
        try TCCFixture.write(
            [
                .init(
                    service: "kTCCServiceScreenCapture", client: "com.obsproject.obs-studio", clientType: 0,
                    authValue: 2),
                .init(service: "kTCCServiceScreenCapture", client: "com.off", clientType: 0, authValue: 0),
            ], to: systemPath)
    }

    private func session(_ runner: FakeCommandRunner = FakeCommandRunner()) -> PermissionsSession {
        PermissionsSession(userDatabase: userPath, systemDatabase: systemPath, runner: runner)
    }

    @Test("only allowed grants are listed, sorted by service then app")
    func loadKeepsAllowedOnly() async throws {
        try writeBoth()
        let session = session()

        await session.load()

        #expect(session.phase == .ready)
        #expect(
            session.grants.map(\.id) == [
                "user:kTCCServiceCamera:/usr/local/bin/tool", "user:kTCCServiceCamera:us.zoom.xos",
                "user:kTCCServiceMicrophone:us.zoom.xos", "system:kTCCServiceScreenCapture:com.obsproject.obs-studio",
            ])
        #expect(session.unreadableScopes.isEmpty)
    }

    /// macOS keeps internal services in the same table (for example `kTCCServiceLiverpool`); they have no name in
    /// System Settings and nothing the person can do about them, so they are not listed.
    @Test("services without a name in System Settings are not listed")
    func unknownServicesAreHidden() async throws {
        try TCCFixture.write(
            [
                .init(service: "kTCCServiceLiverpool", client: "com.apple.Maps", clientType: 0, authValue: 2),
                .init(service: "kTCCServiceCamera", client: "us.zoom.xos", clientType: 0, authValue: 2),
            ], to: userPath)
        let session = session()

        await session.load()

        #expect(session.grants.map(\.service) == ["kTCCServiceCamera"])
    }

    @Test("when neither database can be read, the page asks for Full Disk Access instead of showing an empty list")
    func bothUnreadableNeedsAccess() async {
        let session = session()

        await session.load()

        #expect(session.phase == .needsAccess)
        #expect(session.grants.isEmpty)
    }

    @Test("one readable database is enough to show the list")
    func oneUnreadableStillReady() async throws {
        try TCCFixture.write(
            [.init(service: "kTCCServiceScreenCapture", client: "com.obs", clientType: 0, authValue: 2)],
            to: systemPath)
        let session = session()

        await session.load()

        #expect(session.phase == .ready)
        #expect(session.grants.map(\.client) == ["com.obs"])
        #expect(session.unreadableScopes == [.user])
    }

    @Test("revoking runs tccutil reset for the service and app, then reloads")
    func revokeRunsTccutilReset() async throws {
        try writeBoth()
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/tccutil", ["reset", "Camera", "us.zoom.xos"])
        let session = session(runner)
        await session.load()
        let grant = try #require(session.grants.first { $0.id == "user:kTCCServiceCamera:us.zoom.xos" })
        // What tccutil does to the database; the fake runner only records the command.
        try TCCFixture.remove(service: "kTCCServiceCamera", client: "us.zoom.xos", from: userPath)

        let result = await session.revoke(grant)

        #expect(result == .revoked)
        #expect(runner.commands.map(\.executable) == ["/usr/bin/tccutil"])
        #expect(runner.commands.map(\.arguments) == [["reset", "Camera", "us.zoom.xos"]])
        #expect(!session.grants.contains { $0.id == grant.id })
        #expect(session.grants.contains { $0.id == "user:kTCCServiceMicrophone:us.zoom.xos" })
    }

    @Test("a failing tccutil is reported and the grant stays listed")
    func revokeFailureReported() async throws {
        try writeBoth()
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/tccutil", ["reset", "Camera", "us.zoom.xos"], stderr: "Failed", status: 1)
        let session = session(runner)
        await session.load()
        let grant = try #require(session.grants.first { $0.id == "user:kTCCServiceCamera:us.zoom.xos" })

        #expect(await session.revoke(grant) == .failed)
        #expect(session.grants.contains { $0.id == grant.id })
    }

    @Test("tccutil succeeding while the grant is still there is not called a success")
    func revokeThatLeavesGrantFails() async throws {
        try writeBoth()
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/tccutil", ["reset", "ScreenCapture", "com.obsproject.obs-studio"])
        let session = session(runner)
        await session.load()
        let grant = try #require(session.grants.first { $0.scope == .system })

        #expect(await session.revoke(grant) == .failed)
        #expect(session.grants.contains { $0.id == grant.id })
    }

    @Test("a grant for all users is revoked through the helper, never with tccutil as the user")
    func revokeSystemGrantThroughHelper() async throws {
        try writeBoth()
        let runner = FakeCommandRunner()
        let systemPath = systemPath
        let helper = PermissionHelper(answer: .reset) {
            // What tccutil run as root does to the Mac's database.
            try? TCCFixture.remove(
                service: "kTCCServiceScreenCapture", client: "com.obsproject.obs-studio", from: systemPath)
        }
        let session = PermissionsSession(
            userDatabase: userPath, systemDatabase: systemPath, runner: runner, privileged: helper)
        session.helperAvailable = true
        await session.load()
        let grant = try #require(session.grants.first { $0.scope == .system })

        #expect(session.canRevoke(grant))
        #expect(await session.revoke(grant) == .revoked)

        #expect(runner.commands.isEmpty)
        #expect(helper.calls.map(\.service) == ["ScreenCapture"])
        #expect(helper.calls.map(\.bundleID) == ["com.obsproject.obs-studio"])
        #expect(!session.grants.contains { $0.id == grant.id })
    }

    @Test("when the helper refuses or the grant survives, it is reported as failed")
    func helperRefusalReported() async throws {
        try writeBoth()
        let helper = PermissionHelper(answer: .notAuthorized) {}
        let session = PermissionsSession(
            userDatabase: userPath, systemDatabase: systemPath, runner: FakeCommandRunner(), privileged: helper)
        session.helperAvailable = true
        await session.load()
        let grant = try #require(session.grants.first { $0.scope == .system })

        #expect(await session.revoke(grant) == .failed)
        #expect(session.grants.contains { $0.id == grant.id })
    }

    @Test("revoking several grants reports each one, and reads the databases once at the end")
    func revokeManyReportsEach() async throws {
        try writeBoth()
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/tccutil", ["reset", "Camera", "us.zoom.xos"])
        runner.stub("/usr/bin/tccutil", ["reset", "Microphone", "us.zoom.xos"], stderr: "Failed", status: 1)
        let session = session(runner)
        await session.load()
        let camera = try #require(session.grants.first { $0.id == "user:kTCCServiceCamera:us.zoom.xos" })
        let microphone = try #require(session.grants.first { $0.id == "user:kTCCServiceMicrophone:us.zoom.xos" })
        let tool = try #require(session.grants.first { !$0.clientIsBundleID })
        try TCCFixture.remove(service: "kTCCServiceCamera", client: "us.zoom.xos", from: userPath)

        let results = await session.revoke([camera, microphone, tool])

        #expect(results == [camera.id: .revoked, microphone.id: .failed, tool.id: .failed])
        #expect(runner.commands.count == 2)
        #expect(!session.grants.contains { $0.id == camera.id })
        #expect(session.grants.contains { $0.id == microphone.id })
    }

    @Test("a grant whose client is a path cannot be revoked, and nothing runs")
    func pathClientCannotBeRevoked() async throws {
        try writeBoth()
        let runner = FakeCommandRunner()
        let session = session(runner)
        await session.load()
        let grant = try #require(session.grants.first { !$0.clientIsBundleID })

        #expect(!session.canRevoke(grant))
        #expect(await session.revoke(grant) == .failed)
        #expect(runner.commands.isEmpty)
    }
}
