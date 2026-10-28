import ClenvraKit
import QuickLook
import SwiftUI

/// Downloads & Screenshots review, grouped by kind or age. Everything here needs review; nothing is pre-selected.
struct ClutterView: View {
    let session: StorageSession

    @State private var grouping = ClutterGrouping.kind
    @State private var previewURL: URL?

    var body: some View {
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
                Spacer()
                if let folder = session.screenshotsPath {
                    Text("Screenshots folder:")
                        .foregroundStyle(.secondary)
                    PathText(path: folder)
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        if session.isLoadingClutter, session.clutter.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.clutter.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("Nothing to review")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } description: {
                Text("Downloads is empty and there are no screenshots.")
            }
        } else {
            List(selection: selectionBinding) {
                ForEach(session.clutterGroups(by: grouping)) { group in
                    Section {
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
            .quickLookPreview($previewURL, in: session.clutter.map { URL(filePath: $0.item.path) })
        }
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
                        .font(.caption)
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
