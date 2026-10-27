import Foundation

/// One extension or plug-in that adds code to macOS or to other apps, so users can see what is loaded and remove
/// what they installed themselves.
public struct PluginItem: Sendable, Hashable, Identifiable {
    /// What the item extends; also the order in which groups are shown.
    public enum Kind: Sendable, Hashable, CaseIterable {
        /// `.prefPane` bundles shown in System Settings.
        case preferencePane
        /// `.qlgenerator` bundles (legacy Quick Look previews and thumbnails).
        case quickLook
        /// `.mdimporter` bundles feeding Spotlight.
        case spotlightImporter
        /// Audio Unit `.component` bundles.
        case audioUnit
        /// VST 2 plug-ins.
        case vstPlugIn
        /// VST 3 plug-ins.
        case vst3PlugIn
        /// Audio HAL drivers (virtual audio devices).
        case halPlugIn
        /// MOTU Audio System plug-ins.
        case masPlugIn
        /// Legacy browser plug-ins in `Internet Plug-Ins`.
        case internetPlugIn
        /// App extensions registered with PlugInKit (Safari, Finder, Share, Quick Look, widgets…).
        case appExtension
        /// System extensions (network, endpoint security, drivers) managed by macOS.
        case systemExtension
    }

    /// Where the item lives, which decides who may remove it.
    public enum Domain: Sendable, Hashable {
        /// The user's own `~/Library`.
        case user
        /// `/Library` or macOS itself; root-owned and shared by every user.
        case system
        /// Inside an app bundle; it goes away with the app.
        case appBundle
    }

    /// What Clenvra may do with the item.
    public enum Handling: Sendable, Hashable {
        /// The user's own bundle in a known plug-in folder; it can be moved to the Trash through the deletion gate.
        case removable
        /// Shown and revealed in Finder only (system domain, app and system extensions, links, Apple items).
        case revealOnly
        /// Belongs to security, VPN or management software; never acted on ("Managed by your organisation").
        case managed
    }

    /// The bundle path when there is one; otherwise a stable key built from the identifier.
    public let id: String
    public let name: String
    public let kind: Kind
    /// `nil` for system extensions, whose location `systemextensionsctl` does not report.
    public let path: String?
    public let bundleIdentifier: String?
    public let version: String?
    public let domain: Domain
    /// The app bundle the item ships in, when known.
    public let containingApp: String?
    /// `nil` when macOS does not report it (file-based plug-ins, extensions without a user choice).
    public let isEnabled: Bool?
    public let handling: Handling
    /// Part of macOS or an Apple app; hidden by default and never removable.
    public let isApple: Bool
    /// App extensions: the PlugInKit extension point (e.g. `com.apple.Safari.content-blocker`). System extensions:
    /// the category (e.g. `com.apple.system_extension.network_extension`).
    public let extensionPoint: String?
    /// Signing team, when known (system extensions report it).
    public let teamIdentifier: String?
    /// System extensions: the raw state reported by macOS (e.g. `activated enabled`).
    public let state: String?
    /// Allocated bytes of a file-based bundle; `nil` when not measured.
    public let size: Int64?
    /// The folder a removable item lives in; the deletion gate only allows removal strictly inside it.
    public let ruleRoot: String?
    /// The item as scanned; the deletion gate refuses if it changes before removal.
    public let snapshot: FileSnapshot?

    /// Memberwise, so readers and tests can build items.
    public init(
        id: String? = nil, name: String, kind: Kind, path: String?, bundleIdentifier: String?, version: String?,
        domain: Domain, containingApp: String? = nil, isEnabled: Bool? = nil, handling: Handling,
        isApple: Bool = false, extensionPoint: String? = nil, teamIdentifier: String? = nil, state: String? = nil,
        size: Int64? = nil, ruleRoot: String? = nil, snapshot: FileSnapshot? = nil
    ) {
        self.id = id ?? path ?? "\(kind):\(teamIdentifier ?? "-"):\(bundleIdentifier ?? name):\(version ?? "")"
        self.name = name
        self.kind = kind
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.domain = domain
        self.containingApp = containingApp
        self.isEnabled = isEnabled
        self.handling = handling
        self.isApple = isApple
        self.extensionPoint = extensionPoint
        self.teamIdentifier = teamIdentifier
        self.state = state
        self.size = size
        self.ruleRoot = ruleRoot
        self.snapshot = snapshot
    }

    /// The gate-checked deletion request for a removable item; `nil` for anything that must not be removed.
    public func deletionItem() -> DeletionItem? {
        guard handling == .removable, let path, let ruleRoot, let snapshot else { return nil }
        return DeletionItem(
            path: path, ruleRoot: ruleRoot, expected: snapshot, ownerBundleID: nil, freedBytes: size ?? 0,
            section: .applications)
    }
}
