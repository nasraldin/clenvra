public import Foundation

/// Outcome of asking the helper to delete a local Time Machine snapshot.
public enum SnapshotDeletion: String, Codable, Sendable {
    case deleted
    /// The date was not a snapshot date.
    case invalid
    /// No snapshot with that date exists (any more).
    case notFound
    case failed
}

/// Local Time Machine snapshots (SY-4). Listing needs no privileges; deleting goes through the helper.
public enum LocalSnapshots {
    /// Snapshot dates look like `2026-10-27-093012`.
    public static func isValidDate(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, [4, 2, 2, 6] == parts.map(\.count) else { return false }
        return parts.allSatisfy { $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    /// The dates in `tmutil listlocalsnapshotdates` output; headers and anything else are ignored.
    public static func dates(fromListOutput output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter(isValidDate)
    }

    /// When the snapshot was taken, for display.
    public static func date(of snapshot: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: snapshot)
    }
}
