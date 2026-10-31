import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// The helper's Mac-wide startup and permission operations: only validated input, only allowlisted launch folders,
/// the plist exactly as reviewed, and the administrator's password (a fake authorizer here) before anything runs.
/// A temporary folder stands in for the system root; `launchctl` and `tccutil` are scripted, never run.
/// How often the helper asked for authorization.
private final class AuthorizationCounter: Sendable {
    let count = Mutex(0)
}

@Suite("Helper service: startup items and permissions")
struct HelperServiceTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let runner = FakeCommandRunner()
    private let authorizations = AuthorizationCounter()

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("home/.Trash")
        try fixture.directory("staging")
    }

    private var system: String { String(scratch.url.path(percentEncoded: false).dropLast()) + "/system" }
    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) + "/home" }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func service(authorized: Bool = true) -> HelperService {
        let authorizations = authorizations
        return HelperService(
            allowlist: HelperAllowlist(systemRoot: system), clientHome: home, clientUID: 501,
            log: ActivityLog(directory: fixture.url("helper-log")), staging: path("staging"), processPaths: { [] },
            runner: runner,
            authorize: { _ in
                authorizations.count.withLock { $0 += 1 }
                return authorized
            })
    }

    private func launchItem(_ relative: String, label: String, root: String) throws -> DeletionItem {
        try fixture.directory((relative as NSString).deletingLastPathComponent)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "Program": "/usr/local/bin/vendord"], format: .xml, options: 0)
        try data.write(to: fixture.url(relative))
        return DeletionItem(
            path: path(relative), ruleRoot: root, expected: try SafeWalk.resolve(path(relative)).snapshot,
            ownerBundleID: nil, freedBytes: 0, section: .startup)
    }

    // MARK: - Startup items

    @Test("a Mac-wide daemon is disabled in the system domain only after authorization")
    func disableSystemDaemon() async throws {
        let item = try launchItem(
            "system/Library/LaunchDaemons/com.vendor.d.plist", label: "com.vendor.d",
            root: system + "/Library/LaunchDaemons")
        runner.stub("/bin/launchctl", ["bootout", "system", item.path])
        runner.stub("/bin/launchctl", ["disable", "system/com.vendor.d"])
        runner.stub("/bin/launchctl", ["enable", "system/com.vendor.d"])
        runner.stub("/bin/launchctl", ["bootstrap", "system", item.path])

        #expect(await service().setLaunchItemEnabled(item, enabled: false, authorization: nil) == .done)
        #expect(await service().setLaunchItemEnabled(item, enabled: true, authorization: nil) == .done)

        #expect(
            runner.commands.map(\.arguments) == [
                ["bootout", "system", item.path], ["disable", "system/com.vendor.d"],
                ["enable", "system/com.vendor.d"], ["bootstrap", "system", item.path],
            ])
        #expect(authorizations.count.withLock { $0 } == 2)
        #expect(FileManager.default.fileExists(atPath: item.path))
    }

    @Test("a Mac-wide agent is changed in the requesting user's login domain")
    func disableSystemAgent() async throws {
        let item = try launchItem(
            "system/Library/LaunchAgents/com.vendor.a.plist", label: "com.vendor.a",
            root: system + "/Library/LaunchAgents")
        runner.stub("/bin/launchctl", ["bootout", "gui/501", item.path])
        runner.stub("/bin/launchctl", ["disable", "gui/501/com.vendor.a"])

        #expect(await service().setLaunchItemEnabled(item, enabled: false, authorization: nil) == .done)
        #expect(runner.commands.map(\.arguments).last == ["disable", "gui/501/com.vendor.a"])
    }

    @Test("without the administrator's authorization nothing runs")
    func notAuthorizedRunsNothing() async throws {
        let item = try launchItem(
            "system/Library/LaunchDaemons/com.vendor.d.plist", label: "com.vendor.d",
            root: system + "/Library/LaunchDaemons")

        #expect(
            await service(authorized: false).setLaunchItemEnabled(item, enabled: false, authorization: nil)
                == .notAuthorized)
        #expect(runner.commands.isEmpty)
    }

    @Test("plists outside /Library/LaunchAgents and /Library/LaunchDaemons are refused before authorization")
    func rejectsPlistOutsideLaunchFolders() async throws {
        let caches = try launchItem(
            "system/Library/Caches/com.vendor.d.plist", label: "com.vendor.d", root: system + "/Library/Caches")
        let nested = try launchItem(
            "system/Library/LaunchDaemons/sub/com.vendor.d.plist", label: "com.vendor.d",
            root: system + "/Library/LaunchDaemons")
        let userAgent = try launchItem(
            "home/Library/LaunchAgents/com.vendor.d.plist", label: "com.vendor.d", root: home + "/Library/LaunchAgents")
        let service = service()

        for item in [caches, nested, userAgent] {
            #expect(await service.setLaunchItemEnabled(item, enabled: false, authorization: nil) == .refused)
        }
        #expect(runner.commands.isEmpty)
        #expect(authorizations.count.withLock { $0 } == 0)
    }

    @Test("Apple's own and managed-software items are refused")
    func rejectsAppleAndManagedLabels() async throws {
        let apple = try launchItem(
            "system/Library/LaunchDaemons/com.apple.thing.plist", label: "com.apple.thing",
            root: system + "/Library/LaunchDaemons")
        let managed = try launchItem(
            "system/Library/LaunchDaemons/com.microsoft.wdav.daemon.plist", label: "com.microsoft.wdav.daemon",
            root: system + "/Library/LaunchDaemons")
        let service = service()

        #expect(await service.setLaunchItemEnabled(apple, enabled: false, authorization: nil) == .refused)
        #expect(await service.setLaunchItemEnabled(managed, enabled: false, authorization: nil) == .refused)
        #expect(runner.commands.isEmpty)
    }

    @Test("a plist that changed since review is refused by the helper too")
    func changedPlistRefusedByHelper() async throws {
        let item = try launchItem(
            "system/Library/LaunchDaemons/com.vendor.d.plist", label: "com.vendor.d",
            root: system + "/Library/LaunchDaemons")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.vendor.d", "Program": "/usr/local/bin/something-else-entirely"],
            format: .xml, options: 0)
        try data.write(to: URL(filePath: item.path))

        #expect(await service().setLaunchItemEnabled(item, enabled: false, authorization: nil) == .changedSinceReview)
        #expect(runner.commands.isEmpty)
    }

    // MARK: - Installer records

    @Test("an installer record is forgotten with pkgutil as root, after authorization")
    func forgetPackageRunsPkgutil() async {
        runner.stub("/usr/sbin/pkgutil", ["--forget", "com.vendor.writer.pkg"])

        let result = await service().forgetPackage(id: "com.vendor.writer.pkg", authorization: nil)

        #expect(result == .forgotten)
        #expect(runner.commands.map(\.arguments) == [["--forget", "com.vendor.writer.pkg"]])
        #expect(authorizations.count.withLock { $0 } == 1)
    }

    @Test("Apple's records and malformed IDs are refused before authorization; no password, nothing runs")
    func forgetPackageRefuses() async {
        for id in [
            "com.apple.pkg.Safari", "COM.APPLE.x", "", "-x", "a b", "x;rm", "../x", String(repeating: "a", count: 300),
        ] {
            #expect(await service().forgetPackage(id: id, authorization: nil) == .invalid)
        }
        #expect(authorizations.count.withLock { $0 } == 0)
        #expect(
            await service(authorized: false).forgetPackage(id: "com.vendor.x", authorization: nil) == .notAuthorized)
        #expect(runner.commands.isEmpty)
    }

    // MARK: - Permissions

    @Test("a permission for all users is reset with tccutil as root, after authorization")
    func resetPermissionRunsTccutil() async {
        runner.stub("/usr/bin/tccutil", ["reset", "ScreenCapture", "com.obsproject.obs-studio"])

        let result = await service().resetPermission(
            service: "kTCCServiceScreenCapture", bundleID: "com.obsproject.obs-studio", authorization: nil)

        #expect(result == .reset)
        #expect(runner.commands.map(\.arguments) == [["reset", "ScreenCapture", "com.obsproject.obs-studio"]])
        #expect(authorizations.count.withLock { $0 } == 1)
    }

    @Test("unknown services and malformed bundle IDs are refused before authorization")
    func rejectsUnknownService() async {
        let service = service()

        #expect(await service.resetPermission(service: "Liverpool", bundleID: "com.x", authorization: nil) == .invalid)
        #expect(await service.resetPermission(service: "All", bundleID: "com.x", authorization: nil) == .invalid)
        for bundleID in ["", "-com.x", "com.x; rm", "com x", "../etc", String(repeating: "a", count: 300)] {
            #expect(
                await service.resetPermission(service: "Camera", bundleID: bundleID, authorization: nil) == .invalid)
        }
        #expect(runner.commands.isEmpty)
        #expect(authorizations.count.withLock { $0 } == 0)
    }

    @Test("without authorization no permission is reset")
    func resetNotAuthorized() async {
        #expect(
            await service(authorized: false).resetPermission(service: "Camera", bundleID: "com.x", authorization: nil)
                == .notAuthorized)
        #expect(runner.commands.isEmpty)
    }

    @Test("the authorization right asks for an administrator's password every time")
    func rightIsNeverShared() {
        let rule = HelperRight.definition
        #expect(rule["timeout"] as? Int == 0)
        #expect(rule["shared"] as? Bool == false)
        #expect(rule["group"] as? String == "admin")
        #expect(rule["authenticate-user"] as? Bool == true)
        #expect(HelperIdentity.protocolVersion == 3)
    }
}
