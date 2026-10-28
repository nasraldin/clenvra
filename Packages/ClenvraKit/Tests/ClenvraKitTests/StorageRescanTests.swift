import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Records the root of every scan a rescan asks for, then runs the real scanner.
final class ScanRecorder: Sendable {
    private let roots = Mutex<[String]>([])

    var all: [String] { roots.withLock { $0 } }

    func reset() { roots.withLock { $0 = [] } }

    var scan: StorageScanner.ScanFunction {
        { root, options, executor, progress in
            self.roots.withLock { $0.append(root) }
            return try await StorageScanner.scan(root: root, options: options, executor: executor, progress: progress)
        }
    }
}

@Suite("Storage rescan")
struct StorageRescanTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let rootPath: String
    private let options: ScanOptions

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        rootPath = StorageScanner.normalize(scratch.url.path(percentEncoded: false))
        options = ScanOptions(largeFileThreshold: 1_000_000, excludedPaths: [rootPath + "/Excluded"])

        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try fixture.file("a/x/f1", bytes: 2_000)
        try fixture.file("a/x/big.bin", bytes: 1_200_000)
        try fixture.file("a/x/h", bytes: 50_000)
        try fixture.hardLink("b/h2", to: "a/x/h")
        try fixture.file("a/y/f2", bytes: 3_000)
        try fixture.file("a/y/deep/d", bytes: 500)
        try fixture.file("b/z/f3", bytes: 4_000)
        try fixture.file("b/z/sub/g", bytes: 1_100_000)
        try fixture.file("b/w", bytes: 100)
        try fixture.file("Excluded/e", bytes: 100)
        try fixture.directory("Trash")
        for (index, file) in ["a/x/f1", "a/x/big.bin", "a/y/f2", "a/y/deep/d", "b/z/f3", "b/z/sub/g", "b/w"]
            .enumerated()
        {
            try fixture.setModificationDate(file, old.addingTimeInterval(Double(index) * 86_400))
        }
    }

    private func path(_ relative: String) -> String { rootPath + "/" + relative }

    /// Moves an item into the fixture's Trash folder, as the real Trash does: the inode keeps its link count.
    private func trash(_ relative: String) throws {
        let name = (relative as NSString).lastPathComponent
        guard rename(path(relative), path("Trash/" + name)) == 0 else { throw POSIXError(.EIO) }
    }

    private func fullScan() async throws -> StorageSnapshot {
        try await StorageScanner.scan(root: rootPath, options: options)
    }

    private func rescan(
        _ snapshot: StorageSnapshot, changed: [String], recorder: ScanRecorder
    ) async throws -> StorageSnapshot {
        try await StorageScanner.rescan(
            snapshot, changedFolders: changed.map(path), options: options, scan: recorder.scan)
    }

    /// The patched snapshot must be indistinguishable from scanning the whole tree again.
    private func expectMatchesFullScan(
        _ patched: StorageSnapshot, ancestorsOf folders: [String], sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let full = try await fullScan()
        for folder in folders {
            var current = path(folder)
            while true {
                #expect(
                    patched.directories[current] == full.directories[current], "aggregate of \(current)",
                    sourceLocation: sourceLocation)
                guard current != rootPath else { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        #expect(patched.directories == full.directories, sourceLocation: sourceLocation)
        #expect(Set(patched.largeFiles) == Set(full.largeFiles), sourceLocation: sourceLocation)
        #expect(patched.largeFiles.map(\.path) == full.largeFiles.map(\.path), sourceLocation: sourceLocation)
        #expect(Set(patched.skipped) == Set(full.skipped), sourceLocation: sourceLocation)
        #expect(patched.isComplete == full.isComplete, sourceLocation: sourceLocation)
    }

    @Test("items removed from several folders: only those folders and the Trash are rescanned, totals stay exact")
    func severalFolders() async throws {
        let before = try await fullScan()
        try trash("a/x/big.bin")
        try trash("b/z")
        let recorder = ScanRecorder()

        let patched = try await rescan(before, changed: ["a/x", "Trash", "b", "Trash"], recorder: recorder)

        #expect(Set(recorder.all) == [path("a/x"), path("b"), path("Trash")])
        #expect(recorder.all.count == 3)
        #expect(!recorder.all.contains(rootPath))
        #expect(patched.aggregate(at: path("b/z")) == nil)
        #expect(patched.largeFiles.map(\.path) == [path("Trash/big.bin"), path("Trash/z/sub/g")])
        try await expectMatchesFullScan(patched, ancestorsOf: ["a/x", "b", "Trash"])
    }

    @Test("a changed folder inside another changed folder is covered by the outer rescan")
    func nestedFolders() async throws {
        let before = try await fullScan()
        try trash("a/y/deep/d")
        try trash("a/y/f2")
        let recorder = ScanRecorder()

        let patched = try await rescan(before, changed: ["a/y/deep", "a/y", "Trash"], recorder: recorder)

        #expect(Set(recorder.all) == [path("a/y"), path("Trash")])
        #expect(recorder.all.count == 2)
        try await expectMatchesFullScan(patched, ancestorsOf: ["a/y/deep", "Trash"])
    }

    @Test("a changed folder that no longer exists is replaced by its nearest existing ancestor")
    func goneFolder() async throws {
        let before = try await fullScan()
        try FileManager.default.removeItem(atPath: path("a/y/deep"))
        let recorder = ScanRecorder()

        let patched = try await rescan(before, changed: ["a/y/deep"], recorder: recorder)

        #expect(recorder.all == [path("a/y/deep"), path("a/y")])
        #expect(patched.aggregate(at: path("a/y/deep")) == nil)
        #expect(patched.aggregate(at: path("a/y"))?.childDirectoryNames == [])
        try await expectMatchesFullScan(patched, ancestorsOf: ["a/y"])
    }

    @Test("a hard-linked name moved to the Trash keeps the object counted once in every ancestor")
    func hardLinkMovedToTrash() async throws {
        let before = try await fullScan()
        try trash("a/x/h")
        let recorder = ScanRecorder()

        let patched = try await rescan(before, changed: ["a/x", "Trash"], recorder: recorder)

        #expect(!recorder.all.contains(rootPath))
        try await expectMatchesFullScan(patched, ancestorsOf: ["a/x", "Trash", "b"])
    }

    @Test("unlinking one name of a hard link also rescans the folders holding its other names")
    func unlinkedHardLink() async throws {
        let before = try await fullScan()
        try FileManager.default.removeItem(atPath: path("a/x/h"))
        let recorder = ScanRecorder()

        let patched = try await rescan(before, changed: ["a/x"], recorder: recorder)

        #expect(recorder.all == [path("a/x"), path("b")])
        #expect((patched.aggregate(at: path("b"))?.reclaimable ?? 0) > 50_000)
        try await expectMatchesFullScan(patched, ancestorsOf: ["a/x", "b"])
    }

    @Test("folders outside the scan, or inside a folder the scan skipped, need no rescan")
    func unscannedFolders() async throws {
        let before = try await fullScan()
        try FileManager.default.removeItem(atPath: path("Excluded/e"))
        let recorder = ScanRecorder()

        let patched = try await StorageScanner.rescan(
            before,
            changedFolders: [
                path("Excluded"), path("Excluded/inner"), path("a/../.."), "/clenvra-nonexistent/x", "relative/x",
            ],
            options: options, scan: recorder.scan)

        #expect(recorder.all.isEmpty)
        #expect(patched.directories == before.directories)
    }

    @Test("a change in the scanned root itself rescans the root")
    func rootChanged() async throws {
        let before = try await fullScan()
        try fixture.file("new.txt", bytes: 10)
        let recorder = ScanRecorder()

        let patched = try await StorageScanner.rescan(
            before, changedFolders: [rootPath + "/"], options: options, scan: recorder.scan)

        #expect(recorder.all == [rootPath])
        try await expectMatchesFullScan(patched, ancestorsOf: [])
    }
}
