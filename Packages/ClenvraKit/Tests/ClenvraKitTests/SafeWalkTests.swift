import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("SafeWalk")
struct SafeWalkTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        let scratch = try TemporaryDirectory()
        self.scratch = scratch
        fixture = FixtureBuilder(root: scratch.url)
    }

    private func path(_ relative: String) -> String {
        scratch.url.appending(path: relative).path(percentEncoded: false)
    }

    private func lstatIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// A drive's `.Trashes` is `d-wx--x--t root`: it can be passed through but not read. The walk must only need
    /// to pass through the folders on the way, like `rm` does.
    @Test("passes through a folder that can be searched but not read")
    func passesThroughSearchOnlyFolder() throws {
        try fixture.file("trashes/501/old-file.bin", bytes: 3)
        #expect(chmod(path("trashes"), 0o311) == 0)
        defer { chmod(path("trashes"), 0o755) }

        let item = try SafeWalk.resolve(path("trashes/501/old-file.bin"))
        #expect(item.snapshot.logicalSize == 3)
        #expect(try SafeWalk.openDirectory(path("trashes/501")).identity() == lstatIdentity(path("trashes/501")))
    }

    @Test("resolves the parent directory and a snapshot of the item without following anything")
    func resolvesNestedFile() throws {
        try fixture.file("a/b/file.txt", bytes: 7)

        let item = try SafeWalk.resolve(path("a/b/file.txt"))

        #expect(item.name == "file.txt")
        #expect(try item.parent.identity() == lstatIdentity(path("a/b")))
        #expect(item.snapshot.identity == lstatIdentity(path("a/b/file.txt")))
        #expect(item.snapshot.kind == .file)
        #expect(item.snapshot.logicalSize == 7)
    }

    @Test("an ancestor replaced by a symlink is refused (safety case S2)")
    func ancestorSymlink() throws {
        try fixture.file("elsewhere/secret.txt", bytes: 4)
        try fixture.symlink("cache", to: path("elsewhere"))

        #expect(throws: SafetyRefusal.pathChanged) { _ = try SafeWalk.resolve(path("cache/secret.txt")) }
    }

    @Test("a symlink leaf resolves to the link itself (safety case S1)")
    func leafSymlink() throws {
        try fixture.file("target.txt", bytes: 4)
        try fixture.symlink("link", to: path("target.txt"))

        let item = try SafeWalk.resolve(path("link"))

        #expect(item.snapshot.kind == .symlink)
        #expect(item.snapshot.identity == lstatIdentity(path("link")))
    }

    @Test("a missing item is reported as not found")
    func missing() {
        #expect(throws: SafetyRefusal.notFound) { _ = try SafeWalk.resolve(path("nope")) }
        #expect(throws: SafetyRefusal.notFound) { _ = try SafeWalk.resolve(path("nope/deeper")) }
    }

    @Test("an unreadable ancestor is reported as permission denied")
    func permissionDenied() throws {
        try fixture.file("locked/inner.txt", bytes: 4)
        try fixture.setPermissions("locked", 0o000)

        #expect(throws: SafetyRefusal.permissionDenied) { _ = try SafeWalk.resolve(path("locked/inner.txt")) }
    }

    @Test("the root directory itself can never be a target")
    func rootRefused() {
        #expect(throws: SafetyRefusal.invalidPath(.notAbsolute)) { _ = try SafeWalk.resolve("relative/path") }
        #expect(throws: SafetyRefusal.isVolumeRoot) { _ = try SafeWalk.resolve("/") }
    }

    @Test("a snapshot taken from a scanned entry equals a fresh snapshot of the unchanged item")
    func snapshotFromEntryMatches() throws {
        try fixture.file("dir/f.bin", bytes: 100)
        let entry = try #require(try OpenDirectory(path: path("dir")).entries().first { $0.name == "f.bin" })

        let resolved = try SafeWalk.resolve(path("dir/f.bin"))

        #expect(FileSnapshot(entry) == resolved.snapshot)
    }

    @Test("a modified file no longer matches its scan snapshot (safety case S4)")
    func modifiedFileDiffers() throws {
        try fixture.file("dir/f.bin", bytes: 100)
        let entry = try #require(try OpenDirectory(path: path("dir")).entries().first { $0.name == "f.bin" })
        let handle = try FileHandle(forWritingTo: URL(filePath: path("dir/f.bin")))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1]))
        try handle.close()

        let resolved = try SafeWalk.resolve(path("dir/f.bin"))

        #expect(FileSnapshot(entry) != resolved.snapshot)
    }
}
