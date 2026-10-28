import CoreServices
import Darwin
public import Foundation
import Security

/// Finds installed applications and reads what Clenvra needs to know about each one.
public enum AppInventory {
    /// Places users install apps; `/System/Applications` is included so Apple apps are visible (and protected).
    public static let defaultSearchRoots: [String] = [
        "/Applications",
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path(percentEncoded: false),
        "/System/Applications",
        "/Applications/Setapp",
    ]

    /// Clenvra's own identifier; it must never offer to remove itself.
    public static let clenvraBundleIdentifier = "com.nasraldin.clenvra"

    /// Folder levels below a root that are searched; apps are rarely nested deeper and deeper trees cost time.
    static let maximumDepth = 3

    /// Locations that decide an app's source and protection. Injected so tests never touch `/System`.
    struct Locations: Sendable {
        /// Sealed system app folders; apps here (or symlinked here, like Safari) ship with macOS.
        var systemRoots: [String]
        var setappRoots: [String]
        var homebrewCaskroom: String

        static func standard(homebrewCaskroom: String) -> Locations {
            Locations(
                systemRoots: ["/System/Applications", "/System/Cryptexes/App/System/Applications"],
                setappRoots: ["/Applications/Setapp"],
                homebrewCaskroom: homebrewCaskroom
            )
        }

        /// The same locations with every path made canonical, so prefix checks match `realpath` results.
        func canonical() -> Locations {
            Locations(
                systemRoots: systemRoots.map(AppInventory.canonicalPath),
                setappRoots: setappRoots.map(AppInventory.canonicalPath),
                homebrewCaskroom: AppInventory.canonicalPath(homebrewCaskroom)
            )
        }
    }

    /// Discovers `.app` bundles under the roots so the Applications section and ownership matching start from one
    /// list. Never follows symlinks, except links into the Homebrew Caskroom or a system app folder.
    @concurrent public static func discover(
        roots: [String] = defaultSearchRoots, homebrewCaskroom: String = "/opt/homebrew/Caskroom"
    ) async -> [InstalledApp] {
        await discover(roots: roots, locations: .standard(homebrewCaskroom: homebrewCaskroom))
    }

    /// Reads one bundle (and nothing else), for callers that already know where an app is.
    public static func app(at bundlePath: String, homebrewCaskroom: String = "/opt/homebrew/Caskroom")
        -> InstalledApp?
    {
        app(at: bundlePath, locations: .standard(homebrewCaskroom: homebrewCaskroom))
    }

    /// Group container identifiers an app may own under `~/Library/Group Containers`; unsigned apps have none.
    public static func applicationGroups(of bundlePath: String) -> [String] {
        let url = URL(filePath: bundlePath, directoryHint: .isDirectory)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
            let information = information as? [String: Any],
            let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
            let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }

    /// When the app was last opened, so users can spot apps they no longer use; `nil` if Spotlight does not know.
    /// For bundles never opened Spotlight reports a filesystem date as "last used", so the date is trusted only
    /// when Spotlight has also recorded a use count (`kMDItemUseCount`, which has no public SDK constant).
    public static func lastUsedDate(of bundlePath: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, bundlePath as CFString),
            let useCount = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? Int, useCount > 0
        else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: - Internal (testable)

    @concurrent static func discover(roots: [String], locations: Locations) async -> [InstalledApp] {
        let work: @Sendable () -> [InstalledApp] = {
            let locations = locations.canonical()
            var candidates: [String] = []
            for root in roots {
                let rootPath = canonicalPath(root)
                guard let directory = try? OpenDirectory(path: rootPath) else { continue }
                collectCandidates(in: directory, path: rootPath, depth: 0, locations: locations, into: &candidates)
            }
            var seen: Set<String> = []
            var apps: [InstalledApp] = []
            for candidate in candidates {
                guard let app = app(at: candidate, canonicalLocations: locations), seen.insert(app.id).inserted else {
                    continue
                }
                apps.append(app)
            }
            return apps.sorted { lhs, rhs in
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.id < rhs.id
                }
            }
        }
        return (try? await FSExecutor.shared.run(work)) ?? []
    }

    static func app(at bundlePath: String, locations: Locations) -> InstalledApp? {
        app(at: bundlePath, canonicalLocations: locations.canonical())
    }

    // MARK: - Private

    /// Directory extensions that are bundles; never descended into when looking for apps.
    private static let bundleExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "xpc", "kext", "systemextension",
    ]

    private static func collectCandidates(
        in directory: borrowing OpenDirectory, path: String, depth: Int, locations: Locations,
        into candidates: inout [String]
    ) {
        guard let entries = try? directory.entries() else { return }
        for entry in entries where !entry.name.hasPrefix(".") {
            let childPath = path + "/" + entry.name
            let fileExtension = (entry.name as NSString).pathExtension.lowercased()
            switch entry.kind {
            case .directory where fileExtension == "app":
                candidates.append(childPath)
            case .directory
            where !bundleExtensions.contains(fileExtension) && depth < maximumDepth
                && !entry.isMountPoint:
                guard let child = try? directory.openChild(named: entry.name) else { continue }
                collectCandidates(in: child, path: childPath, depth: depth + 1, locations: locations, into: &candidates)
            case .symlink where fileExtension == "app":
                let target = canonicalPath(childPath)
                let allowed = [locations.homebrewCaskroom] + locations.systemRoots
                if allowed.contains(where: { isUnder(target, $0) }) {
                    candidates.append(target)
                }
            default:
                continue
            }
        }
    }

    private static func app(at bundlePath: String, canonicalLocations locations: Locations) -> InstalledApp? {
        let path = canonicalPath(bundlePath)
        guard (path as NSString).pathExtension.lowercased() == "app",
            let info = readInfoPlist(atBundle: path)
        else { return nil }

        let identifier = nonEmptyString(info["CFBundleIdentifier"])
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = nonEmptyString(info["CFBundleDisplayName"]) ?? nonEmptyString(info["CFBundleName"]) ?? fileName
        let source = source(of: path, locations: locations)
        return InstalledApp(
            id: path,
            url: URL(filePath: path, directoryHint: .isDirectory),
            bundleIdentifier: identifier,
            name: name,
            version: nonEmptyString(info["CFBundleShortVersionString"]),
            build: nonEmptyString(info["CFBundleVersion"]),
            source: source,
            isProtected: source == .apple || identifier == clenvraBundleIdentifier,
            embeddedBundleIdentifiers: embeddedIdentifiers(inBundle: path)
        )
    }

    private static func source(of path: String, locations: Locations) -> InstalledApp.Source {
        if FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") {
            return .appStore
        }
        if isUnder(path, locations.homebrewCaskroom) {
            let relative = path.dropFirst(locations.homebrewCaskroom.count + 1)
            if let token = relative.split(separator: "/").first {
                return .homebrew(token: String(token))
            }
        }
        if locations.setappRoots.contains(where: { isUnder(path, $0) }) { return .setapp }
        if locations.systemRoots.contains(where: { isUnder(path, $0) }) { return .apple }
        return .other
    }

    /// Identifiers of nested code that can own data or launch on its own. Helpers in `Library/LaunchServices`
    /// are usually bare executables named after their identifier, so a plain file contributes its name.
    private static func embeddedIdentifiers(inBundle path: String) -> [String] {
        let folders = [
            "Contents/PlugIns", "Contents/Library/LoginItems", "Contents/XPCServices",
            "Contents/Library/LaunchServices", "Contents/Library/SystemExtensions",
        ]
        var identifiers: Set<String> = []
        for folder in folders {
            let folderPath = path + "/" + folder
            guard let directory = try? OpenDirectory(path: folderPath), let entries = try? directory.entries() else {
                continue
            }
            for entry in entries where !entry.name.hasPrefix(".") {
                switch entry.kind {
                case .directory:
                    let info = readInfoPlist(atBundle: folderPath + "/" + entry.name)
                    if let id = nonEmptyString(info?["CFBundleIdentifier"]) {
                        identifiers.insert(id)
                    }
                case .file where folder == "Contents/Library/LaunchServices":
                    identifiers.insert(entry.name)
                default:
                    continue
                }
            }
        }
        return identifiers.sorted()
    }

    private static func readInfoPlist(atBundle path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func isUnder(_ path: String, _ folder: String) -> Bool {
        path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// `realpath` of the path, or the path itself (tilde-expanded) when it does not exist.
    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else { return expanded }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
