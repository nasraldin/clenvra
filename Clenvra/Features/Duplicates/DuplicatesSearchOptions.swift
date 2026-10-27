import AppKit
import ClenvraKit
import SwiftUI

/// Folders to search and the minimum file size; used on the start screen and in the inspector.
struct DuplicatesSearchOptions: View {
    @Bindable var session: DuplicatesSession

    var body: some View {
        Form {
            Section {
                if session.roots.isEmpty {
                    Text("Add at least one folder to search.")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.roots, id: \.self) { root in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: root))
                            .resizable()
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        PathText(path: root)
                        Spacer()
                        Button {
                            session.removeRoot(root)
                        } label: {
                            Label {
                                Text("Remove")
                            } icon: {
                                Image(systemName: "minus.circle")
                            }
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove"))
                    }
                }
                Button {
                    chooseFolders()
                } label: {
                    Label {
                        Text("Add Folder…")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            } header: {
                Text("Folders to Search")
            }

            Section {
                Picker(selection: $session.minimumSize) {
                    ForEach(DuplicatesSession.minimumSizeChoices, id: \.self) { size in
                        Text(size, format: .byteCount(style: .file)).tag(size)
                    }
                } label: {
                    Text("Ignore files smaller than")
                }
            } footer: {
                Text("Hidden files, apps and photo libraries are not searched.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(isScanning)
    }

    private var isScanning: Bool {
        switch session.phase {
        case .scanning, .removing: true
        case .idle, .ready: false
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            session.addRoot(url.path(percentEncoded: false))
        }
    }
}
