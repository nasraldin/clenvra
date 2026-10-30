import AppKit
import ClenvraKit
import SwiftUI

/// The application pages: installed apps with uninstall-by-evidence, leftovers of apps already removed, and
/// extensions. Each is its own sidebar page.
enum ApplicationsPage: Hashable {
    case installed, leftovers, extensions
}

struct ApplicationsView: View {
    let session: AppsSession
    let plugins: PluginsSession
    let updates: UpdateCheckSession
    /// The "Check for app updates" setting; off by default, and nothing is contacted while it is off.
    let checksForUpdates: Bool
    let page: ApplicationsPage
    @State private var selectedID: String?
    /// The review opens when an app is chosen; until then the list has the whole page.
    @State private var showsDetail = false

    var body: some View {
        VStack(spacing: 0) { content }
            .toolbar {
                if page == .installed {
                    ToolbarItem {
                        CheckForUpdatesButton(session: session, updates: updates, isEnabled: checksForUpdates)
                    }
                    ToolbarItem {
                        InspectorToggle(isPresented: $showsDetail)
                    }
                }
            }
            .task {
                if session.phase == .idle { await session.load() }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard page == .installed,
                    let url = urls.first(where: { $0.pathExtension.lowercased() == "app" })
                else { return false }
                Task {
                    if await session.select(bundleURL: url) { selectedID = session.detail?.app.id }
                }
                return true
            }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .installed:
            // The list fills the page; the selected app's review is in the inspector, as on every other page.
            AppListView(
                session: session, updates: updates, showsUpdates: checksForUpdates, selectedID: $selectedID
            )
            .detailsPanel(isPresented: $showsDetail, width: 400) {
                AppDetailView(session: session, update: checksForUpdates ? selectedUpdate : nil)
            }
            .onChange(of: selectedID) { _, newValue in
                if newValue != nil { showsDetail = true }
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

/// Searchable table of installed apps, sortable by name, size and last use; sizes are measured as rows appear.
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
    @State private var sortOrder = [KeyPathComparator(\AppRow.name)]

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

    private var rows: [AppRow] {
        listedApps.map {
            AppRow(app: $0, size: session.size(of: $0), lastUsed: session.lastUsed(of: $0))
        }
        .sorted(using: sortOrder)
    }

    private func availableVersion(of app: InstalledApp) -> String? {
        guard showsUpdates, case .available(let version) = updates.results[app.id]?.status else { return nil }
        return version
    }

    var body: some View {
        table
            .pageState(isShown: listedApps.isEmpty) {
                if session.phase != .ready && session.apps.isEmpty {
                    ProgressView {
                        Text("Looking for apps…")
                    }
                } else if showsUpdatesOnly && showsUpdates {
                    ContentUnavailableView {
                        Label {
                            Text("No updates")
                        } icon: {
                            Image(systemName: "arrow.down.app")
                        }
                    } description: {
                        Text("Apps with a newer version appear here after you check for updates.")
                    }
                } else {
                    ContentUnavailableView {
                        Label {
                            Text("No apps")
                        } icon: {
                            Image(systemName: "app.dashed")
                        }
                    } description: {
                        Text("No apps match the current search or filter.")
                    }
                }
            }
            .searchable(text: $session.searchText, placement: .toolbar, prompt: Text("Search apps"))
            .toolbar {
                ToolbarItem {
                    filterMenu
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsUpdates, updates.phase != .idle {
                    UpdateCheckProgress(updates: updates)
                        .controlSize(.small)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .statusBarBackground()
                }
            }
            .onChange(of: sortOrder) {
                // Sorting by size needs every app measured, not only the visible ones.
                if sortOrder.first?.keyPath == \AppRow.size as AnyKeyPath { Task { await session.measureAll() } }
            }
    }

    private var table: some View {
        Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn(Text("Name"), value: \.name) { row in
                AppNameCell(app: row.app, availableVersion: availableVersion(of: row.app))
                    .task { await session.measure(row.app) }
            }
            .width(min: 160, ideal: 200)

            TableColumn(Text("Size"), value: \.size) { row in
                if row.size > 0 {
                    SizeText(bytes: row.size)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text("Unknown")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 60, ideal: 75)

            TableColumn(Text("Last Used"), value: \.lastUsed) { row in
                DateCell(date: row.lastUsed)
            }
            .width(min: 80, ideal: 95)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileActionsMenu(paths: ids.sorted())
            if ids.count == 1, let id = ids.first {
                Button {
                    NSWorkspace.shared.open(URL(filePath: id))
                } label: {
                    Text("Open")
                }
            }
        }
        // Two-line rows need no stripes, and grey version text on a grey stripe falls below readable contrast.
        .alternatingRowBackgrounds(.disabled)
        // The edge blur would fade the last visible row below readable contrast.
        .scrollEdgeEffectHidden(true, for: .bottom)
        .accessibilityLabel(Text(AppSection.applications.title))
        .accessibilityIdentifier("review.results")
    }

    /// Which apps the table lists, as a filter menu in the toolbar; the icon fills while a filter is on.
    private var filterMenu: some View {
        Menu {
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
            .pickerStyle(.inline)
        } label: {
            ToolbarLabel(
                title: "Show",
                symbol: listFilter.wrappedValue == .apps(.all)
                    ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuIndicator(.hidden)
        .help(Text("Choose which apps to list"))
        .accessibilityIdentifier("applications.filter")
    }
}

/// One installed app in the table. Plain data, so the table can sort by its key paths.
nonisolated struct AppRow: Identifiable, Sendable {
    let app: InstalledApp
    let name: String
    let size: Int64
    let lastUsed: Date
    var id: String { app.id }

    init(app: InstalledApp, size: Int64?, lastUsed: Date?) {
        self.app = app
        name = app.name
        self.size = size ?? 0
        self.lastUsed = lastUsed ?? .distantPast
    }
}

/// App icon, name, version and source; a newer version when the update check found one.
private struct AppNameCell: View {
    let app: InstalledApp
    var availableVersion: String?

    private var subtitle: String {
        let source = app.source.title.map { String(localized: $0) }
        return [app.version, source].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(path: app.id, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: app.name)
                    .lineLimit(1)
                // One text ("2.10 · Apple"), so it reads and is measured as one line rather than tiny fragments.
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let availableVersion {
                    UpdateBadge(version: availableVersion)
                }
            }
        }
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
        if let title = source.title { Text(title) }
    }
}

extension InstalledApp.Source {
    /// Where the app came from, or nil when unknown.
    var title: LocalizedStringResource? {
        switch self {
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .setapp: "Setapp"
        case .apple: "Apple"
        case .other: nil
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
