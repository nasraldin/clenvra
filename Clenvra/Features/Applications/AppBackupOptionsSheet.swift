import ClenvraKit
import SwiftUI

/// Backs up apps without removing anything: the whole app (to keep its state, for example before an upgrade) or
/// only its settings.
struct AppBackupOptionsSheet: View {
    let session: AppsSession
    let apps: [InstalledApp]
    let folder: URL
    let showBackups: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope = AppBackup.Scope.wholeApp
    @State private var isWorking = false
    @State private var run: AppsSession.BackupRun?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Back up \(apps.count) apps")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "externaldrive.badge.plus")
                    .foregroundStyle(.secondary)
            }
            List(apps) { app in
                HStack(spacing: 8) {
                    AppIcon(path: app.id, size: 20)
                    Text(verbatim: app.name)
                        .lineLimit(1)
                    if let version = app.version {
                        Text(verbatim: version)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 200)
            .accessibilityIdentifier("applications.backup.apps")
            Picker(selection: $scope) {
                Text("Whole app").tag(AppBackup.Scope.wholeApp)
                Text("Settings only").tag(AppBackup.Scope.settingsOnly)
            } label: {
                Text("Back up")
            }
            .pickerStyle(.radioGroup)
            .disabled(isWorking || run != nil)
            Text(scopeExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PathText(path: folder.path(percentEncoded: false))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let run {
                outcome(run)
            }
            HStack {
                if run != nil {
                    Button(action: showBackups) {
                        Text("Show Backups")
                    }
                }
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                if run == nil {
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Text("Cancel")
                    }
                    .keyboardShortcut(.cancelAction)
                    Button {
                        backUp()
                    } label: {
                        Text("Back Up")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apps.isEmpty || isWorking || session.isWorking)
                } else {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var scopeExplanation: LocalizedStringResource {
        switch scope {
        case .wholeApp:
            "The app and every file it owns, so you can go back to this exact state later, for example after an upgrade."
        case .settingsOnly:
            "Only the app's settings and data: preferences, Application Support, containers, saved state and cookies. Not the app itself, its caches or logs."
        }
    }

    @ViewBuilder private func outcome(_ run: AppsSession.BackupRun) -> some View {
        Text("\(run.made.count) backups were made.")
            .font(.headline)
        if !run.failed.isEmpty {
            List(Array(run.failed.enumerated()), id: \.offset) { _, failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: failure.name)
                    Text(verbatim: failure.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 60, maxHeight: 140)
        }
    }

    private func backUp() {
        isWorking = true
        Task {
            run = await session.backUp(apps, scope: scope, in: folder)
            isWorking = false
        }
    }
}
