import Darwin
import Foundation
import Testing

@testable import ClenvraKit

/// Runs the real `HelperService` in-process, standing in for the installed helper.
struct InProcessHelper: PrivilegedOperations {
    let service: HelperService

    func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse {
        await service.perform(request)
    }

    func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError? {
        await service.restore(record)
    }

    func removeOrphanedLaunchItem(_ item: DeletionItem, operationID: UUID) async throws(HelperClientError)
        -> ActivityRecord.Outcome
    {
        await service.removeOrphanedLaunchItem(item, operationID: operationID)
    }

    func deleteLocalSnapshot(date: String) async throws(HelperClientError) -> SnapshotDeletion {
        await service.deleteLocalSnapshot(date: date)
    }
}

/// System-level cleanup (M13): items outside the home folder go through the privileged helper, and only when it is
/// installed. A temporary folder stands in for the system root and the home folder.
@MainActor
@Suite("System-level cleanup through the helper")
struct PrivilegedCleanupTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("home/.Trash")
        try fixture.directory("staging")
        try fixture.file("system/Library/Caches/com.vendor.daemon/blob", bytes: 40_000)
        try fixture.file("system/Library/Logs/Vendor/old.log", bytes: 30_000)
        try fixture.setModificationDate("system/Library/Logs/Vendor/old.log", Date(timeIntervalSinceNow: -30 * 86_400))
        try fixture.file("home/Library/Caches/com.vendor.app/blob", bytes: 10_000)
    }

    private var root: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private var home: String { root + "/home" }
    private var system: String { root + "/system" }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private var activityLog: ActivityLog { ActivityLog(directory: fixture.url("user-log")) }

    private var helper: InProcessHelper {
        InProcessHelper(
            service: HelperService(
                allowlist: HelperAllowlist(systemRoot: system), clientHome: home, clientUID: getuid(),
                log: ActivityLog(directory: fixture.url("helper-log")), staging: path("staging"), processPaths: { [] }))
    }

    /// The system rules of the real catalog, re-rooted into the fixture.
    private var rules: [CleanupRule] {
        RuleCatalog.system(root: system) + RuleCatalog.standard.filter { $0.id == "caches.user" }
    }

    private func session(privileged: (any PrivilegedOperations)?, helperAvailable: Bool) -> CleanupSession {
        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { _ in .notRunning }
        let session = CleanupSession(
            rules: rules, section: .cleanup, home: home, policy: policy, ownerState: ownerState,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState), log: activityLog,
                trash: UserTrash(home: home, uid: getuid())),
            privileged: privileged,
            ownerBundlePath: { $0 == "com.vendor.daemon" ? "/Applications/Vendor.app" : nil })
        session.helperAvailable = helperAvailable
        return session
    }

    @Test("system caches and logs are shown, but need the helper; without it they cannot be selected")
    func withoutHelper() async throws {
        let session = session(privileged: nil, helperAvailable: false)
        await session.scan()

        let systemCache = path("system/Library/Caches/com.vendor.daemon")
        let candidate = try #require(session.groups.flatMap(\.candidates).first { $0.path == systemCache })
        #expect(session.requiresHelper(candidate))
        #expect(!session.canSelect(candidate))
        session.toggle(systemCache)
        #expect(!session.selection.contains(systemCache))
        #expect(session.groups.contains { $0.category == .systemCaches })
        #expect(session.groups.contains { $0.category == .systemLogs })
    }

    @Test("with the helper, selected system items go through it into the user's Trash and are logged for Put Back")
    func throughHelper() async throws {
        let session = session(privileged: helper, helperAvailable: true)
        await session.scan()
        let systemCache = path("system/Library/Caches/com.vendor.daemon")
        let userCache = path("home/Library/Caches/com.vendor.app")
        session.setSelected(false, category: .appCaches)
        session.toggle(systemCache)
        session.toggle(userCache)
        #expect(session.selection == [systemCache, userCache])

        let summary = await session.clean()

        #expect(summary.movedToTrashCount == 2)
        #expect(summary.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: systemCache))
        #expect(FileManager.default.fileExists(atPath: home + "/.Trash/com.vendor.daemon"))
        let records = try await activityLog.readAll().records
        let systemRecord = try #require(records.last { $0.itemPath == systemCache && $0.outcome.isMovedToTrash })
        #expect(systemRecord.privileged == true)
        #expect(records.last { $0.itemPath == userCache && $0.outcome.isMovedToTrash }?.privileged == nil)
    }

    @Test("a dry run through the helper changes nothing")
    func dryRunThroughHelper() async throws {
        let session = session(privileged: helper, helperAvailable: true)
        await session.scan()
        let systemCache = path("system/Library/Caches/com.vendor.daemon")
        session.setSelected(false, category: .appCaches)
        session.toggle(systemCache)

        let summary = await session.clean(dryRun: true)

        #expect(summary.wouldRemoveCount == 1)
        #expect(FileManager.default.fileExists(atPath: systemCache))
    }

    @Test("if the helper cannot be reached, nothing is removed and the items are reported")
    func helperUnreachable() async throws {
        struct Unreachable: PrivilegedOperations {
            func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse {
                throw .unavailable
            }
            func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError? {
                throw .unavailable
            }
            func removeOrphanedLaunchItem(_ item: DeletionItem, operationID: UUID) async throws(HelperClientError)
                -> ActivityRecord.Outcome
            { throw .unavailable }
            func deleteLocalSnapshot(date: String) async throws(HelperClientError) -> SnapshotDeletion {
                throw .unavailable
            }
        }
        let session = session(privileged: Unreachable(), helperAvailable: true)
        await session.scan()
        let systemCache = path("system/Library/Caches/com.vendor.daemon")
        session.setSelected(false, category: .appCaches)
        session.toggle(systemCache)

        let summary = await session.clean()

        #expect(summary.movedToTrashCount == 0)
        #expect(summary.problems.map(\.path) == [systemCache])
        #expect(FileManager.default.fileExists(atPath: systemCache))
    }

    @Test("Put Back of an item the helper moved goes through the helper")
    func putBackThroughHelper() async throws {
        let session = session(privileged: helper, helperAvailable: true)
        await session.scan()
        let systemCache = path("system/Library/Caches/com.vendor.daemon")
        session.setSelected(false, category: .appCaches)
        session.toggle(systemCache)
        _ = await session.clean()

        let activity = ActivitySession(activityLog: activityLog, privileged: helper)
        await activity.load()
        let operation = try #require(activity.operations.first { $0.items.contains { $0.path == systemCache } })

        #expect(await activity.restore(itemPath: systemCache, operationID: operation.id) == nil)
        #expect(FileManager.default.fileExists(atPath: systemCache + "/blob"))
    }

    @Test("the system rules only target folders the helper allows, and are never pre-selected")
    func systemRulesFitTheAllowlist() {
        let allowlist = HelperAllowlist(systemRoot: "/")
        for rule in RuleCatalog.system(root: "/") {
            #expect(rule.elevation == .helper)
            #expect(rule.risk == .review)
            let root = rule.root.path(home: "/Users/u")
            let sample = DeletionItem(
                path: root + "/sample.gz", ruleRoot: root,
                expected: FileSnapshot(
                    identity: FileIdentity(device: 1, inode: 1), kind: .file, logicalSize: 1, modificationDate: nil),
                ownerBundleID: nil, freedBytes: 1, section: .cleanup)
            #expect(allowlist.permits(sample), "\(rule.id) is outside the helper's allowlist")
        }
    }

    // MARK: - Orphaned system startup items (SB-4)

    private func systemDaemon(_ name: String, program: String, state: LaunchItem.ProgramState) throws -> LaunchItem {
        try fixture.directory("system/Library/LaunchDaemons")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": name, "Program": program], format: .xml, options: 0)
        try data.write(to: fixture.url("system/Library/LaunchDaemons/\(name).plist"))
        return LaunchItem(
            plistPath: path("system/Library/LaunchDaemons/\(name).plist"), domain: .systemDaemon, label: name,
            program: program, arguments: [], schedules: [], programState: state, associatedBundleIdentifiers: [],
            ownerAppPath: nil, isApple: false, status: .enabled, parseError: false)
    }

    private func startupSession(privileged: (any PrivilegedOperations)?, runner: FakeCommandRunner) -> StartupSession {
        let policy = ProtectionPolicy(home: home)
        let session = StartupSession(
            reader: LaunchItemReader(
                userAgents: home + "/Library/LaunchAgents", systemAgents: system + "/Library/LaunchAgents",
                systemDaemons: system + "/Library/LaunchDaemons", status: { _ in .enabled }),
            runner: runner, userID: 501,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: { _ in .notRunning }), log: activityLog,
                trash: UserTrash(home: home, uid: getuid())),
            privileged: privileged)
        return session
    }

    @Test("an orphaned system daemon can be removed only with the helper, which unloads it and trashes its plist")
    func orphanedSystemDaemon() async throws {
        let runner = FakeCommandRunner()
        runner.stub("/bin/launchctl", ["bootout", "system/com.vendor.gone"])
        let helper = InProcessHelper(
            service: HelperService(
                allowlist: HelperAllowlist(systemRoot: system), clientHome: home, clientUID: getuid(),
                log: ActivityLog(directory: fixture.url("helper-log")), staging: path("staging"),
                processPaths: { [] }, runner: runner))
        let orphan = try systemDaemon("com.vendor.gone", program: "/Gone/vendord", state: .missing)

        let without = startupSession(privileged: nil, runner: runner)
        #expect(!without.canRemove(orphan))

        let session = startupSession(privileged: helper, runner: runner)
        #expect(!session.canRemove(orphan))  // helper not confirmed yet
        session.helperAvailable = true
        #expect(session.canRemove(orphan))

        #expect(await session.remove(orphan) == .removed)
        #expect(!FileManager.default.fileExists(atPath: orphan.plistPath))
        #expect(runner.commands.map(\.arguments) == [["bootout", "system/com.vendor.gone"]])
        let records = try await activityLog.readAll().records
        #expect(records.last { $0.itemPath == orphan.plistPath }?.privileged == true)
    }

    @Test("a system daemon whose program still exists cannot be removed, even with the helper")
    func liveSystemDaemon() throws {
        let session = startupSession(privileged: helper, runner: FakeCommandRunner())
        session.helperAvailable = true
        let live = try systemDaemon("com.vendor.live", program: "/usr/bin/true", state: .present)

        #expect(!session.canRemove(live))
    }
}
