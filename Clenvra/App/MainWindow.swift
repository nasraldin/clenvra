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
    /// Opens a page from a search result with the query to show there.
    @State private var searchRouter = SearchRouter()

    var body: some View {
        NavigationSplitView {
            Group {
                if isCompact {
                    CompactSidebar(selection: sidebarSelection)
                } else {
                    List(selection: sidebarSelection) {
                        ForEach(AppSection.Group.allCases, id: \.self) { group in
                            if let title = group.title {
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
                // A new toolbar for each group of pages: moving from Developer (two tabs) to Clutter (four) otherwise
                // keeps the old item widths on macOS 27, and the switcher overlaps the page's buttons.
                .id(selection.sidebarEntry)
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
                // After the page's own items, so search is the last icon at the right on every page.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if let prompt = searchRouter.pagePrompt {
                            ToolbarSearch(text: $searchRouter.pageText, prompt: prompt)
                                // A fresh, closed search on each page.
                                .id(selection)
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
        .environment(searchRouter)
        .onChange(of: searchRouter.generation) {
            if let section = searchRouter.requestedSection { selection = section }
        }
        .onChange(of: selection) { _, page in
            guard let page, page.siblings.count > 1 else { return }
            var pages = Self.decode(lastPages)
            pages[page.sidebarEntry.rawValue] = page.rawValue
            lastPages = Self.encode(pages)
        }
    }

    /// Wide enough for the close, minimize and zoom buttons above it, with a margin on each side.
    private static let compactWidth: CGFloat = 100
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
            SidebarRow(section: section)
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
        case .disks:
            DisksView(session: environment.mountedDisksSession)
        case .largeFiles:
            storage(.largeFiles)
        case .downloads:
            storage(.clutter)
        case .similarPhotos:
            storage(.similarPhotos)
        case .otherClutter:
            storage(.otherClutter)
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
        case .permissions:
            PermissionsView(session: environment.permissionsSession)
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
            checksForUpdates: environment.settings.checksForAppUpdates, backupFolder: environment.appBackupFolder,
            page: page
        )
        .id(page)
    }

    private func system(_ page: SystemView.SystemTab) -> some View {
        SystemView(session: environment.systemSession, snapshots: environment.snapshotsSession, page: page)
            .id(page)
    }
}

/// Icon and name, or the icon alone, centred, when the sidebar is a strip of icons.
/// A row of the sidebar with names: a slightly larger icon and a light highlight under the pointer. No tooltip:
/// the name is already shown.
private struct SidebarRow: View {
    let section: AppSection
    @State private var isHovered = false

    var body: some View {
        Label {
            Text(section.sidebarTitle)
        } icon: {
            Image(systemName: section.sidebarSymbol)
                .font(.system(size: 15))
                .frame(width: 22)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.07) : .clear)
                .padding(.horizontal, 10)
        )
        .accessibilityLabel(Text(section.sidebarTitle))
    }
}

/// The sidebar as a strip of icons: a rounded accent tile for the page shown, a light one under the pointer, and
/// the page name as a tooltip. Up and down arrows move between pages as in the list.
private struct CompactSidebar: View {
    @Binding var selection: AppSection?
    @State private var hovered: AppSection?
    @FocusState private var isFocused: Bool

    private var entries: [[AppSection]] {
        AppSection.Group.allCases.map { group in
            AppSection.allCases.filter { $0.group == group && $0.sidebarEntry == $0 }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Divider()
                            .frame(width: 32)
                            .padding(.vertical, 6)
                    }
                    ForEach(group) { section in
                        tile(section)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
    }

    private func tile(_ section: AppSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            Image(systemName: section.sidebarSymbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 44, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(
                            isSelected
                                ? Color.accentColor
                                : hovered == section ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? section : (hovered == section ? nil : hovered) }
        .help(Text(section.sidebarTitle))
        .accessibilityLabel(Text(section.sidebarTitle))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
    }

    private func move(by step: Int) -> KeyPress.Result {
        let all = entries.flatMap { $0 }
        guard let current = selection.flatMap(all.firstIndex(of:)) else { return .ignored }
        let next = current + step
        guard all.indices.contains(next) else { return .handled }
        selection = all[next]
        return .handled
    }
}
