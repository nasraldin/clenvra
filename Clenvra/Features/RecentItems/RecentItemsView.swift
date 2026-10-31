import AppKit
import ClenvraKit
import SwiftUI

/// Recent Items: the Apple menu's lists and Finder's Recent Folders ("Mac"), or each app's File › Open Recent list
/// ("Apps"), in collapsible groups with a checkbox per list. Nothing is chosen automatically.
struct RecentItemsView: View {
    enum Page { case mac, apps }

    let session: RecentItemsSession
    let page: Page

    @State private var highlighted: Set<RecentRow.ID> = []
    @State private var searchText = ""
    private var query: String { AppSearch.normalized(searchText) }
    @State private var isConfirming = false
    @State private var message: LocalizedStringResource?
    /// Bundle identifiers of the apps open now; their lists cannot be cleared.
    @State private var openApps: Set<String> = []
    private let groups: ExpandedGroups

    init(session: RecentItemsSession, page: Page) {
        self.session = session
        self.page = page
        groups = ExpandedGroups(page == .mac ? "recentItems" : "appRecentItems", opensByDefault: false)
    }

    private var section: AppSection { page == .mac ? .recentItems : .appRecentItems }

    var body: some View {
        let shown = visibleGroups
        // A new table whenever rows come or go (after Clear, Refresh or a search) instead of SwiftUI changing the old
        // one in place: on macOS 27 that crashed when a list with highlighted rows went away. Open groups are kept
        // in scene storage, so they survive.
        let rowIDs = shown.flatMap { [$0.id] + $0.children.map(\.id) }
        table(shown)
            .id(rowIDs)
            .onChange(of: rowIDs) { highlighted = [] }
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(section.title))
            .pageState(isShown: visibleGroups.isEmpty) { state }
            .pageSearch(text: $searchText, prompt: "Search Recent Items", section: section)
            .toolbar { toolbar }
            .confirmationDialog(confirmationTitle, isPresented: $isConfirming) {
                Button(role: .destructive) {
                    clear()
                } label: {
                    Text("Clear")
                }
            } message: {
                Text(confirmationMessage)
            }
            .alert(
                Text(section.title),
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button {
                    message = nil
                } label: {
                    Text("OK")
                }
            } message: {
                if let message { Text(message) }
            }
            // Reading the lists is instant and changes nothing.
            .task { await reload() }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            ) { _ in
                refreshOpenApps()
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            ) { _ in
                refreshOpenApps()
            }
    }

    @ViewBuilder private var state: some View {
        if session.isLoading {
            ProgressView {
                Text("Reading recent items…")
            }
        } else if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label {
                    Text("Nothing recent")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } description: {
                page == .mac
                    ? Text("The Apple menu’s Recent Items and Finder’s Recent Folders are empty.")
                    : Text("No app has a list of recently opened documents.")
            }
        }
    }

    // MARK: - Table

    private func table(_ visibleGroups: [RecentRow]) -> some View {
        Table(of: RecentRow.self, selection: $highlighted) {
            TableColumn(Text("Name")) { row in
                HStack(spacing: 6) {
                    checkbox(for: row)
                    RecentNameCell(row: row)
                }
            }
            .width(min: 240, ideal: 360)

            TableColumn(Text("Items")) { row in
                if row.isGroup {
                    HStack(spacing: 8) {
                        Text("\(row.count) items")
                            .foregroundStyle(.secondary)
                        if let app = row.app, openApps.contains(app) {
                            Label {
                                Text("Open: quit it to clear")
                            } icon: {
                                Image(systemName: "app.badge")
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                } else if let path = row.path {
                    PathText(path: (path as NSString).deletingLastPathComponent)
                } else if let list = row.list {
                    Text(list.title)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 160, ideal: 320)
        } rows: {
            ForEach(visibleGroups) { group in
                DisclosureTableRow(group, isExpanded: groups.binding(group.id) { visibleGroups.map(\.id) }) {
                    ForEach(group.children) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: RecentRow.ID.self) { ids in
            contextMenu(for: ids)
        }
        .disabled(session.isWorking)
    }

    @ViewBuilder private func checkbox(for row: RecentRow) -> some View {
        if let list = row.list, row.isGroup {
            Toggle(
                isOn: Binding(
                    get: { session.selectedLists.contains(list) },
                    set: { session.setSelected($0, list: list) })
            ) {
                Text("Include \(row.title)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
        } else if let app = row.app, row.isGroup {
            Toggle(
                isOn: Binding(
                    get: { session.selectedApps.contains(app) },
                    set: { if $0 != session.selectedApps.contains(app) { session.toggleApp(app) } })
            ) {
                Text("Include \(row.title)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(openApps.contains(app))
        }
    }

    @ViewBuilder private func contextMenu(for ids: Set<RecentRow.ID>) -> some View {
        let rows = visibleGroups.flatMap { [$0] + $0.children }.filter { ids.contains($0.id) }
        let paths = rows.compactMap(\.path)
        if !paths.isEmpty {
            FileActionsMenu(paths: paths) {}
        }
        let open = Set(rows.compactMap(\.app)).intersection(openApps)
        ForEach(open.sorted(), id: \.self) { app in
            Button {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: app) {
                    running.terminate()
                }
            } label: {
                Text("Quit \(RecentRow.appName(app))")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await reload() }
            } label: {
                ToolbarLabel(title: "Refresh", symbol: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Read the recent items again (⌘R)"))
            .disabled(session.isLoading || session.isWorking)

            ExpandAllButton(allExpanded: groups.allBinding(visibleGroups.map(\.id)))
                .disabled(visibleGroups.isEmpty)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            PrimaryActionButton(
                title: "Clear…", symbol: "clock.badge.xmark",
                help: "Review and clear the selected lists (⌘⌫)",
                isDisabled: session.isWorking || (page == .mac ? session.selectedLists.isEmpty : clearableApps.isEmpty)
            ) {
                isConfirming = true
            }
        }
    }

    // MARK: - Clearing

    private var clearableApps: Set<String> { session.selectedApps.subtracting(openApps) }

    private var confirmationTitle: Text {
        page == .mac
            ? Text("Clear \(session.selectedLists.count) lists?")
            : Text("Clear the recent documents of \(clearableApps.count) apps?")
    }

    private var confirmationMessage: LocalizedStringResource {
        if page == .apps {
            return "The documents stay where they are; only the apps’ lists go to the Trash."
        }
        if session.selectedLists.contains(.finderFolders) {
            if LiveRecentListStore.openFinderWindows() > 0 {
                return
                    "The documents and folders stay where they are; only the lists are emptied. To clear Recent Folders, Finder quits and opens again. It reopens its windows, and their folders are listed again: close Finder’s windows first to clear them too."
            }
            return
                "The documents and folders stay where they are; only the lists are emptied. To clear Recent Folders, Finder quits and opens again."
        }
        return "The documents and apps stay where they are; only the lists are emptied, as with Clear Menu."
    }

    private func clear() {
        highlighted = []
        Task {
            if page == .mac {
                let includesFinder = session.selectedLists.contains(.finderFolders)
                let failed = await session.clearSelectedLists()
                if failed.isEmpty, includesFinder, !session.names(in: .finderFolders).isEmpty {
                    message = "Cleared. Finder reopened its windows, so their folders are listed again."
                } else if failed.isEmpty {
                    message = "The lists are empty now."
                } else {
                    message =
                        "Some lists could not be cleared. Try again, or use Clear Menu in the Apple menu or Finder’s Go menu."
                }
            } else {
                session.setSelectedApps(clearableApps)
                let summary = await session.clearSelectedApps()
                let kept = summary.problems.count
                if kept == 0 {
                    message = "Cleared. The lists are in the Trash, so you can put them back."
                } else {
                    message = "\(kept) lists were kept, because their app is open or the list changed."
                }
            }
            refreshOpenApps()
        }
    }

    private func reload() async {
        refreshOpenApps()
        await session.load()
    }

    private func refreshOpenApps() {
        let open = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if open != openApps { openApps = open }
    }

    // MARK: - Rows

    private var visibleGroups: [RecentRow] {
        let all: [RecentRow] =
            page == .mac
            ? RecentList.allCases.compactMap { list in
                let names = session.names(in: list)
                return names.isEmpty ? nil : RecentRow(list: list, names: names)
            }
            : session.appLists.map(RecentRow.init(app:))
        guard !query.isEmpty else { return all }
        return all.compactMap { $0.filtered(by: query) }
    }
}

/// A list (with its entries as children) or one entry.
nonisolated struct RecentRow: Identifiable, Sendable {
    let id: String
    let title: String
    let list: RecentList?
    /// The app whose list this is, for the Apps page.
    let app: String?
    /// A document's recorded path.
    let path: String?
    let isGroup: Bool
    let children: [RecentRow]
    var count: Int { children.count }

    init(list: RecentList, names: [String]) {
        id = "list:" + list.rawValue
        title = String(localized: list.title)
        self.list = list
        app = nil
        path = nil
        isGroup = true
        children = names.enumerated().map { index, name in
            RecentRow(id: "list:\(list.rawValue):\(index):\(name)", title: name, path: nil, list: list)
        }
    }

    init(app list: AppRecentList) {
        id = "app:" + list.bundleIdentifier
        title = Self.appName(list.bundleIdentifier)
        self.list = nil
        app = list.bundleIdentifier
        path = nil
        isGroup = true
        children = list.documents.enumerated().map { index, path in
            RecentRow(
                id: "app:\(list.bundleIdentifier):\(index):\(path)", title: (path as NSString).lastPathComponent,
                path: path,
                list: nil)
        }
    }

    private init(id: String, title: String, path: String?, list: RecentList?) {
        self.id = id
        self.title = title
        self.list = list
        app = nil
        self.path = path
        isGroup = false
        children = []
    }

    private init(copy row: RecentRow, children: [RecentRow]) {
        id = row.id
        title = row.title
        list = row.list
        app = row.app
        path = row.path
        isGroup = row.isGroup
        self.children = children
    }

    /// The group whole when its own name matches, otherwise only the matching entries.
    func filtered(by query: String) -> RecentRow? {
        if AppSearch.matches(query, any: [title, app]) { return self }
        let matching = children.filter { AppSearch.matches(query, any: [$0.title, $0.path]) }
        return matching.isEmpty ? nil : RecentRow(copy: self, children: matching)
    }

    /// The installed app's name, or its bundle identifier when it is not installed.
    static func appName(_ bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "")
    }
}

private struct RecentNameCell: View {
    let row: RecentRow

    var body: some View {
        if row.isGroup {
            Label {
                Text(verbatim: row.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            } icon: {
                if let app = row.app {
                    Image(nsImage: Self.icon(for: app))
                        .resizable()
                        .frame(width: 16, height: 16)
                } else if let list = row.list {
                    Image(systemName: list.symbol)
                }
            }
        } else {
            FileNameCell(name: row.title, path: row.path)
        }
    }

    private static func icon(for bundleIdentifier: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return IconCache.shared.icon(forFile: url.path(percentEncoded: false))
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

extension RecentList {
    nonisolated var title: LocalizedStringResource {
        switch self {
        case .applications: "Recent Applications"
        case .documents: "Recent Documents"
        case .servers: "Recent Servers"
        case .finderFolders: "Finder’s Recent Folders"
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .applications: "square.grid.2x2"
        case .documents: "doc"
        case .servers: "server.rack"
        case .finderFolders: "folder"
        }
    }
}
