import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// A hasher that maps every input to the same digest, so only the byte-for-byte stage can tell files apart.
private struct CollidingHasher: ContentHasher {
    mutating func update(_ bytes: UnsafeRawBufferPointer) {}
    func finalize() -> [UInt8] { [0xC0, 0x11, 0x1D, 0xE5] }
}

@Suite("DuplicateFinder")
struct DuplicateFinderTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let rootPath: String
    private let policy = ProtectionPolicy(home: "/Users/clenvra-duplicate-tests")
    private let small = DuplicateScanOptions(minimumSize: 1)

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        var path = scratch.url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        rootPath = path
    }

    // MARK: - Helpers

    private func path(_ relative: String) -> String { rootPath + "/" + relative }

    /// Deterministic, non-repeating content so head, middle and tail all differ between seeds.
    private static func content(size: Int, seed: UInt32) -> Data {
        var state = seed &* 2_654_435_761 &+ 1
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            for index in 0..<size {
                state = state &* 1_664_525 &+ 1_013_904_223
                raw[index] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        return data
    }

    @discardableResult
    private func write(_ relative: String, _ data: Data) throws -> String {
        let url = fixture.url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return path(relative)
    }

    private func scan(
        roots: [String]? = nil, options: DuplicateScanOptions? = nil, policy: ProtectionPolicy? = nil,
        hooks: DuplicateScanHooks = DuplicateScanHooks()
    ) async -> DuplicateScanResult {
        await DuplicateFinder.scan(
            roots: roots ?? [rootPath], options: options ?? small, policy: policy ?? self.policy,
            executor: .shared, progress: { _ in }, hooks: hooks)
    }

    private func paths(_ group: DuplicateGroup) -> Set<String> { Set(group.files.map(\.path)) }

    // MARK: - Grouping

    @Test("identical copies form one group; same size with a different middle does not join it")
    func identicalCopies() async throws {
        let size = 300 * 1024
        let original = Self.content(size: size, seed: 1)
        var middleChanged = original
        middleChanged[size / 2] ^= 0xFF
        try write("a/one.bin", original)
        try write("b/two.bin", original)
        try write("c/three.bin", original)
        try write("d/other.bin", middleChanged)
        try fixture.setModificationDate("a/one.bin", Date(timeIntervalSince1970: 1_700_000_000))
        try fixture.setModificationDate("b/two.bin", Date(timeIntervalSince1970: 1_600_000_000))
        try fixture.setModificationDate("c/three.bin", Date(timeIntervalSince1970: 1_650_000_000))

        let result = await scan()

        #expect(result.isComplete)
        #expect(result.skipped.isEmpty)
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        #expect(paths(group) == [path("a/one.bin"), path("b/two.bin"), path("c/three.bin")])
        #expect(group.size == Int64(size))
        #expect(group.suggestedKeeper == path("b/two.bin"), "the oldest copy is kept")
        #expect(group.files.first?.path == group.suggestedKeeper)
        let others = group.files.filter { $0.path != group.suggestedKeeper }
        #expect(group.reclaimableIfOthersRemoved == others.reduce(0) { $0 + $1.reclaimable })
        #expect(group.reclaimableIfOthersRemoved >= Int64(2 * size))
        #expect(!group.id.isEmpty)
    }

    @Test("equal head and tail but a different middle is not a duplicate")
    func middleDiffers() async throws {
        let size = 300 * 1024
        let original = Self.content(size: size, seed: 2)
        var changed = original
        changed[150 * 1024] ^= 0x01
        try write("x.bin", original)
        try write("y.bin", changed)

        let result = await scan()

        #expect(result.isComplete)
        #expect(result.groups.isEmpty)
    }

    @Test("small identical files are grouped and different ones are not")
    func smallFiles() async throws {
        try write("p.txt", Data("hello duplicate world".utf8))
        try write("q.txt", Data("hello duplicate world".utf8))
        try write("r.txt", Data("hello duplicate WORLD".utf8))

        let result = await scan()

        #expect(result.groups.map(paths) == [[path("p.txt"), path("q.txt")]])
    }

    @Test("several identical sets give several groups, largest reclaimable first")
    func ordering() async throws {
        try write("big1", Self.content(size: 200_000, seed: 3))
        try write("big2", Self.content(size: 200_000, seed: 3))
        try write("small1", Self.content(size: 5_000, seed: 4))
        try write("small2", Self.content(size: 5_000, seed: 4))

        let result = await scan()

        #expect(result.groups.map(paths) == [[path("big1"), path("big2")], [path("small1"), path("small2")]])
        #expect(Set(result.groups.map(\.id)).count == 2)
    }

    // MARK: - Hard links and clones

    @Test("hard links of one file are never a group")
    func hardLinksAlone() async throws {
        try write("data.bin", Self.content(size: 10_000, seed: 5))
        try fixture.hardLink("link1.bin", to: "data.bin")
        try fixture.hardLink("sub/link2.bin", to: "data.bin")

        let result = await scan()

        #expect(result.isComplete)
        #expect(result.groups.isEmpty)
    }

    @Test("a hard-linked file plus a real copy is a group of two distinct files")
    func hardLinkPlusCopy() async throws {
        let data = Self.content(size: 10_000, seed: 6)
        try write("data.bin", data)
        try fixture.hardLink("link.bin", to: "data.bin")
        try write("copy.bin", data)

        let result = await scan()

        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        #expect(group.files.count == 2)
        #expect(Set(group.files.map(\.snapshot.identity)).count == 2)
        #expect(group.files.contains { $0.path == path("copy.bin") })
        // Removing one name of a hard-linked file frees nothing.
        for file in group.files where file.path != path("copy.bin") {
            #expect(file.reclaimable == 0)
        }
    }

    @Test("an APFS clone is grouped but removing it frees nothing (S9)")
    func cloneFreesNothing() async throws {
        try write("original.bin", Self.content(size: 512 * 1024, seed: 7))
        try fixture.clone("clone.bin", of: "original.bin")

        let result = await scan()

        let group = try #require(result.groups.first)
        #expect(paths(group) == [path("original.bin"), path("clone.bin")])
        #expect(group.reclaimableIfOthersRemoved == 0)
        #expect(group.files.allSatisfy { $0.cloneID != nil })
    }

    // MARK: - What is never looked at

    @Test("symlinks, .git, .app, .photoslibrary, secrets and protected paths are ignored")
    func ignoredLocations() async throws {
        let data = Self.content(size: 4_096, seed: 8)
        try write("keep/a.bin", data)
        try write("keep/b.bin", data)
        try fixture.symlink("keep/link.bin", to: path("keep/a.bin"))
        try write("repo/.git/objects/a.bin", data)
        try write("Tool.app/Contents/a.bin", data)
        try write("Library.photoslibrary/originals/a.bin", data)
        try write("vault/a.bin", data)
        let secret = Self.content(size: 2_048, seed: 9)
        try write("one/id_ed25519", secret)
        try write("two/id_ed25519", secret)

        let guarded = ProtectionPolicy(home: "/Users/clenvra-duplicate-tests", additionalProtected: [path("vault")])
        let result = await scan(options: DuplicateScanOptions(minimumSize: 1, includeHidden: true), policy: guarded)

        #expect(result.groups.map(paths) == [[path("keep/a.bin"), path("keep/b.bin")]])
    }

    @Test("a protected root is skipped, not scanned")
    func protectedRoot() async throws {
        let data = Self.content(size: 4_096, seed: 10)
        try write("vault/a.bin", data)
        try write("vault/b.bin", data)
        let guarded = ProtectionPolicy(home: "/Users/clenvra-duplicate-tests", additionalProtected: [path("vault")])

        let result = await scan(roots: [path("vault")], policy: guarded)

        #expect(result.groups.isEmpty)
        #expect(result.skipped[path("vault")] == EPERM)
    }

    @Test("hidden files and folders are ignored unless included")
    func hidden() async throws {
        let data = Self.content(size: 4_096, seed: 11)
        try write(".cache/a.bin", data)
        try write(".b.bin", data)

        #expect(await scan().groups.isEmpty)
        let included = await scan(options: DuplicateScanOptions(minimumSize: 1, includeHidden: true))
        #expect(included.groups.map(paths) == [[path(".cache/a.bin"), path(".b.bin")]])
    }

    @Test("excluded paths are not scanned")
    func excluded() async throws {
        let data = Self.content(size: 4_096, seed: 12)
        try write("a.bin", data)
        try write("skip/b.bin", data)
        try write("c.bin", data)

        let result = await scan(options: DuplicateScanOptions(minimumSize: 1, excludedPaths: [path("skip/")]))

        #expect(result.groups.map(paths) == [[path("a.bin"), path("c.bin")]])
    }

    @Test("overlapping roots do not double count a file")
    func overlappingRoots() async throws {
        let data = Self.content(size: 4_096, seed: 13)
        try write("parent/child/a.bin", data)
        try write("parent/child/b.bin", data)

        let result = await scan(roots: [path("parent"), path("parent/child"), path("parent")])

        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        #expect(group.files.count == 2)
    }

    @Test("zero-length and below-minimum files are ignored")
    func sizeFloor() async throws {
        try write("empty1", Data())
        try write("empty2", Data())
        try write("tiny1", Data("0123456789".utf8))
        try write("tiny2", Data("0123456789".utf8))

        #expect(await scan(options: DuplicateScanOptions(minimumSize: 11)).groups.isEmpty)
        let floorOfOne = await scan(options: DuplicateScanOptions(minimumSize: 0))
        #expect(floorOfOne.groups.map(paths) == [[path("tiny1"), path("tiny2")]])
    }

    @Test("default minimum size is 1 MiB with four readers")
    func defaults() {
        let options = DuplicateScanOptions()
        #expect(options.minimumSize == 1024 * 1024)
        #expect(options.includeHidden == false)
        #expect(options.excludedPaths.isEmpty)
        #expect(options.maximumConcurrentReads == 4)
    }

    // MARK: - Changes, errors and cancellation

    @Test("a file changed after listing is dropped")
    func changedAfterListing() async throws {
        let data = Self.content(size: 100_000, seed: 14)
        try write("a.bin", data)
        try write("b.bin", data)
        try write("c.bin", data)
        let touched = fixture
        var hooks = DuplicateScanHooks()
        hooks.afterListing = {
            try? touched.setModificationDate("c.bin", Date(timeIntervalSince1970: 1_000_000_000))
        }

        let result = await scan(hooks: hooks)

        #expect(result.groups.map(paths) == [[path("a.bin"), path("b.bin")]])
    }

    @Test("a file changed after byte comparison is dropped by the final check")
    func changedBeforeFinalCheck() async throws {
        let data = Self.content(size: 100_000, seed: 15)
        try write("a.bin", data)
        try write("b.bin", data)
        let touched = fixture
        var hooks = DuplicateScanHooks()
        hooks.beforeFinalCheck = {
            try? touched.setModificationDate("b.bin", Date(timeIntervalSince1970: 1_000_000_000))
        }

        let result = await scan(hooks: hooks)

        #expect(result.groups.isEmpty)
    }

    @Test("an unreadable file is recorded as skipped and the others are still grouped")
    func unreadable() async throws {
        let data = Self.content(size: 50_000, seed: 16)
        try write("a.bin", data)
        try write("b.bin", data)
        try write("locked.bin", data)
        try fixture.setPermissions("locked.bin", 0o000)

        let result = await scan()

        #expect(result.groups.map(paths) == [[path("a.bin"), path("b.bin")]])
        #expect(result.skipped[path("locked.bin")] == EACCES)
        #expect(result.isComplete)
    }

    @Test("a missing root is recorded as skipped")
    func missingRoot() async {
        let result = await scan(roots: [path("does-not-exist")])
        #expect(result.groups.isEmpty)
        #expect(result.skipped[path("does-not-exist")] == ENOENT)
    }

    @Test("cancelling before the scan starts returns an incomplete, empty result")
    func cancelledBeforeStart() async throws {
        try write("a.bin", Self.content(size: 4_096, seed: 17))
        try write("b.bin", Self.content(size: 4_096, seed: 17))
        let root = rootPath
        let options = small
        let policy = policy

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await DuplicateFinder.scan(roots: [root], options: options, policy: policy)
        }
        let result = await task.value

        #expect(!result.isComplete)
        #expect(result.groups.isEmpty)
    }

    @Test("cancelling mid-scan returns an incomplete result without crashing")
    func cancelledAfterListing() async throws {
        for index in 0..<20 {
            try write("f\(index).bin", Self.content(size: 64_000, seed: UInt32(index % 5)))
        }
        var hooks = DuplicateScanHooks()
        hooks.afterListing = { withUnsafeCurrentTask { $0?.cancel() } }

        let result = await scan(hooks: hooks)

        #expect(!result.isComplete)
        #expect(result.groups.isEmpty)
    }

    // MARK: - Byte comparison

    @Test("a hash collision never produces a false group: byte comparison splits it")
    func byteCompareGuardsCollisions() async throws {
        try write("a1.bin", Self.content(size: 200_000, seed: 20))
        try write("a2.bin", Self.content(size: 200_000, seed: 20))
        try write("b1.bin", Self.content(size: 200_000, seed: 21))
        try write("b2.bin", Self.content(size: 200_000, seed: 21))
        try write("c.bin", Self.content(size: 200_000, seed: 22))
        var hooks = DuplicateScanHooks()
        hooks.makeHasher = { CollidingHasher() }

        let result = await scan(hooks: hooks)

        #expect(result.isComplete)
        #expect(
            Set(result.groups.map(paths)) == [
                [path("a1.bin"), path("a2.bin")], [path("b1.bin"), path("b2.bin")],
            ])
        #expect(Set(result.groups.map(\.id)).count == 2, "split groups keep distinct ids")
    }

    // MARK: - Pure decisions

    private func entry(name: String, kind: FileKind = .file, flags: UInt32 = 0, size: Int64 = 10) -> FileEntry {
        FileEntry(
            name: name, kind: kind, identity: FileIdentity(device: 1, inode: 2), linkCount: 1, flags: flags,
            modificationDate: Date(), size: SizeInfo(logical: size, allocated: size, reclaimable: size), cloneID: nil)
    }

    @Test("classification skips dataless, UF_HIDDEN and package folders; other volumes are not crossed")
    func classification() {
        let options = DuplicateScanOptions(minimumSize: 1)
        func classify(_ entry: FileEntry, device: Int32 = 1) -> DuplicateFinder.EntryAction {
            DuplicateFinder.classify(
                entry, at: "/x/" + entry.name, rootDevice: device, options: options, policy: policy)
        }
        #expect(classify(entry(name: "a")) == .consider)
        #expect(classify(entry(name: "cloud", flags: UInt32(SF_DATALESS))) == .ignore)
        #expect(classify(entry(name: "flagged", flags: UInt32(UF_HIDDEN))) == .ignore)
        #expect(classify(entry(name: "dir", kind: .directory)) == .descend)
        #expect(classify(entry(name: "dir", kind: .directory), device: 2) == .ignore)
        #expect(classify(entry(name: "Some.APP", kind: .directory)) == .ignore)
        #expect(classify(entry(name: "link", kind: .symlink)) == .ignore)
        #expect(classify(entry(name: "fifo", kind: .other)) == .ignore)
    }

    private func file(_ path: String, modified: TimeInterval) -> DuplicateFile {
        DuplicateFile(
            path: path,
            snapshot: FileSnapshot(
                identity: FileIdentity(device: 1, inode: UInt64(path.count)), kind: .file, logicalSize: 1,
                modificationDate: Date(timeIntervalSince1970: modified)),
            size: 1, allocated: 4096, reclaimable: 4096, modificationDate: Date(timeIntervalSince1970: modified),
            cloneID: nil)
    }

    @Test("keeper: oldest, then shortest path, then lexicographically smallest")
    func keeperHeuristic() {
        func keeper(_ files: DuplicateFile...) -> String? { DuplicateFinder.suggestedKeeper(among: files)?.path }
        #expect(keeper(file("/a/zz", modified: 5), file("/a/longer", modified: 1)) == "/a/longer")
        #expect(keeper(file("/a/longer", modified: 1), file("/a/zz", modified: 1)) == "/a/zz")
        #expect(keeper(file("/a/zz", modified: 1), file("/a/yy", modified: 1)) == "/a/yy")
        #expect(keeper() == nil)
    }

    // MARK: - Performance

    @Test("2,000 files of 32 KiB, half in duplicate pairs, finish well within a minute", .timeLimit(.minutes(1)))
    func performance() async throws {
        let size = 32 * 1024
        for index in 0..<2_000 {
            // Files 0..<1000 form 500 pairs; 1000..<2000 are unique. All share one size, the worst case for stage 3.
            let seed = index < 1_000 ? UInt32(index / 2) : UInt32(index)
            var data = Data(repeating: 0x5A, count: size)
            withUnsafeBytes(of: seed.littleEndian) { data.replaceSubrange(0..<4, with: $0) }
            try write("d\(index % 20)/f\(index).bin", data)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let result = await scan()
        let elapsed = clock.now - start
        print("DuplicateFinder performance: 2,000 files in \(elapsed)")

        #expect(result.isComplete)
        #expect(result.groups.count == 500)
        #expect(result.groups.allSatisfy { $0.files.count == 2 })
    }

    @Test("progress reports every phase")
    func progressPhases() async throws {
        try write("a.bin", Self.content(size: 300_000, seed: 30))
        try write("b.bin", Self.content(size: 300_000, seed: 30))
        let box = ProgressRecorder()

        _ = await DuplicateFinder.scan(roots: [rootPath], options: small, policy: policy) { box.record($0) }

        #expect(box.phases.contains(.listing))
        #expect(box.phases.contains(.grouping))
        #expect(box.phases.contains(.hashing))
        #expect(box.phases.contains(.verifying))
        #expect(box.last?.candidateFiles == 2)
    }
}

/// Collects progress callbacks, which arrive from the scan's tasks.
private final class ProgressRecorder: Sendable {
    private let calls = Mutex<[DuplicateScanProgress]>([])

    func record(_ progress: DuplicateScanProgress) {
        calls.withLock { $0.append(progress) }
    }

    var phases: [DuplicateScanProgress.Phase] { calls.withLock { $0.map(\.phase) } }
    var last: DuplicateScanProgress? { calls.withLock { $0.last } }
}
