import AppKit
import ClenvraKit
import SwiftUI

/// Every duplicate group as a collapsible table row with its copies; one copy per group is always kept (enforced by
/// the session). The checkbox marks a copy for the Trash; highlighting shows its details.
struct DuplicateGroupsList: View {
    let session: DuplicatesSession
    @Binding var previewURL: URL?
    @Binding var highlighted: Set<DuplicateRow.ID>
    @Binding var showsInspector: Bool
    let query: String

    @State private var sortOrder = [KeyPathComparator(\DuplicateRow.path)]
    /// Groups the person closed, remembered across launches (F4).
    private let expansion = ExpandedGroups("duplicates")

    var body: some View {
        VStack(spacing: 0) {
            if !session.lastScanWasComplete || session.unreadableCount > 0 {
                notices
                Divider()
            }
            table
                .pageState(isShown: visibleGroups.isEmpty && !query.isEmpty) {
                    ContentUnavailableView.search(text: query)
                }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !session.lastScanWasComplete {
                Label {
                    Text("The scan was stopped. Results may be incomplete.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if session.unreadableCount > 0 {
                Label {
                    Text("\(session.unreadableCount) files could not be read.")
                } icon: {
                    Image(systemName: "lock")
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var table: some View {
        Table(of: DuplicateRow.self, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn(Text("Name"), value: \.path) { row in
                if let file = row.file {
                    HStack(spacing: 6) {
                        Toggle(
                            isOn: Binding(
                                get: { session.isMarked(file.path) },
                                set: { session.setMarked($0, path: file.path) })
                        ) {
                            Text("Move \(row.name) to the Trash")
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(!session.canMark(file.path))
                        .help(Text("Checked copies move to the Trash. At least one copy is always kept."))
                        VStack(alignment: .leading, spacing: 2) {
                            FileNameCell(name: row.name, path: file.path)
                            PathText(path: (file.path as NSString).deletingLastPathComponent)
                        }
                    }
                } else {
                    DuplicateGroupName(row: row)
                }
            }
            .width(min: 260, ideal: 420)

            TableColumn(Text("Status")) { row in
                if let file = row.file {
                    let marked = session.isMarked(file.path)
                    Label {
                        Text(marked ? "Move to Trash" : "Keep")
                    } icon: {
                        Image(systemName: marked ? "trash" : "checkmark.circle")
                            .foregroundStyle(marked ? Color.orange : Color.green)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else if let group = session.groups.first(where: { $0.id == row.groupID }) {
                    Text("Frees about \(session.markedBytes(in: group).formatted(.byteCount(style: .file)))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 120, ideal: 160)

            TableColumn(Text("Modified"), value: \.modified) { row in
                if row.file != nil { DateCell(date: row.modified) }
            }
            .width(min: 90, ideal: 110)

            TableColumn(Text("Size"), value: \.size) { row in
                SizeText(bytes: row.size)
                    .fontWeight(row.file == nil ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        } rows: {
            ForEach(visibleGroups) { group in
                DisclosureTableRow(DuplicateRow(group: group), isExpanded: expandedBinding(group.id)) {
                    ForEach(
                        matches(in: group).map { DuplicateRow(file: $0, groupID: group.id) }.sorted(using: sortOrder)
                    ) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: DuplicateRow.ID.self) { ids in
            let paths = files(for: ids).map(\.path)
            if !paths.isEmpty {
                FileActionsMenu(paths: paths) {
                    highlighted = ids
                    showsInspector = true
                }
                Button {
                    previewURL = paths.first.map { URL(filePath: $0) }
                } label: {
                    Text("Quick Look")
                }
                if paths.count == 1, let path = paths.first {
                    Divider()
                    Button {
                        session.keepOnly(path)
                    } label: {
                        Text("Keep Only This Copy")
                    }
                }
            }
        } primaryAction: { ids in
            highlighted = ids
            showsInspector = true
        }
        .toolbar {
            ToolbarItem {
                ExpandAllButton(allExpanded: expansion.allBinding(visibleGroups.map(\.id)))
            }
        }
        .onKeyPress(.space) {
            guard let path = files(for: highlighted).first?.path else { return .ignored }
            previewURL = URL(filePath: path)
            return .handled
        }
        .disabled(session.phase == .removing)
    }

    private var visibleGroups: [DuplicatesSession.Group] {
        session.groups.filter { !matches(in: $0).isEmpty }
    }

    private func matches(in group: DuplicatesSession.Group) -> [DuplicateFile] {
        guard !query.isEmpty else { return group.files }
        return group.files.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private func files(for ids: Set<DuplicateRow.ID>) -> [DuplicateFile] {
        session.groups.flatMap(\.files).filter { ids.contains($0.path) }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        expansion.binding(id) { session.groups.map(\.id) }
    }
}

/// One table row: a group of identical files (with its copies as children) or one copy. Plain data, so the table
/// can sort by its key paths.
nonisolated struct DuplicateRow: Identifiable, Sendable {
    let id: String
    let groupID: String
    let file: DuplicateFile?
    let name: String
    let path: String
    let size: Int64
    let modified: Date
    let copies: Int
    let sharesStorage: Bool

    init(group: DuplicatesSession.Group) {
        id = "group:" + group.id
        groupID = group.id
        file = nil
        name = group.files.first.map { ($0.path as NSString).lastPathComponent } ?? ""
        path = ""  // Group rows are not sorted.
        size = group.size
        modified = .distantPast
        copies = group.files.count
        sharesStorage = group.sharesStorage
    }

    init(file: DuplicateFile, groupID: String) {
        id = file.path
        self.groupID = groupID
        self.file = file
        name = (file.path as NSString).lastPathComponent
        path = file.path
        size = file.reclaimable
        modified = file.modificationDate
        copies = 1
        sharesStorage = false
    }
}

/// The group's file name with its icon, how many copies, and a note when the copies share storage.
private struct DuplicateGroupName: View {
    let row: DuplicateRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(row.copies) copies · \(row.size.formatted(.byteCount(style: .file))) each")
                .font(.callout)
                .foregroundStyle(.secondary)
            if row.sharesStorage {
                Text("These copies share storage; removing them frees almost nothing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Details of the highlighted copies.
struct DuplicateInspector: View {
    let session: DuplicatesSession
    let highlighted: Set<DuplicateRow.ID>

    var body: some View {
        let files = session.groups.flatMap(\.files).filter { highlighted.contains($0.path) }
        if files.count == 1, let file = files.first {
            let group = session.groups.first { $0.files.contains(file) }
            ItemInspector(name: (file.path as NSString).lastPathComponent, path: file.path) {
                Section {
                    LabeledContent {
                        Text(session.isMarked(file.path) ? "Move to Trash" : "Keep")
                    } label: {
                        Text("This Copy")
                    }
                    LabeledContent {
                        SizeText(bytes: file.size)
                    } label: {
                        Text("Size")
                    }
                    LabeledContent {
                        SizeText(bytes: file.reclaimable)
                    } label: {
                        Text("Frees")
                    }
                    LabeledContent {
                        Text(file.modificationDate, format: .dateTime.year().month().day().hour().minute())
                    } label: {
                        Text("Modified")
                    }
                    if let group {
                        LabeledContent {
                            Text(group.files.count, format: .number)
                        } label: {
                            Text("Identical Copies")
                        }
                    }
                } footer: {
                    Text("Every copy has the same content, checked byte by byte. At least one copy is always kept.")
                        .font(.callout)
                }
            }
        } else if files.count > 1 {
            SelectionTotalsInspector(count: files.count, bytes: files.reduce(0) { $0 + $1.reclaimable })
        } else {
            NoSelectionInspector(description: "Select a copy to see where it is and when it changed.")
        }
    }
}
