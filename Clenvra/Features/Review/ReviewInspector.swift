import AppKit
import ClenvraKit
import SwiftUI

/// Details of the highlighted items: what it is, where it lives, what removing it frees, and why it is (or is not)
/// included.
struct ReviewInspector: View {
    let candidates: [CleanupCandidate]
    let session: CleanupSession

    var body: some View {
        Group {
            if candidates.count == 1, let candidate = candidates.first {
                single(candidate)
            } else if candidates.count > 1 {
                multiple
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No Selection")
                    } icon: {
                        Image(systemName: "sidebar.trailing")
                    }
                } description: {
                    Text("Select an item to see where it is and what removing it frees.")
                }
            }
        }
        .accessibilityIdentifier("review.inspector")
    }

    private func single(_ candidate: CleanupCandidate) -> some View {
        Form {
            Section {
                VStack(alignment: .center, spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text(verbatim: candidate.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    StatusBadge(
                        candidate: candidate,
                        needsHelper: session.requiresHelper(candidate) && !session.helperAvailable)
                }
                .frame(maxWidth: .infinity)
            }

            Section {
                LabeledContent {
                    SizeText(bytes: candidate.reclaimableSize)
                } label: {
                    Text("Frees")
                }
                if candidate.allocatedSize != candidate.reclaimableSize {
                    LabeledContent {
                        SizeText(bytes: candidate.allocatedSize)
                    } label: {
                        Text("Size on Disk")
                    }
                }
                if let date = candidate.modificationDate {
                    LabeledContent {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    } label: {
                        Text("Modified")
                    }
                }
                if let owner = candidate.ownerBundleID {
                    LabeledContent {
                        Text(verbatim: Self.appName(for: owner) ?? owner)
                    } label: {
                        Text("Belongs To")
                    }
                }
            }

            Section {
                PathText(path: candidate.path)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: candidate.path)])
                } label: {
                    Text("Show in Finder")
                }
            } header: {
                Text("Location")
            }

            if let category = session.groups.first(where: { $0.candidates.contains { $0.path == candidate.path } })?
                .category
            {
                Section {
                    Text(category.explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(category.title)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var multiple: some View {
        Form {
            Section {
                LabeledContent {
                    Text(candidates.count, format: .number)
                } label: {
                    Text("Items")
                }
                LabeledContent {
                    SizeText(bytes: candidates.reduce(0) { $0 + $1.reclaimableSize })
                } label: {
                    Text("Frees")
                }
                let included = candidates.count { session.selection.contains($0.path) }
                LabeledContent {
                    Text(included, format: .number)
                } label: {
                    Text("Included")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The display name of an installed app, from its bundle identifier.
    private static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "")
    }
}
