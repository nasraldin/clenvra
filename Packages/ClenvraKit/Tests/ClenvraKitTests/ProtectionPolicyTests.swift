import Testing

@testable import ClenvraKit

@Suite("ProtectionPolicy")
struct ProtectionPolicyTests {
    private let policy = ProtectionPolicy(home: "/Users/u")

    @Test(
        "system areas are protected, including case variants (safety case S7)",
        arguments: [
            "/System/Library/Caches/x", "/SYSTEM/Library", "/usr/lib/x", "/bin/ls", "/sbin/x",
            "/private/var/db/x", "/private/etc/hosts", "/Library/Apple/x", "/Library/Keychains/System.keychain",
            "/Library/Extensions/x.kext", "/Library/Managed Preferences/x.plist", "/private/var/root/x",
        ])
    func systemTrees(path: String) {
        #expect(policy.protection(for: path) == .system)
    }

    @Test(
        "important roots are protected themselves but their contents are not",
        arguments: [
            "/", "/Applications", "/Library", "/Library/Caches", "/Library/Application Support",
            "/Library/LaunchDaemons",
            "/Users", "/Volumes", "/private", "/private/var", "/private/tmp", "/opt", "/opt/homebrew", "/usr/local",
        ])
    func systemRoots(path: String) {
        #expect(policy.protection(for: path) == .system)
    }

    @Test("contents of ordinary roots are not protected by the root rule")
    func rootContents() {
        #expect(policy.protection(for: "/Library/Caches/com.vendor.app") == nil)
        #expect(policy.protection(for: "/Applications/Some.app") == nil)
    }

    @Test(
        "the home folder, macOS's own folders in it, and the direct children of ~/Library are protected",
        arguments: [
            "/Users/u", "/Users/u/Documents", "/Users/u/Library", "/Users/u/Desktop", "/Users/u/Downloads",
            "/Users/u/Movies", "/Users/u/Music", "/Users/u/Pictures", "/Users/u/Public", "/Users/u/Applications",
            "/Users/u/.Trash",
            "/Users/u/Library/Caches", "/Users/u/Library/Application Support", "/Users/u/Library/Containers",
            "/Users/u/.config", "/Users/u/.local", "/Users/u/.cache", "/USERS/U/documents",
        ])
    func homeRoots(path: String) {
        #expect(policy.protection(for: path) == .homeRoot)
    }

    @Test(
        "folders the person created at the top of the home folder can be reviewed and moved to the Trash",
        arguments: ["/Users/u/flutter", "/Users/u/android-sdk", "/Users/u/Sources", "/Users/u/.rbenv"])
    func ownTopLevelFolders(path: String) {
        #expect(policy.protection(for: path) == nil)
    }

    @Test("items inside home folders are not protected by the home rule")
    func homeContents() {
        #expect(policy.protection(for: "/Users/u/Library/Caches/com.vendor.app") == nil)
        #expect(policy.protection(for: "/Users/u/Downloads/installer.dmg") == nil)
        #expect(policy.protection(for: "/Users/u/.config/someapp") == nil)
    }

    @Test(
        "secrets and credentials are protected anywhere they are found",
        arguments: [
            "/Users/u/.ssh/config", "/Users/u/.gnupg/x", "/Users/u/.aws/credentials", "/Users/u/.kube/config",
            "/Users/u/Library/Keychains/login.keychain-db", "/Users/u/Downloads/id_ed25519",
            "/Users/u/Library/Caches/x/server.pem", "/Users/u/project/.env", "/Users/u/.npmrc", "/Users/u/.netrc",
            "/Users/u/Library/Caches/x/cert.p12", "/Users/u/old.keychain",
        ])
    func secrets(path: String) {
        #expect(policy.protection(for: path) == .secret)
    }

    @Test(
        "personal data stores are protected",
        arguments: [
            "/Users/u/Library/Mail/V10/x", "/Users/u/Library/Messages/chat.db",
            "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a.txt", "/Users/u/Library/CloudStorage/OneDrive/x",
            "/Users/u/Pictures/Photos Library.photoslibrary/database/x",
        ])
    func userData(path: String) {
        #expect(policy.protection(for: path) == .userData)
    }

    @Test("a folder that contains a protected location is itself protected")
    func ancestorsOfProtected() {
        #expect(policy.protection(for: "/Users/u/Library/Containers/com.x/Data/Library/Keychains") == nil)
        let custom = ProtectionPolicy(home: "/Users/u", additionalProtected: ["/Users/u/Library/Caches/keep/me"])
        #expect(custom.protection(for: "/Users/u/Library/Caches/keep") == .custom)
        #expect(custom.protection(for: "/Users/u/Library/Caches/keep/me/x") == .custom)
    }

    @Test("user exclusions protect a whole tree (safety case S18)")
    func exclusions() {
        let custom = ProtectionPolicy(home: "/Users/u", exclusions: ["/Users/u/Library/Caches/com.keep"])
        #expect(custom.protection(for: "/Users/u/Library/Caches/com.keep/data") == .excluded)
        #expect(custom.protection(for: "/Users/u/Library/Caches/com.other") == nil)
    }

    @Test("Unicode composition differences do not bypass protection")
    func unicodeNormalization() {
        let custom = ProtectionPolicy(home: "/Users/u", exclusions: ["/Users/u/Caf\u{E9}"])
        #expect(custom.protection(for: "/Users/u/Cafe\u{301}/x") == .excluded)
    }

    @Test("invalid paths are protected by default")
    func invalid() {
        #expect(policy.protection(for: "relative/path") == .invalid)
        #expect(policy.protection(for: "/Users/u/../etc") == .invalid)
    }
}
