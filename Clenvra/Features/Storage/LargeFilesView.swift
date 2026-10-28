import ClenvraKit
import QuickLook
import SwiftUI

/// Large & Old files from the last scan, filtered by size and by how long ago they were modified.
struct LargeFilesView: View {
    let session: StorageSession

    @State private var previewURL: URL?

    private static let minimums: [Int64] = [50_000_000, 100_000_000, 1_000_000_000]

    var body: some View {
        let files = session.largeFiles
        VStack(spacing: 0) {
            filters
            Divider()
            if files.isEmpty {
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
                Table(files, selection: selectionBinding) {
                    TableColumn("Name") { item in
                        VStack(alignment: .leading, spacing: 2) {
                            ItemNameCell(item: item)
                            PathText(path: (item.path as NSString).deletingLastPathComponent)
                        }
                    }
                    .width(min: 240, ideal: 420)
                    TableColumn("Size") { item in
                        SizeText(bytes: item.allocatedSize)
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Frees ≈") { item in
                        SizeText(bytes: item.reclaimableSize)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Modified") { item in
                        if let date = item.modificationDate {
                            Text(date, format: .dateTime.year().month().day())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 80, ideal: 110)
                }
                .accessibilityLabel(Text("Large and old files"))
                .contextMenu(forSelectionType: StorageItem.ID.self) { paths in
                    ItemActionsMenu(paths: paths, previewURL: $previewURL)
                }
                .onKeyPress(.space) {
                    guard let path = session.selection.first else { return .ignored }
                    previewURL = URL(filePath: path)
                    return .handled
                }
                .quickLookPreview($previewURL, in: files.map { URL(filePath: $0.path) })
            }
        }
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
