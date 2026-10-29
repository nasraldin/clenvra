import AppKit
import ClenvraKit
import SwiftUI

// The parts every list page shares (docs/superpowers/specs/2026-10-28-ui-redesign-design.md, "The page pattern"),
// so a page that adopts them looks and behaves like System Junk.

/// Which groups of a list are open, remembered per page across launches. Option-click opens or closes every group,
/// as in Finder (F4).
struct ExpandedGroups: DynamicProperty {
    @SceneStorage private var stored: String
    /// Long lists (such as the activity history) start with every group closed.
    private let opensByDefault: Bool

    init(_ page: String, opensByDefault: Bool = true) {
        _stored = SceneStorage(wrappedValue: "", "groups.\(page)")
        self.opensByDefault = opensByDefault
    }

    /// `all` lists every group of the page, for Option-click.
    func binding(_ id: String, all: @escaping () -> [String]) -> Binding<Bool> {
        // The stored set holds the groups that differ from the default.
        Binding(
            get: { GroupExpansion(stored: stored).isExpanded(id) == opensByDefault },
            set: { expanded in
                var expansion = GroupExpansion(stored: stored)
                let ids = NSEvent.modifierFlags.contains(.option) ? all() : [id]
                expansion.set(ids, expanded: expanded == opensByDefault)
                stored = expansion.stored
            })
    }
}

/// The page's completing action: the one prominent toolbar button.
struct PrimaryActionButton: View {
    var title: LocalizedStringResource = "Move to Trash…"
    var symbol = "trash"
    var help: LocalizedStringResource = "Review and move the selected items to the Trash (⌘⌫)"
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.delete, modifiers: .command)
        .help(Text(help))
        .disabled(isDisabled)
        .accessibilityIdentifier("page.primaryAction")
    }
}

/// Shows or hides the inspector (⌃⌘I comes from `InspectorCommands`).
struct InspectorToggle: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label {
                Text(isPresented ? "Hide Details" : "Show Details")
            } icon: {
                Image(systemName: "sidebar.trailing")
            }
        }
        .help(Text("Show or hide the details of the highlighted item (⌃⌘I)"))
    }
}

/// The bar under a list: what is selected and what removing it frees, or the running action.
struct SelectionStatusBar: View {
    let count: Int
    let bytes: Int64
    var working: LocalizedStringResource?
    var scanned: Date?

    var body: some View {
        HStack(spacing: 8) {
            if let working {
                ProgressView().controlSize(.small)
                Text(working)
            } else {
                Text("\(count) items selected")
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text("Frees about \(bytes.formatted(.byteCount(style: .file)))")
                if let scanned {
                    Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text("Scanned \(scanned.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Inspector for one file or folder: icon, name, the page's own details, then the location with Show in Finder.
struct ItemInspector<Details: View>: View {
    let name: String
    let path: String?
    var icon: NSImage?
    @ViewBuilder var details: Details

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    if let image = icon ?? path.map({ NSWorkspace.shared.icon(forFile: $0) }) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
            }
            details
            if let path {
                Section {
                    PathText(path: path)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                    } label: {
                        Text("Show in Finder")
                    }
                } header: {
                    Text("Location")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("page.inspector")
    }
}

/// Inspector for several highlighted items: how many, and their size.
struct SelectionTotalsInspector: View {
    let count: Int
    let bytes: Int64?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(count, format: .number)
                } label: {
                    Text("Items")
                }
                if let bytes {
                    LabeledContent {
                        SizeText(bytes: bytes)
                    } label: {
                        Text("Size")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("page.inspector")
    }
}

/// Inspector with nothing highlighted.
struct NoSelectionInspector: View {
    var description: LocalizedStringResource = "Select an item to see its details."

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("No Selection")
            } icon: {
                Image(systemName: "sidebar.trailing")
            }
        } description: {
            Text(description)
        }
        .accessibilityIdentifier("page.inspector")
    }
}

/// A date in a table cell, or "Unknown" (a word: a lone dash is too thin to read reliably).
struct DateCell: View {
    let date: Date?

    var body: some View {
        if let date, date > .distantPast {
            Text(date, format: .dateTime.year().month(.abbreviated).day())
                .foregroundStyle(.secondary)
        } else {
            Text("Unknown")
                .foregroundStyle(.secondary)
        }
    }
}

/// A name with its Finder icon, for table cells.
struct FileNameCell: View {
    let name: String
    let path: String?
    var icon: NSImage?

    var body: some View {
        Label {
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            if let image = icon ?? path.map({ NSWorkspace.shared.icon(forFile: $0) }) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
        }
        .help(Text(verbatim: path ?? name))
    }
}

/// Show in Finder and Copy Path for a set of files, plus Show Details when the page has an inspector.
struct FileActionsMenu: View {
    let paths: [String]
    var showDetails: (() -> Void)?

    var body: some View {
        if let showDetails {
            Button(action: showDetails) {
                Text("Show Details")
            }
        }
        if !paths.isEmpty {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
            } label: {
                Text("Show in Finder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
            } label: {
                Text(paths.count == 1 ? "Copy Path" : "Copy Paths")
            }
        }
    }
}
