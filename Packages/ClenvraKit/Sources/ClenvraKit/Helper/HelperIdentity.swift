import Foundation
import Security

/// Who may talk to whom over the helper's XPC connection. Both sides pin the other's code signature, so an ad-hoc
/// signed impostor using the right identifier is still rejected (safety case S25).
public enum HelperIdentity {
    public static let appIdentifier = "com.nasraldin.clenvra"
    public static let helperIdentifier = "com.nasraldin.clenvra.helper"
    /// The owner's personal Apple Developer team; both binaries must be signed by it.
    public static let teamIdentifier = "CZU6ZC4LYQ"
    /// The launchd Mach service the helper listens on.
    public static let machServiceName = helperIdentifier
    /// The launchd property list inside `Contents/Library/LaunchDaemons`, registered with `SMAppService.daemon`.
    public static let daemonPlistName = helperIdentifier + ".plist"
    /// Bumped whenever the XPC protocol changes, so an old installed helper is noticed and replaced.
    public static let protocolVersion = 1

    /// What the helper requires of a client: Clenvra, signed by the team, through an Apple-issued certificate.
    public static let clientRequirement = requirement(for: appIdentifier)
    /// What the app requires of the helper it connects to.
    public static let helperRequirement = requirement(for: helperIdentifier)

    private static func requirement(for identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Whether the code at `path` is validly signed and meets `requirement`.
    public static func satisfies(path: String, requirement: String) -> Bool {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled
        else { return false }
        return SecStaticCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}
