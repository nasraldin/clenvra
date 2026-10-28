import AppKit
import ClenvraKit
import SwiftUI

/// Extensions and plug-ins that add code to macOS or other apps. Only the user's own plug-in bundles can be
/// removed; everything else is shown so the user knows it is there, and can be revealed in Finder.
struct PluginsView: View {
    let session: PluginsSession

    @State private var isConfirming = false
    @State private var shownSummary: ShownPluginSummary?

    var body: some View {
        VStack(spacing: 0) {
            content
            if session.removableCount > 0 { statusBar }
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { session.showsAppleItems }, set: { session.showsAppleItems = $0 })) {
                    Text("Show Apple Items")
                }
                .accessibilityIdentifier("plugins.showApple")

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
        .sheet(isPresented: $isConfirming) {
            ConfirmCleanupSheet(count: session.selectedCount, bytes: session.selectedBytes) {
                isConfirming = false
                Task { shownSummary = ShownPluginSummary(summary: await session.remove()) }
            }
        }
        .sheet(item: $shownSummary) { shown in
            CleanupResultSheet(summary: shown.summary, isPreview: false)
        }
        .task {
            if session.phase == .idle { await session.scan() }
        }
    }

    private var isBusy: Bool { session.phase != .ready }

    @ViewBuilder private var content: some View {
        if session.phase == .scanning && session.groups.isEmpty {
            ProgressView {
                Text("Looking for extensions and plug-ins…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("review.scanning")
        } else if session.groups.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No extensions or plug-ins found")
                } icon: {
                    Image(systemName: "puzzlepiece.extension")
                }
            } description: {
                Text("Turn on Show Apple Items to see the ones built into macOS.")
            }
            .accessibilityIdentifier("review.results")
        } else {
            List {
                if !session.issues.isEmpty {
                    Section {
                        Text("Some extensions could not be listed, so this list may be incomplete.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(session.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            PluginRow(
                                item: item, isSelectable: session.canSelect(item),
                                isSelected: Binding(
                                    get: { session.selection.contains(item.id) },
                                    set: { _ in session.toggle(item.id) }))
                        }
                    } header: {
                        Text(group.kind.title)
                    }
                }
            }
            .disabled(session.phase == .removing)
            .accessibilityIdentifier("review.results")
        }
    }

    private var statusBar: some View {
        HStack {
            if session.phase == .removing {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…")
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

private struct PluginRow: View {
    let item: PluginItem
    let isSelectable: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: $isSelected) {
                Text(verbatim: item.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isSelectable)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: item.name)
                        .lineLimit(1)
                    if let version = item.version {
                        Text(verbatim: version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    handlingBadge
                }
                if let path = item.path {
                    PathText(path: path)
                } else if let identifier = item.bundleIdentifier {
                    Text(verbatim: identifier)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let app = item.containingApp {
                    Text("Part of \(app)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let size = item.size {
                Text(size.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let path = item.path {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(Text("Show in Finder"))
                .accessibilityLabel(Text("Show in Finder"))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var handlingBadge: some View {
        switch item.handling {
        case .removable:
            EmptyView()
        case .managed:
            Text("Security or management software")
                .font(.caption)
                .foregroundStyle(.orange)
        case .revealOnly:
            if item.isEnabled == false {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
