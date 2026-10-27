import ClenvraKit
import SwiftUI

/// Review of what resetting an app removes (AP-7): its own settings, caches and saved state, grouped by
/// confidence. The app itself stays installed. Possible matches are never selected automatically.
struct ResetAppSheet: View {
    let session: AppsSession
    let app: InstalledApp
    /// Runs the reset with the chosen items; the caller closes this sheet and shows the result.
    let reset: (_ items: [OwnedItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [OwnedItem]?
    @State private var selection: Set<String> = []
    @State private var isConfirming = false
    @State private var preview: ShownPreview?

    private struct ShownPreview: Identifiable {
        let id = UUID()
        /// `nil` when the app became unavailable, so nothing was checked.
        let summary: CleanupSummary?
    }

    private struct ConfidenceGroup: Identifiable {
        var id: OwnedItem.Confidence { confidence }
        let confidence: OwnedItem.Confidence
        let items: [OwnedItem]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Reset \(app.name)?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.secondary)
            }
            Text("Removes the app's settings, caches and saved state. The app stays installed.")
                .foregroundStyle(.secondary)
            if isRunning {
                HStack {
                    Label {
                        Text("Quit \(app.name) to reset it.")
                    } icon: {
                        Image(systemName: "app.badge.clock")
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await session.quitSelectedApp() }
                    } label: {
                        Text("Quit \(app.name)")
                    }
                }
            }
            content
                .frame(minHeight: 240, maxHeight: 420)
            HStack {
                if !chosen.isEmpty {
                    Text("Frees about \(chosenBytes.formatted(.byteCount(style: .file)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    let items = chosen
                    Task { preview = ShownPreview(summary: await session.reset(app, items: items, dryRun: true)) }
                } label: {
                    Text("Preview")
                }
                .disabled(!canReset)
                Button(role: .destructive) {
                    isConfirming = true
                } label: {
                    Text("Reset…")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canReset)
            }
        }
        .padding(24)
        .frame(width: 600)
        .task(id: app.id) {
            let found = await session.resetItems(for: app)
            items = found
            selection = Set(
                found.filter { $0.isSelectedByDefault && $0.confidence != .possible && session.isSelectable($0) }
                    .map(\.path))
        }
        .sheet(isPresented: $isConfirming) {
            ConfirmResetSheet(appName: app.name, count: chosen.count, bytes: chosenBytes) {
                isConfirming = false
                reset(chosen)
            }
        }
        .sheet(item: $preview) { shown in
            if let summary = shown.summary {
                CleanupResultSheet(summary: summary, isPreview: true)
            } else {
                NotUninstalledSheet()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let items {
            if items.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Nothing to reset")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                } description: {
                    Text("No settings, caches or saved state were found for this app.")
                }
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                OwnedItemRow(
                                    item: item, sharedNames: names(for: item.sharedWith),
                                    isSelectable: session.isSelectable(item),
                                    isSelected: Binding(
                                        get: { selection.contains(item.path) },
                                        set: { _ in toggle(item) }))
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.confidence.title).font(.headline)
                                Text(group.confidence.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }
                    }
                }
                .disabled(session.isWorking)
                .accessibilityIdentifier("review.results")
            }
        } else {
            ProgressView {
                Text("Finding the app's files…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var groups: [ConfidenceGroup] {
        let items = items ?? []
        return OwnedItem.Confidence.allCases.compactMap { confidence in
            let matching = items.filter { $0.confidence == confidence }
            return matching.isEmpty ? nil : ConfidenceGroup(confidence: confidence, items: matching)
        }
    }

    private var chosen: [OwnedItem] {
        (items ?? []).filter { selection.contains($0.path) && session.isSelectable($0) }
    }

    private var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.reclaimableSize } }

    private var isRunning: Bool { session.detail?.app.id == app.id && session.detail?.availability == .running }

    private var canReset: Bool {
        !chosen.isEmpty && !session.isWorking && session.detail?.app.id == app.id
            && session.detail?.availability == .available
    }

    private func toggle(_ item: OwnedItem) {
        if selection.contains(item.path) {
            selection.remove(item.path)
        } else if session.isSelectable(item) {
            selection.insert(item.path)
        }
    }

    private func names(for appIDs: [String]) -> [String] {
        appIDs.map { id in session.apps.first { $0.id == id }?.name ?? (id as NSString).lastPathComponent }
    }
}

/// Confirmation before moving an app's settings, caches and saved state to the Trash.
struct ConfirmResetSheet: View {
    let appName: String
    let count: Int
    let bytes: Int64
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Reset \(appName)?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.secondary)
            }
            Text("\(count) items will be moved to the Trash. The app stays installed.")
            Text("This frees about \(bytes.formatted(.byteCount(style: .file))).")
            Text(
                "The app starts as if it were opened for the first time. Every item is checked again just before it is moved. You can put items back from Activity."
            )
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: confirm) {
                    Text("Reset")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
