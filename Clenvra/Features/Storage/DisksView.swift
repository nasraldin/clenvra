import AppKit
import ClenvraKit
import SwiftUI

/// Disks mounted besides the startup disk, shown as on the desktop: disk images (installers and other `.dmg` files),
/// other drives and network shares. Open, details, and Eject; Eject All touches disk images only, so a backup drive
/// is never cut off by accident.
struct DisksView: View {
    let session: MountedDisksSession

    @State private var selected: MountedDisksSession.Disk.ID?
    @State private var showsInspector = false
    @State private var notEjected: [String] = []
    @State private var searchText = ""

    var body: some View {
        // The empty state replaces the grid rather than covering it: a covered grid of buttons confuses the
        // accessibility tree (as on Similar Photos). The toolbar does not depend on the grid, so it stays put.
        Group {
            if allDisks.isEmpty {
                if session.hasLoaded {
                    ContentUnavailableView {
                        Label {
                            Text("No Other Disks")
                        } icon: {
                            Image(systemName: "externaldrive")
                        }
                    } description: {
                        Text(
                            "Only the startup disk is mounted. Disk images and other drives you connect appear here.")
                    }
                } else {
                    ProgressView()
                }
            } else if !query.isEmpty, filtered(allDisks).isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        section("Disk Images", filtered(session.images))
                        section("Drives", filtered(session.drives))
                        section("Network", filtered(session.network))
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The grid reflows once when the details panel opens, instead of resizing tiles on every frame of
                    // the panel's slide-in.
                    .transaction { $0.animation = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("review.results")
        .pageSearch(text: $searchText, prompt: "Search Disks", section: .disks)
        .toolbar { toolbar }
        .detailsPanel(isPresented: $showsInspector, width: 300) {
            DiskInspector(disk: allDisks.first { $0.id == selected }) { eject($0) }
        }
        .task { await session.load() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await session.load() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await session.load() }
        }
        .alert(
            Text("Could not eject"),
            isPresented: Binding(get: { !notEjected.isEmpty }, set: { if !$0 { notEjected = [] } })
        ) {
            Button {
                notEjected = []
            } label: {
                Text("OK")
            }
        } message: {
            Text("\(notEjected.formatted(.list(type: .and))) could not be ejected. A file on it may be open.")
        }
    }

    private var allDisks: [MountedDisksSession.Disk] { session.images + session.drives + session.network }

    private var query: String { AppSearch.normalized(searchText) }

    private func filtered(_ disks: [MountedDisksSession.Disk]) -> [MountedDisksSession.Disk] {
        disks.filter {
            AppSearch.matches(
                query,
                any: [
                    $0.volume.name, $0.volume.id.path(percentEncoded: false), String(localized: $0.volume.kind.title),
                    $0.volume.fileSystem, $0.imagePath,
                ])
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringResource, _ disks: [MountedDisksSession.Disk]) -> some View {
        if !disks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                // Tiles keep one size, as on the desktop; only how many fit in a row changes.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 140), spacing: 12)], spacing: 12) {
                    ForEach(disks) { disk in
                        // A real button, so VoiceOver gets a name and a press action; double-click opens, as in Finder.
                        Button {
                            // Double-click opens, as in Finder; a gesture here would add an unlabelled layer.
                            if NSApp.currentEvent?.clickCount == 2 { open(disk) } else { selected = disk.id }
                        } label: {
                            DiskTile(disk: disk, isSelected: disk.id == selected)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: disk) }
                        // One element for the tile: the context menu adds a container of its own on macOS.
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(verbatim: disk.volume.name))
                        .accessibilityValue(Text(disk.volume.totalCapacity.formatted(.byteCount(style: .file))))
                        .accessibilityAddTraits(disk.id == selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { selected = disk.id }
                        .accessibilityAction(named: Text("Open")) { open(disk) }
                        .accessibilityIdentifier("disks.tile")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for disk: MountedDisksSession.Disk) -> some View {
        Button {
            open(disk)
        } label: {
            Text("Open")
        }
        Button {
            selected = disk.id
            showsInspector = true
        } label: {
            Text("Show Details")
        }
        if let image = disk.imagePath {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: image)])
            } label: {
                Text("Show Disk Image in Finder")
            }
        }
        Divider()
        Button {
            eject(disk)
        } label: {
            Text("Eject")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await session.load() }
            } label: {
                ToolbarLabel(title: "Refresh", symbol: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Read the mounted disks again (⌘R)"))

            Button {
                Task {
                    let failed = await session.ejectAllImages()
                    notEjected = failed.map(\.volume.name)
                }
            } label: {
                ToolbarLabel(title: "Eject All Disk Images", symbol: "eject")
            }
            .help(Text("Eject every mounted disk image. Drives and network shares stay connected."))
            .disabled(session.images.isEmpty)
            .accessibilityIdentifier("disks.ejectAll")
        }

        ToolbarItem {
            InspectorToggle(isPresented: $showsInspector)
        }
    }

    private func open(_ disk: MountedDisksSession.Disk) {
        NSWorkspace.shared.open(disk.volume.id)
    }

    private func eject(_ disk: MountedDisksSession.Disk) {
        Task {
            if !(await session.eject(disk)) { notEjected = [disk.volume.name] }
            if selected == disk.id { selected = nil }
        }
    }
}

/// One disk as on the desktop: its Finder icon, name and size.
private struct DiskTile: View {
    let disk: MountedDisksSession.Disk
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: disk.volume.id.path(percentEncoded: false)))
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(verbatim: disk.volume.name)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            SizeText(bytes: disk.volume.totalCapacity)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Details of the selected disk.
private struct DiskInspector: View {
    let disk: MountedDisksSession.Disk?
    let eject: (MountedDisksSession.Disk) -> Void

    var body: some View {
        if let disk {
            let volume = disk.volume
            ItemInspector(name: volume.name, path: volume.id.path(percentEncoded: false)) {
                Section {
                    LabeledContent {
                        Text(volume.kind.title)
                    } label: {
                        Text("Kind")
                    }
                    if let fileSystem = volume.fileSystem {
                        LabeledContent {
                            Text(verbatim: fileSystem.uppercased())
                        } label: {
                            Text("Format")
                        }
                    }
                    LabeledContent {
                        SizeText(bytes: volume.totalCapacity)
                    } label: {
                        Text("Capacity")
                    }
                    LabeledContent {
                        SizeText(bytes: volume.usedCapacity)
                    } label: {
                        Text("Used")
                    }
                    LabeledContent {
                        SizeText(bytes: volume.availableCapacity)
                    } label: {
                        Text("Free")
                    }
                    if volume.isReadOnly {
                        Text("Read-only")
                            .foregroundStyle(.secondary)
                    }
                }
                if let image = disk.imagePath {
                    Section {
                        PathText(path: image)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: image)])
                        } label: {
                            Text("Show Disk Image in Finder")
                        }
                    } header: {
                        Text("Disk Image File")
                    }
                }
                Section {
                    Button {
                        NSWorkspace.shared.open(volume.id)
                    } label: {
                        Text("Open")
                    }
                    Button {
                        eject(disk)
                    } label: {
                        Text("Eject")
                    }
                }
            }
        } else {
            NoSelectionInspector(description: "Select a disk to see its details.")
        }
    }
}

extension Volume.Kind {
    fileprivate var title: LocalizedStringResource {
        switch self {
        case .diskImage: "Disk Image"
        case .network: "Network Share"
        case .internal: "Internal Drive"
        case .external: "External Drive"
        case .other: "Drive"
        }
    }
}
