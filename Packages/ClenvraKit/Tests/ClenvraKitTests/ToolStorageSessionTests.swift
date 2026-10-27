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

    @Test("rows without a cleanup command, or unknown rows, cannot be run")
    func unknownRow() async {
        let session = session()
        await session.inspect()

        #expect(await session.runCleanup(rowID: "nope") == nil)
        #expect(runner.commands.allSatisfy { $0.arguments != ["store", "prune"] })
    }
}
