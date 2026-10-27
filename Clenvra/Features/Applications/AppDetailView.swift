import AppKit
import ClenvraKit
import SwiftUI

/// Review of one app: what will be removed (grouped by confidence, with evidence) and how.
struct AppDetailView: View {
    let session: AppsSession
    /// The update check's answer for the selected app; `nil` when not checked or checks are off.
    var update: AppUpdate?

    @State private var isConfirmingUninstall = false
    @State private var resettingApp: InstalledApp?
    @State private var isConfirmingHomebrew = false
    @State private var shownResult: ShownResult?
    @State private var homebrewResult: ShownCommandResult?

    var body: some View {
        Group {
            if let detail = session.detail {
                VStack(spacing: 0) {
                    List {
                        Section {
                            AppHeader(detail: detail, session: session)
                            AvailabilityNotice(detail: detail, session: session)
                            if let command = session.homebrewCommand, detail.availability == .available {
                                HomebrewNotice(command: command) { isConfirmingHomebrew = true }
                            }
                            if let update, update.id == detail.app.id {
                                UpdateNotice(update: update)
                            }
                        }
                        if detail.items.isEmpty, detail.availability == .available {
                            Section {
                                Text("No other files were found for this app.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(detail.groups) { group in
                            Section {
                                ForEach(group.items) { item in
                                    OwnedItemRow(
                                        item: item, sharedNames: names(for: item.sharedWith),
                                        isSelectable: session.isSelectable(item),
                                        isSelected: Binding(
                                            get: { session.selection.contains(item.path) },
                                            set: { _ in session.toggle(item.path) }))
                                }
                            } header: {
                                ConfidenceHeader(confidence: group.confidence)
                            }
                        }
                    }
                    .disabled(session.isWorking)
                    .accessibilityIdentifier("review.results")
                    if detail.bundle != nil, detail.availability == .available || detail.availability == .running {
                        statusBar
                    }
                }
                .task(id: detail.app.id) {
                    // Notice when the app is opened or quit while its review is shown.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        await session.refreshAvailability()
                    }
                }
            } else if session.isResolving {
                ProgressView {
                    Text("Finding the app's files…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Select an app")
                    } icon: {
                        Image(systemName: "app.badge")
                    }
                } description: {
                    Text("Choose an app in the list, or drag one from Finder onto this window.")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { shownResult = ShownResult(summary: await session.uninstall(dryRun: true), isPreview: true) }
                } label: {
                    Label {
                        Text("Preview")
                    } icon: {
                        Image(systemName: "eye")
                    }
                }
                .disabled(!canUninstall)

                Button {
                    resettingApp = session.detail?.app
                } label: {
                    Label {
                        Text("Reset…")
                    } icon: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                .help(Text("Removes the app's settings, caches and saved state. The app stays installed."))
                .disabled(!canReset)

                Button(role: .destructive) {
                    isConfirmingUninstall = true
                } label: {
                    Label {
                        Text("Uninstall")
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canUninstall)
            }
        }
        .sheet(isPresented: $isConfirmingUninstall) {
            if let detail = session.detail {
                ConfirmUninstallSheet(
                    appName: detail.app.name, count: session.selectedCount, bytes: session.selectedBytes,
                    hasRevealOnlyItems: detail.items.contains { $0.handling == .revealOnly }
                ) {
                    isConfirmingUninstall = false
                    Task { shownResult = ShownResult(summary: await session.uninstall(), isPreview: false) }
                }
            }
        }
        .sheet(isPresented: $isConfirmingHomebrew) {
            if let command = session.homebrewCommand, let detail = session.detail {
                ConfirmHomebrewSheet(appName: detail.app.name, command: command) {
                    isConfirmingHomebrew = false
                    Task { homebrewResult = await session.uninstallWithHomebrew().map(ShownCommandResult.init) }
                }
            }
        }
        .sheet(item: $resettingApp) { app in
            ResetAppSheet(session: session, app: app) { items in
                resettingApp = nil
                Task {
                    shownResult = ShownResult(summary: await session.reset(app, items: items), isPreview: false)
                }
            }
        }
        .sheet(item: $shownResult) { shown in
            if let summary = shown.summary {
                CleanupResultSheet(summary: summary, isPreview: shown.isPreview)
            } else {
                NotUninstalledSheet()
            }
        }
        .sheet(item: $homebrewResult) { shown in
            HomebrewResultSheet(result: shown.result, output: session.homebrewOutput)
        }
    }

    private var canUninstall: Bool {
        guard let detail = session.detail else { return false }
        return detail.availability == .available && detail.bundle != nil && !session.isWorking
    }

    /// Resetting keeps the app, so only protected and managed apps are excluded; a running app is asked to quit
    /// in the reset sheet.
    private var canReset: Bool {
        guard let detail = session.detail, !session.isWorking else { return false }
        return detail.availability == .available || detail.availability == .running
    }

    private func names(for appIDs: [String]) -> [String] {
        appIDs.map { id in session.apps.first { $0.id == id }?.name ?? (id as NSString).lastPathComponent }
    }

    private var statusBar: some View {
        HStack {
            if session.isWorking {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…")
            } else {
                Text("\(session.selectedCount) items selected")
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text("Frees about \(session.selectedBytes.formatted(.byteCount(style: .file)))")
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// A finished (or refused) uninstall to show in a sheet.
private struct ShownResult: Identifiable {
    let id = UUID()
    /// `nil` when nothing was done (the app was opened, or became unavailable, in the meantime).
    let summary: CleanupSummary?
    let isPreview: Bool
}

private struct ShownCommandResult: Identifiable {
    let id = UUID()
    let result: CommandResult
}

private struct AppHeader: View {
    let detail: AppsSession.Detail
    let session: AppsSession

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIcon(path: detail.app.id, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: detail.app.name)
                    .font(.title2.bold())
                HStack(spacing: 8) {
                    if let version = detail.app.version {
                        Text("Version \(version)")
                    }
                    SourceBadge(source: detail.app.source)
                }
                .foregroundStyle(.secondary)
                if let identifier = detail.app.bundleIdentifier {
                    Text(verbatim: identifier)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                        .textSelection(.enabled)
                }
                PathText(path: detail.app.id)
                HStack(spacing: 12) {
                    if let bundle = detail.bundle {
                        Text("App size: \(bundle.allocatedSize.formatted(.byteCount(style: .file)))")
                    }
                    if let lastUsed = session.lastUsed(of: detail.app) {
                        Text("Last opened \(lastUsed.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// Why the app cannot be uninstalled right now, and what the user can do about it.
private struct AvailabilityNotice: View {
    let detail: AppsSession.Detail
    let session: AppsSession

    var body: some View {
        switch detail.availability {
        case .available:
            if detail.bundle == nil {
                notice("exclamationmark.triangle", "Clenvra could not read this app. It may have been moved.")
            }
        case .protected:
            notice("lock", "This app is part of macOS or Clenvra, so it can't be removed.")
        case .managed(let uninstaller):
            VStack(alignment: .leading, spacing: 8) {
                notice("building.2", "Managed by your organisation")
                Text(
                    "Security and management software must be removed with its own uninstaller, or by your IT department."
                )
                .foregroundStyle(.secondary)
                if let uninstaller {
                    Button {
                        NSWorkspace.shared.selectFile(uninstaller, inFileViewerRootedAtPath: "")
                    } label: {
                        Text("Show Uninstaller in Finder")
                    }
                }
            }
        case .running:
            HStack {
                notice("app.badge.clock", "Quit \(detail.app.name) to uninstall it.")
                Spacer()
                Button {
                    Task { await session.quitSelectedApp() }
                } label: {
                    Text("Quit \(detail.app.name)")
                }
            }
        }
    }

    private func notice(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(.secondary)
    }
}

private struct HomebrewNotice: View {
    let command: Command
    let run: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Installed with Homebrew")
                    .font(.headline)
                Text("You can let Homebrew remove it instead of moving it to the Trash.")
                    .foregroundStyle(.secondary)
                CommandText(command: command)
            }
            Spacer()
            Button(action: run) {
                Text("Uninstall with Homebrew…")
            }
        }
    }
}

/// The exact command, left-to-right and selectable.
struct CommandText: View {
    let command: Command

    var body: some View {
        Text(
            verbatim: ([(command.executable as NSString).lastPathComponent] + command.arguments).joined(separator: " ")
        )
        .font(.callout.monospaced())
        .environment(\.layoutDirection, .leftToRight)
        .textSelection(.enabled)
        .help(Text(verbatim: ([command.executable] + command.arguments).joined(separator: " ")))
    }
}

private struct ConfidenceHeader: View {
    let confidence: OwnedItem.Confidence

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(confidence.title).font(.headline)
            Text(confidence.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}

struct OwnedItemRow: View {
    let item: OwnedItem
    let sharedNames: [String]
    let isSelectable: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: $isSelected) {
                Text(verbatim: item.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isSelectable)

            Image(systemName: item.snapshot.kind == .directory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: item.name)
                        .lineLimit(1)
                    Text(item.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PathText(path: item.path)
                ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                    EvidenceText(evidence: evidence)
                }
                if !sharedNames.isEmpty {
                    warning("person.2", "Also used by \(sharedNames.formatted(.list(type: .and)))")
                }
                if item.containsProtectedItem {
                    warning("lock", "Contains protected files, such as keys, so it can't be removed.")
                }
                if item.handling == .revealOnly {
                    warning("lock.shield", "Outside your home folder. Needs an administrator, so it is only shown.")
                }
            }

            Spacer(minLength: 12)
            SizeText(bytes: item.reclaimableSize)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            } label: {
                Text("Show in Finder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            } label: {
                Text("Copy Path")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func warning(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }
}

/// One piece of evidence: a plain explanation plus the identifier or name it rests on.
struct EvidenceText: View {
    let evidence: Evidence

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text(verbatim: value)
                .monospaced()
                .environment(\.layoutDirection, .leftToRight)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private var title: LocalizedStringResource {
        switch evidence {
        case .exactBundleIdentifierPath: "Named after the identifier"
        case .containerMetadata: "Container registered to"
        case .associatedBundleIdentifier: "Launch item declares"
        case .programInsideBundle: "Runs a program inside the app:"
        case .applicationGroup: "Shared app group"
        case .receipt: "Installed by package"
        case .exactName: "Folder named like the app:"
        case .nameMatch: "Name contains the app's name:"
        }
    }

    private var value: String {
        switch evidence {
        case .exactBundleIdentifierPath(let value), .containerMetadata(let value),
            .associatedBundleIdentifier(let value), .programInsideBundle(let value), .applicationGroup(let value),
            .receipt(let value), .exactName(let value), .nameMatch(let value):
            value
        }
    }
}

extension OwnedItem.Confidence {
    var title: LocalizedStringResource {
        switch self {
        case .certain: "Certain"
        case .likely: "Likely"
        case .possible: "Possible"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .certain: "Found through the app's identifier or system records."
        case .likely:
            "Found through the app's group or its exact name. Selected only when no other app may use it."
        case .possible: "The name looks related. Never selected automatically, so check before removing."
        }
    }
}

extension OwnedItem.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .caches: "Cache"
        case .applicationSupport: "Application Support"
        case .httpStorage, .webKit, .cookies: "Web Data"
        case .logs: "Logs"
        case .applicationScripts: "App Scripts"
        case .preferences: "Preferences"
        case .savedState: "Saved Window State"
        case .container: "Sandbox Container"
        case .groupContainer: "Group Container"
        case .launchAgent: "Launch Agent"
        case .systemFile: "System File"
        }
    }
}
