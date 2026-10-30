import AppKit
import XCTest

/// The sidebar pages in display order, as their `sidebar.<id>` / `section.<id>` identifiers.
let allSections = [
    "overview", "cleanup", "developer", "developerTools", "largeFiles", "downloads", "duplicates", "similarPhotos",
    "storage", "disks",
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
    app.launch()
    return app
}

/// Pages that share one sidebar row: the row, and the page's position in the switcher at the top of the page.
let switcherPages: [String: (row: String, index: Int)] = [
    "developer": ("developer", 0), "developerTools": ("developer", 1),
    "largeFiles": ("largeFiles", 0), "downloads": ("largeFiles", 1), "duplicates": ("largeFiles", 2),
    "similarPhotos": ("largeFiles", 3),
]

@MainActor
func open(section: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let place = switcherPages[section]
    app.outlines.cells.containing(.any, identifier: "sidebar.\(place?.row ?? section)").firstMatch.click()
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
