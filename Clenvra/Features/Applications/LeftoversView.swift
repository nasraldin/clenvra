import AppKit
import ClenvraKit
import SwiftUI

/// Files left behind by apps that are no longer installed, grouped by the app they belonged to: a table of collapsible
/// groups with a checkbox per item and per group, details and evidence in the inspector, and one Move to Trash action.
/// Nothing here is ever selected automatically.
struct LeftoversView: View {
    let session: AppsSession

    @State private var highlighted: Set<LeftoverRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\LeftoverRow.size, order: .reverse)]
    @State private var searchText = ""
    private var query: String { AppSearch.normalized(searchText) }
    @State private var showsInspector = false
    @State private var isConfirming = false
    @State private var shownSummary: ShownLeftoverSummary?
    @State private var scanned: Date?
    /// Groups the person closed, remembered across launches.
    private let groups = ExpandedGroups("leftovers")

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !session.leftovers.isEmpty {
                    SelectionStatusBar(
                        count: session.leftoverSelection.count, bytes: session.leftoverSelectedBytes,
                        working: session.isWorking ? "Moving to the Trash…" : nil, scanned: scanned)
                }
            }
            .pageSearch(text: $searchText, prompt: "Search by Name or Location", section: .leftovers)
            .toolbar { toolbar }
            .detailsPanel(isPresented: $showsInspector, width: 280) {
                inspector
            }
            .sheet(isPresented: $isConfirming) {
                ConfirmCleanupSheet(count: session.leftoverSelection.count, bytes: session.leftoverSelectedBytes) {
                    isConfirming = false
                    Task {
                        shownSummary = ShownLeftoverSummary(summary: await session.removeLeftovers(), isPreview: false)
                    }
                }
            }
            .sheet(item: $shownSummary) { shown in
                CleanupResultSheet(summary: shown.summary, isPreview: shown.isPreview)
            }
            .task {
                // The installed-app list is needed to tell what belongs to removed apps; the search waits for Scan.
                if session.phase == .idle { await session.load() }
            }
    }

    private var isBusy: Bool { session.isScanningLeftovers || session.isWorking || session.phase != .ready }

    private func scan() {
        Task {
            await session.scanLeftovers()
            scanned = .now
        }
    }

    // MARK: - Content

    private var content: some View {
        table
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(AppSection.leftovers.title))
            .pageState(isShown: visibleGroups.isEmpty) { state }
    }

    @ViewBuilder private var state: some View {
        if !session.hasScannedLeftovers && !session.isScanningLeftovers {
            ScanPrompt(
                section: .leftovers,
                description:
                    "Find files that apps you already removed left behind: settings, caches, containers and support files."
            ) {
                scan()
            }
            .disabled(session.phase != .ready)
        } else if session.isScanningLeftovers {
            ProgressView {
                Text("Looking for leftovers…")
            }
            .accessibilityIdentifier("review.scanning")
        } else {
            Group {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No leftovers found")
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                    } description: {
                        Text("No files from removed apps were found, or they were changed in the last 30 days.")
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(AppSection.leftovers.title))
        }
    }

    private var table: some View {
        Table(of: LeftoverRow.self, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn(Text("Name"), value: \.name) { row in
                HStack(spacing: 6) {
                    checkbox(for: row)
                    if let item = row.item {
                        FileNameCell(name: item.name, path: item.path)
                    } else {
                        LeftoverGroupNameCell(row: row)
                    }
                }
            }
            .width(min: 220, ideal: 320)

            TableColumn(Text("Kind")) { row in
                if let item = row.item {
                    Text(item.kind.title)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(row.itemCount) items")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn(Text("Size"), value: \.size) { row in
                SizeText(bytes: row.size)
                    .fontWeight(row.item == nil ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn(Text("Modified"), value: \.modifiedSort) { row in
                DateCell(date: row.modifiedSort)
            }
            .width(min: 90, ideal: 110)
        } rows: {
            ForEach(visibleGroups) { group in
                DisclosureTableRow(LeftoverRow(group: group), isExpanded: expandedBinding(group.id)) {
                    ForEach(group.items.map(LeftoverRow.init(item:)).sorted(using: sortOrder)) { row in
                        TableRow(row)
                    }
                }
            }
        }
        // Group rows already separate the list; grey stripes under short names fall below readable contrast.
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: LeftoverRow.ID.self) { ids in
            let items = items(for: ids)
            FileActionsMenu(paths: items.map(\.path)) {
                highlighted = ids
                showsInspector = true
            }
            let selectable = items.filter { session.isSelectable($0) }
            if !selectable.isEmpty {
                Divider()
                let allChecked = selectable.allSatisfy { session.leftoverSelection.contains($0.path) }
                Button {
                    for item in selectable where session.leftoverSelection.contains(item.path) == allChecked {
                        session.toggleLeftover(item.path)
                    }
                } label: {
                    Text(allChecked ? "Don’t Include" : "Include")
                }
            }
        } primaryAction: { ids in
            highlighted = ids
            showsInspector = true
        }
        .disabled(session.isWorking)
    }

    @ViewBuilder private func checkbox(for row: LeftoverRow) -> some View {
        if let item = row.item {
            Toggle(isOn: checkedBinding(item)) {
                Text("Include \(item.name)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!session.isSelectable(item))
        } else {
            // Only the items of this group the search shows, and only those that can be removed.
            let bindings = row.children.filter { session.isSelectable($0) }.map(checkedBinding)
            Toggle(sources: bindings, isOn: \.self) {
                Text("Include all \(row.title)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(bindings.isEmpty)
        }
    }

    @ViewBuilder private var inspector: some View {
        let items = items(for: highlighted)
        if items.count == 1, let item = items.first {
            ItemInspector(name: item.name, path: item.path) {
                Section {
                    LabeledContent {
                        Text(item.kind.title)
                    } label: {
                        Text("Kind")
                    }
                    LabeledContent {
                        SizeText(bytes: item.reclaimableSize)
                    } label: {
                        Text("Frees")
                    }
                    LabeledContent {
                        DateCell(date: item.modificationDate)
                    } label: {
                        Text("Modified")
                    }
                }
                Section {
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                        EvidenceText(evidence: evidence)
                    }
                    if item.containsProtectedItem {
                        Text("Contains protected files, such as keys, so it can't be removed.")
                            .foregroundStyle(.secondary)
                    }
                    if item.handling == .revealOnly {
                        Text("Outside your home folder. Needs an administrator, so it is only shown.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Why It Is Listed")
                } footer: {
                    Text(
                        "Named after an app that is no longer installed and unchanged for 30 days. Check it before removing it."
                    )
                    .font(.callout)
                }
            }
        } else if items.count > 1 {
            SelectionTotalsInspector(count: items.count, bytes: items.reduce(0) { $0 + $1.reclaimableSize })
        } else {
            NoSelectionInspector(description: "Select a leftover to see where it is and why it is listed.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                scan()
            } label: {
                ToolbarLabel(title: session.hasScannedLeftovers ? "Rescan" : "Scan", symbol: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Look for leftovers again (⌘R)"))
            .disabled(isBusy)

            ExpandAllButton(allExpanded: groups.allBinding(allGroups.map(\.id)))
                .disabled(session.leftovers.isEmpty)

            Menu {
                Button {
                    Task {
                        shownSummary = ShownLeftoverSummary(
                            summary: await session.removeLeftovers(dryRun: true), isPreview: true)
                    }
                } label: {
                    Text("Preview Cleanup")
                }
                .disabled(isBusy || session.leftoverSelection.isEmpty)
            } label: {
                ToolbarLabel(title: "More", symbol: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help(Text("More actions"))
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            PrimaryActionButton(isDisabled: isBusy || session.leftoverSelection.isEmpty) {
                isConfirming = true
            }
        }

        ToolbarItem {
            InspectorToggle(isPresented: $showsInspector)
        }
    }

    // MARK: - Data

    /// Every leftover, grouped by the app it belonged to.
    private var allGroups: [LeftoverGroup] { LeftoverGroups.groups(session.leftovers) }

    /// Groups with at least one item matching the search, holding only those items. A search for the app's own name
    /// shows its whole group.
    private var visibleGroups: [LeftoverGroup] {
        let all = allGroups
        guard !query.isEmpty else { return all }
        return all.compactMap { group in
            if let name = group.name, AppSearch.matches(query, name) { return group }
            let items = group.items.filter {
                AppSearch.matches(query, any: [$0.name, $0.path, String(localized: $0.kind.title)])
            }
            return items.isEmpty ? nil : LeftoverGroup(owner: group.owner, name: group.name, items: items)
        }
    }

    /// The leftovers behind highlighted rows; a group row stands for the items it shows.
    private func items(for ids: Set<LeftoverRow.ID>) -> [OwnedItem] {
        let groupItems = visibleGroups.filter { ids.contains(LeftoverRow.groupID($0)) }.flatMap(\.items)
        let paths = Set(groupItems.map(\.path))
        return groupItems + session.leftovers.filter { ids.contains($0.id) && !paths.contains($0.path) }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        groups.binding(id) { allGroups.map(\.id) }
    }

    private func checkedBinding(_ item: OwnedItem) -> Binding<Bool> {
        Binding(
            get: { session.leftoverSelection.contains(item.path) },
            set: { checked in
                if session.leftoverSelection.contains(item.path) != checked { session.toggleLeftover(item.path) }
            })
    }
}

/// One table row: an app's group (with its leftovers as children) or one leftover. Plain data, not tied to the main
/// actor, so the table can sort by its key paths.
nonisolated struct LeftoverRow: Identifiable, Sendable {
    let id: String
    let item: OwnedItem?
    /// The group's items the search shows; empty for an item row.
    let children: [OwnedItem]
    /// The app's name or bundle identifier; `nil` for an item row or the unknown-app group.
    let groupName: String?
    let name: String
    let size: Int64
    let modifiedSort: Date
    let itemCount: Int

    static func groupID(_ group: LeftoverGroup) -> String { "group:" + group.id }

    init(group: LeftoverGroup) {
        id = Self.groupID(group)
        item = nil
        children = group.items
        groupName = group.name
        name = group.name ?? ""  // Group rows are not sorted.
        size = group.totalBytes
        modifiedSort = group.items.compactMap(\.modificationDate).max() ?? .distantPast
        itemCount = group.items.count
    }

    init(item: OwnedItem) {
        id = item.id
        self.item = item
        children = []
        groupName = nil
        name = item.name
        size = item.reclaimableSize
        modifiedSort = item.modifiedSort
        itemCount = 1
    }
}

extension LeftoverRow {
    /// The group's title: the app, or "Unknown app".
    @MainActor var title: Text {
        if let groupName { Text(verbatim: groupName) } else { Text("Unknown app") }
    }
}

/// The app a group of leftovers belonged to.
private struct LeftoverGroupNameCell: View {
    let row: LeftoverRow

    var body: some View {
        Label {
            row.title
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: row.groupName == nil ? "questionmark.app.dashed" : "app.dashed")
        }
        .help(Text(verbatim: row.groupName ?? ""))
    }
}

extension OwnedItem {
    /// Unknown dates sort first, so the table can sort on a plain date.
    nonisolated var modifiedSort: Date { modificationDate ?? .distantPast }
}

private struct ShownLeftoverSummary: Identifiable {
    let id = UUID()
    let summary: CleanupSummary
    let isPreview: Bool
}
