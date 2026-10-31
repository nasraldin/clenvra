import XCTest

/// End to end for Recent Items, on lists filled in the disposable VM by `scripts/e2e-recent-items.sh` (opt-in,
/// `CLENVRA_E2E=1`). Never run on a real Mac: these tests really clear the lists. The script checks the lists
/// afterwards.
final class RecentItemsE2EUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CLENVRA_E2E"] == nil, "End-to-end tests are opt-in")
        continueAfterFailure = false
    }

    /// Clears the checked lists: the primary action, Clear in the confirmation (Cancel is its default button, so
    /// Clear is clicked inside the dialog, never a Touch Bar copy), then Return for OK on the result.
    @MainActor
    private func clear(in app: XCUIApplication, expecting results: [String]) {
        app.buttons["page.primaryAction"].firstMatch.click()
        let clear = app.windows.buttons["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "No confirmation")
        clear.click()
        let predicates = results.map { NSPredicate(format: "value BEGINSWITH %@", $0) }
        let done = app.staticTexts.containing(NSCompoundPredicate(orPredicateWithSubpredicates: predicates)).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60), "No result “\(results)”")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "The result stayed open")
    }

    @MainActor
    func testClearsMacListsThenAnAppsList() {
        let app = launchApp(language: "en")
        defer { app.terminate() }
        open(section: "recentItems", in: app)
        for list in ["Recent Applications", "Recent Documents", "Finder’s Recent Folders"] {
            let checkbox = app.checkBoxes["Include \(list)"].firstMatch
            XCTAssertTrue(checkbox.waitForExistence(timeout: 10), "\(list) is not listed")
            checkbox.click()
        }
        // As a person would: a list highlighted while it is cleared (its rows then go away).
        app.staticTexts["Recent Documents"].firstMatch.click()
        clear(in: app, expecting: ["The lists are empty now.", "Cleared."])
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground, "Clenvra stopped after clearing")
        XCTAssertTrue(
            app.checkBoxes["Include Recent Documents"].waitForNonExistence(timeout: 10),
            "Recent Documents is still listed")

        open(section: "appRecentItems", in: app)
        let textEdit = app.checkBoxes["Include TextEdit"].firstMatch
        XCTAssertTrue(textEdit.waitForExistence(timeout: 10), "TextEdit's list is not listed")
        textEdit.click()
        clear(in: app, expecting: ["Cleared."])
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground, "Clenvra stopped after clearing")
        XCTAssertTrue(textEdit.waitForNonExistence(timeout: 10), "TextEdit's list is still listed")
    }
}
