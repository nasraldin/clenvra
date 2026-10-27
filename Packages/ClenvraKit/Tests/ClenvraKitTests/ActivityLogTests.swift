import Foundation
import Testing

@testable import ClenvraKit

@Suite("ActivityLog")
struct ActivityLogTests {
    private let scratch: TemporaryDirectory
    private var directory: URL { scratch.url }

    init() throws {
        scratch = try TemporaryDirectory()
    }

    private func record(
        _ path: String,
        at date: Date = Date(timeIntervalSince1970: 1_800_000_000),
        outcome: ActivityRecord.Outcome = .movedToTrash(trashPath: "/Users/u/.Trash/x")
    ) -> ActivityRecord {
        ActivityRecord(
            operationID: UUID(),
            date: date,
            section: .cleanup,
            itemPath: path,
            bytes: 1_024,
            outcome: outcome
        )
    }

    @Test("an appended record can be read back")
    func appendThenRead() async throws {
        let log = ActivityLog(directory: directory)
        let written = record("/Users/u/Library/Caches/com.example")

        try await log.append(written)
        let result = try await log.readAll()

        #expect(result.records == [written])
        #expect(result.skippedLineCount == 0)
    }

    @Test("a truncated line is skipped and counted, other records survive")
    func corruptLineIsSkipped() async throws {
        let log = ActivityLog(directory: directory)
        let first = record("/a")
        let second = record("/b")
        try await log.append(first)
        // 1_800_000_000 is 2027-01-15 UTC, so the record lives in the 2027-01 file.
        let handle = try FileHandle(forWritingTo: directory.appending(path: "activity-2027-01.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"operationID":"trunc"#.utf8 + [0x0A]))
        try handle.close()
        try await log.append(second)

        let result = try await log.readAll()

        #expect(result.records == [first, second])
        #expect(result.skippedLineCount == 1)
    }

    @Test("records are stored in one file per UTC month and read back in date order")
    func monthlyFiles() async throws {
        let log = ActivityLog(directory: directory)
        let november = record("/nov", at: Date(timeIntervalSince1970: 1_793_491_200))  // 2026-11-01T00:00:00Z
        let october = record("/oct", at: Date(timeIntervalSince1970: 1_793_491_199))  // 2026-10-31T23:59:59Z
        try await log.append(november)
        try await log.append(october)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
        let result = try await log.readAll()

        #expect(files == ["activity-2026-10.jsonl", "activity-2026-11.jsonl"])
        #expect(result.records.map(\.itemPath) == ["/oct", "/nov"])
    }

    @Test("reading an empty directory returns no records")
    func emptyLog() async throws {
        let result = try await ActivityLog(directory: directory.appending(path: "missing")).readAll()
        #expect(result.records.isEmpty)
        #expect(result.skippedLineCount == 0)
    }
}
