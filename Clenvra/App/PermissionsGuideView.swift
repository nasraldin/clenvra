import AppKit
import ClenvraKit
import SwiftUI

/// Explains the macOS permission prompts before the first scan triggers them, so they are expected, not alarming.
/// Shown once at first launch, and again from Settings.
struct PermissionsGuideView: View {
    /// UserDefaults key; UI tests pass `-clenvra.permissionsGuideSeen YES` to skip the guide.
    static let seenKey = "clenvra.permissionsGuideSeen"

    let home: String

    @Environment(\.dismiss) private var dismiss
    @State private var fullDiskAccess = FullDiskAccess.Status.unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Before you start")
                    .font(.title2.bold())
                Text("macOS asks before an app can look at some of your files. Here is what you may see, and why.")
                    .foregroundStyle(.secondary)
            }

            point(symbol: "lock.shield", title: "Full Disk Access (recommended)") {
                Text(
                    "Lets scans include folders macOS protects, such as Safari, Mail and Messages data. Clenvra only reads them to measure space; nothing is removed without your review."
                )
                HStack(spacing: 10) {
                    statusLabel
                    if fullDiskAccess != .granted, let url = FullDiskAccess.settingsURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Text("Open Privacy & Security…")
                        }
                        .accessibilityIdentifier("guide.openSettings")
                    }
                }
            }

            point(symbol: "folder.badge.questionmark", title: "Folder prompts") {
                Text(
                    "Without Full Disk Access, macOS asks separately for Desktop, Documents, Downloads and external disks the first time a scan reaches them. If you decline, Clenvra skips those folders and says so."
                )
            }

            point(symbol: "app.badge.checkmark", title: "App Management") {
                Text(
                    "When you uninstall an app, macOS may ask whether Clenvra may change or delete other apps. Allow it only if you want Clenvra to remove apps."
                )
            }

            Text("Clenvra never asks for your password, never runs in the background, and sends nothing off your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Continue")
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("guide.continue")
            }
        }
        .padding(28)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissionsGuide")
        .task { await refresh() }
        // The user may grant access in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func point(
        symbol: String, title: LocalizedStringResource, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                content()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var statusLabel: some View {
        switch fullDiskAccess {
        case .granted:
            Label {
                Text("Full Disk Access is on")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .notGranted:
            Label {
                Text("Full Disk Access is off")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        case .unknown:
            EmptyView()
        }
    }

    private func refresh() async {
        fullDiskAccess = await FullDiskAccess.currentStatus(home: home)
    }
}
