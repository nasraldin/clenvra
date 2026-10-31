import AppKit
import ClenvraKit
import SwiftUI

/// Extensions and plug-ins that add code to macOS or other apps, in collapsible groups. Only the user's own plug-in
/// bundles can be removed; everything else is shown so the user knows it is there, and can be revealed in Finder.
struct PluginsView: View {
    let session: PluginsSession

    @State private var highlighted: Set<PluginRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\PluginRow.name)]
    @State private var searchText = ""
    private var query: String { AppSearch.normalized(searchText) }
    @State private var showsInspector = false
    @State private var isConfirming = false
    @State private var shownSummary: ShownPluginSummary?
    @State private var scanned: Date?
    /// Table rows, built when the scan, search or sort changes (never while scrolling: with Apple's items shown
    /// there are hundreds).
    @State private var tableGroups: [PluginTableGroup] = []
    @State private var itemsByID: [String: PluginItem] = [:]
    /// The open app the Quit confirmation is about.
    @State private var quitTarget: QuitTarget?
    /// Groups the person closed, remembered across launches (F4).
    private let expansion = ExpandedGroups("extensions")

    /// An open app the person asked to quit, so its extension can then be removed with the app.
    struct QuitTarget: Identifiable {
        /// The app's bundle path.
        let id: String
        let name: String
        let force: Bool
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.groups, initial: true) { rebuildRows() }
            .onChange(of: searchText) { rebuildRows() }
            .onChange(of: sortOrder) { rebuildRows() }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            ) { _ in
                session.refreshRunningApps()
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            ) { _ in
                session.refreshRunningApps()
            }
            .confirmationDialog(
                quitTarget?.force == true ? "Force Quit Application" : "Quit Application",
                isPresented: Binding(get: { quitTarget != nil }, set: { if !$0 { quitTarget = nil } }),
                presenting: quitTarget
            ) { target in
                if target.force {
                    Button("Force Quit", role: .destructive) {
                        session.quitApp(target.id, force: true)
                    }
                } else {
                    Button("Quit", role: .destructive) {
                        session.quitApp(target.id, force: false)
                    }
                }
                Button("Cancel", role: .cancel) {
                    quitTarget = nil
                }
            } message: { target in
                if target.force {
                    Text("Force quitting immediately terminates \(target.name). Any unsaved data will be lost.")
                } else {
                    Text("Are you sure you want to quit \(target.name)? Unsaved changes may be lost.")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.removableCount > 0 {
                    SelectionStatusBar(
                        count: session.selectedCount, bytes: session.selectedBytes,
                        working: session.phase == .removing ? "Moving to the Trash…" : nil, scanned: scanned)
                }
            }
            .pageSearch(text: $searchText, prompt: "Search Extensions", section: .extensions)
            .toolbar { toolbar }
            .detailsPanel(isPresented: $showsInspector, width: 290) {
                inspector
            }
            .sheet(isPresented: $isConfirming) {
                ConfirmCleanupSheet(count: session.selectedCount, bytes: session.selectedBytes) {
                    isConfirming = false
                    Task { shownSummary = ShownPluginSummary(summary: await session.remove()) }
                }
            }
            .sheet(item: $shownSummary) { shown in
                CleanupResultSheet(summary: shown.summary, isPreview: false)
            }
    }

    private var isBusy: Bool { session.phase != .ready }

    private func scan() {
        Task {
            await session.scan()
            scanned = .now
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            if !session.issues.isEmpty {
                Label {
                    Text("Some extensions could not be listed, so this list may be incomplete.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            table
                .accessibilityIdentifier("review.results")
                .accessibilityLabel(Text(AppSection.extensions.title))
        }
        .pageState(isShown: tableGroups.isEmpty) { state }
    }

    @ViewBuilder private var state: some View {
        if session.phase == .idle {
            ScanPrompt(
                section: .extensions,
                description:
                    "List Safari extensions, system extensions, Quick Look and Spotlight plug-ins, audio plug-ins and other add-ons."
            ) {
                scan()
            }
        } else if session.phase == .scanning {
            ProgressView {
                Text("Looking for extensions and plug-ins…")
            }
            .accessibilityIdentifier("review.scanning")
        } else {
            Group {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No extensions or plug-ins found")
                        } icon: {
                            Image(systemName: "puzzlepiece.extension")
                        }
                    } description: {
                        Text("Turn on Show Apple Items to see the ones built into macOS.")
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(AppSection.extensions.title))
        }
    }

    private var table: some View {
        Table(of: PluginRow.self, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn(Text("Name"), value: \.name) { row in
                HStack(spacing: 6) {
                    checkbox(for: row)
                    if let item = row.item {
                        PluginNameCell(item: item)
                        if let app = row.appName {
                            Text("Part of \(app)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(row.kind.title)
                            .fontWeight(.semibold)
                    }
                }
            }
            .width(min: 220, ideal: 320)

            TableColumn(Text("Status")) { row in
                if let item = row.item {
                    PluginStatus(item: item)
                } else {
                    Text("\(row.itemCount) items")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 110, ideal: 150)

            TableColumn(Text("Size"), value: \.size) { row in
                if row.size > 0 {
                    SizeText(bytes: row.size)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 70, ideal: 90)
        } rows: {
            ForEach(tableGroups) { group in
                DisclosureTableRow(group.header, isExpanded: expandedBinding(group.kind)) {
                    ForEach(group.rows) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: PluginRow.ID.self) { ids in
            let items = items(for: ids)
            if !items.isEmpty {
                FileActionsMenu(paths: items.compactMap(\.path)) {
                    highlighted = ids
                    showsInspector = true
                }
                let apps = runningApps(for: items)
                if !apps.isEmpty {
                    Divider()
                    ForEach(apps, id: \.path) { app in
                        quitButton(appPath: app.path, name: app.name)
                    }
                }
            }
        } primaryAction: { ids in
            highlighted = ids
            showsInspector = true
        }
        .disabled(session.phase == .removing)
    }

    @ViewBuilder private func checkbox(for row: PluginRow) -> some View {
        if let item = row.item {
            Toggle(
                isOn: Binding(
                    get: { session.selection.contains(item.id) },
                    set: { if $0 != session.selection.contains(item.id) { session.toggle(item.id) } })
            ) {
                Text("Include \(item.name)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!session.canSelect(item))
        } else if let group = tableGroups.first(where: { $0.kind == row.kind }), !group.removableIDs.isEmpty {
            Toggle(
                isOn: Binding(
                    get: { group.removableIDs.allSatisfy(session.selection.contains) },
                    set: { session.setSelected($0, kind: group.kind) })
            ) {
                Text("Include all \(Text(group.kind.title))")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
        }
    }

    @ViewBuilder private var inspector: some View {
        let items = items(for: highlighted)
        if items.count == 1, let item = items.first {
            ItemInspector(
                name: item.name, path: item.path,
                icon: IconCache.shared.icon(for: item)
                    ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            ) {
                if let app = session.runningApp(for: item) {
                    let name = item.containingAppName ?? app
                    Section {
                        Text("\(name) is open. Quit it first, then remove this extension together with its app.")
                            .font(.callout)
                        quitButton(appPath: app, name: name)
                    }
                }
                Section {
                    LabeledContent {
                        Text(item.kind.title)
                    } label: {
                        Text("Kind")
                    }
                    LabeledContent {
                        PluginStatus(item: item)
                    } label: {
                        Text("Status")
                    }
                    if let version = item.version {
                        LabeledContent {
                            Text(verbatim: version)
                        } label: {
                            Text("Version")
                        }
                    }
                    if let app = item.containingApp {
                        LabeledContent {
                            Text(verbatim: app)
                        } label: {
                            Text("Part Of")
                        }
                    }
                    if let identifier = item.bundleIdentifier {
                        LabeledContent {
                            Text(verbatim: identifier)
                                .textSelection(.enabled)
                                .environment(\.layoutDirection, .leftToRight)
                        } label: {
                            Text("Identifier")
                        }
                    }
                    if let size = item.size {
                        LabeledContent {
                            SizeText(bytes: size)
                        } label: {
                            Text("Size")
                        }
                    }
                } footer: {
                    Text(item.handling.explanation)
                        .font(.callout)
                }
            }
        } else if items.count > 1 {
            SelectionTotalsInspector(count: items.count, bytes: items.reduce(0) { $0 + ($1.size ?? 0) })
        } else {
            NoSelectionInspector(description: "Select an extension to see what it is and where it lives.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: Binding(get: { session.showsAppleItems }, set: { session.showsAppleItems = $0 })) {
                ToolbarLabel(title: "Show Apple Items", symbol: "apple.logo")
            }
            .toggleStyle(.button)
            .help(Text("Also list the extensions built into macOS"))
            .accessibilityIdentifier("plugins.showApple")

            Button {
                scan()
            } label: {
                ToolbarLabel(title: session.phase == .idle ? "Scan" : "Rescan", symbol: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Look for extensions again (⌘R)"))
            .disabled(session.phase == .scanning || session.phase == .removing)

            ExpandAllButton(
                allExpanded: expansion.allBinding(session.groups.map { String(describing: $0.kind) })
            )
            .disabled(session.groups.isEmpty)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            PrimaryActionButton(isDisabled: isBusy || session.selection.isEmpty) {
                isConfirming = true
            }
        }

        ToolbarItem {
            InspectorToggle(isPresented: $showsInspector)
        }
    }

    // MARK: - Data

    /// Builds the table rows once per scan, search or sort change, so scrolling only draws.
    private func rebuildRows() {
        let order = sortOrder
        tableGroups = session.groups.compactMap { group in
            let matching = matches(in: group)
            guard !matching.isEmpty else { return nil }
            return PluginTableGroup(
                header: PluginRow(group: group), rows: matching.map(PluginRow.init(item:)).sorted(using: order),
                removableIDs: group.items.filter(session.canSelect).map(\.id))
        }
        itemsByID = Dictionary(
            session.groups.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func items(for ids: Set<PluginRow.ID>) -> [PluginItem] {
        ids.sorted().compactMap { itemsByID[$0] }
    }

    /// The distinct open apps the items ship in, by name.
    private func runningApps(for items: [PluginItem]) -> [(path: String, name: String)] {
        var seen: Set<String> = []
        return items.compactMap { item in
            guard let app = session.runningApp(for: item), seen.insert(app).inserted else { return nil }
            return (app, item.containingAppName ?? app)
        }
    }

    /// Quit (or Force Quit, after a polite quit was refused) an open app, after confirmation.
    private func quitButton(appPath: String, name: String) -> some View {
        let force = session.needsForceQuit(appPath)
        return Button {
            quitTarget = QuitTarget(id: appPath, name: name, force: force)
        } label: {
            Text(force ? "Force Quit \(name)…" : "Quit \(name)…")
        }
        .help(Text("Quit the app this extension belongs to, so you can remove it"))
    }

    private func matches(in group: PluginsSession.Group) -> [PluginItem] {
        guard !query.isEmpty else { return group.items }
        return group.items.filter {
            $0.name.localizedStandardContains(query)
                || ($0.containingApp?.localizedStandardContains(query) ?? false)
                || ($0.bundleIdentifier?.localizedStandardContains(query) ?? false)
        }
    }

    private func expandedBinding(_ kind: PluginItem.Kind) -> Binding<Bool> {
        expansion.binding(String(describing: kind)) { session.groups.map { String(describing: $0.kind) } }
    }
}

/// One table row: a kind of extension (with its items as children) or one extension. Plain data, so the table can
/// sort by its key paths.
nonisolated struct PluginRow: Identifiable, Sendable {
    let id: String
    let kind: PluginItem.Kind
    let item: PluginItem?
    let name: String
    let size: Int64
    let itemCount: Int
    /// The app the extension ships in, by name.
    let appName: String?

    init(group: PluginsSession.Group) {
        id = "kind:" + String(describing: group.kind)
        kind = group.kind
        item = nil
        name = String(describing: group.kind)  // Kind rows are not sorted; the cell shows the localized title.
        size = group.items.reduce(0) { $0 + ($1.size ?? 0) }
        itemCount = group.items.count
        appName = nil
    }

    init(item: PluginItem) {
        id = item.id
        kind = item.kind
        self.item = item
        name = item.name
        size = item.size ?? 0
        itemCount = 1
        appName = item.containingAppName
    }
}

/// One kind of extension with its matching rows, already filtered and sorted.
nonisolated struct PluginTableGroup: Identifiable, Sendable {
    var id: String { header.id }
    var kind: PluginItem.Kind { header.kind }
    let header: PluginRow
    let rows: [PluginRow]
    /// Items of this kind the user may select (the group checkbox covers them all).
    let removableIDs: [String]
}

/// The extension's own icon (or its app's, or a generic symbol) and name. Icons come from `IconCache`, so a row
/// asks `NSWorkspace` and reads its bundle at most once, not on every scroll.
private struct PluginNameCell: View {
    let item: PluginItem

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon = IconCache.shared.icon(for: item) {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(verbatim: item.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(Text(verbatim: item.path ?? item.name))
    }
}

extension PluginsSession.AppControl {
    /// The running apps `NSWorkspace` reports; quitting goes through `NSRunningApplication` only, never Clenvra
    /// itself.
    static let live = PluginsSession.AppControl(
        runningAppPaths: {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map(bundlePath) })
        },
        quit: { path, force in
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0 != NSRunningApplication.current && $0.bundleURL.map(bundlePath) == path
            }
            return apps.map { force ? $0.forceTerminate() : $0.terminate() }.contains(true)
        })

    private static func bundlePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Whether the extension can be removed, as icon + word.
private struct PluginStatus: View {
    let item: PluginItem

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(item.handling == .managed ? Color.orange : Color.secondary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private var title: LocalizedStringResource {
        switch item.handling {
        case .removable: item.isEnabled == false ? "Off" : "Removable"
        case .managed: "Security software"
        case .revealOnly: item.isEnabled == false ? "Off" : "Show only"
        }
    }

    private var symbol: String {
        switch item.handling {
        case .removable: item.isEnabled == false ? "pause.circle" : "trash.circle"
        case .managed: "lock.shield"
        case .revealOnly: item.isEnabled == false ? "pause.circle" : "eye"
        }
    }
}

extension PluginItem.Handling {
    var explanation: LocalizedStringResource {
        switch self {
        case .removable: "Installed in your home folder. You can move it to the Trash."
        case .managed:
            "Security or management software. Remove it with its own app or ask your administrator."
        case .revealOnly:
            "Installed by macOS, an app or an administrator. Clenvra shows it so you know it is there; remove it from the app it belongs to."
        }
    }
}

private struct ShownPluginSummary: Identifiable {
    let id = UUID()
    let summary: CleanupSummary
}

extension PluginItem.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .preferencePane: "Settings Panes"
        case .quickLook: "Quick Look Plug-ins"
        case .spotlightImporter: "Spotlight Importers"
        case .audioUnit: "Audio Units"
        case .vstPlugIn: "VST Plug-ins"
        case .vst3PlugIn: "VST3 Plug-ins"
        case .halPlugIn: "Audio Drivers"
        case .masPlugIn: "MAS Plug-ins"
        case .internetPlugIn: "Internet Plug-ins"
        case .appExtension: "App Extensions"
        case .systemExtension: "System Extensions"
        }
    }
}
