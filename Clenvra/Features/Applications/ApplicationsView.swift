import AppKit
import ClenvraKit
import SwiftUI

/// Applications: installed apps with uninstall-by-evidence, leftovers of apps already removed, and extensions.
struct ApplicationsView: View {
    private enum Tab: Hashable {
        case installed
        case leftovers
        case extensions
    }

    let session: AppsSession
    let plugins: PluginsSession
    let updates: UpdateCheckSession
    /// The "Check for app updates" setting; off by default, and nothing is contacted while it is off.
    let checksForUpdates: Bool
    @State private var tab = Tab.installed
    @State private var selectedID: String?

    init(session: AppsSession, plugins: PluginsSession, updates: UpdateCheckSession, checksForUpdates: Bool) {
        self.session = session
        self.plugins = plugins
        self.updates = updates
        self.checksForUpdates = checksForUpdates
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("section.applications")
            .navigationTitle(Text(AppSection.applications.title))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker(selection: $tab) {
                        Text("Installed").tag(Tab.installed)
                        Text("Leftovers").tag(Tab.leftovers)
                        Text("Extensions").tag(Tab.extensions)
                    } label: {
                        Text("View")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if tab == .installed {
                    ToolbarItem {
                        CheckForUpdatesButton(session: session, updates: updates, isEnabled: checksForUpdates)
                    }
                }
            }
            .task {
                if session.phase == .idle { await session.load() }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else { return false }
                Task {
                    if await session.select(bundleURL: url) {
                        tab = .installed
                        selectedID = session.detail?.app.id
                    }
                }
                return true
            }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .installed:
            HSplitView {
                AppListView(
                    session: session, updates: updates, showsUpdates: checksForUpdates, selectedID: $selectedID
                )
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
                AppDetailView(session: session, update: checksForUpdates ? selectedUpdate : nil)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: selectedID) { _, newValue in
                Task { await session.select(newValue) }
            }
        case .leftovers:
            LeftoversView(session: session)
        case .extensions:
            PluginsView(session: plugins)
        }
    }

    private var selectedUpdate: AppUpdate? {
        session.detail.flatMap { updates.results[$0.app.id] }
    }
}

/// Searchable, sortable list of installed apps; sizes are measured as rows appear.
private struct AppListView: View {
    /// The engine's filters plus "apps with an update", which the update check provides.
    private enum ListFilter: Hashable {
        case apps(AppsSession.Filter)
        case updates
    }

    @Bindable var session: AppsSession
    let updates: UpdateCheckSession
    /// Update results are shown only while update checks are allowed.
    let showsUpdates: Bool
    @Binding var selectedID: String?
    @State private var showsUpdatesOnly = false

    private var listFilter: Binding<ListFilter> {
        Binding(
            get: { showsUpdatesOnly && showsUpdates ? .updates : .apps(session.filter) },
            set: { newValue in
                switch newValue {
                case .apps(let filter):
                    showsUpdatesOnly = false
                    session.filter = filter
                case .updates:
                    showsUpdatesOnly = true
                    session.filter = .all
                }
            })
    }

    private var listedApps: [InstalledApp] {
        guard showsUpdatesOnly && showsUpdates else { return session.visibleApps }
        return session.visibleApps.filter { availableVersion(of: $0) != nil }
    }

    private func availableVersion(of app: InstalledApp) -> String? {
        guard showsUpdates, case .available(let version) = updates.results[app.id]?.status else { return nil }
        return version
    }

    var body: some View {
        Group {
            if session.phase != .ready && session.apps.isEmpty {
                ProgressView {
                    Text("Looking for apps…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listedApps.isEmpty, showsUpdatesOnly && showsUpdates {
                ContentUnavailableView {
                    Label {
                        Text("No updates")
                    } icon: {
                        Image(systemName: "arrow.down.app")
                    }
                } description: {
                    Text("Apps with a newer version appear here after you check for updates.")
                }
            } else if listedApps.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No apps")
                    } icon: {
                        Image(systemName: "app.dashed")
                    }
                } description: {
                    Text("No apps match the current search or filter.")
                }
            } else {
                List(listedApps, selection: $selectedID) { app in
                    AppRow(
                        app: app, size: session.size(of: app), lastUsed: session.lastUsed(of: app),
                        availableVersion: availableVersion(of: app)
                    )
                    .tag(app.id)
                    .task { await session.measure(app) }
                }
                .accessibilityIdentifier("review.results")
            }
        }
        .searchable(text: $session.searchText, placement: .sidebar, prompt: Text("Search apps"))
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                HStack {
                    filterPicker
                    sortPicker
                }
                if showsUpdates {
                    UpdateCheckProgress(updates: updates)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .task(id: session.sortOrder) {
            if session.sortOrder == .size { await session.measureAll() }
        }
    }

    private var filterPicker: some View {
        Picker(selection: listFilter) {
            Text("All").tag(ListFilter.apps(.all))
            Text("Unused for 6 Months").tag(ListFilter.apps(.unused))
            Text("App Store").tag(ListFilter.apps(.appStore))
            Text("Homebrew").tag(ListFilter.apps(.homebrew))
            if showsUpdates {
                Text("Updates").tag(ListFilter.updates)
            }
        } label: {
            Text("Show")
        }
    }

    private var sortPicker: some View {
        Picker(selection: $session.sortOrder) {
            Text("Name").tag(AppsSession.SortOrder.name)
            Text("Size").tag(AppsSession.SortOrder.size)
            Text("Last Used").tag(AppsSession.SortOrder.lastUsed)
        } label: {
            Text("Sort By")
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let size: Int64?
    let lastUsed: Date?
    /// The newer version, when the update check found one.
    var availableVersion: String?

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.id, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: app.name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let version = app.version {
                        Text(verbatim: version)
                    }
                    SourceBadge(source: app.source)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let availableVersion {
                    UpdateBadge(version: availableVersion)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let size {
                    SizeText(bytes: size)
                } else {
                    Text(verbatim: "—").foregroundStyle(.tertiary)
                }
                if let lastUsed {
                    Text(lastUsed, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The app's Finder icon, loaded from the bundle on demand.
struct AppIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Where the app came from, as text (icons alone are not enough).
struct SourceBadge: View {
    let source: InstalledApp.Source

    var body: some View {
        switch source {
        case .appStore: Text("App Store")
        case .homebrew: Text("Homebrew")
        case .setapp: Text("Setapp")
        case .apple: Text("Apple")
        case .other: EmptyView()
        }
    }
}

/// Builds the session's dependencies from the app environment; kept apart so the view stays declarative.
enum ApplicationsServices {
    static func makeSession(environment: AppEnvironment) -> AppsSession {
        let policy = environment.policy
        let ownership = environment.ownership
        let ownerStateByID: @Sendable (String) -> OwnerState = { ownership.state(of: $0) }
        return AppsSession(
            home: environment.home, policy: policy,
            deleter: environment.makeDeleter(ownerState: ownerStateByID),
            log: environment.activityLog,
            resolver: OwnershipResolver(
                home: environment.home, policy: policy,
                receipts: OwnershipResolver.pkgutilReceipts(runner: ProcessCommandRunner())),
            privileged: environment.helper,
            discover: { @MainActor in
                await environment.loadInstalledApps()
                return environment.installedApps
            },
            ownerState: { app in RunningApps.state(of: app, ownership: ownership) },
            requestQuit: { app in await RunningApps.requestQuit(app) },
            homebrew: environment.homebrew)
    }

    /// The `brew` executable, when Homebrew is installed.
    static func locateHomebrew() -> AppsSession.Homebrew? {
        ToolLocator(searchPath: ToolLocator.fallbackSearchPath).locate("brew").map {
            AppsSession.Homebrew(brew: $0, runner: ProcessCommandRunner())
        }
    }
}

/// Running-state checks and polite quit requests, via AppKit plus the process list.
nonisolated enum RunningApps {
    static func state(of app: InstalledApp, ownership: OwnershipProvider) -> OwnerState {
        if let identifier = app.bundleIdentifier {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty { return .running }
            return ownership.state(of: identifier)
        }
        return OwnerActivity(bundlePaths: [app.id: app.id]).state(of: app.id)
    }

    /// Sends the standard quit request, so the app can ask to save documents; never force-quits.
    @MainActor static func requestQuit(_ app: InstalledApp) {
        let prefix = app.id + "/"
        for running in NSWorkspace.shared.runningApplications {
            let path = running.bundleURL?.path(percentEncoded: false) ?? ""
            let matches =
                (app.bundleIdentifier != nil && running.bundleIdentifier == app.bundleIdentifier)
                || path == app.id || path.hasPrefix(prefix)
            if matches { running.terminate() }
        }
    }
}
