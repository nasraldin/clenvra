import Foundation
import Testing

@testable import ClenvraKit

/// The Security page's "Open System Settings" buttons must open a pane this macOS has.
@Suite("System Settings panes")
struct SystemSettingsPaneTests {
    /// Bundle IDs of the System Settings panes installed on this Mac.
    private static let installedPanes: Set<String> = {
        let folder = URL(filePath: "/System/Library/ExtensionKit/Extensions")
        let extensions =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Set(extensions.compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()

    @Test("every link names an installed pane", arguments: SystemSettingsPane.allCases)
    func installed(pane: SystemSettingsPane) throws {
        let url = pane.url
        #expect(url.scheme == "x-apple.systempreferences")
        let id = try #require(url.absoluteString.split(separator: ":").last?.split(separator: "?").first)
        #expect(Self.installedPanes.contains(String(id)), "\(id) is not a System Settings pane on this Mac")
    }

    @Test("permission links open the Privacy & Security pane at the service's section")
    func privacyAnchorsUsePrivacyPane() throws {
        #expect(
            SystemSettingsPane.privacy(anchor: "Privacy_Camera").absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera")
        #expect(
            SystemSettingsPane.privacy().absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        #expect(
            PermissionService.settingsURL("kTCCServiceSomethingNew") == SystemSettingsPane.privacy())
        #expect(
            PermissionService.settingsURL("kTCCServiceMicrophone")
                == SystemSettingsPane.privacy(anchor: "Privacy_Microphone"))
        let id = try #require(
            SystemSettingsPane.privacy(anchor: "Privacy_Camera").absoluteString.split(separator: ":").last?
                .split(separator: "?").first)
        #expect(Self.installedPanes.contains(String(id)))
    }

    @Test("security checks link to their panes")
    func checks() {
        #expect(
            SecurityChecker.parseFirewall(output: "disabled", exitStatus: 0).settingsURL
                == SystemSettingsPane.firewall.url)
        #expect(
            SecurityChecker.parseSecurityUpdates(critical: false, config: false).settingsURL
                == SystemSettingsPane.softwareUpdate.url)
    }
}
