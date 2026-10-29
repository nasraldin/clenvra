import ClenvraKit
import QuickLook
import SwiftUI

/// Large & Old files from the last scan, filtered by size and by how long ago they were modified. Highlighted rows
/// are what Move to Trash removes, as in Finder; the inspector shows their details.
struct LargeFilesView: View {
    let session: StorageSession

    @State private var previewURL: URL?
    @State private var sortOrder = [KeyPathComparator(\StorageItem.allocatedSize, order: .reverse)]
    @State private var query = ""
    @State private var showsInspector = false

    private static let minimums: [Int64] = [50_000_000, 100_000_000, 1_000_000_000]

    var body: some View {
        let files = rows
        VStack(spacing: 0) {
            filters
            Divider()
            if files.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No files match")
                        } icon: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                    } description: {
                        Text("Try a smaller size or a shorter time.")
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                Table(files, selection: selectionBinding, sortOrder: $sortOrder) {
                    TableColumn(Text("Name"), value: \.name) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            FileNameCell(name: item.name, path: item.path)
                            PathText(path: (item.path as NSString).deletingLastPathComponent)
                        }
                    }
                    .width(min: 240, ideal: 420)
                    TableColumn(Text("Size"), value: \.allocatedSize) { item in
                        SizeText(bytes: item.allocatedSize)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn(Text("Frees ≈"), value: \.reclaimableSize) { item in
                        SizeText(bytes: item.reclaimableSize)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn(Text("Modified"), value: \.modifiedSort) { item in
                        DateCell(date: item.modificationDate)
                    }
                    .width(min: 80, ideal: 110)
                }
                .accessibilityLabel(Text("Large and old files"))
                .contextMenu(forSelectionType: StorageItem.ID.self) { paths in
                    Button {
                        session.setSelection(paths)
                        showsInspector = true
                    } label: {
                        Text("Show Details")
                    }
                    ItemActionsMenu(paths: paths, previewURL: $previewURL)
                } primaryAction: { paths in
                    session.setSelection(paths)
                    showsInspector = true
                }
                .onKeyPress(.space) {
                    guard let path = session.selection.first else { return .ignored }
                    previewURL = URL(filePath: path)
                    return .handled
                }
                .quickLookPreview($previewURL, in: files.map { URL(filePath: $0.path) })
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search by Name or Location"))
        .inspector(isPresented: $showsInspector) {
            StorageItemInspector(items: session.largeFiles.filter { session.selection.contains($0.path) })
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                InspectorToggle(isPresented: $showsInspector)
            }
        }
    }

    private var rows: [StorageItem] {
        let matching =
            query.isEmpty
            ? session.largeFiles
            : session.largeFiles.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
            }
        return matching.sorted(using: sortOrder)
    }

    private var filters: some View {
        HStack(spacing: 16) {
            Picker(selection: minimumBinding) {
                ForEach(Self.minimums, id: \.self) { bytes in
                    Text(bytes.formatted(.byteCount(style: .file))).tag(bytes)
                }
            } label: {
                Text("At least")
            }
            .fixedSize()
            .visibleLabel("At least")
            Picker(selection: ageBinding) {
                ForEach(LargeFileAge.allCases, id: \.self) { age in
                    Text(age.title).tag(age)
                }
            } label: {
                Text("Not modified in")
            }
            .fixedSize()
            .visibleLabel("Not modified in")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var selectionBinding: Binding<Set<String>> {
        Binding(get: { session.selection }, set: { session.setSelection($0) })
    }

    private var minimumBinding: Binding<Int64> {
        Binding(get: { session.largeFileMinimum }, set: { session.largeFileMinimum = $0 })
    }

    private var ageBinding: Binding<LargeFileAge> {
        Binding(get: { session.largeFileAge }, set: { session.largeFileAge = $0 })
    }
}

extension StorageItem {
    /// Unknown dates sort first, so the table can sort on a plain date.
    nonisolated var modifiedSort: Date { modificationDate ?? .distantPast }
}

/// Details of the highlighted files or folders on the storage pages.
struct StorageItemInspector: View {
    let items: [StorageItem]

    var body: some View {
        if items.count == 1, let item = items.first {
            ItemInspector(name: item.name, path: item.path) {
                Section {
                    LabeledContent {
                        SizeText(bytes: item.allocatedSize)
                    } label: {
                        Text("Size on Disk")
                    }
                    LabeledContent {
                        SizeText(bytes: item.reclaimableSize)
                    } label: {
                        Text("Frees")
                    }
                    if item.kind == .directory {
                        LabeledContent {
                            Text(item.fileCount, format: .number)
                        } label: {
                            Text("Files")
                        }
                    }
                    LabeledContent {
                        DateCell(date: item.modificationDate)
                    } label: {
                        Text("Modified")
                    }
                } footer: {
                    if let reason = item.protection {
                        Text(reason.explanation)
                            .font(.callout)
                    } else if item.reclaimableSize < item.allocatedSize {
                        Text("Part of this space is shared with other files, so removing it frees less.")
                            .font(.callout)
                    }
                }
            }
        } else if items.count > 1 {
            SelectionTotalsInspector(count: items.count, bytes: items.reduce(0) { $0 + $1.reclaimableSize })
        } else {
            NoSelectionInspector(description: "Select a file to see its size, date and location.")
        }
    }
}

extension LargeFileAge {
    var title: LocalizedStringResource {
        switch self {
        case .any: "Any time"
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        case .twoYears: "2 years"
        }
    }
}
