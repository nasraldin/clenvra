import Darwin
public import Foundation
public import Observation

/// The Applications section: inventory, uninstall with evidence, Homebrew casks and leftovers of removed apps.
///
/// The UI binds to this model; filesystem work runs in the resolver, scanner and deletion executor, off the main
/// actor. Every removal goes through `DeletionExecutor` (Trash first), except `brew uninstall`, which is the
/// tool's own command, shown to the user before it runs.
@MainActor
@Observable
public final class AppsSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case ready
    }

    public enum Filter: Sendable, Hashable, CaseIterable {
        case all
        /// Not opened for six months (only apps Spotlight has a last-used date for).
        case unused
        case appStore
        case homebrew
    }

    public enum SortOrder: Sendable, Hashable, CaseIterable {
        case name
        /// Largest first; apps not measured yet go last.
        case size
        /// Longest unused first; apps without a known date go last.
        case lastUsed
    }

    /// Whether the selected app may be uninstalled right now, and if not, why.
    public enum Availability: Sendable, Equatable {
        case available
        /// Part of macOS or Clenvra itself.
        case protected
        /// A security, VPN or device-management agent; only its own uninstaller may remove it.
        case managed(vendorUninstaller: String?)
        /// Open (or Clenvra cannot tell); it must be quit first.
        case running
    }

    /// The `brew` executable and a runner, when Homebrew is installed.
    public struct Homebrew: Sendable {
        public let brew: String
        public let runner: any CommandRunning
        /// Where each cask records its install options; `nil` uses the Caskroom next to `brew`.
        public let caskroom: String?

        public init(brew: String, runner: any CommandRunning, caskroom: String? = nil) {
            self.brew = brew
            self.runner = runner
            self.caskroom = caskroom
        }
    }

    /// The app bundle as reviewed; the deletion gate refuses if it changes before the move.
    public struct BundleItem: Sendable, Hashable {
        public let path: String
        public let snapshot: FileSnapshot
        public let allocatedSize: Int64
        public let reclaimableSize: Int64
    }

    /// Owned items of one confidence level.
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: OwnedItem.Confidence { confidence }
        public let confidence: OwnedItem.Confidence
        public let items: [OwnedItem]
    }

    /// Everything the review of one app shows.
    public struct Detail: Sendable, Equatable {
        public let app: InstalledApp
        public let availability: Availability
        /// `nil` when the bundle could not be read (it moved or vanished).
        public let bundle: BundleItem?
        public let items: [OwnedItem]
        /// The Homebrew cask managing the app, when there is one.
        public let homebrewToken: String?

        /// Certain, Likely, Possible — only levels that have items.
        public var groups: [Group] {
            OwnedItem.Confidence.allCases.compactMap { confidence in
                let matching = items.filter { $0.confidence == confidence }
                return matching.isEmpty ? nil : Group(confidence: confidence, items: matching)
            }
        }

        func with(_ availability: Availability) -> Detail {
            Detail(app: app, availability: availability, bundle: bundle, items: items, homebrewToken: homebrewToken)
        }
    }

    /// "Unused" means not opened for about six months.
    public static let unusedInterval: TimeInterval = 182 * 86_400

    public private(set) var phase = Phase.idle
    public private(set) var apps: [InstalledApp] = []
    public var searchText = ""
    public var filter = Filter.all
    public var sortOrder = SortOrder.name
    public private(set) var detail: Detail?
    public private(set) var isResolving = false
    /// An uninstall or `brew` command is running.
    public internal(set) var isWorking = false
    /// Paths of owned items chosen for removal (the bundle is always included).
    public private(set) var selection: Set<String> = []
    /// Live output of the last `brew` command.
    public private(set) var homebrewOutput: [String] = []
    /// Apps checked for removal together. Independent of the selected app (`detail`): checking never changes the
    /// selection and selecting never changes the checks.
    public internal(set) var checked: Set<InstalledApp.ID> = []
    public private(set) var leftovers: [OwnedItem] = []
    public private(set) var leftoverSelection: Set<String> = []
    public private(set) var isScanningLeftovers = false
    public private(set) var hasScannedLeftovers = false

    private var sizes: [String: Int64] = [:]
    private var lastUsedDates: [String: Date] = [:]
    private var casks = HomebrewCaskIndex()
    @ObservationIgnored private var measuring: Set<String> = []
    @ObservationIgnored private var resolveGeneration = 0
    @ObservationIgnored private var homebrewRun = 0

    let home: String
    private let policy: ProtectionPolicy
    let deleter: DeletionExecutor
    let log: ActivityLog
    private let resolver: OwnershipResolver
    let privileged: (any PrivilegedOperations)?
    let systemAllowlist: HelperAllowlist
    private let discover: @Sendable @concurrent () async -> [InstalledApp]
    private let ownerState: @Sendable (InstalledApp) -> OwnerState
    private let requestQuit: @Sendable @concurrent (InstalledApp) async -> Void
    private let lastUsedProvider: @Sendable (String) -> Date?
    private let teamIdentifier: @Sendable (InstalledApp) -> String?
    let homebrew: Homebrew?
    /// Runs the read-only `pkgutil --file-info` that tells how an app was installed; `nil` skips that check.
    let installSourceRunner: (any CommandRunning)?
    let now: @Sendable () -> Date
    private let executor: FSExecutor

    /// - Parameters:
    ///   - discover: the installed-app inventory (the app layer also refreshes its own copy here).
    ///   - ownerState: whether the app is running; `.unknown` blocks uninstalling like `.running`.
    ///   - requestQuit: asks the app to quit politely (never force-quits).
    ///   - homebrew: enables `brew uninstall --cask`; `nil` when Homebrew is not installed.
    public init(
        home: String, policy: ProtectionPolicy, deleter: DeletionExecutor, log: ActivityLog,
        resolver: OwnershipResolver, privileged: (any PrivilegedOperations)? = nil,
        systemAllowlist: HelperAllowlist = HelperAllowlist(),
        discover: @escaping @Sendable @concurrent () async -> [InstalledApp],
        ownerState: @escaping @Sendable (InstalledApp) -> OwnerState,
        requestQuit: @escaping @Sendable @concurrent (InstalledApp) async -> Void = { @concurrent _ in },
        lastUsed: @escaping @Sendable (String) -> Date? = { AppInventory.lastUsedDate(of: $0) },
        teamIdentifier: @escaping @Sendable (InstalledApp) -> String? = { ManagedAgents.teamIdentifier(of: $0.id) },
        homebrew: Homebrew? = nil,
        installSourceRunner: (any CommandRunning)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        executor: FSExecutor = .shared
    ) {
        self.home = home
        self.policy = policy
        self.deleter = deleter
        self.log = log
        self.resolver = resolver
        self.privileged = privileged
        self.systemAllowlist = systemAllowlist
        self.discover = discover
        self.ownerState = ownerState
        self.requestQuit = requestQuit
        self.lastUsedProvider = lastUsed
        self.teamIdentifier = teamIdentifier
        self.homebrew = homebrew
        self.installSourceRunner = installSourceRunner
        self.now = now
        self.executor = executor
    }

    // MARK: - Inventory

    /// Reads the inventory, last-used dates and Homebrew casks; keeps measured sizes of apps still present.
    public func load() async {
        phase = .loading
        let found = await discover()
        let ids = found.map(\.id)
        let lastUsed = lastUsedProvider
        let dates =
            (try? await executor.run {
                Dictionary(
                    ids.compactMap { id in lastUsed(id).map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
            }) ?? [:]
        if let homebrew {
            casks = await HomebrewCasks.installedCasks(
                brew: homebrew.brew, runner: homebrew.runner, caskroom: homebrew.caskroom)
        }
        apps = found
        lastUsedDates = dates
        let present = Set(ids)
        sizes = sizes.filter { present.contains($0.key) }
        checked.formIntersection(present)
        phase = .ready
        if let detail, !present.contains(detail.app.id) {
            self.detail = nil
            selection = []
        }
    }

    /// The apps to list, after search, filter and sort.
    public var visibleApps: [InstalledApp] {
        let cutoff = now().addingTimeInterval(-Self.unusedInterval)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = apps.filter { app in
            let included =
                switch filter {
                case .all: true
                case .unused: !app.isProtected && (lastUsedDates[app.id].map { $0 < cutoff } ?? false)
                case .appStore: app.source == .appStore
                case .homebrew: homebrewToken(for: app) != nil
                }
            guard included else { return false }
            return query.isEmpty || app.name.localizedStandardContains(query)
                || app.bundleIdentifier?.localizedStandardContains(query) == true
        }
        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .name:
                break
            case .size:
                if let order = Self.descending(sizes[lhs.id], sizes[rhs.id]) { return order }
            case .lastUsed:
                if let order = Self.ascending(lastUsedDates[lhs.id], lastUsedDates[rhs.id]) { return order }
            }
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.id < rhs.id
            }
        }
    }

    /// `true`/`false` when the values decide the order (larger first, missing values last); `nil` on a tie.
    private static func descending<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool? {
        switch (lhs, rhs) {
        case (let l?, let r?): l == r ? nil : l > r
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): nil
        }
    }

    /// `true`/`false` when the values decide the order (smaller first, missing values last); `nil` on a tie.
    private static func ascending<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool? {
        switch (lhs, rhs) {
        case (let l?, let r?): l == r ? nil : l < r
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): nil
        }
    }

    /// Measured bundle size, or `nil` until `measure` ran for the app.
    public func size(of app: InstalledApp) -> Int64? { sizes[app.id] }

    public func lastUsed(of app: InstalledApp) -> Date? { lastUsedDates[app.id] }

    /// The cask token when Homebrew manages the app.
    public func homebrewToken(for app: InstalledApp) -> String? {
        if case .homebrew(let token) = app.source { return token }
        guard !app.isProtected else { return nil }
        return casks.token(forAppAt: app.id)
    }

    /// Measures one bundle once (rows call this as they appear); cancelled or partial scans are not cached.
    public func measure(_ app: InstalledApp) async {
        guard sizes[app.id] == nil, measuring.insert(app.id).inserted else { return }
        defer { measuring.remove(app.id) }
        let path = app.id
        if let snapshot = try? await StorageScanner.scan(root: path, executor: executor), snapshot.isComplete,
            let aggregate = snapshot.aggregate(at: path)
        {
            sizes[app.id] = aggregate.allocated
        }
    }

    /// Measures every app not measured yet, one at a time, for sorting by size.
    public func measureAll() async {
        for app in apps where sizes[app.id] == nil {
            if Task.isCancelled { return }
            await measure(app)
        }
    }

    // MARK: - Selecting an app

    /// Shows the review for one app (or nothing), resolving what it owns.
    public func select(_ appID: String?) async {
        resolveGeneration += 1
        let generation = resolveGeneration
        homebrewOutput = []
        selection = []
        detail = nil
        guard let appID, let app = apps.first(where: { $0.id == appID }) else {
            isResolving = false
            return
        }
        isResolving = true
        let built = await buildDetail(for: app)
        guard generation == resolveGeneration else { return }
        detail = built
        selection = Set(Self.defaultSelection(built.items).map(\.path))
        isResolving = false
    }

    /// Selects an app dropped from Finder; bundles outside the inventory are read and added first.
    @discardableResult
    public func select(bundleURL url: URL) async -> Bool {
        let path = AppInventory.canonicalPath(url.path(percentEncoded: false))
        if !apps.contains(where: { $0.id == path }) {
            guard (path as NSString).pathExtension.lowercased() == "app",
                let app = try? await executor.run({ AppInventory.app(at: path) }), app.id == path
            else { return false }
            apps.append(app)
        }
        await select(path)
        return true
    }

    func buildDetail(for app: InstalledApp) async -> Detail {
        let availability = await currentAvailability(of: app)
        let isRemovable = availability == .available || availability == .running
        let items =
            isRemovable
            ? await resolver.resolve(app, installedApps: apps, inventoryIsComplete: phase == .ready) : []
        let bundle = await bundleItem(of: app)
        if let bundle { sizes[app.id] = bundle.allocatedSize }
        return Detail(
            app: app, availability: availability, bundle: bundle, items: items, homebrewToken: homebrewToken(for: app))
    }

    private func currentAvailability(of app: InstalledApp) async -> Availability {
        if app.isProtected || policy.protection(for: app.id) != nil { return .protected }
        let teamIdentifier = teamIdentifier
        let ownerState = ownerState
        let checks = try? await executor.run { () -> (managed: Bool, uninstaller: String?, state: OwnerState) in
            let managed = ManagedAgents.isManaged(app, teamIdentifier: teamIdentifier(app))
            return (managed, managed ? ManagedAgents.vendorUninstaller(for: app) : nil, ownerState(app))
        }
        guard let checks else { return .running }
        if checks.managed { return .managed(vendorUninstaller: checks.uninstaller) }
        return checks.state == .notRunning ? .available : .running
    }

    private func bundleItem(of app: InstalledApp) async -> BundleItem? {
        let path = app.id
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let snapshot = FileSnapshot(info)
        guard snapshot.kind == .directory,
            let aggregate = try? await StorageScanner.scan(root: path, executor: executor).aggregate(at: path)
        else { return nil }
        return BundleItem(
            path: path, snapshot: snapshot, allocatedSize: aggregate.allocated,
            reclaimableSize: aggregate.reclaimable)
    }

    /// Re-checks whether the selected app is running (after the user quits it, or before acting).
    public func refreshAvailability() async {
        guard let current = detail else { return }
        let availability = await currentAvailability(of: current.app)
        guard detail?.app.id == current.app.id else { return }
        detail = current.with(availability)
    }

    /// Asks the selected app to quit, then waits briefly for it to close. Never force-quits.
    public func quitSelectedApp() async {
        guard let app = detail?.app else { return }
        await requestQuit(app)
        for _ in 0..<20 {
            await refreshAvailability()
            guard detail?.availability == .running, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Owned item selection

    /// Whether the privileged helper is installed and answering; system leftovers can be selected only then.
    public var helperAvailable = false

    /// Items that can be removed: the user's own files, or system files the helper accepts; nothing protected inside.
    public func isSelectable(_ item: OwnedItem) -> Bool {
        guard !item.containsProtectedItem else { return false }
        return item.handling == .removable || helperItem(for: item, owner: nil) != nil
    }

    /// Whether removing `item` needs administrator rights (it goes through the helper).
    public func needsHelper(_ item: OwnedItem) -> Bool { item.handling == .revealOnly }

    func helperItem(for item: OwnedItem, owner: String?) -> DeletionItem? {
        guard item.handling == .revealOnly, helperAvailable, privileged != nil else { return nil }
        return systemAllowlist.helperItem(
            path: item.path, expected: item.snapshot, owner: owner, freedBytes: item.reclaimableSize,
            section: .applications)
    }

    public func toggle(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else if let item = detail?.items.first(where: { $0.path == path }), isSelectable(item) {
            selection.insert(path)
        }
    }

    private var includesBundle: Bool {
        guard let detail, detail.bundle != nil else { return false }
        return detail.availability == .available || detail.availability == .running
    }

    /// The bundle plus the chosen owned items.
    public var selectedCount: Int { (includesBundle ? 1 : 0) + selection.count }

    /// Estimated bytes freed by the bundle plus the chosen owned items.
    public var selectedBytes: Int64 {
        guard let detail else { return 0 }
        let items = detail.items.filter { selection.contains($0.path) }.reduce(0) { $0 + $1.reclaimableSize }
        return items + (includesBundle ? detail.bundle?.reclaimableSize ?? 0 : 0)
    }

    // MARK: - Uninstalling

    /// Moves the bundle to the Trash and, only if that worked, the chosen owned items; then refreshes. Returns
    /// `nil` (doing nothing) when the app is protected, managed, running or unreadable.
    @discardableResult
    public func uninstall(dryRun: Bool = false) async -> CleanupSummary? {
        guard !isWorking, let current = detail, let bundle = current.bundle else { return nil }
        await refreshAvailability()
        guard let detail, detail.app.id == current.app.id, detail.availability == .available else { return nil }
        let app = detail.app
        let owner = app.bundleIdentifier
        let bundleItem = Self.deletionItem(for: app, bundle: bundle)
        let chosen = detail.items.filter { selection.contains($0.path) && isSelectable($0) }
        let owned = chosen.filter { $0.handling == .removable }.map {
            $0.deletionItem(owner: owner, section: .applications)
        }
        // The app is quit and its bundle goes first, so its launch daemons are orphans by the time the helper looks.
        let system = chosen.compactMap { helperItem(for: $0, owner: nil) }

        isWorking = true
        let (results, bundleDone) = await remove(
            bundle: bundleItem, owned: owned, system: system, dryRun: dryRun, operationID: UUID())
        isWorking = false

        let summary = CleanupSummary(results: results)
        if !dryRun {
            if bundleDone {
                await load()
                await select(nil)
            } else {
                await select(app.id)
            }
        }
        return summary
    }

    /// The bundle first and, only if it went, the owned items; the same path for one app and for several.
    private func remove(
        bundle: DeletionItem, owned: [DeletionItem], system: [DeletionItem], dryRun: Bool, operationID: UUID
    ) async -> (results: [DeletionResult], bundleDone: Bool) {
        var results = await deleter.run([bundle], mode: .moveToTrash, dryRun: dryRun, operationID: operationID)
        let bundleDone = results.contains { result in
            switch result.outcome {
            case .movedToTrash, .wouldDelete: true
            default: false
            }
        }
        if bundleDone {
            results += await deleter.run(owned, mode: .moveToTrash, dryRun: dryRun, operationID: operationID)
            results += await removeThroughHelper(system, dryRun: dryRun, operationID: operationID)
        } else {
            // Data without its app is worse than an app without its data: keep everything if the bundle stays.
            results += (owned + system).map { DeletionResult(item: $0, outcome: .notAttempted) }
        }
        return (results, bundleDone)
    }

    /// The bundle as a deletion item, guarded by the snapshot taken at review.
    static func deletionItem(for app: InstalledApp, bundle: BundleItem) -> DeletionItem {
        DeletionItem(
            path: app.id, ruleRoot: (app.id as NSString).deletingLastPathComponent, expected: bundle.snapshot,
            ownerBundleID: app.bundleIdentifier, freedBytes: bundle.reclaimableSize, section: .applications)
    }

    /// Owned items chosen when an app is selected: those selected by default that the user's own rights cover.
    private static func defaultSelection(_ items: [OwnedItem]) -> [OwnedItem] {
        items.filter { $0.isSelectedByDefault && $0.handling == .removable && !$0.containsProtectedItem }
    }

    /// System leftovers go through the helper, which checks each one again. Launch items use its orphan check.
    func removeThroughHelper(
        _ items: [DeletionItem], mode: HelperRequest.Mode = .moveToTrash, dryRun: Bool, operationID: UUID
    ) async -> [DeletionResult] {
        guard !items.isEmpty else { return [] }
        guard let privileged, helperAvailable else {
            return items.map { DeletionResult(item: $0, outcome: .notAttempted) }
        }
        let isLaunchItem = { (item: DeletionItem) in
            ["LaunchDaemons", "LaunchAgents"].contains((item.ruleRoot as NSString).lastPathComponent)
        }
        var results: [DeletionResult] = []
        let files = items.filter { !isLaunchItem($0) }
        if !files.isEmpty {
            let request = HelperRequest(
                operationID: operationID, mode: dryRun ? .dryRun : mode, items: files, ownerBundlePaths: [:])
            let outcomes =
                (try? await privileged.perform(request).outcomes)
                ?? Array(repeating: .notAttempted, count: files.count)
            results += zip(files, outcomes).map { DeletionResult(item: $0, outcome: $1) }
        }
        for item in items where isLaunchItem(item) {
            let outcome: ActivityRecord.Outcome =
                dryRun
                ? .wouldDelete
                : (try? await privileged.removeOrphanedLaunchItem(item, operationID: operationID)) ?? .notAttempted
            results.append(DeletionResult(item: item, outcome: outcome))
        }
        if !dryRun { await deleter.recordPrivileged(results, operationID: operationID) }
        return results
    }

    // MARK: - Resetting

    /// Reset candidates reuse uninstall's ownership evidence without including the bundle, launch helpers or guesses.
    public func resetItems(for app: InstalledApp) async -> [OwnedItem] {
        await resolver.resetItems(for: app, installedApps: apps, inventoryIsComplete: phase == .ready)
    }

    /// Moves only the reviewed reset items to the Trash, leaving the app itself installed and launch configuration intact.
    @discardableResult
    public func reset(_ app: InstalledApp, items: [OwnedItem], dryRun: Bool = false) async -> CleanupSummary? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        guard await currentAvailability(of: app) == .available else { return nil }

        // Re-resolve ownership to prevent items reviewed for another app being sent through this operation. Keep the
        // reviewed snapshots, so anything changed since review is still refused by the deletion gate.
        let eligiblePaths = Set(await resetItems(for: app).map(\.path))
        let owner = app.bundleIdentifier
        // Reset only ever touches the user's own files; system files are left to uninstall.
        let deletionItems = items.filter {
            eligiblePaths.contains($0.path) && $0.handling == .removable && isSelectable($0)
        }
        .map { $0.deletionItem(owner: owner, section: .applications) }
        let results = await deleter.run(deletionItems, mode: .moveToTrash, dryRun: dryRun)
        let summary = CleanupSummary(results: results)
        if !dryRun, detail?.app.id == app.id { await select(app.id) }
        return summary
    }

    // MARK: - Homebrew

    /// The exact command offered for a Homebrew-managed app, shown before it runs.
    public var homebrewCommand: Command? {
        guard let homebrew, let token = detail?.homebrewToken else { return nil }
        return HomebrewCasks.uninstallCommand(brew: homebrew.brew, token: token)
    }

    /// Runs `brew uninstall --cask <token>` (permanent, not the Trash), logs it, then refreshes.
    @discardableResult
    public func uninstallWithHomebrew() async -> CommandResult? {
        guard !isWorking, let homebrew, let command = homebrewCommand, let current = detail else { return nil }
        await refreshAvailability()
        guard detail?.app.id == current.app.id, detail?.availability == .available else { return nil }
        let app = current.app
        let bytes = current.bundle?.reclaimableSize ?? 0
        let operation = UUID()
        func record(_ outcome: ActivityRecord.Outcome) async -> Bool {
            let entry = ActivityRecord(
                operationID: operation, date: now(), section: .applications, itemPath: app.id, bytes: bytes,
                outcome: outcome)
            return (try? await log.append(entry)) != nil
        }
        guard await record(.intent) else { return nil }  // never act without a log entry

        isWorking = true
        homebrewRun += 1
        let run = homebrewRun
        homebrewOutput = []
        let result: CommandResult?
        do {
            result = try await homebrew.runner.run(command) { [weak self] line in
                Task { @MainActor in
                    guard let self, self.homebrewRun == run else { return }
                    self.homebrewOutput.append(line.text)
                }
            }
        } catch {
            result = nil
        }
        homebrewRun += 1  // late live lines are dropped; the final output below is authoritative
        let succeeded = result?.terminationReason == .exited && result?.exitStatus == 0
        _ = await record(succeeded ? .removedPermanently : .failed(errno: EIO))
        isWorking = false

        await load()
        await select(apps.contains { $0.id == app.id } ? app.id : nil)
        let output = result.map { $0.standardOutput + "\n" + $0.standardError } ?? ""
        homebrewOutput = output.split(whereSeparator: \.isNewline).map(String.init)
        return result
    }

    // MARK: - Leftovers of removed apps

    /// Finds conservative leftovers of apps that are no longer installed, including those of apps already in the
    /// Trash. Needs a loaded inventory.
    public func scanLeftovers() async {
        isScanningLeftovers = true
        let trashRoots = [home + "/.Trash"]
        let trashed = (try? await executor.run { AppInventory.appsInTrash(trashRoots: trashRoots) }) ?? []
        let found = await resolver.leftovers(
            installedApps: apps, trashedApps: trashed, inventoryIsComplete: phase == .ready, now: now())
        leftovers = found
        leftoverSelection.formIntersection(found.map(\.path))
        isScanningLeftovers = false
        hasScannedLeftovers = true
    }

    public func toggleLeftover(_ path: String) {
        if leftoverSelection.contains(path) {
            leftoverSelection.remove(path)
        } else if let item = leftovers.first(where: { $0.path == path }), isSelectable(item) {
            leftoverSelection.insert(path)
        }
    }

    public var leftoverSelectedBytes: Int64 {
        leftovers.filter { leftoverSelection.contains($0.path) }.reduce(0) { $0 + $1.reclaimableSize }
    }

    /// Moves the chosen leftovers to the Trash (or checks them, when `dryRun`), then rescans.
    @discardableResult
    public func removeLeftovers(dryRun: Bool = false) async -> CleanupSummary {
        let items = leftovers.filter { leftoverSelection.contains($0.path) && isSelectable($0) }
            .map { $0.deletionItem(owner: nil, section: .applications) }
        isWorking = true
        let results = await deleter.run(items, mode: .moveToTrash, dryRun: dryRun)
        isWorking = false
        if !dryRun {
            leftoverSelection = []
            await scanLeftovers()
        }
        return CleanupSummary(results: results)
    }

}

// MARK: - Removing several apps

extension AppsSession {
    /// Why a checked app was left installed.
    public enum SkipReason: Sendable, Hashable {
        /// Open (or Clenvra cannot tell); it must be quit first.
        case running
        /// Part of macOS or Clenvra, or a security or device-management agent.
        case protected
        /// The bundle moved, vanished or changed since it was listed, so the deletion gate refused it.
        case changed
        /// Its backup could not be made, so nothing of it was removed.
        case backupFailed(String)
        /// `brew uninstall` failed (with its last error line), so nothing else of it was removed.
        case homebrewFailed(String)
    }

    /// What removing the checked apps did.
    public struct BatchUninstallResult: Sendable {
        /// Names of the apps removed (or, in a dry run, that would be).
        public var removed: [String] = []
        /// Apps left installed, each with the reason.
        public var skipped: [(name: String, reason: SkipReason)] = []
        /// Every item of every app, as for one uninstall.
        public var summary = CleanupSummary()
        /// Backup folders made in this run, also for apps that were not removed afterwards.
        public var backups: [URL] = []

        public init() {}
    }

    /// The checked apps that are still installed, by name: exactly what a batch removal works on, including
    /// apps hidden by the current search or filter.
    public var checkedApps: [InstalledApp] {
        apps.filter { checked.contains($0.id) }.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
    }

    public func toggleChecked(_ id: InstalledApp.ID) {
        if checked.contains(id) {
            checked.remove(id)
        } else if apps.contains(where: { $0.id == id }) {
            checked.insert(id)
        }
    }

    /// Replaces the checks; ids of apps not in the inventory are dropped.
    public func setChecked(_ ids: Set<InstalledApp.ID>) {
        checked = ids.intersection(apps.map(\.id))
    }

    public func clearChecked() { checked = [] }

    /// Removes every checked app the way `uninstall` removes one: the bundle and the files selected by default
    /// go to the Trash, the bundle first. Running, protected or changed apps are skipped and reported. With a
    /// `backup` folder each app is backed up first and kept if its backup fails. One Activity operation per run.
    /// A dry run checks every item and makes no backups.
    public func uninstallChecked(backup: URL?, dryRun: Bool = false) async -> BatchUninstallResult {
        var result = BatchUninstallResult()
        guard !isWorking else { return result }
        isWorking = true
        let operation = UUID()
        var removedIDs: Set<InstalledApp.ID> = []
        for app in checkedApps {
            if Task.isCancelled { break }
            let built = await buildDetail(for: app)
            switch built.availability {
            case .protected, .managed:
                result.skipped.append((app.name, .protected))
                continue
            case .running:
                result.skipped.append((app.name, .running))
                continue
            case .available:
                break
            }
            guard let bundle = built.bundle else {
                result.skipped.append((app.name, .changed))
                continue
            }
            let chosen = Self.defaultSelection(built.items)
            if let backup, !dryRun {
                do {
                    let made = try await AppBackup.create(app: app, items: [app.id] + chosen.map(\.path), in: backup)
                    result.backups.append(made)
                } catch let error as AppBackupError {
                    result.skipped.append((app.name, .backupFailed(error.message)))
                    continue
                } catch {
                    result.skipped.append((app.name, .backupFailed(error.localizedDescription)))
                    continue
                }
            }
            let owned = chosen.map { $0.deletionItem(owner: app.bundleIdentifier, section: .applications) }
            let (results, bundleDone) = await remove(
                bundle: Self.deletionItem(for: app, bundle: bundle), owned: owned, system: [], dryRun: dryRun,
                operationID: operation)
            result.summary.add(results)
            if bundleDone {
                result.removed.append(app.name)
                removedIDs.insert(app.id)
            } else {
                result.skipped.append((app.name, .changed))
            }
        }
        isWorking = false
        if !dryRun, !removedIDs.isEmpty {
            checked.subtract(removedIDs)
            let shown = detail?.app.id
            await load()
            if let shown, removedIDs.contains(shown) { await select(nil) }
        }
        return result
    }

    /// Moves one backup folder to the Trash through the deletion gate, logged like any removal so it can be put
    /// back from Activity. `nil` when the backup is no longer there.
    public func trashBackup(_ backup: AppBackupInfo) async -> CleanupSummary? {
        guard !isWorking, let resolved = realpath(backup.url.path(percentEncoded: false), nil) else { return nil }
        let path = String(cString: resolved)
        free(resolved)
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let item = DeletionItem(
            path: path, ruleRoot: (path as NSString).deletingLastPathComponent, expected: FileSnapshot(info),
            ownerBundleID: nil, freedBytes: backup.archiveBytes, section: .applications)
        isWorking = true
        let results = await deleter.run([item], mode: .moveToTrash)
        isWorking = false
        return CleanupSummary(results: results)
    }
}
