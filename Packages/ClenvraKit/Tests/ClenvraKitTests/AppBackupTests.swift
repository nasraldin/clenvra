import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("AppBackup")
struct AppBackupTests {
    private let fixture: AppsFixture

    init() throws {
        fixture = try AppsFixture()
    }

    private var backups: URL { URL(filePath: fixture.path("Backups"), directoryHint: .isDirectory) }

    private func xattr(_ path: String, _ name: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }

    /// The app plus one cache folder whose file carries an extended attribute; the payload is executable.
    private func makeApp() throws -> (app: InstalledApp, payload: String, cache: String, blob: String) {
        let app = try fixture.app("com.example.writer", name: "Writer")
        let payload = app.id + "/Contents/MacOS/payload"
        #expect(chmod(payload, 0o755) == 0)
        try fixture.file("Library/Caches/com.example.writer/blob", bytes: 5_000)
        let cache = fixture.path("Library/Caches/com.example.writer")
        let blob = cache + "/blob"
        let value = Array("tagged".utf8)
        let status = value.withUnsafeBytes { setxattr(blob, "com.example.tag", $0.baseAddress, value.count, 0, 0) }
        #expect(status == 0)
        return (app, payload, cache, blob)
    }

    @Test("a backup restores identical files, with the executable bit and extended attributes")
    func backupRoundTrip() async throws {
        let (app, payload, cache, blob) = try makeApp()
        let payloadData = try Data(contentsOf: URL(filePath: payload))
        let blobData = try Data(contentsOf: URL(filePath: blob))

        let backup = try await AppBackup.create(app: app, items: [app.id, cache], in: backups)

        #expect(backup.lastPathComponent.hasPrefix("Writer 1.0 "))
        #expect(backup.pathExtension == "clenvrabackup")
        let listed = AppBackup.list(in: backups)
        #expect(listed.count == 1)
        #expect(listed.first?.bundleID == "com.example.writer")
        #expect(listed.first?.items.map(\.original) == [app.id, cache])
        try FileManager.default.removeItem(atPath: app.id)
        try FileManager.default.removeItem(atPath: cache)

        let result = try await AppBackup.restore(backup)

        #expect(result.restored == [app.id, cache])
        #expect(result.skippedExisting.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(try Data(contentsOf: URL(filePath: payload)) == payloadData)
        #expect(try Data(contentsOf: URL(filePath: blob)) == blobData)
        #expect(mode(payload) == 0o755)
        #expect(xattr(blob, "com.example.tag") == "tagged")
        // Nothing is left behind next to the restored items.
        let caches = try FileManager.default.contentsOfDirectory(atPath: fixture.path("Library/Caches"))
        #expect(caches == ["com.example.writer"])
    }

    @Test("restore never overwrites: existing paths are skipped and reported, missing ones come back")
    func restoreNeverOverwrites() async throws {
        let (app, payload, cache, blob) = try makeApp()
        let backup = try await AppBackup.create(app: app, items: [app.id, cache], in: backups)
        try Data("changed".utf8).write(to: URL(filePath: payload))
        try FileManager.default.removeItem(atPath: blob)

        let first = try await AppBackup.restore(backup)

        // The cache folder still exists (only its file is gone), so it is skipped as a whole.
        #expect(first.restored.isEmpty)
        #expect(first.skippedExisting == [app.id, cache])
        #expect(try Data(contentsOf: URL(filePath: payload)) == Data("changed".utf8))

        try FileManager.default.removeItem(atPath: cache)
        let second = try await AppBackup.restore(backup)

        #expect(second.restored == [cache])
        #expect(second.skippedExisting == [app.id])
        #expect(try Data(contentsOf: URL(filePath: payload)) == Data("changed".utf8))
        #expect(fixture.exists("Library/Caches/com.example.writer/blob"))
    }

    @Test("list reads manifests and ignores folders whose manifest is missing or broken")
    func listReadsManifests() async throws {
        let (app, _, _, _) = try makeApp()
        _ = try await AppBackup.create(app: app, items: [app.id], in: backups)
        try fixture.builder.directory("Backups/Broken.clenvrabackup")
        try Data("{nope".utf8).write(to: URL(filePath: fixture.path("Backups/Broken.clenvrabackup/manifest.json")))
        try fixture.builder.directory("Backups/Empty.clenvrabackup")
        try fixture.builder.directory("Backups/Other folder")

        let listed = AppBackup.list(in: backups)

        #expect(listed.map(\.name) == ["Writer"])
        #expect(listed.first?.version == "1.0")
        #expect((listed.first?.bytes ?? 0) > 40_000)
        #expect((listed.first?.archiveBytes ?? 0) > 0)
    }

    @Test("a backup into a folder that cannot be written throws and leaves nothing behind")
    func createFailsCleanly() async throws {
        let (app, _, _, _) = try makeApp()
        try fixture.builder.directory("Backups")
        #expect(chmod(fixture.path("Backups"), 0o555) == 0)
        defer { chmod(fixture.path("Backups"), 0o755) }

        await #expect(throws: (any Error).self) {
            _ = try await AppBackup.create(app: app, items: [app.id], in: backups)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path("Backups")).isEmpty)
        #expect(fixture.exists("Applications/Writer.app"))
    }

    // MARK: - Scope

    @Test("a settings-only backup holds the app's settings and data, never the bundle, caches or logs")
    func settingsOnlyBackupExcludesBundleAndCaches() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        try fixture.file("Library/Caches/com.example.writer/blob")
        try fixture.file("Library/Logs/com.example.writer/log.txt")
        try fixture.file("Library/Preferences/com.example.writer.plist")
        try fixture.file("Library/Application Support/com.example.writer/db")
        try fixture.file("Library/Saved Application State/com.example.writer.savedState/data")
        try fixture.file("Library/HTTPStorages/com.example.writer/store")
        try fixture.container("com.example.writer", identifier: "com.example.writer")
        let owned = await fixture.resolver().resolve(app, installedApps: [app])
        #expect(owned.contains { $0.kind == .caches })

        let settings = AppBackup.paths(for: .settingsOnly, bundle: app.id, owned: owned)
        let whole = AppBackup.paths(for: .wholeApp, bundle: app.id, owned: owned)
        let backup = try await AppBackup.create(app: app, items: settings, scope: .settingsOnly, in: backups)

        let expected = Set([
            fixture.path("Library/Preferences/com.example.writer.plist"),
            fixture.path("Library/Application Support/com.example.writer"),
            fixture.path("Library/Saved Application State/com.example.writer.savedState"),
            fixture.path("Library/HTTPStorages/com.example.writer"),
            fixture.path("Library/Containers/com.example.writer"),
        ])
        #expect(Set(settings) == expected)
        #expect(!settings.contains(app.id))
        #expect(whole.first == app.id)
        #expect(Set(whole) == Set(owned.map(\.path)).union([app.id]))
        let listed = try #require(AppBackup.list(in: backups).first)
        #expect(listed.url.lastPathComponent == backup.lastPathComponent)
        #expect(listed.scope == .settingsOnly)
        #expect(Set(listed.items.map(\.original)) == expected)
    }

    @Test("a manifest written before scopes existed reads as a whole-app backup")
    func oldManifestIsWholeApp() throws {
        try fixture.builder.directory("Backups/Old.clenvrabackup")
        try fixture.file("Backups/Old.clenvrabackup/item-1.zip")
        let manifest = """
            {"bundleID": "com.example.old", "name": "Old", "version": "1", "created": "2026-01-01T10:00:00Z",
             "items": [{"original": "/Applications/Old.app", "archive": "item-1.zip", "bytes": 10}]}
            """
        try Data(manifest.utf8).write(to: URL(filePath: fixture.path("Backups/Old.clenvrabackup/manifest.json")))

        #expect(AppBackup.list(in: backups).map(\.scope) == [.wholeApp])
    }

    // MARK: - Choosing what to restore

    private func deleter(running: Set<String> = []) -> DeletionExecutor {
        let policy = ProtectionPolicy(home: fixture.home)
        return DeletionExecutor(
            gate: DeletionGate(
                policy: policy, ownerState: { running.contains($0) ? .running : .notRunning }),
            log: ActivityLog(directory: URL(filePath: fixture.path("log"))),
            trash: BackupFixtureTrash(directory: fixture.path(".Trash")))
    }

    @Test("only the chosen items are restored; the others stay missing")
    func restoreSelectedItemsOnly() async throws {
        let (app, _, cache, _) = try makeApp()
        let backup = try await AppBackup.create(app: app, items: [app.id, cache], in: backups)
        try FileManager.default.removeItem(atPath: app.id)
        try FileManager.default.removeItem(atPath: cache)

        let result = try await AppBackup.restore(backup, items: [cache])

        #expect(result.restored == [cache])
        #expect(result.skippedExisting.isEmpty)
        #expect(fixture.exists("Library/Caches/com.example.writer/blob"))
        #expect(!fixture.exists("Applications/Writer.app"))
    }

    @Test("replacing moves the current copy to the Trash first, logged, then restores the backup's copy")
    func restoreReplaceMovesCurrentToTrash() async throws {
        let (app, payload, cache, _) = try makeApp()
        let original = try Data(contentsOf: URL(filePath: payload))
        let backup = try await AppBackup.create(app: app, items: [app.id, cache], in: backups)
        try Data("upgraded".utf8).write(to: URL(filePath: payload))

        // Without replacing, nothing is touched.
        let kept = try await AppBackup.restore(backup, items: [app.id], replaceExisting: false, trash: deleter())
        #expect(kept.skippedExisting == [app.id])
        #expect(try Data(contentsOf: URL(filePath: payload)) == Data("upgraded".utf8))

        let result = try await AppBackup.restore(backup, items: [app.id], replaceExisting: true, trash: deleter())

        #expect(result.restored == [app.id])
        #expect(result.movedToTrash == [app.id])
        #expect(result.notReplaced.isEmpty)
        #expect(try Data(contentsOf: URL(filePath: payload)) == original)
        // The upgraded copy is in the Trash, never deleted; the cache was not chosen and is untouched.
        let trashed = try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash"))
        #expect(trashed.count == 1)
        let inTrash = fixture.path(".Trash/\(trashed[0])/Contents/MacOS/payload")
        #expect(try Data(contentsOf: URL(filePath: inTrash)) == Data("upgraded".utf8))
        #expect(fixture.exists("Library/Caches/com.example.writer/blob"))
        let records = try await ActivityLog(directory: URL(filePath: fixture.path("log"))).readAll().records
        #expect(records.contains { $0.itemPath == app.id && $0.outcome.isMovedToTrash })
    }

    @Test("replacing a running app's copy is refused by the deletion gate and nothing is restored over it")
    func restoreReplaceRefusesRunningApp() async throws {
        let (app, payload, cache, _) = try makeApp()
        let backup = try await AppBackup.create(app: app, items: [app.id, cache], in: backups)
        try Data("upgraded".utf8).write(to: URL(filePath: payload))

        let result = try await AppBackup.restore(
            backup, items: [app.id], replaceExisting: true, trash: deleter(running: ["com.example.writer"]))

        #expect(result.restored.isEmpty)
        #expect(result.movedToTrash.isEmpty)
        #expect(result.notReplaced.map(\.path) == [app.id])
        #expect(try Data(contentsOf: URL(filePath: payload)) == Data("upgraded".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash")).isEmpty)
    }
}

/// Moves items into the fixture's `.Trash` folder.
private struct BackupFixtureTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}
