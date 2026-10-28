import Darwin
import Foundation

/// A browser whose explicitly reviewed history, cookie, session and site-data stores can be cleaned.
public enum Browser: String, Sendable, Hashable, Codable, CaseIterable {
    case safari, chrome, edge, brave, arc, vivaldi, opera, firefox, zen

    /// The name shown beside a browser's data groups.
    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .firefox: "Firefox"
        case .zen: "Zen"
        }
    }

    /// The owner identity used both while scanning and immediately before every Trash operation.
    public var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .arc: "company.thebrowser.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .firefox: "org.mozilla.firefox"
        case .zen: "app.zen-browser.zen"
        }
    }

    fileprivate var supportFolder: String? {
        switch self {
        case .safari: nil
        case .chrome: "Library/Application Support/Google/Chrome"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .arc: "Library/Application Support/Arc/User Data"
        case .vivaldi: "Library/Application Support/Vivaldi"
        case .opera: "Library/Application Support/com.operasoftware.Opera"
        case .firefox: "Library/Application Support/Firefox"
        case .zen: "Library/Application Support/zen"
        }
    }
}

/// The four independently opt-in kinds of browser data.
public enum BrowserDataType: String, Sendable, Hashable, Codable, CaseIterable {
    case history, cookies, sessions, siteData

    /// The consequence that must be visible before a user selects this kind of data.
    public var warning: String {
        switch self {
        case .history:
            "Removes browsing history. Firefox and Zen also keep bookmarks in the history database."
        case .cookies:
            "Removes cookies and signs you out of websites."
        case .sessions:
            "Removes saved windows and tabs; open tabs cannot be restored."
        case .siteData:
            "Removes local site data and may reset website settings or sign you out."
        }
    }

    /// The short label for a review-group heading.
    public var displayName: String {
        switch self {
        case .history: "History"
        case .cookies: "Cookies"
        case .sessions: "Sessions and tabs"
        case .siteData: "Site data / local storage"
        }
    }
}

/// Whether a location is relative to a discovered profile or is one of Safari's fixed data roots.
public enum BrowserDataRoot: Sendable, Hashable {
    case profile
    case home(String)
}

/// One allowlisted set of exact paths; no password, preference, extension or autofill store is represented here.
public struct BrowserDataLocation: Sendable, Hashable, Identifiable {
    public let browser: Browser
    public let dataType: BrowserDataType
    public let root: BrowserDataRoot
    /// Paths are relative to `root`, and each path is the complete name of a file or folder.
    public let relativePaths: [String]
    public let warning: String
    /// True for Gecko's combined `places.sqlite`, whose history and bookmarks cannot be separated by file deletion.
    public let removesBookmarks: Bool

    public var id: String { "\(browser.rawValue).\(dataType.rawValue).\(rootIdentifier)" }

    private var rootIdentifier: String {
        switch root {
        case .profile: "profile"
        case .home(let relative): relative
        }
    }

    fileprivate init(
        browser: Browser, dataType: BrowserDataType, root: BrowserDataRoot, relativePaths: [String],
        warning: String? = nil, removesBookmarks: Bool = false
    ) {
        self.browser = browser
        self.dataType = dataType
        self.root = root
        self.relativePaths = relativePaths
        self.warning = warning ?? dataType.warning
        self.removesBookmarks = removesBookmarks
    }
}

/// The reviewed browser-data table consumed by the single scanner and deletion workflow.
public enum BrowserDataCatalog {
    private static let chromiumBrowsers: [Browser] = [.chrome, .edge, .brave, .arc, .vivaldi, .opera]
    private static let geckoBrowsers: [Browser] = [.firefox, .zen]

    private static let chromiumHistory = ["History", "History-wal", "History-shm", "History-journal"]
    private static let chromiumCookies = [
        "Cookies", "Cookies-wal", "Cookies-shm", "Cookies-journal",
        "Network/Cookies", "Network/Cookies-wal", "Network/Cookies-shm", "Network/Cookies-journal",
    ]
    private static let chromiumSessions = ["Current Session", "Current Tabs", "Last Session", "Last Tabs", "Sessions"]
    private static let chromiumSiteData = ["Local Storage", "IndexedDB", "Session Storage"]

    private static let geckoHistory = [
        "places.sqlite", "places.sqlite-wal", "places.sqlite-shm", "places.sqlite-journal",
    ]
    private static let geckoCookies = [
        "cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm", "cookies.sqlite-journal",
    ]
    private static let geckoSessions = [
        "sessionstore.jsonlz4", "sessionstore.js", "sessionstore.bak", "sessionstore-backups",
    ]
    private static let geckoSiteData = [
        "storage", "webappsstore.sqlite", "webappsstore.sqlite-wal", "webappsstore.sqlite-shm",
    ]

    fileprivate static let safariSupport = "Library/Safari"
    fileprivate static let safariContainerSupport = "Library/Containers/com.apple.Safari/Data/Library/Safari"
    fileprivate static let safariCookies = "Library/Cookies"
    fileprivate static let safariContainerCookies = "Library/Containers/com.apple.Safari/Data/Library/Cookies"

    private static let safariHistory = ["History.db", "History.db-wal", "History.db-shm", "History.db-journal"]
    private static let safariSessions = [
        "LastSession.plist", "RecentlyClosedTabs.plist", "SafariTabs.db", "SafariTabs.db-wal", "SafariTabs.db-shm",
        "SafariTabs.db-journal",
    ]
    private static let safariSiteData = ["LocalStorage", "Databases", "IndexedDB"]

    /// Every row is explicit opt-in review data; there is no safe or pre-selected browser-data rule.
    public static let locations: [BrowserDataLocation] = chromiumRows + geckoRows + safariRows

    /// Returns the rows for one browser without exposing any discovery or deletion special cases to the UI.
    public static func locations(for browser: Browser) -> [BrowserDataLocation] {
        locations.filter { $0.browser == browser }
    }

    private static let chromiumRows: [BrowserDataLocation] = chromiumBrowsers.flatMap { browser in
        [
            BrowserDataLocation(
                browser: browser, dataType: .history, root: .profile, relativePaths: chromiumHistory),
            BrowserDataLocation(
                browser: browser, dataType: .cookies, root: .profile, relativePaths: chromiumCookies),
            BrowserDataLocation(
                browser: browser, dataType: .sessions, root: .profile, relativePaths: chromiumSessions),
            BrowserDataLocation(
                browser: browser, dataType: .siteData, root: .profile, relativePaths: chromiumSiteData),
        ]
    }

    private static let geckoRows: [BrowserDataLocation] = geckoBrowsers.flatMap { browser in
        [
            BrowserDataLocation(
                browser: browser, dataType: .history, root: .profile, relativePaths: geckoHistory,
                warning: "Removes history and bookmarks stored together in places.sqlite.", removesBookmarks: true),
            BrowserDataLocation(
                browser: browser, dataType: .cookies, root: .profile, relativePaths: geckoCookies),
            BrowserDataLocation(
                browser: browser, dataType: .sessions, root: .profile, relativePaths: geckoSessions),
            BrowserDataLocation(
                browser: browser, dataType: .siteData, root: .profile, relativePaths: geckoSiteData),
        ]
    }

    private static let safariRows: [BrowserDataLocation] = [
        BrowserDataLocation(
            browser: .safari, dataType: .history, root: .home(safariSupport), relativePaths: safariHistory),
        BrowserDataLocation(
            browser: .safari, dataType: .history, root: .home(safariContainerSupport), relativePaths: safariHistory),
        BrowserDataLocation(
            browser: .safari, dataType: .cookies, root: .home(safariCookies), relativePaths: ["Cookies.binarycookies"]),
        BrowserDataLocation(
            browser: .safari, dataType: .cookies, root: .home(safariContainerCookies),
            relativePaths: ["Cookies.binarycookies"]),
        BrowserDataLocation(
            browser: .safari, dataType: .sessions, root: .home(safariSupport), relativePaths: safariSessions),
        BrowserDataLocation(
            browser: .safari, dataType: .sessions, root: .home(safariContainerSupport), relativePaths: safariSessions),
        BrowserDataLocation(
            browser: .safari, dataType: .siteData, root: .home(safariSupport), relativePaths: safariSiteData),
        BrowserDataLocation(
            browser: .safari, dataType: .siteData, root: .home(safariContainerSupport), relativePaths: safariSiteData),
    ]
}

/// A discovered profile, retained so the UI can explain exactly which profile a group belongs to.
public struct BrowserDataProfile: Sendable, Hashable, Identifiable {
    public let browser: Browser
    public let path: String
    public let name: String
    /// Safari's protected stores need Full Disk Access; unreadable stores are skipped with a reason.
    public let requiresFullDiskAccess: Bool

    public var id: String { "\(browser.rawValue):\(path)" }

    fileprivate init(browser: Browser, path: String, name: String, requiresFullDiskAccess: Bool) {
        self.browser = browser
        self.path = path
        self.name = name
        self.requiresFullDiskAccess = requiresFullDiskAccess
    }
}

/// One exact file or folder in a browser-data review group, with its scan-time identity for the deletion gate.
public struct BrowserDataItem: Sendable, Hashable, Identifiable {
    public let browser: Browser
    public let profile: BrowserDataProfile
    public let dataType: BrowserDataType
    public let warning: String
    public let removesBookmarks: Bool
    public let candidate: CleanupCandidate

    public var id: String { candidate.id }
    public var path: String { candidate.path }
    public var name: String { candidate.name }
    public var ruleRoot: String { candidate.ruleRoot }
    public var status: CandidateStatus { candidate.status }
    public var risk: Risk { candidate.risk }
    public var ownerBundleID: String? { candidate.ownerBundleID }
    public var groupID: String { "\(profile.id):\(dataType.rawValue)" }

    /// Browser data is always review-only, including empty or otherwise harmless-looking stores.
    public var isSelectedByDefault: Bool { false }

    fileprivate init(
        profile: BrowserDataProfile, location: BrowserDataLocation, candidate: CleanupCandidate
    ) {
        browser = profile.browser
        self.profile = profile
        dataType = location.dataType
        warning = location.warning
        removesBookmarks = location.removesBookmarks
        self.candidate = candidate
    }

    /// Converts the reviewed item without changing its profile containment root or owner check.
    public func deletionItem(section: ActivityRecord.Section = .cleanup) -> DeletionItem {
        candidate.deletionItem(section: section)
    }
}

/// A per-profile, per-data-type review unit; selecting it never implicitly selects another data type.
public struct BrowserDataGroup: Sendable, Hashable, Identifiable {
    public let browser: Browser
    public let profile: BrowserDataProfile
    public let dataType: BrowserDataType
    public let warning: String
    public let removesBookmarks: Bool
    public let items: [BrowserDataItem]

    public var id: String { "\(profile.id):\(dataType.rawValue)" }

    fileprivate init(items: [BrowserDataItem]) {
        let first = items[0]
        browser = first.browser
        profile = first.profile
        dataType = first.dataType
        warning = first.warning
        removesBookmarks = first.removesBookmarks
        self.items = items
    }
}

/// The read-only result of discovering and scanning all supported browser profiles.
public struct BrowserDataScanResult: Sendable {
    public let profiles: [BrowserDataProfile]
    public let groups: [BrowserDataGroup]
    public let skipped: [SkippedPath]
    public var items: [BrowserDataItem] { groups.flatMap(\.items) }

    fileprivate init(profiles: [BrowserDataProfile], groups: [BrowserDataGroup], skipped: [SkippedPath]) {
        self.profiles = profiles
        self.groups = groups
        self.skipped = skipped
    }
}

private enum BrowserProfileStrategy {
    case chromium, firefox, safari
}

private struct DiscoveredProfiles {
    var profiles: [BrowserDataProfile] = []
    var skipped: [SkippedPath] = []
}

private struct DirectoryMeasurement {
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var reclaimable: Int64 = 0
    var protectedReason: ProtectionReason?
    var hasProtectiveFlags = false
    var hasUnsafeContent = false
    var skipped: [SkippedPath] = []
}

/// Discovers profiles and reads only the catalog's exact paths, never a whole profile for cleanup.
public enum BrowserDataScanner {
    /// Scans fixture or real homes read-only; permission and malformed-profile failures become skipped paths.
    @concurrent public static func scan(
        home: String, policy: ProtectionPolicy,
        ownerState: @escaping @Sendable (String) -> OwnerState,
        executor: FSExecutor = .shared
    ) async -> BrowserDataScanResult {
        do {
            return try await executor.run {
                scanSynchronously(home: home, policy: policy, ownerState: ownerState)
            }
        } catch {
            return BrowserDataScanResult(profiles: [], groups: [], skipped: [])
        }
    }

    private static func scanSynchronously(
        home: String, policy: ProtectionPolicy, ownerState: @Sendable (String) -> OwnerState
    ) -> BrowserDataScanResult {
        let home = normalize(home)
        var profiles: [BrowserDataProfile] = []
        var items: [BrowserDataItem] = []
        var skipped: [SkippedPath] = []
        var seenTargets: Set<String> = []

        for browser in Browser.allCases {
            let discovered = discoverProfiles(for: browser, home: home)
            profiles.append(contentsOf: discovered.profiles)
            skipped.append(contentsOf: discovered.skipped)
            for profile in discovered.profiles {
                let scanned = scan(
                    profile, home: home, policy: policy, ownerState: ownerState, seenTargets: &seenTargets)
                items.append(contentsOf: scanned.items)
                skipped.append(contentsOf: scanned.skipped)
            }
        }

        let groups = makeGroups(from: items)
        let uniqueSkipped = Array(Set(skipped)).sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            return String(describing: $0.reason) < String(describing: $1.reason)
        }
        return BrowserDataScanResult(profiles: profiles, groups: groups, skipped: uniqueSkipped)
    }

    // MARK: - Profile discovery

    private static func discoverProfiles(for browser: Browser, home: String) -> DiscoveredProfiles {
        switch strategy(for: browser) {
        case .chromium: discoverChromiumProfiles(for: browser, home: home)
        case .firefox: discoverFirefoxProfiles(for: browser, home: home)
        case .safari: discoverSafariProfiles(home: home)
        }
    }

    private static func strategy(for browser: Browser) -> BrowserProfileStrategy {
        switch browser {
        case .safari: .safari
        case .firefox, .zen: .firefox
        case .chrome, .edge, .brave, .arc, .vivaldi, .opera: .chromium
        }
    }

    private static func discoverChromiumProfiles(for browser: Browser, home: String) -> DiscoveredProfiles {
        guard let supportFolder = browser.supportFolder else { return DiscoveredProfiles() }
        let support = join(home, supportFolder)
        var result = DiscoveredProfiles()
        let listing: DirectoryListing
        switch readListing(at: support) {
        case .success(let found): listing = found
        case .failure(let refusal):
            if !isMissing(refusal) { result.skipped.append(SkippedPath(path: support, reason: skipReason(refusal))) }
            return result
        }
        if listing.unreadableCount > 0 {
            result.skipped.append(SkippedPath(path: support, reason: .unreadableEntries(listing.unreadableCount)))
        }

        var displayNames: [String: String] = [:]
        if let localState = listing.entries.first(where: { $0.name == "Local State" }) {
            if localState.kind == .file {
                do {
                    let data = try readSmallFile(at: join(support, "Local State"))
                    displayNames = chromiumProfileNames(in: data)
                } catch {
                    if error.code != ENOENT {
                        result.skipped.append(
                            SkippedPath(path: join(support, "Local State"), reason: StorageScanner.reason(for: error)))
                    }
                }
            } else if localState.kind == .symlink {
                result.skipped.append(SkippedPath(path: join(support, "Local State"), reason: .changedDuringScan))
            }
        }

        let entries = Dictionary(listing.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var names: Set<String> = Set(displayNames.keys)
        for entry in listing.entries where isChromiumFallbackProfileName(entry.name) {
            names.insert(entry.name)
        }
        for name in names.sorted() {
            guard let entry = entries[name] else { continue }
            let profilePath = join(support, name)
            if entry.kind == .symlink {
                result.skipped.append(SkippedPath(path: profilePath, reason: .changedDuringScan))
                continue
            }
            guard entry.kind == .directory else { continue }
            result.profiles.append(
                BrowserDataProfile(
                    browser: browser, path: profilePath, name: displayNames[name] ?? name,
                    requiresFullDiskAccess: false))
        }
        return result
    }

    private static func chromiumProfileNames(in data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any], let profile = root["profile"] as? [String: Any],
            let cache = profile["info_cache"] as? [String: Any]
        else { return [:] }
        var names: [String: String] = [:]
        for (directory, value) in cache where isPlainComponent(directory) {
            guard let details = value as? [String: Any], let name = details["name"] as? String,
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            names[directory] = name
        }
        return names
    }

    private static func isChromiumFallbackProfileName(_ name: String) -> Bool {
        if name == "Default" { return true }
        guard name.hasPrefix("Profile ") else { return false }
        let number = name.dropFirst("Profile ".count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    private static func discoverFirefoxProfiles(for browser: Browser, home: String) -> DiscoveredProfiles {
        guard let supportFolder = browser.supportFolder else { return DiscoveredProfiles() }
        let support = join(home, supportFolder)
        var result = DiscoveredProfiles()
        let listing: DirectoryListing
        switch readListing(at: support) {
        case .success(let found): listing = found
        case .failure(let refusal):
            if !isMissing(refusal) { result.skipped.append(SkippedPath(path: support, reason: skipReason(refusal))) }
            return result
        }
        if listing.unreadableCount > 0 {
            result.skipped.append(SkippedPath(path: support, reason: .unreadableEntries(listing.unreadableCount)))
        }

        var parsed: [[String: String]] = []
        if let ini = listing.entries.first(where: { $0.name == "profiles.ini" }) {
            if ini.kind == .file {
                do {
                    parsed = parseProfilesINI(try readSmallFile(at: join(support, "profiles.ini")))
                } catch {
                    if error.code != ENOENT {
                        result.skipped.append(
                            SkippedPath(path: join(support, "profiles.ini"), reason: StorageScanner.reason(for: error)))
                    }
                }
            } else if ini.kind == .symlink {
                result.skipped.append(SkippedPath(path: join(support, "profiles.ini"), reason: .changedDuringScan))
            }
        }

        var seen: Set<String> = []
        for values in parsed {
            guard let profilePath = firefoxProfilePath(values, support: support, home: home),
                seen.insert(profilePath).inserted
            else { continue }
            let name = values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? (profilePath as NSString).lastPathComponent
            result.profiles.append(
                BrowserDataProfile(
                    browser: browser, path: profilePath, name: name, requiresFullDiskAccess: false))
        }

        // A damaged or absent INI must not make a normal Profiles directory invisible.
        if result.profiles.isEmpty {
            let profilesRoot = join(support, "Profiles")
            switch readListing(at: profilesRoot) {
            case .success(let profilesListing):
                if profilesListing.unreadableCount > 0 {
                    result.skipped.append(
                        SkippedPath(path: profilesRoot, reason: .unreadableEntries(profilesListing.unreadableCount)))
                }
                for entry in profilesListing.entries.sorted(by: { $0.name < $1.name }) {
                    let profilePath = join(profilesRoot, entry.name)
                    if entry.kind == .symlink {
                        result.skipped.append(SkippedPath(path: profilePath, reason: .changedDuringScan))
                    } else if entry.kind == .directory {
                        result.profiles.append(
                            BrowserDataProfile(
                                browser: browser, path: profilePath, name: entry.name, requiresFullDiskAccess: false))
                    }
                }
            case .failure(let refusal):
                if !isMissing(refusal) {
                    result.skipped.append(SkippedPath(path: profilesRoot, reason: skipReason(refusal)))
                }
            }
        }
        return result
    }

    private static func parseProfilesINI(_ data: Data) -> [[String: String]] {
        let text = String(decoding: data, as: UTF8.self)
        var profiles: [[String: String]] = []
        var current: [String: String] = [:]
        var inProfile = false

        func finishSection() {
            if inProfile, !current.isEmpty { profiles.append(current) }
            current = [:]
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                finishSection()
                let section = String(line.dropFirst().dropLast())
                let digits = section.hasPrefix("Profile") ? String(section.dropFirst("Profile".count)) : ""
                inProfile = !digits.isEmpty && digits.allSatisfy({ $0.isNumber })
                continue
            }
            guard inProfile, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            current[key] = unquote(value)
        }
        finishSection()
        return profiles
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func firefoxProfilePath(_ values: [String: String], support: String, home: String) -> String? {
        guard let rawPath = values["path"], !rawPath.isEmpty else { return nil }
        if values["isrelative"] != "0" {
            guard isSafeRelativePath(rawPath) else { return nil }
            return join(support, rawPath)
        }
        guard rawPath.hasPrefix("/"), (try? PathPolicy.components(of: rawPath)) != nil,
            (try? PathPolicy.isStrictlyInside(rawPath, root: home)) == true
        else { return nil }
        return rawPath
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func discoverSafariProfiles(home: String) -> DiscoveredProfiles {
        var result = DiscoveredProfiles()
        let roots = [
            BrowserDataCatalog.safariSupport, BrowserDataCatalog.safariContainerSupport,
            BrowserDataCatalog.safariCookies, BrowserDataCatalog.safariContainerCookies,
        ].map { join(home, $0) }
        var found = false
        for root in roots {
            switch readListing(at: root) {
            case .success:
                found = true
            case .failure(let refusal):
                if !isMissing(refusal) {
                    found = true
                    result.skipped.append(SkippedPath(path: root, reason: skipReason(refusal)))
                }
            }
        }
        guard found else { return result }
        result.profiles.append(
            BrowserDataProfile(
                browser: .safari, path: join(home, BrowserDataCatalog.safariSupport), name: "Safari",
                requiresFullDiskAccess: true))
        return result
    }

    // MARK: - Exact target scanning

    private static func scan(
        _ profile: BrowserDataProfile, home: String, policy: ProtectionPolicy,
        ownerState: @Sendable (String) -> OwnerState, seenTargets: inout Set<String>
    ) -> (items: [BrowserDataItem], skipped: [SkippedPath]) {
        var items: [BrowserDataItem] = []
        var skipped: [SkippedPath] = []
        for location in BrowserDataCatalog.locations(for: profile.browser) {
            let root: String
            switch location.root {
            case .profile: root = profile.path
            case .home(let relative): root = join(home, relative)
            }
            switch readListing(at: root) {
            case .success(let listing):
                if listing.unreadableCount > 0 {
                    skipped.append(SkippedPath(path: root, reason: .unreadableEntries(listing.unreadableCount)))
                }
            case .failure(let refusal):
                if !isMissing(refusal) { skipped.append(SkippedPath(path: root, reason: skipReason(refusal))) }
                continue
            }

            for relative in location.relativePaths {
                let target = join(root, relative)
                guard !seenTargets.contains(target) else { continue }
                switch entry(at: target) {
                case .failure(let refusal):
                    if !isMissing(refusal) { skipped.append(SkippedPath(path: target, reason: skipReason(refusal))) }
                case .success(let entry):
                    if entry.kind == .symlink {
                        skipped.append(SkippedPath(path: target, reason: .changedDuringScan))
                        continue
                    }
                    guard entry.kind == .file || entry.kind == .directory else { continue }
                    seenTargets.insert(target)
                    let measurement = entry.kind == .directory ? measureDirectory(at: target) : nil
                    if let measurement { skipped.append(contentsOf: measurement.skipped) }
                    let status = status(
                        of: entry, at: target, browser: profile.browser, policy: policy, ownerState: ownerState,
                        measurement: measurement)
                    let candidate = CleanupCandidate(
                        ruleID: "browserData.\(profile.browser.rawValue).\(location.dataType.rawValue)",
                        name: entry.name, path: target, ruleRoot: root, kind: entry.kind,
                        logicalSize: measurement?.logical ?? entry.size.logical,
                        allocatedSize: measurement?.allocated ?? entry.size.allocated,
                        reclaimableSize: measurement?.reclaimable
                            ?? (entry.linkCount > 1 ? 0 : entry.size.freedIfDeleted),
                        modificationDate: entry.modificationDate, snapshot: FileSnapshot(entry),
                        ownerBundleID: profile.browser.bundleIdentifier, status: status, risk: .review)
                    items.append(BrowserDataItem(profile: profile, location: location, candidate: candidate))
                }
            }
        }
        return (items, skipped)
    }

    private static func status(
        of entry: FileEntry, at path: String, browser: Browser, policy: ProtectionPolicy,
        ownerState: @Sendable (String) -> OwnerState, measurement: DirectoryMeasurement?
    ) -> CandidateStatus {
        if let reason = policy.protection(for: path) { return .protected(reason) }
        if let reason = measurement?.protectedReason { return .protected(reason) }
        if entry.flags & DeletionGate.protectiveFlags != 0 || measurement?.hasProtectiveFlags == true
            || measurement?.hasUnsafeContent == true || !isRemovableByCurrentUser(entry, at: path)
        {
            return .systemManaged
        }
        if ownerState(browser.bundleIdentifier) != .notRunning { return .inUse }
        return .available
    }

    private static func isRemovableByCurrentUser(_ entry: FileEntry, at path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard access(parent, W_OK) == 0 else { return false }
        return entry.kind != .directory || access(path, W_OK) == 0
    }

    private static func measureDirectory(at path: String) -> DirectoryMeasurement {
        var measurement = DirectoryMeasurement()
        do {
            let directory = try SafeWalk.openDirectory(path)
            let identity = try directory.identity()
            measure(directory, at: path, device: identity.device, into: &measurement)
        } catch let refusal as SafetyRefusal {
            measurement.hasUnsafeContent = true
            measurement.skipped.append(SkippedPath(path: path, reason: skipReason(refusal)))
        } catch let error as FileSystemError {
            measurement.hasUnsafeContent = true
            measurement.skipped.append(SkippedPath(path: path, reason: StorageScanner.reason(for: error)))
        } catch {
            measurement.hasUnsafeContent = true
            measurement.skipped.append(SkippedPath(path: path, reason: .error(EIO)))
        }
        return measurement
    }

    private static func measure(
        _ directory: borrowing OpenDirectory, at path: String, device: Int32,
        into measurement: inout DirectoryMeasurement
    ) {
        let listing: DirectoryListing
        do {
            listing = try directory.read()
        } catch {
            measurement.hasUnsafeContent = true
            measurement.skipped.append(SkippedPath(path: path, reason: StorageScanner.reason(for: error)))
            return
        }
        if listing.unreadableCount > 0 {
            measurement.hasUnsafeContent = true
            measurement.skipped.append(SkippedPath(path: path, reason: .unreadableEntries(listing.unreadableCount)))
        }
        for entry in listing.entries {
            let childPath = join(path, entry.name)
            if let reason = ProtectionPolicy.protection(forName: entry.name), measurement.protectedReason == nil {
                measurement.protectedReason = reason
            }
            if entry.flags & DeletionGate.protectiveFlags != 0 { measurement.hasProtectiveFlags = true }
            switch entry.kind {
            case .directory:
                if entry.isMountPoint || entry.identity.device != device {
                    measurement.hasUnsafeContent = true
                    continue
                }
                do {
                    let child = try directory.openChild(named: entry.name)
                    measure(child, at: childPath, device: device, into: &measurement)
                } catch {
                    measurement.hasUnsafeContent = true
                    measurement.skipped.append(SkippedPath(path: childPath, reason: StorageScanner.reason(for: error)))
                }
            case .file, .symlink, .other:
                measurement.logical += entry.size.logical
                measurement.allocated += entry.size.allocated
                measurement.reclaimable += entry.linkCount > 1 ? 0 : entry.size.freedIfDeleted
            }
        }
    }

    // MARK: - Safe reads and result ordering

    private static func readListing(at path: String) -> Result<DirectoryListing, SafetyRefusal> {
        do {
            let directory = try SafeWalk.openDirectory(path)
            return .success(try directory.read())
        } catch let refusal as SafetyRefusal {
            return .failure(refusal)
        } catch let error as FileSystemError {
            return .failure(SafeWalk.refusal(for: error))
        } catch {
            return .failure(.ioError(EIO))
        }
    }

    private static func entry(at path: String) -> Result<FileEntry, SafetyRefusal> {
        do {
            let resolved = try SafeWalk.resolve(path)
            let entries = try resolved.parent.entries()
            guard let entry = entries.first(where: { $0.name == resolved.name }) else { return .failure(.notFound) }
            return .success(entry)
        } catch let refusal as SafetyRefusal {
            return .failure(refusal)
        } catch let error as FileSystemError {
            return .failure(SafeWalk.refusal(for: error))
        } catch {
            return .failure(.ioError(EIO))
        }
    }

    private static func readSmallFile(at path: String) throws(FileSystemError) -> Data {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .current("open", path) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .current("fstat", path) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 8 * 1024 * 1024 else {
            throw FileSystemError(code: EFBIG, operation: "read", path: path)
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw .current("read", path)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 8 * 1024 * 1024 else {
                throw FileSystemError(code: EFBIG, operation: "read", path: path)
            }
        }
        return data
    }

    private static func makeGroups(from items: [BrowserDataItem]) -> [BrowserDataGroup] {
        let grouped = Dictionary(grouping: items, by: \.groupID)
        return grouped.values.compactMap { groupItems in
            guard !groupItems.isEmpty else { return nil }
            let sorted = groupItems.sorted {
                if $0.candidate.reclaimableSize != $1.candidate.reclaimableSize {
                    return $0.candidate.reclaimableSize > $1.candidate.reclaimableSize
                }
                return $0.path < $1.path
            }
            return BrowserDataGroup(items: sorted)
        }.sorted {
            if $0.browser.rawValue != $1.browser.rawValue { return $0.browser.rawValue < $1.browser.rawValue }
            if $0.profile.path != $1.profile.path { return $0.profile.path < $1.profile.path }
            return $0.dataType.rawValue < $1.dataType.rawValue
        }
    }

    private static func skipReason(_ refusal: SafetyRefusal) -> SkippedPath.Reason {
        switch refusal {
        case .permissionDenied: .permissionDenied
        case .notFound, .pathChanged, .changedSinceScan: .changedDuringScan
        case .protected(.excluded): .excluded
        case .ioError(let code): .error(code)
        default: .error(EIO)
        }
    }

    private static func isMissing(_ refusal: SafetyRefusal) -> Bool {
        if case .notFound = refusal { true } else { false }
    }

    private static func isPlainComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    private static func join(_ parent: String, _ child: String) -> String {
        parent.hasSuffix("/") ? parent + child : parent + "/" + child
    }

    private static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
