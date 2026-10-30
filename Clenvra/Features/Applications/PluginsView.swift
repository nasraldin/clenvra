import AppKit
import ClenvraKit
import SwiftUI

/// Extensions and plug-ins that add code to macOS or other apps, in collapsible groups. Only the user's own plug-in
/// bundles can be removed; everything else is shown so the user knows it is there, and can be revealed in Finder.
struct PluginsView: View {
    let session: PluginsSession

    @State private var highlighted: Set<PluginRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\PluginRow.name)]
    @State private var query = ""
    @State private var showsInspector = false
    @State private var isConfirming = false
    @State private var shownSummary: ShownPluginSummary?
    @State private var scanned: Date?
    /// Groups the person closed, remembered across launches (F4).
    private let expansion = ExpandedGroups("extensions")

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.removableCount > 0 {
                    SelectionStatusBar(
                        count: session.selectedCount, bytes: session.selectedBytes,
                        working: session.phase == .removing ? "Moving to the Trash…" : nil, scanned: scanned)
                }
            }
            .toolbar { toolbar }
            .detailsPanel(isPresented: $showsInspector, width: 290) {
                inspector
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text("Search Extensions"))
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
        .pageState(isShown: visibleGroups.isEmpty) { state }
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
                        FileNameCell(name: item.name, path: item.path)
                        if let app = item.containingApp {
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
            ForEach(visibleGroups) { group in
                DisclosureTableRow(PluginRow(group: group), isExpanded: expandedBinding(group.kind)) {
                    ForEach(matches(in: group).map(PluginRow.init(item:)).sorted(using: sortOrder)) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: PluginRow.ID.self) { ids in
            let items = session.groups.flatMap(\.items).filter { ids.contains($0.id) }
            if !items.isEmpty {
                FileActionsMenu(paths: items.compactMap(\.path)) {
                    highlighted = ids
                    showsInspector = true
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
        } else if let group = session.groups.first(where: { $0.kind == row.kind }),
            group.items.contains(where: session.canSelect)
        {
            let removable = group.items.filter(session.canSelect)
            Toggle(
                isOn: Binding(
                    get: { removable.allSatisfy { session.selection.contains($0.id) } },
                    set: { session.setSelected($0, kind: group.kind) })
            ) {
                Text("Include all \(Text(group.kind.title))")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
        }
    }

    @ViewBuilder private var inspector: some View {
        let items = session.groups.flatMap(\.items).filter { highlighted.contains($0.id) }
        if items.count == 1, let item = items.first {
            ItemInspector(name: item.name, path: item.path) {
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

    private var visibleGroups: [PluginsSession.Group] {
        session.groups.filter { !matches(in: $0).isEmpty }
    }

    private func matches(in group: PluginsSession.Group) -> [PluginItem] {
        guard !query.isEmpty else { return group.items }
        return group.items.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.containingApp?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
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

    init(group: PluginsSession.Group) {
        id = "kind:" + String(describing: group.kind)
        kind = group.kind
        item = nil
        name = String(describing: group.kind)  // Kind rows are not sorted; the cell shows the localized title.
        size = group.items.reduce(0) { $0 + ($1.size ?? 0) }
        itemCount = group.items.count
    }

    init(item: PluginItem) {
        id = item.id
        kind = item.kind
        self.item = item
        name = item.name
        size = item.size ?? 0
        itemCount = 1
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
