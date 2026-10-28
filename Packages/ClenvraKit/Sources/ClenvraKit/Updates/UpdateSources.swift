public import Foundation

/// Where an app's updates come from and how each source's answer is read (AP-9).
///
/// Every parser is defensive: anything unexpected gives `nil`, which the update list shows as "unknown".
public enum UpdateSources {
    /// The Sparkle feed an app declares; plain-HTTP feeds are reported but never fetched.
    public enum Feed: Sendable, Equatable {
        case https(URL)
        case insecure
    }

    /// The newest release an appcast offers this Mac.
    struct AppcastRelease: Sendable, Equatable {
        /// `sparkle:shortVersionString`, shown to people.
        var shortVersion: String?
        /// `sparkle:version`, compared with the app's `CFBundleVersion` the way Sparkle does.
        var build: String?
    }

    // MARK: - Sparkle

    /// The `SUFeedURL` from the bundle's Info.plist. Apps that set their feed in code have none here.
    public static func sparkleFeed(ofBundle path: String) -> Feed? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
            let text = plist["SUFeedURL"] as? String,
            let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return URLSessionFetcher.isSecure(url) ? .https(url) : .insecure
    }

    /// The newest item on the default channel whose minimum macOS this Mac meets, compared by version number.
    static func latestAppcastRelease(from data: Data, systemVersion: AppVersion) -> AppcastRelease? {
        let reader = AppcastReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { return nil }

        var best: (version: AppVersion, release: AppcastRelease)?
        for item in reader.items {
            if let channel = item.channel, !channel.isEmpty { continue }
            if let minimum = item.minimumSystemVersion.flatMap(AppVersion.init), systemVersion < minimum { continue }
            let release = AppcastRelease(shortVersion: item.shortVersion, build: item.build)
            guard let version = item.build.flatMap(AppVersion.init) ?? item.shortVersion.flatMap(AppVersion.init)
            else { continue }
            if best.map({ $0.version < version }) ?? true { best = (version, release) }
        }
        return best?.release
    }

    // MARK: - Homebrew

    /// The command that lists outdated casks, including those that update themselves (`--greedy`).
    /// Auto-update is off so checking never changes the user's Homebrew installation.
    static func outdatedCommand(brew: String) -> Command {
        let inherited = ProcessInfo.processInfo.environment
        let environment = [
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "USER": inherited["USER"] ?? NSUserName(),
            "PATH": [(brew as NSString).deletingLastPathComponent, "/usr/bin", "/bin"].joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
        ]
        return Command(
            executable: brew, arguments: ["outdated", "--cask", "--greedy", "--json=v2"], environment: environment,
            timeout: .seconds(120))
    }

    /// Cask token → newest version from `brew outdated --cask --json=v2`; `nil` when the output is unreadable.
    static func outdatedCasks(fromJSON data: Data) -> [String: String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let casks = root["casks"] as? [Any]
        else { return nil }
        var versions: [String: String] = [:]
        for case let cask as [String: Any] in casks {
            guard let name = cask["name"] as? String, let current = cask["current_version"] as? String,
                !name.isEmpty, !current.isEmpty
            else { continue }
            versions[name] = current
        }
        return versions
    }

    // MARK: - Mac App Store

    /// The public iTunes lookup for one bundle identifier, restricted to Mac apps.
    public static func appStoreLookupURL(bundleIdentifier: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard !bundleIdentifier.isEmpty,
            let escaped = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "https://itunes.apple.com/lookup?bundleId=\(escaped)&entity=macSoftware")
    }

    /// The store's current version for the bundle, or `nil` when the response does not list it.
    static func appStoreVersion(fromJSON data: Data, bundleIdentifier: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = root["results"] as? [Any]
        else { return nil }
        for case let result as [String: Any] in results {
            guard result["bundleId"] as? String == bundleIdentifier, let version = result["version"] as? String,
                !version.isEmpty
            else { continue }
            return version
        }
        return nil
    }
}

/// Collects `<item>` versions from a Sparkle appcast. Both the attribute form on `<enclosure>` and the element form
/// (`<sparkle:version>` inside `<item>`) are read; any namespace prefix is accepted.
private final class AppcastReader: NSObject, XMLParserDelegate {
    struct Item {
        var shortVersion: String?
        var build: String?
        var channel: String?
        var minimumSystemVersion: String?
    }

    private(set) var items: [Item] = []
    private var current: Item?
    private var element: String?
    private var text = ""

    /// Elements and attributes inside the Sparkle namespace that matter here.
    private static let fields: Set<String> = ["version", "shortVersionString", "channel", "minimumSystemVersion"]

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        if elementName == "item" {
            current = Item()
            return
        }
        guard current != nil else { return }
        if elementName == "enclosure" {
            for (key, value) in attributes {
                guard let field = Self.prefixedField(key) else { continue }
                assign(value, to: field, overwrite: false)
            }
        } else if let field = Self.prefixedField(elementName) {
            element = field
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if element != nil { text += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        if elementName == "item" {
            if let current { items.append(current) }
            current = nil
            element = nil
        } else if let field = element, Self.prefixedField(elementName) == field {
            assign(text, to: field, overwrite: true)
            element = nil
        }
    }

    private func assign(_ raw: String, to field: String, overwrite: Bool) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != nil else { return }
        switch field {
        case "version" where overwrite || current?.build == nil: current?.build = value
        case "shortVersionString" where overwrite || current?.shortVersion == nil: current?.shortVersion = value
        case "channel": current?.channel = value
        case "minimumSystemVersion": current?.minimumSystemVersion = value
        default: break
        }
    }

    /// `sparkle:version` → `version`; unprefixed names are not Sparkle's and are ignored.
    private static func prefixedField(_ name: String) -> String? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let local = String(name[name.index(after: colon)...])
        return fields.contains(local) ? local : nil
    }
}
