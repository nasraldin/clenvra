import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Moves items into the fixture's `.Trash` folder.
private struct FixtureTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

@MainActor
@Suite("AppsSession batch uninstall")
struct AppsBatchUninstallTests {
    private let fixture: AppsFixture
    private let running = RunningSet()

    init() throws {
        fixture = try AppsFixture()
    }

    private func session() -> AppsSession {
        let home = fixture.home
        let policy = ProtectionPolicy(home: home)
        let running = running
        let ownerState: @Sendable (String) -> OwnerState = { id in running.contains(id) ? .running : .notRunning }
        let log = ActivityLog(directory: URL(filePath: home + "/log"))
        return AppsSession(
            home: home, policy: policy,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState), log: log,
                trash: FixtureTrash(directory: home + "/.Trash")),
            log: log,
            resolver: OwnershipResolver(home: home, policy: policy, launchItems: fixture.launchItems),
            discover: {
                await AppInventory.discover(roots: [home + "/Applications"], homebrewCaskroom: home + "/Caskroom")
            },
            ownerState: { app in app.bundleIdentifier.map(ownerState) ?? .unknown },
            lastUsed: { _ in nil },
            teamIdentifier: { _ in nil })
    }

    private var backups: URL { URL(filePath: fixture.path("Backups"), directoryHint: .isDirectory) }

    @Test("checking apps never changes the selected app, and selecting never changes the checks")
    func checkingDoesNotChangeSelection() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let viewer = try fixture.app("com.example.viewer", name: "Viewer")
        let session = session()
        await session.load()
        await session.select(writer.id)

        session.toggleChecked(viewer.id)

        #expect(session.checked == [viewer.id])
        #expect(session.detail?.app.id == writer.id)

        await session.select(viewer.id)
        #expect(session.checked == [viewer.id])
        session.toggleChecked(viewer.id)
        #expect(session.checked.isEmpty)
        #expect(session.detail?.app.id == viewer.id)

        session.setChecked([writer.id, viewer.id, fixture.path("Applications/Missing.app")])
        #expect(session.checked == [writer.id, viewer.id])
        session.clearChecked()
        #expect(session.checked.isEmpty)
        #expect(session.detail?.app.id == viewer.id)
    }

    @Test("every checked app goes, even ones hidden by search, with backups and one Activity operation")
    func batchRemovesEveryCheckedApp() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let viewer = try fixture.app("com.example.viewer", name: "Viewer")
        _ = try fixture.app("com.example.keeper", name: "Keeper")
        try fixture.file("Library/Caches/com.example.writer/blob", bytes: 10_000)
        try fixture.file("Library/Preferences/com.example.viewer.plist")
        let session = session()
        await session.load()
        session.setChecked([writer.id, viewer.id])
        session.searchText = "keep"  // the checked apps are no longer shown

        #expect(session.checkedApps.map(\.name) == ["Viewer", "Writer"])

        let preview = await session.uninstallChecked(backup: backups, dryRun: true)
        #expect(preview.removed == ["Viewer", "Writer"])
        #expect(preview.summary.wouldRemoveCount == 4)
        #expect(preview.backups.isEmpty)
        #expect(fixture.exists("Applications/Writer.app"))

        let result = await session.uninstallChecked(backup: backups)

        #expect(result.removed == ["Viewer", "Writer"])
        #expect(result.skipped.isEmpty)
        #expect(result.summary.movedToTrashCount == 4)
        #expect(result.summary.problems.isEmpty)
        #expect(result.backups.count == 2)
        #expect(AppBackup.list(in: backups).map(\.name).sorted() == ["Viewer", "Writer"])
        for gone in [
            "Applications/Writer.app", "Applications/Viewer.app", "Library/Caches/com.example.writer",
            "Library/Preferences/com.example.viewer.plist",
        ] {
            #expect(!fixture.exists(gone), "\(gone) should be in the Trash")
        }
        #expect(fixture.exists("Applications/Keeper.app"))
        #expect(session.apps.map(\.name) == ["Keeper"])
        #expect(session.checked.isEmpty)
        let records = try await ActivityLog(directory: URL(filePath: fixture.path("log"))).readAll().records
        let removal = records.filter { $0.outcome != .wouldDelete }  // the dry run above is its own operation
        #expect(removal.count == 8)  // intent and outcome of 4 items
        #expect(Set(removal.map(\.operationID)).count == 1)
    }

    @Test("a running or protected app is skipped and reported; the others still go")
    func batchSkipsRunningApp() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let viewer = try fixture.app("com.example.viewer", name: "Viewer")
        let clenvra = try fixture.app(AppInventory.clenvraBundleIdentifier, name: "Clenvra")
        running.ids.withLock { $0 = ["com.example.writer"] }
        let session = session()
        await session.load()
        session.setChecked([writer.id, viewer.id, clenvra.id])

        let result = await session.uninstallChecked(backup: nil)

        #expect(result.removed == ["Viewer"])
        #expect(result.skipped.map(\.name) == ["Clenvra", "Writer"])
        #expect(result.skipped.map(\.reason) == [.protected, .running])
        #expect(fixture.exists("Applications/Writer.app"))
        #expect(fixture.exists("Applications/Clenvra.app"))
        #expect(!fixture.exists("Applications/Viewer.app"))
        #expect(session.checked == [writer.id, clenvra.id])
    }

    @Test("an app whose bundle changed since review is skipped as changed")
    func batchSkipsChangedApp() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let session = session()
        await session.load()
        session.setChecked([writer.id])
        try FileManager.default.removeItem(atPath: writer.id)

        let result = await session.uninstallChecked(backup: nil)

        #expect(result.removed.isEmpty)
        #expect(result.skipped.map(\.reason) == [.changed])
    }

    @Test("a backup is moved to the Trash through the deletion gate and logged")
    func trashBackup() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let session = session()
        await session.load()
        _ = try await AppBackup.create(app: writer, items: [writer.id], in: backups)
        let backup = try #require(AppBackup.list(in: backups).first)

        let summary = try #require(await session.trashBackup(backup))

        #expect(summary.movedToTrashCount == 1)
        #expect(AppBackup.list(in: backups).isEmpty)
        #expect(fixture.exists("Applications/Writer.app"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash")).count == 1)
        #expect(await session.trashBackup(backup) == nil)
    }

    @Test("when the backup fails the app is kept, with the reason")
    func batchSkipsWhenBackupFails() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        try fixture.file("Library/Caches/com.example.writer/blob")
        try fixture.builder.directory("Backups")
        #expect(chmod(fixture.path("Backups"), 0o555) == 0)
        defer { chmod(fixture.path("Backups"), 0o755) }
        let session = session()
        await session.load()
        session.setChecked([writer.id])

        let result = await session.uninstallChecked(backup: backups)

        #expect(result.removed.isEmpty)
        #expect(result.backups.isEmpty)
        #expect(result.skipped.count == 1)
        if case .backupFailed(let reason)? = result.skipped.first?.reason {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("expected .backupFailed, got \(String(describing: result.skipped.first?.reason))")
        }
        #expect(fixture.exists("Applications/Writer.app"))
        #expect(fixture.exists("Library/Caches/com.example.writer/blob"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash")).isEmpty)
    }
}

/// Which bundle identifiers are "running"; shared with the session's closures.
private final class RunningSet: Sendable {
    let ids = Mutex<Set<String>>([])

    func contains(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
}
