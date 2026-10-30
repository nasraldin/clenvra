import Foundation
import Testing

@testable import ClenvraKit

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
