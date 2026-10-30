import AppKit
import ClenvraKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (⌘,): toolbar tabs with icons, one page per topic (F10). General and Menu Bar use the classic
/// two-column Mac layout (titles on the leading side, controls on the trailing side); list pages use grouped forms.
struct SettingsView: View {
    let environment: AppEnvironment

    private enum SettingsTab: String, Hashable {
        case general, schedule, menuBar, exclusions, customRules, helper
    }

    @AppStorage("settings.tab") private var tab = SettingsTab.general
    @State private var selectedExclusion: String?
    @State private var message: Message?
    @State private var fullDiskAccess = FullDiskAccess.Status.unknown
    @State private var isShowingGuide = false
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(ToolbarLabel.showsTitlesKey) private var toolbarShowsTitles = false

    private enum Message {
        case text(LocalizedStringResource)
        case importedSkipping(Int)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: SettingsTab.general) {
                general
            } label: {
                Label {
                    Text("General")
                } icon: {
                    Image(systemName: "gearshape")
                }
            }
            Tab(value: SettingsTab.schedule) {
                page { ScheduleSettingsSection(environment: environment) }
            } label: {
                Label {
                    Text("Schedule")
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                }
            }
            Tab(value: SettingsTab.menuBar) {
                menuBar
            } label: {
                Label {
                    Text("Menu Bar")
                } icon: {
                    Image(systemName: "menubar.rectangle")
                }
            }
            Tab(value: SettingsTab.exclusions) {
                page { exclusions }
            } label: {
                Label {
                    Text("Exclusions")
                } icon: {
                    Image(systemName: "nosign")
                }
            }
            Tab(value: SettingsTab.customRules) {
                page { CustomRulesSettingsSection(environment: environment) }
            } label: {
                Label {
                    Text("Custom Rules")
                } icon: {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            Tab(value: SettingsTab.helper) {
                page { HelperSettingsSection(onChange: { await environment.refreshHelper() }) }
            } label: {
                Label {
                    Text("System Helper")
                } icon: {
                    Image(systemName: "lock.shield")
                }
            }
        }
        .frame(width: 620)
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

    /// A grouped page for list-like settings, sized to its content.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(minHeight: 360, idealHeight: 460)
    }

    // MARK: - General

    private var general: some View {
        Form {
            LabeledContent {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(fullDiskAccessTitle)
                    } icon: {
                        Image(systemName: fullDiskAccess == .granted ? "checkmark.shield" : "lock.shield")
                            .foregroundStyle(fullDiskAccess == .granted ? .green : .orange)
                    }
                    HStack {
                        if let url = FullDiskAccess.settingsURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Text("Open Privacy Settings…")
                            }
                            .accessibilityIdentifier("settings.fullDiskAccess")
                        }
                        Button {
                            isShowingGuide = true
                        } label: {
                            Text("About Permission Prompts…")
                        }
                        .accessibilityIdentifier("settings.permissionsGuide")
                    }
                    note(
                        "Lets scans include protected folders such as Safari and Mail data. Clenvra only reads them; nothing is deleted without your review."
                    )
                }
            } label: {
                Text("Full Disk Access:")
            }

            LabeledContent {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        isOn: Binding(
                            get: { environment.settings.checksForAppUpdates },
                            set: { newValue in update { $0.checksForAppUpdates = newValue } }
                        )
                    ) {
                        Text("Check for app updates")
                    }
                    .accessibilityIdentifier("settings.checksForAppUpdates")
                    note(
                        "When you check for updates in Applications, Clenvra contacts the apps' update feeds, Apple's App Store and Homebrew. Nothing is contacted while this is off, and nothing is downloaded or installed."
                    )
                }
            } label: {
                Text("App Updates:")
            }
            .padding(.top, 12)

            LabeledContent {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $toolbarShowsTitles) {
                        Text("Show names with icons")
                    }
                    .accessibilityIdentifier("settings.toolbarShowsTitles")
                    note("Toolbar buttons show only their icon. Point to a button to see its name.")
                }
            } label: {
                Text("Toolbar:")
            }
            .padding(.top, 12)

            LabeledContent {
                VStack(alignment: .leading, spacing: 8) {
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
                    note("Folders in your home folder are saved relative to it, so they work for any user name.")
                }
            } label: {
                Text("Your Settings:")
            }
            .padding(.top, 12)
        }
        .formStyle(.columns)
        .padding(28)
    }

    // MARK: - Menu Bar

    private var menuBar: some View {
        Form {
            LabeledContent {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Bindable(environment).showsMenuBarExtra) {
                        Text("Show Clenvra in the menu bar")
                    }
                    note("Free space and the last scan at a glance. Cleaning always happens in the main window.")
                }
            } label: {
                Text("Menu Bar:")
            }

            LabeledContent {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $opensAtLogin) {
                        Text("Open Clenvra at login")
                    }
                    .onChange(of: opensAtLogin) { _, enabled in setOpensAtLogin(enabled) }
                    note("Useful with scheduled scans, which run only while Clenvra is open.")
                }
            } label: {
                Text("Login:")
            }
            .padding(.top, 12)
        }
        .formStyle(.columns)
        .padding(28)
    }

    // MARK: - Exclusions

    @ViewBuilder private var exclusions: some View {
        Section {
            List(environment.settings.exclusions, id: \.self, selection: $selectedExclusion) { path in
                Label {
                    PathText(path: path)
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
            }
            .frame(minHeight: 200)
            .overlay {
                if environment.settings.exclusions.isEmpty {
                    Text("No excluded folders").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Button {
                    addExclusion()
                } label: {
                    Label {
                        Text("Add Folder…")
                    } icon: {
                        Image(systemName: "plus")
                    }
                    .labelStyle(.iconOnly)
                }
                .help(Text("Add a folder Clenvra never touches"))
                Button {
                    removeSelected()
                } label: {
                    Label {
                        Text("Remove")
                    } icon: {
                        Image(systemName: "minus")
                    }
                    .labelStyle(.iconOnly)
                }
                .help(Text("Remove the selected folder from the list"))
                .disabled(selectedExclusion == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Folders Clenvra Never Touches")
        } footer: {
            Text(
                "Clenvra never lists or removes anything inside these folders. Changes apply immediately. You can also exclude an item from any scan result with its right-click menu."
            )
            .font(.callout)
        }
    }

    private func note(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380, alignment: .leading)
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = .text(
                "macOS did not allow this change. You can manage it in System Settings › General › Login Items.")
            opensAtLogin = SMAppService.mainApp.status == .enabled
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
