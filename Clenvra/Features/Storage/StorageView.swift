import ClenvraKit
import SwiftUI

/// The storage pages: Space Map, Large & Old Files and Downloads share one scan; Similar Photos has its own.
/// Each is its own sidebar page.
struct StorageView: View {
    let session: StorageSession
    let similarPhotos: SimilarPhotosSession
    let page: StoragePage
    /// Opens another page, for the links in "What's in System Data".
    let navigate: (AppSection) -> Void

    @State private var isConfirming = false
    @State private var isShowingSystemData = false
    @State private var shownSummary: StorageShownSummary?
    private var showsSimilarPhotos: Bool { page == .similarPhotos }

    private var pageSection: AppSection {
        switch page {
        case .browser: .storage
        case .largeFiles: .largeFiles
        case .clutter: .downloads
        case .similarPhotos: .similarPhotos
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The disks belong to Space Map; the cleanup pages show only their own results.
            if page == .browser {
                VolumeBarsView(session: session)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider()
            }
            if session.isPartial, page == .browser || page == .largeFiles {
                partialNotice
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Anchored to the top: if the page is ever taller than the window, it is cut at the bottom, never pushed up
        // under the toolbar.
        .frame(maxHeight: .infinity, alignment: .top)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showsSimilarPhotos { statusBar }
        }
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
            if let list = page.list {
                session.list = list
            } else {
                // Nothing selected in a hidden list may be moved to the Trash.
                session.setSelection([])
            }
            await session.refreshVolumes()
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if showsSimilarPhotos {
            SimilarPhotosView(session: similarPhotos)
        } else {
            scanContent
        }
    }

    @ViewBuilder private var scanContent: some View {
        switch page.list ?? .browser {
        case .clutter:
            ClutterView(session: session)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("review.results")
                .accessibilityLabel(Text(pageSection.title))
                .pageState(isShown: !session.hasLoadedClutter && !session.isLoadingClutter) {
                    ScanPrompt(
                        section: .downloads,
                        description:
                            "List the files in Downloads and your screenshots by kind, age and source, so you can remove what you no longer need."
                    ) {
                        Task { await session.loadClutter() }
                    }
                }
        case .browser:
            StorageBrowserView(session: session)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("review.results")
                .accessibilityLabel(Text(pageSection.title))
                .disabled(isBusy)
                .pageState(isShown: session.snapshot == nil) { scanState }
        case .largeFiles:
            LargeFilesView(session: session)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("review.results")
                .accessibilityLabel(Text(pageSection.title))
                .disabled(isBusy)
                .pageState(isShown: session.snapshot == nil) { scanState }
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
            ScanPrompt(
                section: pageSection,
                description: page == .largeFiles
                    ? "Find the biggest files you have not opened in a long time."
                    : "See which folders use the most space, and open any folder to look inside."
            ) {
                Task { await session.scan() }
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
        if !showsSimilarPhotos { scanToolbar }
    }

    @ToolbarContentBuilder private var scanToolbar: some ToolbarContent {
        if page == .largeFiles {
            ToolbarItem {
                ScanTargetMenu(session: session)
            }
        }

        if page == .browser {
            ToolbarItem {
                Button {
                    isShowingSystemData.toggle()
                } label: {
                    ToolbarLabel(title: "What's in System Data", symbol: "questionmark.circle")
                }
                .help(Text("What's in System Data"))
                .accessibilityIdentifier("storage.systemDataButton")
                .popover(isPresented: $isShowingSystemData, arrowEdge: .bottom) {
                    SystemDataView(rootVolume: session.volumes.first(where: \.isRoot)) { section in
                        isShowingSystemData = false
                        navigate(section)
                    }
                }
            }
        }

        ToolbarItemGroup {
            ScanButton(
                isScanning: { if case .scanning = session.phase { true } else { false } }(), title: "Rescan",
                isDisabled: isBusy,
                scan: {
                    Task {
                        if page == .clutter {
                            await session.loadClutter()
                        } else {
                            await session.scan()
                        }
                    }
                }, stop: { session.cancelScan() })
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            PrimaryActionButton(isDisabled: isBusy || session.selection.isEmpty) {
                isConfirming = true
            }
        }
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
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .statusBarBackground()
    }
}

/// The storage pages: the scan's three lists, plus Similar Photos.
enum StoragePage: Hashable {
    case browser, largeFiles, clutter, similarPhotos

    var list: StorageList? {
        switch self {
        case .browser: .browser
        case .largeFiles: .largeFiles
        case .clutter: .clutter
        case .similarPhotos: nil
        }
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
