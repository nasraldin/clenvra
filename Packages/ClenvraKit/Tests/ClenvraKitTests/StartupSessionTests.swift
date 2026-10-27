import Darwin
import Foundation
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
}
