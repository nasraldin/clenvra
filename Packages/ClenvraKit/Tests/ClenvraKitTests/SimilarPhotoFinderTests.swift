import Darwin
import Foundation
import Synchronization
import Testing
import Vision

@testable import ClenvraKit

@Suite("SimilarPhotoFinder")
struct SimilarPhotoFinderTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private func path(_ relative: String) -> String { home + "/" + relative }

    private func image(
        _ relative: String, _ scene: ImageFixture.Scene, width: Int = 400, height: Int = 300,
        format: ImageFixture.Format = .png
    ) throws {
        try ImageFixture.write(scene, width: width, height: height, format: format, to: fixture.url(relative))
    }

    private func scan(
        _ roots: [String] = ["Pictures"], options: SimilarPhotoScanOptions = SimilarPhotoScanOptions(),
        progress: @escaping @Sendable (SimilarPhotoScanProgress) -> Void = { _ in }
    ) async -> SimilarPhotoScanResult {
        await SimilarPhotoFinder.scan(
            roots: roots.map(path), options: options, policy: ProtectionPolicy(home: home), progress: progress)
    }

    private func photo(
        _ path: String, width: Int, height: Int, modified: TimeInterval, size: Int64 = 1_000
    ) -> SimilarPhoto {
        SimilarPhoto(
            path: path,
            snapshot: FileSnapshot(
                identity: FileIdentity(device: 1, inode: UInt64(abs(path.hashValue))), kind: .file, logicalSize: size,
                modificationDate: Date(timeIntervalSince1970: modified)),
            size: size, reclaimable: size, modificationDate: Date(timeIntervalSince1970: modified),
            pixelWidth: width, pixelHeight: height)
    }

    // MARK: - Finding

    @Test("the same picture re-encoded and resized is grouped; different pictures are not")
    func groupsSimilar() async throws {
        try image("Pictures/original.png", .landscape)
        try image("Pictures/Export/small.jpg", .landscape, width: 300, height: 225, format: .jpeg(quality: 0.8))
        try image("Pictures/board.png", .checkerboard)
        try image("Pictures/frames.png", .frames)

        let result = await scan()

        #expect(result.isComplete)
        #expect(result.skipped.isEmpty)
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        #expect(Set(group.photos.map(\.path)) == [path("Pictures/original.png"), path("Pictures/Export/small.jpg")])
        // The keeper has the most pixels and comes first.
        #expect(group.suggestedKeeper == path("Pictures/original.png"))
        #expect(group.photos.first?.path == group.suggestedKeeper)
        #expect(group.photos.first?.pixelWidth == 400 && group.photos.first?.pixelHeight == 300)
        let small = try #require(group.photos.last)
        #expect(group.reclaimableIfOthersRemoved == small.reclaimable)
        #expect(small.reclaimable > 0)
    }

    @Test("a stricter threshold separates the resized copy")
    func threshold() async throws {
        try image("Pictures/original.png", .landscape)
        try image("Pictures/small.jpg", .landscape, width: 300, height: 225, format: .jpeg(quality: 0.8))

        let strict = await scan(options: SimilarPhotoScanOptions(distanceThreshold: 0.01))
        let loose = await scan(options: SimilarPhotoScanOptions(distanceThreshold: 2))

        #expect(strict.groups.isEmpty)
        #expect(loose.groups.count == 1)
    }

    @Test("only regular image files are read: symlinks, other types and hidden files are ignored")
    func onlyImages() async throws {
        try image("Pictures/a.png", .landscape)
        try image("Elsewhere/b.png", .landscape)
        try fixture.symlink("Pictures/link.png", to: path("Elsewhere/b.png"))
        try fixture.file("Pictures/notes.txt", bytes: 2_000)
        try image("Pictures/.hidden.png", .landscape)

        let result = await scan()

        #expect(result.groups.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test("Photos libraries are never looked into, nor accepted as a folder to scan")
    func photosLibrary() async throws {
        try image("Pictures/a.png", .landscape)
        try image("Pictures/Photos Library.photoslibrary/originals/a.png", .landscape)

        let result = await scan(["Pictures", "Pictures/Photos Library.photoslibrary/originals"])

        #expect(result.groups.isEmpty)
        #expect(
            result.skipped == [path("Pictures/Photos Library.photoslibrary/originals"): .insidePhotosLibrary])
    }

    @Test("unreadable, undecodable and oversized images are skipped with a reason")
    func skipReasons() async throws {
        try image("Pictures/a.png", .landscape)
        try image("Pictures/b.png", .landscape, width: 360, height: 270)
        try image("Pictures/locked.png", .landscape)
        try fixture.setPermissions("Pictures/locked.png", 0o000)
        try fixture.file("Pictures/broken.jpg", bytes: 3_000, fill: 0x00)

        let result = await scan()

        #expect(result.groups.count == 1)
        #expect(result.skipped[path("Pictures/locked.png")] == .unreadable(EACCES))
        #expect(result.skipped[path("Pictures/broken.jpg")] == .notDecodable)

        let small = await scan(options: SimilarPhotoScanOptions(maximumFileSize: 100))
        #expect(small.groups.isEmpty)
        #expect(small.skipped[path("Pictures/a.png")] == .tooLarge)
    }

    @Test("hard-link names of one image are one image, and overlapping roots are scanned once")
    func hardLinksAndOverlap() async throws {
        try image("Pictures/a.png", .landscape)
        try fixture.hardLink("Pictures/Sub/a-link.png", to: "Pictures/a.png")

        let result = await scan(["Pictures", "Pictures/Sub"])

        #expect(result.groups.isEmpty)
    }

    @Test("progress moves from listing through analysing to grouping")
    func progress() async throws {
        try image("Pictures/a.png", .landscape)
        try image("Pictures/b.png", .checkerboard)
        let phases = Mutex<[SimilarPhotoScanProgress.Phase]>([])
        let last = Mutex<SimilarPhotoScanProgress?>(nil)

        _ = await scan { update in
            phases.withLock { if $0.last != update.phase { $0.append(update.phase) } }
            last.withLock { $0 = update }
        }

        #expect(phases.withLock { $0 } == [.listing, .analyzing, .grouping])
        #expect(last.withLock { $0?.imagesFound } == 2)
        #expect(last.withLock { $0?.imagesAnalyzed } == 2)
    }

    @Test("a cancelled scan returns early and says it is incomplete")
    func cancelled() async throws {
        try image("Pictures/a.png", .landscape)
        try image("Pictures/b.png", .landscape, width: 360, height: 270)

        let roots = [path("Pictures")]
        let policy = ProtectionPolicy(home: home)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SimilarPhotoFinder.scan(roots: roots, policy: policy)
        }
        let result = await task.value

        #expect(!result.isComplete)
        #expect(result.groups.isEmpty)
    }

    // MARK: - Pure decisions

    @Test("image types are recognised by extension; other types are not")
    func imageTypes() {
        for name in ["a.jpg", "b.JPEG", "c.png", "d.heic", "e.tiff", "f.gif", "g.webp"] {
            #expect(SimilarPhotoFinder.isImageName(name), "\(name)")
        }
        for name in ["a.txt", "b.mov", "c", "d.pdf", ".png.zip"] {
            #expect(!SimilarPhotoFinder.isImageName(name), "\(name)")
        }
    }

    @Test("the suggested keeper has the most pixels, then is the newest, then has the smallest path")
    func keeper() {
        let big = photo("/p/big.jpg", width: 600, height: 400, modified: 1)
        let newer = photo("/p/newer.jpg", width: 300, height: 400, modified: 5)
        let older = photo("/p/older.jpg", width: 300, height: 400, modified: 2)
        let twin = photo("/p/a-twin.jpg", width: 300, height: 400, modified: 5)

        #expect(SimilarPhotoFinder.suggestedKeeper(among: [older, big, newer])?.path == big.path)
        #expect(SimilarPhotoFinder.suggestedKeeper(among: [older, newer])?.path == newer.path)
        #expect(SimilarPhotoFinder.suggestedKeeper(among: [newer, twin])?.path == twin.path)
        #expect(SimilarPhotoFinder.suggestedKeeper(among: []) == nil)
    }

    @Test("clusters are built around a seed, so a chain of small differences does not form one group")
    func clustering() {
        // On a line: 0 and 1 are close, 1 and 2 are close, 0 and 2 are not.
        let vectors: [[Float]] = [[0, 0], [0.6, 0], [1.2, 0], [5, 5], [5.1, 5]]

        let clusters = SimilarPhotoFinder.cluster(vectors, threshold: 0.5)

        #expect(clusters == [[0, 1], [3, 4]])
    }

    @Test("the distance is the squared Euclidean distance Vision reports for its feature prints")
    func distanceMatchesVision() async throws {
        let request = GenerateImageFeaturePrintRequest()
        let first = try await request.perform(on: ImageFixture.render(.landscape, width: 400, height: 300))
        let second = try await request.perform(on: ImageFixture.render(.frames, width: 400, height: 300))

        let ours = try SimilarPhotoFinder.distance(
            #require(SimilarPhotoFinder.vector(of: first)), #require(SimilarPhotoFinder.vector(of: second)))

        #expect(abs(ours - (try first.distance(to: second))) < 1e-4)
        #expect(SimilarPhotoFinder.distance([1, 2], [1, 2]) == 0)
        #expect(SimilarPhotoFinder.distance([0, 0], [3, 4]) == 25)
    }
}
