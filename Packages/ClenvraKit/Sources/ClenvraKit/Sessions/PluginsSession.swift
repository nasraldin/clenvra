import Foundation
public import Observation

/// The Extensions & plug-ins section: everything that adds code to macOS or other apps, grouped by kind, with
/// removal of the user's own plug-in bundles through the deletion gate.
@MainActor
@Observable
public final class PluginsSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case scanning
        case ready
        case removing
    }

    /// Items of one kind, by name; only kinds with visible items are present.
    public struct Group: Sendable, Identifiable, Equatable {
        public var id: PluginItem.Kind { kind }
        public let kind: PluginItem.Kind
        public let items: [PluginItem]
    }

    public private(set) var phase = Phase.idle
    public private(set) var groups: [Group] = []
    /// IDs (paths) of selected removable items. Nothing is selected by default: plug-ins are the user's choice.
    public private(set) var selection: Set<String> = []
    /// Sources that could not be read in the last scan, so the UI can say what is missing.
    public private(set) var issues: [PluginInventory.Issue] = []
    public private(set) var lastSummary: CleanupSummary?
    /// Apple's own extensions are many and never actionable, so they are hidden unless the user asks.
    public var showsAppleItems = false {
        didSet { regroup() }
    }

    /// Which apps are open and how to quit one, so an extension's app can be closed before the user removes it.
    /// The app passes `NSWorkspace` / `NSRunningApplication`; tests pass fakes.
    public struct AppControl: Sendable {
        /// Bundle paths of the apps running now.
        public var runningAppPaths: @MainActor @Sendable () -> Set<String>
        /// Asks the app at the bundle path to quit (`force`: terminate at once); `true` when the request was accepted.
        public var quit: @MainActor @Sendable (_ appPath: String, _ force: Bool) -> Bool

        public init(
            runningAppPaths: @escaping @MainActor @Sendable () -> Set<String>,
            quit: @escaping @MainActor @Sendable (_ appPath: String, _ force: Bool) -> Bool
        ) {
            self.runningAppPaths = runningAppPaths
            self.quit = quit
        }

        /// Never reports a running app and never quits anything.
        public static let none = AppControl(runningAppPaths: { [] }, quit: { _, _ in false })
    }

    /// Bundle paths (no trailing slash) of the apps open at the last scan or refresh.
    public private(set) var runningApps: Set<String> = []
    /// Apps whose polite quit request was refused, so the UI offers Force Quit next.
    public private(set) var failedPoliteQuits: Set<String> = []

    private let reader: PluginReader
    private let deleter: DeletionExecutor
    private let executor: FSExecutor
    private let apps: AppControl
    private let runner: any CommandRunning
    private var items: [PluginItem] = []
    private var itemsByID: [String: PluginItem] = [:]

    public init(
        reader: PluginReader, deleter: DeletionExecutor, executor: FSExecutor = .shared, apps: AppControl = .none,
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.reader = reader
        self.deleter = deleter
        self.executor = executor
        self.apps = apps
        self.runner = runner
    }

    // MARK: - Turning app extensions on and off

    /// A third-party app extension that macOS lists: it can be turned off and on again, as in System Settings.
    /// Never Apple's own, security software, or system extensions (only their app or System Settings can).
    public func canToggle(_ item: PluginItem) -> Bool {
        guard item.kind == .appExtension, !item.isApple, item.handling != .managed, item.isEnabled != nil,
            let identifier = item.bundleIdentifier
        else { return false }
        return identifier.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.\-_]*/) != nil
    }

    /// Tells macOS to use or ignore the extension (`pluginkit -e use|ignore`), then reads the list again.
    /// `true` when the new read shows the change.
    public func setEnabled(_ enabled: Bool, _ item: PluginItem) async -> Bool {
        guard canToggle(item), let identifier = item.bundleIdentifier else { return false }
        let command = Command(
            executable: "/usr/bin/pluginkit", arguments: ["-e", enabled ? "use" : "ignore", "-i", identifier],
            timeout: .seconds(15))
        guard let result = try? await runner.run(command), result.terminationReason == .exited,
            result.exitStatus == 0
        else { return false }
        await scan()
        return items.first { $0.id == item.id }?.isEnabled == enabled
    }

    // MARK: - Scanning

    public func scan() async {
        phase = .scanning
        let inventory = await reader.read(executor: executor)
        items = inventory.items
        issues = inventory.issues
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selection = selection.filter { itemsByID[$0]?.handling == .removable }
        regroup()
        refreshRunningApps()
        phase = .ready
    }

    // MARK: - Containing apps

    /// Re-reads which apps are open (call when an app launches or quits).
    public func refreshRunningApps() {
        let running = Set(apps.runningAppPaths().map(Self.normalized))
        if running != runningApps { runningApps = running }
        let stillFailed = failedPoliteQuits.intersection(running)
        if stillFailed != failedPoliteQuits { failedPoliteQuits = stillFailed }
    }

    /// The open app the item ships in, when it may be quit here: never for security or management software, nor
    /// for apps that are part of macOS (`/System`).
    public func runningApp(for item: PluginItem) -> String? {
        guard item.handling != .managed, let app = item.containingApp.map(Self.normalized),
            Self.isQuittable(app), runningApps.contains(app)
        else { return nil }
        return app
    }

    /// Whether the last polite quit of the app was refused, so Force Quit is the next step.
    public func needsForceQuit(_ appPath: String) -> Bool {
        failedPoliteQuits.contains(Self.normalized(appPath))
    }

    /// Asks an open app to quit (`force`: terminate it at once, unsaved work is lost). Only apps that are running and
    /// not part of macOS are asked. Returns whether the request was accepted; the app may take a moment to exit.
    @discardableResult
    public func quitApp(_ appPath: String, force: Bool) -> Bool {
        let app = Self.normalized(appPath)
        refreshRunningApps()
        guard Self.isQuittable(app), runningApps.contains(app) else { return false }
        let accepted = apps.quit(app, force)
        if !force, !accepted { failedPoliteQuits.insert(app) }
        if accepted { failedPoliteQuits.remove(app) }
        return accepted
    }

    private static func isQuittable(_ appPath: String) -> Bool {
        appPath.hasSuffix(".app") && !appPath.hasPrefix("/System/")
    }

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func regroup() {
        let visible = items.filter { showsAppleItems || !$0.isApple }
        let byKind = Dictionary(grouping: visible, by: \.kind)
        groups = PluginItem.Kind.allCases.compactMap { kind in
            guard let items = byKind[kind], !items.isEmpty else { return nil }
            let sorted = items.sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
            return Group(kind: kind, items: sorted)
        }
    }

    // MARK: - Selection

    /// Items the user could remove here, across all kinds.
    public var removableCount: Int { items.filter { $0.handling == .removable }.count }

    public var selectedCount: Int { selection.count }

    /// Estimated bytes the selection frees.
    public var selectedBytes: Int64 { selection.reduce(0) { $0 + (itemsByID[$1]?.size ?? 0) } }

    public func canSelect(_ item: PluginItem) -> Bool { item.handling == .removable }

    /// Selects or deselects one item; anything not removable (system, extensions, managed) cannot be selected.
    public func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else if let item = itemsByID[id], canSelect(item) {
            selection.insert(id)
        }
    }

    public func setSelected(_ selected: Bool, kind: PluginItem.Kind) {
        let ids = items.filter { $0.kind == kind && canSelect($0) }.map(\.id)
        if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    // MARK: - Removal

    /// Moves the selection to the Trash (or only checks it, when `dryRun`), then rescans.
    @discardableResult
    public func remove(dryRun: Bool = false) async -> CleanupSummary {
        let deletions = selection.sorted().compactMap { itemsByID[$0]?.deletionItem() }
        phase = .removing
        let results = await deleter.run(deletions, mode: .moveToTrash, dryRun: dryRun)
        let summary = CleanupSummary(results: results)
        lastSummary = summary
        if dryRun {
            phase = .ready
        } else {
            await scan()
        }
        return summary
    }
}
