import AppKit
import ClenvraKit
import SwiftUI

/// The review page for rule-based cleanup (System Junk, Developer Junk): scan on request, a table of collapsible
/// categories with a checkbox per item, details in the inspector, and one prominent Move to Trash action.
///
/// Highlighting a row (click, arrows) shows its details; the checkbox decides what is cleaned, as in Finder lists
/// with checkboxes. Nothing scans until the person asks.
struct RuleReviewView<MoreActions: View>: View {
    let section: AppSection
    let session: CleanupSession
    /// What this page looks for, shown before the first scan.
    let introduction: LocalizedStringResource
    /// Adds a folder to the exclusions (Settings › Exclusions); nil hides the command.
    var exclude: ((String) -> Void)?
    /// Extra commands in the toolbar's More menu.
    @ViewBuilder var moreActions: MoreActions

    @State private var highlighted: Set<ReviewRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\ReviewRow.size, order: .reverse)]
    @State private var searchText = ""
    private var query: String { AppSearch.normalized(searchText) }
    @State private var showsInspector = false
    @State private var isConfirming = false
    @State private var shownSummary: ShownSummary?
    /// Categories the person closed, remembered per page across launches.
    private let groups: ExpandedGroups

    init(
        section: AppSection, session: CleanupSession, introduction: LocalizedStringResource,
        exclude: ((String) -> Void)? = nil, @ViewBuilder moreActions: () -> MoreActions
    ) {
        self.section = section
        self.session = session
        self.introduction = introduction
        self.exclude = exclude
        self.moreActions = moreActions()
        groups = ExpandedGroups(section.rawValue)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !session.groups.isEmpty || isScanning { statusBar }
            }
            .pageSearch(text: $searchText, prompt: "Search by Name or Location", section: section)
            .toolbar { toolbar }
            .detailsPanel(isPresented: $showsInspector, width: 280) {
                ReviewInspector(candidates: highlightedCandidates, session: session)
            }
            .sheet(isPresented: $isConfirming) {
                ConfirmCleanupSheet(
                    count: session.selectedCount, bytes: session.selectedBytes,
                    includesPermanentRemoval: session.selectionIncludesPermanentRemoval
                ) {
                    isConfirming = false
                    Task { shownSummary = ShownSummary(summary: await session.clean(), isPreview: false) }
                }
            }
            .sheet(item: $shownSummary) { shown in
                CleanupResultSheet(summary: shown.summary, isPreview: shown.isPreview)
            }
    }

    // MARK: - Content

    private var content: some View {
        table
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(section.title))
            .pageState(isShown: showsState) { state }
    }

    /// Before the first scan, while the first results come in, and when nothing is listed.
    private var showsState: Bool {
        (session.lastScanned == nil && !isScanning) || visibleGroups.isEmpty
    }

    @ViewBuilder private var state: some View {
        if session.lastScanned == nil && !isScanning {
            ContentUnavailableView {
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.symbol)
                }
            } description: {
                Text(introduction)
            } actions: {
                Button {
                    Task { await session.scan() }
                } label: {
                    Text("Scan")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("review.scan")
            }
        } else if session.groups.isEmpty, case .scanning(let completed, let total) = session.phase {
            VStack(spacing: 12) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .frame(maxWidth: 320)
                Text("Scanning \(completed) of \(total) locations…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityIdentifier("review.scanning")
        } else if query.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("Nothing to clean")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } description: {
                Text("No items were found in this section on this Mac.")
            }
            .accessibilityIdentifier("review.results")
        } else {
            ContentUnavailableView.search(text: query)
                .accessibilityIdentifier("review.results")
        }
    }

    private var table: some View {
        Table(of: ReviewRow.self, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn(Text("Name"), value: \.name) { row in
                HStack(spacing: 6) {
                    checkbox(for: row)
                    ReviewNameCell(row: row)
                }
            }
            .width(min: 240, ideal: 360)

            TableColumn(Text("Size"), value: \.size) { row in
                SizeText(bytes: row.size)
                    .fontWeight(row.candidate == nil ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn(Text("Status")) { row in
                if let candidate = row.candidate {
                    StatusBadge(
                        candidate: candidate,
                        needsHelper: session.requiresHelper(candidate) && !session.helperAvailable)
                } else {
                    Text("\(row.itemCount) items")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn(Text("Modified"), value: \.modifiedSort) { row in
                if row.modifiedSort > .distantPast {
                    Text(row.modifiedSort, format: .dateTime.year().month(.abbreviated).day())
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "—")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Unknown"))
                }
            }
            .width(min: 90, ideal: 110)

        } rows: {
            ForEach(visibleGroups) { group in
                DisclosureTableRow(ReviewRow(group: group), isExpanded: expandedBinding(group.category)) {
                    ForEach(sortedRows(of: group)) { row in
                        TableRow(row)
                    }
                }
            }
        }
        // Group rows already separate the list; grey stripes under short names fall below readable contrast.
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: ReviewRow.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            highlighted = ids
            showsInspector = true
        }
        .disabled(session.phase == .cleaning)
    }

    @ViewBuilder private func checkbox(for row: ReviewRow) -> some View {
        if let candidate = row.candidate {
            Toggle(isOn: checkedBinding(candidate)) {
                Text("Include \(candidate.name)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!session.canSelect(candidate))
        } else if let group = session.groups.first(where: { $0.category == row.category }) {
            let bindings = group.candidates.filter { session.canSelect($0) }.map(checkedBinding)
            Toggle(sources: bindings, isOn: \.self) {
                Text("Include all \(Text(group.category.title))")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(bindings.isEmpty)
        }
    }

    @ViewBuilder private func contextMenu(for ids: Set<ReviewRow.ID>) -> some View {
        let items = candidates(for: ids)
        if !items.isEmpty {
            Button {
                highlighted = ids
                showsInspector = true
            } label: {
                Text("Show Details")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(filePath: $0.path) })
            } label: {
                Text("Show in Finder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            } label: {
                Text(items.count == 1 ? "Copy Path" : "Copy Paths")
            }
            Divider()
            let selectable = items.filter { session.canSelect($0) }
            if !selectable.isEmpty {
                let allChecked = selectable.allSatisfy { session.selection.contains($0.path) }
                Button {
                    for item in selectable where session.selection.contains(item.path) == allChecked {
                        session.toggle(item.path)
                    }
                } label: {
                    Text(allChecked ? "Don’t Include" : "Include")
                }
            }
            if let exclude, items.count == 1, let item = items.first {
                Button {
                    if session.selection.contains(item.path) { session.toggle(item.path) }
                    exclude(item.path)
                } label: {
                    Text("Exclude from Scans")
                }
            }
        }
    }

    // MARK: - Toolbar and status

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await session.scan() }
            } label: {
                ToolbarLabel(title: session.lastScanned == nil ? "Scan" : "Rescan", symbol: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Look for items again (⌘R)"))
            .disabled(isBusy)

            ExpandAllButton(allExpanded: groups.allBinding(session.groups.map(\.category.rawValue)))
                .disabled(session.groups.isEmpty)

            Menu {
                Button {
                    Task { shownSummary = ShownSummary(summary: await session.clean(dryRun: true), isPreview: true) }
                } label: {
                    Text("Preview Cleanup")
                }
                .disabled(isBusy || session.selection.isEmpty)
                moreActions
            } label: {
                ToolbarLabel(title: "More", symbol: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help(Text("More actions"))
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            PrimaryActionButton(
                help: "Review and move the included items to the Trash (⌘⌫)",
                isDisabled: isBusy || session.selection.isEmpty
            ) {
                isConfirming = true
            }
        }

        ToolbarItem {
            InspectorToggle(isPresented: $showsInspector)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if session.phase == .cleaning {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…")
            } else if case .scanning(let completed, let total) = session.phase {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .frame(width: 120)
                Text("Still scanning…")
                    .accessibilityIdentifier("review.scanning")
            } else {
                Text("\(session.selectedCount) items included")
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text("Frees about \(session.selectedBytes.formatted(.byteCount(style: .file)))")
                if let scanned = session.lastScanned {
                    Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text("Scanned \(scanned.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .statusBarBackground()
    }

    // MARK: - Data

    private var isScanning: Bool {
        if case .scanning = session.phase { true } else { false }
    }

    private var isBusy: Bool {
        switch session.phase {
        case .idle, .ready: false
        case .scanning, .cleaning: true
        }
    }

    /// Groups with at least one item matching the search.
    private var visibleGroups: [CleanupSession.Group] {
        session.groups.filter { !matches(in: $0).isEmpty }
    }

    private func matches(in group: CleanupSession.Group) -> [CleanupCandidate] {
        // A search for the group's own title ("Xcode", "Logs"…) shows the whole group.
        if AppSearch.matches(query, String(localized: group.category.title)) { return group.candidates }
        return group.candidates.filter { AppSearch.matches(query, any: [$0.name, $0.path]) }
    }

    private func sortedRows(of group: CleanupSession.Group) -> [ReviewRow] {
        matches(in: group).map { ReviewRow(candidate: $0, category: group.category) }.sorted(using: sortOrder)
    }

    private var highlightedCandidates: [CleanupCandidate] { candidates(for: highlighted) }

    private func candidates(for ids: Set<ReviewRow.ID>) -> [CleanupCandidate] {
        session.groups.flatMap(\.candidates).filter { ids.contains($0.path) }
    }

    private func checkedBinding(_ candidate: CleanupCandidate) -> Binding<Bool> {
        Binding(
            get: { session.selection.contains(candidate.path) },
            set: { checked in
                if session.selection.contains(candidate.path) != checked { session.toggle(candidate.path) }
            })
    }

    private func expandedBinding(_ category: CleanupCategory) -> Binding<Bool> {
        groups.binding(category.rawValue) { session.groups.map(\.category.rawValue) }
    }
}

extension RuleReviewView where MoreActions == EmptyView {
    init(
        section: AppSection, session: CleanupSession, introduction: LocalizedStringResource,
        exclude: ((String) -> Void)? = nil
    ) {
        self.init(section: section, session: session, introduction: introduction, exclude: exclude) {
            EmptyView()
        }
    }
}

/// One table row: a category (with its items as children) or one item. Plain data, not tied to the main actor, so
/// the table can sort by its key paths.
nonisolated struct ReviewRow: Identifiable, Sendable {
    let id: String
    let category: CleanupCategory
    let candidate: CleanupCandidate?
    let name: String
    let size: Int64
    let modifiedSort: Date
    let itemCount: Int

    init(group: CleanupSession.Group) {
        id = "category:" + group.category.rawValue
        category = group.category
        candidate = nil
        name = group.category.rawValue  // Category rows are not sorted; the cell shows the localized title.
        size = group.candidates.reduce(0) { $0 + $1.reclaimableSize }
        modifiedSort = group.candidates.compactMap(\.modificationDate).max() ?? .distantPast
        itemCount = group.candidates.count
    }

    init(candidate: CleanupCandidate, category: CleanupCategory) {
        id = candidate.path
        self.category = category
        self.candidate = candidate
        name = candidate.name
        size = candidate.reclaimableSize
        modifiedSort = candidate.modificationDate ?? .distantPast
        itemCount = 1
    }
}

/// Name with the Finder icon for an item, or the category symbol and item count for a category.
private struct ReviewNameCell: View {
    let row: ReviewRow

    var body: some View {
        if let candidate = row.candidate {
            FileNameCell(name: candidate.name, path: candidate.path)
        } else {
            Label {
                Text(row.category.title)
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: row.category.symbol)
            }
            .help(Text(row.category.explanation))
        }
    }
}

private struct ShownSummary: Identifiable {
    let id = UUID()
    let summary: CleanupSummary
    let isPreview: Bool
}
