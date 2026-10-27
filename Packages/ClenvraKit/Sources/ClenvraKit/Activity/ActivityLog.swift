public import Foundation

/// Append-only JSON-lines log of every action Clenvra performs.
public actor ActivityLog {
    public struct ReadResult: Sendable {
        public let records: [ActivityRecord]
        /// Lines that could not be decoded (e.g. truncated by a crash); they are skipped, not fatal.
        public let skippedLineCount: Int
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private static let filePrefix = "activity-"
    private static let fileExtension = "jsonl"

    /// One file per UTC month keeps files small and lets old months be archived or deleted as a unit.
    private func fileURL(for date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month], from: date)
        let name = String(
            format: "%@%04d-%02d.%@", Self.filePrefix, parts.year ?? 0, parts.month ?? 0, Self.fileExtension)
        return directory.appending(path: name)
    }

    public func append(_ record: ActivityRecord) throws {
        var line = try encoder.encode(record)
        line.append(0x0A)
        let url = fileURL(for: record.date)
        let path = url.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func readAll() throws -> ReadResult {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var records: [ActivityRecord] = []
        var skipped = 0
        for name in names where name.hasPrefix(Self.filePrefix) && name.hasSuffix("." + Self.fileExtension) {
            guard
                let data = FileManager.default.contents(
                    atPath: directory.appending(path: name).path(percentEncoded: false))
            else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let record = try? decoder.decode(ActivityRecord.self, from: line) {
                    records.append(record)
                } else {
                    skipped += 1
                }
            }
        }
        records.sort { $0.date < $1.date }
        return ReadResult(records: records, skippedLineCount: skipped)
    }
}
