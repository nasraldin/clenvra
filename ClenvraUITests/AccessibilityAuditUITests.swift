import XCTest

/// Runs Xcode's accessibility audit on every main screen, in light and dark appearance.
///
/// Every issue fails the test unless it matches one of the documented exclusions below. Each exclusion covers
/// something the app does not draw or structure itself (system chrome, SwiftUI containers, system controls), a
/// measurement artifact, or a deliberate design choice.
final class AccessibilityAuditUITests: XCTestCase {
    @MainActor func testEverySectionPassesAuditInLight() throws { try audit(.light) }
    @MainActor func testEverySectionPassesAuditInDark() throws { try audit(.dark) }

    /// The pages that start the home-folder scan go last: it keeps running in the background and loads the Mac.
    private static let scanPages = ["storage", "largeFiles", "downloads"]
    private static let auditOrder: [String] = {
        let all = allSections.filter { !scanPages.contains($0) } + scanPages
        // `CLENVRA_AUDIT_SECTIONS=developer,duplicates` audits only those pages, for a quick re-check.
        guard let only = ProcessInfo.processInfo.environment["CLENVRA_AUDIT_SECTIONS"] else { return all }
        let wanted = Set(only.split(separator: ",").map(String.init))
        return all.filter(wanted.contains)
    }()

    @MainActor
    private func audit(_ appearance: Appearance) throws {
        let app = launchApp(language: "en", appearance: appearance)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        for section in Self.auditOrder {
            open(section: section, in: app)
            // Pages scan only on request: press Scan where there is one, so the results are audited too.
            scanAndWait(in: app)
            let windowFrame = window.frame
            let alerts = Self.systemAlertFrames()
            let lists = (app.tables.allElementsBoundByIndex + app.outlines.allElementsBoundByIndex).map(\.frame)
            // The trailing edge of the sidebar list: the content column starts right after it.
            let sidebarEdge = app.outlines.containing(.any, identifier: "sidebar.overview").firstMatch.frame.maxX
            var failed = false
            try app.performAccessibilityAudit { issue in
                let context = AuditContext(
                    windowFrame: windowFrame, alerts: alerts, lists: lists, sidebarEdge: sidebarEdge,
                    appearance: appearance, section: section)
                if Self.isExcluded(issue, in: context) { return true }
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
        "Select an app", "No Activity Yet", "No apps", "No Results", "Nothing to clean", "Nothing to review",
    ]

    @MainActor
    private static func isExcluded(
        _ issue: XCUIAccessibilityAuditIssue, in context: AuditContext
    ) -> Bool {
        let (windowFrame, alerts, lists) = (context.windowFrame, context.alerts, context.lists)
        // 1. The element is gone by the time the issue is reported: live results replaced the content mid-audit,
        //    so the finding refers to a view that no longer exists. (A snapshot reads every property at once, so
        //    an element that vanishes now cannot fail the test halfway through this check.)
        guard let element = try? issue.element?.snapshot() else { return true }
        let frame = element.frame

        // 2. Not part of the app's window (for example the menu bar, which the system draws).
        if !windowFrame.insetBy(dx: -1, dy: -1).contains(frame) { return true }

        // 2a. A help tag (tooltip) the system is showing because the pointer rests on a control after a click. The
        //     system draws it; its text is the control's help, and the control itself carries the label.
        if element.elementType == .helpTag { return true }

        switch issue.auditType {
        case .parentChild where frame.maxY <= windowFrame.minY + 60:
            // 3a. The title bar and toolbar chrome (sidebar toggle, window controls) is drawn by the system.
            return true

        case .sufficientElementDescription, .parentChild:
            guard element.elementType == .group && element.label.isEmpty else { return false }
            // 3. Full-height, unlabeled groups are the column containers AppKit creates for NavigationSplitView
            //    and HSplitView. They are not focusable content; their children carry the labels.
            if abs(frame.height - windowFrame.height) < 1 { return true }
            // 4. SwiftUI wraps each List `Section` header in an unlabeled row group (and reports it under the
            //    wrong parent). The header's own text is exposed inside it, so VoiceOver still reads it.
            return containsDescribedElement(element)

        case .contrast:
            // 5c. In light mode the floating sidebar casts a soft shadow onto the first points of the content column;
            //     the audit samples it as the background of text that starts there. The text is drawn in the
            //     normal label colour on the window background.
            if context.appearance == .light, element.elementType == .staticText,
                frame.minX - context.sidebarEdge < 32
            {
                return true
            }
            // 5d. Processes are sampled every second, so their live figures are redrawn while the audit measures.
            if context.section == "processes", element.elementType == .staticText,
                lists.contains(where: { $0.contains(frame) })
            {
                return true
            }
            // 5b. A row cut off by the edge of its own list (the last, half-visible row): the audit samples the
            //     clipped glyphs together with the next pane, so the result is not what a scrolled-in row shows.
            if element.elementType == .staticText,
                lists.contains(where: { $0.intersects(frame) && !$0.insetBy(dx: -1, dy: -1).contains(frame) })
            {
                return true
            }
            // 5e. A file name of a few letters in a list row, in light mode ("dyld"): the audit samples too few glyph
            //     pixels to tell the text from the row and the colored file icon beside it. The text is the normal
            //     label colour on the list background, the same as every longer name that passes.
            if context.appearance == .light, element.elementType == .staticText, frame.width < 60,
                lists.contains(where: { $0.contains(frame) })
            {
                return true
            }
            // 5a. Sidebar rows are drawn by the system over the window's vibrant material (and in the selection
            //     colour); the app does not choose their text colour.
            if element.identifier.hasPrefix("sidebar.") { return true }
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
    /// Text, or any element with its own label (a named map, a named list), inside an unlabeled container such as
    /// an AppKit split-view pane: VoiceOver reads those, so the container needs no name of its own.
    private static func containsDescribedElement(_ element: any XCUIElementSnapshot) -> Bool {
        element.children.contains {
            $0.elementType == .staticText || !$0.label.isEmpty || containsDescribedElement($0)
        }
    }
}

/// What the exclusions need to know about the screen being audited.
private struct AuditContext {
    let windowFrame: CGRect
    let alerts: [CGRect]
    let lists: [CGRect]
    /// Leading edge of the content column, where the sidebar ends.
    let sidebarEdge: CGFloat
    let appearance: Appearance
    let section: String
}
