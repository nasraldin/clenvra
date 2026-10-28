import XCTest

/// Runs Xcode's accessibility audit on every main screen, in light and dark appearance.
///
/// Every issue fails the test unless it matches one of the documented exclusions below. Each exclusion covers
/// something the app does not draw or structure itself (system chrome, SwiftUI containers, system controls), a
/// measurement artifact, or a deliberate design choice.
final class AccessibilityAuditUITests: XCTestCase {
    @MainActor func testEverySectionPassesAuditInLight() throws { try audit(.light) }
    @MainActor func testEverySectionPassesAuditInDark() throws { try audit(.dark) }

    /// Storage goes last: its home-folder scan keeps running in the background and loads the Mac.
    private static let auditOrder = allSections.filter { $0 != "storage" } + ["storage"]
    /// Sections whose read-only scan starts on open; they are audited once results are shown.
    private static let scanningSections: Set<String> = ["cleanup", "developer", "startup"]

    @MainActor
    private func audit(_ appearance: Appearance) throws {
        let app = launchApp(language: "en", appearance: appearance)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        for section in Self.auditOrder {
            open(section: section, in: app)
            if Self.scanningSections.contains(section) { waitForScan(in: app) }
            let windowFrame = window.frame
            let alerts = Self.systemAlertFrames()
            var failed = false
            try app.performAccessibilityAudit { issue in
                if Self.isExcluded(issue, windowFrame: windowFrame, alerts: alerts) { return true }
                failed = true
                let element = issue.element
                XCTFail(
                    "[\(appearance)/\(section)] \(issue.compactDescription): \(issue.detailedDescription) "
                        + "(identifier: \(element?.identifier ?? "-"), type: \(element?.elementType.rawValue ?? 0), "
                        + "frame: \(element?.frame ?? .zero), system prompts: \(alerts))")
                return true
            }
            if failed {
                // The screen as audited, to locate the reported frames.
                let attachment = XCTAttachment(screenshot: window.screenshot())
                attachment.name = "audit-\(appearance)-\(section)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    private func waitForScan(in app: XCUIApplication) {
        _ = app.descendants(matching: .any)["review.results"].waitForExistence(timeout: 90)
        let scanning = app.descendants(matching: .any)["review.scanning"]
        let finished = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: scanning)
        _ = XCTWaiter.wait(for: [finished], timeout: 90)
    }

    /// Frames of system permission prompts currently on screen (macOS shows them from UserNotificationCenter).
    @MainActor
    private static func systemAlertFrames() -> [CGRect] {
        let center = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        guard center.state != .notRunning && center.state != .unknown else { return [] }
        return center.windows.allElementsBoundByIndex.map(\.frame)
            + center.dialogs.allElementsBoundByIndex.map(\.frame)
    }

    /// Titles of SwiftUI `ContentUnavailableView` empty states reached by the audit.
    private static let emptyStateTitles: Set<String> = [
        "Select an app", "No Activity Yet", "No apps", "No Results", "Nothing to clean",
    ]

    @MainActor
    private static func isExcluded(
        _ issue: XCUIAccessibilityAuditIssue, windowFrame: CGRect, alerts: [CGRect]
    ) -> Bool {
        // 1. The element is gone by the time the issue is reported: live results replaced the content mid-audit,
        //    so the finding refers to a view that no longer exists. (A snapshot reads every property at once, so
        //    an element that vanishes now cannot fail the test halfway through this check.)
        guard let element = try? issue.element?.snapshot() else { return true }
        let frame = element.frame

        // 2. Not part of the app's window (for example the menu bar, which the system draws).
        if !windowFrame.insetBy(dx: -1, dy: -1).contains(frame) { return true }

        switch issue.auditType {
        case .sufficientElementDescription, .parentChild:
            guard element.elementType == .group && element.label.isEmpty else { return false }
            // 3. Full-height, unlabeled groups are the column containers AppKit creates for NavigationSplitView
            //    and HSplitView. They are not focusable content; their children carry the labels.
            if abs(frame.height - windowFrame.height) < 1 { return true }
            // 4. SwiftUI wraps each List `Section` header in an unlabeled row group (and reports it under the
            //    wrong parent). The header's own text is exposed inside it, so VoiceOver still reads it.
            return containsText(element)

        case .contrast:
            // 5. The navigation title is drawn by the system in the Liquid Glass toolbar, over whatever scrolls
            //    beneath it; the app does not choose its color.
            if element.elementType == .staticText && frame.maxY <= windowFrame.minY + 60 { return true }
            // 6. The bottom status bar uses the translucent `.bar` material; the audit samples the blurred rows
            //    scrolling beneath it, so text in or partly under that band gives results that change run to run.
            if element.elementType == .staticText && frame.maxY >= windowFrame.maxY - 36 { return true }
            // 7. "Nearly passed" means the text meets the 3:1 large-text ratio but not 4.5:1. This is the system
            //    `.secondary` label color (and sidebar vibrancy), used on purpose for supporting text; macOS raises
            //    it when Increase Contrast is on. Switching all secondary text to primary would be a design change.
            if issue.compactDescription == "Contrast nearly passed" { return true }
            // 8. A system permission prompt (for example "access files in your Desktop folder", raised when a
            //    freshly signed test build scans the home folder) covers part of the window and takes key focus, so
            //    the window draws in its dimmed, inactive state. Contrast measured then is not what users see.
            //    The other audit types still run.
            if !alerts.isEmpty { return true }
            // 9. ContentUnavailableView merges its large tertiary symbol into the title element, and the symbol's
            //    color is the system's.
            return emptyStateTitles.contains { issue.detailedDescription.hasSuffix(" \($0)") }

        case .action:
            // 10. Pop-up buttons and menu buttons (SwiftUI Picker with menu style, Menu) open with AXShowMenu, not
            //     AXPress; VoiceOver and Full Keyboard Access operate them normally.
            return element.elementType == .popUpButton || element.elementType == .menuButton

        default:
            return false
        }
    }

    @MainActor
    private static func containsText(_ element: any XCUIElementSnapshot) -> Bool {
        element.children.contains { $0.elementType == .staticText || containsText($0) }
    }
}
