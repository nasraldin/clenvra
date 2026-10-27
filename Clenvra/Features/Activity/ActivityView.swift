import AppKit
import ClenvraKit
import SwiftUI
import UniformTypeIdentifiers

/// History of everything Clenvra did, with Put Back for items that are still in the Trash.
struct ActivityView: View {
    @Bindable var session: ActivitySession

    @State private var didLoad = false
    @State private var expanded: Set<UUID> = []
    @State private var restoreFailure: RestoreReason?
    @State private var exportFailed = false

    var body: some View {
        content
            .navigationTitle(Text("Activity"))
            .toolbar { toolbar }
            .searchable(text: $session.searchText, prompt: Text("Search by Path"))
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
                Text("The CSV file could not be written.")
            }
            .task { await loadIfNeeded() }
            .accessibilityIdentifier("section.activity")
    }

    @ViewBuilder private var content: some View {
        if !didLoad {
            Color.clear
        } else if session.operations.isEmpty {
            emptyState
        } else if session.visibleOperations.isEmpty {
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
        } else {
            list
                .accessibilityIdentifier("review.results")
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
        List {
            ForEach(session.visibleOperations) { operation in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expanded.contains(operation.id) },
                        set: { isExpanded in
                            if isExpanded {
                                expanded.insert(operation.id)
                            } else {
                                expanded.remove(operation.id)
                            }
                        }
                    )
                ) {
                    ForEach(operation.items) { item in
                        ItemRow(
                            item: item,
                            restored: session.isRestored(itemPath: item.path, operationID: operation.id),
                            onRestore: {
                                Task {
                                    if let failure = await session.restore(
                                        itemPath: item.path, operationID: operation.id)
                                    {
                                        restoreFailure = failure
                                    }
                                }
                            })
                    }
                } label: {
                    OperationHeader(operation: operation)
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Filter by Section", selection: $session.sectionFilter) {
                Text("All Sections").tag(nil as ActivityRecord.Section?)
                ForEach(ActivityRecord.Section.allCases, id: \.self) { section in
                    Text(section.title).tag(section as ActivityRecord.Section?)
                }
            }

            Button {
                Task {
                    didLoad = false
                    await loadIfNeeded()
                }
            } label: {
                Label {
                    Text("Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button {
                exportCSV()
            } label: {
                Label {
                    Text("Export…")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
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

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Clenvra-Activity.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(session.exportCSV().utf8).write(to: url, options: .atomic)
        } catch {
            exportFailed = true
        }
    }
}

private struct OperationHeader: View {
    let operation: ActivitySession.Operation

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.date, format: .dateTime.day().month().year().hour().minute())
                Label {
                    Text(operation.section.title)
                } icon: {
                    Image(systemName: operation.section.symbol)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("\(operation.items.count) items")
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text("Freed \(operation.freedBytes.formatted(.byteCount(style: .file)))")
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ItemRow: View {
    let item: ActivitySession.Item
    let restored: Bool
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            OutcomeBadge(outcome: item.outcome)
                .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: (item.path as NSString).lastPathComponent)
                PathText(path: item.path)
            }
            Spacer(minLength: 12)
            if isRestorable {
                if restored {
                    Label {
                        Text("Restored")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                } else {
                    Button {
                        onRestore()
                    } label: {
                        Text("Put Back")
                    }
                    .controlSize(.small)
                }
            }
            SizeText(bytes: item.bytes)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var isRestorable: Bool {
        if case .movedToTrash = item.outcome { return true }
        return false
    }
}

/// Risk or status, always as icon + text (never colour alone).
private struct OutcomeBadge: View {
    let outcome: ActivityRecord.Outcome

    var body: some View {
        label
            .font(.caption)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var label: some View {
        switch outcome {
        case .intent:
            // Rows always carry a final outcome; an intent record is followed by one.
            EmptyView()
        case .movedToTrash:
            Label("Moved to Trash", systemImage: "trash")
        case .removedPermanently:
            Label("Removed Permanently", systemImage: "trash.slash")
        case .wouldDelete:
            Label("Would Remove", systemImage: "eye")
        case .skipped:
            Label("Skipped", systemImage: "exclamationmark.triangle")
        case .failed:
            Label("Failed", systemImage: "exclamationmark.octagon")
        case .anomaly:
            Label("Batch Stopped", systemImage: "flag")
        case .notAttempted:
            Label("Not Attempted", systemImage: "minus.circle")
        case .restored:
            Label("Put Back", systemImage: "arrow.uturn.backward")
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
