public import Foundation

/// One installed application, with what a user needs to decide whether to remove it and the identifiers later
/// units use to match its leftovers, containers and launch items.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    /// Where the app came from; drives how it should be updated or uninstalled.
    public enum Source: Sendable, Hashable {
        case appStore
        case homebrew(token: String)
        case setapp
        case apple
        case other
    }

    /// Canonical (symlink-free) bundle path, so the same bundle reached two ways is one app.
    public let id: String
    public let url: URL
    /// `nil` when Info.plist has none; such an app is still listed so the user can see and remove it.
    public let bundleIdentifier: String?
    public let name: String
    public let version: String?
    public let build: String?
    public let source: Source
    /// Removing it would break macOS or Clenvra itself, so it is never offered for removal.
    public let isProtected: Bool
    /// Identifiers of extensions, login items, XPC services and helpers inside the bundle; they own data too.
    public let embeddedBundleIdentifiers: [String]
    /// Shared group container identifiers from the code signature; `nil` until requested because it is costly.
    public let applicationGroups: [String]?

    public init(
        id: String,
        url: URL,
        bundleIdentifier: String?,
        name: String,
        version: String?,
        build: String?,
        source: Source,
        isProtected: Bool,
        embeddedBundleIdentifiers: [String],
        applicationGroups: [String]? = nil
    ) {
        self.id = id
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.build = build
        self.source = source
        self.isProtected = isProtected
        self.embeddedBundleIdentifiers = embeddedBundleIdentifiers
        self.applicationGroups = applicationGroups
    }
}
