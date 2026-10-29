import ClenvraKit
import QuickLook
import SwiftUI

/// Choose folders → scan → review groups (one copy always kept) → confirm → move extra copies to the Trash.
struct DuplicatesView: View {
    @State private var session: DuplicatesSession
    @State private var isShowingOptions = false
    @State private var isConfirming = false
    @State private var shownSummary: ShownDuplicatesSummary?
    @State private var previewURL: URL?
    @State private var highlighted: Set<DuplicateRow.ID> = []
    @State private var showsInspector = false
    @State private var query = ""

    init(session: DuplicatesSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .accessibilityElement(children: .contain)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if !session.groups.isEmpty {
                    SelectionStatusBar(
                        count: session.markedCount, bytes: session.markedBytes,
                        working: session.phase == .removing ? "Moving to the Trash…" : nil)
                }
            }
            .inspector(isPresented: $showsInspector) {
                DuplicateInspector(session: session, highlighted: highlighted)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text("Search by Name or Location"))
            .sheet(isPresented: $isConfirming) {
                ConfirmCleanupSheet(count: session.markedCount, bytes: session.markedBytes) {
                    isConfirming = false
                    Task { shownSummary = ShownDuplicatesSummary(summary: await session.moveMarkedToTrash()) }
                }
            }
            .sheet(item: $shownSummary) { shown in
                CleanupResultSheet(summary: shown.summary, isPreview: false)
            }
            .quickLookPreview($previewURL)
            .task { await session.loadDefaultRoots() }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .idle:
            DuplicatesStartView(session: session) {
                Task { await session.scan() }
            }
        case .scanning(let progress):
            DuplicatesProgressView(progress: progress) {
                session.cancelScan()
            }
        case .ready where session.groups.isEmpty:
            ContentUnavailableView {
                Label {
                    Text("No duplicates found")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } description: {
                if session.lastScanWasComplete {
                    Text("No identical files were found in the folders you chose.")
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
            .accessibilityIdentifier("review.results")
        case .ready, .removing:
            DuplicateGroupsList(
                session: session, previewURL: $previewURL, highlighted: $highlighted,
                showsInspector: $showsInspector, query: query
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(AppSection.duplicates.title))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if case .scanning = session.phase {
                Button {
                    session.cancelScan()
                } label: {
                    Label {
                        Text("Stop")
                    } icon: {
                        Image(systemName: "stop.circle")
                    }
                }
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    Task { await session.scan() }
                } label: {
                    Label {
                        Text("Scan")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session.phase == .removing || session.roots.isEmpty)
            }

            Menu {
                Button {
                    session.keepNewest()
                } label: {
                    Text("Keep Newest in Each Group")
                }
                Button {
                    session.keepOldest()
                } label: {
                    Text("Keep Oldest in Each Group")
                }
                Menu {
                    ForEach(session.scannedRoots, id: \.self) { root in
                        Button {
                            session.keepCopies(inFolder: root)
                        } label: {
                            Text(verbatim: root)
                        }
                    }
                } label: {
                    Text("Keep Copies in Folder")
                }
                Divider()
                Button {
                    session.unmarkAll()
                } label: {
                    Text("Unmark All")
                }
            } label: {
                Label {
                    Text("Choose Copies")
                } icon: {
                    Image(systemName: "checklist")
                }
            }
            .disabled(session.phase != .ready || session.groups.isEmpty)

            Button {
                isShowingOptions.toggle()
            } label: {
                Label {
                    Text("Search Options")
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
            .help(Text("Choose the folders to search and the smallest file size"))
            .disabled(session.phase == .idle)
            .popover(isPresented: $isShowingOptions, arrowEdge: .bottom) {
                DuplicatesSearchOptions(session: session)
                    .frame(width: 380, height: 420)
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            PrimaryActionButton(
                help: "Review and move the checked copies to the Trash (⌘⌫)",
                isDisabled: session.phase != .ready || session.markedCount == 0
            ) {
                isConfirming = true
            }
        }

        ToolbarItem {
            InspectorToggle(isPresented: $showsInspector)
        }
    }
}

private struct ShownDuplicatesSummary: Identifiable {
    let id = UUID()
    let summary: CleanupSummary
}

/// First screen: what will be searched, and the button to start.
private struct DuplicatesStartView: View {
    let session: DuplicatesSession
    let start: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DuplicatesSearchOptions(session: session)
            HStack {
                Text("One copy of every file is always kept.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: start) {
                    Text("Find Duplicates")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.roots.isEmpty)
            }
            .padding(16)
        }
    }
}

/// Phase-aware scan progress with a Stop button.
private struct DuplicatesProgressView: View {
    let progress: DuplicateScanProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
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
        .accessibilityIdentifier("duplicates.progress")
    }

    @ViewBuilder private var title: some View {
        switch progress.phase {
        case .listing: Text("Looking for files…")
        case .grouping: Text("Comparing file sizes…")
        case .hashing: Text("Reading possible duplicates…")
        case .verifying: Text("Verifying identical files…")
        }
    }

    @ViewBuilder private var detail: some View {
        switch progress.phase {
        case .listing, .grouping:
            Text("\(progress.filesSeen) files found")
        case .hashing, .verifying:
            Text(
                "\(progress.candidateFiles) files to compare · \(progress.bytesHashed.formatted(.byteCount(style: .file))) read"
            )
        }
    }
}
