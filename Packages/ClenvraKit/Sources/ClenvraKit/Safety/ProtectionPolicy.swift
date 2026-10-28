import Foundation

/// Why a location can never be deleted by Clenvra.
public enum ProtectionReason: Sendable, Equatable, Codable {
    /// macOS itself or a root folder whose removal would break the system.
    case system
    /// The home folder, a folder macOS puts in it (Documents, Library…), or a top-level folder of ~/Library.
    case homeRoot
    /// Keys, certificates, keychains and credential files.
    case secret
    /// Mail, Messages, iCloud Drive, cloud storage, Photos libraries.
    case userData
    /// Protected by another component (e.g. managed or security software, apps' own data).
    case custom
    /// The user excluded this folder.
    case excluded
    /// The path is malformed; anything we cannot reason about is protected.
    case invalid
}

/// Path-level protection rules, applied at scan time and again immediately before deletion.
///
/// Comparison is case-insensitive and Unicode-normalisation-insensitive, matching APFS defaults, so `/SYSTEM` or a
/// decomposed "é" cannot bypass a rule. A location is also protected when it *contains* a protected location
/// (deleting `~/Library/Caches/keep` would delete a protected `…/keep/me`).
public struct ProtectionPolicy: Sendable {
    private enum Scope: Sendable {
        /// The location and everything inside it.
        case tree
        /// The location itself only.
        case exact
    }

    private struct Rule: Sendable {
        let components: [String]
        let scope: Scope
        let reason: ProtectionReason
    }

    private static let systemTrees = [
        "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/private/var/root", "/Library/Apple",
        "/Library/Keychains", "/Library/Extensions", "/Library/Managed Preferences",
    ]
    private static let systemRoots = [
        "/", "/Applications", "/Applications/Utilities", "/Library", "/Library/Caches", "/Library/Application Support",
        "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Logs",
        "/Library/Preferences", "/Users", "/Users/Shared", "/Volumes", "/private", "/private/var", "/private/tmp",
        "/private/var/folders", "/private/var/log", "/opt", "/opt/homebrew", "/usr/local",
    ]
    /// Relative to the home folder.
    private static let secretHomeTrees = [".ssh", ".gnupg", ".aws", ".kube", ".docker", "Library/Keychains"]
    private static let userDataHomeTrees = [
        "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/CloudStorage",
    ]
    /// Exact lower-cased file names that hold credentials.
    private static let secretNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "id_rsa.pub", "id_dsa.pub", "id_ecdsa.pub", "id_ed25519.pub",
        ".env", ".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials",
    ]
    private static let secretExtensions: Set<String> = ["pem", "p12", "pfx", "keychain", "keychain-db"]
    private static let userDataExtensions: Set<String> = ["photoslibrary"]

    private let homeComponents: [String]
    private let rules: [Rule]

    /// - Parameters:
    ///   - home: canonical path of the user's home folder.
    ///   - additionalProtected: trees protected by other components (managed software, app data under review).
    ///   - exclusions: trees the user excluded.
    public init(home: String, additionalProtected: [String] = [], exclusions: [String] = []) {
        let homeComponents = Self.folded(home) ?? []
        func rules(_ paths: [String], _ scope: Scope, _ reason: ProtectionReason) -> [Rule] {
            paths.compactMap { Self.folded($0) }.map { Rule(components: $0, scope: scope, reason: reason) }
        }
        func homeRules(_ relatives: [String], _ reason: ProtectionReason) -> [Rule] {
            relatives.map { relative in
                let parts = relative.split(separator: "/").map { Self.fold(String($0)) }
                return Rule(components: homeComponents + parts, scope: .tree, reason: reason)
            }
        }
        self.homeComponents = homeComponents
        self.rules =
            rules(Self.systemTrees, .tree, .system) + rules(Self.systemRoots, .exact, .system)
            + homeRules(Self.secretHomeTrees, .secret) + homeRules(Self.userDataHomeTrees, .userData)
            + rules(additionalProtected, .tree, .custom) + rules(exclusions, .tree, .excluded)
    }

    /// The reason `path` is protected, or `nil` when it may be offered for deletion.
    public func protection(for path: String) -> ProtectionReason? {
        guard let parts = Self.folded(path) else { return .invalid }

        for rule in rules where Self.matches(parts, rule) {
            return rule.reason
        }
        // The most specific reason wins: a secret file directly in home is reported as a secret.
        if let reason = Self.nameReason(parts) { return reason }
        if isHomeRoot(parts) { return .homeRoot }
        // A location that contains a protected location is protected too.
        for rule in rules where rule.components.count > parts.count && rule.components.starts(with: parts) {
            return rule.reason
        }
        return nil
    }

    // MARK: - Private

    private static func matches(_ parts: [String], _ rule: Rule) -> Bool {
        switch rule.scope {
        case .exact: parts == rule.components
        case .tree: parts.starts(with: rule.components)
        }
    }

    /// Home itself, its direct children, and direct children of ~/Library.
    private func isHomeRoot(_ parts: [String]) -> Bool {
        guard parts.starts(with: homeComponents) else { return false }
        let relative = Array(parts.dropFirst(homeComponents.count))
        switch relative.count {
        case 0: return true
        case 1: return Self.standardHomeFolders.contains(relative[0])
        case 2: return relative[0] == "library"
        default: return false
        }
    }

    /// The folders macOS and the shell put in every home folder (case-folded). Folders the person created there
    /// (`~/flutter`, `~/Sources`) are not structural: they may be reviewed and moved to the Trash like anything else.
    /// Secrets inside them (`~/.ssh`, keys, keychains) stay protected by the name rules.
    private static let standardHomeFolders: Set<String> = [
        "applications", "desktop", "documents", "downloads", "library", "movies", "music", "pictures", "public",
        "sites", ".trash", ".config", ".local", ".cache",
    ]

    private static func nameReason(_ parts: [String]) -> ProtectionReason? {
        parts.lazy.compactMap(protection(forFoldedName:)).first
    }

    /// Protection that follows from a single file or folder name, wherever it appears (e.g. `id_ed25519`, `*.pem`).
    public static func protection(forName name: String) -> ProtectionReason? {
        protection(forFoldedName: fold(name))
    }

    private static func protection(forFoldedName name: String) -> ProtectionReason? {
        let ext = (name as NSString).pathExtension
        if userDataExtensions.contains(ext) { return .userData }
        if secretNames.contains(name) || secretExtensions.contains(ext) { return .secret }
        return nil
    }

    private static func folded(_ path: String) -> [String]? {
        guard let parts = try? PathPolicy.components(of: path) else { return nil }
        return parts.map(fold)
    }

    private static func fold(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased()
    }
}
