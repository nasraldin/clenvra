import XCTest

final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language))", "-AppleLocale", language, "-ApplePersistenceIgnoreState", "YES",
            "-clenvra.permissionsGuideSeen", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    func testEverySidebarSectionOpensItsScreen() {
        let app = launch(language: "en")
        for section in [
            "overview", "storage", "duplicates", "cleanup", "developer", "applications", "startup", "system",
            "activity",
        ] {
            app.outlines.cells.containing(.any, identifier: "sidebar.\(section)").firstMatch.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["section.\(section)"].waitForExistence(timeout: 2),
                "Section \(section) did not appear")
        }
    }

    @MainActor
    func testPermissionsGuideAppearsOnFirstLaunchAndCanBeDismissed() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en", "-ApplePersistenceIgnoreState", "YES",
            "-clenvra.permissionsGuideSeen", "NO",
        ]
        app.launch()
        let guide = app.descendants(matching: .any)["permissionsGuide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 3))
        app.buttons["guide.continue"].click()
        XCTAssertTrue(guide.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testArabicShowsLocalizedSidebar() {
        let app = launch(language: "ar")
        XCTAssertTrue(app.staticTexts["التخزين"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["أدوات المطوّر"].exists)
    }
}
