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
                "-ClenvraUITestMainDisplay", "YES",
                "-clenvra.permissionsGuideSeen", "YES",
            ]
            if language == "ar" {
                // What Xcode's right-to-left run option passes, so the layout mirrors as on an Arabic system.
                app.launchArguments += ["-NSForceRightToLeftWritingDirection", "YES", "-AppleTextDirection", "YES"]
            }
            app.launch()
            for section in allSections {
                open(section: section, in: app)
                scanAndWait(in: app, timeout: 120)
                // A window screenshot is a screen region: bring the app to the front so nothing covers it.
                app.activate()
                let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                attachment.name = "\(section)-\(language)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            captureCompactSidebar(of: app, language: language)
            if language == "en" { captureSettings(of: app) }
            app.terminate()
        }
    }

    override func setUpWithError() throws {
        // The VM script always passes the variable (0 or 1), so only "1" turns the screenshots on.
        try XCTSkipIf(outputFolder != "1", "Screenshots are opt-in")
    }

    /// The sidebar as a strip of icons, then back to names.
    @MainActor
    private func captureCompactSidebar(of app: XCUIApplication, language: String) {
        let toggle = app.descendants(matching: .any)["sidebar.toggle"].firstMatch
        guard toggle.waitForExistence(timeout: 3) else { return }
        toggle.click()
        open(section: "applications", in: app)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "compact-sidebar-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
        toggle.click()
    }

    /// Every Settings tab, for visual review.
    @MainActor
    private func captureSettings(of app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.firstMatch
        guard settings.waitForExistence(timeout: 5) else { return }
        for tab in ["General", "Schedule", "Menu Bar", "Exclusions", "Custom Rules", "System Helper"] {
            let button = app.toolbars.buttons[tab].firstMatch
            guard button.waitForExistence(timeout: 3) else { continue }
            button.click()
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "settings-\(tab)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.typeKey("w", modifierFlags: .command)
    }
}
