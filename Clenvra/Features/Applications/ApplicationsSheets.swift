import ClenvraKit
import SwiftUI

/// Confirmation before moving an app and its files to the Trash.
struct ConfirmUninstallSheet: View {
    let appName: String
    let count: Int
    let bytes: Int64
    let hasRevealOnlyItems: Bool
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Move \(appName) to the Trash?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            Text("The app and \(count - 1) of its items will be moved to the Trash.")
            Text("This frees about \(bytes.formatted(.byteCount(style: .file))).")
            if hasRevealOnlyItems {
                Text("Files outside your home folder are not removed.")
                    .foregroundStyle(.secondary)
            }
            Text("Every item is checked again just before it is moved. You can put items back from Activity.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: confirm) {
                    Text("Move to Trash")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Confirmation before removing every checked app: lists exactly the apps that will be removed, including ones the
/// current search or filter hides, with the backup choice.
struct ConfirmBatchUninstallSheet: View {
    let session: AppsSession
    let backupFolder: URL
    @Binding var backsUp: Bool
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var apps: [InstalledApp] { session.checkedApps }

    private var knownBytes: Int64 { apps.compactMap { session.size(of: $0) }.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Move \(apps.count) apps to the Trash?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            Text(
                "Each app and the files it owns that are selected by default will be moved to the Trash. Together the apps use about \(knownBytes.formatted(.byteCount(style: .file)))."
            )
            .fixedSize(horizontal: false, vertical: true)
            List(apps) { app in
                HStack(spacing: 8) {
                    AppIcon(path: app.id, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: app.name)
                            .lineLimit(1)
                        if let version = app.version {
                            Text(verbatim: version)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let size = session.size(of: app) {
                        SizeText(bytes: size)
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 240)
            .accessibilityIdentifier("applications.batch.apps")
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $backsUp) {
                    Text("Back up before removing")
                }
                .accessibilityIdentifier("applications.batch.backup")
                PathText(path: backupFolder.path(percentEncoded: false))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(
                    "If an app's backup fails, that app is kept. You can choose the folder in Settings › Applications."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "Apps that are open, protected or changed are skipped. Every item is checked again just before it is moved. You can put items back from Activity."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: confirm) {
                    Text("Move to Trash")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apps.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task {
            for app in apps where session.size(of: app) == nil { await session.measure(app) }
        }
    }
}

/// A batch removal's result, for `sheet(item:)`.
struct ShownBatchResult: Identifiable {
    let id = UUID()
    let result: AppsSession.BatchUninstallResult
}

/// Which apps were removed, which were kept and why, and the way to the backups.
struct BatchUninstallResultSheet: View {
    let result: AppsSession.BatchUninstallResult
    /// Uninstall deleted the apps for good; otherwise they were moved to the Trash.
    var isPermanent = false
    let showBackups: () -> Void

    @Environment(\.dismiss) private var dismiss

    private struct Line: Identifiable {
        let id: Int
        let name: String
        let reason: AppsSession.SkipReason?
    }

    private var lines: [Line] {
        let removed = result.removed.map { (name: $0, reason: AppsSession.SkipReason?.none) }
        let skipped = result.skipped.map { (name: $0.name, reason: Optional($0.reason)) }
        return (removed + skipped).enumerated().map {
            Line(id: $0.offset, name: $0.element.name, reason: $0.element.reason)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isPermanent {
                Text("Uninstalled \(result.removed.count) apps")
                    .font(.title3.bold())
            } else {
                Text("Removed \(result.removed.count) apps")
                    .font(.title3.bold())
            }
            if result.summary.removedPermanentlyCount > 0 {
                Text(
                    "\(result.summary.removedPermanentlyCount) items were deleted for good, freeing about \(result.summary.freedBytes.formatted(.byteCount(style: .file)))."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if result.summary.movedToTrashCount > 0 {
                Text(
                    "About \(result.summary.freedBytes.formatted(.byteCount(style: .file))) is now in the Trash. Empty the Trash to free that space; until then you can put items back."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !result.backups.isEmpty {
                Text("\(result.backups.count) backups were made.")
            }
            if !result.receiptsKept.isEmpty {
                Text(
                    "The app is gone, but these installer records stay (no helper or no password): \(result.receiptsKept.joined(separator: ", "))"
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            List(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.reason == nil ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(line.reason == nil ? .green : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: line.name)
                        if let reason = line.reason {
                            Text(reason.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if isPermanent {
                            Text("Deleted for good")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Moved to the Trash")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 220)
            .accessibilityIdentifier("review.results")
            if !result.summary.problems.isEmpty {
                Text("\(result.summary.problems.count) items were skipped")
                    .font(.headline)
                List(result.summary.problems, id: \.path) { problem in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.reason.explanation)
                        PathText(path: problem.path)
                    }
                }
                .frame(minHeight: 80, maxHeight: 160)
            }
            HStack {
                Button(action: showBackups) {
                    Text("Show Backups")
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

extension AppsSession.SkipReason {
    /// Plain-language reason an app was kept.
    var explanation: LocalizedStringResource {
        switch self {
        case .running: "Kept: it is open. Quit it and try again."
        case .protected: "Kept: it is part of macOS or Clenvra, or a security or management tool."
        case .changed: "Kept: it changed or moved after you checked it."
        case .backupFailed(let reason): "Kept: its backup failed (\(reason))."
        case .homebrewFailed(let reason): "Kept: Homebrew could not remove it (\(reason))."
        }
    }
}

/// Confirmation before uninstalling apps completely: lists, per app, everything that will be deleted for good and
/// how (Homebrew apps through `brew`), what stays and why, with "Back up first" on by default.
struct ConfirmCompleteUninstallSheet: View {
    let session: AppsSession
    let apps: [InstalledApp]
    let backupFolder: URL
    /// Called with the backup scope (`nil` = no backup) and the plans shown, so nothing else is touched.
    let confirm: (AppBackup.Scope?, [AppsSession.UninstallPlan]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plans: [AppsSession.UninstallPlan]?
    @State private var backsUp = true
    @State private var scope = AppBackup.Scope.wholeApp

    private var removable: [AppsSession.UninstallPlan] { (plans ?? []).filter { $0.skip == nil } }
    private var bytes: Int64 { removable.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Uninstall \(apps.count) apps completely?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "xmark.bin")
                    .foregroundStyle(.red)
            }
            Text(
                "Each app and everything listed below are deleted for good, as if the app had never been installed. They do not go to the Trash and can't be put back, except from a backup."
            )
            .fixedSize(horizontal: false, vertical: true)
            if let plans {
                List {
                    ForEach(plans) { plan in
                        Section {
                            planRows(plan)
                        } header: {
                            HStack(spacing: 6) {
                                AppIcon(path: plan.app.id, size: 16)
                                Text(verbatim: plan.app.name)
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 320)
                .accessibilityIdentifier("applications.uninstall.plan")
                Text("Together this frees about \(bytes.formatted(.byteCount(style: .file))).")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView {
                    Text("Finding everything the apps installed…")
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $backsUp) {
                    Text("Back up first")
                }
                .accessibilityIdentifier("applications.uninstall.backup")
                Picker(selection: $scope) {
                    Text("Whole app").tag(AppBackup.Scope.wholeApp)
                    Text("Settings only").tag(AppBackup.Scope.settingsOnly)
                } label: {
                    Text("Back up")
                }
                .pickerStyle(.radioGroup)
                .disabled(!backsUp)
                PathText(path: backupFolder.path(percentEncoded: false))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("If an app's backup fails, that app is kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    confirm(backsUp ? scope : nil, plans ?? [])
                } label: {
                    Text("Uninstall Permanently")
                }
                .disabled(removable.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { plans = await session.uninstallPlans(for: apps) }
    }

    @ViewBuilder private func planRows(_ plan: AppsSession.UninstallPlan) -> some View {
        if let skip = plan.skip {
            Text(skip.explanation)
                .foregroundStyle(.secondary)
        } else {
            if let line = plan.source.uninstallLine {
                Label {
                    Text(line)
                } icon: {
                    Image(systemName: "terminal")
                }
                .font(.callout)
            }
            HStack {
                PathText(path: plan.app.id)
                Spacer()
                if let bundle = plan.bundle { SizeText(bytes: bundle.reclaimableSize) }
            }
            ForEach(plan.items) { item in
                HStack {
                    PathText(path: item.path)
                    if session.needsHelper(item) {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                            .help(Text("Needs your administrator password"))
                    }
                    Spacer()
                    SizeText(bytes: item.reclaimableSize)
                }
            }
            if !plan.kept.isEmpty {
                Text("\(plan.kept.count) items stay: they are shared with another app, protected, or need the helper.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension InstallSource {
    /// How Uninstall removes an app installed this way, when it is more than deleting files.
    var uninstallLine: LocalizedStringResource? {
        switch self {
        case .homebrewCask(let token): "Homebrew cask \(token): removed with “brew uninstall --cask --zap” first."
        case .homebrewFormula(let name): "Homebrew formula \(name): removed with “brew uninstall” first."
        case .appStore: "From the App Store. You can download it again from your purchases."
        case .package(let ids):
            "Installed by a package (\(ids.joined(separator: ", "))). Its installer record is removed too; macOS asks for an administrator’s password."
        case .direct: nil
        }
    }
}

/// Confirmation before running `brew uninstall`, which bypasses the Trash.
struct ConfirmHomebrewSheet: View {
    let appName: String
    let command: Command
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Uninstall \(appName) with Homebrew?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
            }
            Text("Clenvra will run this command:")
            CommandText(command: command)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 6))
            Text("Homebrew removes the app permanently. It does not go to the Trash and can't be put back.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(role: .destructive, action: confirm) {
                    Text("Run Command")
                }
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// What `brew` printed and whether it succeeded.
struct HomebrewResultSheet: View {
    let result: CommandResult
    let output: [String]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if result.terminationReason == .exited && result.exitStatus == 0 {
                Text("Homebrew removed the app")
                    .font(.title3.bold())
            } else {
                Text("Homebrew could not remove the app")
                    .font(.title3.bold())
                Text("Nothing else was changed. The output below explains what went wrong.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(verbatim: output.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .accessibilityIdentifier("review.results")
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Shown when an uninstall was not started because the app became unavailable after review.
struct NotUninstalledSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing was removed")
                .font(.title3.bold())
            Text("The app is open, or it changed after you reviewed it. Quit it and try again.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
