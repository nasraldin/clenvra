import AppKit
import ClenvraKit
import SwiftUI

/// Which apps may use the camera, microphone, screen, files and other protected services, grouped by service, with
/// Revoke through Apple's `tccutil` for apps listed by bundle ID.
struct PermissionsView: View {
    let session: PermissionsSession

    @State private var highlighted: Set<PermissionRow.ID> = []
    @State private var showsInspector = false
    private let groups = ExpandedGroups("permissions")
    @State private var clients: [String: PermissionClient] = [:]
    @State private var revoking: [PermissionGrant] = []
    /// Grants that are still there after Revoke.
    @State private var failed: [PermissionGrant] = []
    /// The selection holds only programs listed by path, which only System Settings can change.
    @State private var notRevocable: PermissionGrant?
    @State private var isRevoking = false
    @State private var searchText = ""
    private var query: String { AppSearch.normalized(searchText) }

    var body: some View {
        table
            .pageState(isShown: visibleGroups.isEmpty) { placeholder }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.phase == .ready, !session.unreadableScopes.isEmpty {
                    partialNote
                }
            }
            .pageSearch(text: $searchText, prompt: "Search Permissions", section: .permissions)
            .toolbar { toolbar }
            .detailsPanel(isPresented: $showsInspector, width: 300) {
                PermissionInspector(
                    grant: highlightedGrants.count == 1 ? highlightedGrants.first : nil, session: session,
                    client: highlightedGrants.first.map(client), revoke: { askToRevoke([$0]) })
            }
            // Reading the privacy database changes nothing, like the Startup Items page.
            .task { if session.phase == .idle { await session.load() } }
            .task(id: session.grants) { resolveClients() }
            .confirmationDialog(
                revoking.count == 1 ? Text("Revoke this permission?") : Text("Revoke \(revoking.count) permissions?"),
                isPresented: Binding(get: { !revoking.isEmpty }, set: { if !$0 { revoking = [] } }),
                presenting: revoking
            ) { grants in
                Button(role: .destructive) {
                    revoke(grants)
                } label: {
                    Text("Revoke")
                }
            } message: { grants in
                revokeMessage(grants)
            }
            .alert(
                failed.count == 1
                    ? Text("Could not revoke this permission") : Text("Could not revoke \(failed.count) permissions"),
                isPresented: Binding(get: { !failed.isEmpty }, set: { if !$0 { failed = [] } }),
                presenting: failed.first
            ) { grant in
                Button {
                    NSWorkspace.shared.open(PermissionService.settingsURL(grant.service))
                } label: {
                    Text("Open Privacy Settings")
                }
                Button(role: .cancel) {
                    failed = []
                } label: {
                    Text("OK")
                }
            } message: { grant in
                if failed.count == 1 {
                    Text(
                        "\(client(for: grant).name) still has access to \(String(localized: PermissionService.title(grant.service))). Change it in System Settings."
                    )
                } else {
                    Text("These apps still have access. Change them in System Settings.")
                }
            }
            .alert(
                Text("This permission cannot be revoked here"),
                isPresented: Binding(get: { notRevocable != nil }, set: { if !$0 { notRevocable = nil } }),
                presenting: notRevocable
            ) { grant in
                Button {
                    NSWorkspace.shared.open(PermissionService.settingsURL(grant.service))
                } label: {
                    Text("Open Privacy Settings")
                }
                Button(role: .cancel) {
                    notRevocable = nil
                } label: {
                    Text("OK")
                }
            } message: { _ in
                Text("Programs listed by path, not as an app, can only be changed in System Settings.")
            }
    }

    // MARK: - Revoke

    /// Revocable grants go to the confirmation; a selection of only path programs explains why it cannot.
    private func askToRevoke(_ grants: [PermissionGrant]) {
        let revocable = grants.filter(session.canRevoke)
        if revocable.isEmpty {
            notRevocable = grants.first
        } else {
            revoking = revocable
        }
    }

    private func revoke(_ grants: [PermissionGrant]) {
        guard !isRevoking else { return }
        isRevoking = true
        Task {
            let results = await session.revoke(grants)
            isRevoking = false
            failed = grants.filter { results[$0.id] != .revoked }
        }
    }

    private func revokeMessage(_ grants: [PermissionGrant]) -> Text {
        let needsPassword = grants.contains(where: session.revokesThroughHelper)
        if grants.count == 1, let grant = grants.first {
            let name = client(for: grant).name
            let service = String(localized: PermissionService.title(grant.service))
            return needsPassword
                ? Text(
                    "\(name) will lose access to \(service) for all users. macOS asks for an administrator’s password first."
                )
                : Text("\(name) will lose access to \(service). macOS asks again the next time it needs it.")
        }
        return needsPassword
            ? Text(
                "These apps will lose these permissions. Permissions for all users ask for an administrator’s password."
            )
            : Text("These apps will lose these permissions. macOS asks again the next time they need them.")
    }

    @ViewBuilder private var placeholder: some View {
        switch session.phase {
        case .idle, .loading:
            ProgressView {
                Text("Reading permissions…")
            }
        case .needsAccess:
            ContentUnavailableView {
                Label {
                    Text("Allow Full Disk Access")
                } icon: {
                    Image(systemName: "lock.shield")
                }
            } description: {
                Text(
                    "macOS keeps the list of app permissions private. Allow Full Disk Access for Clenvra, then refresh."
                )
            } actions: {
                if let url = FullDiskAccess.settingsURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("Open Privacy Settings…")
                    }
                }
            }
        case .ready:
            if query.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No Permissions")
                    } icon: {
                        Image(systemName: "hand.raised")
                    }
                } description: {
                    Text("No app has access to your camera, microphone, screen or other protected data.")
                }
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var partialNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Some permissions could not be read, so they are not listed.")
            if let url = FullDiskAccess.settingsURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Open Privacy Settings…")
                }
                .buttonStyle(.link)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .statusBarBackground()
    }

    // MARK: - Table

    private var table: some View {
        Table(of: PermissionRow.self, selection: $highlighted) {
            TableColumn(Text("Name")) { row in
                PermissionNameCell(row: row, client: row.grant.map(client))
            }
            .width(min: 220, ideal: 320)

            TableColumn(Text("Since")) { row in
                if let date = row.grant?.lastModified {
                    Text(date, format: .dateTime.year().month().day())
                        .foregroundStyle(.secondary)
                } else if row.grant == nil {
                    Text("\(row.count) apps")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 130)

        } rows: {
            ForEach(visibleGroups, id: \.service) { entry in
                DisclosureTableRow(
                    PermissionRow(service: entry.service, count: entry.grants.count),
                    isExpanded: expandedBinding(entry.service)
                ) {
                    ForEach(entry.grants.map(PermissionRow.init(grant:))) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: PermissionRow.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            highlighted = ids
            showsInspector = true
        }
        .accessibilityLabel(Text(AppSection.permissions.title))
        .accessibilityIdentifier("review.results")
    }

    @ViewBuilder private func contextMenu(for ids: Set<PermissionRow.ID>) -> some View {
        let grants = session.grants.filter { ids.contains($0.id) }
        if grants.count > 1 {
            let revocable = grants.filter(session.canRevoke)
            if !revocable.isEmpty {
                Button {
                    askToRevoke(revocable)
                } label: {
                    Text("Revoke \(revocable.count) Permissions…")
                }
            }
        } else if let grant = grants.first {
            Button {
                highlighted = ids
                showsInspector = true
            } label: {
                Text("Show Details")
            }
            if let url = client(for: grant).location {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Text("Show in Finder")
                }
            }
            Button {
                NSWorkspace.shared.open(PermissionService.settingsURL(grant.service))
            } label: {
                Text("Open Privacy Settings")
            }
            if session.canRevoke(grant) {
                Divider()
                Button {
                    askToRevoke([grant])
                } label: {
                    Text("Revoke…")
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                askToRevoke(highlightedGrants)
            } label: {
                ToolbarLabel(title: "Revoke", symbol: "hand.raised.slash")
            }
            .help(Text("Remove the selected permissions. macOS asks again the next time the app needs them."))
            .disabled(isRevoking || highlightedGrants.isEmpty)
        }

        ToolbarItemGroup {
            Button {
                Task { await session.load() }
            } label: {
                ToolbarLabel(title: "Refresh", symbol: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Read the permissions again (⌘R)"))
            .disabled(session.phase == .loading)

            ExpandAllButton(allExpanded: groups.allBinding(visibleGroups.map(\.service)))
                .disabled(visibleGroups.isEmpty)
        }

        ToolbarItem {
            InspectorToggle(isPresented: $showsInspector)
        }
    }

    // MARK: - Data

    private var highlightedGrants: [PermissionGrant] { session.grants.filter { highlighted.contains($0.id) } }

    /// Services in the session's order (sorted by service), each with its matching grants.
    private var visibleGroups: [(service: String, grants: [PermissionGrant])] {
        var order: [String] = []
        var byService: [String: [PermissionGrant]] = [:]
        for grant in session.grants where matches(grant) {
            if byService[grant.service] == nil { order.append(grant.service) }
            byService[grant.service, default: []].append(grant)
        }
        return order.map { ($0, byService[$0] ?? []) }
    }

    private func matches(_ grant: PermissionGrant) -> Bool {
        guard !query.isEmpty else { return true }
        return [grant.client, client(for: grant).name, String(localized: PermissionService.title(grant.service))]
            .contains { $0.localizedStandardContains(query) }
    }

    private func client(for grant: PermissionGrant) -> PermissionClient {
        clients[grant.client] ?? PermissionClient(grant: grant)
    }

    private func resolveClients() {
        var resolved: [String: PermissionClient] = [:]
        for grant in session.grants where resolved[grant.client] == nil {
            resolved[grant.client] = PermissionClient(grant: grant)
        }
        clients = resolved
    }

    private func expandedBinding(_ service: String) -> Binding<Bool> {
        groups.binding(service) { visibleGroups.map(\.service) }
    }
}

/// The app (or program) a grant belongs to, as the person knows it.
struct PermissionClient {
    let name: String
    /// The app bundle or program, when it is on this Mac.
    let location: URL?
    let icon: NSImage

    init(grant: PermissionGrant) {
        if grant.clientIsBundleID {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: grant.client)
            location = url
            if let url {
                name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
                    .replacing(/\.app$/, with: "")
                icon = IconCache.shared.icon(forFile: url.path(percentEncoded: false))
            } else {
                name = grant.client
                icon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
            }
        } else {
            let exists = FileManager.default.fileExists(atPath: grant.client)
            location = exists ? URL(filePath: grant.client) : nil
            name = (grant.client as NSString).lastPathComponent
            icon =
                exists
                ? IconCache.shared.icon(forFile: grant.client)
                : NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        }
    }
}

/// One table row: a service header or one app's grant.
struct PermissionRow: Identifiable {
    let id: String
    let service: String
    let grant: PermissionGrant?
    let count: Int

    init(service: String, count: Int) {
        id = "service:\(service)"
        self.service = service
        grant = nil
        self.count = count
    }

    init(grant: PermissionGrant) {
        id = grant.id
        service = grant.service
        self.grant = grant
        count = 1
    }
}

private struct PermissionNameCell: View {
    let row: PermissionRow
    let client: PermissionClient?

    var body: some View {
        if let grant = row.grant, let client {
            // Icon and text side by side, and who the grant is for under the name: an empty cell on the group rows
            // would be an unlabelled element.
            HStack(spacing: 6) {
                Image(nsImage: client.icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: client.name)
                        .lineLimit(1)
                    Text(grant.scope == .user ? "This user" : "All users")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .help(Text(verbatim: grant.client))
        } else {
            Label {
                Text(PermissionService.title(row.service))
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: PermissionService.symbol(row.service))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Details of one grant and what can be done about it.
private struct PermissionInspector: View {
    let grant: PermissionGrant?
    let session: PermissionsSession
    let client: PermissionClient?
    let revoke: (PermissionGrant) -> Void

    var body: some View {
        if let grant, let client {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(nsImage: client.icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        Text(verbatim: client.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Label {
                            Text(PermissionService.title(grant.service))
                        } icon: {
                            Image(systemName: PermissionService.symbol(grant.service))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                Section {
                    if let date = grant.lastModified {
                        LabeledContent {
                            Text(date, format: .dateTime.year().month().day())
                        } label: {
                            Text("Since")
                        }
                    }
                    LabeledContent {
                        Text(grant.scope == .user ? "This user" : "All users")
                    } label: {
                        Text("For")
                    }
                    LabeledContent {
                        Text(verbatim: grant.client)
                            .textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                    } label: {
                        Text(grant.clientIsBundleID ? "Bundle ID" : "Program")
                    }
                }

                Section {
                    HStack {
                        Button {
                            NSWorkspace.shared.open(PermissionService.settingsURL(grant.service))
                        } label: {
                            Text("Open Privacy Settings")
                        }
                        if let url = client.location {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                Text("Show in Finder")
                            }
                        }
                        Spacer()
                        if session.canRevoke(grant) {
                            Button(role: .destructive) {
                                revoke(grant)
                            } label: {
                                Text("Revoke…")
                            }
                        }
                    }
                } footer: {
                    if session.revokesThroughHelper(grant) {
                        Text(
                            "This permission is for all users. Revoke asks for an administrator’s password, then removes it."
                        )
                        .font(.callout)
                    } else if session.canRevoke(grant) {
                        Text("Revoke removes this permission. macOS asks again the next time the app needs it.")
                            .font(.callout)
                    } else {
                        Text("Programs listed by path are changed in System Settings.")
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label {
                    Text("No Selection")
                } icon: {
                    Image(systemName: "sidebar.trailing")
                }
            } description: {
                Text("Select an app to see the permission and change it.")
            }
        }
    }
}
