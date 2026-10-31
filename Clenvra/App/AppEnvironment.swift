import AppKit
import ClenvraKit
import Foundation
import Synchronization

/// Long-lived services shared by every section. Created once at launch.
@MainActor
@Observable
final class AppEnvironment {
    /// Canonical home folder (no symlinks), as the deletion gate requires.
    let home: String
    let activityLog: ActivityLog
    let ownership = OwnershipProvider()
    /// Read by every deletion gate on every check, so new exclusions apply immediately.
    let policyProvider: PolicyProvider

    private(set) var settings: UserSettings
    /// The menu bar extra, a per-Mac preference. Kept here, not in `@AppStorage`: macOS writes the status item's own
    /// visibility to the same defaults, and an `@AppStorage` binding on `MenuBarExtra` rebuilds the scenes on that
    /// write, which writes again: an endless redraw loop at launch.
    var showsMenuBarExtra = UserDefaults.standard.bool(forKey: MenuBarExtraView.preferenceKey) {
        didSet { UserDefaults.standard.set(showsMenuBarExtra, forKey: MenuBarExtraView.preferenceKey) }
    }
    let settingsStore: SettingsStore
    private(set) var installedApps: [InstalledApp] = []
    /// The optional privileged helper. Every call is pinned to its signature; sessions use it only when available.
    let helper = HelperClient()
    /// Installed, approved, and answering with this version's protocol.
    private(set) var helperAvailable = false
    /// Available once the login-shell PATH is known (tools from Homebrew, nvm, volta… live there).
    private(set) var toolSession: ToolStorageSession?

    @ObservationIgnored private(set) lazy var cleanupSession = makeSession(for: .cleanup)
    @ObservationIgnored private(set) lazy var developerSession = makeSession(for: .developer)
    @ObservationIgnored private(set) lazy var storageSession = StorageView.makeSession(environment: self)
    @ObservationIgnored private(set) lazy var duplicatesSession = DuplicatesSession.live(environment: self)
    @ObservationIgnored private(set) lazy var similarPhotosSession = SimilarPhotosSession.live(environment: self)
    @ObservationIgnored private(set) lazy var appsSession = ApplicationsServices.makeSession(environment: self)
    /// Homebrew, when installed; shared by uninstall (`brew uninstall`) and the update check (`brew outdated`).
    @ObservationIgnored private(set) lazy var homebrew = ApplicationsServices.locateHomebrew()
    /// Contacts the network only while "Check for app updates" is on (D5); the setting is read before every step.
    @ObservationIgnored private(set) lazy var updateSession = UpdateCheckSession(
        isEnabled: { [weak self] in self?.settings.checksForAppUpdates ?? false }, fetcher: URLSessionFetcher(),
        homebrew: homebrew)
    /// Quitting goes through `NSRunningApplication` only, so it can affect regular apps but never system processes.
    @ObservationIgnored private(set) lazy var systemSession = SystemSession(
        politeTerminator: { pid in NSRunningApplication(processIdentifier: pid)?.terminate() ?? false },
        forceTerminator: { pid in NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false })
    /// Plug-in bundles are not apps, so no owner check applies; the gate still checks identity and protection.
    @ObservationIgnored private(set) lazy var pluginsSession = PluginsSession(
        reader: PluginReader(home: home), deleter: makeDeleter { _ in .notRunning }, apps: .live)
    @ObservationIgnored private(set) lazy var activitySession = ActivitySession(
        activityLog: activityLog, reenabler: LaunchAgentReenabler(runner: ProcessCommandRunner()), privileged: helper)
    @ObservationIgnored private(set) lazy var startupSession = StartupSession(
        reader: LaunchItemReader(), runner: ProcessCommandRunner(),
        deleter: makeDeleter { _ in .notRunning }, privileged: helper)
    /// Disk images, other drives and network shares; ejecting runs off the main thread (it waits for the disk).
    @ObservationIgnored private(set) lazy var mountedDisksSession = MountedDisksSession(eject: { url in
        try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }.value
    })
    /// Reads the privacy databases read-only; revoking goes through Apple's `tccutil` only.
    @ObservationIgnored private(set) lazy var permissionsSession = PermissionsSession(runner: ProcessCommandRunner())
    @ObservationIgnored private(set) lazy var scheduler = ScanScheduler(environment: self)
    /// Browser history, cookies, sessions and site data: explicit opt-in per type, never while the browser is open.
    @ObservationIgnored private(set) lazy var browserDataSession = makeBrowserDataSession()
    @ObservationIgnored private(set) lazy var snapshotsSession = SnapshotsSession(
        runner: ProcessCommandRunner(), privileged: helper)

    init() {
        home = Self.canonicalHome()
        let support = URL.applicationSupportDirectory.appending(path: "Clenvra", directoryHint: .isDirectory)
        activityLog = ActivityLog(directory: support.appending(path: "Activity", directoryHint: .isDirectory))
        settingsStore = SettingsStore(file: support.appending(path: "settings.json"), home: home)
        let settings = settingsStore.load()
        self.settings = settings
        policyProvider = PolicyProvider(ProtectionPolicy(home: home, exclusions: settings.exclusions))
    }

    /// Saves new settings and applies them to every deletion gate immediately.
    func apply(_ newSettings: UserSettings) throws {
        try settingsStore.save(newSettings)
        let rulesChanged = settings.customRules != newSettings.customRules
        settings = newSettings
        policyProvider.update(ProtectionPolicy(home: home, exclusions: newSettings.exclusions))
        if rulesChanged { cleanupSession.setRules(cleanupRules) }
    }

    /// The one way sections get a deleter: always the live rules, always the shared activity log.
    func makeDeleter(ownerState: @escaping @Sendable (String) -> OwnerState) -> DeletionExecutor {
        DeletionExecutor(gate: DeletionGate(policyProvider: policyProvider, ownerState: ownerState), log: activityLog)
    }

    var policy: ProtectionPolicy { policyProvider.current }

    /// Where apps are backed up before removal: the folder chosen in Settings › Applications, or
    /// `~/Documents/Clenvra Backups`.
    var appBackupFolder: URL {
        settings.appBackupFolder.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? AppBackup.defaultFolder(home: home)
    }

    /// Loads the installed-app list used to decide whether an item's owner is running.
    func loadInstalledApps() async {
        installedApps = await AppInventory.discover()
        ownership.update(apps: installedApps)
    }

    /// Resolves where developer tools live, once per launch.
    func prepareTools() async {
        let runner = ProcessCommandRunner()
        let searchPath = await ToolLocator.resolveLoginPath(runner: runner)
        toolSession = ToolStorageSession(
            locator: ToolLocator(searchPath: searchPath + ToolLocator.fallbackSearchPath), runner: runner, home: home,
            log: activityLog)
    }

    /// Asks the helper for its protocol version and tells every section whether system items can be removed.
    /// Adds a folder or file to Settings › Exclusions; scans skip it from now on.
    func exclude(_ path: String) {
        var updated = settings
        guard !updated.exclusions.contains(path) else { return }
        updated.exclusions.append(path)
        try? apply(updated)
    }

    func refreshHelper() async {
        let available = (try? await helper.protocolVersion()) == HelperIdentity.protocolVersion
        helperAvailable = available
        cleanupSession.helperAvailable = available
        startupSession.helperAvailable = available
        appsSession.helperAvailable = available
        snapshotsSession.helperAvailable = available
    }

    /// Cleanup's rules: the catalog, the system rules (through the helper) and the user's own review-only rules.
    private var cleanupRules: [CleanupRule] {
        RuleCatalog.standard.filter { !$0.category.isDeveloper } + RuleCatalog.system(root: "/")
            + settings.customRules.map(\.cleanupRule)
    }

    private func makeSession(for section: ActivityRecord.Section) -> CleanupSession {
        let rules =
            section == .cleanup ? cleanupRules : RuleCatalog.standard.filter { $0.category.isDeveloper }
        let policy = policy
        let ownerState: @Sendable (String) -> OwnerState = { [ownership] in ownership.state(of: $0) }
        var extraRules: @Sendable () -> [CleanupRule] = { [] }
        if section == .cleanup { extraRules = OtherDriveTrash.rules }
        return CleanupSession(
            rules: rules, section: section, home: home, policy: policy, ownerState: ownerState,
            deleter: makeDeleter(ownerState: ownerState), privileged: helper,
            ownerBundlePath: { [ownership] in ownership.bundlePath(of: $0) }, extraRules: extraRules)
    }

    private func makeBrowserDataSession() -> BrowserDataSession {
        let ownerState: @Sendable (String) -> OwnerState = { [ownership] in ownership.state(of: $0) }
        return BrowserDataSession(
            home: home, policy: policy, ownerState: ownerState, deleter: makeDeleter(ownerState: ownerState))
    }

    private static func canonicalHome() -> String {
        let home = NSHomeDirectory()
        guard let resolved = realpath(home, nil) else { return home }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Thread-safe holder of the current owner-activity checker. Until the app inventory has loaded, every owner is
/// "unknown", which the deletion gate treats as running — nothing owned by an app is removed before we can tell.
nonisolated final class OwnershipProvider: Sendable {
    private let activity = Mutex<OwnerActivity?>(nil)
    private let paths = Mutex<[String: String]>([:])

    func update(apps: [InstalledApp]) {
        var paths: [String: String] = [:]
        for app in apps {
            for identifier in [app.bundleIdentifier].compactMap({ $0 }) + app.embeddedBundleIdentifiers {
                paths[identifier] = app.id
            }
        }
        activity.withLock { $0 = OwnerActivity(bundlePaths: paths) }
        self.paths.withLock { $0 = paths }
    }

    /// Where an app with this bundle identifier is installed, so the helper can check it is not running.
    func bundlePath(of bundleIdentifier: String) -> String? {
        paths.withLock { $0[bundleIdentifier] }
    }

    func state(of bundleIdentifier: String) -> OwnerState {
        activity.withLock { $0 }?.state(of: bundleIdentifier) ?? .unknown
    }
}

/// The Trash of every other writable drive mounted right now, read again at every Cleanup scan. The startup disk's
/// Trash is `~/.Trash`; disk images, network shares and read-only drives get no rule.
nonisolated enum OtherDriveTrash {
    @Sendable static func rules() -> [CleanupRule] {
        let roots = VolumeInventory.mountedVolumes()
            .filter { !$0.isRoot && !$0.isReadOnly && ($0.kind == .internal || $0.kind == .external) }
            .map(\.id.path)
        return RuleCatalog.volumeTrash(volumeRoots: roots, uid: getuid())
    }
}

extension CleanupCategory {
    /// Developer-tool categories live in the Developer section; the rest in Cleanup.
    var isDeveloper: Bool { section == .developer }
}
