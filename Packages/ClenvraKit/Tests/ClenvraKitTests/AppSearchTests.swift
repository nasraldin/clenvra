import Testing

@testable import ClenvraKit

@Suite("App search")
struct AppSearchTests {
    private static func entry(
        _ title: String, subtitle: String? = nil, keywords: [String] = [], destination: String = "overview"
    ) -> SearchEntry {
        SearchEntry(title: title, subtitle: subtitle, keywords: keywords, destination: destination, query: nil)
    }

    private static let pages = [
        entry("System Junk", keywords: ["cache", "logs", "junk"], destination: "cleanup"),
        entry("Xcode Developer Tools", destination: "developerTools"),
        entry("Developer Junk", destination: "developer"),
        entry("Safari", subtitle: "/Applications/Safari.app", destination: "applications"),
        entry("الكاميرا", subtitle: "Permissions", destination: "permissions"),
    ]

    @Test func emptyQueryGivesNothing() {
        #expect(AppSearch.results(for: "", in: Self.pages).isEmpty)
        #expect(AppSearch.results(for: "   \n", in: Self.pages).isEmpty)
    }

    @Test func matchesTitleCaseInsensitively() {
        let results = AppSearch.results(for: "SAFARI", in: Self.pages)
        #expect(results.map(\.title) == ["Safari"])
    }

    @Test func matchesArabic() {
        let results = AppSearch.results(for: "الكاميرا", in: Self.pages)
        #expect(results.map(\.destination) == ["permissions"])
    }

    @Test func prefixRanksFirst() {
        let results = AppSearch.results(for: "Dev", in: Self.pages)
        #expect(results.map(\.title) == ["Developer Junk", "Xcode Developer Tools"])
    }

    @Test func keywordMatch() {
        let results = AppSearch.results(for: "cache", in: Self.pages)
        #expect(results.map(\.title) == ["System Junk"])
    }

    @Test func subtitleRanksAfterTitle() {
        let entries = [
            Self.entry("Mail", subtitle: "Safari helper"), Self.entry("Safari Web"), Self.entry("My Safari"),
        ]
        let results = AppSearch.results(for: "safari", in: entries)
        #expect(results.map(\.title) == ["Safari Web", "My Safari", "Mail"])
    }

    @Test func stableWithinRank() {
        let entries = (1...5).map { Self.entry("Item \($0)") }
        #expect(AppSearch.results(for: "item", in: entries) == entries)
    }

    @Test func trimsSpaces() {
        let results = AppSearch.results(for: "  safari \n", in: Self.pages)
        #expect(results.map(\.title) == ["Safari"])
    }

    @Test func matchesAnyField() {
        let fields: [String?] = ["Installer.dmg", nil, "/Users/me/Downloads/Installer.dmg", "apple.com"]
        #expect(AppSearch.matches(" APPLE ", any: fields))
        #expect(AppSearch.matches("downloads", any: fields))
        #expect(!AppSearch.matches("nothing", any: fields))
        #expect(AppSearch.matches("", any: []))
    }

    @Test func respectsLimit() {
        let entries = (1...80).map { Self.entry("File \($0)") }
        #expect(AppSearch.results(for: "file", in: entries).count == 50)
        #expect(AppSearch.results(for: "file", in: entries, limit: 3).count == 3)
        #expect(AppSearch.results(for: "file", in: entries, limit: 0).isEmpty)
    }

    @Test func normalizedQueryTrims() {
        #expect(AppSearch.normalized("  Foo ") == "Foo")
        #expect(AppSearch.matches("  SAFARI ", "Safari"))
        #expect(AppSearch.matches("", "Safari"))
        #expect(!AppSearch.matches("chrome", "Safari"))
    }
}

@Suite("Search handoff")
struct SearchHandoffTests {
    @Test func takeReturnsOnce() {
        var handoff = SearchHandoff()
        handoff.open(destination: "applications", query: "Safari")
        #expect(handoff.take(for: "applications") == "Safari")
        #expect(handoff.take(for: "applications") == nil)
    }

    @Test func takeForOtherPageIsNil() {
        var handoff = SearchHandoff()
        handoff.open(destination: "applications", query: "Safari")
        #expect(handoff.take(for: "startup") == nil)
        #expect(handoff.take(for: "applications") == "Safari")
    }

    @Test func newOpenReplacesOld() {
        var handoff = SearchHandoff()
        handoff.open(destination: "applications", query: "Safari")
        handoff.open(destination: "applications", query: "Mail")
        #expect(handoff.take(for: "applications") == "Mail")
        handoff.open(destination: "applications", query: "Notes")
        handoff.open(destination: "startup", query: "Dropbox")
        #expect(handoff.take(for: "applications") == nil)
        #expect(handoff.take(for: "startup") == "Dropbox")
    }

    @Test func openWithoutQueryClearsPending() {
        var handoff = SearchHandoff()
        handoff.open(destination: "applications", query: "Safari")
        handoff.open(destination: "applications", query: nil)
        #expect(handoff.take(for: "applications") == nil)
    }
}
