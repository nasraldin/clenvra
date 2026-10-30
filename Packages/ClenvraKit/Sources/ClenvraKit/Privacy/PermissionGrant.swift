public import Foundation

/// One row of macOS's privacy database: an app (or a program at a path) and the protected service it may use.
public struct PermissionGrant: Sendable, Hashable, Identifiable {
    /// Which privacy database the grant came from.
    public enum Scope: String, Sendable, Hashable {
        /// The person's own database (`~/Library/Application Support/com.apple.TCC/TCC.db`).
        case user
        /// The Mac's database, for every user (`/Library/Application Support/com.apple.TCC/TCC.db`).
        case system
    }

    /// The TCC service, such as `kTCCServiceCamera`.
    public let service: String
    /// A bundle ID, or an absolute path when `clientIsBundleID` is false.
    public let client: String
    public let clientIsBundleID: Bool
    /// Allowed or limited (Photos "limited access"); false when the person said no.
    public let isAllowed: Bool
    public let lastModified: Date?
    public let scope: Scope

    public var id: String { "\(scope.rawValue):\(service):\(client)" }

    public init(
        service: String, client: String, clientIsBundleID: Bool, isAllowed: Bool, lastModified: Date?, scope: Scope
    ) {
        self.service = service
        self.client = client
        self.clientIsBundleID = clientIsBundleID
        self.isAllowed = isAllowed
        self.lastModified = lastModified
        self.scope = scope
    }
}

/// Names, symbols and System Settings sections of the TCC services.
public enum PermissionService {
    private static let prefix = "kTCCService"

    /// The name without `kTCCService`; also what `tccutil` takes ("Camera").
    public static func shortName(_ service: String) -> String {
        service.hasPrefix(prefix) ? String(service.dropFirst(prefix.count)) : service
    }

    /// The name System Settings uses for the service; unknown services show their short name.
    public static func title(_ service: String) -> LocalizedStringResource {
        switch shortName(service) {
        case "Camera": "Camera"
        case "Microphone": "Microphone"
        case "ScreenCapture": "Screen & System Audio Recording"
        case "SystemPolicyAllFiles": "Full Disk Access"
        case "Accessibility": "Accessibility"
        case "ListenEvent": "Input Monitoring"
        case "PostEvent": "Control Input"
        case "AddressBook": "Contacts"
        case "Calendar": "Calendars"
        case "Reminders": "Reminders"
        case "Photos": "Photos"
        case "AppleEvents": "Automation"
        case "SystemPolicyDesktopFolder": "Desktop Folder"
        case "SystemPolicyDocumentsFolder": "Documents Folder"
        case "SystemPolicyDownloadsFolder": "Downloads Folder"
        default: "\(shortName(service))"
        }
    }

    /// An SF Symbol for the service.
    public static func symbol(_ service: String) -> String {
        switch shortName(service) {
        case "Camera": "camera"
        case "Microphone": "mic"
        case "ScreenCapture": "rectangle.dashed.badge.record"
        case "SystemPolicyAllFiles": "externaldrive"
        case "Accessibility": "accessibility"
        case "ListenEvent": "keyboard"
        case "PostEvent": "cursorarrow.click"
        case "AddressBook": "person.crop.circle"
        case "Calendar": "calendar"
        case "Reminders": "checklist"
        case "Photos": "photo"
        case "AppleEvents": "gearshape.2"
        case "SystemPolicyDesktopFolder": "menubar.dock.rectangle"
        case "SystemPolicyDocumentsFolder": "doc"
        case "SystemPolicyDownloadsFolder": "arrow.down.circle"
        default: "hand.raised"
        }
    }

    /// The section of Privacy & Security that lists the service, when System Settings has one.
    public static func anchor(_ service: String) -> String? {
        switch shortName(service) {
        case "Camera": "Privacy_Camera"
        case "Microphone": "Privacy_Microphone"
        case "ScreenCapture": "Privacy_ScreenCapture"
        case "SystemPolicyAllFiles": "Privacy_AllFiles"
        case "Accessibility": "Privacy_Accessibility"
        case "ListenEvent": "Privacy_ListenEvent"
        case "AppleEvents": "Privacy_Automation"
        case "Photos": "Privacy_Photos"
        case "AddressBook": "Privacy_Contacts"
        case "Calendar": "Privacy_Calendars"
        case "Reminders": "Privacy_Reminders"
        default: nil
        }
    }

    /// Where the person changes this permission themselves.
    public static func settingsURL(_ service: String) -> URL {
        SystemSettingsPane.privacy(anchor: anchor(service))
    }
}
