import AppKit
import ClenvraKit
import SwiftUI

/// Every duplicate group with its copies; one copy per group is always kept (enforced by the session).
struct DuplicateGroupsList: View {
    let session: DuplicatesSession
    @Binding var previewURL: URL?

    var body: some View {
        List {
            if !session.lastScanWasComplete || session.unreadableCount > 0 {
                Section {
                    if !session.lastScanWasComplete {
                        Label {
                            Text("The scan was stopped. Results may be incomplete.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                    }
                    if session.unreadableCount > 0 {
                        Label {
                            Text("\(session.unreadableCount) files could not be read.")
                        } icon: {
                            Image(systemName: "lock")
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }
            ForEach(session.groups) { group in
                Section {
                    ForEach(group.files, id: \.path) { file in
                        DuplicateFileRow(file: file, session: session, previewURL: $previewURL)
                    }
                } header: {
                    DuplicateGroupHeader(
                        group: group, markedBytes: session.markedBytes(in: group), previewURL: $previewURL)
                }
            }
        }
        .disabled(session.phase == .removing)
    }
}

private struct DuplicateGroupHeader: View {
    let group: DuplicatesSession.Group
    let markedBytes: Int64
    @Binding var previewURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let first = group.files.first {
                Button {
                    previewURL = URL(filePath: first.path)
                } label: {
                    Label {
                        Text("Quick Look")
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                            .resizable()
                            .frame(width: 36, height: 36)
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help(Text("Quick Look"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: (first.path as NSString).lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(
                        "\(group.files.count) copies · \(group.size.formatted(.byteCount(style: .file))) each"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if group.sharesStorage {
                        Label {
                            Text("These copies share storage; removing them frees almost nothing.")
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .textCase(nil)
            }
            Spacer()
            Text("Frees about \(markedBytes.formatted(.byteCount(style: .file)))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
        .padding(.vertical, 4)
    }
}

private struct DuplicateFileRow: View {
    let file: DuplicateFile
    let session: DuplicatesSession
    @Binding var previewURL: URL?

    var body: some View {
        let isMarked = session.isMarked(file.path)
        HStack(spacing: 10) {
            Button {
                session.keepOnly(file.path)
            } label: {
                Label {
                    Text("Keep")
                } icon: {
                    Image(systemName: isMarked ? "circle" : "largecircle.fill.circle")
                        .foregroundStyle(isMarked ? Color.secondary : Color.accentColor)
                }
            }
            .buttonStyle(.borderless)
            .help(Text("Keep only this copy"))
            .accessibilityAddTraits(isMarked ? [] : .isSelected)

            VStack(alignment: .leading, spacing: 2) {
                PathText(path: file.path)
                Text("Modified \(file.modificationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle(
                isOn: Binding(
                    get: { session.isMarked(file.path) },
                    set: { session.setMarked($0, path: file.path) })
            ) {
                Text("Move to Trash")
            }
            .toggleStyle(.checkbox)
            .disabled(!session.canMark(file.path))
            .help(Text("At least one copy is always kept."))

            SizeText(bytes: file.reclaimable)
                .foregroundStyle(isMarked ? .primary : .secondary)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                previewURL = URL(filePath: file.path)
            } label: {
                Text("Quick Look")
            }
            Button {
                NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
            } label: {
                Text("Show in Finder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            } label: {
                Text("Copy Path")
            }
        }
    }
}
