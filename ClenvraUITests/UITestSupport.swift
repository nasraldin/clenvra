import AppKit
import XCTest

/// The sidebar pages in display order, as their `sidebar.<id>` / `section.<id>` identifiers.
let allSections = [
    "overview", "cleanup", "developer", "developerTools", "largeFiles", "downloads", "duplicates", "similarPhotos",
    "otherClutter", "recentItems", "appRecentItems", "storage", "disks",
    "applications", "leftovers", "extensions", "startup", "system", "processes", "security", "permissions", "snapshots",
    "activity",
]

enum Appearance: String, CaseIterable {
    case light, dark
}

/// Launches the app in a given language and appearance, independent of the Mac's own settings.
///
/// Appearance is forced with `-ClenvraUITestAppearance`, which the debug app applies as its preferred color
/// scheme. (`-AppleInterfaceStyle` in the argument domain does not work: AppKit keeps the system appearance.)
@MainActor
func launchApp(language: String, appearance: Appearance = .light, arguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += arguments
    app.launchArguments += [
        "-AppleLanguages", "(\(language))", "-AppleLocale", language, "-ApplePersistenceIgnoreState", "YES",
        "-ClenvraUITestMainDisplay", "YES",
        "-clenvra.permissionsGuideSeen", "YES",
        "-ClenvraUITestAppearance", appearance.rawValue,
    ]
    if language == "ar" {
        // What Xcode's right-to-left run option passes, so the layout mirrors as on an Arabic system.
        app.launchArguments += ["-NSForceRightToLeftWritingDirection", "YES", "-AppleTextDirection", "YES"]
    }
    // In the test VM only: banners macOS posts (such as "Quick Look Previewer Extensions Added" while Xcode registers
    // its apps) stay over the top of the window until closed.
    if ProcessInfo.processInfo.environment["CLENVRA_VM"] != nil { closeNotificationBanners() }
    // Windows other apps left open (Finder reopens its windows) must not cover the app or the audit measures them.
    for other in NSWorkspace.shared.runningApplications
    where other.activationPolicy == .regular && other.bundleIdentifier != Bundle.main.bundleIdentifier {
        other.hide()
    }
    app.launch()
    return app
}

/// Closes notification banners with Notification Center's own Close button (shown under the pointer), as a person
/// would.
@MainActor
private func closeNotificationBanners() {
    let center = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
    let banners = center.dialogs.scrollViews.groups.matching(NSPredicate(format: "label != ''"))
    for _ in 0..<5 {
        let banner = banners.firstMatch
        guard banner.waitForExistence(timeout: 1) else { return }
        banner.hover()
        let close = center.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Clear"])).firstMatch
        if close.waitForExistence(timeout: 2) {
            close.click()
        } else {
            XCTContext.runActivity(named: "Notification Center") { activity in
                let tree = XCTAttachment(string: center.debugDescription)
                tree.lifetime = .keepAlways
                activity.add(tree)
            }
            return
        }
        _ = banner.waitForNonExistence(timeout: 2)
    }
}

/// Pages that share one sidebar row: the row, and the page's position in the switcher at the top of the page.
let switcherPages: [String: (row: String, index: Int)] = [
    "developer": ("developer", 0), "developerTools": ("developer", 1),
    "largeFiles": ("largeFiles", 0), "downloads": ("largeFiles", 1), "duplicates": ("largeFiles", 2),
    "similarPhotos": ("largeFiles", 3), "otherClutter": ("largeFiles", 4),
    "recentItems": ("recentItems", 0), "appRecentItems": ("recentItems", 1),
]

@MainActor
func open(section: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let place = switcherPages[section]
    let row = app.outlines.cells.containing(.any, identifier: "sidebar.\(place?.row ?? section)").firstMatch
    // With the sidebar as a strip of icons, each page is a button instead of a list row.
    if row.exists {
        row.click()
    } else {
        app.buttons["sidebar.\(place?.row ?? section)"].firstMatch.click()
    }
    if let place {
        let switcher = app.descendants(matching: .any).matching(identifier: "page.switcher").firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "No page switcher for \(section)", file: file, line: line)
        let segments = switcher.descendants(matching: .radioButton)
        let segment =
            segments.count > place.index
            ? segments.element(boundBy: place.index)
            : switcher.descendants(matching: .button).element(boundBy: place.index)
        segment.click()
    }
    XCTAssertTrue(
        app.descendants(matching: .any)["section.\(section)"].waitForExistence(timeout: 5),
        "Section \(section) did not appear", file: file, line: line)
}

/// Mean relative luminance (0 black … 1 white) of a screenshot, sampled down to a small grid.
@MainActor
func meanLuminance(of screenshot: XCUIScreenshot) -> Double? {
    guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let side = 64
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard
            let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return true
    }
    guard drawn else { return nil }
    var total = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let red = Double(pixels[index])
        let green = Double(pixels[index + 1])
        let blue = Double(pixels[index + 2])
        total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
    return total / Double(side * side) / 255
}

/// Pages scan only when asked: press the page's Scan button if it shows one, then wait for the results to settle.
@MainActor
func scanAndWait(in app: XCUIApplication, timeout: TimeInterval = 90) {
    let scan = app.buttons["review.scan"]
    let scanned = scan.waitForExistence(timeout: 2)
    if scanned { scan.click() }
    // Pages without a Scan button show their content at once.
    _ = app.descendants(matching: .any)["review.results"].waitForExistence(timeout: scanned ? timeout : 5)
    let scanning = app.descendants(matching: .any)["review.scanning"]
    let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: scanning)
    _ = XCTWaiter.wait(for: [finished], timeout: timeout)
}
