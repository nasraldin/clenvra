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
        text: Binding<String>, prompt: LocalizedStringResource, section: AppSection
    ) -> some View {
        modifier(PageSearch(text: text, prompt: prompt, section: section))
    }
}

private struct PageSearch: ViewModifier {
    @Binding var text: String
    let prompt: LocalizedStringResource
    let section: AppSection
    @Environment(SearchRouter.self) private var router: SearchRouter?

    func body(content: Content) -> some View {
        content
            // At the trailing end of the toolbar; macOS shrinks it to an icon when the toolbar is short of space.
            // (`searchToolbarBehavior(.minimize)` is unavailable on macOS.)
            .searchable(text: $text, placement: .toolbar, prompt: Text(prompt))
            .onAppear(perform: takeQuery)
            .onChange(of: router?.generation) { takeQuery() }
    }

    private func takeQuery() {
        if let query = router?.take(for: section) { text = query }
    }
}
