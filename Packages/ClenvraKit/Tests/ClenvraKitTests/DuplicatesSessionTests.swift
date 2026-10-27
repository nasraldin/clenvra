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
@Suite("DuplicatesSession")
struct DuplicatesSessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    private static let oldest = Date(timeIntervalSince1970: 1_500_000_000)
    private static let middle = Date(timeIntervalSince1970: 1_600_000_000)
    private static let newest = Date(timeIntervalSince1970: 1_700_000_000)

    /// Report: three copies (Documents oldest, Desktop, Downloads newest). Photo: two copies. Tiny: below minimum.
    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try fixture.directory("Movies")
        try fixture.file("Documents/report.pdf", bytes: 400_000, fill: 0x41)
        try fixture.file("Desktop/report copy.pdf", bytes: 400_000, fill: 0x41)
        try fixture.file("Downloads/report.pdf", bytes: 400_000, fill: 0x41)
        try fixture.setModificationDate("Documents/report.pdf", Self.oldest)
        try fixture.setModificationDate("Desktop/report copy.pdf", Self.middle)
        try fixture.setModificationDate("Downloads/report.pdf", Self.newest)
        try fixture.file("Documents/photo.jpg", bytes: 200_000, fill: 0x42)
        try fixture.file("Pictures/photo.jpg", bytes: 200_000, fill: 0x42)
        try fixture.setModificationDate("Documents/photo.jpg", Self.newest)
        try fixture.setModificationDate("Pictures/photo.jpg", Self.oldest)
        try fixture.file("Documents/tiny.txt", bytes: 1_000, fill: 0x43)
        try fixture.file("Downloads/tiny.txt", bytes: 1_000, fill: 0x43)
    }

    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private func path(_ relative: String) -> String { home + "/" + relative }

    private var reportPaths: Set<String> {
        [path("Documents/report.pdf"), path("Desktop/report copy.pdf"), path("Downloads/report.pdf")]
    }
    private var photoPaths: Set<String> { [path("Documents/photo.jpg"), path("Pictures/photo.jpg")] }

    private func session() -> DuplicatesSession {
        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { _ in .notRunning }
        let session = DuplicatesSession(
            home: home, policy: policy,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState),
                log: ActivityLog(directory: fixture.url("log")),
                trash: FixtureTrash(directory: path(".Trash"))))
        session.minimumSize = 100_000
        return session
    }

    private func scanned() async -> DuplicatesSession {
        let session = session()
        await session.loadDefaultRoots()
        await session.scan()
        return session
    }

    private func group(_ session: DuplicatesSession, containing relative: String) -> DuplicatesSession.Group? {
        session.groups.first { $0.files.contains { $0.path == path(relative) } }
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relative))
    }

    /// S26: every group keeps at least one copy, and nothing outside the groups is marked.
    private func expectEveryGroupKeepsACopy(
        _ session: DuplicatesSession, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for group in session.groups {
            #expect(
                group.files.contains { !session.isMarked($0.path) }, "group \(group.id) has every copy marked",
                sourceLocation: sourceLocation)
        }
        let shown = Set(session.groups.flatMap { $0.files.map(\.path) })
        #expect(session.marked.isSubset(of: shown), sourceLocation: sourceLocation)
    }

    // MARK: - Folders

    @Test("default folders are the standard user folders that exist on this Mac")
    func defaultRoots() async {
        let session = session()

        await session.loadDefaultRoots()

        #expect(session.roots == ["Documents", "Downloads", "Desktop", "Pictures", "Movies"].map(path))
    }

    @Test("folders can be added and removed; duplicates and trailing slashes are ignored")
    func editRoots() async {
        let session = session()
        await session.loadDefaultRoots()

        session.removeRoot(path("Movies"))
        session.addRoot(path("Elsewhere") + "/")
        session.addRoot(path("Elsewhere"))

        #expect(session.roots == ["Documents", "Downloads", "Desktop", "Pictures", "Elsewhere"].map(path))
    }

    @Test("defaults never overwrite folders the user chose first")
    func defaultsDoNotOverrideChoice() async {
        let session = session()
        session.addRoot(path("Documents"))

        await session.loadDefaultRoots()

        #expect(session.roots == [path("Documents")])
    }

    // MARK: - Scanning

    @Test("scanning finds groups above the minimum size, largest first, and marks all but the suggested keeper")
    func scanDefaults() async throws {
        let session = await scanned()

        #expect(session.phase == .ready)
        #expect(session.lastScanWasComplete)
        #expect(session.groups.map { Set($0.files.map(\.path)) } == [reportPaths, photoPaths])
        let report = try #require(group(session, containing: "Documents/report.pdf"))
        #expect(report.suggestedKeeper == path("Documents/report.pdf"))
        #expect(report.files.first?.path == report.suggestedKeeper)
        #expect(
            session.marked == [
                path("Desktop/report copy.pdf"), path("Downloads/report.pdf"), path("Documents/photo.jpg"),
            ])
        #expect(session.markedCount == 3)
        #expect(session.markedBytes == session.groups.reduce(0) { $0 + $1.reclaimableIfOthersRemoved })
        #expect(session.markedBytes >= 1_000_000)
    }

    @Test("a smaller minimum size includes smaller files")
    func minimumSize() async {
        let session = session()
        await session.loadDefaultRoots()
        session.minimumSize = 1_000

        await session.scan()

        #expect(session.groups.count == 3)
    }

    @Test("scanned roots are canonical so deletions can be confined to them")
    func canonicalRoots() async throws {
        let session = session()
        try fixture.symlink("DocsLink", to: path("Documents"))
        session.addRoot(path("DocsLink"))
        session.addRoot(path("Downloads"))
        session.addRoot(path("Missing"))

        await session.scan()

        #expect(session.scannedRoots == [path("Documents"), path("Downloads")])
        #expect(session.groups.count == 1)
    }

    @Test("progress reports the scan stage while scanning")
    func progress() async {
        let session = session()
        await session.loadDefaultRoots()
        var stages: [DuplicateScanProgress.Phase] = []
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

    @Test("cancelling a scan ends it as incomplete")
    func cancel() async {
        let session = session()
        await session.loadDefaultRoots()
        let scan = Task { await session.scan() }
        while session.phase == .idle { await Task.yield() }

        session.cancelScan()
        await scan.value

        #expect(session.phase == .ready)
        #expect(!session.lastScanWasComplete)
        expectEveryGroupKeepsACopy(session)
    }

    @Test("cancelling the task running the scan also stops it")
    func cancelTask() async {
        let session = session()
        await session.loadDefaultRoots()
        let scan = Task { await session.scan() }

        scan.cancel()
        await scan.value

        #expect(session.phase == .ready)
        #expect(!session.lastScanWasComplete)
    }

    @Test("copies that share storage (APFS clones) report almost nothing reclaimable")
    func clones() async throws {
        try fixture.file("Movies/clip.mov", bytes: 500_000, fill: 0x44)
        try fixture.clone("Movies/clip copy.mov", of: "Movies/clip.mov")
        let session = await scanned()

        let clip = try #require(group(session, containing: "Movies/clip.mov"))
        #expect(clip.sharesStorage)
        #expect(clip.reclaimableIfOthersRemoved < 500_000 / 20)
        #expect(session.groups.last?.id == clip.id)
        #expect(group(session, containing: "Documents/report.pdf")?.sharesStorage == false)
    }

    // MARK: - S26: at least one copy is always kept

    @Test("marking the last kept copy is rejected and changes nothing")
    func lastCopyCannotBeMarked() async {
        let session = await scanned()
        let before = session.marked

        #expect(!session.canMark(path("Documents/report.pdf")))
        #expect(!session.setMarked(true, path: path("Documents/report.pdf")))
        #expect(!session.setMarked(true, path: path("Pictures/photo.jpg")))

        #expect(session.marked == before)
    }

    @Test("every sequence of mark, unmark and keep calls on a group leaves a copy kept")
    func exhaustiveToggleSequences() async {
        let session = await scanned()
        let files = reportPaths.sorted() + [path("Documents/photo.jpg"), path("Not/Shown.pdf")]
        enum Operation: CaseIterable { case mark, unmark, keepOnly }
        let operations = files.flatMap { file in Operation.allCases.map { (file, $0) } }

        for first in operations {
            for second in operations {
                for third in operations {
                    session.unmarkAll()
                    for (file, operation) in [first, second, third] {
                        switch operation {
                        case .mark: session.setMarked(true, path: file)
                        case .unmark: session.setMarked(false, path: file)
                        case .keepOnly: session.keepOnly(file)
                        }
                        let report = session.groups.first { $0.files.contains { reportPaths.contains($0.path) } }
                        guard let report, !report.files.contains(where: { !session.isMarked($0.path) }) else {
                            continue
                        }
                        Issue.record("every copy marked after \([first, second, third])")
                        return
                    }
                }
            }
        }
        expectEveryGroupKeepsACopy(session)
    }

    @Test("marking copies one by one stops before the last copy")
    func markOneByOne() async {
        let session = await scanned()
        session.unmarkAll()

        let accepted = reportPaths.sorted().map { session.setMarked(true, path: $0) }

        #expect(accepted == [true, true, false])
        expectEveryGroupKeepsACopy(session)
    }

    @Test("keep-only keeps exactly the chosen copy")
    func keepOnly() async {
        let session = await scanned()

        #expect(session.keepOnly(path("Downloads/report.pdf")))

        #expect(!session.isMarked(path("Downloads/report.pdf")))
        #expect(session.isMarked(path("Documents/report.pdf")))
        #expect(session.isMarked(path("Desktop/report copy.pdf")))
        #expect(!session.keepOnly(path("Not/Shown.pdf")))
    }

    @Test("keep newest and keep oldest choose by modification date in every group")
    func keepNewestOldest() async {
        let session = await scanned()

        session.keepNewest()
        #expect(!session.isMarked(path("Downloads/report.pdf")))
        #expect(!session.isMarked(path("Documents/photo.jpg")))
        #expect(
            session.marked == [
                path("Documents/report.pdf"), path("Desktop/report copy.pdf"), path("Pictures/photo.jpg"),
            ])
        expectEveryGroupKeepsACopy(session)

        session.keepOldest()
        #expect(
            session.marked == [
                path("Downloads/report.pdf"), path("Desktop/report copy.pdf"), path("Documents/photo.jpg"),
            ])
        expectEveryGroupKeepsACopy(session)
    }

    @Test("keep copies in a folder keeps them where present and leaves other groups unchanged")
    func keepInFolder() async {
        let session = await scanned()
        session.keepOnly(path("Pictures/photo.jpg"))
        let photoBefore = session.marked.intersection(photoPaths)

        session.keepCopies(inFolder: path("Downloads"))

        #expect(!session.isMarked(path("Downloads/report.pdf")))
        #expect(session.isMarked(path("Documents/report.pdf")))
        #expect(session.marked.intersection(photoPaths) == photoBefore)

        session.keepCopies(inFolder: path("Documents"))
        #expect(!session.isMarked(path("Documents/report.pdf")))
        #expect(!session.isMarked(path("Documents/photo.jpg")))
        #expect(session.isMarked(path("Pictures/photo.jpg")))

        session.keepCopies(inFolder: home)
        #expect(session.marked.isEmpty)
        expectEveryGroupKeepsACopy(session)
    }

    @Test("bulk helpers in any order keep a copy in every group")
    func bulkSequences() async {
        let session = await scanned()
        let helpers: [(DuplicatesSession) -> Void] = [
            { $0.keepNewest() }, { $0.keepOldest() }, { $0.unmarkAll() },
            { $0.keepCopies(inFolder: path("Desktop")) }, { $0.keepCopies(inFolder: path("Pictures")) },
            { $0.keepCopies(inFolder: path("Nowhere")) },
        ]
        for first in helpers {
            for second in helpers {
                for third in helpers {
                    first(session)
                    second(session)
                    third(session)
                    expectEveryGroupKeepsACopy(session)
                }
            }
        }
    }

    @Test("unmark all keeps every copy")
    func unmarkAll() async {
        let session = await scanned()

        session.unmarkAll()

        #expect(session.marked.isEmpty)
        #expect(session.markedBytes == 0)
    }

    @Test("marking is refused before results exist and while removing")
    func notReady() async {
        let session = session()

        #expect(!session.setMarked(true, path: path("Downloads/report.pdf")))
        #expect(!session.keepOnly(path("Downloads/report.pdf")))
        #expect(session.marked.isEmpty)
    }

    @Test("after a rescan where the kept copy vanished, the group still keeps a copy")
    func staleGroupAfterRescan() async throws {
        let session = await scanned()
        session.keepOnly(path("Downloads/report.pdf"))
        try FileManager.default.removeItem(atPath: path("Downloads/report.pdf"))

        await session.scan()

        let report = try #require(group(session, containing: "Documents/report.pdf"))
        #expect(report.files.count == 2)
        #expect(!session.isMarked(path("Documents/report.pdf")))
        #expect(session.isMarked(path("Desktop/report copy.pdf")))
        expectEveryGroupKeepsACopy(session)
    }

    @Test("a rescan keeps earlier choices for files found again; new files get the default")
    func choicesSurviveRescan() async throws {
        let session = await scanned()
        session.keepOnly(path("Desktop/report copy.pdf"))
        try fixture.file("Movies/report.pdf", bytes: 400_000, fill: 0x41)
        try fixture.setModificationDate("Movies/report.pdf", Self.newest)

        await session.scan()

        #expect(!session.isMarked(path("Desktop/report copy.pdf")))
        #expect(session.isMarked(path("Documents/report.pdf")))
        #expect(session.isMarked(path("Movies/report.pdf")))
        expectEveryGroupKeepsACopy(session)
    }

    @Test("the deletion plan leaves out any group whose copies are all marked, even if state was corrupted")
    func planRechecksEachGroup() async throws {
        let session = await scanned()
        session.marked = reportPaths.union([path("Documents/photo.jpg")])

        let plan = session.deletionPlan()

        #expect(plan.flatMap { $0.items.map(\.path) } == [path("Documents/photo.jpg")])

        await session.moveMarkedToTrash()
        #expect(exists("Documents/report.pdf"))
        #expect(exists("Desktop/report copy.pdf"))
        #expect(exists("Downloads/report.pdf"))
        #expect(!exists("Documents/photo.jpg"))
        expectEveryGroupKeepsACopy(session)
    }

    @Test("planned items carry the scanned root, snapshot and per-file reclaimable bytes")
    func planItems() async throws {
        let session = session()
        session.addRoot(home)
        session.addRoot(path("Downloads"))
        await session.scan()

        let items = session.deletionPlan().flatMap(\.items)
        let downloads = try #require(items.first { $0.path == path("Downloads/report.pdf") })
        let desktop = try #require(items.first { $0.path == path("Desktop/report copy.pdf") })

        #expect(downloads.ruleRoot == path("Downloads"))
        #expect(desktop.ruleRoot == home)
        #expect(desktop.section == .storage)
        #expect(desktop.ownerBundleID == nil)
        let file = try #require(session.groups.flatMap(\.files).first { $0.path == desktop.path })
        #expect(desktop.expected == file.snapshot)
        #expect(desktop.freedBytes == file.reclaimable)
    }

    // MARK: - Moving to the Trash

    @Test("moving to the Trash removes the marked copies, keeps the kept ones and drops resolved groups")
    func moveToTrash() async throws {
        let session = await scanned()
        let expectedBytes = session.markedBytes

        let summary = await session.moveMarkedToTrash()

        #expect(summary.movedToTrashCount == 3)
        #expect(summary.freedBytes == expectedBytes)
        #expect(summary.problems.isEmpty)
        #expect(exists("Documents/report.pdf"))
        #expect(exists("Pictures/photo.jpg"))
        #expect(!exists("Downloads/report.pdf"))
        #expect(!exists("Desktop/report copy.pdf"))
        #expect(!exists("Documents/photo.jpg"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: path(".Trash")).count == 3)
        #expect(session.groups.isEmpty)
        #expect(session.marked.isEmpty)
        #expect(session.phase == .ready)
        #expect(session.lastSummary == summary)
    }

    @Test("a group that still has two copies after removal stays, with both kept")
    func partialGroupRemains() async throws {
        let session = await scanned()
        session.setMarked(false, path: path("Desktop/report copy.pdf"))

        await session.moveMarkedToTrash()

        let report = try #require(group(session, containing: "Documents/report.pdf"))
        #expect(Set(report.files.map(\.path)) == [path("Documents/report.pdf"), path("Desktop/report copy.pdf")])
        #expect(session.marked.isEmpty)
        #expect(session.groups.count == 1)
    }

    @Test("a copy changed after review is skipped with its reason and stays listed")
    func changedCopySkipped() async throws {
        let session = await scanned()
        try fixture.setModificationDate("Downloads/report.pdf", Self.middle)

        let summary = await session.moveMarkedToTrash()

        #expect(summary.movedToTrashCount == 2)
        #expect(summary.problems.map(\.path) == [path("Downloads/report.pdf")])
        #expect(summary.problems.first?.reason == .skipped(.changedSinceScan))
        #expect(exists("Downloads/report.pdf"))
        let report = try #require(group(session, containing: "Documents/report.pdf"))
        #expect(report.files.count == 2)
        expectEveryGroupKeepsACopy(session)
    }

    @Test("a copy already gone is reported and removed from the results")
    func missingCopy() async throws {
        let session = await scanned()
        try FileManager.default.removeItem(atPath: path("Documents/photo.jpg"))

        let summary = await session.moveMarkedToTrash()

        #expect(summary.problems.map(\.path) == [path("Documents/photo.jpg")])
        #expect(summary.problems.first?.reason == .skipped(.notFound))
        #expect(group(session, containing: "Pictures/photo.jpg") == nil)
    }

    @Test("when every kept copy of a group is gone or changed, none of its copies are moved")
    func keptCopyVanished() async throws {
        let session = await scanned()
        try FileManager.default.removeItem(atPath: path("Documents/report.pdf"))

        let summary = await session.moveMarkedToTrash()

        #expect(exists("Desktop/report copy.pdf"))
        #expect(exists("Downloads/report.pdf"))
        #expect(!exists("Documents/photo.jpg"))
        #expect(summary.movedToTrashCount == 1)
        #expect(
            Set(summary.problems.map(\.path)) == [path("Desktop/report copy.pdf"), path("Downloads/report.pdf")])
        #expect(summary.problems.allSatisfy { $0.reason == .skipped(.changedSinceScan) })
        expectEveryGroupKeepsACopy(session)
    }

    @Test("with nothing marked, moving to the Trash changes nothing")
    func nothingMarked() async {
        let session = await scanned()
        session.unmarkAll()

        let summary = await session.moveMarkedToTrash()

        #expect(summary.movedToTrashCount == 0)
        #expect(summary.problems.isEmpty)
        #expect(session.groups.count == 2)
    }
}
