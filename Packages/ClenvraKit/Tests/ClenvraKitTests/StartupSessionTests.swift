import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Moves items into a `.Trash` folder inside the test directory.
private struct StartupTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

/// Stands in for the installed helper: records each enable/disable request and answers with `answer`.
private final class RecordingHelper: PrivilegedOperations {
    struct Call: Sendable {
        let item: DeletionItem
        let enabled: Bool
    }

    let answer: LaunchItemChange
    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }

    init(answer: LaunchItemChange) {
        self.answer = answer
    }

    func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse { throw .unavailable }
    func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError? { throw .unavailable }
    func removeOrphanedLaunchItem(_ item: DeletionItem, operationID: UUID) async throws(HelperClientError)
        -> ActivityRecord.Outcome
    { throw .unavailable }
    func deleteLocalSnapshot(date: String) async throws(HelperClientError) -> SnapshotDeletion { throw .unavailable }
    func setLaunchItemEnabled(_ item: DeletionItem, enabled: Bool) async throws(HelperClientError)
        -> LaunchItemChange
    {
        recorded.withLock { $0.append(Call(item: item, enabled: enabled)) }
        return answer
    }
}

@MainActor
@Suite("StartupSession")
struct StartupSessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let runner = FakeCommandRunner()

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try fixture.file("bin/real-tool", bytes: 1)
        try writePlist(
            "home/Library/LaunchAgents/com.vendor.orphan.plist", label: "com.vendor.orphan",
            program: "/Applications/Gone.app/Contents/MacOS/agent")
        try writePlist(
            "home/Library/LaunchAgents/com.vendor.ok.plist", label: "com.vendor.ok", program: path("bin/real-tool"))
        try writePlist(
            "home/Library/LaunchAgents/com.apple.something.plist", label: "com.apple.something",
            program: path("bin/real-tool"))
        try writePlist(
            "system/LaunchDaemons/com.vendor.daemon.plist", label: "com.vendor.daemon",
            program: "/Library/PrivilegedHelperTools/gone")
    }

    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func writePlist(_ relative: String, label: String, program: String) throws {
        try fixture.directory((relative as NSString).deletingLastPathComponent)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "Program": program, "RunAtLoad": true], format: .xml, options: 0)
        try data.write(to: fixture.url(relative))
    }

    private func session() -> StartupSession {
        let policy = ProtectionPolicy(home: path("home"))
        return StartupSession(
            reader: LaunchItemReader(
                userAgents: path("home/Library/LaunchAgents"), systemAgents: path("system/LaunchAgents"),
                systemDaemons: path("system/LaunchDaemons"), status: { _ in .enabled }),
            runner: runner, userID: 501,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: { _ in .notRunning }),
                log: ActivityLog(directory: fixture.url("log")), trash: StartupTrash(directory: path(".Trash"))))
    }

    @Test("items whose program is missing are listed first and flagged")
    func orphansFirst() async {
        let session = session()

        await session.load(installedApps: [])

        #expect(session.items.prefix(2).compactMap(\.label).sorted() == ["com.vendor.daemon", "com.vendor.orphan"])
        #expect(session.problemCount == 2)
    }

    @Test("only the user's own non-Apple agents can be removed")
    func removability() async throws {
        let session = session()
        await session.load(installedApps: [])
        func item(_ label: String) throws -> LaunchItem { try #require(session.items.first { $0.label == label }) }

        #expect(session.canRemove(try item("com.vendor.orphan")))
        #expect(!session.canRemove(try item("com.apple.something")))
        #expect(!session.canRemove(try item("com.vendor.daemon")))
    }

    @Test("removing a user agent stops it, moves its plist to the Trash and logs it")
    func remove() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.orphan.plist")
        runner.stub("/bin/launchctl", ["bootout", "gui/501", plist])
        let session = session()
        await session.load(installedApps: [])
        let item = try #require(session.items.first { $0.label == "com.vendor.orphan" })

        let outcome = await session.remove(item)

        #expect(outcome == .removed)
        #expect(runner.commands.map(\.arguments) == [["bootout", "gui/501", plist]])
        #expect(!FileManager.default.fileExists(atPath: plist))
        #expect(!session.items.contains { $0.label == "com.vendor.orphan" })
        let records = try await ActivityLog(directory: fixture.url("log")).readAll().records
        #expect(records.last?.section == .startup)
    }

    @Test("an agent that is not loaded is still removed (launchctl reports it as not found)")
    func notLoaded() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.orphan.plist")
        runner.stub("/bin/launchctl", ["bootout", "gui/501", plist], stderr: "No such process", status: 3)
        let session = session()
        await session.load(installedApps: [])
        let item = try #require(session.items.first { $0.label == "com.vendor.orphan" })

        #expect(await session.remove(item) == .removed)
    }

    // MARK: - Stop and start (F9)

    @Test("only the person's own agents whose program exists can be stopped and started")
    func controllability() async throws {
        let session = session()
        await session.load(installedApps: [])
        func item(_ label: String) throws -> LaunchItem { try #require(session.items.first { $0.label == label }) }

        #expect(session.canControl(try item("com.vendor.ok")))
        #expect(!session.canControl(try item("com.vendor.orphan")))  // program is gone
        #expect(!session.canControl(try item("com.apple.something")))
        #expect(!session.canControl(try item("com.vendor.daemon")))  // system daemon
    }

    @Test("stopping unloads the agent for this session and keeps its plist; starting loads it again")
    func stopAndStart() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.ok.plist")
        runner.stub("/bin/launchctl", ["bootout", "gui/501", plist])
        runner.stub("/bin/launchctl", ["bootstrap", "gui/501", plist])
        let session = session()
        await session.load(installedApps: [])
        let item = try #require(session.items.first { $0.label == "com.vendor.ok" })

        #expect(await session.stop(item))
        #expect(FileManager.default.fileExists(atPath: plist))
        #expect(await session.start(item))
        #expect(
            runner.commands.map(\.arguments) == [["bootout", "gui/501", plist], ["bootstrap", "gui/501", plist]])
    }

    @Test("starting fails visibly when launchctl refuses, and nothing is run for items that cannot be controlled")
    func startFailureAndRefusal() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.ok.plist")
        runner.stub("/bin/launchctl", ["bootstrap", "gui/501", plist], stderr: "Bootstrap failed: 5", status: 5)
        let session = session()
        await session.load(installedApps: [])
        let ok = try #require(session.items.first { $0.label == "com.vendor.ok" })
        let apple = try #require(session.items.first { $0.label == "com.apple.something" })

        #expect(await session.start(ok) == false)
        #expect(await session.stop(apple) == false)
        #expect(runner.commands.count == 1)
    }

    @Test("whether an agent is running comes from launchctl print; unknown when launchctl gives another answer")
    func runningState() async throws {
        runner.stub("/bin/launchctl", ["print", "gui/501/com.vendor.ok"])
        runner.stub(
            "/bin/launchctl", ["print", "gui/501/com.vendor.orphan"], stderr: "Could not find service", status: 113)
        let session = session()
        await session.load(installedApps: [])
        let ok = try #require(session.items.first { $0.label == "com.vendor.ok" })
        let orphan = try #require(session.items.first { $0.label == "com.vendor.orphan" })

        #expect(await session.isRunning(ok) == true)
        #expect(await session.isRunning(orphan) == false)
    }

    @Test("if stopping fails for another reason, the plist is kept")
    func stopFailure() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.orphan.plist")
        runner.stub("/bin/launchctl", ["bootout", "gui/501", plist], stderr: "Operation not permitted", status: 1)
        let session = session()
        await session.load(installedApps: [])
        let item = try #require(session.items.first { $0.label == "com.vendor.orphan" })

        #expect(await session.remove(item) == .couldNotStop)
        #expect(FileManager.default.fileExists(atPath: plist))
    }

    @Test("system and Apple items are refused without running anything")
    func refuseSystem() async throws {
        let session = session()
        await session.load(installedApps: [])
        let daemon = try #require(session.items.first { $0.label == "com.vendor.daemon" })

        #expect(await session.remove(daemon) == .notAllowed)
        #expect(runner.commands.isEmpty)
    }

    @Test("items of company security or management software are marked managed and never removable (SB-6)")
    func managedItems() async throws {
        try writePlist(
            "home/Library/LaunchAgents/com.microsoft.wdav.tray.plist", label: "com.microsoft.wdav.tray",
            program: path("bin/real-tool"))
        let session = session()
        await session.load(installedApps: [])
        let item = try #require(session.items.first { $0.label == "com.microsoft.wdav.tray" })

        #expect(session.isManaged(item))
        #expect(!session.canRemove(item))
        #expect(await session.remove(item) == .notAllowed)
    }
    @Test("a removed agent can be put back and re-enabled from Activity, once, and only after Put Back (SB-3)")
    func putBackAndReenable() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.orphan.plist")
        let uid = getuid()
        runner.stub("/bin/launchctl", ["bootout", "gui/501", plist])
        runner.stub("/bin/launchctl", ["print", "gui/\(uid)/com.vendor.orphan"], status: 113)
        runner.stub("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
        let startup = session()
        await startup.load(installedApps: [])
        let item = try #require(startup.items.first { $0.label == "com.vendor.orphan" })
        #expect(await startup.remove(item) == .removed)

        let activity = ActivitySession(
            activityLog: ActivityLog(directory: fixture.url("log")),
            reenabler: LaunchAgentReenabler(
                runner: runner, userAgentsDirectory: path("home/Library/LaunchAgents"), userID: uid))
        await activity.load()
        let operation = try #require(activity.operations.first)
        #expect(!activity.canReenable(itemPath: plist, operationID: operation.id))
        #expect(await activity.reenable(itemPath: plist, operationID: operation.id) == .notAllowed)

        #expect(await activity.restore(itemPath: plist, operationID: operation.id) == nil)
        #expect(activity.canReenable(itemPath: plist, operationID: operation.id))
        #expect(await activity.reenable(itemPath: plist, operationID: operation.id) == .enabled)

        #expect(runner.commands.last?.arguments == ["bootstrap", "gui/\(uid)", plist])
        #expect(activity.isReenabled(itemPath: plist, operationID: operation.id))
        #expect(!activity.canReenable(itemPath: plist, operationID: operation.id))
    }

    // MARK: - Disable and enable

    private func session(privileged: RecordingHelper) -> StartupSession {
        let policy = ProtectionPolicy(home: path("home"))
        return StartupSession(
            reader: LaunchItemReader(
                userAgents: path("home/Library/LaunchAgents"), systemAgents: path("system/LaunchAgents"),
                systemDaemons: path("system/LaunchDaemons"), status: { _ in .enabled }),
            runner: runner, userID: 501,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: { _ in .notRunning }),
                log: ActivityLog(directory: fixture.url("log")), trash: StartupTrash(directory: path(".Trash"))),
            privileged: privileged)
    }

    @Test("disabling an own agent unloads it, then disables it in launchd; its plist stays")
    func disableOwnAgentRunsLaunchctl() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.ok.plist")
        runner.stub("/bin/launchctl", ["bootout", "gui/501", plist])
        runner.stub("/bin/launchctl", ["disable", "gui/501/com.vendor.ok"])
        let session = session()
        await session.load(installedApps: [])
        let item = try #require(session.items.first { $0.label == "com.vendor.ok" })

        #expect(session.canDisable(item))
        #expect(await session.disable(item) == .done)

        #expect(
            runner.commands.map(\.arguments) == [["bootout", "gui/501", plist], ["disable", "gui/501/com.vendor.ok"]])
        #expect(session.isDisabled(item))
        #expect(FileManager.default.fileExists(atPath: plist))
    }

    @Test("enabling reverses a disable: enable in launchd, then load it again")
    func enableReverses() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.ok.plist")
        runner.stub("/bin/launchctl", ["bootout", "gui/501", plist])
        runner.stub("/bin/launchctl", ["disable", "gui/501/com.vendor.ok"])
        runner.stub("/bin/launchctl", ["enable", "gui/501/com.vendor.ok"])
        runner.stub("/bin/launchctl", ["bootstrap", "gui/501", plist])
        let session = session()
        await session.load(installedApps: [])
        let item = try #require(session.items.first { $0.label == "com.vendor.ok" })
        #expect(await session.disable(item) == .done)

        #expect(await session.enable(item) == .done)

        #expect(
            runner.commands.map(\.arguments).suffix(2) == [
                ["enable", "gui/501/com.vendor.ok"], ["bootstrap", "gui/501", plist],
            ])
        #expect(!session.isDisabled(item))
    }

    @Test("Apple and managed items are never disabled, and nothing runs")
    func disableRefusesAppleItems() async throws {
        let session = session()
        await session.load(installedApps: [])
        let apple = try #require(session.items.first { $0.label == "com.apple.something" })

        #expect(!session.canDisable(apple))
        #expect(await session.disable(apple) == .notAllowed)
        #expect(runner.commands.isEmpty)
    }

    @Test("a Mac-wide item is disabled only through the helper, with the plist as it was reviewed")
    func systemItemGoesThroughHelper() async throws {
        let helper = RecordingHelper(answer: .done)
        let plist = path("system/LaunchDaemons/com.vendor.daemon.plist")
        let session = session(privileged: helper)
        await session.load(installedApps: [])
        let daemon = try #require(session.items.first { $0.label == "com.vendor.daemon" })
        #expect(!session.canDisable(daemon))  // helper not confirmed yet
        #expect(await session.disable(daemon) == .notAllowed)
        session.helperAvailable = true
        #expect(session.canDisable(daemon))

        #expect(await session.disable(daemon) == .done)
        #expect(await session.enable(daemon) == .done)

        #expect(runner.commands.isEmpty)
        let calls = helper.calls
        #expect(calls.map(\.enabled) == [false, true])
        #expect(calls.map(\.item.path) == [plist, plist])
        #expect(calls.first?.item.expected == (try SafeWalk.resolve(plist).snapshot))
    }

    @Test("a plist that changed since it was reviewed is refused, own or Mac-wide, and nothing runs")
    func changedPlistIsRefused() async throws {
        let helper = RecordingHelper(answer: .done)
        let session = session(privileged: helper)
        session.helperAvailable = true
        await session.load(installedApps: [])
        let own = try #require(session.items.first { $0.label == "com.vendor.ok" })
        let daemon = try #require(session.items.first { $0.label == "com.vendor.daemon" })
        try writePlist(
            "home/Library/LaunchAgents/com.vendor.ok.plist", label: "com.vendor.ok", program: "/tmp/somewhere-else")
        try writePlist(
            "system/LaunchDaemons/com.vendor.daemon.plist", label: "com.vendor.daemon", program: "/tmp/other-daemon")

        #expect(await session.disable(own) == .changedSinceReview)
        #expect(await session.disable(daemon) == .changedSinceReview)
        #expect(runner.commands.isEmpty)
        #expect(helper.calls.isEmpty)
    }

    @Test("a refusal from the helper is passed on")
    func helperRefusalIsReported() async throws {
        let helper = RecordingHelper(answer: .notAuthorized)
        let session = session(privileged: helper)
        session.helperAvailable = true
        await session.load(installedApps: [])
        let daemon = try #require(session.items.first { $0.label == "com.vendor.daemon" })

        #expect(await session.disable(daemon) == .notAuthorized)
        #expect(!session.isDisabled(daemon))
    }

    @Test("the Disabled state is read from launchctl print-disabled, for this user and for the Mac")
    func readsDisabledState() async throws {
        runner.stub(
            "/bin/launchctl", ["print-disabled", "gui/501"],
            stdout: """
                disabled services = {
                \t"com.vendor.ok" => disabled
                \t"com.vendor.orphan" => enabled
                }
                login item associations = {
                }
                """)
        runner.stub(
            "/bin/launchctl", ["print-disabled", "system"],
            stdout: """
                disabled services = {
                \t"com.vendor.daemon" => true
                \t"com.vendor.other" => false
                }
                """)
        let session = session()
        await session.load(installedApps: [])
        await session.loadDisabledState()
        func item(_ label: String) throws -> LaunchItem { try #require(session.items.first { $0.label == label }) }

        #expect(session.isDisabled(try item("com.vendor.ok")))
        #expect(!session.isDisabled(try item("com.vendor.orphan")))
        #expect(session.isDisabled(try item("com.vendor.daemon")))
        #expect(
            StartupSession.disabledLabels(fromPrintDisabled: "\t\"a.b\" => disabled\n\t\"c.d\" => enabled\n")
                == ["a.b"])
    }

    @Test("without a re-enabler, Activity never offers re-enabling")
    func noReenabler() async throws {
        let plist = path("home/Library/LaunchAgents/com.vendor.orphan.plist")
        runner.stub("/bin/launchctl", ["bootout", "gui/501", plist])
        let startup = session()
        await startup.load(installedApps: [])
        let item = try #require(startup.items.first { $0.label == "com.vendor.orphan" })
        #expect(await startup.remove(item) == .removed)
        let activity = ActivitySession(activityLog: ActivityLog(directory: fixture.url("log")))
        await activity.load()
        let operation = try #require(activity.operations.first)
        #expect(await activity.restore(itemPath: plist, operationID: operation.id) == nil)

        #expect(!activity.canReenable(itemPath: plist, operationID: operation.id))
        #expect(await activity.reenable(itemPath: plist, operationID: operation.id) == .notAllowed)
    }

    @Test("a Mac-wide item is offered Remove and Disable, waiting for the helper rather than refused")
    func macWideItemWaitsForHelper() async throws {
        let session = session(privileged: RecordingHelper(answer: .done))
        await session.load(installedApps: [])
        func item(_ label: String) throws -> LaunchItem { try #require(session.items.first { $0.label == label }) }
        let daemon = try item("com.vendor.daemon")  // Mac-wide, program missing
        let apple = try item("com.apple.something")
        let own = try item("com.vendor.orphan")

        #expect(session.mayRemove(daemon) && session.mayDisable(daemon))
        #expect(session.waitsForHelper(daemon))
        #expect(!session.canRemove(daemon) && !session.canDisable(daemon))
        #expect(!session.mayRemove(apple) && !session.mayDisable(apple) && !session.waitsForHelper(apple))
        #expect(session.mayRemove(own) && !session.waitsForHelper(own))

        session.helperAvailable = true
        #expect(!session.waitsForHelper(daemon))
        #expect(session.canRemove(daemon) && session.canDisable(daemon))
    }
}
