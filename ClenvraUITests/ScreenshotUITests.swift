import XCTest

/// Captures each implemented section in English and Arabic as test attachments for visual review.
/// Opt-in: `TEST_RUNNER_CLENVRA_SCREENSHOTS=1 xcodebuild test -resultBundlePath R.xcresult
/// -only-testing:ClenvraUITests/ScreenshotUITests`, then `xcrun xcresulttool export attachments --path R.xcresult`.
final class ScreenshotUITests: XCTestCase {
    private var outputFolder: String? { ProcessInfo.processInfo.environment["CLENVRA_SCREENSHOTS"] }

    @MainActor
    func testCaptureSections() {
        for language in ["en", "ar"] {
            let app = XCUIApplication()
            app.launchArguments += [
                "-AppleLanguages", "(\(language))", "-AppleLocale", language, "-ApplePersistenceIgnoreState", "YES",
            ]
            if language == "ar" {
                // What Xcode's right-to-left run option passes, so the layout mirrors as on an Arabic system.
                app.launchArguments += ["-NSForceRightToLeftWritingDirection", "YES", "-AppleTextDirection", "YES"]
            }
            app.launch()
            let sections = [
                "overview", "storage", "duplicates", "cleanup", "developer", "applications", "startup", "system",
                "activity",
            ]
            for section in sections {
                app.outlines.cells.containing(.any, identifier: "sidebar.\(section)").firstMatch.click()
                // Wait for the read-only scan to finish and results to appear.
                _ = app.descendants(matching: .any)["section.\(section)"].waitForExistence(timeout: 10)
                _ = app.descendants(matching: .any)["review.results"].waitForExistence(timeout: 30)
                let scanning = app.descendants(matching: .any)["review.scanning"]
                let finished = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: scanning)
                wait(for: [finished], timeout: 180)
                // A window screenshot is a screen region: bring the app to the front so nothing covers it.
                app.activate()
                let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                attachment.name = "\(section)-\(language)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }

    override func setUpWithError() throws {
        try XCTSkipIf(outputFolder == nil, "Screenshots are opt-in")
    }
}
