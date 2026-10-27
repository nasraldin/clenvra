import Foundation
import Security

/// Security, VPN and device-management agents Clenvra never removes itself (`safety-model.md` §1.7, S23).
///
/// Removing such an agent by moving files leaves kernel/system extensions and profiles behind and can lock the Mac
/// out of its organisation, so only the vendor's own uninstaller is offered.
public enum ManagedAgents {
    /// Bundle identifier owners (dotted-prefix match) of known security, VPN and MDM agents.
    public static let identifierPrefixes = [
        "com.microsoft.wdav", "com.microsoft.CompanyPortalMac", "com.crowdstrike", "com.sentinelone", "com.jamf",
        "com.jamfsoftware", "com.kandji", "io.kandji", "com.paloaltonetworks", "net.pulsesecure", "com.ivanti",
    ]

    /// Developer Team IDs of vendors whose apps are all agents (CrowdStrike, SentinelOne, Jamf, Palo Alto Networks).
    public static let teamIdentifiers: Set<String> = ["X9E956P446", "4AYE5J54KN", "483DWKW443", "PXPZ95SK77"]

    /// Whether the app (or any component inside it) belongs to a managed or security agent.
    public static func isManaged(_ app: InstalledApp, teamIdentifier: String?) -> Bool {
        if let teamIdentifier, teamIdentifiers.contains(teamIdentifier) { return true }
        return ([app.bundleIdentifier].compactMap { $0 } + app.embeddedBundleIdentifiers).contains(where: isManaged)
    }

    /// Whether a bundle identifier or launchd label belongs to a known managed or security agent.
    public static func isManaged(identifier: String) -> Bool {
        let identifier = identifier.lowercased()
        return identifierPrefixes.contains { prefix in
            let owner = prefix.lowercased()
            return identifier == owner || identifier.hasPrefix(owner + ".")
        }
    }

    /// The signing Team ID, so agents are recognised even under an unfamiliar bundle identifier.
    public static func teamIdentifier(of bundlePath: String) -> String? {
        let url = URL(filePath: bundlePath, directoryHint: .isDirectory)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
            let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The vendor's own `Uninstall….app`, inside the bundle or next to it in a vendor folder, if there is one.
    public static func vendorUninstaller(for app: InstalledApp) -> String? {
        let parent = (app.id as NSString).deletingLastPathComponent
        var folders = [app.id + "/Contents/Resources", app.id + "/Contents", app.id + "/Contents/Library"]
        if (parent as NSString).lastPathComponent != "Applications" { folders.append(parent) }
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            let match = names.sorted().first { name in
                let lowered = name.lowercased()
                return lowered.hasPrefix("uninstall") && lowered.hasSuffix(".app")
            }
            if let match { return folder + "/" + match }
        }
        return nil
    }
}
