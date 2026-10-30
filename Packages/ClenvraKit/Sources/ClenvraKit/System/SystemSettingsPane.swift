public import Foundation

/// Places in System Settings the app links to. macOS 13 and later name panes by their extension's bundle ID (the old
/// `com.apple.preference.*` names open the wrong place or nothing); the part after `?` selects the section.
public enum SystemSettingsPane: String, CaseIterable, Sendable {
    case fileVault, gatekeeper, firewall, softwareUpdate, fullDiskAccess

    public var url: URL {
        let target =
            switch self {
            case .fileVault: "com.apple.settings.PrivacySecurity.extension?FileVault"
            case .gatekeeper: "com.apple.settings.PrivacySecurity.extension?Security"
            // No anchor reaches the Firewall page (seven tried on macOS 26; the owner saw the same on 27): Network has it as a row.
            case .firewall: "com.apple.Network-Settings.extension"
            case .softwareUpdate: "com.apple.Software-Update-Settings.extension"
            case .fullDiskAccess: "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
            }
        // The strings above are fixed and valid; the fallback (Settings' main window) is never reached.
        return URL(string: "x-apple.systempreferences:" + target)
            ?? URL(filePath: "/System/Applications/System Settings.app")
    }

    /// Privacy & Security, at the section named by `anchor` (such as `Privacy_Camera`), or at its top without one.
    public static func privacy(anchor: String? = nil) -> URL {
        let target = "com.apple.settings.PrivacySecurity.extension" + (anchor.map { "?" + $0 } ?? "")
        return URL(string: "x-apple.systempreferences:" + target)
            ?? URL(filePath: "/System/Applications/System Settings.app")
    }
}
