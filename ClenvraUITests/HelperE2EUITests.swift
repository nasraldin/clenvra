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
        let toggle = settings.switches.matching(NSPredicate(format: "label CONTAINS[c] 'Clenvra'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "Clenvra is not listed under Allow in the Background")
        if (toggle.value as? Int) != 1 { toggle.click() }
        answerPasswordDialog(required: false)
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
        let row = app.tables.firstMatch.tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The seeded daemon is not listed")
        row.click()
        let disable = app.toolbars.buttons["Disable"].firstMatch
        XCTAssertTrue(disable.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilEnabled(disable), "Disable is not offered for the daemon")
        disable.click()
        answerPasswordDialog(required: true)
        XCTAssertTrue(
            app.staticTexts["Disabled"].firstMatch.waitForExistence(timeout: 30), "The daemon is not shown as disabled")
        attach(app.windows.firstMatch.screenshot(), "daemon-disabled")
    }

    /// Applications: check Writer, Uninstall Permanently without a backup; the helper asks for the password for its
    /// root-owned files and again to forget its installer record.
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

        // One dialog for the root-owned files, one for the installer record.
        answerPasswordDialog(required: true)
        answerPasswordDialog(required: false)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60), "No result after Uninstall")
        attach(app.windows.firstMatch.screenshot(), "uninstall-result")
        done.click()
    }

    // MARK: - Helpers

    /// Types the account's password into the macOS authorization dialog (SecurityAgent) when it appears.
    @MainActor
    private func answerPasswordDialog(required: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let agent = XCUIApplication(bundleIdentifier: "com.apple.SecurityAgent")
        let secure = agent.secureTextFields.firstMatch
        guard secure.waitForExistence(timeout: required ? 30 : 8) else {
            if required { XCTFail("No password dialog appeared", file: file, line: line) }
            return
        }
        attach(agent.screenshot(), "password-dialog")
        let user = agent.textFields.firstMatch
        if user.exists, (user.value as? String ?? "").isEmpty {
            user.click()
            user.typeText("admin")
        }
        secure.click()
        secure.typeText(password)
        agent.typeKey(.return, modifierFlags: [])
        // The dialog closes once accepted.
        let gone = NSPredicate(format: "exists == false")
        let closed = XCTNSPredicateExpectation(predicate: gone, object: secure)
        XCTAssertEqual(
            XCTWaiter.wait(for: [closed], timeout: 20), .completed, "The password was not accepted",
            file: file, line: line)
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
