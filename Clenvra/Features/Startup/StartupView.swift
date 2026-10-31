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
    private let groups = ExpandedGroups("startup")
    @State private var removing: [LaunchItem] = []
    @State private var isChanging = false
    @State private var message: LocalizedStringResource?
    @State private var searchText = ""
    private var query: String { AppSearch.normalized(searchText) }

    var body: some View {
        table
            .pageState(isShown: visibleGroups.isEmpty && (session.isLoading || !query.isEmpty)) {
                if session.isLoading {
                    ProgressView {
                        Text("Reading startup items…")
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .pageSearch(text: $searchText, prompt: "Search Startup Items", section: .startup)
            .toolbar { toolbar }
            .detailsPanel(isPresented: $showsInspector, width: 300) {
                StartupInspector(
                    item: highlightedItems.count == 1 ? highlightedItems.first : nil, session: session,
                    ownerName: highlightedItems.first.flatMap(ownerName), remove: { removing = [$0] },
                    change: { change([$0], enable: $1) }, report: { message = $0 }
                )
            }
            // Listing what is installed is instant and changes nothing, like Finder showing a folder.
            .task(id: installedApps.count) { await reload() }
            .confirmationDialog(
                removing.count == 1
                    ? Text("Remove this startup item?") : Text("Remove \(removing.count) startup items?"),
                isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }),
                presenting: removing
            ) { items in
                Button(role: .destructive) {
                    remove(items)
                } label: {
                    Text("Stop and Move to Trash")
                }
            } message: { _ in
                Text(
                    "Stopped now, they will not start again. Their files go to the Trash, so you can put them back."
                )
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
        if items.count > 1 {
            actionButtons(for: items)
        } else if let item = items.first {
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
            Divider()
            actionButtons(for: [item])
            if !session.canDisable(item) || session.needsLoginItemsSettings(item) {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text("Manage in Login Items Settings")
                }
            }
        }
    }

    /// Disable, Enable and Remove for every item that allows it.
    @ViewBuilder private func actionButtons(for items: [LaunchItem]) -> some View {
        let disabling = disableTargets(items)
        let enabling = enableTargets(items)
        let removable = items.filter(session.canRemove)
        if !disabling.isEmpty {
            Button {
                change(disabling, enable: false)
            } label: {
                disabling.count == 1 ? Text("Disable") : Text("Disable \(disabling.count) Items")
            }
        }
        if !enabling.isEmpty {
            Button {
                change(enabling, enable: true)
            } label: {
                enabling.count == 1 ? Text("Enable") : Text("Enable \(enabling.count) Items")
            }
        }
        if !removable.isEmpty {
            Button {
                removing = removable
            } label: {
                removable.count == 1 ? Text("Remove…") : Text("Remove \(removable.count) Items…")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                change(disableTargets(highlightedItems), enable: false)
            } label: {
                ToolbarLabel(title: "Disable", symbol: "pause.circle")
            }
            .help(Text("Stop the selected items and keep them from starting again. Enable undoes it."))
            .disabled(isChanging || disableTargets(highlightedItems).isEmpty)

            Button {
                change(enableTargets(highlightedItems), enable: true)
            } label: {
                ToolbarLabel(title: "Enable", symbol: "play.circle")
            }
            .help(Text("Allow the selected disabled items to start again"))
            .disabled(isChanging || enableTargets(highlightedItems).isEmpty)

            Button {
                removing = highlightedItems.filter(session.canRemove)
            } label: {
                ToolbarLabel(title: "Remove", symbol: "trash")
            }
            .help(Text("Stop the selected items and move their files to the Trash"))
            .disabled(isChanging || !highlightedItems.contains(where: session.canRemove))
        }

        ToolbarItemGroup {
            Button {
                Task { await reload() }
            } label: {
                ToolbarLabel(title: "Refresh", symbol: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Read the startup items again (⌘R)"))

            ExpandAllButton(allExpanded: groups.allBinding(visibleGroups.map { String(describing: $0.group) }))
                .disabled(visibleGroups.isEmpty)

            Menu {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text("Open Login Items Settings")
                }
            } label: {
                ToolbarLabel(title: "More", symbol: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help(Text("More actions"))
        }

        ToolbarItem {
            InspectorToggle(isPresented: $showsInspector)
        }
    }

    // MARK: - Actions

    private func reload() async {
        await session.load(installedApps: installedApps)
        await session.loadDisabledState()
    }

    private func disableTargets(_ items: [LaunchItem]) -> [LaunchItem] {
        items.filter { session.canDisable($0) && !session.isDisabled($0) }
    }

    private func enableTargets(_ items: [LaunchItem]) -> [LaunchItem] {
        items.filter { session.canDisable($0) && session.isDisabled($0) }
    }

    /// One item at a time: each Mac-wide item asks for an administrator's password.
    private func change(_ items: [LaunchItem], enable: Bool) {
        guard !items.isEmpty, !isChanging else { return }
        isChanging = true
        Task {
            var outcomes: [StartupSession.ChangeOutcome] = []
            for item in items {
                outcomes.append(enable ? await session.enable(item) : await session.disable(item))
            }
            await session.loadDisabledState()
            isChanging = false
            message = StartupSession.ChangeOutcome.summary(outcomes, enabling: enable)
        }
    }

    private func remove(_ items: [LaunchItem]) {
        guard !items.isEmpty, !isChanging else { return }
        isChanging = true
        Task {
            var outcomes: [StartupSession.RemovalOutcome] = []
            for item in items { outcomes.append(await session.remove(item)) }
            isChanging = false
            let failures = outcomes.filter { $0 != .removed }
            if let failure = failures.first {
                message =
                    failures.count == outcomes.count
                    ? failure.message : "Some items were moved to the Trash. Others were kept: \(failure.message)"
            } else {
                message =
                    outcomes.count == 1
                    ? StartupSession.RemovalOutcome.removed.message
                    : "\(outcomes.count) items were stopped and moved to the Trash."
            }
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
            .contains { $0.localizedStandardContains(query) }
    }

    private func ownerName(of item: LaunchItem) -> String? {
        guard let path = item.ownerAppPath else { return nil }
        return installedApps.first { $0.id == path }?.name
    }

    private func expandedBinding(_ group: StartupGroup) -> Binding<Bool> {
        groups.binding(String(describing: group)) { StartupGroup.allCases.map { String(describing: $0) } }
    }
}

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
        if session.isDisabled(item) { return "Disabled" }
        if session.needsLoginItemsSettings(item) { return "Waiting for approval" }
        return "Installed"
    }

    private var symbol: String {
        if item.programState == .missing { return "exclamationmark.triangle" }
        if item.isApple || session.isManaged(item) { return "lock" }
        if session.isDisabled(item) { return "pause.circle" }
        if session.needsLoginItemsSettings(item) { return "hand.raised" }
        return "checkmark.circle"
    }
}

/// Details of one startup item, its running state, and the actions that apply to it.
private struct StartupInspector: View {
    let item: LaunchItem?
    let session: StartupSession
    let ownerName: String?
    let remove: (LaunchItem) -> Void
    /// Disable (`false`) or enable (`true`) the item.
    let change: (LaunchItem, Bool) -> Void
    let report: (LocalizedStringResource) -> Void

    @State private var isRunning: Bool?
    @State private var isWorking = false
    /// Who signed the program the item runs (F8); read when the item is highlighted.
    @State private var signature: CodeSignature?

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
                        if let signature {
                            LabeledContent {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(signature.kind.title)
                                    if let authority = signature.authority {
                                        Text(verbatim: authority)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                }
                            } label: {
                                Text("Signed By")
                            }
                        }
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

                Section {
                    HStack {
                        if session.canDisable(item) {
                            if session.isDisabled(item) {
                                Button {
                                    change(item, true)
                                } label: {
                                    Text("Enable")
                                }
                            } else {
                                Button {
                                    change(item, false)
                                } label: {
                                    Text("Disable")
                                }
                            }
                        }
                        Button {
                            SMAppService.openSystemSettingsLoginItems()
                        } label: {
                            Text("Manage in Login Items Settings")
                        }
                    }
                } footer: {
                    Text(disableExplanation(for: item))
                        .font(.callout)
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
            .task(id: item.id) {
                signature = nil
                if let program = item.program, program.hasPrefix("/") {
                    signature = await Task.detached { CodeSignature.read(at: program) }.value
                }
                isRunning = await session.isRunning(item)
            }
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

    private func disableExplanation(for item: LaunchItem) -> LocalizedStringResource {
        if item.isApple || session.isManaged(item) {
            return "This item cannot be changed here. Login Items Settings shows what macOS allows."
        }
        if session.needsLoginItemsSettings(item) {
            return "macOS is waiting for you to allow this item. Only Login Items Settings can allow it."
        }
        if !session.canDisable(item) {
            return
                "Items for all users are changed with Clenvra’s helper. Install it in Settings, or use Login Items Settings."
        }
        if item.domain == .userAgent {
            return "Disable stops it and keeps it from starting again; its file stays. Enable undoes it."
        }
        return "This item is for all users: Disable and Enable ask for an administrator’s password each time."
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
        IconCache.shared.icon(
            firstExistingOf: [ownerAppPath, program].compactMap { $0 },
            fallback: NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage())
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

extension StartupSession.ChangeOutcome {
    fileprivate var message: LocalizedStringResource {
        switch self {
        case .done: "Done."
        case .notAllowed: "This item cannot be changed here. Use Login Items Settings."
        case .changedSinceReview: "This item changed since it was listed, so nothing was done. Refresh and try again."
        case .notAuthorized: "Nothing was changed: an administrator’s password is needed for items for all users."
        case .failed: "macOS could not change this item."
        }
    }

    /// One message for a batch: the first problem, or what was done.
    fileprivate static func summary(_ outcomes: [Self], enabling: Bool) -> LocalizedStringResource {
        let failures = outcomes.filter { $0 != .done }
        if let failure = failures.first {
            return failures.count == outcomes.count
                ? failure.message : "Some items were changed. Others were not: \(failure.message)"
        }
        return enabling
            ? "Enabled. It can start again, and was started now if macOS allowed it."
            : "Disabled. It was stopped and will not start again until you enable it."
    }
}

extension CodeSignature.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .apple: "Apple"
        case .appStore: "Mac App Store"
        case .developerID: "Identified developer"
        case .otherCertificate: "Developer certificate"
        case .adHoc: "Not identified (ad hoc)"
        case .unsigned: "Not signed"
        case .invalid: "Broken signature"
        }
    }
}
