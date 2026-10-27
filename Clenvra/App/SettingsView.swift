import AppKit
import ClenvraKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings window: folders Clenvra must never touch, and moving settings between Macs.
struct SettingsView: View {
    let environment: AppEnvironment

    @State private var selectedExclusion: String?
    @State private var message: Message?
    @State private var fullDiskAccess = FullDiskAccess.Status.unknown
    @State private var isShowingGuide = false

    private enum Message {
        case text(LocalizedStringResource)
        case importedSkipping(Int)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if let url = FullDiskAccess.settingsURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Text("Open Settings…")
                        }
                        .accessibilityIdentifier("settings.fullDiskAccess")
                    }
                } label: {
                    Label {
                        Text(fullDiskAccessTitle)
                    } icon: {
                        Image(systemName: fullDiskAccess == .granted ? "checkmark.shield" : "lock.shield")
                            .foregroundStyle(fullDiskAccess == .granted ? .green : .orange)
                    }
                }
                Button {
                    isShowingGuide = true
                } label: {
                    Text("About macOS Permission Prompts…")
                }
                .accessibilityIdentifier("settings.permissionsGuide")
            } header: {
                Text("Full Disk Access")
            } footer: {
                Text(
                    "Lets scans include protected folders such as Safari and Mail data. Clenvra only reads them; nothing is deleted without your review."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                List(environment.settings.exclusions, id: \.self, selection: $selectedExclusion) { path in
                    PathText(path: path)
                }
                .frame(minHeight: 160)
                .overlay {
                    if environment.settings.exclusions.isEmpty {
                        Text("No excluded folders").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        addExclusion()
                    } label: {
                        Label {
                            Text("Add Folder…")
                        } icon: {
                            Image(systemName: "plus")
                        }
                    }
                    Button {
                        removeSelected()
                    } label: {
                        Label {
                            Text("Remove")
                        } icon: {
                            Image(systemName: "minus")
                        }
                    }
                    .disabled(selectedExclusion == nil)
                }
            } header: {
                Text("Excluded Folders")
            } footer: {
                Text("Clenvra never lists or removes anything inside these folders. Changes apply immediately.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button {
                        exportSettings()
                    } label: {
                        Text("Export…")
                    }
                    Button {
                        importSettings()
                    } label: {
                        Text("Import…")
                    }
                }
            } header: {
                Text("Use on Another Mac")
            } footer: {
                Text("Folders in your home folder are saved relative to it, so they work for any user name.")
                    .foregroundStyle(.secondary)
            }

            HelperSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .task { await refreshFullDiskAccess() }
        .sheet(isPresented: $isShowingGuide) { PermissionsGuideView(home: environment.home) }
        // The user may grant access in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshFullDiskAccess() }
        }
        .alert(
            Text("Settings"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button {
                message = nil
            } label: {
                Text("OK")
            }
        } message: {
            switch message {
            case .text(let text): Text(text)
            case .importedSkipping(let count): Text("Settings imported. \(count) invalid entries were skipped.")
            case nil: EmptyView()
            }
        }
    }

    private var fullDiskAccessTitle: LocalizedStringResource {
        switch fullDiskAccess {
        case .granted: "Full Disk Access is on"
        case .notGranted: "Full Disk Access is off"
        case .unknown: "Full Disk Access status is unknown"
        }
    }

    private func refreshFullDiskAccess() async {
        fullDiskAccess = await FullDiskAccess.currentStatus(home: environment.home)
    }

    private func update(_ change: (inout UserSettings) -> Void) {
        var settings = environment.settings
        change(&settings)
        do {
            try environment.apply(settings)
        } catch {
            message = .text("The settings could not be saved.")
        }
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { Self.canonical($0.path(percentEncoded: false)) }
        update { settings in
            for path in paths where !settings.exclusions.contains(path) { settings.exclusions.append(path) }
        }
    }

    private func removeSelected() {
        guard let selectedExclusion else { return }
        update { $0.exclusions.removeAll { $0 == selectedExclusion } }
        self.selectedExclusion = nil
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Clenvra Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try environment.settingsStore.export(environment.settings).write(to: url, options: .atomic)
        } catch {
            message = .text("The settings could not be exported.")
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try environment.settingsStore.importSettings(from: Data(contentsOf: url))
            try environment.apply(result.settings)
            let skipped = result.rejectedEntries.count
            message = skipped == 0 ? .text("Settings imported.") : .importedSkipping(skipped)
        } catch SettingsStore.ImportError.unsupportedVersion {
            message = .text("This file was made by a newer version of Clenvra.")
        } catch {
            message = .text("This file is not a Clenvra settings file.")
        }
    }

    /// Exclusions are compared with canonical scan paths, so symlinked folders are resolved first.
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
