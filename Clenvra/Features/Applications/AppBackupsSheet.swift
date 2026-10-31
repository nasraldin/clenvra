import AppKit
import ClenvraKit
import SwiftUI

/// The app backups in the backups folder, grouped by app, newest first. Choose one or more backups, choose which of
/// their items to put back, and restore them; or show them in Finder or move them to the Trash. Restoring never
/// overwrites: unless "Replace the current version" is on, anything already at an item's place is left alone;
/// with it on, the current copy is moved to the Trash first (it can be put back from Activity).
struct AppBackupsSheet: View {
    let session: AppsSession
    let folder: URL

    @Environment(\.dismiss) private var dismiss
    @State private var backups: [AppBackupInfo] = []
    @State private var hasLoaded = false
    @State private var selection: Set<AppBackupInfo.ID> = []
    /// Items the user unchecked, per backup; every item is checked by default.
    @State private var unchecked: [AppBackupInfo.ID: Set<String>] = [:]
    @State private var replacesExisting = false
    @State private var isWorking = false
    @State private var isConfirmingTrash = false
    @State private var restoreResults: ShownRestoreResults?
    @State private var trashFailed = false

    private var selected: [AppBackupInfo] { backups.filter { selection.contains($0.id) } }

    /// Backups grouped by app (bundle identifier, else name), each group newest first, groups by name.
    private var groups: [(key: String, name: String, backups: [AppBackupInfo])] {
        let grouped = Dictionary(grouping: backups) { $0.bundleID ?? $0.name }
        return grouped.map { key, value in
            (key: key, name: value.first?.name ?? key, backups: value.sorted { $0.created > $1.created })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chosenItems(of backup: AppBackupInfo) -> Set<String> {
        Set(backup.items.map(\.original)).subtracting(unchecked[backup.id] ?? [])
    }

    private var chosenCount: Int { selected.reduce(0) { $0 + chosenItems(of: $1).count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App Backups")
                .font(.title3.bold())
            PathText(path: folder.path(percentEncoded: false))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                list
                    .frame(minWidth: 300, minHeight: 260, maxHeight: 360)
                itemsChecklist
                    .frame(minWidth: 300, minHeight: 260, maxHeight: 360)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $replacesExisting) {
                    Text("Replace the current version")
                }
                .accessibilityIdentifier("applications.backups.replace")
                Text(
                    "When something is already at an item's place, it is moved to the Trash first and the backup's copy is put back. You can put the current copy back from Activity. When off, existing items are left alone."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    restore()
                } label: {
                    Text("Restore \(chosenCount) Items")
                }
                .help(Text("Put the checked items of the chosen backups back where they were"))
                .disabled(chosenCount == 0 || isWorking || session.isWorking)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.url))
                } label: {
                    Text("Show in Finder")
                }
                .disabled(selected.isEmpty)
                Button {
                    isConfirmingTrash = true
                } label: {
                    Text("Move Backups to Trash")
                }
                .disabled(selected.isEmpty || isWorking || session.isWorking)
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
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
        .frame(width: 720)
        .task { await reload() }
        .confirmationDialog(
            Text("Move \(selected.count) backups to the Trash?"), isPresented: $isConfirmingTrash
        ) {
            Button(role: .destructive) {
                trash(selected)
            } label: {
                Text("Move to Trash")
            }
        } message: {
            Text("These backups can no longer be restored once the Trash is emptied.")
        }
        .alert(Text("A backup could not be moved to the Trash."), isPresented: $trashFailed) {
            Button {
                trashFailed = false
            } label: {
                Text("OK")
            }
        }
        .sheet(item: $restoreResults) { shown in
            RestoreResultSheet(results: shown.results)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.backups) { backup in
                        BackupRow(backup: backup)
                            .tag(backup.id)
                    }
                } header: {
                    Text(verbatim: group.name)
                }
            }
        }
        .pageState(isShown: backups.isEmpty) {
            if hasLoaded {
                ContentUnavailableView {
                    Label {
                        Text("No backups")
                    } icon: {
                        Image(systemName: "archivebox")
                    }
                } description: {
                    Text("Back up apps with Back Up…, or before removing them; the backups appear here.")
                }
            } else {
                ProgressView()
            }
        }
        .accessibilityIdentifier("applications.backups.list")
    }

    private var itemsChecklist: some View {
        List {
            ForEach(selected) { backup in
                Section {
                    ForEach(backup.items, id: \.original) { item in
                        Toggle(isOn: itemBinding(backup, item.original)) {
                            HStack {
                                PathText(path: item.original)
                                Spacer()
                                SizeText(bytes: item.bytes)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    Text(backup.created, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                }
            }
        }
        .pageState(isShown: selected.isEmpty) {
            ContentUnavailableView {
                Label {
                    Text("Choose backups")
                } icon: {
                    Image(systemName: "checklist")
                }
            } description: {
                Text("Choose one or more backups to see what they hold and what to restore.")
            }
        }
        .accessibilityIdentifier("applications.backups.items")
    }

    private func itemBinding(_ backup: AppBackupInfo, _ path: String) -> Binding<Bool> {
        Binding(
            get: { !(unchecked[backup.id]?.contains(path) ?? false) },
            set: { isOn in
                var paths = unchecked[backup.id] ?? []
                if isOn { paths.remove(path) } else { paths.insert(path) }
                unchecked[backup.id] = paths
            })
    }

    private func reload() async {
        let folder = folder
        backups = await Task.detached { AppBackup.list(in: folder) }.value
        selection.formIntersection(backups.map(\.id))
        hasLoaded = true
    }

    private func restore() {
        let chosen = selected.filter { !chosenItems(of: $0).isEmpty }
        guard !chosen.isEmpty else { return }
        let items = Dictionary(uniqueKeysWithValues: chosen.map { ($0.url, chosenItems(of: $0)) })
        let replaces = replacesExisting
        isWorking = true
        Task {
            let results = await session.restore(chosen, items: items, replaceExisting: replaces)
            isWorking = false
            restoreResults = ShownRestoreResults(results: results)
        }
    }

    private func trash(_ chosen: [AppBackupInfo]) {
        Task {
            var failed = false
            for backup in chosen {
                let summary = await session.trashBackup(backup)
                if summary?.movedToTrashCount != 1 { failed = true }
            }
            trashFailed = failed
            await reload()
        }
    }
}

/// One backup: when, what it holds and its size.
private struct BackupRow: View {
    let backup: AppBackupInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: backup.scope == .wholeApp ? "archivebox" : "gearshape")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(backup.created, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SizeText(bytes: backup.archiveBytes)
        }
    }

    private var subtitle: String {
        let scope =
            backup.scope == .wholeApp ? String(localized: "Whole app") : String(localized: "Settings only")
        return [backup.version, scope].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct ShownRestoreResults: Identifiable {
    let id = UUID()
    let results: [AppsSession.RestoredBackup]
}

/// What each restore put back, the current copies it moved to the Trash, and every path it left alone with the
/// reason.
private struct RestoreResultSheet: View {
    let results: [AppsSession.RestoredBackup]

    @Environment(\.dismiss) private var dismiss

    private var restoredCount: Int { results.reduce(0) { $0 + $1.result.restored.count } }
    private var skipped: [String] { results.flatMap(\.result.skippedExisting) }
    private var movedToTrash: [String] { results.flatMap(\.result.movedToTrash) }
    private var notReplaced: [CleanupSummary.Problem] { results.flatMap(\.result.notReplaced) }
    private var failed: [RestoreResult.Failure] { results.flatMap(\.result.failed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restored \(restoredCount) items")
                .font(.title3.bold())
            if !movedToTrash.isEmpty {
                Text("\(movedToTrash.count) current items were moved to the Trash first")
                    .font(.headline)
                Text("You can put them back from Activity.")
                    .foregroundStyle(.secondary)
                List(movedToTrash, id: \.self) { path in
                    PathText(path: path)
                }
                .frame(minHeight: 60, maxHeight: 140)
            }
            if !skipped.isEmpty {
                Text("\(skipped.count) items were not restored because something is already there")
                    .font(.headline)
                Text("Nothing was replaced. Turn on “Replace the current version” to swap in the backup's copy.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(skipped, id: \.self) { path in
                    PathText(path: path)
                }
                .frame(minHeight: 60, maxHeight: 140)
            }
            if !notReplaced.isEmpty {
                Text("\(notReplaced.count) current items could not be moved to the Trash, so they were kept")
                    .font(.headline)
                List(notReplaced, id: \.path) { problem in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.reason.explanation)
                        PathText(path: problem.path)
                    }
                }
                .frame(minHeight: 60, maxHeight: 140)
            }
            if !failed.isEmpty {
                Text("\(failed.count) items could not be restored")
                    .font(.headline)
                List(failed, id: \.path) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: failure.reason)
                        PathText(path: failure.path)
                    }
                }
                .frame(minHeight: 60, maxHeight: 140)
            }
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
        .accessibilityIdentifier("review.results")
    }
}
