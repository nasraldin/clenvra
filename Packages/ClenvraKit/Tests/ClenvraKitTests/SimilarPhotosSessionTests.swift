import Darwin
import Foundation
import Testing

@testable import ClenvraKit

/// Moves items into a `.Trash` folder inside the test directory.
private struct FixtureTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

@MainActor
@Suite("SimilarPhotosSession")
struct SimilarPhotosSessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    /// Landscape: three versions (Pictures 400 × 300 PNG, Desktop 300 × 225 JPEG, Downloads 200 × 150 JPEG).
    /// Board: two versions (Pictures PNG, Documents JPEG of the same size, newer). Frames: one picture alone.
    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try fixture.directory("Movies")
        try image("Pictures/landscape.png", .landscape, width: 400, height: 300, format: .png)
        try image("Desktop/landscape.jpg", .landscape, width: 300, height: 225, format: .jpeg(quality: 0.8))
        try image("Downloads/landscape.jpg", .landscape, width: 240, height: 180, format: .jpeg(quality: 0.8))
        try image("Pictures/board.png", .checkerboard, width: 400, height: 300, format: .png)
        try image("Documents/board.jpg", .checkerboard, width: 400, height: 300, format: .jpeg(quality: 0.9))
        try fixture.setModificationDate("Pictures/board.png", Date(timeIntervalSince1970: 1_500_000_000))
        try fixture.setModificationDate("Documents/board.jpg", Date(timeIntervalSince1970: 1_700_000_000))
        try image("Pictures/frames.png", .frames, width: 400, height: 300, format: .png)
    }

    private func image(
        _ relative: String, _ scene: ImageFixture.Scene, width: Int, height: Int, format: ImageFixture.Format
    ) throws {
        try ImageFixture.write(scene, width: width, height: height, format: format, to: fixture.url(relative))
    }

    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private func path(_ relative: String) -> String { home + "/" + relative }

    private var landscapePaths: Set<String> {
        [path("Pictures/landscape.png"), path("Desktop/landscape.jpg"), path("Downloads/landscape.jpg")]
    }
    private var boardPaths: Set<String> { [path("Pictures/board.png"), path("Documents/board.jpg")] }

    private func session() -> SimilarPhotosSession {
        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { _ in .notRunning }
        return SimilarPhotosSession(
            home: home, policy: policy,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState),
                log: ActivityLog(directory: fixture.url("log")),
                trash: FixtureTrash(directory: path(".Trash"))))
    }

    private func scanned() async -> SimilarPhotosSession {
        let session = session()
        await session.loadDefaultRoots()
        await session.scan()
        return session
    }

    private func group(_ session: SimilarPhotosSession, containing relative: String) -> SimilarPhotoGroup? {
        session.groups.first { $0.photos.contains { $0.path == path(relative) } }
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relative))
    }

    /// Keep-one rule: every group keeps at least one image, and nothing outside the groups is marked.
    private func expectEveryGroupKeepsAnImage(
        _ session: SimilarPhotosSession, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for group in session.groups {
            #expect(
                group.photos.contains { !session.isMarked($0.path) }, "group \(group.id) has every image marked",
                sourceLocation: sourceLocation)
        }
        let shown = Set(session.groups.flatMap { $0.photos.map(\.path) })
        #expect(session.marked.isSubset(of: shown), sourceLocation: sourceLocation)
    }

    // MARK: - Folders

    @Test("default folders are the standard picture locations that exist on this Mac")
    func defaultRoots() async {
        let session = session()

        await session.loadDefaultRoots()

        #expect(session.roots == ["Pictures", "Desktop", "Downloads", "Documents"].map(path))
    }

    @Test("folders can be added and removed; duplicates and trailing slashes are ignored")
    func editRoots() async {
        let session = session()
        session.addRoot(path("Pictures") + "/")
        session.addRoot(path("Pictures"))
        session.addRoot(path("Movies"))

        session.removeRoot(path("Movies"))
        await session.loadDefaultRoots()

        #expect(session.roots == [path("Pictures")])
    }

    // MARK: - Scanning

    @Test("scanning groups similar pictures, suggests a keeper and marks nothing")
    func scanMarksNothing() async throws {
        let session = await scanned()

        #expect(session.phase == .ready)
        #expect(session.lastScanWasComplete)
        #expect(Set(session.groups.map { Set($0.photos.map(\.path)) }) == [landscapePaths, boardPaths])
        let landscape = try #require(group(session, containing: "Pictures/landscape.png"))
        #expect(landscape.suggestedKeeper == path("Pictures/landscape.png"))
        let board = try #require(group(session, containing: "Pictures/board.png"))
        // Same pixel count: the newer image is suggested.
        #expect(board.suggestedKeeper == path("Documents/board.jpg"))
        #expect(session.marked.isEmpty)
        #expect(session.markedCount == 0)
        #expect(session.markedBytes == 0)
        #expect(session.scannedRoots == ["Pictures", "Desktop", "Downloads", "Documents"].map(path))
    }

    @Test("the distance threshold is passed to the scan")
    func threshold() async {
        let session = session()
        await session.loadDefaultRoots()
        session.distanceThreshold = 0.000_1

        await session.scan()

        #expect(session.groups.isEmpty)
    }

    @Test("unreadable images are counted and reported with their reason")
    func skipped() async throws {
        try fixture.file("Pictures/broken.png", bytes: 500, fill: 0)
        let session = await scanned()

        #expect(session.skipped == [path("Pictures/broken.png"): .notDecodable])
    }

    @Test("progress reports the scan stage while scanning")
    func progress() async {
        let session = session()
        await session.loadDefaultRoots()
        var stages: [SimilarPhotoScanProgress.Phase] = []
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                if case .scanning(let progress) = session.phase, stages.last != progress.phase {
                    stages.append(progress.phase)
                }
                await Task.yield()
            }
        }
        await session.scan()
        observer.cancel()

        #expect(stages.first == .listing)
        #expect(session.phase == .ready)
    }

    @Test("cancelling a scan ends it as incomplete with no groups")
    func cancel() async {
        let session = session()
        await session.loadDefaultRoots()
        let scan = Task { await session.scan() }
        session.cancelScan()
        scan.cancel()
        await scan.value

        #expect(session.phase == .ready)
        #expect(!session.lastScanWasComplete)
        #expect(session.groups.isEmpty)
    }

    // MARK: - Marking

    @Test("opting in marks every image except each group's suggested keeper")
    func markAllButSuggested() async {
        let session = await scanned()

        session.markAllButSuggested()

        #expect(
            session.marked == [
                path("Desktop/landscape.jpg"), path("Downloads/landscape.jpg"), path("Pictures/board.png"),
            ])
        #expect(session.markedBytes == session.groups.reduce(0) { $0 + $1.reclaimableIfOthersRemoved })
        expectEveryGroupKeepsAnImage(session)
    }

    @Test("the last kept image of a group cannot be marked")
    func keepOne() async {
        let session = await scanned()

        #expect(session.setMarked(true, path: path("Pictures/board.png")))
        #expect(!session.canMark(path("Documents/board.jpg")))
        #expect(!session.setMarked(true, path: path("Documents/board.jpg")))
        #expect(session.canMark(path("Pictures/board.png")))
        #expect(session.setMarked(false, path: path("Pictures/board.png")))
        #expect(!session.setMarked(true, path: path("Pictures/frames.png")))
        expectEveryGroupKeepsAnImage(session)
    }

    @Test("keep only one image marks the rest of its group and leaves other groups alone")
    func keepOnly() async {
        let session = await scanned()

        #expect(session.keepOnly(path("Downloads/landscape.jpg")))

        #expect(session.marked == [path("Pictures/landscape.png"), path("Desktop/landscape.jpg")])
        session.unmarkAll()
        #expect(session.marked.isEmpty)
    }

    @Test("a rescan starts with nothing marked")
    func rescanClearsMarks() async {
        let session = await scanned()
        session.markAllButSuggested()

        await session.scan()

        #expect(session.marked.isEmpty)
    }

    @Test("marks are refused while not ready")
    func refusedWhenNotReady() {
        let session = session()

        #expect(!session.setMarked(true, path: path("Desktop/landscape.jpg")))
        session.markAllButSuggested()
        #expect(session.marked.isEmpty)
    }

    @Test("the deletion plan never removes every image of a group, even if the marks say so")
    func planKeepsOne() async {
        let session = await scanned()
        session.marked = boardPaths.union([path("Desktop/landscape.jpg")])

        let plan = session.deletionPlan()

        #expect(plan.flatMap { $0.items.map(\.path) } == [path("Desktop/landscape.jpg")])
    }

    // MARK: - Removing

    @Test("marked images move to the Trash; the keeper stays and emptied groups disappear")
    func moveToTrash() async throws {
        let session = await scanned()
        session.markAllButSuggested()

        let summary = await session.moveMarkedToTrash()

        #expect(summary.movedToTrashCount == 3)
        #expect(summary.problems.isEmpty)
        #expect(!exists("Desktop/landscape.jpg") && !exists("Downloads/landscape.jpg") && !exists("Pictures/board.png"))
        #expect(exists("Pictures/landscape.png") && exists("Documents/board.jpg"))
        #expect(session.groups.isEmpty)
        #expect(session.marked.isEmpty)
        #expect(session.lastSummary == summary)
        #expect(session.phase == .ready)
    }

    @Test("a group shrinks but stays while two or more images are left")
    func partialRemoval() async throws {
        let session = await scanned()
        session.setMarked(true, path: path("Downloads/landscape.jpg"))

        await session.moveMarkedToTrash()

        let landscape = try #require(group(session, containing: "Pictures/landscape.png"))
        #expect(Set(landscape.photos.map(\.path)) == [path("Pictures/landscape.png"), path("Desktop/landscape.jpg")])
        #expect(session.groups.count == 2)
    }

    @Test("nothing in a group is removed when its kept image changed on disk since the scan")
    func keptImageChanged() async throws {
        let session = await scanned()
        session.markAllButSuggested()
        try FileManager.default.removeItem(atPath: path("Documents/board.jpg"))

        let summary = await session.moveMarkedToTrash()

        #expect(exists("Pictures/board.png"))
        #expect(summary.problems.map(\.path) == [path("Pictures/board.png")])
        #expect(summary.movedToTrashCount == 2)
    }

    // MARK: - Blurry or dark photos

    /// A photo rated by image analysis, for results injected with `apply(_:roots:)`.
    private func rated(_ relative: String, score: Float, reclaimable: Int64 = 1_000) throws -> SimilarPhoto {
        let resolved = try SafeWalk.resolve(path(relative))
        return SimilarPhoto(
            path: path(relative), snapshot: resolved.snapshot, size: reclaimable, reclaimable: reclaimable,
            modificationDate: Date(timeIntervalSince1970: 1_600_000_000), pixelWidth: 400, pixelHeight: 300,
            quality: PhotoQuality(score: score, isUtility: false))
    }

    @Test("a scan rates every compared photo and lists only low-rated ones, worst first")
    func scanRatesPhotos() async {
        let session = await scanned()

        #expect(session.groups.flatMap(\.photos).allSatisfy { $0.quality != nil })
        #expect(session.lowQualityPhotos.allSatisfy { $0.quality?.isLow == true })
        let scores = session.lowQualityPhotos.compactMap { $0.quality?.score }
        #expect(scores == scores.sorted())
        #expect(!session.lowQualityPhotos.contains { session.isMarked($0.path) })
    }

    @Test("a blurry or dark photo in no group can be marked on its own and moved to the Trash")
    func lowQualityPhotoCanBeMarkedAlone() async throws {
        let session = await scanned()
        let frames = try rated("Pictures/frames.png", score: -0.4)
        session.apply(
            SimilarPhotoScanResult(groups: session.groups, lowQuality: [frames], skipped: [:], isComplete: true),
            roots: session.scannedRoots)

        #expect(session.lowQualityPhotos == [frames])
        #expect(session.marked.isEmpty)
        #expect(session.canMark(frames.path))
        #expect(session.setMarked(true, path: frames.path))
        #expect(session.markedCount == 1)
        #expect(session.markedBytes == frames.reclaimable)

        session.unmarkAll()
        session.markAllButSuggested()
        #expect(!session.isMarked(frames.path))

        session.unmarkAll()
        session.setMarked(true, path: frames.path)
        let summary = await session.moveMarkedToTrash()

        #expect(summary.movedToTrashCount == 1)
        #expect(summary.problems.isEmpty)
        #expect(!exists("Pictures/frames.png"))
        #expect(session.lowQualityPhotos.isEmpty)
        #expect(session.marked.isEmpty)
        #expect(session.groups.count == 2)
    }

    @Test("a blurry photo that is also in a group keeps the group's keep-one rule")
    func groupRuleStillWins() async throws {
        let session = await scanned()
        let board = try #require(group(session, containing: "Pictures/board.png"))
        let low = board.photos.map { photo in
            SimilarPhoto(
                path: photo.path, snapshot: photo.snapshot, size: photo.size, reclaimable: photo.reclaimable,
                modificationDate: photo.modificationDate, pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight, quality: PhotoQuality(score: -0.5, isUtility: false))
        }
        session.apply(
            SimilarPhotoScanResult(groups: session.groups, lowQuality: low, skipped: [:], isComplete: true),
            roots: session.scannedRoots)

        #expect(session.setMarked(true, path: path("Pictures/board.png")))
        #expect(!session.canMark(path("Documents/board.jpg")))
        #expect(!session.setMarked(true, path: path("Documents/board.jpg")))
        // Listed twice, counted once.
        #expect(session.markedCount == 1)
        #expect(session.markedBytes == board.photos.first { $0.path == path("Pictures/board.png") }?.reclaimable)
        expectEveryGroupKeepsAnImage(session)
    }
}
