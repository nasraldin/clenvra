public import Foundation

/// How much review an item needs before it is removed.
public enum Risk: Sendable, Hashable, Codable {
    /// Regenerated automatically, no user content: pre-selected.
    case safe
    /// Recoverable but costs something (re-download, sign-in, slower build) or may hold user content: opt-in.
    case review
}

/// User-facing grouping of rules; drives section and sidebar grouping in the UI.
public enum CleanupCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case appCaches, logs, crashReports, installers, deviceBackups, trash, browserCaches
    case xcode, simulators, packageCaches, projectArtifacts, ideCaches, containers
}

/// Where a rule looks. Home-relative roots make rules portable across Macs and user names.
public enum RuleRoot: Sendable, Hashable {
    case home(String)
    case absolute(String)

    public func path(home: String) -> String {
        switch self {
        case .home(let relative): relative.isEmpty ? home : home + "/" + relative
        case .absolute(let path): path
        }
    }
}

/// A minimum age, so recently used items are left alone.
public struct Age: Sendable, Hashable {
    public let seconds: TimeInterval

    public static func days(_ days: Int) -> Age { Age(seconds: TimeInterval(days) * 86_400) }
}

/// What inside the root is offered.
public enum Selection: Sendable, Hashable {
    /// Each direct child of the root is one item (e.g. one cache folder per app), except names that more
    /// specific rules own.
    case children(excluding: Set<String> = [])
    /// Only the listed direct children (e.g. an editor's cache folders, never its settings).
    case named(Set<String>)
    /// Files anywhere below the root (up to `maximumDepth` folders deep) with one of the extensions,
    /// not modified for at least `minimumAge`.
    case files(extensions: Set<String>, minimumAge: Age?, maximumDepth: Int)
    /// Build-output folders inside code projects (up to `maximumDepth` folders deep). A folder is offered only when
    /// one of its kind's marker files sits next to it; projects active within `inactivity` are offered for review only.
    case projectArtifacts([ArtifactKind], inactivity: Age, maximumDepth: Int)
}

/// A regenerable project folder and the files that prove it belongs to a project (e.g. node_modules ← package.json).
public struct ArtifactKind: Sendable, Hashable {
    public let folder: String
    public let markers: Set<String>

    public init(folder: String, markers: Set<String>) {
        self.folder = folder
        self.markers = markers
    }
}

public enum CleanupAction: Sendable, Hashable {
    case moveToTrash
    /// Shown for information; the user acts in Finder (e.g. items that need an administrator).
    case revealOnly
}

/// How to tell which app owns an item, for the "app is running" check.
public enum OwnershipHint: Sendable, Hashable {
    case none
    /// The item's name is the owner's bundle identifier (e.g. `~/Library/Caches/com.vendor.app`).
    case bundleIdentifierFromName
    case fixed(String)
}

/// One cleanup category as data. All categories run through the same scanner, gate and review UI.
public struct CleanupRule: Sendable, Hashable, Identifiable {
    public let id: String
    public let category: CleanupCategory
    public let root: RuleRoot
    public let selection: Selection
    public let risk: Risk
    public let action: CleanupAction
    public let ownership: OwnershipHint

    public init(
        id: String, category: CleanupCategory, root: RuleRoot, selection: Selection, risk: Risk,
        action: CleanupAction, ownership: OwnershipHint
    ) {
        self.id = id
        self.category = category
        self.root = root
        self.selection = selection
        self.risk = risk
        self.action = action
        self.ownership = ownership
    }
}
