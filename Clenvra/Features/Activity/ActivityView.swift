import AppKit
import ClenvraKit
import SwiftUI
import UniformTypeIdentifiers

/// History of everything Clenvra did, with Put Back for items that are still in the Trash.
struct ActivityView: View {
    @Bindable var session: ActivitySession

    @State private var didLoad = false
    @State private var highlighted: Set<ActivityRow.ID> = []
    @State private var showsInspector = false
    /// Runs the person opened, remembered across launches; history starts closed.
    private let expansion = ExpandedGroups("activity", opensByDefault: false)
    @State private var restoreFailure: RestoreReason?
    @State private var reenableFailure: LaunchAgentReenabler.Outcome?
    @State private var exportFailed = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageSearch(text: $session.searchText, prompt: "Search by Path", section: .activity)
            .toolbar { toolbar }
            .detailsPanel(isPresented: $showsInspector, width: 290) {
                inspector
            }
            .alert(
                "Could Not Put Back",
                isPresented: Binding(
                    get: { restoreFailure != nil },
                    set: { if !$0 { restoreFailure = nil } }
                )
            ) {
            } message: {
                if let failure = restoreFailure {
                    Text(failureMessage(failure))
                }
            }
            .alert("Could Not Export", isPresented: $exportFailed) {
            } message: {
                Text("The file could not be written.")
            }
            .alert(
                "Could Not Enable",
                isPresented: Binding(
                    get: { reenableFailure != nil },
                    set: { if !$0 { reenableFailure = nil } }
                )
            ) {
            } message: {
                if let outcome = reenableFailure {
                    Text(reenableMessage(outcome))
                }
            }
            .task { await loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        list
            .accessibilityIdentifier("review.results")
            .pageState(isShown: session.visibleOperations.isEmpty) {
                if !didLoad {
                    Color.clear
                } else if session.operations.isEmpty {
                    emptyState
                } else {
                    ContentUnavailableView {
                        Label {
                            Text("No Results")
                        } icon: {
                            Image(systemName: "magnifyingglass")
                        }
                    } description: {
                        Text("Try a different path or another section.")
                    }
                    .accessibilityIdentifier("review.results")
                }
            }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Activity Yet")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
        } description: {
            Text("Cleanup and other actions Clenvra performs will appear here.")
        }
        .accessibilityIdentifier("review.results")
    }

    private var list: some View {
        Table(of: ActivityRow.self, selection: $highlighted) {
            TableColumn(Text("Name")) { row in
                if let item = row.item {
                    FileNameCell(name: (item.path as NSString).lastPathComponent, path: item.path)
                } else if let operation = row.operation {
                    OperationHeader(operation: operation)
                }
            }
            .width(min: 240, ideal: 380)

            TableColumn(Text("Result")) { row in
                if let item = row.item {
                    ItemResult(
                        item: item, restored: session.isRestored(itemPath: item.path, operationID: row.operationID),
                        reenabled: session.isReenabled(itemPath: item.path, operationID: row.operationID))
                } else if let operation = row.operation {
                    Text("\(operation.items.count) items")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 130, ideal: 170)

            TableColumn(Text("Size")) { row in
                SizeText(bytes: row.bytes)
                    .fontWeight(row.item == nil ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        } rows: {
            ForEach(session.visibleOperations) { operation in
                DisclosureTableRow(ActivityRow(operation: operation), isExpanded: expandedBinding(operation.id)) {
                    ForEach(operation.items.map { ActivityRow(item: $0, operationID: operation.id) }) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: ActivityRow.ID.self) { ids in
            let rows = selectedRows(ids)
            FileActionsMenu(paths: rows.compactMap(\.item?.path)) {
                highlighted = ids
                showsInspector = true
            }
            if rows.count == 1, let row = rows.first, let item = row.item, canRestore(item, row.operationID) {
                Divider()
                Button {
                    restore(item, row.operationID)
                } label: {
                    Text("Put Back")
                }
            }
        } primaryAction: { ids in
            highlighted = ids
            showsInspector = true
        }
    }

    @ViewBuilder private var inspector: some View {
        let rows = selectedRows(highlighted)
        if rows.count == 1, let row = rows.first, let item = row.item {
            ItemInspector(name: (item.path as NSString).lastPathComponent, path: item.path) {
                Section {
                    LabeledContent {
                        ItemResult(
                            item: item,
                            restored: session.isRestored(itemPath: item.path, operationID: row.operationID),
                            reenabled: session.isReenabled(itemPath: item.path, operationID: row.operationID))
                    } label: {
                        Text("Result")
                    }
                    LabeledContent {
                        SizeText(bytes: item.bytes)
                    } label: {
                        Text("Size")
                    }
                    if let operation = session.operations.first(where: { $0.id == row.operationID }) {
                        LabeledContent {
                            Text(operation.date, format: .dateTime.day().month().year().hour().minute())
                        } label: {
                            Text("Date")
                        }
                        LabeledContent {
                            Text(operation.section.title)
                        } label: {
                            Text("From")
                        }
                    }
                }
                if canRestore(item, row.operationID) || canReenable(item, row.operationID) {
                    Section {
                        if canRestore(item, row.operationID) {
                            Button {
                                restore(item, row.operationID)
                            } label: {
                                Text("Put Back")
                            }
                        }
                        if canReenable(item, row.operationID) {
                            Button {
                                reenable(item, row.operationID)
                            } label: {
                                Text("Enable at Login")
                            }
                            .help(Text("Loads this startup item again, as it was before Clenvra removed it."))
                        }
                    } footer: {
                        Text("Put Back moves the item from the Trash to where it was.")
                            .font(.callout)
                    }
                }
            }
        } else if rows.count == 1, let operation = rows.first?.operation {
            Form {
                Section {
                    LabeledContent {
                        Text(operation.date, format: .dateTime.day().month().year().hour().minute())
                    } label: {
                        Text("Date")
                    }
                    LabeledContent {
                        Text(operation.section.title)
                    } label: {
                        Text("From")
                    }
                    LabeledContent {
                        Text(operation.items.count, format: .number)
                    } label: {
                        Text("Items")
                    }
                    LabeledContent {
                        SizeText(bytes: operation.freedBytes)
                    } label: {
                        Text("Freed")
                    }
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("page.inspector")
        } else if rows.count > 1 {
            SelectionTotalsInspector(count: rows.count, bytes: rows.reduce(0) { $0 + $1.bytes })
        } else {
            NoSelectionInspector(description: "Select an entry to see what happened and put it back.")
        }
    }

    private func selectedRows(_ ids: Set<ActivityRow.ID>) -> [ActivityRow] {
        session.visibleOperations.flatMap { operation in
            [ActivityRow(operation: operation)]
                + operation.items.map { ActivityRow(item: $0, operationID: operation.id) }
        }
        .filter { ids.contains($0.id) }
    }

    private func canRestore(_ item: ActivitySession.Item, _ operationID: UUID) -> Bool {
        guard case .movedToTrash = item.outcome else { return false }
        return !session.isRestored(itemPath: item.path, operationID: operationID)
    }

    private func canReenable(_ item: ActivitySession.Item, _ operationID: UUID) -> Bool {
        session.isRestored(itemPath: item.path, operationID: operationID)
            && session.canReenable(itemPath: item.path, operationID: operationID)
            && !session.isReenabled(itemPath: item.path, operationID: operationID)
    }

    private func restore(_ item: ActivitySession.Item, _ operationID: UUID) {
        Task {
            if let failure = await session.restore(itemPath: item.path, operationID: operationID) {
                restoreFailure = failure
            }
        }
    }

    private func reenable(_ item: ActivitySession.Item, _ operationID: UUID) {
        Task {
            let outcome = await session.reenable(itemPath: item.path, operationID: operationID)
            switch outcome {
            case .enabled, .alreadyEnabled: break
            default: reenableFailure = outcome
            }
        }
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        expansion.binding(id.uuidString) { session.visibleOperations.map(\.id.uuidString) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Filter by Section", selection: $session.sectionFilter) {
                    Text("All Sections").tag(nil as ActivityRecord.Section?)
                    ForEach(ActivityRecord.Section.allCases, id: \.self) { section in
                        Text(section.title).tag(section as ActivityRecord.Section?)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                ToolbarLabel(
                    title: "Filter by Section",
                    symbol: session.sectionFilter == nil
                        ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuIndicator(.hidden)
            .help(Text("Show the activity of one section"))

            Button {
                Task {
                    didLoad = false
                    await loadIfNeeded()
                }
            } label: {
                ToolbarLabel(title: "Refresh", symbol: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)

            ExpandAllButton(allExpanded: expansion.allBinding(session.visibleOperations.map(\.id.uuidString)))
                .disabled(session.visibleOperations.isEmpty)

            Menu {
                Button {
                    export(markdown: false)
                } label: {
                    Text("Export as CSV…")
                }
                Button {
                    export(markdown: true)
                } label: {
                    Text("Export Report as Markdown…")
                }
            } label: {
                ToolbarLabel(title: "Export…", symbol: "square.and.arrow.up")
            }
            .accessibilityIdentifier("activity.export")
            .disabled(didLoad && session.visibleOperations.isEmpty)
        }
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        await session.load()
        didLoad = true
    }

    private func failureMessage(_ failure: RestoreReason) -> LocalizedStringResource {
        switch failure {
        case .notRestorable: "This entry does not describe an item in the Trash."
        case .notInTrash: "This item is no longer in the Trash."
        case .originalFolderMissing: "The folder it came from no longer exists."
        case .originalPathOccupied: "Another item now occupies its original location, so it was left in the Trash."
        case .restoreFailed: "Moving the item back did not succeed."
        }
    }

    private func reenableMessage(_ outcome: LaunchAgentReenabler.Outcome) -> LocalizedStringResource {
        switch outcome {
        case .enabled, .alreadyEnabled: "It is enabled again."
        case .notAllowed: "Only startup items you put back from the Trash can be enabled again."
        case .invalidPlist: "Its settings file is not valid, so it was not enabled."
        case .failed: "macOS did not load it. It will still start the next time you log in."
        }
    }

    private func export(markdown: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [markdown ? UTType(filenameExtension: "md") ?? .plainText : .commaSeparatedText]
        panel.nameFieldStringValue = markdown ? "Clenvra-Activity.md" : "Clenvra-Activity.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = markdown ? session.exportMarkdown() : session.exportCSV()
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            exportFailed = true
        }
    }
}

private struct OperationHeader: View {
    let operation: ActivitySession.Operation

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(operation.date, format: .dateTime.day().month().year().hour().minute())
                    .fontWeight(.semibold)
                Text(operation.section.title)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: operation.section.symbol)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One table row: a run of Clenvra (with its items as children) or one item it acted on.
nonisolated struct ActivityRow: Identifiable, Sendable {
    let id: String
    let operationID: UUID
    let operation: ActivitySession.Operation?
    let item: ActivitySession.Item?
    let bytes: Int64

    init(operation: ActivitySession.Operation) {
        id = "run:" + operation.id.uuidString
        operationID = operation.id
        self.operation = operation
        item = nil
        bytes = operation.freedBytes
    }

    init(item: ActivitySession.Item, operationID: UUID) {
        id = operationID.uuidString + ":" + item.path
        self.operationID = operationID
        operation = nil
        self.item = item
        bytes = item.bytes
    }
}

/// What happened to an item, and whether it was put back or enabled again since.
private struct ItemResult: View {
    let item: ActivitySession.Item
    let restored: Bool
    let reenabled: Bool

    var body: some View {
        if reenabled {
            Label {
                Text("Enabled")
            } icon: {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if restored {
            Label {
                Text("Restored")
            } icon: {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            OutcomeBadge(outcome: item.outcome)
        }
    }
}

/// Risk or status, always as icon + text (never colour alone).
private struct OutcomeBadge: View {
    let outcome: ActivityRecord.Outcome

    var body: some View {
        label
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var label: some View {
        switch outcome {
        case .intent:
            // Rows always carry a final outcome; an intent record is followed by one.
            EmptyView()
        case .movedToTrash:
            badge("Moved to Trash", "trash")
        case .removedPermanently:
            badge("Removed Permanently", "trash.slash")
        case .wouldDelete:
            badge("Would Remove", "eye")
        case .skipped:
            badge("Skipped", "exclamationmark.triangle")
        case .failed:
            badge("Failed", "exclamationmark.octagon")
        case .anomaly:
            badge("Batch Stopped", "flag")
        case .notAttempted:
            badge("Not Attempted", "minus.circle")
        case .restored:
            badge("Put Back", "arrow.uturn.backward")
        }
    }

    private func badge(_ title: LocalizedStringResource, _ symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch outcome {
        case .intent, .movedToTrash, .removedPermanently, .wouldDelete, .notAttempted, .restored: .secondary
        case .skipped, .anomaly: .orange
        case .failed: .red
        }
    }
}

extension ActivityRecord.Section {
    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .storage: "Storage"
        case .cleanup: "Cleanup"
        case .developer: "Developer"
        case .applications: "Applications"
        case .startup: "Startup"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .storage: "internaldrive"
        case .cleanup: "sparkles"
        case .developer: "hammer"
        case .applications: "app.badge"
        case .startup: "power"
        case .system: "cpu"
        }
    }
}
