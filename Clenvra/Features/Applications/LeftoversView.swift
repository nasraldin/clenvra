import AppKit
import ClenvraKit
import SwiftUI

/// Files left behind by apps that are no longer installed: a table with a checkbox per item, details and evidence in
/// the inspector, and one Move to Trash action. Nothing here is ever selected automatically.
struct LeftoversView: View {
    let session: AppsSession

    @State private var highlighted: Set<OwnedItem.ID> = []
    @State private var sortOrder = [KeyPathComparator(\OwnedItem.reclaimableSize, order: .reverse)]
    @State private var query = ""
    @State private var showsInspector = false
    @State private var isConfirming = false
    @State private var shownSummary: ShownLeftoverSummary?
    @State private var scanned: Date?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                if !session.leftovers.isEmpty {
                    SelectionStatusBar(
                        count: session.leftoverSelection.count, bytes: session.leftoverSelectedBytes,
                        working: session.isWorking ? "Moving to the Trash…" : nil, scanned: scanned)
                }
            }
            .toolbar { toolbar }
            .inspector(isPresented: $showsInspector) {
                inspector
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text("Search by Name or Location"))
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

    @ViewBuilder private var content: some View {
        if !session.hasScannedLeftovers && !session.isScanningLeftovers {
            ScanPrompt(
                section: .leftovers,
                description:
                    "Find files that apps you already removed left behind: settings, caches, containers and support files."
            ) {
                scan()
            }
            .disabled(session.phase != .ready)
        } else if session.isScanningLeftovers && session.leftovers.isEmpty {
            ProgressView {
                Text("Looking for leftovers…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("review.scanning")
        } else if rows.isEmpty {
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
        } else {
            table
                .accessibilityIdentifier("review.results")
                .accessibilityLabel(Text(AppSection.leftovers.title))
        }
    }

    private var table: some View {
        Table(rows, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn(Text("Name"), value: \.name) { item in
                HStack(spacing: 6) {
                    Toggle(isOn: checkedBinding(item)) {
                        Text("Include \(item.name)")
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!session.isSelectable(item))
                    FileNameCell(name: item.name, path: item.path)
                }
            }
            .width(min: 220, ideal: 320)

            TableColumn(Text("Kind")) { item in
                Text(item.kind.title)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)

            TableColumn(Text("Size"), value: \.reclaimableSize) { item in
                SizeText(bytes: item.reclaimableSize)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn(Text("Modified"), value: \.modifiedSort) { item in
                DateCell(date: item.modificationDate)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: OwnedItem.ID.self) { ids in
            FileActionsMenu(paths: ids.sorted()) {
                highlighted = ids
                showsInspector = true
            }
            let items = session.leftovers.filter { ids.contains($0.id) && session.isSelectable($0) }
            if !items.isEmpty {
                Divider()
                let allChecked = items.allSatisfy { session.leftoverSelection.contains($0.path) }
                Button {
                    for item in items where session.leftoverSelection.contains(item.path) == allChecked {
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

    @ViewBuilder private var inspector: some View {
        let items = session.leftovers.filter { highlighted.contains($0.id) }
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
                Label {
                    Text(session.hasScannedLeftovers ? "Rescan" : "Scan")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Look for leftovers again (⌘R)"))
            .disabled(isBusy)

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
                Label {
                    Text("More")
                } icon: {
                    Image(systemName: "ellipsis")
                }
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

    private var rows: [OwnedItem] {
        let matching =
            query.isEmpty
            ? session.leftovers
            : session.leftovers.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
            }
        return matching.sorted(using: sortOrder)
    }

    private func checkedBinding(_ item: OwnedItem) -> Binding<Bool> {
        Binding(
            get: { session.leftoverSelection.contains(item.path) },
            set: { checked in
                if session.leftoverSelection.contains(item.path) != checked { session.toggleLeftover(item.path) }
            })
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
