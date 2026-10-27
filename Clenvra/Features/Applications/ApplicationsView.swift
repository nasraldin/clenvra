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
    @State private var tab = Tab.installed
    @State private var selectedID: String?

    init(session: AppsSession, plugins: PluginsSession) {
        self.session = session
        self.plugins = plugins
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
                AppListView(session: session, selectedID: $selectedID)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
                AppDetailView(session: session)
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
}

/// Searchable, sortable list of installed apps; sizes are measured as rows appear.
private struct AppListView: View {
    @Bindable var session: AppsSession
    @Binding var selectedID: String?

    var body: some View {
        Group {
            if session.phase != .ready && session.apps.isEmpty {
                ProgressView {
                    Text("Looking for apps…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.visibleApps.isEmpty {
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
                List(session.visibleApps, selection: $selectedID) { app in
                    AppRow(app: app, size: session.size(of: app), lastUsed: session.lastUsed(of: app))
                        .tag(app.id)
                        .task { await session.measure(app) }
                }
                .accessibilityIdentifier("review.results")
            }
        }
        .searchable(text: $session.searchText, placement: .sidebar, prompt: Text("Search apps"))
        .safeAreaInset(edge: .top) {
            HStack {
                Picker(selection: $session.filter) {
                    Text("All").tag(AppsSession.Filter.all)
                    Text("Unused for 6 Months").tag(AppsSession.Filter.unused)
                    Text("App Store").tag(AppsSession.Filter.appStore)
                    Text("Homebrew").tag(AppsSession.Filter.homebrew)
                } label: {
                    Text("Show")
                }
                Picker(selection: $session.sortOrder) {
                    Text("Name").tag(AppsSession.SortOrder.name)
                    Text("Size").tag(AppsSession.SortOrder.size)
                    Text("Last Used").tag(AppsSession.SortOrder.lastUsed)
                } label: {
                    Text("Sort By")
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
}

private struct AppRow: View {
    let app: InstalledApp
    let size: Int64?
    let lastUsed: Date?

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
        let homebrew = ToolLocator(searchPath: ToolLocator.fallbackSearchPath).locate("brew").map {
            AppsSession.Homebrew(brew: $0, runner: ProcessCommandRunner())
        }
        return AppsSession(
            home: environment.home, policy: policy,
            deleter: environment.makeDeleter(ownerState: ownerStateByID),
            log: environment.activityLog,
            resolver: OwnershipResolver(
                home: environment.home, policy: policy,
                receipts: OwnershipResolver.pkgutilReceipts(runner: ProcessCommandRunner())),
            discover: { @MainActor in
                await environment.loadInstalledApps()
                return environment.installedApps
            },
            ownerState: { app in RunningApps.state(of: app, ownership: ownership) },
            requestQuit: { app in await RunningApps.requestQuit(app) },
            homebrew: homebrew)
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
