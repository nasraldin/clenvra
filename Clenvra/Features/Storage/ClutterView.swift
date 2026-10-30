import ClenvraKit
import QuickLook
import SwiftUI

/// The Downloads review (`.downloads`) or the Other review (`.screenshots`: screenshots and screen recordings),
/// grouped by kind, age or source. Everything here needs review; nothing is pre-selected.
struct ClutterView: View {
    let session: StorageSession
    let source: ClutterSource

    @State private var grouping = ClutterGrouping.kind
    @State private var previewURL: URL?
    @State private var age = AgeFilter.any
    @State private var minimumSize = SizeFilter.any
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -3, to: .now) ?? .now
    @State private var customTo = Date.now
    @State private var searchText = ""
    /// Groups the person closed, remembered across launches (F4).
    private let expansion: ExpandedGroups

    init(session: StorageSession, source: ClutterSource) {
        self.session = session
        self.source = source
        expansion = ExpandedGroups(source == .downloads ? "downloads" : "otherClutter")
    }

    /// This tab's files, before the age and size filters.
    private var items: [ClutterItem] { session.clutter.filter { $0.source == source } }

    var body: some View {
        page
            .pageSearch(
                text: $searchText, prompt: "Search by File Name",
                section: source == .downloads ? .downloads : .otherClutter
            )
            .toolbar {
                ToolbarItem {
                    ExpandAllButton(allExpanded: expansion.allBinding(groups.map { String(describing: $0.id) }))
                        .disabled(groups.isEmpty)
                }
            }
    }

    private var page: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(selection: $grouping) {
                    Text("Kind").tag(ClutterGrouping.kind)
                    Text("Age").tag(ClutterGrouping.age)
                    Text("Source").tag(ClutterGrouping.sourceHost)
                } label: {
                    Text("Group by")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .visibleLabel("Group by")

                Picker(selection: $age) {
                    ForEach(AgeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Age")
                }
                .fixedSize()
                .accessibilityIdentifier("downloads.age")
                .visibleLabel("Age")

                Picker(selection: $minimumSize) {
                    ForEach(SizeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Size")
                }
                .fixedSize()
                .accessibilityIdentifier("downloads.size")
                .visibleLabel("Size")

                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            HStack {
                if source == .screenshots, let folder = session.screenshotsPath {
                    Text("Screenshots folder:")
                        .foregroundStyle(.secondary)
                    PathText(path: folder)
                }
                Spacer()
                Button {
                    session.setSelection(
                        Set(groups.flatMap(\.items).filter(\.item.isSelectable).map(\.id)).union(session.selection))
                } label: {
                    Text("Select All Shown")
                }
                .disabled(groups.isEmpty)
                .help(Text("Select every file the filters show"))
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if age == .custom {
                HStack {
                    DatePicker(selection: $customFrom, in: ...customTo, displayedComponents: .date) {
                        Text("Modified from")
                    }
                    DatePicker(selection: $customTo, in: customFrom..., displayedComponents: .date) {
                        Text("to")
                    }
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()
            content
                .frame(maxHeight: .infinity)
        }
        // The filter bar stays at the top whatever the list holds.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        List(selection: selectionBinding) {
            ForEach(groups) { group in
                Section(isExpanded: expandedBinding(group.id)) {
                    ForEach(group.items) { clutter in
                        ClutterRow(clutter: clutter)
                            .tag(clutter.id)
                    }
                } header: {
                    HStack {
                        Text(group.key.title)
                        Spacer()
                        SizeText(bytes: group.totalBytes)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { paths in
            ItemActionsMenu(paths: paths, previewURL: $previewURL)
        }
        .onKeyPress(.space) {
            guard let path = session.selection.first else { return .ignored }
            previewURL = URL(filePath: path)
            return .handled
        }
        .quickLookPreview($previewURL, in: items.map { URL(filePath: $0.item.path) })
        .pageState(isShown: items.isEmpty) {
            if session.isLoadingClutter {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Nothing to review")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                } description: {
                    if source == .downloads {
                        Text("Downloads is empty.")
                    } else {
                        Text("There are no screenshots or screen recordings.")
                    }
                }
            }
        }
    }

    private var filter: ClutterFilter {
        var filter = age.filter(now: .now, customFrom: customFrom, customTo: customTo)
        filter.minimumBytes = minimumSize.bytes
        filter.source = source
        filter.nameContains = searchText
        return filter
    }

    private var groups: [ClutterGroup] { session.clutterGroups(by: grouping, filter: filter) }

    private func expandedBinding(_ id: ClutterGroup.ID) -> Binding<Bool> {
        expansion.binding(String(describing: id)) { groups.map { String(describing: $0.id) } }
    }

    private var selectionBinding: Binding<Set<String>> {
        Binding(get: { session.selection }, set: { session.setSelection($0) })
    }
}

private struct ClutterRow: View {
    let clutter: ClutterItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: clutter.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: clutter.item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                PathText(path: (clutter.item.path as NSString).deletingLastPathComponent)
                if let host = clutter.sourceHost {
                    Text("Downloaded from \(host)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Label {
                Text("Review")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(.orange)
            if let date = clutter.item.modificationDate {
                Text(date, format: .dateTime.year().month().day())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 90, alignment: .trailing)
            }
            SizeText(bytes: clutter.item.allocatedSize)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

extension ClutterGroup.Key {
    var title: LocalizedStringResource {
        switch self {
        case .kind(let kind): kind.title
        case .age(let age): age.title
        // A website name is shown as it is; "%@" is not translated.
        case .sourceHost(let host?): "\(host)"
        case .sourceHost(nil): "Unknown source"
        }
    }
}

extension ClutterKind {
    var title: LocalizedStringResource {
        switch self {
        case .screenshot: "Screenshots"
        case .screenRecording: "Screen Recordings"
        case .installer: "Installers & Disk Images"
        case .archive: "Archives"
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .document: "Documents"
        case .other: "Other Files"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "camera.viewfinder"
        case .screenRecording: "record.circle"
        case .installer: "shippingbox"
        case .archive: "archivebox"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.text"
        case .other: "doc"
        }
    }
}

extension ClutterAge {
    var title: LocalizedStringResource {
        switch self {
        case .thisWeek: "Last 7 Days"
        case .thisMonth: "Last 30 Days"
        case .thisYear: "Last 12 Months"
        case .older: "Older"
        }
    }
}

/// How old the listed files are (F7). "Last…" keeps recent files; "Older than…" keeps files left alone that long.
private enum AgeFilter: CaseIterable {
    case any, lastWeek, lastMonth, olderThanMonth, olderThanThreeMonths, olderThanYear, custom

    var title: LocalizedStringResource {
        switch self {
        case .any: "Any Age"
        case .lastWeek: "Last Week"
        case .lastMonth: "Last Month"
        case .olderThanMonth: "Older than a Month"
        case .olderThanThreeMonths: "Older than 3 Months"
        case .olderThanYear: "Older than a Year"
        case .custom: "Custom Range"
        }
    }

    func filter(now: Date, customFrom: Date, customTo: Date) -> ClutterFilter {
        let calendar = Calendar.current
        func ago(_ component: Calendar.Component, _ value: Int) -> Date? {
            calendar.date(byAdding: component, value: -value, to: now)
        }
        switch self {
        case .any: return ClutterFilter()
        case .lastWeek: return ClutterFilter(modifiedAfter: ago(.day, 7))
        case .lastMonth: return ClutterFilter(modifiedAfter: ago(.month, 1))
        case .olderThanMonth: return ClutterFilter(modifiedBefore: ago(.month, 1))
        case .olderThanThreeMonths: return ClutterFilter(modifiedBefore: ago(.month, 3))
        case .olderThanYear: return ClutterFilter(modifiedBefore: ago(.year, 1))
        case .custom:
            // The whole "to" day counts.
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customTo))
            return ClutterFilter(modifiedBefore: end, modifiedAfter: calendar.startOfDay(for: customFrom))
        }
    }
}

/// The smallest file to list (F7).
private enum SizeFilter: CaseIterable {
    case any, tenMB, hundredMB, oneGB

    var bytes: Int64 {
        switch self {
        case .any: 0
        case .tenMB: 10_000_000
        case .hundredMB: 100_000_000
        case .oneGB: 1_000_000_000
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .any: "Any Size"
        case .tenMB: "Over 10 MB"
        case .hundredMB: "Over 100 MB"
        case .oneGB: "Over 1 GB"
        }
    }
}
