import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("FixtureBuilder")
struct FixtureBuilderTests {
    private let scratch: TemporaryDirectory
    private var builder: FixtureBuilder { FixtureBuilder(root: scratch.url) }
    private var root: URL { scratch.url }

    init() throws {
        scratch = try TemporaryDirectory()
    }

    // MARK: - lstat/stat verification helpers (never verify with the builder itself)

    private func fsPath(_ base: URL, _ relative: String) -> String {
        base.appending(path: relative).path(percentEncoded: false)
    }

    private func fsPath(_ relative: String) -> String {
        fsPath(root, relative)
    }

    private func lstatEntry(at path: String) -> stat {
        var entry = stat()
        let result = lstat(path, &entry)
        #expect(result == 0)
        return entry
    }

    private func lstatEntry(_ relative: String) -> stat {
        lstatEntry(at: fsPath(relative))
    }

    private func lstatEntry(at base: URL, _ relative: String) -> stat {
        lstatEntry(at: fsPath(base, relative))
    }

    private func readlinkTarget(_ relative: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let capacity = buffer.count
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return readlink(fsPath(relative), base.assumingMemoryBound(to: CChar.self), capacity)
        }
        #expect(count > 0)
        guard count > 0, count < buffer.count else { return nil }
        // readlink does not NUL-terminate; decode exactly the bytes it wrote.
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    /// Builds a fixture tree inside its own scratch directory, which is deallocated as soon as
    /// `configure` returns, letting the caller assert what TemporaryDirectory's deinit cleaned up.
    @discardableResult
    private func stageFixture(_ configure: (FixtureBuilder) throws -> Void) throws -> URL {
        let scratch = try TemporaryDirectory()
        try configure(FixtureBuilder(root: scratch.url))
        let url = scratch.url
        return url
    }

    // MARK: - Tests

    @Test("a written file has its exact byte count and content")
    func fileStoresExactBytesAndContent() throws {
        let url = try builder.file("nested/data.bin", bytes: 4_096, fill: 0x5A)

        let entry = lstatEntry("nested/data.bin")
        #expect((entry.st_mode & S_IFMT) == S_IFREG)
        #expect(entry.st_size == off_t(4_096))
        let contents = try Data(contentsOf: url)
        #expect(contents == Data(repeating: 0x5A, count: 4_096))
    }

    @Test("a sparse file reports the logical size with a small allocation")
    func sparseFileHasLogicalSizeAndTinyAllocation() throws {
        let logicalSize: Int64 = 8_000_000
        try builder.sparseFile("deep/big.bin", logicalSize: logicalSize)

        let entry = lstatEntry(at: root, "deep/big.bin")
        #expect((entry.st_mode & S_IFMT) == S_IFREG)
        #expect(Int64(entry.st_size) == logicalSize)
        #expect(Int64(entry.st_blocks) * 512 * 8 < logicalSize)
    }

    @Test("symlinks store the target verbatim, including dangling ones")
    func symlinkStoresTargetVerbatim() throws {
        try builder.file("real.txt", bytes: 4)
        try builder.symlink("link", to: "real.txt")
        try builder.symlink("dangling", to: "nowhere/missing.txt")

        let link = lstatEntry("link")
        #expect((link.st_mode & S_IFMT) == S_IFLNK)
        #expect(readlinkTarget("link") == "real.txt")

        let dangling = lstatEntry("dangling")
        #expect((dangling.st_mode & S_IFMT) == S_IFLNK)
        #expect(readlinkTarget("dangling") == "nowhere/missing.txt")

        var resolved = stat()
        let result = stat(fsPath("dangling"), &resolved)
        #expect(result == -1)
        #expect(errno == ENOENT)
    }

    @Test("a hard link shares inode, device and link count with the original")
    func hardLinkSharesIdentity() throws {
        try builder.file("original.bin", bytes: 16)
        try builder.hardLink("links/alias.bin", to: "original.bin")

        let original = lstatEntry("original.bin")
        let alias = lstatEntry(at: root, "links/alias.bin")
        #expect(alias.st_ino == original.st_ino)
        #expect(alias.st_dev == original.st_dev)
        #expect(alias.st_nlink == 2)
    }

    @Test("a clone keeps the content but gets a new inode")
    func cloneHasNewInodeAndSameContent() throws {
        let sourceURL = try builder.file("deep/source.bin", bytes: 300, fill: 0x37)
        try builder.clone("deep/copy.bin", of: "deep/source.bin")

        let source = lstatEntry(at: root, "deep/source.bin")
        let copy = lstatEntry(at: root, "deep/copy.bin")
        #expect(copy.st_ino != source.st_ino)
        #expect(copy.st_size == source.st_size)
        #expect(copy.st_dev == source.st_dev)

        let sourceBytes = try Data(contentsOf: sourceURL)
        let copyBytes = try Data(contentsOf: builder.url("deep/copy.bin"))
        #expect(copyBytes == Data(repeating: 0x37, count: 300))
        #expect(copyBytes == sourceBytes)
    }

    @Test("an immutable flag makes the file refuse writes")
    func immutableFlagBlocksWriting() throws {
        try builder.file("locked.bin", bytes: 4)
        try builder.setFlags("locked.bin", UInt32(UF_IMMUTABLE))

        let attempt = open(fsPath("locked.bin"), O_WRONLY | O_APPEND)
        if attempt >= 0 { _ = close(attempt) }
        let lastErrno = errno
        #expect(attempt == -1)
        #expect(lastErrno == EPERM)
    }

    @Test("TemporaryDirectory clears immutable flags so locked fixtures are removed")
    func cleanupRemovesImmutableFixtures() throws {
        let scratchURL = try stageFixture { staged in
            try staged.directory("locked")
            try staged.file("locked/x.bin", bytes: 8)
            try staged.setFlags("locked/x.bin", UInt32(UF_IMMUTABLE))
            try staged.setFlags("locked", UInt32(UF_IMMUTABLE))

            let locked = lstatEntry(at: staged.root, "locked")
            let file = lstatEntry(at: staged.root, "locked/x.bin")
            #expect(locked.st_flags & UInt32(UF_IMMUTABLE) != 0)
            #expect(file.st_flags & UInt32(UF_IMMUTABLE) != 0)
        }

        #expect(!FileManager.default.fileExists(atPath: scratchURL.path(percentEncoded: false)))
    }

    @Test("a chmod-000 directory refuses listing and is still cleaned up")
    func chmodZeroDirectoryIsUnlistableAndCleanedUp() throws {
        let scratchURL = try stageFixture { staged in
            try staged.directory("sealed")
            try staged.setPermissions("sealed", 0o000)

            let listing = opendir(fsPath(staged.root, "sealed"))
            let lastErrno = errno
            if let handle = listing { _ = closedir(handle) }
            #expect(listing == nil)
            #expect(lastErrno == EACCES)
        }

        #expect(!FileManager.default.fileExists(atPath: scratchURL.path(percentEncoded: false)))
    }

    @Test("setting a symlink's modification date touches only the link")
    func symlinkModificationDateDoesNotFollow() throws {
        try builder.file("target.bin", bytes: 4)
        try builder.symlink("link.bin", to: "target.bin")
        let targetBefore = lstatEntry("target.bin")

        try builder.setModificationDate("link.bin", Date(timeIntervalSince1970: 1_700_000_000))

        let targetAfter = lstatEntry("target.bin")
        #expect(targetAfter.st_mtimespec.tv_sec == targetBefore.st_mtimespec.tv_sec)
        #expect(targetAfter.st_mtimespec.tv_nsec == targetBefore.st_mtimespec.tv_nsec)

        let link = lstatEntry("link.bin")
        #expect(link.st_mtimespec.tv_sec == 1_700_000_000)
    }

    @Test("url resolves paths inside the scratch root")
    func urlResolvesWithinRoot() throws {
        try builder.file("sub/deep/file.txt", bytes: 1)

        let resolved = builder.url("sub/deep/file.txt")
        #expect(resolved == root.appending(path: "sub/deep/file.txt"))
        #expect(FileManager.default.fileExists(atPath: fsPath("sub/deep/file.txt")))
    }

    @Test("paths that would escape the scratch root are rejected")
    func rejectsEscapingPaths() throws {
        #expect(throws: FixtureError.self) { try builder.directory("../escape") }
        #expect(throws: FixtureError.self) { try builder.file("/etc/hosts-copy", bytes: 1) }
        // Symlink targets are stored verbatim on purpose; only the fixture path is validated.
        #expect(throws: FixtureError.self) { try builder.symlink("../outside", to: "real.txt") }
        #expect(throws: FixtureError.self) { try builder.hardLink("a/../b", to: "a") }
        #expect(throws: FixtureError.self) { try builder.clone("c/../d", of: "a") }
        #expect(throws: FixtureError.self) { try builder.sparseFile("up/..", logicalSize: 4) }
        #expect(throws: FixtureError.self) { try builder.setFlags("", UInt32(0)) }
        #expect(throws: FixtureError.self) { try builder.setPermissions("..", 0o644) }
    }
}
