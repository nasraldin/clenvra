import ClenvraKit
import SwiftUI

/// Storage section: volume bars, then Browser · Large & Old · Downloads & Screenshots over one scan.
struct StorageView: View {
    let session: StorageSession

    @State private var isConfirming = false
    @State private var shownSummary: StorageShownSummary?
    @State private var didLoadClutter = false

    var body: some View {
        VStack(spacing: 0) {
            VolumeBarsView(session: session)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            if session.isPartial, session.list != .clutter {
                partialNotice
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text("Storage"))
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(isPresented: $isConfirming) {
            ConfirmCleanupSheet(count: session.selectedCount, bytes: session.selectedBytes) {
                isConfirming = false
                Task { shownSummary = StorageShownSummary(summary: await session.moveSelectionToTrash()) }
            }
        }
        .sheet(item: $shownSummary) { shown in
            CleanupResultSheet(summary: shown.summary, isPreview: false)
        }
        .task {
            await session.refreshVolumes()
            if session.phase == .idle, session.snapshot == nil { await session.scan() }
        }
        .accessibilityIdentifier("section.storage")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch session.list {
        case .clutter:
            ClutterView(session: session)
                .accessibilityIdentifier("review.results")
                .task {
                    if !didLoadClutter {
                        didLoadClutter = true
                        await session.loadClutter()
                    }
                }
        case .browser, .largeFiles:
            if session.snapshot == nil {
                scanState
            } else if session.list == .browser {
                StorageBrowserView(session: session)
                    .accessibilityIdentifier("review.results")
                    .disabled(isBusy)
            } else {
                LargeFilesView(session: session)
                    .accessibilityIdentifier("review.results")
                    .disabled(isBusy)
            }
        }
    }

    @ViewBuilder private var scanState: some View {
        switch session.phase {
        case .scanning(let progress):
            ScanProgressView(progress: progress) { session.cancelScan() }
        case .failed:
            ContentUnavailableView {
                Label {
                    Text("Could not read this location")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text("Check that the disk is connected and that Clenvra has Full Disk Access.")
            } actions: {
                Button {
                    Task { await session.scan() }
                } label: {
                    Text("Try Again")
                }
            }
        case .idle, .ready, .deleting:
            ContentUnavailableView {
                Label {
                    Text("Not scanned yet")
                } icon: {
                    Image(systemName: "internaldrive")
                }
            } description: {
                Text("Scan to see what uses space.")
            } actions: {
                Button {
                    Task { await session.scan() }
                } label: {
                    Text("Scan")
                }
            }
        }
    }

    private var partialNotice: some View {
        HStack {
            Label {
                Text("Partial results: the scan was stopped before it finished, so sizes may be too small.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            Spacer()
            Button {
                Task { await session.scan() }
            } label: {
                Text("Scan Again")
            }
            .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar and status

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker(selection: listBinding) {
                Text("Browser").tag(StorageList.browser)
                Text("Large & Old").tag(StorageList.largeFiles)
                Text("Downloads & Screenshots").tag(StorageList.clutter)
            } label: {
                Text("View")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("storage.list")
        }
        ToolbarItemGroup {
            if case .scanning = session.phase {
                Button {
                    session.cancelScan()
                } label: {
                    Label {
                        Text("Stop Scan")
                    } icon: {
                        Image(systemName: "stop.circle")
                    }
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    Task {
                        if session.list == .clutter {
                            await session.loadClutter()
                        } else {
                            await session.scan()
                        }
                    }
                } label: {
                    Label {
                        Text("Rescan")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isBusy)
            }

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

    private var listBinding: Binding<StorageList> {
        Binding(get: { session.list }, set: { session.list = $0 })
    }

    private var isBusy: Bool {
        switch session.phase {
        case .idle, .ready, .failed: session.isLoadingClutter
        case .scanning, .deleting: true
        }
    }

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 8) {
            switch session.phase {
            case .deleting:
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…")
            case .scanning(let progress) where session.snapshot != nil:
                ProgressView().controlSize(.small)
                if session.isStale {
                    Text("Updating sizes after the cleanup…")
                } else {
                    Text("Scanning…")
                }
                if let progress {
                    Text("\(progress.filesScanned) files")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            default:
                Text("\(session.selectedCount) items selected")
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
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

struct StorageShownSummary: Identifiable {
    let id = UUID()
    let summary: CleanupSummary
}

/// Indeterminate progress with live counters, the folder being read and a Stop button.
private struct ScanProgressView: View {
    let progress: ScanProgress?
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            if let progress {
                Text(
                    "\(progress.filesScanned) files · \(progress.allocatedBytesSeen.formatted(.byteCount(style: .file))) found"
                )
                .monospacedDigit()
                PathText(path: progress.currentDirectory)
                    .frame(maxWidth: 420)
            } else {
                Text("Scanning…")
                    .foregroundStyle(.secondary)
            }
            Button(action: stop) {
                Text("Stop Scan")
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("storage.scanning")
    }
}

extension StorageView {
    /// Builds the long-lived session for this section from the app's shared services.
    @MainActor
    static func makeSession(environment: AppEnvironment) -> StorageSession {
        let ownership = environment.ownership
        return StorageSession(
            home: environment.home, policy: environment.policy,
            deleter: environment.makeDeleter { ownership.state(of: $0) },
            screenshotsLocation: UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"))
    }
}
