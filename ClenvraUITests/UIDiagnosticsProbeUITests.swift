import XCTest

/// Diagnosis probe (opt-in, `CLENVRA_PROBE=1`): each test does one action and then fails on purpose, so Xcode keeps
/// the screen recording of the seconds around it.
final class UIDiagnosticsProbeUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CLENVRA_PROBE"] == nil, "Probe is opt-in")
    }

    @MainActor
    private func startApp() -> XCUIApplication {
        let app = launchApp(language: "en", appearance: .dark)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testDetailsPanel() {
        let app = startApp()
        open(section: "startup", in: app)
        sleep(3)
        app.toolbars.buttons["Show Details"].firstMatch.click()
        sleep(3)
        app.toolbars.buttons["Hide Details"].firstMatch.click()
        sleep(3)
        XCTFail("recording: details panel")
    }

    @MainActor
    func testRescan() {
        let app = startApp()
        open(section: "developer", in: app)
        scanAndWait(in: app)
        sleep(2)
        app.toolbars.buttons["Rescan"].firstMatch.click()
        sleep(1)
        scanAndWait(in: app)
        sleep(2)
        XCTFail("recording: rescan")
    }

    @MainActor
    func testDeveloperSwitch() {
        let app = startApp()
        open(section: "developer", in: app)
        scanAndWait(in: app)
        sleep(2)
        open(section: "developerTools", in: app)
        sleep(2)
        open(section: "developer", in: app)
        sleep(3)
        XCTFail("recording: developer")
    }

    /// Moving from Developer (two tabs) to Clutter (four) must not leave the switcher overlapping the page's buttons.
    @MainActor
    func testDeveloperToClutterToolbar() {
        let app = startApp()
        open(section: "developer", in: app)
        sleep(2)
        app.outlines.cells.containing(.any, identifier: "sidebar.largeFiles").firstMatch.click()
        sleep(3)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "developer-to-clutter"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
