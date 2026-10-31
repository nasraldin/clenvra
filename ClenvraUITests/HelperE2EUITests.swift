import XCTest

/// The privileged helper end to end, in the disposable VM of `scripts/e2e-helper.sh` only: the signed app in
/// /Applications installs the helper, the test approves it in System Settings, then disables a seeded Mac-wide
/// startup daemon and uninstalls a seeded package-installed app, answering each macOS password dialog with the VM
/// account's password. The script checks the result on disk.
final class HelperE2EUITests: XCTestCase {
    /// The test image's account (cirruslabs macOS images: admin / admin).
    private let password = "admin"

    override func setUpWithError() throws {
        // Changes the machine for real: never outside the throwaway VM.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLENVRA_HELPER_E2E"] == "1", "Helper E2E is opt-in")
        continueAfterFailure = false
    }

    @MainActor
    func testHelperEndToEnd() throws {
        let app = XCUIApplication(url: URL(filePath: "/Applications/Clenvra.app"))
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en", "-ApplePersistenceIgnoreState", "YES",
            "-ClenvraUITestMainDisplay", "YES", "-clenvra.permissionsGuideSeen", "YES",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["section.overview"].waitForExistence(timeout: 10))

        installHelper(in: app)
        disableDaemon(in: app)
        uninstallWriter(in: app)
    }

    // MARK: - Steps

    /// Settings › System Helper › Install, then the approval in System Settings › Login Items.
    @MainActor
    private func installHelper(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["System Helper"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "No System Helper tab in Settings")
        tab.click()
        let install = app.buttons["settings.helper.install"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 5), "No Install button")
        install.click()

        // Installing opens Login Items Settings; the helper waits there for approval.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 20), "System Settings did not open")
        // The switch has no name of its own: it is the one on the same row as the "Clenvra" title.
        let title = settings.staticTexts["Clenvra"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20), "Clenvra is not listed under App Background Activity")
        let row = title.frame.midY
        let toggle = settings.switches.allElementsBoundByIndex.first { abs($0.frame.midY - row) < 24 }
        XCTAssertNotNil(toggle, "No switch on Clenvra's row")
        if let toggle, (toggle.value as? Int) != 1 { toggle.click() }
        answerPasswordDialog()
        attach(settings.screenshot(), "login-items")
        settings.terminate()

        // Back in Clenvra: the helper answers once approved (the section checks again on appearing).
        app.activate()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["System Helper"].firstMatch.click()
        XCTAssertTrue(
            app.buttons["settings.helper.remove"].firstMatch.waitForExistence(timeout: 30),
            "The helper did not come up after approval")
        attach(app.windows.firstMatch.screenshot(), "helper-installed")
        app.typeKey("w", modifierFlags: .command)
    }

    /// Startup Items: select the seeded daemon and Disable it; the helper asks for the password.
    @MainActor
    private func disableDaemon(in app: XCUIApplication) {
        open(section: "startup", in: app)
        search("e2e", in: app)
        // Startup Items is a grouped list: the daemon's row is found by its name ("com.example.e2e.daemon").
        let row = app.staticTexts["Example E2e Daemon"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The seeded daemon is not listed")
        row.click()
        let disable = app.toolbars.buttons["Disable"].firstMatch
        XCTAssertTrue(disable.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilEnabled(disable), "Disable is not offered for the daemon")
        disable.click()
        answerPasswordDialog()
        XCTAssertTrue(
            app.staticTexts["Disabled"].firstMatch.waitForExistence(timeout: 30), "The daemon is not shown as disabled")
        // Clenvra confirms what happened in an alert; Return presses its OK (a query for "OK" also finds the
        // Touch Bar's copy, which cannot be clicked).
        let confirmation = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Disabled. It was stopped'"))
            .firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10), "No confirmation after Disable")
        attach(app.windows.firstMatch.screenshot(), "daemon-disabled")
        app.typeKey(.return, modifierFlags: [])
    }

    /// Applications: check Writer, Uninstall Permanently without a backup; the helper asks for the password once
    /// for its root-owned files and its installer record.
    @MainActor
    private func uninstallWriter(in app: XCUIApplication) {
        open(section: "applications", in: app)
        search("Writer", in: app)
        let check = app.checkBoxes["Check Writer"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 30), "Writer is not listed")
        check.click()
        app.buttons["applications.uninstall"].firstMatch.click()

        let confirm = app.buttons["Uninstall Permanently"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "No Uninstall confirmation")
        let backup = app.checkBoxes["Back up first"].firstMatch
        if backup.exists, (backup.value as? Int) == 1 { backup.click() }
        XCTAssertTrue(waitUntilEnabled(confirm), "Uninstall Permanently stays disabled")
        attach(app.windows.firstMatch.screenshot(), "uninstall-confirmation")
        confirm.click()

        // One password for the whole Uninstall: its root-owned files, its bundle and its installer record.
        answerPasswordDialog()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60), "No result after Uninstall")
        attach(app.windows.firstMatch.screenshot(), "uninstall-result")
        done.click()
    }

    // MARK: - Helpers

    /// Has the VM's password agent (`scripts/e2e/password-agent.swift`) answer the macOS password dialog. The
    /// dialog is hidden from UI automation and the runner has no Accessibility, so the test asks for the answer by
    /// posting the agent's notification. Each step then checks the outcome (helper up, item disabled, app gone).
    @MainActor
    private func answerPasswordDialog() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.nasraldin.clenvra.e2e.typePassword"), object: nil, userInfo: nil,
            deliverImmediately: true)
        Thread.sleep(forTimeInterval: 3)
        attach(XCUIScreen.main.screenshot(), "password-dialog")
        Thread.sleep(forTimeInterval: 5)
    }

    @MainActor
    private func search(_ text: String, in app: XCUIApplication) {
        let button = app.toolbars.buttons["page.search"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(text)
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [enabled], timeout: timeout) == .completed
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
