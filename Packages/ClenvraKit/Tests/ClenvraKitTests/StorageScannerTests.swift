import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Collects progress callbacks from the scanner's task.
private final class ProgressRecorder: Sendable {
    private let calls = Mutex<[ScanProgress]>([])

    func record(_ progress: ScanProgress) {
        calls.withLock { $0.append(progress) }
    }

    var all: [ScanProgress] { calls.withLock { $0 } }
}

@Suite("StorageScanner")
struct StorageScannerTests {
    private let scratch: TemporaryDirectory
    private let rootPath: String

    init() throws {
        scratch = try TemporaryDirectory()
        var path = scratch.url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        rootPath = path
    }

    // MARK: - Fixture helpers

    private func path(_ relative: String) -> String { rootPath + "/" + relative }

    private func makeFile(_ relative: String, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: URL(filePath: path(relative), directoryHint: .notDirectory))
    }

    private func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    /// Creates an empty file with raw syscalls; FileManager is too slow for the 100k-file fixture.
    private func touch(_ absolute: String) throws {
        let fd = open(absolute, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        close(fd)
    }

    private func scan(_ options: ScanOptions = ScanOptions()) async throws -> StorageSnapshot {
        try await StorageScanner.scan(root: rootPath, options: options)
    }

    private func entry(
        named name: String = "child", device: Int32, isMountPoint: Bool = false, kind: FileKind = .directory
    ) -> FileEntry {
        FileEntry(
            name: name, kind: kind, identity: FileIdentity(device: device, inode: 42), linkCount: 1, flags: 0,
            modificationDate: Date(), size: SizeInfo(logical: 0, allocated: 0, reclaimable: 0), cloneID: nil,
            isMountPoint: isMountPoint)
    }

    // MARK: - 1. Totals

    @Test("per-directory and subtree totals of a known tree are exact")
    func totals() async throws {
        try makeFile("a.txt", bytes: 100)
        try makeDirectory("docs/deep")
        try makeDirectory("empty")
        try makeFile("docs/b.txt", bytes: 2_000)
        try makeFile("docs/c.txt", bytes: 3_000)
        try makeFile("docs/deep/d.txt", bytes: 50_000)

        let snapshot = try await scan()

        #expect(snapshot.isComplete)
        #expect(snapshot.root == rootPath)
        #expect(Set(snapshot.directories.keys) == [rootPath, path("docs"), path("docs/deep"), path("empty")])

        let root = try #require(snapshot.aggregate(at: rootPath))
        #expect(root.fileCount == 4)
        #expect(root.directoryCount == 3)
        #expect(root.logical == 55_100)
        #expect(root.childDirectoryNames.sorted() == ["docs", "empty"])
        #expect(root.latestModification != nil)

        var info = stat()
        #expect(lstat(rootPath, &info) == 0)
        #expect(root.identity == FileIdentity(device: info.st_dev, inode: info.st_ino))

        let docs = try #require(snapshot.aggregate(at: path("docs")))
        #expect(docs.fileCount == 3)
        #expect(docs.directoryCount == 1)
        #expect(docs.logical == 55_000)
        #expect(docs.childDirectoryNames == ["deep"])

        let deep = try #require(snapshot.aggregate(at: path("docs/deep")))
        #expect(deep.fileCount == 1)
        #expect(deep.directoryCount == 0)
        #expect(deep.logical == 50_000)

        let empty = try #require(snapshot.aggregate(at: path("empty")))
        #expect(empty.fileCount == 0)
        #expect(empty.logical == 0)
        #expect(empty.latestModification == nil)

        for aggregate in snapshot.directories.values {
            #expect(aggregate.allocated >= aggregate.logical)
            #expect(aggregate.reclaimable <= aggregate.allocated)
        }
        #expect(snapshot.skipped.isEmpty)
    }

    @Test("aggregate(at:) accepts a trailing slash")
    func trailingSlashLookup() async throws {
        try makeDirectory("docs")
        let snapshot = try await StorageScanner.scan(root: rootPath + "/")
        #expect(snapshot.root == rootPath)
        #expect(snapshot.aggregate(at: path("docs") + "/") != nil)
    }

    // MARK: - 2. Symlinks

    @Test("a symlink to a big directory outside the root counts only the link itself")
    func symlinksNotFollowed() async throws {
        let outside = try TemporaryDirectory()
        let outsidePath = outside.url.path(percentEncoded: false)
        try Data(repeating: 0x42, count: 1_000_000).write(to: outside.url.appending(path: "big.bin"))
        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: outsidePath)

        var options = ScanOptions()
        options.largeFileThreshold = 1_000
        let snapshot = try await scan(options)

        let root = try #require(snapshot.aggregate(at: rootPath))
        #expect(root.fileCount == 1)
        #expect(root.directoryCount == 0)
        #expect(root.logical < 4_096)
        #expect(root.allocated < 100_000)
        #expect(Set(snapshot.directories.keys) == [rootPath])
        #expect(snapshot.largeFiles.isEmpty)
    }

    // MARK: - 3. Hard links

    @Test("hard links count their bytes once in every total and free nothing")
    func hardLinks() async throws {
        try makeDirectory("x")
        try makeDirectory("y")
        try makeFile("x/original", bytes: 100_000)
        try FileManager.default.linkItem(atPath: path("x/original"), toPath: path("y/link"))
        try FileManager.default.linkItem(atPath: path("x/original"), toPath: path("x/second"))

        let snapshot = try await scan()

        let root = try #require(snapshot.aggregate(at: rootPath))
        #expect(root.fileCount == 3)
        #expect(root.logical == 100_000)
        #expect(root.allocated >= 100_000)
        #expect(root.allocated < 200_000)
        #expect(root.reclaimable == 0)

        let x = try #require(snapshot.aggregate(at: path("x")))
        #expect(x.fileCount == 2)
        #expect(x.logical == 100_000)
        #expect(x.reclaimable == 0)

        let y = try #require(snapshot.aggregate(at: path("y")))
        #expect(y.logical == 100_000)
        #expect(y.reclaimable == 0)
    }

    // MARK: - 4. Clones

    @Test("a directory holding only an APFS clone frees ~nothing but still has allocated bytes")
    func clones() async throws {
        try makeDirectory("src")
        try makeDirectory("copies")
        try makeFile("src/original", bytes: 1_000_000)
        #expect(clonefile(path("src/original"), path("copies/clone"), 0) == 0)

        let snapshot = try await scan()

        let copies = try #require(snapshot.aggregate(at: path("copies")))
        #expect(copies.allocated >= 1_000_000)
        #expect(copies.logical == 1_000_000)
        #expect(copies.reclaimable == 0)
    }

    // MARK: - 5, 7. Traversal decisions

    @Test("a mount point or a directory on another device is not descended into")
    func volumeBoundary() {
        let sameDevice = entry(device: 7)
        #expect(
            StorageScanner.decision(forDirectory: sameDevice, at: "/r/child", rootDevice: 7, excludedPaths: []) == nil)

        let otherDevice = entry(device: 8)
        #expect(
            StorageScanner.decision(forDirectory: otherDevice, at: "/r/child", rootDevice: 7, excludedPaths: [])
                == .mountPoint)

        let mountPoint = entry(device: 7, isMountPoint: true)
        #expect(
            StorageScanner.decision(forDirectory: mountPoint, at: "/r/child", rootDevice: 7, excludedPaths: [])
                == .mountPoint)
    }

    @Test("an excluded path is not descended into")
    func excludedDecision() {
        let child = entry(device: 7)
        #expect(
            StorageScanner.decision(forDirectory: child, at: "/r/child", rootDevice: 7, excludedPaths: ["/r/child"])
                == .excluded)
    }

    @Test("excludedPaths are skipped during a scan and reported")
    func excludedScan() async throws {
        try makeDirectory("skipme")
        try makeDirectory("keep")
        try makeFile("skipme/f", bytes: 10)
        try makeFile("keep/f", bytes: 10)

        var options = ScanOptions()
        options.excludedPaths = [path("skipme") + "/"]
        let snapshot = try await scan(options)

        #expect(snapshot.skipped.contains(SkippedPath(path: path("skipme"), reason: .excluded)))
        #expect(snapshot.aggregate(at: path("skipme")) == nil)
        #expect(snapshot.aggregate(at: rootPath)?.fileCount == 1)
        #expect(snapshot.aggregate(at: rootPath)?.childDirectoryNames == ["keep"])
    }

    // MARK: - 6. Permission denied

    @Test("an unreadable directory is skipped and everything else is counted", .enabled(if: geteuid() != 0))
    func permissionDenied() async throws {
        try makeDirectory("locked")
        try makeDirectory("ok")
        try makeFile("locked/secret", bytes: 10)
        try makeFile("ok/f", bytes: 10)
        #expect(chmod(path("locked"), 0) == 0)

        let snapshot = try await scan()

        #expect(snapshot.isComplete)
        #expect(snapshot.skipped.contains(SkippedPath(path: path("locked"), reason: .permissionDenied)))
        #expect(snapshot.aggregate(at: rootPath)?.fileCount == 1)
        #expect(snapshot.aggregate(at: path("ok"))?.logical == 10)
    }

    // MARK: - 8. Race safety

    @Test("a child whose identity changed since the parent's listing is skipped")
    func identityCheck() {
        let listed = FileIdentity(device: 1, inode: 10)
        #expect(StorageScanner.identityMismatch(expected: listed, actual: listed) == nil)
        #expect(
            StorageScanner.identityMismatch(expected: listed, actual: FileIdentity(device: 1, inode: 11))
                == .changedDuringScan)
        #expect(
            StorageScanner.identityMismatch(expected: listed, actual: FileIdentity(device: 2, inode: 10))
                == .changedDuringScan)
    }

    @Test("open errors map to user-facing skip reasons")
    func errorMapping() {
        func reason(_ code: Int32) -> SkippedPath.Reason {
            StorageScanner.reason(for: FileSystemError(code: code, operation: "open", path: "/x"))
        }
        #expect(reason(EACCES) == .permissionDenied)
        #expect(reason(EPERM) == .permissionDenied)
        #expect(reason(ENOENT) == .changedDuringScan)
        #expect(reason(ELOOP) == .changedDuringScan)
        #expect(reason(ENOTDIR) == .changedDuringScan)
        #expect(reason(EIO) == .error(EIO))
    }

    // MARK: - 9. Large files

    @Test("large files are those at or above the threshold, biggest first, capped")
    func largeFiles() async throws {
        try makeDirectory("sub")
        try makeFile("a", bytes: 100_000)
        try makeFile("sub/b", bytes: 300_000)
        try makeFile("sub/c", bytes: 200_000)
        try makeFile("small1", bytes: 10_000)
        try makeFile("small2", bytes: 20_000)

        var options = ScanOptions()
        options.largeFileThreshold = 50_000
        let all = try await scan(options)
        #expect(all.largeFiles.map(\.path) == [path("sub/b"), path("sub/c"), path("a")])
        #expect(all.largeFiles.first?.size.logical == 300_000)

        options.maxLargeFiles = 2
        let capped = try await scan(options)
        #expect(capped.largeFiles.map(\.path) == [path("sub/b"), path("sub/c")])
    }

    @Test("a hard-linked large file is listed once")
    func largeHardLinkListedOnce() async throws {
        try makeFile("big", bytes: 100_000)
        try FileManager.default.linkItem(atPath: path("big"), toPath: path("alias"))

        var options = ScanOptions()
        options.largeFileThreshold = 50_000
        let snapshot = try await scan(options)

        #expect(snapshot.largeFiles.count == 1)
        #expect(snapshot.largeFiles.first?.linkCount == 2)
    }

    // MARK: - 10. Cancellation

    @Test("cancelling mid-scan returns promptly with a consistent partial snapshot", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        for outer in 0..<50 {
            for inner in 0..<100 {
                try makeDirectory("d\(outer)/e\(inner)")
            }
        }
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        var options = ScanOptions()
        options.progressInterval = .zero
        let root = rootPath
        let task = Task {
            try await StorageScanner.scan(root: root, options: options) { progress in
                if progress.directoriesScanned >= 10 { startedContinuation.yield() }
            }
        }
        for await _ in started { break }

        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let snapshot = try await task.value
        let elapsed = clock.now - start

        #expect(elapsed < .milliseconds(500))
        #expect(!snapshot.isComplete)
        #expect(snapshot.directories.count < 5_051)
        let rootAggregate = try #require(snapshot.aggregate(at: rootPath))
        #expect(rootAggregate.directoryCount == snapshot.directories.count - 1)
        for (directoryPath, aggregate) in snapshot.directories {
            for name in aggregate.childDirectoryNames {
                #expect(snapshot.directories[directoryPath + "/" + name] != nil)
            }
        }
    }

    // MARK: - 11. Progress

    @Test("progress is coalesced and a final progress carries the totals")
    func progressCoalesced() async throws {
        for index in 0..<20 {
            try makeDirectory("d\(index)")
            for file in 0..<50 { try touch(path("d\(index)/f\(file)")) }
        }

        let slow = ProgressRecorder()
        var options = ScanOptions()
        options.progressInterval = .seconds(60)
        _ = try await StorageScanner.scan(root: rootPath, options: options) { slow.record($0) }
        #expect(slow.all.count == 1)
        let final = try #require(slow.all.last)
        #expect(final.filesScanned == 1_000)
        #expect(final.directoriesScanned == 21)

        let fast = ProgressRecorder()
        options.progressInterval = .zero
        _ = try await StorageScanner.scan(root: rootPath, options: options) { fast.record($0) }
        #expect(fast.all.count > 1)
        #expect(fast.all.count <= 22)
        #expect(fast.all.last?.filesScanned == 1_000)
    }

    // MARK: - 12. Root errors

    @Test("a root that is a symlink or missing throws")
    func rootErrors() async throws {
        try makeDirectory("real")
        try FileManager.default.createSymbolicLink(atPath: path("alias"), withDestinationPath: path("real"))

        await #expect(throws: FileSystemError.self) {
            _ = try await StorageScanner.scan(root: path("alias"))
        }
        await #expect(throws: FileSystemError.self) {
            _ = try await StorageScanner.scan(root: path("missing"))
        }
    }

    // MARK: - 13. Performance smoke test

    @Test(
        "scans 100,000 files in 1,000 directories with exact counts",
        .enabled(if: ProcessInfo.processInfo.environment["CLENVRA_PERF"] == "1", "set CLENVRA_PERF=1 to run"),
        .timeLimit(.minutes(2)))
    func performanceSmoke() async throws {
        for directory in 0..<1_000 {
            let directoryPath = path("g\(directory / 100)/d\(directory)")
            try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
            for file in 0..<100 { try touch(directoryPath + "/f\(file)") }
        }

        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try await scan()
        let elapsed = clock.now - start

        let root = try #require(snapshot.aggregate(at: rootPath))
        #expect(snapshot.isComplete)
        #expect(root.fileCount == 100_000)
        #expect(root.directoryCount == 1_010)
        #expect(snapshot.aggregate(at: path("g3"))?.fileCount == 10_000)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let entries = Double(root.fileCount + root.directoryCount)
        print("StorageScanner: \(Int(entries)) entries in \(elapsed) → \(Int(entries / seconds)) entries/s")
    }
}
