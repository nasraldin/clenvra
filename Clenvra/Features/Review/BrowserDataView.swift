import AppKit
import ClenvraKit
import SwiftUI

/// Browser history, cookies, open tabs and site data (CL-7). Opened deliberately from the Cleanup toolbar because
/// it signs people out of websites: every data type of every profile is opt-in, and nothing is ever pre-selected.
struct BrowserDataSheet: View {
    let session: BrowserDataSession
    /// Whether a browser is open; read once per scan, off the main thread.
    let ownerState: @Sendable (String) -> OwnerState

    @State private var ownerStates: [Browser: OwnerState] = [:]
    @State private var isConfirming = false
    @State private var shownSummary: BrowserDataSummary?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 640)
        .sheet(isPresented: $isConfirming) {
            ConfirmBrowserDataSheet(
                groups: selectedGroups, count: session.selectedCount, bytes: session.selectedBytes
            ) {
                isConfirming = false
                Task { await clean() }
            }
        }
        .sheet(item: $shownSummary) { shown in
            CleanupResultSheet(summary: shown.summary, isPreview: false)
        }
        .task { await rescan() }
        .accessibilityIdentifier("browserData")
    }

    // MARK: - Layout

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Browser History & Cookies")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Choose exactly what to remove from each browser. Nothing is selected for you.")
                    .foregroundStyle(.secondary)
                Text("Removing cookies or site data signs you out of websites.")
                    .font(.callout.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        if browsers.isEmpty {
            if session.phase == .ready {
                ContentUnavailableView {
                    Label {
                        Text("No browser data found")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                } description: {
                    Text("No supported browser keeps history, cookies or site data on this Mac.")
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning…")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            List {
                ForEach(browsers, id: \.self) { browser in
                    Section {
                        BrowserNotes(
                            browser: browser, skipped: skipped(for: browser),
                            isBlocked: isBlocked(browser), ownerState: ownerStates[browser])
                        ForEach(profiles(of: browser)) { profile in
                            if showsProfileNames(of: browser) {
                                Text(verbatim: profile.profile.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(profile.groups) { group in
                                BrowserDataRow(group: group, session: session)
                            }
                        }
                    } header: {
                        Label {
                            Text(verbatim: browser.displayName)
                                .font(.headline)
                        } icon: {
                            Image(systemName: "globe")
                        }
                    }
                }
            }
            .disabled(session.phase != .ready)
            .accessibilityIdentifier("browserData.list")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                Task { await rescan() }
            } label: {
                Label {
                    Text("Rescan")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(session.phase != .ready)

            if session.phase == .cleaning {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…")
            } else if session.phase == .scanning {
                ProgressView().controlSize(.small)
                Text("Scanning…")
            } else {
                Text("\(session.selectedCount) items selected")
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text("Frees about \(session.selectedBytes.formatted(.byteCount(style: .file)))")
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
            }
            .keyboardShortcut(.cancelAction)

            Button(role: .destructive) {
                isConfirming = true
            } label: {
                Text("Move to Trash…")
            }
            .disabled(session.phase != .ready || session.selection.isEmpty)
            .accessibilityIdentifier("browserData.remove")
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Data

    /// Browsers that exist on this Mac: those with data, and those whose data could not be read.
    private var browsers: [Browser] {
        let found = Set(session.groups.map(\.browser)).union(
            session.skipped.compactMap { Browser(skippedPath: $0.path) })
        return Browser.allCases.filter(found.contains)
    }

    private func profiles(of browser: Browser) -> [ProfileGroups] {
        var result: [ProfileGroups] = []
        for group in session.groups where group.browser == browser {
            if let index = result.firstIndex(where: { $0.profile == group.profile }) {
                result[index].groups.append(group)
            } else {
                result.append(ProfileGroups(profile: group.profile, groups: [group]))
            }
        }
        return result.map { profile in
            var profile = profile
            profile.groups.sort { $0.dataType.order < $1.dataType.order }
            return profile
        }
    }

    private func showsProfileNames(of browser: Browser) -> Bool {
        let profiles = Set(session.groups.filter { $0.browser == browser }.map(\.profile))
        return profiles.count > 1 || profiles.contains { $0.name != browser.displayName }
    }

    private func skipped(for browser: Browser) -> [SkippedPath] {
        session.skipped.filter { Browser(skippedPath: $0.path) == browser }
    }

    /// The engine marks a browser's data as in use while it is open (or when Clenvra cannot tell).
    private func isBlocked(_ browser: Browser) -> Bool {
        session.groups.contains { group in
            group.browser == browser && group.items.contains { $0.status == .inUse }
        }
    }

    private var selectedGroups: [BrowserDataGroup] {
        session.groups.filter { group in group.items.contains { session.selection.contains($0.path) } }
    }

    // MARK: - Actions

    private func rescan() async {
        guard session.phase == .idle || session.phase == .ready else { return }
        clearSelection()
        await session.scan()
        // The engine keeps earlier choices that are still available; this screen never carries a choice over.
        clearSelection()
        await refreshOwnerStates()
    }

    private func clean() async {
        let summary = await session.clean()
        clearSelection()
        await refreshOwnerStates()
        shownSummary = BrowserDataSummary(summary: summary)
    }

    private func clearSelection() {
        for path in session.selection { session.toggle(path) }
    }

    private func refreshOwnerStates() async {
        let browsers = browsers
        let ownerState = ownerState
        ownerStates = await Task.detached {
            Dictionary(uniqueKeysWithValues: browsers.map { ($0, ownerState($0.bundleIdentifier)) })
        }.value
    }
}

private struct ProfileGroups: Identifiable {
    let profile: BrowserDataProfile
    var groups: [BrowserDataGroup]

    var id: String { profile.id }
}

private struct BrowserDataSummary: Identifiable {
    let id = UUID()
    let summary: CleanupSummary
}

/// Why a browser's rows are unavailable: it is open, or macOS kept some of its data from being read.
private struct BrowserNotes: View {
    let browser: Browser
    let skipped: [SkippedPath]
    let isBlocked: Bool
    let ownerState: OwnerState?

    var body: some View {
        if isBlocked {
            note(symbol: "app.badge.clock") {
                if ownerState == .unknown {
                    Text("Clenvra can't tell whether \(browser.displayName) is open, so its data is left alone.")
                } else {
                    Text("Quit \(browser.displayName) first")
                }
            }
        }
        if skipped.contains(where: { $0.reason == .permissionDenied }) {
            VStack(alignment: .leading, spacing: 6) {
                note(symbol: "lock") {
                    if browser == .safari {
                        Text("macOS protects Safari's data. Allow Full Disk Access for Clenvra, then rescan.")
                    } else {
                        Text("macOS did not allow access to some \(browser.displayName) data.")
                    }
                }
                if let url = FullDiskAccess.settingsURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("Open Privacy & Security")
                    }
                }
            }
        }
        if skipped.contains(where: { $0.reason == .excluded }) {
            note(symbol: "eye.slash") {
                Text("Some \(browser.displayName) data is in a folder you excluded in Settings.")
            }
        }
        if skipped.contains(where: { $0.reason != .permissionDenied && $0.reason != .excluded }) {
            note(symbol: "questionmark.folder") {
                Text("Some \(browser.displayName) files could not be read, so they are not listed.")
            }
        }
    }

    private func note(symbol: String, @ViewBuilder text: () -> some View) -> some View {
        Label {
            text()
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// One data type of one profile: its size, what removing it costs, and an opt-in checkbox.
private struct BrowserDataRow: View {
    let group: BrowserDataGroup
    let session: BrowserDataSession

    var body: some View {
        let available = group.items.filter { $0.status == .available }
        Toggle(
            isOn: Binding(
                get: { !available.isEmpty && available.allSatisfy { session.selection.contains($0.path) } },
                set: { session.setSelected($0, groupID: group.id) })
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: group.dataType.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.dataType.title)
                    Text(group.dataType.consequence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if group.dataType == .history && group.removesBookmarks {
                        Label {
                            Text(BrowserDataGroup.bookmarksWarning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout)
                    }
                    if available.isEmpty && !group.items.contains(where: { $0.status == .inUse }) {
                        Text("macOS does not allow removing this.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                SizeText(bytes: group.size)
                    .frame(minWidth: 80, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(available.isEmpty)
        .help(Text(verbatim: group.profile.path))
    }
}
