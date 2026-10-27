import ClenvraKit
import SwiftUI

/// Confirmation before moving items to the Trash, or deleting Trash items for good.
struct ConfirmCleanupSheet: View {
    let count: Int
    let bytes: Int64
    /// The selection includes Trash items, which are deleted for good.
    var includesPermanentRemoval = false
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(includesPermanentRemoval ? "Clean up \(count) items?" : "Move \(count) items to the Trash?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            Text("This frees about \(bytes.formatted(.byteCount(style: .file))).")
            if includesPermanentRemoval {
                Label {
                    Text("Items already in the Trash are deleted permanently. This cannot be undone.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout.weight(.semibold))
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
                    if includesPermanentRemoval {
                        Text("Clean Up")
                    } else {
                        Text("Move to Trash")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// What happened, including every skipped item with a plain reason.
struct CleanupResultSheet: View {
    let summary: CleanupSummary
    let isPreview: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isPreview {
                Text("Preview: \(summary.wouldRemoveCount) items can be moved to the Trash")
                    .font(.title3.bold())
                Text("Nothing was changed.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Moved \(summary.movedToTrashCount) items to the Trash")
                    .font(.title3.bold())
                if summary.removedPermanentlyCount > 0 {
                    Text("Deleted \(summary.removedPermanentlyCount) items from the Trash permanently.")
                }
                Text("Freed about \(summary.freedBytes.formatted(.byteCount(style: .file))).")
            }

            if !summary.problems.isEmpty {
                Text("\(summary.problems.count) items were skipped")
                    .font(.headline)
                List(summary.problems, id: \.path) { problem in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.reason.explanation)
                        PathText(path: problem.path)
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
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
        .frame(width: 480)
    }
}

extension ActivityRecord.Outcome {
    /// Plain-language reason shown next to a skipped or failed item.
    var explanation: LocalizedStringResource {
        switch self {
        case .skipped(let refusal): refusal.explanation
        case .failed: "macOS could not move this item."
        case .anomaly: "The item in the Trash was not the one checked, so the cleanup was stopped."
        case .notAttempted: "Not attempted because the cleanup was stopped."
        case .intent, .movedToTrash, .removedPermanently, .wouldDelete, .restored: "Done."
        }
    }
}

extension SafetyRefusal {
    var explanation: LocalizedStringResource {
        switch self {
        case .invalidPath, .isVolumeRoot, .outsideRoot: "This location is not allowed."
        case .pathChanged: "A folder on the way to this item changed."
        case .notFound: "It no longer exists."
        case .permissionDenied: "macOS did not allow access."
        case .protected, .containsProtectedItem: "It is protected or contains protected items."
        case .changedSinceScan: "It changed after you reviewed it."
        case .differentVolume: "It is on another disk."
        case .flagged: "It is locked or protected by macOS."
        case .inUse: "The app that uses it is open."
        case .ioError: "macOS reported an error."
        }
    }
}
