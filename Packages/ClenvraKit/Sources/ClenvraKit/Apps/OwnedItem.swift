public import Foundation

/// Why Clenvra believes an item belongs to an app; shown next to the item so the user can judge it.
public enum Evidence: Sendable, Hashable {
    /// The item is named exactly after the app's (or an embedded component's) bundle identifier.
    case exactBundleIdentifierPath(String)
    /// The sandbox container's own metadata names this identifier (folder names are not trusted).
    case containerMetadata(String)
    /// A launch item declares this identifier in `AssociatedBundleIdentifiers`.
    case associatedBundleIdentifier(String)
    /// A launch item runs this program, which lives inside the app's bundle.
    case programInsideBundle(String)
    /// The app's signature lists this shared group container.
    case applicationGroup(String)
    /// An installer package with this identifier placed the item.
    case receipt(String)
    /// The folder is named exactly like the app.
    case exactName(String)
    /// The name contains the app's name as a whole word; a guess, never acted on by default.
    case nameMatch(String)
    /// An app with this name, whose identifier the item shares lineage with, is in the Trash.
    case appInTrash(String)
}

/// One file or folder an app owns outside its bundle, with how sure Clenvra is and why.
public struct OwnedItem: Sendable, Hashable, Identifiable {
    /// Where the item lives, so the review can group and explain it.
    public enum Kind: Sendable, Hashable {
        case caches, applicationSupport, httpStorage, webKit, logs, applicationScripts
        case preferences, savedState, cookies, container, groupContainer, launchAgent
        /// Outside the home folder (installer receipts, system launch items); needs an administrator.
        case systemFile
    }

    /// How certain the ownership is; drives default selection (`safety-model.md` §5).
    public enum Confidence: Int, Sendable, Hashable, Comparable, CaseIterable {
        case certain, likely, possible

        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What Clenvra may do with the item in this version.
    public enum Handling: Sendable, Hashable {
        /// Can be moved to the Trash through the deletion gate.
        case removable
        /// Only shown in Finder: it needs administrator rights, which this version never uses.
        case revealOnly
    }

    public var id: String { path }
    /// Canonical absolute path.
    public let path: String
    /// The Library folder the item lives in; the deletion gate only acts strictly below it.
    public let ruleRoot: String
    public let kind: Kind
    /// The item as reviewed; the deletion gate refuses if it changes.
    public let snapshot: FileSnapshot
    /// Bytes allocated on disk.
    public let allocatedSize: Int64
    /// Bytes deleting it would actually free (clone- and hard-link-aware).
    public let reclaimableSize: Int64
    /// Newest modification inside the item, when known.
    public let modificationDate: Date?
    public let confidence: Confidence
    public let evidence: [Evidence]
    /// `InstalledApp.id`s of other installed apps that may also use this item.
    public let sharedWith: [String]
    public let handling: Handling
    /// A folder holding a protected file (a key, a keychain…); the deletion gate will refuse it, so it is never
    /// pre-selected and the review warns about it.
    public let containsProtectedItem: Bool
    /// Certain items, and Likely ones when ownership is proven exclusive, start selected; never shared ones.
    public let isSelectedByDefault: Bool

    /// File or folder name, for display.
    public var name: String { (path as NSString).lastPathComponent }

    /// What the deletion gate needs to move this item; `owner` is checked for "is it running" at deletion time.
    public func deletionItem(owner: String?, section: ActivityRecord.Section) -> DeletionItem {
        DeletionItem(
            path: path, ruleRoot: ruleRoot, expected: snapshot, ownerBundleID: owner, freedBytes: reclaimableSize,
            section: section)
    }
}
