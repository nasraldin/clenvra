import AppKit
import ClenvraKit
import QuickLook
import SwiftUI

/// Storage › Similar Photos: choose folders → scan → review groups (one photo always kept, nothing marked for you)
/// → confirm → move the marked photos to the Trash.
struct SimilarPhotosView: View {
    let session: SimilarPhotosSession

    @State private var isShowingOptions = false
    @State private var isConfirming = false
    @State private var shownSummary: StorageShownSummary?
    @State private var previewURL: URL?
    @State private var focusedPath: String?
    @State private var searchText = ""

    /// Groups the person closed, remembered across launches (F4).
    private let expansion = ExpandedGroups("similarPhotos")

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { toolbar }
            .pageSearch(text: $searchText, prompt: "Search by File Name", section: .similarPhotos)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if hasResults { statusBar }
            }
            .sheet(isPresented: $isConfirming) {
                ConfirmCleanupSheet(count: session.markedCount, bytes: session.markedBytes) {
                    isConfirming = false
                    Task { shownSummary = StorageShownSummary(summary: await session.moveMarkedToTrash()) }
                }
            }
            .sheet(item: $shownSummary) { shown in
                CleanupResultSheet(summary: shown.summary, isPreview: false)
            }
            .quickLookPreview($previewURL, in: previewURLs)
            .task { await session.loadDefaultRoots() }
    }

    /// Unlike the table pages, the start and progress screens replace the photo list: drawn over it, the list's
    /// photo grid confuses the accessibility tree. The page's toolbar does not depend on the list, so it stays put.
    @ViewBuilder private var content: some View {
        if showsState {
            state
        } else {
            SimilarPhotoGroupsList(
                session: session, focusedPath: $focusedPath, previewURL: $previewURL,
                isExpanded: { id in expansion.binding(id) { sectionIDs } }, query: AppSearch.normalized(searchText)
            )
            .accessibilityIdentifier("review.results")
        }
    }

    private var showsState: Bool {
        switch session.phase {
        case .idle, .scanning: true
        case .ready: !hasResults
        case .removing: false
        }
    }

    @ViewBuilder private var state: some View {
        switch session.phase {
        case .idle:
            SimilarPhotosStartView(session: session) {
                Task { await session.scan() }
            }
        case .scanning(let progress):
            SimilarPhotosProgressView(progress: progress) {
                session.cancelScan()
            }
        case .ready, .removing:
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label {
                        Text("No similar photos found")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                } description: {
                    if session.lastScanWasComplete {
                        Text("No photos that look alike were found in the folders you chose.")
                    } else {
                        Text("The scan was stopped before it finished.")
                    }
                } actions: {
                    Button {
                        isShowingOptions = true
                    } label: {
                        Text("Search Options")
                    }
                }
                SimilarPhotosSkippedList(skipped: session.skipped)
                    .padding(16)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.results")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            ScanButton(
                isScanning: { if case .scanning = session.phase { true } else { false } }(),
                isDisabled: session.phase == .removing || session.roots.isEmpty,
                scan: { Task { await session.scan() } }, stop: { session.cancelScan() })

            ExpandAllButton(allExpanded: expansion.allBinding(sectionIDs))
                .disabled(!hasResults)

            Menu {
                Button {
                    session.markAllButSuggested()
                } label: {
                    Text("Mark All but the Best in Every Group")
                }
                .disabled(session.groups.isEmpty)
                Divider()
                Button {
                    session.unmarkAll()
                } label: {
                    Text("Unmark All")
                }
            } label: {
                ToolbarLabel(title: "Choose Photos", symbol: "checklist")
            }
            .disabled(session.phase != .ready || !hasResults)

            Button {
                isShowingOptions.toggle()
            } label: {
                ToolbarLabel(title: "Search Options", symbol: "slider.horizontal.3")
            }
            .disabled(session.phase == .idle)
            // A popover, not an inspector: an inspector here would push the results under the toolbar.
            .popover(isPresented: $isShowingOptions, arrowEdge: .bottom) {
                SimilarPhotosFolders(session: session)
                    .frame(width: 380, height: 320)
            }

        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            PrimaryActionButton(
                help: "Review and move the marked photos to the Trash (⌘⌫)",
                isDisabled: session.phase != .ready || session.markedCount == 0
            ) {
                isConfirming = true
            }
        }
    }

    /// Whether there is anything to review: similar groups or blurry or dark photos.
    private var hasResults: Bool { !session.groups.isEmpty || !session.lowQualityPhotos.isEmpty }

    /// Expansion ids of every section shown, the blurry or dark photos first.
    private var sectionIDs: [String] {
        (session.lowQualityPhotos.isEmpty ? [] : [SimilarPhotoGroupsList.lowQualityID]) + session.groups.map(\.id)
    }

    /// Every photo shown, once, in page order, for Quick Look.
    private var previewURLs: [URL] {
        var seen = Set<String>()
        return (session.lowQualityPhotos + session.groups.flatMap(\.photos)).compactMap { photo in
            seen.insert(photo.path).inserted ? URL(filePath: photo.path) : nil
        }
    }

    private var statusBar: some View {
        SelectionStatusBar(
            count: session.markedCount, bytes: session.markedBytes,
            working: session.phase == .removing ? "Moving to the Trash…" : nil)
    }
}

/// The folders to search; used on the start screen and in the inspector.
private struct SimilarPhotosFolders: View {
    let session: SimilarPhotosSession

    var body: some View {
        Form {
            Section {
                if session.roots.isEmpty {
                    Text("Add at least one folder to search.")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.roots, id: \.self) { root in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: root))
                            .resizable()
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        PathText(path: root)
                        Spacer()
                        Button {
                            session.removeRoot(root)
                        } label: {
                            Label {
                                Text("Remove")
                            } icon: {
                                Image(systemName: "minus.circle")
                            }
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove"))
                    }
                }
                Button {
                    chooseFolders()
                } label: {
                    Label {
                        Text("Add Folder…")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            } header: {
                Text("Folders to Search")
            } footer: {
                Text("Hidden files and the Photos library are not searched.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(isBusy)
    }

    private var isBusy: Bool {
        switch session.phase {
        case .scanning, .removing: true
        case .idle, .ready: false
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            session.addRoot(url.path(percentEncoded: false))
        }
    }
}

/// First screen: what will be searched, and the button to start.
private struct SimilarPhotosStartView: View {
    let session: SimilarPhotosSession
    let start: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SimilarPhotosFolders(session: session)
            HStack {
                Text("Nothing is marked for you. One photo in every group is always kept.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: start) {
                    Text("Find Similar Photos")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.roots.isEmpty)
            }
            .padding(16)
        }
    }
}

/// Stage-aware scan progress with a Stop button.
private struct SimilarPhotosProgressView: View {
    let progress: SimilarPhotoScanProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if progress.phase == .analyzing, progress.imagesFound > 0 {
                ProgressView(value: Double(progress.imagesAnalyzed), total: Double(progress.imagesFound))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            title
                .font(.headline)
            detail
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: cancel) {
                Text("Stop")
            }
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.scanning")
    }

    @ViewBuilder private var title: some View {
        switch progress.phase {
        case .listing: Text("Looking for photos…")
        case .analyzing: Text("Comparing photos…")
        case .grouping: Text("Grouping similar photos…")
        }
    }

    @ViewBuilder private var detail: some View {
        switch progress.phase {
        case .listing:
            Text("\(progress.filesSeen) files checked · \(progress.imagesFound) photos found")
        case .analyzing, .grouping:
            Text("\(progress.imagesAnalyzed) of \(progress.imagesFound) photos compared")
        }
    }
}
