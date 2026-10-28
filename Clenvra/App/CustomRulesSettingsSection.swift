import AppKit
import ClenvraKit
import SwiftUI

/// The user's own cleanup locations (SA-8). They are review-only: never pre-selected, and every safety check still
/// applies, so a custom rule can never make Clenvra remove something it otherwise would not.
struct CustomRulesSettingsSection: View {
    let environment: AppEnvironment

    @State private var draftFolder: String?
    @State private var draftPattern = "*"
    @State private var draftDays = 30
    @State private var failure: LocalizedStringResource?

    var body: some View {
        Section {
            ForEach(environment.settings.customRules) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        PathText(path: rule.folder)
                        Text("\(rule.namePattern) · older than \(Int(rule.minimumAge.seconds / 86_400)) days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        remove(rule)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove Rule"))
                }
            }
            if let folder = draftFolder {
                VStack(alignment: .leading, spacing: 8) {
                    PathText(path: folder)
                    TextField(text: $draftPattern) {
                        Text("File names, for example *.log")
                    }
                    Stepper(value: $draftDays, in: 0...3_650) {
                        Text("Older than \(draftDays) days")
                    }
                    HStack {
                        Button {
                            draftFolder = nil
                        } label: {
                            Text("Cancel")
                        }
                        Button {
                            add(folder: folder)
                        } label: {
                            Text("Add Rule")
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                Button {
                    chooseFolder()
                } label: {
                    Text("Add Folder…")
                }
                .accessibilityIdentifier("settings.customRules.add")
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        } header: {
            Text("Your Cleanup Rules")
        } footer: {
            Text(
                "Matching files appear in Cleanup under Your Rules for you to review. They are never selected for you, and protected folders cannot be added."
            )
            .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        failure = nil
        draftFolder = url.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private func add(folder: String) {
        do {
            let rule = try CustomCleanupRule(
                folder: folder, minimumAge: .days(draftDays), namePattern: draftPattern, home: environment.home,
                policy: environment.policy)
            var settings = environment.settings
            settings.customRules.append(rule)
            try environment.apply(settings)
            draftFolder = nil
            draftPattern = "*"
        } catch let error as CustomCleanupRule.ValidationError {
            failure =
                switch error {
                case .protected: "Clenvra protects this folder, so it cannot be a cleanup rule."
                case .invalidFolder: "This folder cannot be used."
                case .invalidMinimumAge: "Choose a valid age."
                case .invalidNamePattern: "Enter a file name pattern without slashes, for example *.log."
                }
        } catch {
            failure = "The rule could not be saved."
        }
    }

    private func remove(_ rule: CustomCleanupRule) {
        var settings = environment.settings
        settings.customRules.removeAll { $0.id == rule.id }
        try? environment.apply(settings)
    }
}
