import ClenvraKit
import QuickLook
import SwiftUI

/// Large & Old files from the last scan, filtered by size and by how long ago they were modified, and grouped by
/// kind, folder or age. Highlighted rows are what Move to Trash removes, as in Finder; a group's checkbox highlights
/// every file it shows. The inspector shows their details.
struct LargeFilesView: View {
    let session: StorageSession

    @State private var previewURL: URL?
    @State private var sortOrder = [KeyPathComparator(\LargeFileRow.size, order: .reverse)]
    @State private var searchText = ""
    private var query: String { AppSearch.normalized(searchText) }
    @State private var showsInspector = false
    @State private var grouping = LargeFileGrouping.kind
    /// Groups the person closed, remembered across launches.
    private let expansion = ExpandedGroups("largeFiles")

    private static let minimums: [Int64] = [50_000_000, 100_000_000, 1_000_000_000]

    var body: some View {
        let files = rows
        let groups = visibleGroups(of: files)
        VStack(spacing: 0) {
            filters
            Divider()
            Table(of: LargeFileRow.self, selection: selectionBinding, sortOrder: $sortOrder) {
                TableColumn(Text("Name"), value: \.name) { row in
                    if let item = row.item {
                        VStack(alignment: .leading, spacing: 2) {
                            FileNameCell(name: item.name, path: item.path)
                            PathText(path: (item.path as NSString).deletingLastPathComponent)
                        }
                    } else {
                        HStack(spacing: 6) {
                            groupCheckbox(for: row)
                            LargeFileGroupNameCell(row: row)
                        }
                    }
                }
                .width(min: 240, ideal: 420)
                TableColumn(Text("Size"), value: \.size) { row in
                    SizeText(bytes: row.size)
                        .fontWeight(row.item == nil ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100)
                TableColumn(Text("Frees ≈"), value: \.reclaimable) { row in
                    if row.item == nil {
                        Text("\(row.itemCount) items")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        SizeText(bytes: row.reclaimable)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .width(min: 70, ideal: 90)
                TableColumn(Text("Modified"), value: \.modifiedSort) { row in
                    DateCell(date: row.modifiedSort)
                }
                .width(min: 80, ideal: 110)
            } rows: {
                ForEach(groups) { group in
                    DisclosureTableRow(LargeFileRow(group: group), isExpanded: expandedBinding(group.id, all: groups)) {
                        ForEach(group.items.map(LargeFileRow.init(item:)).sorted(using: sortOrder)) { row in
                            TableRow(row)
                        }
                    }
                }
            }
            // Group rows already separate the list; grey stripes under short names fall below readable contrast.
            .alternatingRowBackgrounds(.disabled)
            .accessibilityLabel(Text("Large and old files"))
            .contextMenu(forSelectionType: LargeFileRow.ID.self) { ids in
                let paths = filePaths(for: ids, in: groups)
                Button {
                    session.setSelection(paths)
                    showsInspector = true
                } label: {
                    Text("Show Details")
                }
                ItemActionsMenu(paths: paths, previewURL: $previewURL)
            } primaryAction: { ids in
                session.setSelection(filePaths(for: ids, in: groups))
                showsInspector = true
            }
            .onKeyPress(.space) {
                guard let path = session.selection.first else { return .ignored }
                previewURL = URL(filePath: path)
                return .handled
            }
            .quickLookPreview($previewURL, in: groups.flatMap(\.items).map { URL(filePath: $0.path) })
            .pageState(isShown: groups.isEmpty) {
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
            }
        }
        .pageSearch(text: $searchText, prompt: "Search by Name or Location", section: .largeFiles)
        .detailsPanel(isPresented: $showsInspector, width: 280) {
            StorageItemInspector(items: session.largeFiles.filter { session.selection.contains($0.path) })
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExpandAllButton(allExpanded: expansion.allBinding(groups.map(\.id)))
                    .disabled(groups.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                InspectorToggle(isPresented: $showsInspector)
            }
        }
    }

    /// The files the size and age filters show, before the search.
    private var rows: [StorageItem] { session.largeFiles }

    /// The groups of `files`, holding only the files the search matches. A search for a group's own title ("Videos",
    /// a folder name…) shows the whole group.
    private func visibleGroups(of files: [StorageItem]) -> [LargeFileGroup] {
        let all = LargeFileGroups.groups(files, by: grouping, root: session.snapshot?.root ?? "")
        guard !query.isEmpty else { return all }
        return all.compactMap { group in
            if AppSearch.matches(query, group.key.searchTitle) { return group }
            let items = group.items.filter { AppSearch.matches(query, any: [$0.name, $0.path]) }
            return items.isEmpty ? nil : LargeFileGroup(key: group.key, items: items)
        }
    }

    /// The files behind highlighted rows; a group row stands for the files it shows.
    private func filePaths(for ids: Set<LargeFileRow.ID>, in groups: [LargeFileGroup]) -> Set<String> {
        var paths = ids.filter { !$0.hasPrefix(LargeFileRow.groupPrefix) }
        for group in groups where ids.contains(LargeFileRow.groupID(group)) {
            paths.formUnion(group.items.map(\.path))
        }
        return paths
    }

    /// Highlights or clears every file of a group the search shows that may be moved to the Trash.
    @ViewBuilder private func groupCheckbox(for row: LargeFileRow) -> some View {
        let bindings = row.children.filter(\.isSelectable).map { item in
            Binding(
                get: { session.selection.contains(item.path) },
                set: { checked in
                    if session.selection.contains(item.path) != checked { session.toggleChecked(item.path) }
                })
        }
        Toggle(sources: bindings, isOn: \.self) {
            Text("Select all \(row.title)")
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(bindings.isEmpty)
    }

    private func expandedBinding(_ id: String, all groups: [LargeFileGroup]) -> Binding<Bool> {
        expansion.binding(id) { groups.map(\.id) }
    }

    private var filters: some View {
        HStack(spacing: 16) {
            Picker(selection: $grouping) {
                Text("Kind").tag(LargeFileGrouping.kind)
                Text("Folder").tag(LargeFileGrouping.folder)
                Text("Age").tag(LargeFileGrouping.age)
            } label: {
                Text("Group by")
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .visibleLabel("Group by")
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

/// One table row: a group (with its files as children) or one file. Plain data, not tied to the main actor, so the
/// table can sort by its key paths.
nonisolated struct LargeFileRow: Identifiable, Sendable {
    static let groupPrefix = "group:"

    let id: String
    let item: StorageItem?
    let key: LargeFileGroup.Key?
    /// The group's files the search shows; empty for a file row.
    let children: [StorageItem]
    let name: String
    let size: Int64
    let reclaimable: Int64
    let modifiedSort: Date
    let itemCount: Int

    static func groupID(_ group: LargeFileGroup) -> String { groupPrefix + group.id }

    init(group: LargeFileGroup) {
        id = Self.groupID(group)
        item = nil
        key = group.key
        children = group.items
        name = group.id  // Group rows are not sorted; the cell shows the localized title.
        size = group.totalBytes
        reclaimable = group.items.reduce(0) { $0 + $1.reclaimableSize }
        modifiedSort = group.items.compactMap(\.modificationDate).max() ?? .distantPast
        itemCount = group.items.count
    }

    init(item: StorageItem) {
        id = item.id
        self.item = item
        key = nil
        children = []
        name = item.name
        size = item.allocatedSize
        reclaimable = item.reclaimableSize
        modifiedSort = item.modifiedSort
        itemCount = 1
    }
}

extension LargeFileRow {
    @MainActor var title: Text {
        if let key { Text(key.title) } else { Text(verbatim: name) }
    }
}

/// A group's title: the kind or age with a symbol, or the folder with its Finder icon.
private struct LargeFileGroupNameCell: View {
    let row: LargeFileRow

    var body: some View {
        if case .folder(let path) = row.key {
            FileNameCell(name: (path as NSString).lastPathComponent, path: path)
                .fontWeight(.semibold)
        } else {
            Label {
                row.title
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: row.key?.symbol ?? "doc")
            }
        }
    }
}

extension LargeFileGroup.Key {
    var title: LocalizedStringResource {
        switch self {
        case .kind(let kind): kind.title
        case .age(let age): age.title
        // A folder name is shown as it is; "%@" is not translated.
        case .folder(let path): "\((path as NSString).lastPathComponent)"
        }
    }

    /// What a search compares with the group's title.
    var searchTitle: String {
        if case .folder(let path) = self { return (path as NSString).lastPathComponent }
        return String(localized: title)
    }

    var symbol: String {
        switch self {
        case .kind(let kind): kind.symbol
        case .age: "clock"
        case .folder: "folder"
        }
    }
}

extension LargeFileKind {
    var title: LocalizedStringResource {
        switch self {
        case .video: "Videos"
        case .image: "Images"
        case .archive: "Archives"
        case .diskImage: "Disk Images"
        case .app: "Apps"
        case .document: "Documents"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .archive: "archivebox"
        case .diskImage: "opticaldiscdrive"
        case .app: "app"
        case .document: "doc.text"
        case .other: "doc"
        }
    }
}

extension LargeFileAgeBucket {
    var title: LocalizedStringResource {
        switch self {
        case .underSixMonths: "Less than 6 Months"
        case .sixToTwelveMonths: "6 to 12 Months"
        case .oneToTwoYears: "1 to 2 Years"
        case .overTwoYears: "More than 2 Years"
        case .unknown: "Unknown Date"
        }
    }
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
