import Darwin
public import Foundation

/// Decides which files outside an app's bundle belong to it, and how sure that is (`safety-model.md` §5).
///
/// Ownership comes from system-maintained metadata first (exact identifier paths, container metadata, launch item
/// declarations, signed application groups, installer receipts) and from names only as a last, never-pre-selected
/// guess. Anything another installed app may also use is reported as shared and never pre-selected.
public struct OwnershipResolver: Sendable {
    /// One top-level item an installer package placed outside the home folder.
    public struct ReceiptFile: Sendable, Hashable {
        public let path: String
        public let packageIdentifier: String

        /// Memberwise, so lookups (and tests) can build results.
        public init(path: String, packageIdentifier: String) {
            self.path = path
            self.packageIdentifier = packageIdentifier
        }
    }

    /// Returns receipt items for an app's identifiers; injected so the `pkgutil` dependency stays optional.
    public typealias ReceiptLookup = @Sendable @concurrent (_ identifiers: [String]) async -> [ReceiptFile]

    /// Owner prefixes never reported as leftovers: shared frameworks and updaters many apps use.
    public static let neverFlagPrefixes = [
        "com.apple.", "org.chromium.", "com.google.keystone", "com.github.electron", "com.electron.",
        "org.qt-project.", "io.qt.", "com.microsoft.autoupdate", "org.sparkle-project",
    ]

    /// Leftovers touched more recently than this may still be in use by something not in the inventory.
    public static let minimumLeftoverAge: TimeInterval = 30 * 86_400

    /// System folders whose direct children an installer package can own.
    static let receiptRoots = [
        "/Library/Application Support", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Preferences", "/Library/Caches", "/Library/Logs",
        "/Library/Frameworks", "/Library/Internet Plug-Ins", "/Library/PreferencePanes", "/Library/QuickLook",
        "/Library/Spotlight", "/Library/Screen Savers", "/Library/Audio/Plug-Ins/Components",
        "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3",
    ].sorted { $0.count > $1.count }

    private struct Folder: Sendable {
        let relative: String
        let kind: OwnedItem.Kind
        /// Extension the item carries after the identifier (for example `.plist`).
        let suffix: String?
    }

    /// `~/Library` folders whose children are named after a bundle identifier.
    private static let identifierFolders = [
        Folder(relative: "Caches", kind: .caches, suffix: nil),
        Folder(relative: "Application Support", kind: .applicationSupport, suffix: nil),
        Folder(relative: "HTTPStorages", kind: .httpStorage, suffix: nil),
        Folder(relative: "WebKit", kind: .webKit, suffix: nil),
        Folder(relative: "Logs", kind: .logs, suffix: nil),
        Folder(relative: "Application Scripts", kind: .applicationScripts, suffix: nil),
        Folder(relative: "Preferences", kind: .preferences, suffix: ".plist"),
        Folder(relative: "Saved Application State", kind: .savedState, suffix: ".savedState"),
        Folder(relative: "Cookies", kind: .cookies, suffix: ".binarycookies"),
    ]

    /// `~/Library` folders where apps also create folders named after themselves.
    private static let nameFolders = identifierFolders.filter {
        ["Caches", "Application Support", "Logs"].contains($0.relative)
    }

    private static let containerMetadataName = ".com.apple.containermanagerd.metadata.plist"

    private let home: String
    private let policy: ProtectionPolicy
    private let launchItems: @Sendable ([InstalledApp]) -> [LaunchItem]
    private let receipts: ReceiptLookup?
    private let applicationGroups: @Sendable (InstalledApp) -> [String]
    private let executor: FSExecutor

    /// - Parameters:
    ///   - home: canonical home folder.
    ///   - launchItems: launch items attributed to the given apps; defaults to the user's and the system's folders.
    ///   - receipts: installer receipt lookup (for example `pkgutilReceipts`); `nil` skips receipts.
    ///   - applicationGroups: group containers an app may own; defaults to the signature's entitlement.
    public init(
        home: String, policy: ProtectionPolicy,
        launchItems: (@Sendable ([InstalledApp]) -> [LaunchItem])? = nil,
        receipts: ReceiptLookup? = nil,
        applicationGroups: @escaping @Sendable (InstalledApp) -> [String] = {
            $0.applicationGroups ?? AppInventory.applicationGroups(of: $0.id)
        },
        executor: FSExecutor = .shared
    ) {
        self.home = home
        self.policy = policy
        self.launchItems = launchItems ?? Self.standardLaunchItems(home: home)
        self.receipts = receipts
        self.applicationGroups = applicationGroups
        self.executor = executor
    }

    /// Launch agents of the user plus system agents and daemons, read without asking ServiceManagement.
    public static func standardLaunchItems(home: String) -> @Sendable ([InstalledApp]) -> [LaunchItem] {
        { apps in
            LaunchItemReader(userAgents: home + "/Library/LaunchAgents", status: { _ in .unknown })
                .read(installedApps: apps)
        }
    }

    // MARK: - Resolving one app

    /// Everything `app` owns, Certain first. `installedApps` must be the whole inventory (including `app`);
    /// when it is not known to be complete, nothing less than Certain is pre-selected.
    @concurrent public func resolve(
        _ app: InstalledApp, installedApps: [InstalledApp], inventoryIsComplete: Bool = true
    ) async -> [OwnedItem] {
        guard !app.isProtected else { return [] }
        let identifiers = Self.identifiers(of: app)
        let receiptFiles = await receipts?(identifiers) ?? []
        let context = Context(
            app: app, installedApps: installedApps, receipts: receiptFiles,
            inventoryIsComplete: inventoryIsComplete && installedApps.contains { $0.id != app.id })
        let matches = (try? await executor.run { collect(context) }) ?? []
        return await finish(matches) { match in
            match.handling == .removable && match.sharedWith.isEmpty
                && (match.confidence == .certain || (match.confidence == .likely && context.inventoryIsComplete))
        }
    }

    /// Reset keeps the app and its launch configuration, and never acts on name-only ownership guesses.
    @concurrent func resetItems(
        for app: InstalledApp, installedApps: [InstalledApp], inventoryIsComplete: Bool
    ) async -> [OwnedItem] {
        await resolve(app, installedApps: installedApps, inventoryIsComplete: inventoryIsComplete).filter { item in
            item.confidence != .possible && item.kind != .launchAgent && item.kind != .systemFile
                && item.handling == .removable
        }
    }

    private struct Context: Sendable {
        let app: InstalledApp
        let installedApps: [InstalledApp]
        let receipts: [ReceiptFile]
        let inventoryIsComplete: Bool
    }

    /// An item found on disk, before its size is measured.
    private struct Match: Sendable {
        let path: String
        let ruleRoot: String
        let kind: OwnedItem.Kind
        let snapshot: FileSnapshot
        let size: SizeInfo
        let modificationDate: Date?
        var confidence: OwnedItem.Confidence
        var evidence: [Evidence]
        var sharedWith: Set<String>
        let handling: OwnedItem.Handling
    }

    private func collect(_ context: Context) -> [Match] {
        let app = context.app
        let others = context.installedApps.filter { $0.id != app.id }
        let ownIdentifiers = Dictionary(
            Self.identifiers(of: app).map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var groupCache: [String: [String]] = [:]
        func groups(of other: InstalledApp) -> [String] {
            if let cached = groupCache[other.id] { return cached }
            let groups = applicationGroups(other)
            groupCache[other.id] = groups
            return groups
        }
        func claimants(identifier: String) -> Set<String> {
            Set(others.filter { Self.identifiers(of: $0).contains { Self.sharesLineage($0, identifier) } }.map(\.id))
        }

        var matches: [String: Match] = [:]
        func add(_ match: Match?) {
            guard let match else { return }
            guard var existing = matches[match.path] else {
                matches[match.path] = match
                return
            }
            existing.confidence = min(existing.confidence, match.confidence)
            existing.evidence += match.evidence.filter { !existing.evidence.contains($0) }
            existing.sharedWith.formUnion(match.sharedWith)
            matches[match.path] = existing
        }

        let library = home + "/Library"

        // Certain: children named exactly after an identifier.
        for folder in Self.identifierFolders {
            let root = library + "/" + folder.relative
            for entry in Self.list(root) {
                guard let stem = Self.stem(of: entry.name, suffix: folder.suffix),
                    let identifier = ownIdentifiers[stem.lowercased()]
                else { continue }
                add(
                    Self.match(
                        entry, in: root, kind: folder.kind, confidence: .certain,
                        evidence: [.exactBundleIdentifierPath(identifier)],
                        sharedWith: claimants(identifier: identifier)
                    ))
            }
        }
        // Certain: per-host preferences, `<id>.<host UUID>.plist`.
        let byHost = library + "/Preferences/ByHost"
        for entry in Self.list(byHost) where entry.name.lowercased().hasSuffix(".plist") {
            let stem = String(entry.name.dropLast(".plist".count)).lowercased()
            for (lowered, identifier) in ownIdentifiers where stem.hasPrefix(lowered + ".") {
                guard !stem.dropFirst(lowered.count + 1).contains(".") else { continue }
                add(
                    Self.match(
                        entry, in: byHost, kind: .preferences, confidence: .certain,
                        evidence: [.exactBundleIdentifierPath(identifier)],
                        sharedWith: claimants(identifier: identifier)
                    ))
            }
        }
        // Certain: sandbox containers, by the identifier their metadata records.
        let containers = library + "/Containers"
        for entry in Self.list(containers) where entry.kind == .directory {
            guard let recorded = Self.containerIdentifier(at: containers + "/" + entry.name),
                let identifier = ownIdentifiers[recorded.lowercased()]
            else { continue }
            add(
                Self.match(
                    entry, in: containers, kind: .container, confidence: .certain,
                    evidence: [.containerMetadata(identifier)], sharedWith: claimants(identifier: identifier)))
        }
        // Certain: launch items that declare the app or run a program inside its bundle.
        for item in launchItems(context.installedApps) {
            add(launchMatch(item, app: app, ownIdentifiers: ownIdentifiers, others: others, claimants: claimants))
        }
        // Certain, reveal-only: installer receipts.
        for receipt in context.receipts {
            add(
                Self.match(
                    atPath: receipt.path, kind: .systemFile, evidence: [.receipt(receipt.packageIdentifier)],
                    sharedWith: [], handling: .revealOnly))
        }

        // Likely: the app's signed group containers.
        let ownGroups = applicationGroups(app)
        if !ownGroups.isEmpty {
            let groupRoot = library + "/Group Containers"
            for entry in Self.list(groupRoot) {
                guard let group = ownGroups.first(where: { $0.lowercased() == entry.name.lowercased() }) else {
                    continue
                }
                let bare = Self.groupWithoutPrefix(group)
                let sharing = others.filter { other in
                    groups(of: other).contains { $0.lowercased() == group.lowercased() }
                        || Self.identifiers(of: other).contains { Self.sharesLineage($0, bare) }
                }
                add(
                    Self.match(
                        entry, in: groupRoot, kind: .groupContainer, confidence: .likely,
                        evidence: [.applicationGroup(group)], sharedWith: Set(sharing.map(\.id))))
            }
        }
        // Likely: folders named exactly like the app.
        let name = app.name.trimmingCharacters(in: .whitespaces)
        if name.count >= 3 {
            for folder in Self.nameFolders {
                let root = library + "/" + folder.relative
                for entry in Self.list(root) where entry.name.lowercased() == name.lowercased() {
                    let sharing = others.filter { $0.name.lowercased() == name.lowercased() }
                    add(
                        Self.match(
                            entry, in: root, kind: folder.kind, confidence: .likely, evidence: [.exactName(app.name)],
                            sharedWith: Set(sharing.map(\.id))))
                }
            }
        }
        // Possible: whole-word name matches no other installed app could also explain.
        for folder in Self.identifierFolders {
            let root = library + "/" + folder.relative
            for entry in Self.list(root) where matches[root + "/" + entry.name] == nil {
                guard !entry.name.lowercased().hasPrefix("com.apple."), Self.containsWholeWord(name, in: entry.name)
                else { continue }
                let stem = Self.stem(of: entry.name, suffix: folder.suffix) ?? entry.name
                let ambiguous = others.contains { other in
                    Self.containsWholeWord(other.name, in: entry.name)
                        || Self.identifiers(of: other).contains { Self.sharesLineage($0, stem) }
                }
                guard !ambiguous else { continue }
                add(
                    Self.match(
                        entry, in: root, kind: folder.kind, confidence: .possible, evidence: [.nameMatch(app.name)],
                        sharedWith: []))
            }
        }

        let bundles = context.installedApps.map { $0.id + "/" }
        return matches.values.filter { match in
            policy.protection(for: match.path) == nil && !bundles.contains { match.path.hasPrefix($0) }
        }
    }

    private func launchMatch(
        _ item: LaunchItem, app: InstalledApp, ownIdentifiers: [String: String], others: [InstalledApp],
        claimants: (String) -> Set<String>
    ) -> Match? {
        var evidence: [Evidence] = item.associatedBundleIdentifiers.compactMap { declared in
            ownIdentifiers[declared.lowercased()].map { .associatedBundleIdentifier($0) }
        }
        if let program = item.program, program.hasPrefix(app.id + "/") {
            evidence.append(.programInsideBundle(program))
        }
        guard !evidence.isEmpty else { return nil }
        var sharing = Set(others.filter { other in item.program?.hasPrefix(other.id + "/") == true }.map(\.id))
        for declared in item.associatedBundleIdentifiers {
            sharing.formUnion(claimants(declared))
        }
        let handling: OwnedItem.Handling = item.domain == .userAgent ? .removable : .revealOnly
        return Self.match(
            atPath: item.plistPath, kind: item.domain == .userAgent ? .launchAgent : .systemFile, evidence: evidence,
            sharedWith: sharing, handling: handling)
    }

    // MARK: - Leftovers of removed apps

    /// Library items named after bundle identifiers that no installed app (or its components) shares lineage with,
    /// untouched for at least 30 days. They are offered for review only and never pre-selected. Without a complete,
    /// non-empty inventory nothing is reported, because "no owner" must be proven.
    ///
    /// An orphan whose identifier shares lineage with an app in `trashedApps` is Likely, carries `.appInTrash`
    /// evidence and is listed whatever its age: the user has just thrown the app away. An identifier an installed
    /// app shares lineage with is never listed, even when a trashed app matches it too.
    @concurrent public func leftovers(
        installedApps: [InstalledApp], trashedApps: [InstalledApp] = [], inventoryIsComplete: Bool = true,
        now: Date = Date()
    ) async -> [OwnedItem] {
        guard inventoryIsComplete, !installedApps.isEmpty else { return [] }
        let installed = installedApps.flatMap(Self.identifiers(of:))
        let trashed: [(identifier: String, name: String)] = trashedApps.flatMap { app in
            Self.identifiers(of: app).filter { Self.looksLikeBundleIdentifier($0) && !Self.isNeverFlagged($0) }
                .map { (identifier: $0, name: app.name) }
        }
        let home = home
        let policy = policy
        let matches =
            (try? await executor.run { () -> [Match] in
                func isOrphan(_ identifier: String) -> Bool {
                    Self.looksLikeBundleIdentifier(identifier) && !Self.isNeverFlagged(identifier)
                        && !installed.contains { Self.sharesLineage($0, identifier) }
                }
                /// A Possible orphan, raised to Likely when an app in the Trash explains it.
                func orphan(_ match: Match?, identifier: String) -> Match? {
                    guard var match else { return nil }
                    let names = trashed.filter { Self.sharesLineage($0.identifier, identifier) }.map(\.name)
                    for name in names where !match.evidence.contains(.appInTrash(name)) {
                        match.evidence.append(.appInTrash(name))
                    }
                    if !names.isEmpty { match.confidence = .likely }
                    return match
                }
                let library = home + "/Library"
                var found: [Match] = []
                for folder in Self.identifierFolders {
                    let root = library + "/" + folder.relative
                    for entry in Self.list(root) {
                        guard let identifier = Self.stem(of: entry.name, suffix: folder.suffix), isOrphan(identifier),
                            let match = orphan(
                                Self.match(
                                    entry, in: root, kind: folder.kind, confidence: .possible,
                                    evidence: [.exactBundleIdentifierPath(identifier)], sharedWith: []),
                                identifier: identifier)
                        else { continue }
                        found.append(match)
                    }
                }
                let containers = library + "/Containers"
                for entry in Self.list(containers) where entry.kind == .directory {
                    guard let identifier = Self.containerIdentifier(at: containers + "/" + entry.name),
                        isOrphan(identifier),
                        let match = orphan(
                            Self.match(
                                entry, in: containers, kind: .container, confidence: .possible,
                                evidence: [.containerMetadata(identifier)], sharedWith: []),
                            identifier: identifier)
                    else { continue }
                    found.append(match)
                }
                return found.filter { policy.protection(for: $0.path) == nil }
            }) ?? []
        let cutoff = now.addingTimeInterval(-Self.minimumLeftoverAge)
        return await finish(matches) { _ in false }.filter { item in
            item.evidence.contains { if case .appInTrash = $0 { true } else { false } }
                || (item.modificationDate ?? now) <= cutoff
        }
    }

    // MARK: - Sizes and ordering

    @concurrent private func finish(_ matches: [Match], preselect: (Match) -> Bool) async -> [OwnedItem] {
        var items: [OwnedItem] = []
        for match in matches {
            var allocated = match.size.allocated
            var reclaimable = match.size.freedIfDeleted
            var modified = match.modificationDate
            var guarded = false
            if match.snapshot.kind == .directory,
                let aggregate = try? await StorageScanner.scan(root: match.path, executor: executor)
                    .aggregate(at: match.path)
            {
                allocated = aggregate.allocated
                reclaimable = aggregate.reclaimable
                if let latest = aggregate.latestModification { modified = max(modified ?? latest, latest) }
                let path = match.path
                guarded = (try? await executor.run { Self.containsProtectedName(atPath: path) }) ?? true
            }
            items.append(
                OwnedItem(
                    path: match.path, ruleRoot: match.ruleRoot, kind: match.kind, snapshot: match.snapshot,
                    allocatedSize: allocated, reclaimableSize: reclaimable, modificationDate: modified,
                    confidence: match.confidence, evidence: match.evidence, sharedWith: match.sharedWith.sorted(),
                    handling: match.handling, containsProtectedItem: guarded,
                    isSelectedByDefault: !guarded && preselect(match)))
        }
        return items.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            if lhs.allocatedSize != rhs.allocatedSize { return lhs.allocatedSize > rhs.allocatedSize }
            return lhs.path < rhs.path
        }
    }

    // MARK: - Matching rules (internal for tests)

    /// The app's own identifier and those of its extensions, helpers and login items.
    static func identifiers(of app: InstalledApp) -> [String] {
        ([app.bundleIdentifier].compactMap { $0 } + app.embeddedBundleIdentifiers).filter { !$0.isEmpty }
    }

    /// Same identifier, or one is a dotted prefix of the other (`com.a` and `com.a.helper`), ignoring case.
    static func sharesLineage(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.lowercased()
        let b = rhs.lowercased()
        return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    /// True when `word` (at least four characters) appears in `text` delimited by non-alphanumerics or the ends.
    static func containsWholeWord(_ word: String, in text: String) -> Bool {
        let needle = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 4 else { return false }
        let haystack = text.lowercased()
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let startsWord =
                range.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: range.lowerBound)])
            let endsWord = range.upperBound == haystack.endIndex || !isWordCharacter(haystack[range.upperBound])
            if startsWord && endsWord { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    static func isNeverFlagged(_ identifier: String) -> Bool {
        let owner = groupOwner(of: identifier).lowercased()
        return neverFlagPrefixes.contains { owner.hasPrefix($0) }
    }

    /// The identifier a group container is named after: `group.`, `groups.` and `systemgroup.` and a ten-character
    /// team prefix (`243LU875E5.groups.com.apple.podcasts`) are dropped, so macOS's own groups match `com.apple.`.
    static func groupOwner(of identifier: String) -> String {
        var parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        if let team = parts.first, team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }),
            parts.count > 1
        {
            parts.removeFirst()
        }
        if let first = parts.first, ["group", "groups", "systemgroup"].contains(first.lowercased()), parts.count > 1 {
            parts.removeFirst()
        }
        return parts.joined(separator: ".")
    }

    /// Reverse-DNS shape with at least three components (`com.vendor.app`), so plain folder names never qualify.
    static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty
                && part.unicodeScalars.allSatisfy { $0.isASCII && (isWordScalar($0) || $0 == "-" || $0 == "_") }
        }
    }

    /// `TEAMID.com.vendor.group` or `group.com.vendor.group` → `com.vendor.group`.
    static func groupWithoutPrefix(_ group: String) -> String {
        if group.lowercased().hasPrefix("group.") { return String(group.dropFirst("group.".count)) }
        let parts = group.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10,
            parts[0].unicodeScalars.allSatisfy({
                $0.isASCII && CharacterSet.uppercaseLetters.union(.decimalDigits).contains($0)
            })
        {
            return String(parts[1])
        }
        return group
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - File system helpers

    private static func list(_ path: String) -> [FileEntry] {
        guard let directory = try? OpenDirectory(path: path), let entries = try? directory.entries() else { return [] }
        return entries
    }

    /// The name without `suffix` (matched case-insensitively); `nil` when the suffix is required and missing.
    private static func stem(of name: String, suffix: String?) -> String? {
        guard let suffix else { return name }
        guard name.count > suffix.count, name.lowercased().hasSuffix(suffix.lowercased()) else { return nil }
        return String(name.dropLast(suffix.count))
    }

    private static func containerIdentifier(at container: String) -> String? {
        guard let data = FileManager.default.contents(atPath: container + "/" + containerMetadataName),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let identifier = plist["MCMMetadataIdentifier"] as? String, !identifier.isEmpty
        else { return nil }
        return identifier
    }

    private static func match(
        _ entry: FileEntry, in root: String, kind: OwnedItem.Kind, confidence: OwnedItem.Confidence,
        evidence: [Evidence], sharedWith: Set<String>
    ) -> Match? {
        guard entry.kind == .directory || entry.kind == .file else { return nil }
        return Match(
            path: root + "/" + entry.name, ruleRoot: root, kind: kind, snapshot: FileSnapshot(entry), size: entry.size,
            modificationDate: entry.modificationDate, confidence: confidence, evidence: evidence,
            sharedWith: sharedWith, handling: .removable)
    }

    /// A Certain item found by path (launch items, receipts); its parent folder is the rule root.
    private static func match(
        atPath path: String, kind: OwnedItem.Kind, evidence: [Evidence], sharedWith: Set<String>,
        handling: OwnedItem.Handling
    ) -> Match? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let snapshot = FileSnapshot(info)
        guard snapshot.kind == .directory || snapshot.kind == .file else { return nil }
        let allocated = Int64(info.st_blocks) * 512
        return Match(
            path: path, ruleRoot: (path as NSString).deletingLastPathComponent, kind: kind, snapshot: snapshot,
            size: SizeInfo(logical: Int64(info.st_size), allocated: allocated, reclaimable: nil),
            modificationDate: snapshot.modificationDate, confidence: .certain, evidence: evidence,
            sharedWith: sharedWith, handling: handling)
    }

    /// Whether anything inside the folder is protected by name (keys, keychains…); unreadable counts as yes.
    private static func containsProtectedName(atPath path: String) -> Bool {
        guard let directory = try? OpenDirectory(path: path) else { return true }
        return containsProtectedName(in: directory, depth: 0)
    }

    private static func containsProtectedName(in directory: borrowing OpenDirectory, depth: Int) -> Bool {
        guard depth < 64, let entries = try? directory.entries() else { return true }
        for entry in entries {
            if ProtectionPolicy.protection(forName: entry.name) != nil { return true }
            if entry.kind == .directory, !entry.isMountPoint {
                guard let child = try? directory.openChild(named: entry.name) else { return true }
                if containsProtectedName(in: child, depth: depth + 1) { return true }
            }
        }
        return false
    }

    // MARK: - Installer receipts

    /// Receipt lookup through `pkgutil`: packages whose identifier shares lineage with the app, reduced to their
    /// top-level items below known system folders (never the bundle itself, never `/Applications`).
    public static func pkgutilReceipts(
        runner: any CommandRunning, pkgutil: String = "/usr/sbin/pkgutil"
    ) -> ReceiptLookup {
        { @concurrent identifiers in
            @concurrent func output(_ arguments: [String]) async -> String? {
                let command = Command(executable: pkgutil, arguments: arguments, timeout: .seconds(30))
                guard let result = try? await runner.run(command), result.terminationReason == .exited,
                    result.exitStatus == 0
                else { return nil }
                return result.standardOutput
            }
            guard let listing = await output(["--pkgs"]) else { return [] }
            let packages = listing.split(whereSeparator: \.isNewline).map(String.init).filter { package in
                identifiers.contains { sharesLineage(package, $0) }
            }
            var files: Set<ReceiptFile> = []
            for package in packages {
                guard let infoText = await output(["--pkg-info-plist", package]),
                    let info = try? PropertyListSerialization.propertyList(from: Data(infoText.utf8), format: nil)
                        as? [String: Any],
                    let fileList = await output(["--files", package])
                else { continue }
                let volume = info["volume"] as? String ?? "/"
                let location = info["install-location"] as? String ?? "/"
                for line in fileList.split(whereSeparator: \.isNewline) {
                    guard let path = normalizedPath([volume, location, String(line)]), let top = topLevelItem(path)
                    else { continue }
                    files.insert(ReceiptFile(path: top, packageIdentifier: package))
                }
            }
            return files.sorted { $0.path < $1.path }
        }
    }

    /// Joins path pieces, collapsing repeated slashes; `nil` for anything with `.` or `..` components.
    private static func normalizedPath(_ pieces: [String]) -> String? {
        let parts = pieces.flatMap { $0.split(separator: "/") }.map(String.init)
        guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    private static func topLevelItem(_ path: String) -> String? {
        for root in receiptRoots where path.hasPrefix(root + "/") {
            guard let first = path.dropFirst(root.count + 1).split(separator: "/").first else { return nil }
            return root + "/" + first
        }
        return nil
    }
}
