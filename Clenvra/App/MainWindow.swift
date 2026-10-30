import ClenvraKit
import SwiftUI

struct MainWindow: View {
    @Binding var selection: AppSection?
    let environment: AppEnvironment

    /// The sidebar shrinks to a strip of icons instead of disappearing (the toolbar button); View › Hide Sidebar
    /// still hides it completely.
    @SceneStorage("sidebar.compact") private var isCompact = false
    /// The page last shown in each group of sibling pages, so its sidebar row reopens it.
    @SceneStorage("sidebar.lastPages") private var lastPages = ""

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(AppSection.Group.allCases, id: \.self) { group in
                    if let title = group.title, !isCompact {
                        Section {
                            rows(in: group)
                        } header: {
                            Text(title)
                        }
                    } else {
                        Section {
                            rows(in: group)
                        }
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            // The sidebar never gives up width to the details panel: shrinking it when the panel opens looks like a flash.
            .navigationSplitViewColumnWidth(
                min: isCompact ? Self.compactWidth : Self.sidebarWidth,
                ideal: isCompact ? Self.compactWidth : Self.sidebarWidth,
                max: isCompact ? Self.compactWidth : 320)
        } detail: {
            if let selection {
                // The page title and the test identifier are set here, once for every page.
                VStack(spacing: 0) {
                    page(selection)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Room for a list and its details panel from the start. The panel sits inside this column, so if the
                // column's minimum grew when the panel opened, the window would take the width from the sidebar and
                // macOS 27 would collapse it for a moment.
                .navigationSplitViewColumnWidth(min: Self.pageMinimumWidth, ideal: 880)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(selection.title))
                .accessibilityIdentifier("section.\(selection.rawValue)")
                .navigationTitle(Text(selection.title))
                .toolbar {
                    // In the toolbar, as in Calendar's Day/Week/Month: a row under the toolbar would leave a blurred
                    // strip over the list on macOS 27.
                    if selection.siblings.count > 1 {
                        ToolbarItem(placement: .principal) {
                            switcher(for: selection)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { isCompact.toggle() }
                } label: {
                    Label {
                        Text(isCompact ? "Expand Sidebar" : "Collapse Sidebar")
                    } icon: {
                        Image(systemName: "sidebar.leading")
                    }
                }
                .help(Text(isCompact ? "Show the sidebar with names" : "Show only icons in the sidebar"))
                .accessibilityIdentifier("sidebar.toggle")
            }
        }
        .onChange(of: selection) { _, page in
            guard let page, page.siblings.count > 1 else { return }
            var pages = Self.decode(lastPages)
            pages[page.sidebarEntry.rawValue] = page.rawValue
            lastPages = Self.encode(pages)
        }
    }

    /// Wide enough for the window buttons above it.
    private static let compactWidth: CGFloat = 80
    private static let sidebarWidth: CGFloat = 220
    /// The widest list's minimum (about 540) plus a details panel's (240).
    private static let pageMinimumWidth: CGFloat = 780

    /// The sidebar selects a group of sibling pages by its first page; choosing it reopens the page last shown.
    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { selection?.sidebarEntry },
            set: { entry in
                guard let entry, entry != selection?.sidebarEntry else { return }
                let last = Self.decode(lastPages)[entry.rawValue].flatMap(AppSection.init(rawValue:))
                selection = last.flatMap { entry.siblings.contains($0) ? $0 : nil } ?? entry
            })
    }

    private func switcher(for page: AppSection) -> some View {
        Picker(selection: Binding(get: { page }, set: { selection = $0 })) {
            ForEach(page.siblings) { sibling in
                ToolbarLabel(title: sibling.switcherTitle, symbol: sibling.symbol)
                    .help(Text(sibling.title))
                    .tag(sibling)
            }
        } label: {
            Text(page.sidebarEntry.sidebarTitle)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("page.switcher")
    }

    private func rows(in group: AppSection.Group) -> some View {
        ForEach(AppSection.allCases.filter { $0.group == group && $0.sidebarEntry == $0 }) { section in
            Label {
                Text(section.sidebarTitle)
            } icon: {
                Image(systemName: section.sidebarSymbol)
            }
            .labelStyle(SidebarLabelStyle(isCompact: isCompact))
            .help(Text(section.sidebarTitle))
            .accessibilityLabel(Text(section.sidebarTitle))
            .tag(section)
            .accessibilityIdentifier("sidebar.\(section.rawValue)")
        }
    }

    private static func decode(_ text: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))) ?? [:]
    }

    private static func encode(_ pages: [String: String]) -> String {
        String(decoding: (try? JSONEncoder().encode(pages)) ?? Data(), as: UTF8.self)
    }

    @ViewBuilder private func page(_ section: AppSection) -> some View {
        switch section {
        case .overview:
            OverviewView(environment: environment, navigate: { selection = $0 })
        case .cleanup:
            CleanupView(environment: environment)
        case .developer:
            RuleReviewView(
                section: .developer, session: environment.developerSession,
                introduction:
                    "Find Xcode data, simulators, package caches and build folders in your projects. Your tools rebuild them when needed.",
                exclude: { environment.exclude($0) })
        case .developerTools:
            DeveloperToolsView(session: environment.toolSession)
        case .storage:
            storage(.browser)
        case .largeFiles:
            storage(.largeFiles)
        case .downloads:
            storage(.clutter)
        case .similarPhotos:
            storage(.similarPhotos)
        case .duplicates:
            DuplicatesView(session: environment.duplicatesSession)
        case .applications:
            applications(.installed)
        case .leftovers:
            applications(.leftovers)
        case .extensions:
            applications(.extensions)
        case .startup:
            StartupView(session: environment.startupSession, installedApps: environment.installedApps)
        case .system:
            system(.health)
        case .processes:
            system(.processes)
        case .security:
            system(.security)
        case .snapshots:
            system(.snapshots)
        case .activity:
            ActivityView(session: environment.activitySession)
        }
    }

    private func storage(_ page: StoragePage) -> some View {
        StorageView(
            session: environment.storageSession, similarPhotos: environment.similarPhotosSession, page: page,
            navigate: { selection = $0 }
        )
        .id(page)
    }

    private func applications(_ page: ApplicationsPage) -> some View {
        ApplicationsView(
            session: environment.appsSession, plugins: environment.pluginsSession, updates: environment.updateSession,
            checksForUpdates: environment.settings.checksForAppUpdates, page: page
        )
        .id(page)
    }

    private func system(_ page: SystemView.SystemTab) -> some View {
        SystemView(session: environment.systemSession, snapshots: environment.snapshotsSession, page: page)
            .id(page)
    }
}

/// Icon and name, or the icon alone, centred, when the sidebar is a strip of icons.
private struct SidebarLabelStyle: LabelStyle {
    let isCompact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if isCompact {
            configuration.icon
                .imageScale(.large)
                .frame(maxWidth: .infinity)
                // One element for the row, so it keeps its name and identifier without the title.
                .accessibilityElement(children: .ignore)
        } else {
            Label(configuration)
        }
    }
}
