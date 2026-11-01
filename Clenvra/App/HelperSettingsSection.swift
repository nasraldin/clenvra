import ClenvraKit
import ServiceManagement
import SwiftUI

/// Installs and removes the optional administrator helper. Off by default; Clenvra works fully without it and shows
/// system items in Finder instead.
struct HelperSettingsSection: View {
    /// Tells the rest of the app the helper's state changed.
    var onChange: () async -> Void = {}
    @State private var status = SMAppService.Status.notRegistered
    @State private var connection: ConnectionState = .unknown
    @State private var isWorking = false
    @State private var failure: LocalizedStringResource?

    private enum ConnectionState: Equatable {
        case unknown
        case connected(version: Int)
        case unavailable
    }

    private var service: SMAppService { SMAppService.daemon(plistName: HelperIdentity.daemonPlistName) }

    var body: some View {
        Section {
            LabeledContent {
                actions
            } label: {
                Label {
                    Text(statusTitle)
                } icon: {
                    Image(systemName: status == .enabled ? "checkmark.shield" : "shield")
                        .foregroundStyle(status == .enabled ? .green : .secondary)
                }
            }
            if case .connected(let version) = connection, version != HelperIdentity.protocolVersion {
                Text("The installed helper is from another version of Clenvra. Remove it and install it again.")
                    .foregroundStyle(.orange)
            }
            if connection == .unavailable, status == .enabled {
                Text(
                    "The helper is installed but did not answer. Remove it and install it again, or use Update Helper on Overview."
                )
                .foregroundStyle(.orange)
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        } header: {
            Text("System Helper")
        } footer: {
            Text(
                "Optional. Lets Clenvra clean system caches and logs, and remove leftovers outside your home folder. It runs only while working, acts only on a short list of system folders, checks every item again itself, and moves items to your Trash. macOS asks for your approval."
            )
            .foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            switch status {
            case .enabled:
                Button {
                    Task { await checkConnection() }
                } label: {
                    Text("Check")
                }
                Button(role: .destructive) {
                    Task { await uninstall() }
                } label: {
                    Text("Remove")
                }
                .accessibilityIdentifier("settings.helper.remove")
            case .requiresApproval:
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text("Approve in System Settings…")
                }
                Button(role: .destructive) {
                    Task { await uninstall() }
                } label: {
                    Text("Remove")
                }
            default:
                Button {
                    install()
                } label: {
                    Text("Install…")
                }
                .accessibilityIdentifier("settings.helper.install")
            }
        }
        .disabled(isWorking)
    }

    private var statusTitle: LocalizedStringResource {
        switch status {
        case .enabled: "Helper is installed"
        case .requiresApproval: "Helper is waiting for your approval"
        case .notFound: "Helper is missing from this copy of Clenvra"
        default: "Helper is not installed"
        }
    }

    private func refresh() async {
        status = service.status
        if status == .enabled { await checkConnection() }
        await onChange()
    }

    private func checkConnection() async {
        do {
            connection = .connected(version: try await HelperClient().protocolVersion())
        } catch {
            connection = .unavailable
        }
        await onChange()
    }

    private func install() {
        failure = nil
        do {
            try service.register()
        } catch {
            // Registering returns "requires approval" as an error the first time; the status says what to do next.
            if service.status != .requiresApproval {
                failure = "macOS did not install the helper. Make sure Clenvra is in the Applications folder."
            }
        }
        status = service.status
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        Task { await refresh() }
    }

    private func uninstall() async {
        isWorking = true
        defer { isWorking = false }
        failure = nil
        do {
            try await service.unregister()
        } catch {
            failure = "macOS did not remove the helper."
        }
        status = service.status
        connection = .unknown
        await onChange()
    }
}
