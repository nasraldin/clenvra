public import Foundation

/// A user-facing explanation of why an item could not be put back; the session maps every
/// `RestoreError` to one so views never need to interpret filesystem errors.
public enum RestoreReason: Sendable, Equatable, Hashable, CaseIterable {
    /// The log entry is not a move to the Trash with a known identity.
    case notRestorable
    /// The Trash no longer holds the object Clenvra moved.
    case notInTrash
    /// The folder the item came from is gone.
    case originalFolderMissing
    /// Something new now occupies the original path; it is never overwritten.
    case originalPathOccupied
    /// The move back failed for a filesystem reason.
    case restoreFailed

    init(_ error: RestoreError) {
        switch error {
        case .notRestorable: self = .notRestorable
        case .notInTrash: self = .notInTrash
        case .originalFolderMissing: self = .originalFolderMissing
        case .originalPathOccupied: self = .originalPathOccupied
        case .failed: self = .restoreFailed
        }
    }
}

@Observable
@MainActor
/// Everything the activity log says, in a shape the Activity section can display: log records
/// grouped into operations, newest first, with one final-outcome row per item, plus Put Back
/// for items still in the Trash and CSV or Markdown export of the current view.
public final class ActivitySession {
    /// One item of an operation, showing the outcome that actually happened (never the intent record).
    public struct Item: Sendable, Equatable, Identifiable {
        public let record: ActivityRecord
        /// The path that was acted on.
        public var path: String { record.itemPath }
        public var bytes: Int64 { record.bytes }
        public var outcome: ActivityRecord.Outcome { record.outcome }
        /// Paths are unique per operation: rows come from one final record per path.
        public var id: String { record.itemPath }
    }

    /// One run of Clenvra, identified by its operation ID, with counts per outcome and bytes freed.
    public struct Operation: Sendable, Equatable, Identifiable {
        public let id: UUID
        /// The time of the last record written by this run.
        public let date: Date
        public let section: ActivityRecord.Section
        public let items: [Item]
        public let movedCount: Int
        public let removedCount: Int
        public let wouldDeleteCount: Int
        /// Skipped items, including anomalies and items not attempted because the run was stopped.
        public let skippedCount: Int
        public let failedCount: Int
        /// Bytes freed by items actually moved to the Trash or removed permanently. Intent records are ignored.
        public let freedBytes: Int64

        /// Rows come from one final record per path, so paths identify the items within one run.
    }

    public private(set) var operations: [Operation] = []
    /// Log lines that could not be decoded (e.g. a crash truncated the file); they are skipped, not lost silently.
    public private(set) var skippedLineCount = 0

    /// Path the user is searching for; matched case-insensitively against item paths.
    public var searchText = ""
    /// Show only this section; `nil` shows every section.
    public var sectionFilter: ActivityRecord.Section?

    /// The operations that survive the current section filter and path search, newest first.
    /// Searching narrows each operation to its matching items.
    public var visibleOperations: [Operation] {
        let query = searchText
        var result: [Operation] = []
        for operation in operations {
            if let filter = sectionFilter, operation.section != filter { continue }
            guard !query.isEmpty else {
                result.append(operation)
                continue
            }
            let items = operation.items.filter { $0.path.localizedCaseInsensitiveContains(query) }
            guard !items.isEmpty else { continue }
            result.append(
                Self.operation(id: operation.id, date: operation.date, section: operation.section, items: items))
        }
        return result
    }

    private let activityLog: ActivityLog
    private let reenabler: LaunchAgentReenabler?
    /// Items put back from the Trash, keyed by operation ID and path; rebuilt from `.restored` log records.
    private var restoredKeys: Set<String> = []
    /// Startup items loaded again after Put Back during this run, keyed like `restoredKeys`.
    private var reenabledKeys: Set<String> = []
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.gmt
        return formatter
    }()

    /// - Parameter reenabler: offers loading a put-back startup agent again; `nil` never offers it.
    public init(activityLog: ActivityLog, reenabler: LaunchAgentReenabler? = nil) {
        self.activityLog = activityLog
        self.reenabler = reenabler
    }

    /// Loads every record the log holds and rebuilds the operations. A read failure leaves the
    /// session empty rather than showing partial data.
    public func load() async {
        do {
            let result = try await activityLog.readAll()
            restoredKeys = Set(
                result.records.filter { $0.outcome == .restored }.map {
                    Self.restoredKey(itemPath: $0.itemPath, operationID: $0.operationID)
                })
            operations = Self.operations(from: result.records.filter { $0.outcome != .restored })
            skippedLineCount = result.skippedLineCount
        } catch {
            operations = []
            skippedLineCount = 0
        }
    }

    /// Whether the item was put back from the Trash.
    public func isRestored(itemPath: String, operationID: UUID) -> Bool {
        restoredKeys.contains(Self.restoredKey(itemPath: itemPath, operationID: operationID))
    }

    /// Puts the item back where it was, using the recorded identity to verify the Trash still holds it.
    /// Returns `nil` on success, otherwise the user-facing reason.
    @discardableResult
    public func restore(itemPath: String, operationID: UUID) async -> RestoreReason? {
        guard
            let operation = operations.first(where: { $0.id == operationID }),
            let item = operation.items.first(where: { $0.path == itemPath })
        else { return .notRestorable }
        do {
            try RestoreService.restore(item.record)
            restoredKeys.insert(Self.restoredKey(itemPath: itemPath, operationID: operationID))
            try? await activityLog.append(
                ActivityRecord(
                    operationID: operationID, date: Date(), section: item.record.section, itemPath: itemPath,
                    bytes: item.record.bytes, outcome: .restored, identity: item.record.identity))
            return nil
        } catch {
            return RestoreReason(error)
        }
    }

    // MARK: - Re-enabling startup items

    /// Whether the item is a startup agent that was put back and can now be loaded again (SB-3).
    public func canReenable(itemPath: String, operationID: UUID) -> Bool {
        guard let reenabler, let item = item(itemPath: itemPath, operationID: operationID),
            isRestored(itemPath: itemPath, operationID: operationID),
            !isReenabled(itemPath: itemPath, operationID: operationID)
        else { return false }
        return reenabler.canReenable(item.record)
    }

    /// Whether the startup agent was loaded again after Put Back during this run.
    public func isReenabled(itemPath: String, operationID: UUID) -> Bool {
        reenabledKeys.contains(Self.restoredKey(itemPath: itemPath, operationID: operationID))
    }

    /// Loads a put-back startup agent again with `launchctl bootstrap`; refused until the item was put back.
    @discardableResult
    public func reenable(itemPath: String, operationID: UUID) async -> LaunchAgentReenabler.Outcome {
        guard let reenabler, let item = item(itemPath: itemPath, operationID: operationID),
            isRestored(itemPath: itemPath, operationID: operationID)
        else { return .notAllowed }
        let outcome = await reenabler.reenable(item.record)
        if outcome == .enabled || outcome == .alreadyEnabled {
            reenabledKeys.insert(Self.restoredKey(itemPath: itemPath, operationID: operationID))
        }
        return outcome
    }

    private func item(itemPath: String, operationID: UUID) -> Item? {
        operations.first { $0.id == operationID }?.items.first { $0.path == itemPath }
    }

    /// The currently visible view as CSV (RFC 4180 quoting, CRLF line endings, ISO-8601 UTC dates),
    /// so the user can keep exactly what they see in the Activity list.
    public func exportCSV() -> String {
        var lines = ["date,section,path,outcome,bytes"]
        for operation in visibleOperations {
            for item in operation.items {
                let fields = [
                    Self.iso8601.string(from: item.record.date),
                    item.record.section.rawValue,
                    item.record.itemPath,
                    Self.token(for: item.outcome),
                    String(item.record.bytes),
                ]
                lines.append(fields.map(Self.field).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The currently visible view as a Markdown report (period, totals, one row per item, ISO-8601 UTC dates),
    /// readable by people where the CSV is for spreadsheets. Items put back count as put back, not as freed.
    public func exportMarkdown() -> String {
        let rows = visibleOperations.flatMap { operation in
            operation.items.map { item in
                (item: item, restored: isRestored(itemPath: item.path, operationID: operation.id))
            }
        }
        var lines = ["# Clenvra Activity Report", ""]
        let dates = rows.map(\.item.record.date)
        guard let first = dates.min(), let last = dates.max() else {
            lines.append("No activity.")
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("Period: \(Self.iso8601.string(from: first)) – \(Self.iso8601.string(from: last))")

        var moved = 0
        var removed = 0
        var putBack = 0
        var wouldDelete = 0
        var skipped = 0
        var failed = 0
        var freed: Int64 = 0
        for row in rows {
            if row.restored {
                putBack += 1
                continue
            }
            switch row.item.outcome {
            case .intent, .restored: break
            case .movedToTrash:
                moved += 1
                freed += row.item.bytes
            case .removedPermanently:
                removed += 1
                freed += row.item.bytes
            case .wouldDelete: wouldDelete += 1
            case .skipped, .anomaly, .notAttempted: skipped += 1
            case .failed: failed += 1
            }
        }
        lines += [
            "", "## Totals", "",
            "- Moved to Trash: \(moved)",
            "- Removed permanently: \(removed)",
            "- Put back: \(putBack)",
            "- Would delete (dry run): \(wouldDelete)",
            "- Skipped: \(skipped)",
            "- Failed: \(failed)",
            "- Bytes freed: \(freed)",
            "", "## Items", "",
            "| Date | Section | Path | Bytes | Outcome |",
            "| --- | --- | --- | ---: | --- |",
        ]
        for row in rows {
            let record = row.item.record
            let cells = [
                Self.iso8601.string(from: record.date),
                record.section.rawValue,
                Self.markdownCell(record.itemPath),
                String(record.bytes),
                Self.token(for: row.restored ? .restored : record.outcome),
            ]
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Grouping

    /// Groups records into operations, keeps only the final outcome per item and orders operations
    /// newest first. Intent records never appear: every item has an outcome record that follows it.
    private static func operations(from records: [ActivityRecord]) -> [Operation] {
        var result: [Operation] = []
        for (id, group) in Dictionary(grouping: records, by: \.operationID) {
            var finalByPath: [String: ActivityRecord] = [:]
            for record in group where record.outcome != .intent {
                if let existing = finalByPath[record.itemPath], existing.date > record.date { continue }
                finalByPath[record.itemPath] = record
            }
            let items = finalByPath.values.map(Item.init).sorted { $0.path < $1.path }
            let date = group.map(\.date).max() ?? Date(timeIntervalSince1970: 0)
            let section = group[0].section
            result.append(operation(id: id, date: date, section: section, items: items))
        }
        return
            result
            .sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }
    }

    private static func operation(
        id: UUID, date: Date, section: ActivityRecord.Section, items: [Item]
    ) -> Operation {
        var moved = 0
        var removed = 0
        var wouldDelete = 0
        var skipped = 0
        var failed = 0
        var freed: Int64 = 0
        for item in items {
            switch item.outcome {
            case .intent, .restored:
                break
            case .movedToTrash:
                moved += 1
                freed += item.bytes
            case .removedPermanently:
                removed += 1
                freed += item.bytes
            case .wouldDelete:
                wouldDelete += 1
            case .skipped, .anomaly, .notAttempted:
                skipped += 1
            case .failed:
                failed += 1
            }
        }
        return Operation(
            id: id, date: date, section: section, items: items, movedCount: moved, removedCount: removed,
            wouldDeleteCount: wouldDelete, skippedCount: skipped, failedCount: failed, freedBytes: freed)
    }

    private static func restoredKey(itemPath: String, operationID: UUID) -> String {
        operationID.uuidString + "|" + itemPath
    }

    // MARK: - CSV

    /// A stable machine token for the outcome; raw values live longer than any UI wording.
    private static func token(for outcome: ActivityRecord.Outcome) -> String {
        switch outcome {
        case .intent: "intent"
        case .restored: "restored"
        case .movedToTrash: "movedToTrash"
        case .removedPermanently: "removedPermanently"
        case .wouldDelete: "wouldDelete"
        case .skipped: "skipped"
        case .failed: "failed"
        case .anomaly: "anomaly"
        case .notAttempted: "notAttempted"
        }
    }

    /// Keeps a path inside one table cell, shown literally: backslashes and pipes are escaped, HTML-significant
    /// characters become entities, and line breaks become `<br>`.
    private static func markdownCell(_ value: String) -> String {
        var cell = ""
        var previousWasCR = false
        for scalar in value.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            switch scalar {
            case "\\": cell += "\\\\"
            case "|": cell += "\\|"
            case "&": cell += "&amp;"
            case "<": cell += "&lt;"
            case ">": cell += "&gt;"
            case "\r": cell += "<br>"
            case "\n": if !previousWasCR { cell += "<br>" }
            default: cell.unicodeScalars.append(scalar)
            }
        }
        return cell
    }

    /// RFC 4180: fields containing a comma, quote or line break are quoted, with embedded quotes doubled.
    private static func field(_ value: String) -> String {
        let requiresQuote = value.contains {
            $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r"
        }
        guard requiresQuote else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Lets the Activity picker list every section the log can hold, in declaration order.
extension ActivityRecord.Section: CaseIterable {
    public static var allCases: [Self] {
        [.overview, .storage, .cleanup, .developer, .applications, .startup, .system]
    }
}
