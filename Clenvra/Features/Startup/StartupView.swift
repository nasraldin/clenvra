import AppKit
import ClenvraKit
import ServiceManagement
import SwiftUI

/// Everything that starts automatically, problems first: a table of collapsible groups, details in the inspector,
/// and Stop, Start and Remove for the person's own agents (F8, F9).
struct StartupView: View {
    let session: StartupSession
    let installedApps: [InstalledApp]

    @State private var highlighted: Set<StartupRow.ID> = []
    @State private var showsInspector = false
    @State private var collapsed: Set<StartupGroup> = []
    @State private var removing: LaunchItem?
    @State private var message: LocalizedStringResource?
    @State private var query = ""

    var body: some View {
        Group {
            if session.isLoading && session.items.isEmpty {
                ProgressView {
                    Text("Reading startup items…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleGroups.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                table
            }
        }
        .toolbar { toolbar }
        .inspector(isPresented: $showsInspector) {
            StartupInspector(
                item: highlightedItems.count == 1 ? highlightedItems.first : nil, session: session,
                ownerName: highlightedItems.first.flatMap(ownerName), remove: { removing = $0 },
                report: { message = $0 }
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search Startup Items"))
        // Listing what is installed is instant and changes nothing, like Finder showing a folder.
        .task(id: installedApps.count) { await session.load(installedApps: installedApps) }
        .confirmationDialog(
            Text("Remove this startup item?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { item in
            Button(role: .destructive) {
                Task { message = await session.remove(item).message }
            } label: {
                Text("Stop and Move to Trash")
            }
        } message: { _ in
            Text("It is stopped now and will not start again. Its file goes to the Trash, so you can put it back.")
        }
        .alert(
            Text(AppSection.startup.title),
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button {
                message = nil
            } label: {
                Text("OK")
            }
        } message: {
            if let message { Text(message) }
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(of: StartupRow.self, selection: $highlighted) {
            TableColumn(Text("Name")) { row in
                StartupNameCell(row: row, ownerName: row.item.flatMap(ownerName))
            }
            .width(min: 220, ideal: 320)

            TableColumn(Text("Runs")) { row in
                if let item = row.item {
                    Text(item.scheduleDescription)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(row.count) items")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 130)

            TableColumn(Text("Status")) { row in
                if let item = row.item {
                    StartupStatus(item: item, session: session)
                } else if let group = row.group {
                    Text(group.statusSummary)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 200)
        } rows: {
            ForEach(visibleGroups, id: \.group) { entry in
                DisclosureTableRow(
                    StartupRow(group: entry.group, count: entry.items.count), isExpanded: expandedBinding(entry.group)
                ) {
                    ForEach(entry.items.map(StartupRow.init(item:))) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: StartupRow.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            highlighted = ids
            showsInspector = true
        }
        .accessibilityLabel(Text(AppSection.startup.title))
        .accessibilityIdentifier("review.results")
    }

    @ViewBuilder private func contextMenu(for ids: Set<StartupRow.ID>) -> some View {
        let items = session.items.filter { ids.contains($0.id) }
        if items.count == 1, let item = items.first {
            Button {
                highlighted = ids
                showsInspector = true
            } label: {
                Text("Show Details")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.plistPath)])
            } label: {
                Text("Show in Finder")
            }
            if session.canControl(item) {
                Divider()
                Button {
                    Task {
                        message =
                            await session.stop(item)
                            ? "Stopped for now. It starts again at your next login." : "macOS could not stop this item."
                    }
                } label: {
                    Text("Stop")
                }
                Button {
                    Task { message = await session.start(item) ? "Started." : "macOS could not start this item." }
                } label: {
                    Text("Start")
                }
            }
            if session.canRemove(item) {
                Divider()
                Button {
                    removing = item
                } label: {
                    Text("Remove…")
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await session.load(installedApps: installedApps) }
            } label: {
                Label {
                    Text("Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Read the startup items again (⌘R)"))

            Menu {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text("Open Login Items Settings")
                }
            } label: {
                Label {
                    Text("More")
                } icon: {
                    Image(systemName: "ellipsis")
                }
            }
            .menuIndicator(.hidden)
            .help(Text("More actions"))
        }

        ToolbarItem {
            Button {
                showsInspector.toggle()
            } label: {
                Label {
                    Text(showsInspector ? "Hide Details" : "Show Details")
                } icon: {
                    Image(systemName: "sidebar.trailing")
                }
            }
            .help(Text("Show or hide the details of the highlighted item (⌃⌘I)"))
        }
    }

    // MARK: - Data

    private var highlightedItems: [LaunchItem] { session.items.filter { highlighted.contains($0.id) } }

    private var visibleGroups: [(group: StartupGroup, items: [LaunchItem])] {
        StartupGroup.allCases.compactMap { group in
            let items = session.items.filter { group.contains($0) && matches($0) }
            return items.isEmpty ? nil : (group, items)
        }
    }

    private func matches(_ item: LaunchItem) -> Bool {
        guard !query.isEmpty else { return true }
        return [item.label, item.program, ownerName(of: item), item.displayName].compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func ownerName(of item: LaunchItem) -> String? {
        guard let path = item.ownerAppPath else { return nil }
        return installedApps.first { $0.id == path }?.name
    }

    private func expandedBinding(_ group: StartupGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(group) },
            set: { expanded in
                if expanded { collapsed.remove(group) } else { collapsed.insert(group) }
            })
    }
}

/// The startup groups, problems first.
enum StartupGroup: CaseIterable, Hashable {
    case needsAttention, userAgents, systemAgents, systemDaemons

    var title: LocalizedStringResource {
        switch self {
        case .needsAttention: "Needs Attention"
        case .userAgents: "Your Login Agents"
        case .systemAgents: "System Agents"
        case .systemDaemons: "System Daemons"
        }
    }

    /// What the items in this group have in common, for the group row's Status cell.
    var statusSummary: LocalizedStringResource {
        switch self {
        case .needsAttention: "Program missing"
        case .userAgents: "Installed by you or your apps"
        case .systemAgents, .systemDaemons: "For all users"
        }
    }

    func contains(_ item: LaunchItem) -> Bool {
        switch self {
        case .needsAttention: item.programState == .missing
        case .userAgents: item.domain == .userAgent && item.programState != .missing
        case .systemAgents: item.domain == .systemAgent && item.programState != .missing
        case .systemDaemons: item.domain == .systemDaemon && item.programState != .missing
        }
    }
}

/// One table row: a group header or one startup item.
struct StartupRow: Identifiable {
    let id: String
    let group: StartupGroup?
    let item: LaunchItem?
    let count: Int

    init(group: StartupGroup, count: Int) {
        id = "group:\(group)"
        self.group = group
        item = nil
        self.count = count
    }

    init(item: LaunchItem) {
        id = item.id
        group = nil
        self.item = item
        count = 1
    }
}

private struct StartupNameCell: View {
    let row: StartupRow
    let ownerName: String?

    var body: some View {
        if let item = row.item {
            Label {
                Text(verbatim: ownerName ?? item.displayName)
                    .lineLimit(1)
            } icon: {
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            .help(Text(verbatim: item.label ?? item.plistPath))
        } else if let group = row.group {
            Label {
                Text(group.title)
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: group == .needsAttention ? "exclamationmark.triangle" : "power")
                    .foregroundStyle(group == .needsAttention ? .orange : .secondary)
            }
        }
    }
}

/// Program missing, Apple, managed, or an icon-plus-word state.
private struct StartupStatus: View {
    let item: LaunchItem
    let session: StartupSession

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(item.programState == .missing ? .orange : .secondary)
        }
        .labelStyle(.titleAndIcon)
    }

    private var title: LocalizedStringResource {
        if item.programState == .missing { return "Program missing" }
        if item.isApple { return "Part of macOS" }
        if session.isManaged(item) { return "Managed by your organisation" }
        return "Installed"
    }

    private var symbol: String {
        if item.programState == .missing { return "exclamationmark.triangle" }
        if item.isApple || session.isManaged(item) { return "lock" }
        return "checkmark.circle"
    }
}

/// Details of one startup item, its running state, and the actions that apply to it.
private struct StartupInspector: View {
    let item: LaunchItem?
    let session: StartupSession
    let ownerName: String?
    let remove: (LaunchItem) -> Void
    let report: (LocalizedStringResource) -> Void

    @State private var isRunning: Bool?
    @State private var isWorking = false

    var body: some View {
        if let item {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        Text(verbatim: ownerName ?? item.displayName)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        StartupStatus(item: item, session: session)
                    }
                    .frame(maxWidth: .infinity)
                }

                Section {
                    LabeledContent {
                        switch isRunning {
                        case true?: Text("Running")
                        case false?: Text("Not running")
                        case nil: Text("Unknown")
                        }
                    } label: {
                        Text("Now")
                    }
                    LabeledContent {
                        Text(item.scheduleDescription)
                    } label: {
                        Text("Runs")
                    }
                    if let label = item.label {
                        LabeledContent {
                            Text(verbatim: label)
                                .textSelection(.enabled)
                                .environment(\.layoutDirection, .leftToRight)
                        } label: {
                            Text("Label")
                        }
                    }
                    if let ownerName {
                        LabeledContent {
                            Text(verbatim: ownerName)
                        } label: {
                            Text("Belongs To")
                        }
                    }
                }

                if let program = item.program {
                    Section {
                        PathText(path: ([program] + item.arguments.dropFirst()).joined(separator: " "))
                    } header: {
                        Text("Runs This Program")
                    }
                }

                Section {
                    PathText(path: item.plistPath)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.plistPath)])
                    } label: {
                        Text("Show in Finder")
                    }
                } header: {
                    Text("Location")
                }

                if session.canControl(item) || session.canRemove(item) {
                    Section {
                        HStack {
                            if session.canControl(item) {
                                Button {
                                    act {
                                        await session.stop(item)
                                            ? "Stopped for now. It starts again at your next login."
                                            : "macOS could not stop this item."
                                    }
                                } label: {
                                    Text("Stop")
                                }
                                .disabled(isWorking || isRunning == false)
                                Button {
                                    act { await session.start(item) ? "Started." : "macOS could not start this item." }
                                } label: {
                                    Text("Start")
                                }
                                .disabled(isWorking || isRunning == true)
                            }
                            Spacer()
                            if session.canRemove(item) {
                                Button(role: .destructive) {
                                    remove(item)
                                } label: {
                                    Text("Remove…")
                                }
                            }
                        }
                    } footer: {
                        Text(
                            "Stop and Start apply to this login only. Remove stops it and moves its file to the Trash."
                        )
                        .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .task(id: item.id) { isRunning = await session.isRunning(item) }
        } else {
            ContentUnavailableView {
                Label {
                    Text("No Selection")
                } icon: {
                    Image(systemName: "sidebar.trailing")
                }
            } description: {
                Text("Select a startup item to see what it runs, when, and who made it.")
            }
        }
    }

    private func act(_ action: @escaping () async -> LocalizedStringResource) {
        guard let item else { return }
        isWorking = true
        Task {
            report(await action())
            isRunning = await session.isRunning(item)
            isWorking = false
        }
    }
}

extension LaunchItem {
    fileprivate var scheduleDescription: LocalizedStringResource {
        if schedules.contains(.keepAlive) { return "Always running" }
        if schedules.contains(.atLoad) { return "At login" }
        if schedules.contains(where: { if case .interval = $0 { true } else { false } }) { return "Repeats" }
        if schedules.contains(.calendar) { return "On a schedule" }
        return "When needed"
    }

    /// A readable name from the reverse-DNS label: "com.google.keystone.agent" → "Google Keystone Agent".
    fileprivate var displayName: String {
        let raw = label ?? ((plistPath as NSString).lastPathComponent as NSString).deletingPathExtension
        var parts = raw.split(separator: ".").map(String.init)
        if parts.count > 2, ["com", "org", "net", "io", "de", "co", "app", "dev"].contains(parts[0].lowercased()) {
            parts.removeFirst()
        }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The owning app's icon, else the program's, else a generic gear.
    fileprivate var icon: NSImage {
        let candidates = [ownerAppPath, program].compactMap { $0 }
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
    }
}

extension StartupSession.RemovalOutcome {
    fileprivate var message: LocalizedStringResource {
        switch self {
        case .removed: "The item was stopped and moved to the Trash."
        case .notAllowed: "Only your own startup items can be removed here. Use Show in Finder for system items."
        case .couldNotStop: "macOS could not stop this item, so it was kept."
        case .refused(let outcome): outcome.explanation
        }
    }
}
