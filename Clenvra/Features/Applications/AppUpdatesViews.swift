import AppKit
import ClenvraKit
import SwiftUI

/// Starts an update check. Disabled while the setting is off, because checking contacts the network (D5).
struct CheckForUpdatesButton: View {
    let session: AppsSession
    let updates: UpdateCheckSession
    let isEnabled: Bool

    var body: some View {
        Button {
            Task { await updates.check(session.apps, homebrewToken: session.homebrewToken(for:)) }
        } label: {
            ToolbarLabel(title: "Check for Updates", symbol: "arrow.down.app")
        }
        .disabled(!isEnabled || isChecking || session.apps.isEmpty)
        .help(isEnabled ? Text("Check for Updates") : Text("Turn on update checks in Settings"))
        .accessibilityIdentifier("applications.checkForUpdates")
    }

    private var isChecking: Bool {
        if case .checking = updates.phase { true } else { false }
    }
}

/// Progress of a running check, or how many updates the last one found.
struct UpdateCheckProgress: View {
    let updates: UpdateCheckSession

    var body: some View {
        switch updates.phase {
        case .idle:
            EmptyView()
        case .checking(let completed, let total):
            ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                Text("Checking \(completed) of \(total) apps for updates…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            HStack {
                Text("\(updates.availableUpdates.count) updates available")
                if let lastChecked = updates.lastChecked {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text("Checked \(lastChecked, format: .relative(presentation: .named))")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .disabled:
            HStack {
                Text("Update checks are off. Nothing was contacted.")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// "Update available 2.4" next to an app in the list.
struct UpdateBadge: View {
    let version: String

    var body: some View {
        Label {
            Text("Update available \(Self.isolated(version))")
        } icon: {
            Image(systemName: "arrow.down.circle")
        }
        .font(.caption)
        .foregroundStyle(Color.accentColor)
    }

    /// Versions stay left-to-right inside Arabic sentences.
    static func isolated(_ version: String) -> String { "\u{2066}\(version)\u{2069}" }
}

/// The update check's answer for the selected app, and how to update from its source. Clenvra never updates
/// anything itself.
struct UpdateNotice: View {
    let update: AppUpdate

    var body: some View {
        switch update.status {
        case .available(let version):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Update available \(UpdateBadge.isolated(version))")
                        .font(.headline)
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Color.accentColor)
                }
                action
            }
        case .upToDate:
            Label {
                Text("This app is up to date.")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .foregroundStyle(.secondary)
        case .unknown(let reason):
            Label {
                Text(reason.explanation)
            } icon: {
                Image(systemName: "questionmark.circle")
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var action: some View {
        switch update.source {
        case .appStore:
            HStack {
                Text("Update it from the App Store.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
                } label: {
                    Text("Open App Store")
                }
            }
        case .homebrew(let token):
            let command = "brew upgrade --cask \(token)"
            VStack(alignment: .leading, spacing: 6) {
                Text("Installed with Homebrew. Run this command in Terminal to update it:")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(verbatim: command)
                        .font(.callout.monospaced())
                        .environment(\.layoutDirection, .leftToRight)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Label {
                            Text("Copy Command")
                        } icon: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            }
        case .sparkle:
            HStack {
                Text("Open the app and choose Check for Updates from its menu.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.openApplication(
                        at: URL(filePath: update.id), configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    Text("Open App")
                }
            }
        case nil:
            EmptyView()
        }
    }
}

extension AppUpdate.UnknownReason {
    var explanation: LocalizedStringResource {
        switch self {
        case .noUpdateSource: "Clenvra can't check this app for updates. It has no update feed Clenvra can read."
        case .insecureFeed: "This app's update feed doesn't use a secure connection, so Clenvra didn't contact it."
        case .requestFailed: "The update check for this app didn't finish. Check your connection and try again."
        case .unreadableResponse: "The update source answered in a way Clenvra doesn't understand."
        case .unreadableVersion: "Clenvra couldn't read this app's version."
        }
    }
}
