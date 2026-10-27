import ClenvraKit
import SwiftUI

/// Scan → review → confirm → clean → result, for any set of cleanup rules.
struct RuleReviewView<Leading: View>: View {
    let section: AppSection
    let session: CleanupSession
    /// Extra content shown above the rule groups (the Developer section's tool rows).
    @ViewBuilder var leading: Leading

    @State private var isConfirming = false
    @State private var shownSummary: ShownSummary?

    var body: some View {
        content
            .navigationTitle(Text(section.title))
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if !session.groups.isEmpty { statusBar }
            }
            .sheet(isPresented: $isConfirming) {
                ConfirmCleanupSheet(count: session.selectedCount, bytes: session.selectedBytes) {
                    isConfirming = false
                    Task { shownSummary = ShownSummary(summary: await session.clean(), isPreview: false) }
                }
            }
            .sheet(item: $shownSummary) { shown in
                CleanupResultSheet(summary: shown.summary, isPreview: shown.isPreview)
            }
            .task {
                if session.phase == .idle { await session.scan() }
            }
            .accessibilityIdentifier("section.\(section.rawValue)")
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .idle:
            Color.clear
        case .scanning where !session.groups.isEmpty:
            list
                .accessibilityIdentifier("review.results")
        case .scanning(let completed, let total):
            VStack(spacing: 12) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .frame(maxWidth: 320)
                Text("Scanning…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .cleaning:
            if session.groups.allSatisfy(\.candidates.isEmpty) {
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
                list
                    .accessibilityIdentifier("review.results")
            }
        }
    }

    private var list: some View {
        List {
            leading
            ForEach(session.groups) { group in
                Section {
                    if group.candidates.isEmpty {
                        Text("Nothing to clean")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.candidates) { candidate in
                        CandidateRow(
                            candidate: candidate,
                            isSelected: Binding(
                                get: { session.selection.contains(candidate.path) },
                                set: { _ in session.toggle(candidate.path) }))
                    }
                } header: {
                    CategoryHeader(group: group, session: session)
                }
            }
        }
        .disabled(session.phase == .cleaning)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await session.scan() }
            } label: {
                Label {
                    Text("Rescan")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isBusy)

            Button {
                Task { shownSummary = ShownSummary(summary: await session.clean(dryRun: true), isPreview: true) }
            } label: {
                Label {
                    Text("Preview")
                } icon: {
                    Image(systemName: "eye")
                }
            }
            .disabled(isBusy || session.selection.isEmpty)

            Button(role: .destructive) {
                isConfirming = true
            } label: {
                Label {
                    Text("Move to Trash")
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(isBusy || session.selection.isEmpty)
        }
    }

    private var isBusy: Bool {
        switch session.phase {
        case .ready: false
        case .idle, .scanning, .cleaning: true
        }
    }

    private var statusBar: some View {
        HStack {
            if session.phase == .cleaning {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…")
            } else if case .scanning(let completed, let total) = session.phase {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .frame(width: 120)
                Text("Still scanning…")
                    .accessibilityIdentifier("review.scanning")
            } else {
                Text("\(session.selectedCount) items selected")
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text("Frees about \(session.selectedBytes.formatted(.byteCount(style: .file)))")
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ShownSummary: Identifiable {
    let id = UUID()
    let summary: CleanupSummary
    let isPreview: Bool
}

private struct CategoryHeader: View {
    let group: CleanupSession.Group
    let session: CleanupSession

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.category.title).font(.headline)
                    Text(group.category.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            } icon: {
                Image(systemName: group.category.symbol)
            }
            Spacer()
            let selectable = group.candidates.filter { $0.status == .available }
            if !selectable.isEmpty {
                let allSelected = selectable.allSatisfy { session.selection.contains($0.path) }
                Button {
                    session.setSelected(!allSelected, category: group.category)
                } label: {
                    Text(allSelected ? "Deselect All" : "Select All")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: CleanupCandidate
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isSelected) {
                Text(verbatim: candidate.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(candidate.status != .available)

            Image(systemName: candidate.kind == .directory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: candidate.name)
                    .lineLimit(1)
                PathText(path: candidate.path)
            }

            Spacer(minLength: 12)
            StatusBadge(candidate: candidate)
            SizeText(bytes: candidate.reclaimableSize)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(candidate.path, inFileViewerRootedAtPath: "")
            } label: {
                Text("Show in Finder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(candidate.path, forType: .string)
            } label: {
                Text("Copy Path")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension RuleReviewView where Leading == EmptyView {
    init(section: AppSection, session: CleanupSession) {
        self.init(section: section, session: session) { EmptyView() }
    }
}
