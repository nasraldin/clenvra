import XCTest

/// The search icon on every page, and the Overview search that opens other pages. Search only reads.
final class SearchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEveryPageHasSearch() {
        let app = launchApp(language: "en")
        defer { app.terminate() }
        for section in allSections {
            open(section: section, in: app)
            XCTAssertTrue(searchButton(in: app).waitForExistence(timeout: 5), "No search on \(section)")
        }
    }

    @MainActor
    func testOverviewSearchOpensPage() {
        let app = launchApp(language: "en")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["section.overview"].waitForExistence(timeout: 5))

        searchButton(in: app).click()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "The icon did not open a field")
        app.typeText("time machine")
        let result = app.descendants(matching: .any).matching(identifier: "overview.searchResult").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), "No result for a page keyword")
        result.click()
        XCTAssertTrue(app.descendants(matching: .any)["section.snapshots"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEscClearsThenCloses() {
        let app = launchApp(language: "en")
        defer { app.terminate() }
        open(section: "activity", in: app)
        app.typeKey("f", modifierFlags: .command)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F did not open the field")
        app.typeText("abc")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(field.value as? String ?? "", "", "Esc did not clear the text")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchButton(in: app).waitForExistence(timeout: 5), "Esc on an empty field did not close it")
    }

    @MainActor
    private func searchButton(in app: XCUIApplication) -> XCUIElement {
        app.toolbars.buttons.matching(identifier: "page.search").firstMatch
    }
}
