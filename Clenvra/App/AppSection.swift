import SwiftUI

/// The sidebar sections, in display order. Grouping drives the sidebar dividers.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case storage
    case duplicates
    case cleanup
    case developer
    case applications
    case startup
    case system
    case activity

    var id: Self { self }

    enum Group: CaseIterable {
        case summary, tools, history
    }

    var group: Group {
        switch self {
        case .overview: .summary
        case .storage, .duplicates, .cleanup, .developer, .applications, .startup, .system: .tools
        case .activity: .history
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .storage: "Storage"
        case .duplicates: "Duplicates"
        case .cleanup: "Cleanup"
        case .developer: "Developer"
        case .applications: "Applications"
        case .startup: "Startup"
        case .system: "System"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .storage: "internaldrive"
        case .duplicates: "doc.on.doc"
        case .cleanup: "sparkles"
        case .developer: "hammer"
        case .applications: "app.badge"
        case .startup: "power"
        case .system: "cpu"
        case .activity: "clock.arrow.circlepath"
        }
    }

    /// ⌘1…⌘7 for the main sections; Activity has no number shortcut.
    var shortcut: KeyEquivalent? {
        switch self {
        case .overview: "1"
        case .storage: "2"
        case .cleanup: "3"
        case .developer: "4"
        case .applications: "5"
        case .startup: "6"
        case .system: "7"
        case .duplicates, .activity: nil
        }
    }
}
