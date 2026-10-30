import Foundation
import Testing

@testable import ClenvraKit

@MainActor
@Suite("ToolStorageSession")
struct ToolStorageSessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let runner = FakeCommandRunner()

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.file("bin/pnpm", bytes: 1)
        try fixture.setPermissions("bin/pnpm", 0o755)
        try fixture.file("home/store/v10/blob", bytes: 20_000)
        runner.stub(path("bin/pnpm"), ["store", "path"], stdout: path("home/store") + "\n")
    }

    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func session() -> ToolStorageSession {
        let pnpm = ToolAdapters.standard.filter { $0.id == "pnpm" }
        return ToolStorageSession(
            adapters: pnpm, locator: ToolLocator(searchPath: [path("bin")]), runner: runner, home: path("home"),
            log: ActivityLog(directory: fixture.url("log")))
    }

    @Test("inspecting lists each installed tool with its size and cleanup command")
    func inspect() async throws {
        let session = session()

        await session.inspect()

        #expect(session.phase == .ready)
        let row = try #require(session.rows.first)
        #expect(row.id == "pnpm.store")
        #expect((row.size ?? 0) > 0)
        #expect(row.cleanup?.summary == "pnpm store prune")
    }

    @Test("running a cleanup streams output, logs the command and refreshes the sizes")
    func runCleanup() async throws {
        runner.stub(
            path("bin/pnpm"), ["store", "prune"], stdout: "Removed 12 packages\n",
            lines: [OutputLine(stream: .standardOutput, text: "Removed 12 packages")])
        let session = session()
        await session.inspect()

        let result = try #require(await session.runCleanup(rowID: "pnpm.store"))

        #expect(result.exitStatus == 0)
        #expect(session.lastRun?.output.map(\.text) == ["Removed 12 packages"])
        #expect(session.lastRun?.rowID == "pnpm.store")
        #expect(runner.commands.filter { $0.arguments == ["store", "path"] }.count == 2)
        let records = try await ActivityLog(directory: fixture.url("log")).readAll().records
        #expect(records.map(\.outcome) == [.intent, .removedPermanently])
        #expect(records.allSatisfy { $0.section == .developer && $0.itemPath == path("home/store") })
    }

    @Test("a failing command is logged as failed with its exit status")
    func failingCleanup() async throws {
        runner.stub(path("bin/pnpm"), ["store", "prune"], stderr: "boom", status: 3)
        let session = session()
        await session.inspect()

        let result = await session.runCleanup(rowID: "pnpm.store")

        #expect(result?.exitStatus == 3)
        let records = try await ActivityLog(directory: fixture.url("log")).readAll().records
        #expect(records.last?.outcome == .failed(errno: 3))
    }

    /// npm, pnpm and Gradle (no cleanup command), in that order.
    private func threeTools() throws -> ToolStorageSession {
        try fixture.file("bin/npm", bytes: 1)
        try fixture.setPermissions("bin/npm", 0o755)
        try fixture.file("home/.npm/_cacache/blob", bytes: 10_000)
        try fixture.file("home/.gradle/caches/blob", bytes: 10_000)
        runner.stub(path("bin/npm"), ["config", "get", "cache"], stdout: path("home/.npm") + "\n")
        let adapters = ToolAdapters.standard.filter { ["npm", "pnpm", "gradle"].contains($0.id) }
        return ToolStorageSession(
            adapters: adapters, locator: ToolLocator(searchPath: [path("bin")]), runner: runner, home: path("home"),
            log: ActivityLog(directory: fixture.url("log")))
    }

    private var cleanupCommands: [[String]] {
        runner.commands.map(\.arguments).filter { $0 == ["cache", "clean", "--force"] || $0 == ["store", "prune"] }
    }

    @Test("checked tools are cleaned in the order shown; a tool without a command cannot be checked")
    func toolsCleanCheckedInOrder() async throws {
        runner.stub(path("bin/npm"), ["cache", "clean", "--force"], stdout: "npm done\n")
        runner.stub(path("bin/pnpm"), ["store", "prune"], stdout: "pnpm done\n")
        let session = try threeTools()
        await session.inspect()
        #expect(session.rows.map(\.id) == ["npm.cache", "pnpm.store", "gradle.caches"])

        session.toggleChecked("gradle.caches")
        #expect(session.checked.isEmpty)
        session.toggleChecked("pnpm.store")
        session.toggleChecked("npm.cache")
        session.setChecked(["npm.cache", "pnpm.store", "gradle.caches", "nope"])
        #expect(session.checked == ["npm.cache", "pnpm.store"])
        #expect(session.checkedRows.map(\.id) == ["npm.cache", "pnpm.store"])

        let runs = await session.runCheckedCleanups()

        #expect(runs.map(\.rowID) == ["npm.cache", "pnpm.store"])
        #expect(runs.allSatisfy { $0.result?.exitStatus == 0 })
        #expect(cleanupCommands == [["cache", "clean", "--force"], ["store", "prune"]])
        #expect(session.lastBatch?.map(\.rowID) == ["npm.cache", "pnpm.store"])
        #expect(session.checked.isEmpty)
        #expect(session.phase == .ready)
        let records = try await ActivityLog(directory: fixture.url("log")).readAll().records
        #expect(records.map(\.outcome) == [.intent, .removedPermanently, .intent, .removedPermanently])
    }

    @Test("a failing tool is reported and the next checked tool still runs")
    func toolFailureDoesNotStopOthers() async throws {
        // npm's cleanup is not scripted, so the runner throws for it; pnpm fails with a status.
        runner.stub(path("bin/pnpm"), ["store", "prune"], stderr: "boom", status: 3)
        let session = try threeTools()
        await session.inspect()
        session.setChecked(["npm.cache", "pnpm.store"])

        let runs = await session.runCheckedCleanups()

        #expect(runs.map(\.rowID) == ["npm.cache", "pnpm.store"])
        #expect(runs[0].result == nil)
        #expect(runs[1].result?.exitStatus == 3)
        #expect(cleanupCommands == [["cache", "clean", "--force"], ["store", "prune"]])
        let records = try await ActivityLog(directory: fixture.url("log")).readAll().records
        #expect(records.map(\.outcome) == [.intent, .failed(errno: -1), .intent, .failed(errno: 3)])
    }

    @Test("rows without a cleanup command, or unknown rows, cannot be run")
    func unknownRow() async {
        let session = session()
        await session.inspect()

        #expect(await session.runCleanup(rowID: "nope") == nil)
        #expect(runner.commands.allSatisfy { $0.arguments != ["store", "prune"] })
    }
}
