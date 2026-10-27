import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("LaunchAgentReenabler")
struct LaunchAgentReenablerTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let runner = FakeCommandRunner()
    private let uid = getuid()

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("home/Library/LaunchAgents")
    }

    private var agents: String { fixture.url("home/Library/LaunchAgents").path(percentEncoded: false) }

    private func reenabler(userID: UInt32? = nil) -> LaunchAgentReenabler {
        LaunchAgentReenabler(runner: runner, userAgentsDirectory: agents, userID: userID ?? uid)
    }

    @discardableResult
    private func writePlist(_ name: String, contents: [String: Any]) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        let url = fixture.url("home/Library/LaunchAgents/" + name)
        try data.write(to: url)
        return url.path(percentEncoded: false)
    }

    private func record(
        _ path: String, section: ActivityRecord.Section = .startup,
        outcome: ActivityRecord.Outcome = .movedToTrash(trashPath: "/t/x")
    ) -> ActivityRecord {
        ActivityRecord(operationID: UUID(), date: Date(), section: section, itemPath: path, bytes: 0, outcome: outcome)
    }

    // MARK: - Eligibility

    @Test("only Startup Trash moves of a .plist directly inside the user's LaunchAgents qualify")
    func eligibility() {
        let reenabler = reenabler()

        #expect(reenabler.canReenable(record(agents + "/com.vendor.agent.plist")))
        #expect(!reenabler.canReenable(record(agents + "/com.vendor.agent.plist", section: .cleanup)))
        #expect(!reenabler.canReenable(record(agents + "/com.vendor.agent.plist", outcome: .removedPermanently)))
        #expect(!reenabler.canReenable(record(agents + "/sub/com.vendor.agent.plist")))
        #expect(!reenabler.canReenable(record(agents + "/../com.vendor.agent.plist")))
        #expect(!reenabler.canReenable(record(agents + "/com.vendor.agent.txt")))
        #expect(!reenabler.canReenable(record(agents + "/.hidden.plist")))
        #expect(!reenabler.canReenable(record("/Library/LaunchAgents/com.vendor.agent.plist")))
        #expect(!reenabler.canReenable(record(agents + "x/com.vendor.agent.plist")))
    }

    // MARK: - Re-enabling

    @Test("a valid agent that is not loaded is bootstrapped into the user's GUI domain with a fixed argv")
    func bootstraps() async throws {
        let path = try writePlist(
            "com.vendor.agent.plist", contents: ["Label": "com.vendor.agent", "Program": "/usr/bin/true"])
        runner.stub("/bin/launchctl", ["print", "gui/\(uid)/com.vendor.agent"], status: 113)
        runner.stub("/bin/launchctl", ["bootstrap", "gui/\(uid)", path])

        #expect(await reenabler().reenable(record(path)) == .enabled)
        #expect(runner.commands.map(\.executable) == ["/bin/launchctl", "/bin/launchctl"])
        #expect(runner.commands.last?.arguments == ["bootstrap", "gui/\(uid)", path])
    }

    @Test("an agent that is already loaded is not bootstrapped again")
    func alreadyLoaded() async throws {
        let path = try writePlist("com.vendor.agent.plist", contents: ["Label": "com.vendor.agent"])
        runner.stub("/bin/launchctl", ["print", "gui/\(uid)/com.vendor.agent"])

        #expect(await reenabler().reenable(record(path)) == .alreadyEnabled)
        #expect(runner.commands.count == 1)
    }

    @Test("a failing bootstrap is reported with its exit status")
    func bootstrapFails() async throws {
        let path = try writePlist("com.vendor.agent.plist", contents: ["Label": "com.vendor.agent"])
        runner.stub("/bin/launchctl", ["print", "gui/\(uid)/com.vendor.agent"], status: 113)
        runner.stub("/bin/launchctl", ["bootstrap", "gui/\(uid)", path], stderr: "Bootstrap failed: 5", status: 5)

        #expect(await reenabler().reenable(record(path)) == .failed(exitStatus: 5))
    }

    @Test("a runner that cannot start launchctl is reported as failed")
    func runnerThrows() async throws {
        let path = try writePlist("com.vendor.agent.plist", contents: ["Label": "com.vendor.agent"])

        #expect(await reenabler().reenable(record(path)) == .failed(exitStatus: nil))
    }

    @Test(
        "unsafe or invalid plists are refused before anything runs",
        arguments: [
            ["Program": "/usr/bin/true"],
            ["Label": ""],
            ["Label": 42],
            ["Label": "has space"],
            ["Label": "-flag"],
            ["Label": "a/b"],
            ["Label": "com.apple.fake"],
            ["Label": "com.microsoft.wdav.tray"],
            ["Label": String(repeating: "a", count: 300)],
        ] as [[String: any Sendable]])
    func invalidPlists(contents: [String: any Sendable]) async throws {
        let path = try writePlist("com.vendor.agent.plist", contents: contents)

        #expect(await reenabler().reenable(record(path)) == .invalidPlist)
        #expect(runner.commands.isEmpty)
    }

    @Test("a plist that is not a property list, a symlink, missing, or group-writable is refused")
    func unsafeFiles() async throws {
        try fixture.file("home/Library/LaunchAgents/garbage.plist", bytes: 10)
        #expect(await reenabler().reenable(record(agents + "/garbage.plist")) == .invalidPlist)

        let real = try writePlist("real.plist", contents: ["Label": "com.vendor.agent"])
        #expect(symlink(real, agents + "/link.plist") == 0)
        #expect(await reenabler().reenable(record(agents + "/link.plist")) == .invalidPlist)

        #expect(await reenabler().reenable(record(agents + "/missing.plist")) == .invalidPlist)

        #expect(chmod(real, 0o664) == 0)
        #expect(await reenabler().reenable(record(real)) == .invalidPlist)
        #expect(runner.commands.isEmpty)
    }

    @Test("a plist owned by another user is refused")
    func otherOwner() async throws {
        let path = try writePlist("com.vendor.agent.plist", contents: ["Label": "com.vendor.agent"])

        #expect(await reenabler(userID: uid + 1).reenable(record(path)) == .invalidPlist)
        #expect(runner.commands.isEmpty)
    }

    @Test("records outside the allowed scope are refused without reading or running anything")
    func notAllowed() async {
        #expect(await reenabler().reenable(record("/Library/LaunchDaemons/x.plist")) == .notAllowed)
        #expect(runner.commands.isEmpty)
    }
}
