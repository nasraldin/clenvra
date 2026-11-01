import XCTest

/// The pages shown on the download page and release notes, in dark mode, in English and Arabic, after each page's
/// scan (opt-in, `CLENVRA_STORE=1`; run by `scripts/store-screenshots.sh` in a VM with sample files).
final class StoreScreenshotUITests: XCTestCase {
    /// Order of the store images, each page after its scan.
    private let pages = [
        "overview", "cleanup", "storage", "applications", "startup", "recentItems", "developer", "largeFiles",
    ]

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CLENVRA_STORE"] == nil, "Store screenshots are opt-in")
    }

    @MainActor
    func testCaptureStoreScreens() {
        for language in ["en", "ar"] {
            let app = launchApp(language: language, appearance: .dark)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            for (index, page) in pages.enumerated() {
                open(section: page, in: app)
                if page == "overview" {
                    scanEverything(in: app)
                } else {
                    scanAndWait(in: app, timeout: 180)
                }
                sleep(2)
                app.activate()
                let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                shot.name = String(format: "store-%02d-%@-%@", index + 1, page, language)
                shot.lifetime = .keepAlways
                add(shot)
            }
            app.terminate()
        }
    }

    /// Overview's read-only Scan Everything, until Rescan is offered.
    @MainActor
    private func scanEverything(in app: XCUIApplication) {
        let scan = app.buttons["overview.scanEverything"].firstMatch
        guard scan.waitForExistence(timeout: 5) else { return }
        scan.click()
        let rescan = app.buttons["overview.rescan"].firstMatch
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: rescan)
        _ = XCTWaiter.wait(for: [done], timeout: 300)
    }
}
