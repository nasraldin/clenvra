public import Foundation

/// Whether a candidate can be acted on, and if not, why (shown greyed with this reason).
public enum CandidateStatus: Sendable, Hashable {
    case available
    /// The owning app is running (or Clenvra could not tell).
    case inUse
    /// macOS does not let the current user remove it (permissions, data vault, system flags).
    case systemManaged
    case protected(ProtectionReason)
}

/// One item a rule offers for review.
public struct CleanupCandidate: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let ruleID: String
    public let name: String
    public let path: String
    public let ruleRoot: String
    public let kind: FileKind
    public let logicalSize: Int64
    public let allocatedSize: Int64
    /// What deleting it would actually free (clone- and hard-link-aware).
    public let reclaimableSize: Int64
    public let modificationDate: Date?
    /// The item as reviewed; the deletion gate refuses if it changes.
    public let snapshot: FileSnapshot
    public let ownerBundleID: String?
    public let status: CandidateStatus
    public let risk: Risk

    /// Display order: what deleting frees, then space used, then path.
    public static func largestFreedFirst(_ lhs: CleanupCandidate, _ rhs: CleanupCandidate) -> Bool {
        if lhs.reclaimableSize != rhs.reclaimableSize { return lhs.reclaimableSize > rhs.reclaimableSize }
        if lhs.allocatedSize != rhs.allocatedSize { return lhs.allocatedSize > rhs.allocatedSize }
        return lhs.path < rhs.path
    }

    /// Only safe, available items start selected.
    public var isSelectedByDefault: Bool { risk == .safe && status == .available }

    public func deletionItem(section: ActivityRecord.Section) -> DeletionItem {
        DeletionItem(
            path: path, ruleRoot: ruleRoot, expected: snapshot, ownerBundleID: ownerBundleID,
            freedBytes: reclaimableSize, section: section)
    }
}

/// Result of running one rule.
public struct RuleScanResult: Sendable {
    public let rule: CleanupRule
    /// False when the root does not exist on this Mac (e.g. the tool is not installed); the UI hides the rule.
    public let rootExists: Bool
    /// Largest first.
    public let candidates: [CleanupCandidate]
    public let skipped: [SkippedPath]
}
