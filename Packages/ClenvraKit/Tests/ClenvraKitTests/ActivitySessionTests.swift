import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@MainActor
@Suite("ActivitySession")
struct ActivitySessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try fixture.directory("cache")
    }

    private func path(_ relative: String) -> String {
        scratch.url.appending(path: relative).path(percentEncoded: false)
    }

    private func identity(of relative: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path(relative), &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Appends the records to a fresh log, then loads a session over it.
    private func loadedSession(records: [ActivityRecord]) async throws -> ActivitySession {
        let log = ActivityLog(directory: scratch.url)
        for record in records {
            try await log.append(record)
        }
        let session = ActivitySession(activityLog: log)
        await session.load()
        return session
    }

    private func record(
        op: UUID,
        date: Date = Date(timeIntervalSince1970: 1_800_000_000),
        section: ActivityRecord.Section = .cleanup,
        path itemPath: String,
        bytes: Int64 = 100,
        outcome: ActivityRecord.Outcome = .wouldDelete,
        identity: FileIdentity? = nil
    ) -> ActivityRecord {
        ActivityRecord(
            operationID: op, date: date, section: section, itemPath: itemPath, bytes: bytes,
            outcome: outcome, identity: identity)
    }

    /// A record describing an item Clenvra moved to the Trash, with the Trash object still in place.
    private func trashed(name: String, op: UUID) throws -> ActivityRecord {
        try fixture.file(".Trash/\(name)", bytes: 3)
        return ActivityRecord(
            operationID: op, date: Date(timeIntervalSince1970: 1_800_000_000), section: .cleanup,
            itemPath: path("cache/\(name)"), bytes: 3,
            outcome: .movedToTrash(trashPath: path(".Trash/\(name)")), identity: identity(of: ".Trash/\(name)"))
    }

    // MARK: - Grouping

    @Test("records group by operation ID, newest operation first")
    func groupedByOperationNewestFirst() async throws {
        let oldOp = UUID()
        let newOp = UUID()
        let session = try await loadedSession(records: [
            record(op: newOp, date: Date(timeIntervalSince1970: 1_800_001_000), path: "/cache/a"),
            record(op: oldOp, date: Date(timeIntervalSince1970: 1_800_000_000), path: "/cache/b"),
        ])

        #expect(session.operations.map(\.id) == [newOp, oldOp])
        #expect(session.operations[1].items.count == 1)
        #expect(session.operations[1].items[0].record.itemPath == "/cache/b")
    }

    @Test("intent records leave no row and no totals; the outcome record comes last per path")
    func intentRecordsAreIgnored() async throws {
        let op = UUID()
        let session = try await loadedSession(records: [
            record(op: op, path: "/c/a.bin", bytes: 4096, outcome: .intent),
            record(op: op, path: "/c/a.bin", bytes: 1024, outcome: .movedToTrash(trashPath: "/Users/u/.Trash/a.bin")),
        ])

        #expect(session.operations.count == 1)
        #expect(session.operations[0].items.count == 1)
        #expect(session.operations[0].items[0].outcome == .movedToTrash(trashPath: "/Users/u/.Trash/a.bin"))
        #expect(session.operations[0].movedCount == 1)
        #expect(session.operations[0].removedCount == 0)
        #expect(session.operations[0].freedBytes == 1024)
    }

    @Test("counts per outcome and bytes freed sum moved and permanent removals only")
    func outcomeCountsAndFreedBytes() async throws {
        let op = UUID()
        let session = try await loadedSession(records: [
            record(op: op, path: "/a", bytes: 100, outcome: .movedToTrash(trashPath: "/Trash/a")),
            record(op: op, path: "/b", bytes: 200, outcome: .removedPermanently),
            record(op: op, path: "/c", bytes: 300, outcome: .wouldDelete),
            record(op: op, path: "/d", bytes: 400, outcome: .skipped(.inUse)),
            record(op: op, path: "/e", bytes: 500, outcome: .failed(errno: EIO)),
            record(op: op, path: "/f", bytes: 600, outcome: .notAttempted),
        ])

        let operation = session.operations[0]
        #expect(operation.movedCount == 1)
        #expect(operation.removedCount == 1)
        #expect(operation.wouldDeleteCount == 1)
        #expect(operation.skippedCount == 2)
        #expect(operation.failedCount == 1)
        #expect(operation.freedBytes == 300)
    }

    // MARK: - Filtering

    @Test("section filter and case-insensitive path search narrow the visible operations")
    func sectionFilterAndSearch() async throws {
        let cleanupOp = UUID()
        let storageOp = UUID()
        let session = try await loadedSession(records: [
            record(op: cleanupOp, section: .cleanup, path: "/Users/u/Library/Caches/x"),
            record(
                op: storageOp, date: Date(timeIntervalSince1970: 1_800_001_000), section: .storage,
                path: "/Volumes/big/x"),
        ])

        session.searchText = "caches"
        #expect(session.visibleOperations.map(\.id) == [cleanupOp])
        #expect(session.visibleOperations[0].items.count == 1)

        session.searchText = "/no such path"
        #expect(session.visibleOperations.isEmpty)

        session.searchText = ""
        session.sectionFilter = .storage
        #expect(session.visibleOperations.map(\.id) == [storageOp])
    }

    // MARK: - Export

    @Test("CSV quotes commas, double quotes, newlines, keeps Arabic paths, and uses ISO-8601 UTC dates")
    func csvQuotingAndArabicPaths() async throws {
        let session = try await loadedSession(records: [
            record(
                op: UUID(), date: Date(timeIntervalSince1970: 0), section: .cleanup,
                path: "/a,b\"c.dmg", bytes: 10, outcome: .movedToTrash(trashPath: "/Trash/x")),
            record(
                op: UUID(), date: Date(timeIntervalSince1970: 0), section: .cleanup,
                path: "/Downloads/تقارير/الملف القديم.txt", bytes: 20, outcome: .removedPermanently),
            record(
                op: UUID(), date: Date(timeIntervalSince1970: 0), section: .cleanup,
                path: "/weird\nline/file", bytes: 30, outcome: .skipped(.inUse)),
            record(
                op: UUID(), date: Date(timeIntervalSince1970: 0), section: .developer,
                path: "/d/e", bytes: 40, outcome: .failed(errno: EIO)),
        ])

        let csv = session.exportCSV()
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }

        #expect(lines.count == 5)
        #expect(lines[0] == "date,section,path,outcome,bytes")
        #expect(csv.contains("\"/a,b\"\"c.dmg\""))
        #expect(csv.contains("\"/weird\nline/file\""))
        #expect(csv.contains("/Downloads/تقارير/الملف القديم.txt"))
        #expect(lines.contains { $0.hasPrefix("1970-01-01T00:00:00Z,cleanup,") && $0.hasSuffix(",movedToTrash,10") })
        #expect(lines.contains { $0.hasSuffix("الملف القديم.txt,removedPermanently,20") })
    }

    @Test("CSV export honours the section filter and path search")
    func csvExportIsFiltered() async throws {
        let session = try await loadedSession(records: [
            record(op: UUID(), section: .cleanup, path: "/Caches/x"),
            record(op: UUID(), date: Date(timeIntervalSince1970: 1_800_001_000), section: .storage, path: "/Volumes/x"),
        ])

        session.sectionFilter = .storage
        let csv = session.exportCSV()
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines[1].contains(",storage,/Volumes/x,"))
    }

    @Test("Markdown report has a title, the period, totals and one escaped row per item")
    func markdownReport() async throws {
        let op = UUID()
        let restored = try trashed(name: "back.bin", op: op)
        let session = try await loadedSession(records: [
            record(
                op: op, date: Date(timeIntervalSince1970: 0), path: "/a|b\nc.dmg", bytes: 10,
                outcome: .movedToTrash(trashPath: "/Trash/x")),
            record(
                op: op, date: Date(timeIntervalSince1970: 60), path: "/Downloads/تقارير/الملف.txt", bytes: 20,
                outcome: .removedPermanently),
            record(op: op, date: Date(timeIntervalSince1970: 120), path: "/s", bytes: 30, outcome: .skipped(.inUse)),
            record(
                op: UUID(), date: Date(timeIntervalSince1970: 86_400), section: .developer, path: "/f", bytes: 40,
                outcome: .failed(errno: EIO)),
            restored,
        ])
        #expect(await session.restore(itemPath: restored.itemPath, operationID: op) == nil)

        let report = session.exportMarkdown()
        let lines = report.components(separatedBy: "\n")

        #expect(lines[0] == "# Clenvra Activity Report")
        #expect(report.contains("Period: 1970-01-01T00:00:00Z – 2027-01-15T08:00:00Z"))
        #expect(report.contains("- Moved to Trash: 1\n"))
        #expect(report.contains("- Removed permanently: 1\n"))
        #expect(report.contains("- Put back: 1\n"))
        #expect(report.contains("- Skipped: 1\n"))
        #expect(report.contains("- Failed: 1\n"))
        #expect(report.contains("- Bytes freed: 30\n"))
        #expect(report.contains("| Date | Section | Path | Bytes | Outcome |"))
        #expect(report.contains("| 1970-01-01T00:00:00Z | cleanup | /a\\|b<br>c.dmg | 10 | movedToTrash |"))
        #expect(
            report.contains(
                "| 1970-01-01T00:01:00Z | cleanup | /Downloads/تقارير/الملف.txt | 20 | removedPermanently |"))
        #expect(report.contains("| 1970-01-02T00:00:00Z | developer | /f | 40 | failed |"))
        #expect(report.contains("| 3 | restored |"))
        #expect(lines.filter { $0.hasPrefix("| ") }.count == 7)  // header, separator, five items
        #expect(report == session.exportMarkdown())
    }

    @Test("Markdown report neutralises HTML and honours the section filter")
    func markdownReportIsFilteredAndEscaped() async throws {
        let session = try await loadedSession(records: [
            record(op: UUID(), section: .cleanup, path: "/x/<script>&\r"),
            record(op: UUID(), date: Date(timeIntervalSince1970: 1_800_001_000), section: .storage, path: "/v"),
        ])

        #expect(session.exportMarkdown().contains("/x/&lt;script&gt;&amp;<br>"))
        session.sectionFilter = .storage
        let report = session.exportMarkdown()
        #expect(!report.contains("/x/"))
        #expect(report.contains("| storage | /v | 100 | wouldDelete |"))
        #expect(report.contains("Period: 2027-01-15T08:16:40Z – 2027-01-15T08:16:40Z"))
    }

    @Test("an empty Markdown report says there is no activity")
    func markdownReportEmpty() async throws {
        let session = try await loadedSession(records: [])
        let report = session.exportMarkdown()
        #expect(report.contains("No activity."))
        #expect(!report.contains("| Date |"))
    }

    // MARK: - Restore

    @Test("an item Clenvra moved to the Trash is put back and reported as restored")
    func restoreSucceeds() async throws {
        let op = UUID()
        let record = try trashed(name: "a.bin", op: op)
        let session = try await loadedSession(records: [record])

        let failure = await session.restore(itemPath: record.itemPath, operationID: op)

        #expect(failure == nil)
        #expect(session.isRestored(itemPath: record.itemPath, operationID: op))
        #expect(identity(of: "cache/a.bin") == record.identity)
        #expect(identity(of: ".Trash/a.bin") == nil)
    }

    @Test("restore never overwrites an item that now occupies the original path")
    func restoreRefusesOccupiedPath() async throws {
        let op = UUID()
        let record = try trashed(name: "a.bin", op: op)
        let session = try await loadedSession(records: [record])
        try fixture.file("cache/a.bin", bytes: 1)

        #expect(await session.restore(itemPath: record.itemPath, operationID: op) == .originalPathOccupied)
        #expect(identity(of: ".Trash/a.bin") == record.identity)
    }

    @Test("restore is refused when the Trash no longer holds the item")
    func restoreRefusesWhenNotInTrash() async throws {
        let op = UUID()
        let record = try trashed(name: "a.bin", op: op)
        let session = try await loadedSession(records: [record])
        try FileManager.default.removeItem(atPath: path(".Trash/a.bin"))

        #expect(await session.restore(itemPath: record.itemPath, operationID: op) == .notInTrash)
    }

    @Test("restore is refused when the original folder no longer exists")
    func restoreRefusesWhenFolderMissing() async throws {
        let op = UUID()
        let record = try trashed(name: "a.bin", op: op)
        let session = try await loadedSession(records: [record])
        try FileManager.default.removeItem(atPath: path("cache"))

        #expect(await session.restore(itemPath: record.itemPath, operationID: op) == .originalFolderMissing)
    }

    @Test("records that are not Trash moves, and unknown operations, cannot be restored")
    func restoreRefusesNonTrashRecords() async throws {
        let session = try await loadedSession(records: [
            record(op: UUID(), path: "/x", bytes: 0, outcome: .removedPermanently)
        ])

        #expect(await session.restore(itemPath: "/x", operationID: session.operations[0].id) == .notRestorable)
        #expect(await session.restore(itemPath: "/unknown", operationID: UUID()) == .notRestorable)
    }

    @Test("every RestoreError maps to a user-facing reason")
    func restoreErrorMapping() {
        #expect(RestoreReason(.notRestorable) == .notRestorable)
        #expect(RestoreReason(.notInTrash) == .notInTrash)
        #expect(RestoreReason(.originalFolderMissing) == .originalFolderMissing)
        #expect(RestoreReason(.originalPathOccupied) == .originalPathOccupied)
        #expect(RestoreReason(.failed(errno: EIO)) == .restoreFailed)
    }

    @Test("restored state survives a reload that rebuilds the operations")
    func restoredStateSurvivesReload() async throws {
        let op = UUID()
        let record = try trashed(name: "a.bin", op: op)
        let session = try await loadedSession(records: [record])
        #expect(await session.restore(itemPath: record.itemPath, operationID: op) == nil)

        // A new session (as after relaunching the app) still knows the item was put back.
        let relaunched = ActivitySession(activityLog: ActivityLog(directory: scratch.url))
        await relaunched.load()

        #expect(relaunched.isRestored(itemPath: record.itemPath, operationID: op))
        let records = try await ActivityLog(directory: scratch.url).readAll().records
        #expect(records.contains { $0.outcome == .restored && $0.operationID == op })
    }

    // MARK: - Log corruption

    @Test("corrupted log lines are counted and surfaced; intact records still load")
    func corruptedLinesAreCounted() async throws {
        let log = ActivityLog(directory: scratch.url)
        try await log.append(record(op: UUID(), path: "/a"))
        // 1_800_000_000 is 2027-01-15 UTC, so both records live in the 2027-01 file.
        let handle = try FileHandle(forWritingTo: scratch.url.appending(path: "activity-2027-01.jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try await log.append(record(op: UUID(), path: "/b"))

        let session = ActivitySession(activityLog: log)
        await session.load()

        #expect(session.skippedLineCount == 1)
        #expect(session.operations.count == 2)
    }
}
