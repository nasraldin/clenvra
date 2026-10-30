import XCTest

/// End to end for the gap features, on data seeded into the disposable VM by `scripts/e2e-gap-features.sh`
/// (opt-in, `CLENVRA_E2E=1`). Never run on a real Mac: these tests really remove what they find.
///
/// Seeded: `~/.Trash/Foo.app` (com.example.foo) with `~/Library/Application Support/com.example.foo`, a second
/// drive "TestDrive" with `.Trashes/501/old-file.bin`, blurry and dark photos in `~/Pictures/E2E`. The script
/// checks the files on disk afterwards.
final class GapFeaturesE2EUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CLENVRA_E2E"] == nil, "End-to-end tests are opt-in")
        continueAfterFailure = false
    }

    @MainActor
    private func startApp() -> XCUIApplication {
        let app = launchApp(language: "en")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// Confirms the open review sheet (its default button), then closes the result sheet that replaces it.
    @MainActor
    private func confirmAndFinish(in app: XCUIApplication) {
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "No confirmation sheet")
        app.typeKey(.return, modifierFlags: [])
        let done = app.sheets.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 120), "No result after confirming")
        done.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "The result sheet did not close")
    }

    @MainActor
    func testLeftoversOfAppInTrash() {
        let app = startApp()
        open(section: "leftovers", in: app)
        scanAndWait(in: app)
        let checkbox = app.checkBoxes["Include com.example.foo"].firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 30), "The trashed app's data was not listed")
        checkbox.click()
        app.buttons["page.primaryAction"].firstMatch.click()
        confirmAndFinish(in: app)
        XCTAssertTrue(checkbox.waitForNonExistence(timeout: 30), "The leftover is still listed after removal")
    }

    @MainActor
    func testTrashOnOtherDrive() {
        let app = startApp()
        open(section: "cleanup", in: app)
        scanAndWait(in: app)
        let checkbox = app.checkBoxes["Include old-file.bin"].firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 60), "The other drive's Trash was not listed")
        // Never preselected (it cannot be undone). Other preselected VM caches go too; the VM is disposable.
        XCTAssertEqual(checkbox.value as? Int, 0, "A drive's Trash item was preselected")
        checkbox.click()
        app.buttons["page.primaryAction"].firstMatch.click()
        confirmAndFinish(in: app)
        XCTAssertTrue(checkbox.waitForNonExistence(timeout: 30), "The item is still listed after emptying")
    }

    @MainActor
    func testBlurryAndDarkPhotos() {
        let app = startApp()
        open(section: "similarPhotos", in: app)
        let find = app.buttons["Find Similar Photos"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        find.click()
        let section = app.descendants(matching: .any)["similarPhotos.lowQuality"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 180), "No blurry or dark photos were listed")
        // A checkbox of the low-quality section, by its label (the section header does not contain the grid).
        let mark = app.checkBoxes["Move photo2-dark.jpg to the Trash"].firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 10), "No checkbox for the dark test photo")
        mark.click()
        app.buttons["page.primaryAction"].firstMatch.click()
        confirmAndFinish(in: app)
    }

    @MainActor
    func testRemoveSimulatorRuntime() {
        let app = startApp()
        open(section: "developerTools", in: app)
        let check = app.buttons["review.scan"].firstMatch
        if check.waitForExistence(timeout: 10) { check.click() }
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'xrOS 27.0 Simulator runtime'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120), "The xrOS runtime was not listed")
        // The row is one accessibility element; "Clean…" is its trailing button.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        let run = app.buttons["Run"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 10), "No confirmation for the runtime")
        run.click()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 300), "The runtime removal did not finish")
        XCTAssertTrue(app.staticTexts["Finished"].exists, "simctl reported a failure")
        done.click()
    }

    @MainActor
    func testPermissionsPageReads() {
        let app = startApp()
        open(section: "permissions", in: app)
        // The test build has no Full Disk Access in the VM: the page must say so, never show an empty list.
        let prompt = app.staticTexts["Allow Full Disk Access"].firstMatch
        let list = app.outlines.matching(NSPredicate(format: "identifier != 'Sidebar'")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20) || list.exists, "Neither the access prompt nor a list")
        XCTAssertFalse(app.staticTexts["No Permissions"].exists, "An unreadable database looked like no permissions")
    }
}
