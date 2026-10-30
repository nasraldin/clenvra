import AppKit
import ClenvraKit
import SwiftUI

/// Opens a page from a search result and hands it the query to show. A page takes its query once when it appears
/// (or when a new result for it arrives while it is open), so an old query is never applied again.
@Observable @MainActor
final class SearchRouter {
    private var handoff = SearchHandoff()
    /// Bumped on every `open`, so the window selects the page and a page that is already showing sees a new query.
    private(set) var generation = 0
    /// The page the last result opens; the window selects it.
    private(set) var requestedSection: AppSection?

    func open(_ section: AppSection, query: String?) {
        handoff.open(destination: section.rawValue, query: query)
        requestedSection = section
        generation += 1
    }

    func take(for section: AppSection) -> String? {
        handoff.take(for: section.rawValue)
    }
}

extension View {
    /// The page's search, at the right of the toolbar. It takes the query a search
    /// result handed over, when the page appears and when a new result for it arrives while it is open.
    func pageSearch(
        text: Binding<String>, prompt: LocalizedStringResource, section: AppSection,
        onHandoff: @escaping () -> Void = {}
    ) -> some View {
        modifier(PageSearch(text: text, prompt: prompt, section: section, onHandoff: onHandoff))
    }
}

private struct PageSearch: ViewModifier {
    @Binding var text: String
    let prompt: LocalizedStringResource
    let section: AppSection
    /// Runs when a search result hands this page a query, e.g. to clear a filter that would hide the result.
    let onHandoff: () -> Void
    @Environment(SearchRouter.self) private var router: SearchRouter?

    func body(content: Content) -> some View {
        content
            // The page applies this before its own `.toolbar`: SwiftUI lists an outer view's items first, so the
            // search icon ends up last, at the right end, on every page.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ToolbarSearch(text: $text, prompt: prompt)
                }
            }
            .onAppear(perform: takeQuery)
            .onChange(of: router?.generation) { takeQuery() }
    }

    private func takeQuery() {
        if let query = router?.take(for: section) {
            onHandoff()
            text = query
        }
    }
}

/// The search icon; clicking it (or ⌘F) opens a search field in its place. The field closes again when it is empty
/// and loses focus, or on Esc. One toolbar item throughout, so the toolbar is never rebuilt.
private struct ToolbarSearch: View {
    @Binding var text: String
    let prompt: LocalizedStringResource
    @State private var isOpen = false

    var body: some View {
        Group {
            if isOpen || !text.isEmpty {
                SearchField(text: $text, prompt: String(localized: prompt)) { isOpen = false }
                    .frame(width: 220)
            } else {
                Button {
                    isOpen = true
                } label: {
                    Label {
                        Text("Search")
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .help(Text("Search (⌘F)"))
            }
        }
        .accessibilityIdentifier("page.search")
        // Outside the `if`, so ⌘F works while the field is open too (it focuses it again).
        .background {
            Button {
                isOpen = true
            } label: {
                EmptyView()
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

/// A native search field that takes focus when it appears and calls `close` when it is left empty.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let close: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.text.isEmpty { parent.close() }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            // Esc clears the text first, as in Finder; on an empty field it closes it.
            if parent.text.isEmpty {
                control.window?.makeFirstResponder(nil)
                parent.close()
            } else {
                parent.text = ""
            }
            return true
        }
    }
}
