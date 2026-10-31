import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Moves items into the fixture's `.Trash` folder.
private struct UninstallFixtureTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

/// Records what is asked of the helper and answers as if it had deleted every item; it never touches a file.
private final class RecordingHelper: PrivilegedOperations {
    let requests = Mutex<[HelperRequest]>([])
    let forgotten = Mutex<[String]>([])
    /// Authorizations opened, and helper calls made outside one (each of those would ask for the password again).
    let sessions = Mutex(0)
    let callsOutsideSession = Mutex(0)
    private let inSession = Mutex(false)

    func withOneAuthorization<T>(
        isolation: isolated (any Actor)? = #isolation, _ body: () async -> T
    ) async -> T {
        sessions.withLock { $0 += 1 }
        inSession.withLock { $0 = true }
        defer { inSession.withLock { $0 = false } }
        return await body()
    }

    private func noteCall() {
        if !inSession.withLock({ $0 }) { callsOutsideSession.withLock { $0 += 1 } }
    }
    /// The answer to a request to forget an installer record.
    let forgetAnswer: PackageForget

    init(forgetAnswer: PackageForget = .forgotten) { self.forgetAnswer = forgetAnswer }

    func forgetPackage(id: String) async throws(HelperClientError) -> PackageForget {
        noteCall()
        forgotten.withLock { $0.append(id) }
        return forgetAnswer
    }

    func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse {
        noteCall()
        requests.withLock { $0.append(request) }
        return HelperResponse(outcomes: request.items.map { _ in .removedPermanently })
    }
    func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError? { throw .unavailable }
    func removeOrphanedLaunchItem(_ item: DeletionItem, operationID: UUID) async throws(HelperClientError)
        -> ActivityRecord.Outcome
    { throw .unavailable }
    func deleteLocalSnapshot(date: String) async throws(HelperClientError) -> SnapshotDeletion { throw .unavailable }
}

@MainActor
@Suite("AppsSession complete uninstall")
struct AppUninstallTests {
    private let fixture: AppsFixture
    private let brew = "/opt/homebrew/bin/brew"

    init() throws {
        fixture = try AppsFixture()
    }

    private var backups: URL { URL(filePath: fixture.path("Backups"), directoryHint: .isDirectory) }

    private func session(
        homebrew: AppsSession.Homebrew? = nil, privileged: (any PrivilegedOperations)? = nil,
        receipts: OwnershipResolver.ReceiptLookup? = nil, running: Set<String> = [],
        installSourceRunner: (any CommandRunning)? = nil
    ) -> AppsSession {
        let home = fixture.home
        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { running.contains($0) ? .running : .notRunning }
        let log = ActivityLog(directory: URL(filePath: home + "/log"))
        return AppsSession(
            home: home, policy: policy,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState), log: log,
                trash: UninstallFixtureTrash(directory: home + "/.Trash")),
            log: log,
            resolver: OwnershipResolver(
                home: home, policy: policy, launchItems: fixture.launchItems, receipts: receipts),
            privileged: privileged,
            systemAllowlist: HelperAllowlist(systemRoot: home + "/sys"),
            discover: {
                await AppInventory.discover(roots: [home + "/Applications"], homebrewCaskroom: home + "/Caskroom")
            },
            ownerState: { app in app.bundleIdentifier.map(ownerState) ?? .unknown },
            lastUsed: { _ in nil },
            teamIdentifier: { _ in nil },
            homebrew: homebrew, installSourceRunner: installSourceRunner)
    }

    private func records() async throws -> [ActivityRecord] {
        try await ActivityLog(directory: URL(filePath: fixture.path("log"))).readAll().records
    }

    private func trashIsEmpty() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash")).isEmpty
    }

    @Test("a Homebrew cask is uninstalled with brew --zap as the user, then whatever is left is deleted")
    func uninstallRunsBrewZapThenDeletesRest() async throws {
        let app = try fixture.app("org.mozilla.firefox", name: "Firefox")
        try fixture.file("Library/Caches/org.mozilla.firefox/blob")
        try fixture.file("Library/Preferences/org.mozilla.firefox.plist")
        let runner = FakeCommandRunner()
        runner.stub(
            brew, ["info", "--json=v2", "--installed", "--cask"],
            stdout: """
                {"casks": [{"token": "firefox", "artifacts": [{"app": ["Firefox.app"], "target": "\(app.id)"}]}]}
                """)
        runner.stub(brew, ["uninstall", "--cask", "--zap", "firefox"], stdout: "==> Uninstalling Cask firefox\n")
        let session = session(homebrew: .init(brew: brew, runner: runner, caskroom: fixture.home + "/Caskroom"))
        await session.load()

        let plans = await session.uninstallPlans(for: [app])
        #expect(plans.first?.source == .homebrewCask(token: "firefox"))

        let preview = await session.uninstall([app], backup: nil, dryRun: true)
        #expect(preview.removed == ["Firefox"])
        #expect(!runner.commands.contains { $0.arguments.first == "uninstall" })  // a dry run runs nothing
        #expect(fixture.exists("Applications/Firefox.app"))

        let result = await session.uninstall([app], backup: nil)

        #expect(result.removed == ["Firefox"])
        #expect(result.skipped.isEmpty)
        let uninstalls = runner.commands.filter { $0.arguments.first == "uninstall" }
        #expect(uninstalls.map(\.arguments) == [["uninstall", "--cask", "--zap", "firefox"]])
        #expect(uninstalls.allSatisfy { $0.executable == brew })
        #expect(!runner.commands.contains { $0.executable.hasSuffix("sudo") || $0.arguments.contains("sudo") })
        // The fake brew removed nothing, so Clenvra deleted the rest itself, for good.
        #expect(!fixture.exists("Applications/Firefox.app"))
        #expect(!fixture.exists("Library/Caches/org.mozilla.firefox"))
        #expect(!fixture.exists("Library/Preferences/org.mozilla.firefox.plist"))
        #expect(try trashIsEmpty())
        #expect(session.apps.isEmpty)
    }

    @Test("when brew fails, the app is kept with the reason and nothing else is deleted")
    func uninstallKeepsAppWhenBrewFails() async throws {
        let app = try fixture.app("org.mozilla.firefox", name: "Firefox")
        try fixture.file("Library/Caches/org.mozilla.firefox/blob")
        let runner = FakeCommandRunner()
        runner.stub(
            brew, ["info", "--json=v2", "--installed", "--cask"],
            stdout: """
                {"casks": [{"token": "firefox", "artifacts": [{"app": ["Firefox.app"], "target": "\(app.id)"}]}]}
                """)
        runner.stub(
            brew, ["uninstall", "--cask", "--zap", "firefox"], stderr: "Error: permission denied\n", status: 1)
        let session = session(homebrew: .init(brew: brew, runner: runner, caskroom: fixture.home + "/Caskroom"))
        await session.load()

        let result = await session.uninstall([app], backup: nil)

        #expect(result.removed.isEmpty)
        #expect(result.skipped.map(\.reason) == [.homebrewFailed("Error: permission denied")])
        #expect(fixture.exists("Applications/Firefox.app"))
        #expect(fixture.exists("Library/Caches/org.mozilla.firefox/blob"))
    }

    @Test("uninstall deletes the app and every owned item for good, never to the Trash, and logs each one")
    func uninstallIsIrreversibleAndRecorded() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        _ = try fixture.app("com.example.keeper", name: "Keeper")
        try fixture.file("Library/Caches/com.example.writer/blob", bytes: 10_000)
        try fixture.file("Library/Preferences/com.example.writer.plist")
        try fixture.file("Library/Application Support/Writer/notes")  // Likely: named exactly like the app
        try fixture.file("Library/Preferences/com.example.keeper.plist")
        let session = session()
        await session.load()

        let plan = try #require(await session.uninstallPlans(for: [writer]).first)
        #expect(plan.source == .direct)
        #expect(plan.skip == nil)
        #expect(Set(plan.items.map(\.path)).isSuperset(of: [fixture.path("Library/Application Support/Writer")]))

        let result = await session.uninstall([writer], backup: nil)

        #expect(result.removed == ["Writer"])
        #expect(result.summary.removedPermanentlyCount == 1 + plan.items.count)
        #expect(result.summary.movedToTrashCount == 0)
        #expect(result.summary.problems.isEmpty)
        for gone in [
            "Applications/Writer.app", "Library/Caches/com.example.writer",
            "Library/Preferences/com.example.writer.plist", "Library/Application Support/Writer",
        ] {
            #expect(!fixture.exists(gone), "\(gone) should be deleted")
        }
        #expect(fixture.exists("Applications/Keeper.app"))
        #expect(fixture.exists("Library/Preferences/com.example.keeper.plist"))
        #expect(try trashIsEmpty())
        let outcomes = try await records().filter { $0.outcome != .intent }
        #expect(outcomes.count == 1 + plan.items.count)
        #expect(outcomes.allSatisfy { $0.outcome == .removedPermanently })
        #expect(outcomes.contains { $0.itemPath == writer.id })
        #expect(Set(outcomes.map(\.operationID)).count == 1)
    }

    @Test("with a reviewed plan, an item found after the review is left alone and a changed one is refused")
    func uninstallTouchesOnlyTheReviewedList() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        try fixture.file("Library/Caches/com.example.writer/blob")
        try fixture.file("Library/Preferences/com.example.writer.plist")
        let session = session()
        await session.load()
        let reviewed = await session.uninstallPlans(for: [writer])
        try fixture.file("Library/Application Support/com.example.writer/new")  // appeared after the review
        try Data("changed".utf8).write(to: URL(filePath: fixture.path("Library/Preferences/com.example.writer.plist")))

        let result = await session.uninstall([writer], backup: nil, reviewed: reviewed)

        #expect(result.removed == ["Writer"])
        #expect(!fixture.exists("Applications/Writer.app"))
        #expect(!fixture.exists("Library/Caches/com.example.writer"))
        #expect(fixture.exists("Library/Application Support/com.example.writer/new"))
        #expect(fixture.exists("Library/Preferences/com.example.writer.plist"))
        #expect(result.summary.problems.map(\.path) == [fixture.path("Library/Preferences/com.example.writer.plist")])
    }

    @Test("a running or protected app is skipped; nothing of it is touched")
    func uninstallSkipsRunningApp() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let clenvra = try fixture.app(AppInventory.clenvraBundleIdentifier, name: "Clenvra")
        let session = session(running: ["com.example.writer"])
        await session.load()

        let result = await session.uninstall([writer, clenvra], backup: nil)

        #expect(result.removed.isEmpty)
        #expect(Set(result.skipped.map(\.reason)) == [.running, .protected])
        #expect(fixture.exists("Applications/Writer.app"))
        #expect(fixture.exists("Applications/Clenvra.app"))
    }

    @Test("with a backup the app is backed up first; when the backup fails nothing is removed")
    func uninstallBacksUpFirstAndAbortsOnFailure() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let viewer = try fixture.app("com.example.viewer", name: "Viewer")
        try fixture.file("Library/Caches/com.example.writer/blob")
        try fixture.file("Library/Preferences/com.example.writer.plist")
        let session = session()
        await session.load()

        let result = await session.uninstall([writer], backup: .wholeApp, backupFolder: backups)

        #expect(result.removed == ["Writer"])
        #expect(result.backups.count == 1)
        let made = try #require(AppBackup.list(in: backups).first)
        #expect(made.scope == .wholeApp)
        #expect(made.items.first?.original == writer.id)
        #expect(made.items.contains { $0.original == fixture.path("Library/Caches/com.example.writer") })
        #expect(!fixture.exists("Applications/Writer.app"))

        let locked = URL(filePath: fixture.path("Locked"), directoryHint: .isDirectory)
        try fixture.builder.directory("Locked")
        #expect(chmod(fixture.path("Locked"), 0o555) == 0)
        defer { chmod(fixture.path("Locked"), 0o755) }

        let failed = await session.uninstall([viewer], backup: .settingsOnly, backupFolder: locked)

        #expect(failed.removed.isEmpty)
        #expect(failed.backups.isEmpty)
        if case .backupFailed(let reason)? = failed.skipped.first?.reason {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("expected .backupFailed, got \(String(describing: failed.skipped.first?.reason))")
        }
        #expect(fixture.exists("Applications/Viewer.app"))
    }

    @Test("files only an administrator can remove go to the helper, deleted for good, after the bundle")
    func uninstallSendsSystemFilesToHelperIrreversibly() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        try fixture.file("sys/Library/Application Support/com.example.writer.daemon/state")
        let systemPath = fixture.path("sys/Library/Application Support/com.example.writer.daemon")
        let helper = RecordingHelper()
        let session = session(
            privileged: helper,
            receipts: { _ in [.init(path: systemPath, packageIdentifier: "com.example.writer.pkg")] })
        session.helperAvailable = true
        await session.load()

        let plan = try #require(await session.uninstallPlans(for: [writer]).first)
        #expect(plan.items.contains { $0.path == systemPath && session.needsHelper($0) })

        let result = await session.uninstall([writer], backup: nil)

        #expect(result.removed == ["Writer"])
        let requests = helper.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests.first?.mode == .irreversible)
        #expect(requests.first?.items.map(\.path) == [systemPath])
        #expect(!fixture.exists("Applications/Writer.app"))
        let logged = try await records().filter { $0.itemPath == systemPath }
        #expect(logged.map(\.outcome) == [.removedPermanently])
    }

    @Test("an app installed by a package leaves no installer record: the helper forgets it after the app is gone")
    func uninstallForgetsInstallerRecord() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        let pkgutil = FakeCommandRunner()
        pkgutil.stub(
            InstallSource.pkgutilPath, ["--file-info", app.id],
            stdout: "volume: /\npath: \(app.id)\n\npkgid: com.example.writer.pkg\npkg-version: 1.0\n")
        let helper = RecordingHelper()
        let session = session(privileged: helper, installSourceRunner: pkgutil)
        session.helperAvailable = true
        await session.load()

        let preview = await session.uninstall([app], backup: nil, dryRun: true)
        #expect(helper.forgotten.withLock { $0 }.isEmpty)  // a dry run changes nothing
        #expect(preview.receiptsKept.isEmpty)

        let result = await session.uninstall([app], backup: nil)

        #expect(result.removed == ["Writer"])
        #expect(helper.forgotten.withLock { $0 } == ["com.example.writer.pkg"])
        #expect(result.receiptsKept.isEmpty)
        // One password for the whole Uninstall: every helper call runs inside one authorization.
        #expect(helper.sessions.withLock { $0 } == 1)
        #expect(helper.callsOutsideSession.withLock { $0 } == 0)
    }

    @Test("an installer record the helper could not forget is reported, and the app is still removed")
    func uninstallReportsKeptRecord() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        let pkgutil = FakeCommandRunner()
        pkgutil.stub(InstallSource.pkgutilPath, ["--file-info", app.id], stdout: "pkgid: com.example.writer.pkg\n")
        let helper = RecordingHelper(forgetAnswer: .notAuthorized)
        let session = session(privileged: helper, installSourceRunner: pkgutil)
        session.helperAvailable = true
        await session.load()

        let result = await session.uninstall([app], backup: nil)

        #expect(result.removed == ["Writer"])
        #expect(result.receiptsKept == ["com.example.writer.pkg"])
        #expect(!fixture.exists("Applications/Writer.app"))
    }

    @Test("Copy Path and Show in Finder act on every checked app when the clicked one is checked")
    func copyPathUsesAllChecked() throws {
        let a = try fixture.app("com.example.a", name: "Alpha")
        let b = try fixture.app("com.example.b", name: "Beta")
        let c = try fixture.app("com.example.c", name: "Gamma")
        let apps = [a, b, c]

        #expect(AppsSession.paths(for: apps, clicked: [b.id], checked: [a.id, b.id]) == [a.id, b.id])
        #expect(AppsSession.paths(for: apps, clicked: [c.id], checked: [a.id, b.id]) == [c.id])
        #expect(AppsSession.paths(for: apps, clicked: [c.id, a.id], checked: [b.id]) == [a.id, c.id])
        #expect(AppsSession.paths(for: apps, clicked: [], checked: [a.id]) == [])
    }
}
