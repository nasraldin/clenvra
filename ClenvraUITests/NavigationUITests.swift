import XCTest

/// Smoke navigation through every section in each language × appearance.
final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testNavigationEnglishLight() { runNavigation(language: "en", appearance: .light) }
    @MainActor func testNavigationEnglishDark() { runNavigation(language: "en", appearance: .dark) }
    @MainActor func testNavigationArabicLight() { runNavigation(language: "ar", appearance: .light) }
    @MainActor func testNavigationArabicDark() { runNavigation(language: "ar", appearance: .dark) }

    @MainActor
    private func runNavigation(language: String, appearance: Appearance) {
        let app = launchApp(language: language, appearance: appearance)
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["section.overview"].waitForExistence(timeout: 5))

        if language == "ar" {
            XCTAssertTrue(app.staticTexts["التخزين"].exists)
            XCTAssertTrue(app.staticTexts["أدوات المطوّر"].exists)
        }
        assertAppearance(appearance, of: app)

        for section in allSections {
            open(section: section, in: app)
        }
    }

    /// Proves the forced appearance took effect: the window is clearly dark or clearly light.
    @MainActor
    private func assertAppearance(_ appearance: Appearance, of app: XCUIApplication) {
        app.activate()
        let window = app.windows.firstMatch
        guard let luminance = meanLuminance(of: window.screenshot()) else {
            return XCTFail("Could not read the window screenshot")
        }
        switch appearance {
        case .dark: XCTAssertLessThan(luminance, 0.35, "Window is not dark (mean luminance \(luminance))")
        case .light: XCTAssertGreaterThan(luminance, 0.6, "Window is not light (mean luminance \(luminance))")
        }
    }

    @MainActor
    func testPermissionsGuideAppearsOnFirstLaunchAndCanBeDismissed() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en", "-ApplePersistenceIgnoreState", "YES",
            "-ClenvraUITestMainDisplay", "YES",
            "-clenvra.permissionsGuideSeen", "NO",
        ]
        app.launch()
        defer { app.terminate() }
        let guide = app.descendants(matching: .any)["permissionsGuide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 3))
        app.buttons["guide.continue"].click()
        XCTAssertTrue(guide.waitForNonExistence(timeout: 3))
    }
}
