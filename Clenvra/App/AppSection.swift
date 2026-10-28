import SwiftUI

/// Every page in the sidebar, in display order. Pages that used to be tabs inside a section are pages of their own,
/// so the sidebar shows every place in the app (two levels: group, then page).
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case cleanup
    case developer
    case developerTools
    case largeFiles
    case downloads
    case duplicates
    case similarPhotos
    case storage
    case applications
    case leftovers
    case extensions
    case startup
    case system
    case processes
    case security
    case snapshots
    case activity

    var id: Self { self }

    /// Sidebar groups. Overview stands alone at the top, without a header.
    enum Group: CaseIterable {
        case summary, cleanUp, storage, applications, system, history

        var title: LocalizedStringResource? {
            switch self {
            case .summary: nil
            case .cleanUp: "Clean Up"
            case .storage: "Storage"
            case .applications: "Applications"
            case .system: "System"
            case .history: "History"
            }
        }
    }

    var group: Group {
        switch self {
        case .overview: .summary
        case .cleanup, .developer, .developerTools, .largeFiles, .downloads, .duplicates, .similarPhotos: .cleanUp
        case .storage: .storage
        case .applications, .leftovers, .extensions, .startup: .applications
        case .system, .processes, .security, .snapshots: .system
        case .activity: .history
        }
    }

    /// The page name: shown in the sidebar and as the window title.
    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .cleanup: "System Junk"
        case .developer: "Developer Junk"
        case .developerTools: "Developer Tools"
        case .largeFiles: "Large & Old Files"
        case .downloads: "Downloads"
        case .duplicates: "Duplicates"
        case .similarPhotos: "Similar Photos"
        case .storage: "Space Map"
        case .applications: "Applications"
        case .leftovers: "Leftovers"
        case .extensions: "Extensions"
        case .startup: "Startup Items"
        case .system: "Health"
        case .processes: "Processes"
        case .security: "Security"
        case .snapshots: "Snapshots"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cleanup: "sparkles"
        case .developer: "hammer"
        case .developerTools: "terminal"
        case .largeFiles: "doc.badge.clock"
        case .downloads: "arrow.down.circle"
        case .duplicates: "plus.square.on.square"
        case .similarPhotos: "photo.on.rectangle.angled"
        case .storage: "chart.pie"
        case .applications: "square.grid.2x2"
        case .leftovers: "tray.full"
        case .extensions: "puzzlepiece.extension"
        case .startup: "power"
        case .system: "heart.text.square"
        case .processes: "cpu"
        case .security: "lock.shield"
        case .snapshots: "clock.badge.checkmark"
        case .activity: "clock.arrow.circlepath"
        }
    }

    /// ⌘1…⌘9 for the most used pages; the others are in the Go menu without a number.
    var shortcut: KeyEquivalent? {
        switch self {
        case .overview: "1"
        case .cleanup: "2"
        case .developer: "3"
        case .largeFiles: "4"
        case .duplicates: "5"
        case .storage: "6"
        case .applications: "7"
        case .startup: "8"
        case .activity: "9"
        default: nil
        }
    }
}
