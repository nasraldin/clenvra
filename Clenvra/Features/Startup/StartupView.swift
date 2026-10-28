import ClenvraKit
import ServiceManagement
import SwiftUI

/// Everything that starts automatically, problems first.
struct StartupView: View {
    let session: StartupSession
    let installedApps: [InstalledApp]

    @State private var removing: LaunchItem?
    @State private var removalMessage: LocalizedStringResource?

    var body: some View {
        Group {
            if session.isLoading && session.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Label {
                        Text("Login Items Settings")
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
                Button {
                    Task { await session.load(installedApps: installedApps) }
                } label: {
                    Label {
                        Text("Rescan")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task(id: installedApps.count) { await session.load(installedApps: installedApps) }
        .confirmationDialog(
            Text("Remove this startup item?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { item in
            Button(role: .destructive) {
                Task {
                    let outcome = await session.remove(item)
                    removalMessage = outcome.message
                }
            } label: {
                Text("Stop and Move to Trash")
            }
        } message: { _ in
            Text("It is stopped now and will not start again. Its file goes to the Trash, so you can put it back.")
        }
        .alert(
            Text("Startup item"),
            isPresented: Binding(get: { removalMessage != nil }, set: { if !$0 { removalMessage = nil } })
        ) {
            Button {
                removalMessage = nil
            } label: {
                Text("OK")
            }
        } message: {
            if let removalMessage { Text(removalMessage) }
        }
    }

    private var list: some View {
        List {
            section(Text("Needs Attention"), items: session.items.filter { $0.programState == .missing })
            section(Text("Your Login Agents"), items: present(.userAgent))
            section(Text("System Agents"), items: present(.systemAgent))
            section(Text("System Daemons"), items: present(.systemDaemon))
        }
        .accessibilityLabel(Text(AppSection.startup.title))
        .accessibilityIdentifier("review.results")
    }

    private func present(_ domain: LaunchItem.Domain) -> [LaunchItem] {
        session.items.filter { $0.domain == domain && $0.programState != .missing }
    }

    @ViewBuilder
    private func section(_ title: Text, items: [LaunchItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    LaunchItemRow(
                        item: item, ownerName: ownerName(of: item), canRemove: session.canRemove(item),
                        isManaged: session.isManaged(item),
                        needsHelper: session.needsHelper(item) && !session.helperAvailable
                    ) {
                        removing = item
                    }
                }
            } header: {
                title.font(.headline)
            }
        }
    }

    private func ownerName(of item: LaunchItem) -> String? {
        guard let path = item.ownerAppPath else { return nil }
        return installedApps.first { $0.id == path }?.name
    }
}

private struct LaunchItemRow: View {
    let item: LaunchItem
    let ownerName: String?
    let canRemove: Bool
    let isManaged: Bool
    let needsHelper: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.programState == .missing ? "exclamationmark.triangle.fill" : "gearshape.2")
                .foregroundStyle(item.programState == .missing ? .orange : .secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.label ?? (item.plistPath as NSString).lastPathComponent)
                    .environment(\.layoutDirection, .leftToRight)
                HStack(spacing: 6) {
                    if let ownerName {
                        Text(verbatim: ownerName)
                    } else if item.programState == .missing {
                        Text("Program missing — left behind by an app that was removed")
                    }
                    if item.isApple { Text("Apple") }
                    if isManaged { Text("Managed by your organisation") }
                    if needsHelper { Text("Install the System Helper in Settings to remove it") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let program = item.program { PathText(path: program) }
            }
            Spacer(minLength: 12)
            Text(item.scheduleDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if canRemove {
                Button(action: remove) {
                    Text("Remove…")
                }
            } else {
                Button {
                    NSWorkspace.shared.selectFile(item.plistPath, inFileViewerRootedAtPath: "")
                } label: {
                    Text("Show in Finder")
                }
            }
        }
        .accessibilityElement(children: .combine)
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
