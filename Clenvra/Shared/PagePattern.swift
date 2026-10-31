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
        Binding(
            get: { isExpanded(id) },
            set: { expanded in setExpanded(NSEvent.modifierFlags.contains(.option) ? all() : [id], expanded) })
    }

    /// Whether every one of `ids` is open; setting it opens or closes them all (Expand All / Collapse All).
    func allBinding(_ ids: [String]) -> Binding<Bool> {
        Binding(
            get: { !ids.isEmpty && ids.allSatisfy(isExpanded) },
            set: { setExpanded(ids, $0) })
    }

    private func isExpanded(_ id: String) -> Bool {
        // The stored set holds the groups that differ from the default.
        GroupExpansion(stored: stored).isExpanded(id) == opensByDefault
    }

    private func setExpanded(_ ids: [String], _ expanded: Bool) {
        var expansion = GroupExpansion(stored: stored)
        expansion.set(ids, expanded: expanded == opensByDefault)
        withAnimation(.smooth(duration: 0.25)) { stored = expansion.stored }
    }
}

/// Scan (⌘R), which becomes Stop (Esc) while the scan runs. One button whose label changes, so the toolbar keeps its
/// layout instead of rebuilding when a scan starts or ends.
struct ScanButton: View {
    let isScanning: Bool
    var title: LocalizedStringResource = "Scan"
    var isDisabled = false
    let scan: () -> Void
    let stop: () -> Void

    var body: some View {
        Button {
            if isScanning { stop() } else { scan() }
        } label: {
            ToolbarLabel(
                title: isScanning ? "Stop Scan" : title, symbol: isScanning ? "stop.circle" : "arrow.clockwise")
        }
        .keyboardShortcut(isScanning ? .cancelAction : KeyboardShortcut("r", modifiers: .command))
        .help(Text(isScanning ? "Stop the scan (Esc)" : "Scan again (⌘R)"))
        .disabled(!isScanning && isDisabled)
    }
}

/// Opens or closes every group of a page at once.
struct ExpandAllButton: View {
    @Binding var allExpanded: Bool

    var body: some View {
        Button {
            allExpanded.toggle()
        } label: {
            ToolbarLabel(
                title: allExpanded ? "Collapse All" : "Expand All",
                symbol: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        }
        .help(Text(allExpanded ? "Close every group (Option-click a group does the same)" : "Open every group"))
        .accessibilityIdentifier("page.expandAll")
    }
}

/// A toolbar button's label: the icon alone, or icon and name when the person turns on
/// Settings › General › Show Names in the Toolbar.
struct ToolbarLabel: View {
    static let showsTitlesKey = "toolbar.showsTitles"

    let title: LocalizedStringResource
    let symbol: String
    @AppStorage(ToolbarLabel.showsTitlesKey) private var showsTitles = false

    var body: some View {
        let label = Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
        }
        if showsTitles {
            label.labelStyle(.titleAndIcon)
        } else {
            label.labelStyle(.iconOnly)
        }
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
            ToolbarLabel(title: title, symbol: symbol)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.delete, modifiers: .command)
        .help(Text(help))
        .disabled(isDisabled)
        .accessibilityIdentifier("page.primaryAction")
    }
}

/// A details panel on the trailing side of the page. Drawn by the page itself rather than with the system inspector:
/// on macOS 27 the system inspector, inside a split view's detail column, collapses the sidebar for a moment each time
/// it opens.
struct DetailsPanel<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat
    @ViewBuilder let panel: Panel

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented {
                HStack(spacing: 0) {
                    Divider()
                    panel
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: isPresented)
    }
}

extension View {
    func detailsPanel<Panel: View>(
        isPresented: Binding<Bool>, width: CGFloat = 280, @ViewBuilder _ panel: () -> Panel
    ) -> some View {
        modifier(DetailsPanel(isPresented: isPresented, width: width, panel: panel))
    }
}

/// See `View.pageState(isShown:_:)`.
struct PageStateOverlay<Placeholder: View>: ViewModifier {
    let isShown: Bool
    let placeholder: Placeholder

    func body(content: Content) -> some View {
        // Transparent rather than hidden from accessibility: hiding a list that owns toolbar items confuses the
        // accessibility tree. A transparent view is skipped by VoiceOver.
        content
            .opacity(isShown ? 0 : 1)
            .overlay {
                if isShown {
                    placeholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                }
            }
    }
}

/// Shows or hides the details panel (⌃⌘I).
struct InspectorToggle: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ToolbarLabel(title: isPresented ? "Hide Details" : "Show Details", symbol: "sidebar.trailing")
        }
        .keyboardShortcut("i", modifiers: [.control, .command])
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
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .statusBarBackground()
    }
}

extension View {
    /// Shows a page state (Scan prompt, progress, nothing found) over the page's list instead of in its place. The
    /// list stays in the window: replacing it makes macOS rebuild the whole toolbar, which looks like a reload.
    func pageState<Placeholder: View>(isShown: Bool, @ViewBuilder _ placeholder: () -> Placeholder) -> some View {
        modifier(PageStateOverlay(isShown: isShown, placeholder: placeholder()))
    }

    /// A bar under a list sits below the rows, never over them: the page's own background and a divider, as in
    /// Finder's status bar.
    func statusBarBackground() -> some View {
        VStack(spacing: 0) {
            Divider()
            self
        }
        .background(.background)
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
                    if let image = icon ?? path.map({ IconCache.shared.icon(forFile: $0) }) {
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
        // Icon and name side by side rather than one Label: the name's accessibility frame then holds only the text,
        // so a short name is not measured against the colored icon next to it.
        HStack(spacing: 6) {
            if let image = icon ?? path.map({ IconCache.shared.icon(forFile: $0) }) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.middle)
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
