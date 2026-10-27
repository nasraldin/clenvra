import AppKit
import ClenvraKit
import SwiftUI

/// Files left behind by apps that are no longer installed. Nothing here is ever selected automatically.
struct LeftoversView: View {
    let session: AppsSession

    @State private var isConfirming = false
    @State private var shownSummary: ShownLeftoverSummary?

    var body: some View {
        VStack(spacing: 0) {
            content
            if !session.leftovers.isEmpty { statusBar }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await session.scanLeftovers() }
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
                    Task {
                        shownSummary = ShownLeftoverSummary(
                            summary: await session.removeLeftovers(dryRun: true), isPreview: true)
                    }
                } label: {
                    Label {
                        Text("Preview")
                    } icon: {
                        Image(systemName: "eye")
                    }
                }
                .disabled(isBusy || session.leftoverSelection.isEmpty)

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
                .disabled(isBusy || session.leftoverSelection.isEmpty)
            }
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
            if session.phase == .idle { await session.load() }
            if !session.hasScannedLeftovers { await session.scanLeftovers() }
        }
    }

    private var isBusy: Bool { session.isScanningLeftovers || session.isWorking || session.phase != .ready }

    @ViewBuilder private var content: some View {
        if session.isScanningLeftovers && session.leftovers.isEmpty {
            ProgressView {
                Text("Looking for leftovers…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.leftovers.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No leftovers found")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } description: {
                Text("No files from removed apps were found, or they were changed in the last 30 days.")
            }
            .accessibilityIdentifier("review.results")
        } else {
            List {
                Section {
                    ForEach(session.leftovers) { item in
                        OwnedItemRow(
                            item: item, sharedNames: [], isSelectable: session.isSelectable(item),
                            isSelected: Binding(
                                get: { session.leftoverSelection.contains(item.path) },
                                set: { _ in session.toggleLeftover(item.path) }))
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Leftovers of removed apps").font(.headline)
                        Text(
                            "These files are named after apps that are no longer installed and haven't changed for 30 days. Check each one before removing it."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    }
                }
            }
            .disabled(session.isWorking)
            .accessibilityIdentifier("review.results")
        }
    }

    private var statusBar: some View {
        HStack {
            if session.isWorking {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…")
            } else {
                Text("\(session.leftoverSelection.count) items selected")
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text("Frees about \(session.leftoverSelectedBytes.formatted(.byteCount(style: .file)))")
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ShownLeftoverSummary: Identifiable {
    let id = UUID()
    let summary: CleanupSummary
    let isPreview: Bool
}
