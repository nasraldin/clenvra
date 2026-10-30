import AppKit
import ClenvraKit
import SwiftUI

/// The app backups in the backups folder: restore one, show it in Finder, or move it to the Trash.
/// Restoring never overwrites: anything already at an item's place is left alone and listed.
struct AppBackupsSheet: View {
    let session: AppsSession
    let folder: URL

    @Environment(\.dismiss) private var dismiss
    @State private var backups: [AppBackupInfo] = []
    @State private var hasLoaded = false
    @State private var selectedID: AppBackupInfo.ID?
    @State private var isWorking = false
    @State private var isConfirmingTrash = false
    @State private var restoreResult: ShownRestoreResult?
    @State private var trashFailed = false

    private var selected: AppBackupInfo? { backups.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App Backups")
                .font(.title3.bold())
            PathText(path: folder.path(percentEncoded: false))
                .font(.callout)
                .foregroundStyle(.secondary)
            table
                .frame(minHeight: 200, maxHeight: 320)
            HStack {
                Button {
                    restore()
                } label: {
                    Text("Restore")
                }
                .help(Text("Put the app and its files back where they were. Nothing that exists there is replaced."))
                .disabled(selected == nil || isWorking)
                Button {
                    if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.url]) }
                } label: {
                    Text("Show in Finder")
                }
                .disabled(selected == nil)
                Button {
                    isConfirmingTrash = true
                } label: {
                    Text("Move Backup to Trash")
                }
                .disabled(selected == nil || isWorking || session.isWorking)
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
        .frame(width: 620)
        .task { await reload() }
        .confirmationDialog(
            Text("Move this backup to the Trash?"), isPresented: $isConfirmingTrash, presenting: selected
        ) { backup in
            Button(role: .destructive) {
                trash(backup)
            } label: {
                Text("Move to Trash")
            }
        } message: { backup in
            Text("The backup of \(backup.name) can no longer be restored once the Trash is emptied.")
        }
        .alert(Text("The backup could not be moved to the Trash."), isPresented: $trashFailed) {
            Button {
                trashFailed = false
            } label: {
                Text("OK")
            }
        }
        .sheet(item: $restoreResult) { shown in
            RestoreResultSheet(name: shown.name, result: shown.result)
        }
    }

    private var table: some View {
        Table(backups, selection: $selectedID) {
            TableColumn(Text("Name")) { backup in
                HStack(spacing: 6) {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: backup.name)
                        .lineLimit(1)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn(Text("Version")) { backup in
                Text(verbatim: backup.version ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn(Text("Date")) { backup in
                Text(backup.created, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn(Text("Size")) { backup in
                SizeText(bytes: backup.archiveBytes)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
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
                    Text("Backups made when you remove several apps appear here.")
                }
            } else {
                ProgressView()
            }
        }
        .accessibilityIdentifier("applications.backups.list")
    }

    private func reload() async {
        let folder = folder
        backups = await Task.detached { AppBackup.list(in: folder) }.value
        if let selectedID, !backups.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        hasLoaded = true
    }

    private func restore() {
        guard let backup = selected else { return }
        isWorking = true
        Task {
            let result: RestoreResult
            do {
                result = try await AppBackup.restore(backup.url)
            } catch {
                var failed = RestoreResult()
                let reason = (error as? AppBackupError)?.message ?? error.localizedDescription
                failed.failed = [.init(path: backup.url.path(percentEncoded: false), reason: reason)]
                result = failed
            }
            isWorking = false
            restoreResult = ShownRestoreResult(name: backup.name, result: result)
            // Restored apps show up in the list again.
            if !result.restored.isEmpty { await session.load() }
        }
    }

    private func trash(_ backup: AppBackupInfo) {
        Task {
            let summary = await session.trashBackup(backup)
            if summary?.movedToTrashCount != 1 { trashFailed = true }
            await reload()
        }
    }
}

private struct ShownRestoreResult: Identifiable {
    let id = UUID()
    let name: String
    let result: RestoreResult
}

/// What a restore put back, and every path it left alone with the reason.
private struct RestoreResultSheet: View {
    let name: String
    let result: RestoreResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restored \(result.restored.count) items of \(name)")
                .font(.title3.bold())
            if !result.skippedExisting.isEmpty {
                Text("\(result.skippedExisting.count) items were not restored because something is already there")
                    .font(.headline)
                Text("Nothing was replaced. Move the existing item away first if you want the backup's copy.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(result.skippedExisting, id: \.self) { path in
                    PathText(path: path)
                }
                .frame(minHeight: 60, maxHeight: 160)
            }
            if !result.failed.isEmpty {
                Text("\(result.failed.count) items could not be restored")
                    .font(.headline)
                List(result.failed, id: \.path) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: failure.reason)
                        PathText(path: failure.path)
                    }
                }
                .frame(minHeight: 60, maxHeight: 160)
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
        .frame(width: 500)
        .accessibilityIdentifier("review.results")
    }
}
