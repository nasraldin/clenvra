import ClenvraKit
import QuickLook
import SwiftUI

/// The space map: path bar, the current folder's children by size, and a treemap or sunburst of the same folder.
struct StorageBrowserView: View {
    let session: StorageSession

    @State private var previewURL: URL?
    @AppStorage("storage.mapStyle") private var mapStyle = StorageMapStyle.treemap
    @State private var searchText = ""
    private var query: String { AppSearch.normalized(searchText) }

    /// The current folder's children whose name matches the search; the map always shows the whole folder.
    private var rows: [StorageItem] {
        session.children.filter { AppSearch.matches(query, any: [$0.name, $0.path]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            VSplitView {
                table
                    .frame(minHeight: 200)
                    .pageState(isShown: !session.children.isEmpty && rows.isEmpty) {
                        ContentUnavailableView.search(text: query)
                    }
                map
                    .frame(minHeight: 160, idealHeight: 240)
            }
            .pageState(isShown: session.children.isEmpty) {
                ContentUnavailableView {
                    Label {
                        Text("This folder is empty")
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            }
        }
        .pageSearch(text: $searchText, prompt: "Search This Folder", section: .storage)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await session.goUp() }
                } label: {
                    ToolbarLabel(title: "Back", symbol: "chevron.backward")
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!session.canGoUp)
            }
        }
    }

    private var map: some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                Picker(selection: $mapStyle) {
                    Text("Treemap").tag(StorageMapStyle.treemap)
                    Text("Sunburst").tag(StorageMapStyle.sunburst)
                } label: {
                    Text("Map Style")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("storage.mapStyle")
            }
            switch mapStyle {
            case .treemap:
                StorageTreemap(items: session.children) { item in
                    Task { await session.open(item.path) }
                }
            case .sunburst:
                StorageSunburst(session: session)
            }
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Space map"))
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(session.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.forward")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button {
                        Task { await session.open(crumb.path) }
                    } label: {
                        if index == 0, session.target.kind == .home {
                            Label {
                                Text(verbatim: crumb.name)
                            } icon: {
                                Image(systemName: "house")
                            }
                        } else {
                            Text(verbatim: crumb.name)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(crumb.path == session.currentPath)
                }
                if let aggregate = session.currentAggregate {
                    Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    SizeText(bytes: aggregate.allocated)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("storage.pathBar")
    }

    private var table: some View {
        let largest = max(session.children.first?.allocatedSize ?? 1, 1)
        return Table(rows, selection: selectionBinding) {
            TableColumn("Name") { item in
                ItemNameCell(item: item, showsOpen: item.kind == .directory) {
                    Task { await session.open(item.path) }
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Size") { item in
                HStack(spacing: 8) {
                    ProgressView(value: Double(item.allocatedSize), total: Double(largest))
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                        .accessibilityHidden(true)
                    SizeText(bytes: item.allocatedSize)
                }
            }
            .width(min: 140, ideal: 170)
            TableColumn("Frees ≈") { item in
                SizeText(bytes: item.reclaimableSize)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Items") { item in
                if item.kind == .directory {
                    Text("\(item.fileCount) files")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
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
        .contextMenu(forSelectionType: StorageItem.ID.self) { paths in
            ItemActionsMenu(paths: paths, previewURL: $previewURL)
        } primaryAction: { paths in
            guard paths.count == 1, let path = paths.first,
                session.children.contains(where: { $0.path == path && $0.kind == .directory })
            else { return }
            Task { await session.open(path) }
        }
        .onKeyPress(.space) {
            guard let path = session.selection.first else { return .ignored }
            previewURL = URL(filePath: path)
            return .handled
        }
        .quickLookPreview($previewURL, in: rows.map { URL(filePath: $0.path) })
        .accessibilityLabel(Text("Folders and files"))
        // No floating control overlaps this edge (the map pane follows it), so no fading edge effect.
        .scrollEdgeEffectHidden(true, for: .bottom)
    }

    private var selectionBinding: Binding<Set<String>> {
        Binding(get: { session.selection }, set: { session.setSelection($0) })
    }
}

/// Icon, name and — for protected items — a lock with the reason.
struct ItemNameCell: View {
    let item: StorageItem
    var showsOpen = false
    var open: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind == .directory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let reason = item.protection {
                Label {
                    Text(reason.title)
                } icon: {
                    Image(systemName: "lock")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(Text(reason.explanation))
            }
            Spacer(minLength: 4)
            if showsOpen {
                Button(action: open) {
                    Label {
                        Text("Open")
                    } icon: {
                        Image(systemName: "chevron.forward.circle")
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(Text("Open"))
            }
        }
    }
}

/// Quick Look, Show in Finder and Copy Path for the clicked rows.
struct ItemActionsMenu: View {
    let paths: Set<String>
    @Binding var previewURL: URL?

    var body: some View {
        if !paths.isEmpty {
            Button {
                previewURL = paths.sorted().first.map { URL(filePath: $0) }
            } label: {
                Text("Quick Look")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(paths.sorted().map { URL(filePath: $0) })
            } label: {
                Text("Show in Finder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.sorted().joined(separator: "\n"), forType: .string)
            } label: {
                Text("Copy Path")
            }
        }
    }
}

extension ProtectionReason {
    var title: LocalizedStringResource {
        switch self {
        case .system: "macOS"
        case .homeRoot: "Home folder"
        case .secret: "Keys & passwords"
        case .userData: "Personal data"
        case .custom: "Protected"
        case .excluded: "Excluded"
        case .invalid: "Protected"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .system: "Part of macOS. Clenvra never removes it."
        case .homeRoot: "A main folder of your home folder. Open it to review what is inside."
        case .secret: "Holds keys, certificates or passwords. Clenvra never removes it."
        case .userData: "Holds mail, messages, photos or cloud files. Clenvra never removes it."
        case .custom: "Protected by Clenvra."
        case .excluded: "You excluded this folder in Settings."
        case .invalid: "This location is not allowed."
        }
    }
}

/// How the browser draws the current folder below the list.
enum StorageMapStyle: String {
    case treemap, sunburst
}
