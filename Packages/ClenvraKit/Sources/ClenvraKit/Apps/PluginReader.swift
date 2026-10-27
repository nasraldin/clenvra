import Darwin
import Foundation

/// Everything one plug-in scan found, plus why some sources could not be read (shown instead of a silent gap).
public struct PluginInventory: Sendable, Equatable {
    /// A source that produced no items because it could not be read.
    public enum Source: Sendable, Hashable {
        case appExtensions
        case systemExtensions
    }

    /// Why a source is missing from the results.
    public enum Issue: Sendable, Hashable {
        /// The command could not be run, timed out or exited with an error.
        case commandFailed(Source)
        /// The command ran but its output was not in a format Clenvra understands.
        case unreadableOutput(Source)
        /// A plug-in folder exists but could not be listed (permissions).
        case unreadableFolder(String)
    }

    public var items: [PluginItem]
    public var issues: [Issue]

    public init(items: [PluginItem] = [], issues: [Issue] = []) {
        self.items = items
        self.issues = issues
    }
}

/// Reads plug-ins and extensions from the plug-in folders of both domains, `pluginkit` and `systemextensionsctl`,
/// without changing anything, so the Extensions section can show what is installed.
public struct PluginReader: Sendable {
    /// Plug-in folders relative to a domain root, with the kind of bundle each holds.
    static let folders: [(relative: String, kind: PluginItem.Kind)] = [
        ("Library/PreferencePanes", .preferencePane),
        ("Library/QuickLook", .quickLook),
        ("Library/Spotlight", .spotlightImporter),
        ("Library/Audio/Plug-Ins/Components", .audioUnit),
        ("Library/Audio/Plug-Ins/VST", .vstPlugIn),
        ("Library/Audio/Plug-Ins/VST3", .vst3PlugIn),
        ("Library/Audio/Plug-Ins/HAL", .halPlugIn),
        ("Library/Audio/Plug-Ins/MAS", .masPlugIn),
        ("Library/Internet Plug-Ins", .internetPlugIn),
    ]

    /// System-extension categories that only security, VPN and network software use (`safety-model.md` §3).
    static let managedCategories: Set<String> = [
        "com.apple.system_extension.network_extension", "com.apple.system_extension.endpoint_security",
    ]

    static let pluginKit = Command(executable: "/usr/bin/pluginkit", arguments: ["-mAvvv"], timeout: .seconds(30))
    static let systemExtensionsList = Command(
        executable: "/usr/bin/systemextensionsctl", arguments: ["list"], timeout: .seconds(30))

    /// The current user's home folder, the default user domain.
    public static let defaultHome: String = FileManager.default.homeDirectoryForCurrentUser.path(
        percentEncoded: false)

    /// Larger Info.plist files are not plug-in metadata; refusing them bounds memory.
    private static let maxInfoPlistSize = 1 << 20

    private let home: String
    private let systemRoot: String
    private let runner: any CommandRunning
    private let teamIdentifier: @Sendable (String) -> String?

    /// `home` and `systemRoot` are injectable so tests can use a fixture tree; both must be canonical paths.
    public init(
        home: String = PluginReader.defaultHome,
        systemRoot: String = "/",
        runner: any CommandRunning = ProcessCommandRunner(),
        teamIdentifier: @escaping @Sendable (String) -> String? = { ManagedAgents.teamIdentifier(of: $0) }
    ) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.systemRoot = systemRoot
        self.runner = runner
        self.teamIdentifier = teamIdentifier
    }

    /// Reads every source; file-based folders run on `executor` because they block on the filesystem.
    public func read(executor: FSExecutor = .shared) async -> PluginInventory {
        async let bundles = (try? await executor.run { readBundles() }) ?? PluginInventory()
        async let appExtensions = readAppExtensions()
        async let systemExtensions = readSystemExtensions()
        let parts = await [bundles, appExtensions, systemExtensions]
        return PluginInventory(items: parts.flatMap(\.items), issues: parts.flatMap(\.issues))
    }

    // MARK: - File-based plug-ins

    /// Lists bundles in the plug-in folders of the user and system domains. Blocking; call off the main actor.
    public func readBundles() -> PluginInventory {
        var inventory = PluginInventory()
        for (root, domain) in [(home, PluginItem.Domain.user), (systemRoot, .system)] {
            for folder in Self.folders {
                let path = (root as NSString).appendingPathComponent(folder.relative)
                readFolder(path, kind: folder.kind, domain: domain, into: &inventory)
            }
        }
        return inventory
    }

    private func readFolder(
        _ folder: String, kind: PluginItem.Kind, domain: PluginItem.Domain, into inventory: inout PluginInventory
    ) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch {
            let code = (error as NSError).code
            if code != NSFileReadNoSuchFileError, code != NSFileNoSuchFileError {
                inventory.issues.append(.unreadableFolder(folder))
            }
            return
        }
        for name in names.sorted() where !name.hasPrefix(".") {
            if let item = bundleItem(name: name, folder: folder, kind: kind, domain: domain) {
                inventory.items.append(item)
            }
        }
    }

    private func bundleItem(
        name: String, folder: String, kind: PluginItem.Kind, domain: PluginItem.Domain
    ) -> PluginItem? {
        let path = (folder as NSString).appendingPathComponent(name)
        let fallbackName = (name as NSString).deletingPathExtension
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }

        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            // Never followed: neither its metadata nor its target are read, and only revealing is offered.
            return PluginItem(
                name: fallbackName, kind: kind, path: path, bundleIdentifier: nil, version: nil, domain: domain,
                handling: .revealOnly)
        case S_IFDIR:
            break
        default:
            return nil
        }

        let plist = Self.infoPlist(ofBundle: path)
        let identifier = plist["CFBundleIdentifier"] as? String
        let displayName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
        let isApple = identifier.map(Self.isAppleIdentifier) ?? false
        let isManaged =
            identifier.map(ManagedAgents.isManaged(identifier:)) == true
            || teamIdentifier(path).map(ManagedAgents.teamIdentifiers.contains) == true

        var snapshot: FileSnapshot?
        let handling: PluginItem.Handling
        if isManaged {
            handling = .managed
        } else if domain == .user, !isApple, let resolved = try? SafeWalk.resolve(path) {
            snapshot = resolved.snapshot
            handling = .removable
        } else {
            handling = .revealOnly
        }

        return PluginItem(
            name: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName, kind: kind, path: path,
            bundleIdentifier: identifier, version: version, domain: domain, handling: handling, isApple: isApple,
            size: Self.allocatedSize(of: path), ruleRoot: handling == .removable ? folder : nil, snapshot: snapshot)
    }

    /// Reads `Contents/Info.plist` (or a flat bundle's `Info.plist`) without following any symlink.
    private static func infoPlist(ofBundle bundle: String) -> [String: Any] {
        for relative in ["Contents/Info.plist", "Info.plist"] {
            if relative.hasPrefix("Contents/") {
                var info = stat()
                let contents = bundle + "/Contents"
                guard lstat(contents, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            }
            guard let data = readRegularFile(bundle + "/" + relative, limit: maxInfoPlistSize),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            return plist
        }
        return [:]
    }

    private static func readRegularFile(_ path: String, limit: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            return nil
        }
        return try? handle.read(upToCount: limit)
    }

    /// Sums allocated sizes without following links, so the size shown is what moving the bundle frees.
    private static func allocatedSize(of path: String) -> Int64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(filePath: path, directoryHint: .isDirectory), includingPropertiesForKeys: keys)
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - App extensions

    /// Reads `pluginkit -mAvvv`; on failure the result is empty with a reason.
    public func readAppExtensions() async -> PluginInventory {
        guard let output = await output(of: Self.pluginKit) else {
            return PluginInventory(issues: [.commandFailed(.appExtensions)])
        }
        guard let records = Self.parsePluginKit(output) else {
            return PluginInventory(issues: [.unreadableOutput(.appExtensions)])
        }
        return PluginInventory(items: records.map(appExtensionItem))
    }

    /// One `pluginkit` record: the header line plus its `Key = Value` lines.
    struct PluginKitRecord: Equatable {
        var identifier: String
        var version: String?
        /// `+` elected to use, `-` elected to ignore; anything else means no user choice.
        var election: Character?
        var fields: [String: String] = [:]
    }

    /// `nil` when the output contains no recognisable record.
    static func parsePluginKit(_ output: String) -> [PluginKitRecord]? {
        var records: [PluginKitRecord] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("\t") {
                guard !records.isEmpty, let separator = line.range(of: " = ") else { continue }
                let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
                let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                records[records.count - 1].fields[key] = value
            } else if let record = pluginKitHeader(line) {
                records.append(record)
            }
        }
        return records.isEmpty ? nil : records
    }

    /// Parses `+    com.vendor.ext(1.0)`; the version is `(null)` when the bundle has none.
    private static func pluginKitHeader(_ line: String) -> PluginKitRecord? {
        var rest = Substring(line)
        var election: Character?
        if let first = rest.first, "+-!=?".contains(first) {
            election = first
            rest = rest.dropFirst()
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(")"), let open = text.range(of: "(") else { return nil }
        let identifier = String(text[..<open.lowerBound])
        let version = String(text[open.upperBound..<text.index(before: text.endIndex)])
        guard isPlausibleIdentifier(identifier), !version.isEmpty else { return nil }
        return PluginKitRecord(
            identifier: identifier, version: version == "(null)" ? nil : version, election: election)
    }

    private func appExtensionItem(_ record: PluginKitRecord) -> PluginItem {
        let path = record.fields["Path"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let parent = record.fields["Parent Bundle"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let containingApp = parent ?? path.flatMap(Self.enclosingApp)
        let domain: PluginItem.Domain =
            if containingApp != nil {
                .appBundle
            } else if let path, path.hasPrefix(home + "/") {
                .user
            } else {
                .system
            }
        let isApple = Self.isAppleIdentifier(record.identifier) || (path?.hasPrefix("/System/") ?? false)
        let name = [record.fields["Display Name"], record.fields["Short Name"]].compactMap { $0 }
            .first { !$0.isEmpty }
        let isEnabled: Bool? =
            switch record.election {
            case "+": true
            case "-": false
            default: nil
            }
        return PluginItem(
            id: path.map { "appex:" + $0 }, name: name ?? record.identifier, kind: .appExtension, path: path,
            bundleIdentifier: record.identifier, version: record.version, domain: domain,
            containingApp: containingApp, isEnabled: isEnabled,
            handling: ManagedAgents.isManaged(identifier: record.identifier) ? .managed : .revealOnly,
            isApple: isApple, extensionPoint: record.fields["SDK"])
    }

    /// `/Applications/X.app/Contents/PlugIns/Y.appex` → `/Applications/X.app`.
    private static func enclosingApp(of path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(path[..<path.index(range.lowerBound, offsetBy: 4)])
    }

    // MARK: - System extensions

    /// Reads `systemextensionsctl list`; on failure the result is empty with a reason.
    public func readSystemExtensions() async -> PluginInventory {
        guard let output = await output(of: Self.systemExtensionsList) else {
            return PluginInventory(issues: [.commandFailed(.systemExtensions)])
        }
        guard let items = Self.parseSystemExtensions(output) else {
            return PluginInventory(issues: [.unreadableOutput(.systemExtensions)])
        }
        return PluginInventory(items: items)
    }

    /// `nil` when there is no `N extension(s)` header or fewer rows than it announces could be read.
    static func parseSystemExtensions(_ output: String) -> [PluginItem]? {
        var announced: Int?
        var category: String?
        var items: [PluginItem] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if announced == nil {
                let words = line.split(separator: " ")
                if words.count == 2, words[1] == "extension(s)", let count = Int(words[0]) { announced = count }
                continue
            }
            if line.hasPrefix("--- ") {
                category = line.dropFirst(4).split(separator: " ").first.map(String.init)
                continue
            }
            if line.hasPrefix("enabled\t") { continue }
            if let item = systemExtensionRow(line, category: category) { items.append(item) }
        }
        guard let announced, items.count >= announced else { return nil }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Parses `*\t*\tTEAMID\tcom.vendor.ext (1.2/120)\tName\t[activated enabled]`.
    private static func systemExtensionRow(_ line: String, category: String?) -> PluginItem? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard columns.count >= 6 else { return nil }
        let idAndVersion = columns[3]
        guard idAndVersion.hasSuffix(")"), let open = idAndVersion.range(of: " (") else { return nil }
        let identifier = String(idAndVersion[..<open.lowerBound])
        let versions = idAndVersion[open.upperBound..<idAndVersion.index(before: idAndVersion.endIndex)]
        guard isPlausibleIdentifier(identifier) else { return nil }
        let version = versions.split(separator: "/").first.map(String.init)
        let team = columns[2].isEmpty || columns[2] == "-" ? nil : columns[2]
        var state = columns[5]
        if state.hasPrefix("["), state.hasSuffix("]") { state = String(state.dropFirst().dropLast()) }
        let isManaged =
            category.map(managedCategories.contains) == true || ManagedAgents.isManaged(identifier: identifier)
            || team.map(ManagedAgents.teamIdentifiers.contains) == true
        return PluginItem(
            id: "systemextension:\(team ?? "-"):\(identifier):\(version ?? ""):\(state)",
            name: columns[4].isEmpty ? identifier : columns[4], kind: .systemExtension, path: nil,
            bundleIdentifier: identifier, version: version, domain: .system, isEnabled: columns[0] == "*",
            handling: isManaged ? .managed : .revealOnly, isApple: isAppleIdentifier(identifier),
            extensionPoint: category, teamIdentifier: team, state: state.isEmpty ? nil : state)
    }

    // MARK: - Helpers

    private func output(of command: Command) async -> String? {
        guard let result = try? await runner.run(command), result.terminationReason == .exited,
            result.exitStatus == 0
        else { return nil }
        return result.standardOutput
    }

    /// Reverse-DNS-like: at least two dot-separated parts, no whitespace or control characters.
    private static func isPlausibleIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return identifier.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
                && scalar != "(" && scalar != ")"
        }
    }

    private static func isAppleIdentifier(_ identifier: String) -> Bool {
        identifier.lowercased().hasPrefix("com.apple.")
    }
}
