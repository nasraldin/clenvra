import Darwin
import Foundation
import Testing

@testable import ClenvraKit

/// The helper's system-level actions (M13): orphaned system launch items (SB-4) and local Time Machine snapshots
/// (SY-4). Every value the helper acts on is read or validated by the helper itself.
@Suite("Helper system actions")
struct HelperSystemTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let runner = FakeCommandRunner()

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("home/.Trash")
        try fixture.directory("staging")
        try fixture.directory("system/Library/LaunchDaemons")
        try fixture.directory("system/Library/LaunchAgents")
    }

    private var root: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private var home: String { root + "/home" }
    private var system: String { root + "/system" }

    private var service: HelperService {
        HelperService(
            allowlist: HelperAllowlist(systemRoot: system), clientHome: home, clientUID: 501,
            log: ActivityLog(directory: fixture.url("helper-log")), staging: root + "/staging", processPaths: { [] },
            runner: runner)
    }

    private func writePlist(_ relative: String, _ contents: [String: Any]) throws -> DeletionItem {
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: fixture.url("system/" + relative))
        let full = system + "/" + relative
        return DeletionItem(
            path: full, ruleRoot: (full as NSString).deletingLastPathComponent,
            expected: try SafeWalk.resolve(full).snapshot, ownerBundleID: nil, freedBytes: 1, section: .startup)
    }

    // MARK: - Orphaned launch items (SB-4)

    @Test("an orphaned system daemon is unloaded and its plist moved to the user's Trash")
    func removesOrphanedDaemon() async throws {
        let item = try writePlist(
            "Library/LaunchDaemons/com.vendor.old.plist", ["Label": "com.vendor.old", "Program": "/Gone/Vendor/oldd"])
        runner.stub("/bin/launchctl", ["bootout", "system", item.path])

        let outcome = await service.removeOrphanedLaunchItem(item, operationID: UUID())

        #expect(outcome.isMovedToTrash)
        #expect(!FileManager.default.fileExists(atPath: item.path))
        // By plist path, so only the job loaded from this very file can be stopped, never another job's label.
        #expect(runner.commands.map(\.arguments) == [["bootout", "system", item.path]])
    }

    @Test("an orphaned agent in /Library/LaunchAgents is unloaded from the requesting user's session")
    func removesOrphanedAgent() async throws {
        let item = try writePlist(
            "Library/LaunchAgents/com.vendor.agent.plist",
            ["Label": "com.vendor.agent", "ProgramArguments": ["/Gone/Vendor/agent", "--run"]])
        runner.stub("/bin/launchctl", ["bootout", "gui/501", item.path])

        let outcome = await service.removeOrphanedLaunchItem(item, operationID: UUID())

        #expect(outcome.isMovedToTrash)
        #expect(runner.commands.map(\.arguments) == [["bootout", "gui/501", item.path]])
    }

    @Test("an item whose program still exists is not orphaned and is left alone, with nothing run")
    func refusesInstalledProgram() async throws {
        try fixture.file("system/Applications/Vendor.app/Contents/MacOS/vendord", bytes: 10)
        let item = try writePlist(
            "Library/LaunchDaemons/com.vendor.live.plist",
            ["Label": "com.vendor.live", "Program": system + "/Applications/Vendor.app/Contents/MacOS/vendord"])

        let outcome = await service.removeOrphanedLaunchItem(item, operationID: UUID())

        #expect(outcome == .skipped(.programStillInstalled))
        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(runner.commands.isEmpty)
    }

    @Test("labels and programs the helper cannot verify are refused before anything runs")
    func refusesUnverifiable() async throws {
        let cases: [(String, [String: Any])] = [
            ("apple.plist", ["Label": "com.apple.something", "Program": "/Gone/x"]),
            ("space.plist", ["Label": "com.vendor bad", "Program": "/Gone/x"]),
            ("dash.plist", ["Label": "-flag", "Program": "/Gone/x"]),
            ("relative.plist", ["Label": "com.vendor.rel", "Program": "relative/path"]),
            ("bundle.plist", ["Label": "com.vendor.bundle", "BundleProgram": "Contents/MacOS/x"]),
            ("nolabel.plist", ["Program": "/Gone/x"]),
            ("managed.plist", ["Label": "com.crowdstrike.falcon", "Program": "/Gone/x"]),
        ]
        for (name, contents) in cases {
            let item = try writePlist("Library/LaunchDaemons/" + name, contents)
            let outcome = await service.removeOrphanedLaunchItem(item, operationID: UUID())
            #expect(!outcome.isMovedToTrash, "\(name) must be refused")
            #expect(FileManager.default.fileExists(atPath: item.path))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("nothing is unloaded when the deletion gate would refuse the plist (it changed after the scan)")
    func gateRunsBeforeBootout() async throws {
        let item = try writePlist(
            "Library/LaunchDaemons/com.vendor.old.plist", ["Label": "com.vendor.old", "Program": "/Gone/Vendor/oldd"])
        // Replaced after the app scanned it: a different file now, though still an orphan.
        try FileManager.default.removeItem(atPath: item.path)
        _ = try writePlist(
            "Library/LaunchDaemons/com.vendor.old.plist", ["Label": "com.vendor.old", "Program": "/Gone/Vendor/oldd"])

        let outcome = await service.removeOrphanedLaunchItem(item, operationID: UUID())

        #expect(outcome == .skipped(.changedSinceScan))
        #expect(runner.commands.isEmpty)
    }

    @Test("only plists directly in the system launch folders are accepted")
    func refusesOtherLocations() async throws {
        try fixture.directory("system/Library/Caches")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.vendor.x", "Program": "/Gone/x"], format: .xml, options: 0)
        try data.write(to: fixture.url("system/Library/Caches/com.vendor.x.plist"))
        let path = system + "/Library/Caches/com.vendor.x.plist"
        let item = DeletionItem(
            path: path, ruleRoot: system + "/Library/Caches", expected: try SafeWalk.resolve(path).snapshot,
            ownerBundleID: nil, freedBytes: 1, section: .startup)

        #expect(await service.removeOrphanedLaunchItem(item, operationID: UUID()) == .skipped(.outsideRoot))
        #expect(runner.commands.isEmpty)
    }

    // MARK: - Local snapshots (SY-4)

    @Test("the snapshot list from tmutil is parsed defensively")
    func parsesSnapshotDates() {
        let output = "Snapshot dates for all disks:\n2026-10-25-101500\n2026-10-27-093012\nnot a date\n\n"
        #expect(LocalSnapshots.dates(fromListOutput: output) == ["2026-10-25-101500", "2026-10-27-093012"])
        #expect(LocalSnapshots.dates(fromListOutput: "").isEmpty)
    }

    @Test("a listed snapshot is deleted; anything else is refused without running the delete")
    func deletesSnapshots() async {
        runner.stub(
            "/usr/bin/tmutil", ["listlocalsnapshotdates", "/"],
            stdout: "Snapshot dates for all disks:\n2026-10-27-093012\n")
        runner.stub("/usr/bin/tmutil", ["deletelocalsnapshots", "2026-10-27-093012"])

        #expect(await service.deleteLocalSnapshot(date: "2026-10-27-093012") == .deleted)
        #expect(await service.deleteLocalSnapshot(date: "2026-10-26-000000") == .notFound)
        #expect(await service.deleteLocalSnapshot(date: "/ ; rm -rf") == .invalid)
        #expect(await service.deleteLocalSnapshot(date: "2026-10-27-093012 /") == .invalid)
        let deletes = runner.commands.filter { $0.arguments.first == "deletelocalsnapshots" }
        #expect(deletes.map(\.arguments) == [["deletelocalsnapshots", "2026-10-27-093012"]])
    }

    @Test("a failing tmutil is reported as failed")
    func snapshotDeleteFails() async {
        runner.stub(
            "/usr/bin/tmutil", ["listlocalsnapshotdates", "/"],
            stdout: "Snapshot dates for all disks:\n2026-10-27-093012\n")
        runner.stub("/usr/bin/tmutil", ["deletelocalsnapshots", "2026-10-27-093012"], status: 1)

        #expect(await service.deleteLocalSnapshot(date: "2026-10-27-093012") == .failed)
    }
}
