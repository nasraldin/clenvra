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
}
