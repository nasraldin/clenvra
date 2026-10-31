import ClenvraKit
import SwiftUI

/// The Developer Tools page: checks tools only when asked, then lists what each one stores.
struct DeveloperToolsView: View {
    /// Nil until the login-shell PATH is known (tools from Homebrew, nvm, volta… live there).
    let session: ToolStorageSession?

    @State private var searchText = ""
    @State private var isConfirmingBatch = false
    @State private var showingBatchResult = false
    private let expansion = ExpandedGroups("developerTools")

    var body: some View {
        page
    }

    @ViewBuilder private var page: some View {
        if let session {
            let query = AppSearch.normalized(searchText)
            List {
                ToolStorageSection(session: session, query: query, expansion: expansion)
            }
            .pageState(isShown: !query.isEmpty && !session.rows.isEmpty && !session.rows.contains { $0.matches(query) })
            {
                ContentUnavailableView.search(text: query)
            }
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(AppSection.developerTools.title))
            .pageState(isShown: session.phase == .idle && session.rows.isEmpty) {
                ContentUnavailableView {
                    Label {
                        Text(AppSection.developerTools.title)
                    } icon: {
                        Image(systemName: AppSection.developerTools.symbol)
                    }
                } description: {
                    Text(
                        "See how much space npm, pnpm, Homebrew, Docker and your other tools keep, and clean it with each tool’s own command."
                    )
                } actions: {
                    Button {
                        Task { await session.inspect() }
                    } label: {
                        Text("Check Tools")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("review.scan")
                }
            }
            .pageSearch(text: $searchText, prompt: "Search Tools", section: .developerTools)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await session.inspect() }
                    } label: {
                        ToolbarLabel(title: "Check Again", symbol: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help(Text("Check your tools again (⌘R)"))
                    .disabled(session.phase == .inspecting)
                }
                ToolbarItem {
                    ExpandAllButton(
                        allExpanded: expansion.allBinding(
                            Set(session.rows.map(\.category)).map(ToolStorageSection.groupID))
                    )
                    .disabled(session.rows.isEmpty)
                }
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    PrimaryActionButton(
                        title: "Clean \(session.checked.count) Tools…", symbol: "sparkles",
                        help: "Review and run the cleanup command of every checked tool (⌘⌫)",
                        isDisabled: session.checked.isEmpty || session.phase != .ready
                    ) {
                        isConfirmingBatch = true
                    }
                }
            }
            .sheet(isPresented: $isConfirmingBatch) {
                // Every checked tool, including any the search hides: the sheet lists exactly what will run.
                ConfirmToolBatchSheet(rows: session.checkedRows) {
                    isConfirmingBatch = false
                    Task {
                        await session.runCheckedCleanups()
                        showingBatchResult = true
                    }
                }
            }
            .sheet(isPresented: $showingBatchResult) {
                if let runs = session.lastBatch { ToolBatchResultSheet(runs: runs) }
            }
        } else {
            ProgressView {
                Text("Finding your developer tools…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Developer tools' own storage, each cleaned by the tool's own command (shown before it runs).
struct ToolStorageSection: View {
    let session: ToolStorageSession
    /// Shows only the tools whose name matches; empty shows them all.
    var query = ""

    @State private var confirming: ToolStorage?
    @State private var showingOutput = false

    /// Which groups are open; shared with the page's Expand All button.
    let expansion: ExpandedGroups

    var body: some View {
        Group {
            if session.phase == .inspecting && session.rows.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking developer tools…").foregroundStyle(.secondary)
                }
            }
            ForEach(shownGroups, id: \.category) { group in
                let isExpanded = expansion.binding(Self.groupID(group.category)) {
                    shownGroups.map { Self.groupID($0.category) }
                }
                Section {
                    if isExpanded.wrappedValue {
                        ForEach(group.rows) { row in
                            ToolRow(
                                row: row, isRunning: session.phase == .running(rowID: row.id),
                                isChecked: Binding(
                                    get: { session.checked.contains(row.id) },
                                    set: { if $0 != session.checked.contains(row.id) { session.toggleChecked(row.id) } }
                                )
                            ) {
                                confirming = row
                            }
                            .disabled(isBusy)
                        }
                    }
                } header: {
                    ToolGroupHeader(
                        category: group.category, rows: group.rows, isExpanded: isExpanded,
                        isChecked: checkedBinding(for: group.rows)
                    )
                    .disabled(isBusy)
                }
            }
            if !shownRows.isEmpty {
                Section {
                } footer: {
                    Text(
                        "Space managed by your tools. Cleaning runs the tool's own command, which does not use the Trash."
                    )
                    .font(.callout)
                }
            }
        }
        .sheet(item: $confirming) { row in
            ConfirmToolCleanupSheet(row: row) {
                confirming = nil
                Task {
                    await session.runCleanup(rowID: row.id)
                    showingOutput = true
                }
            }
        }
        .sheet(isPresented: $showingOutput) {
            if let run = session.lastRun { ToolRunResultSheet(run: run) }
        }
    }

    private var isBusy: Bool {
        if case .running = session.phase { true } else { false }
    }

    private var shownRows: [ToolStorage] { session.rows.filter { $0.matches(query) } }

    /// The shown tools by category, in the categories' own order; the tools keep the order they were found in.
    private var shownGroups: [(category: CleanupCategory, rows: [ToolStorage])] {
        let byCategory = Dictionary(grouping: shownRows, by: \.category)
        return CleanupCategory.allCases.compactMap { category in byCategory[category].map { (category, $0) } }
    }

    static func groupID(_ category: CleanupCategory) -> String { category.rawValue }

    /// Checks or unchecks every shown tool of a group that has a cleanup command; checks on hidden tools are kept.
    /// `nil` when no tool of the group can be checked.
    private func checkedBinding(for rows: [ToolStorage]) -> Binding<Bool>? {
        let ids = Set(rows.filter { $0.cleanup != nil }.map(\.id))
        guard !ids.isEmpty else { return nil }
        return Binding(
            get: { ids.isSubset(of: session.checked) },
            set: { checked in
                session.setChecked(checked ? session.checked.union(ids) : session.checked.subtracting(ids))
            })
    }
}

extension ToolStorage {
    /// Whether the tool's name matches the (already trimmed) search text; empty matches every tool.
    fileprivate func matches(_ query: String) -> Bool {
        AppSearch.matches(
            query,
            any: [
                String(localized: tool), location, String(localized: category.title),
                note.map { String(localized: $0) },
            ])
    }
}

/// A group's header: open or close it, check all its tools, and its count and total size.
private struct ToolGroupHeader: View {
    let category: CleanupCategory
    let rows: [ToolStorage]
    @Binding var isExpanded: Bool
    let isChecked: Binding<Bool>?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? Text("Collapse") : Text("Expand"))
            if let isChecked {
                Toggle(isOn: isChecked) {
                    Text("Include all \(Text(category.title))")
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            Image(systemName: category.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(category.title)
                .font(.headline)
            Text("\(rows.count) items")
                .foregroundStyle(.secondary)
            Spacer()
            if let total = rows.compactMap(\.size).reduce(nil, { ($0 ?? 0) + $1 }) {
                SizeText(bytes: total)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { isExpanded.toggle() }
    }
}

private struct ToolRow: View {
    let row: ToolStorage
    let isRunning: Bool
    @Binding var isChecked: Bool
    let clean: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Only tools with their own cleanup command can be checked; the others keep the space for alignment.
            Group {
                if row.cleanup != nil {
                    Toggle(isOn: $isChecked) {
                        Text("Include \(String(localized: row.tool))")
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                } else {
                    Color.clear
                }
            }
            .frame(width: 18)
            Image(systemName: row.category.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.tool)
                if let note = row.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                if let location = row.location { PathText(path: location) }
            }
            Spacer(minLength: 12)
            if let size = row.size {
                SizeText(bytes: size).frame(minWidth: 80, alignment: .trailing)
            } else {
                Text(verbatim: "—").foregroundStyle(.tertiary).frame(minWidth: 80, alignment: .trailing)
            }
            if isRunning {
                ProgressView().controlSize(.small)
            } else if row.cleanup != nil {
                Button(action: clean) {
                    Text("Clean…")
                }
                // Nothing measured to free; an unknown size (—) stays enabled.
                .disabled(row.size == 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shows exactly what will run and that it cannot be undone.
private struct ConfirmToolCleanupSheet: View {
    let row: ToolStorage
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run this command?").font(.title3.bold())
            if let summary = row.cleanup?.summary {
                Text(verbatim: summary)
                    .font(.body.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
            }
            if let note = row.note { Text(note) }
            Label {
                Text("This does not use the Trash and cannot be undone.")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: confirm) {
                    Text("Run")
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct ToolRunResultSheet: View {
    let run: ToolStorageSession.Run

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if run.succeeded {
                Label {
                    Text("Finished")
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
                .font(.title3.bold())
            } else {
                Label {
                    Text("The command did not finish successfully")
                } icon: {
                    Image(systemName: "xmark.octagon").foregroundStyle(.red)
                }
                .font(.title3.bold())
            }
            Text(verbatim: run.summary).font(.callout.monospaced()).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: outputText)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 140, maxHeight: 280)
            .environment(\.layoutDirection, .leftToRight)
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var outputText: String { run.outputText }
}

extension ToolStorageSession.Run {
    fileprivate var succeeded: Bool {
        if let result, result.terminationReason == .exited, result.exitStatus == 0 { true } else { false }
    }

    fileprivate var outputText: String {
        let lines = output.map(\.text)
        if !lines.isEmpty { return lines.joined(separator: "\n") }
        return [result?.standardOutput, result?.standardError].compactMap { $0 }.joined(separator: "\n")
    }
}

/// One confirmation for several tools: every checked tool with the exact command that will run.
private struct ConfirmToolBatchSheet: View {
    let rows: [ToolStorage]
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run these commands?").font(.title3.bold())
            Text("They run one after another, in this order.").foregroundStyle(.secondary)
            List(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.tool).bold()
                        Spacer()
                        if let size = row.size { SizeText(bytes: size).foregroundStyle(.secondary) }
                    }
                    if let summary = row.cleanup?.summary {
                        Text(verbatim: summary)
                            .font(.callout.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, .leftToRight)
                            .textSelection(.enabled)
                    }
                    if let note = row.note { Text(note).font(.callout).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120, idealHeight: 240, maxHeight: 320)
            Label {
                Text("This does not use the Trash and cannot be undone.")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: confirm) {
                    Text("Run")
                }
                .disabled(rows.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// What happened for each tool of a batch, in the order they ran.
private struct ToolBatchResultSheet: View {
    let runs: [ToolStorageSession.Run]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finished").font(.title3.bold())
            List(runs, id: \.rowID) { run in
                DisclosureGroup {
                    Text(verbatim: run.outputText)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, .leftToRight)
                        .textSelection(.enabled)
                } label: {
                    HStack(spacing: 8) {
                        if run.succeeded {
                            Image(systemName: "checkmark.circle").foregroundStyle(.green)
                                .accessibilityLabel(Text("Finished"))
                        } else {
                            Image(systemName: "xmark.octagon").foregroundStyle(.red)
                                .accessibilityLabel(Text("The command did not finish successfully"))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.tool)
                            Text(verbatim: run.summary).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 160, idealHeight: 280, maxHeight: 360)
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
