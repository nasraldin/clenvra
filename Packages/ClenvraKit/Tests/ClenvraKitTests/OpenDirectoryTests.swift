import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("OpenDirectory")
struct OpenDirectoryTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private var root: URL { scratch.url }

    init() throws {
        let scratch = try TemporaryDirectory()
        self.scratch = scratch
        fixture = FixtureBuilder(root: scratch.url)
    }

    // MARK: - Helpers

    private func path(_ relative: String) -> String { root.appending(path: relative).path(percentEncoded: false) }

    private func lstatOf(_ relative: String) throws -> stat {
        var info = stat()
        guard lstat(path(relative), &info) == 0 else { throw POSIXError(.ENOENT) }
        return info
    }

    private func entries() throws -> [String: FileEntry] {
        let directory = try OpenDirectory(path: root.path(percentEncoded: false))
        return Dictionary(uniqueKeysWithValues: try directory.entries().map { ($0.name, $0) })
    }

    // MARK: - Tests

    @Test("lists every entry with its kind, including non-ASCII names")
    func kinds() throws {
        try fixture.file("تقرير.txt", bytes: 3)
        try fixture.directory("folder")
        try fixture.symlink("link", to: "folder")

        let result = try entries()

        #expect(Set(result.keys) == ["تقرير.txt", "folder", "link"])
        #expect(result["تقرير.txt"]?.kind == .file)
        #expect(result["folder"]?.kind == .directory)
        #expect(result["link"]?.kind == .symlink)
    }

    @Test("identity, link count and modification date match lstat")
    func identityMatchesLstat() throws {
        try fixture.file("a.bin", bytes: 10)
        let info = try lstatOf("a.bin")

        let entry = try #require(try entries()["a.bin"])

        #expect(entry.identity == FileIdentity(device: info.st_dev, inode: info.st_ino))
        #expect(entry.linkCount == 1)
        #expect(
            entry.modificationDate.timeIntervalSince1970 == Double(info.st_mtimespec.tv_sec) + Double(
                info.st_mtimespec.tv_nsec) / 1e9)
    }

    @Test("file sizes: logical, allocated and reclaimable for an unshared file")
    func sizes() throws {
        try fixture.file("data.bin", bytes: 10_000)

        let size = try #require(try entries()["data.bin"]).size

        #expect(size.logical == 10_000)
        #expect(size.allocated >= 10_000)
        #expect(size.reclaimable == size.allocated)
    }

    @Test("hard links share identity and report a link count of 2")
    func hardLinks() throws {
        try fixture.file("original", bytes: 100)
        try fixture.hardLink("second", to: "original")

        let result = try entries()

        #expect(result["original"]?.identity == result["second"]?.identity)
        #expect(result["second"]?.linkCount == 2)
    }

    @Test("an APFS clone shares its clone ID and frees nothing on its own")
    func clones() throws {
        try fixture.file("original", bytes: 1_000_000)
        try fixture.clone("clone", of: "original")

        let result = try entries()
        let original = try #require(result["original"])
        let clone = try #require(result["clone"])

        #expect(original.identity != clone.identity)
        #expect(original.cloneID != nil)
        #expect(original.cloneID == clone.cloneID)
        #expect(clone.size.reclaimable == 0)
    }

    @Test("BSD flags are reported")
    func flags() throws {
        try fixture.file("hidden", bytes: 1)
        try fixture.setFlags("hidden", UInt32(UF_HIDDEN))

        let entry = try #require(try entries()["hidden"])

        #expect(entry.flags & UInt32(UF_HIDDEN) != 0)
    }

    @Test("a large directory is read completely across multiple buffer refills")
    func manyEntries() throws {
        try fixture.directory("many")
        for index in 0..<5_000 {
            try fixture.file("many/item-\(index)-with-a-fairly-long-name.txt", bytes: 0)
        }

        let directory = try OpenDirectory(path: path("many"))

        #expect(try directory.entries().count == 5_000)
    }

    @Test("a child directory can be opened relative to its parent")
    func openChild() throws {
        try fixture.directory("parent/child")
        try fixture.file("parent/child/file", bytes: 1)

        let parent = try OpenDirectory(path: path("parent"))
        let child = try parent.openChild(named: "child")

        #expect(try child.entries().map(\.name) == ["file"])
    }

    @Test("symlinks are never followed when opening, either at the root or as a child")
    func symlinksNotFollowed() throws {
        try fixture.directory("real")
        try fixture.symlink("link", to: "real")

        #expect(throws: FileSystemError.self) { _ = try OpenDirectory(path: path("link")) }
        let parent = try OpenDirectory(path: root.path(percentEncoded: false))
        #expect(throws: FileSystemError.self) { _ = try parent.openChild(named: "link") }
    }

    @Test("names that could escape the parent are rejected")
    func childNameValidation() throws {
        let parent = try OpenDirectory(path: root.path(percentEncoded: false))
        for bad in ["", ".", "..", "a/b"] {
            #expect(throws: FileSystemError.self) { _ = try parent.openChild(named: bad) }
        }
    }

    @Test("permission denied is reported with EACCES")
    func permissionDenied() throws {
        try fixture.directory("locked")
        try fixture.setPermissions("locked", 0o000)

        let parent = try OpenDirectory(path: root.path(percentEncoded: false))

        #expect(throws: FileSystemError(code: EACCES, operation: "open", path: "locked")) {
            _ = try parent.openChild(named: "locked")
        }
    }

    @Test("the identity of the opened directory itself is available")
    func ownIdentity() throws {
        try fixture.directory("dir")
        let info = try lstatOf("dir")

        let directory = try OpenDirectory(path: path("dir"))

        #expect(try directory.identity() == FileIdentity(device: info.st_dev, inode: info.st_ino))
    }
}
