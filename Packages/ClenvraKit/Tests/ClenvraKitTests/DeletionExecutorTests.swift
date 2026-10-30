import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Moves items into a `.Trash` folder inside the test directory, so tests never touch the real Trash.
private struct FixtureTrash: TrashOperations {
    let trashDirectory: String

    func moveToTrash(path: String) throws -> String {
        let destination = trashDirectory + "/" + (path as NSString).lastPathComponent + "-" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

/// Simulates the Trash refusing the move (safety case S15).
private struct FailingTrash: TrashOperations {
    func moveToTrash(path: String) throws -> String {
        throw FileSystemError(code: EPERM, operation: "trash", path: path)
    }
}

/// Simulates a swap: reports a different object as "the item now in the Trash" (safety case S16).
private struct SwappingTrash: TrashOperations {
    let impostor: String
    let inner: FixtureTrash

    func moveToTrash(path: String) throws -> String {
        _ = try inner.moveToTrash(path: path)
        return impostor
    }
}

@Suite("DeletionExecutor")
struct DeletionExecutorTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let log: ActivityLog

    init() throws {
        let scratch = try TemporaryDirectory()
        self.scratch = scratch
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        log = ActivityLog(directory: scratch.url.appending(path: "log"))
    }

    private func path(_ relative: String) -> String {
        scratch.url.appending(path: relative).path(percentEncoded: false)
    }
    private var cacheRoot: String { path("cache") }
    private var fixtureTrash: FixtureTrash { FixtureTrash(trashDirectory: path(".Trash")) }

    private func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path(relative), &info) == 0
    }

    private func item(_ relative: String) throws -> DeletionItem {
        DeletionItem(
            path: path(relative), ruleRoot: cacheRoot, expected: try SafeWalk.resolve(path(relative)).snapshot,
            ownerBundleID: nil, freedBytes: 4, section: .cleanup)
    }

    private func executor(trash: any TrashOperations) -> DeletionExecutor {
        DeletionExecutor(
            gate: DeletionGate(policy: ProtectionPolicy(home: "/Users/nobody"), ownerState: { _ in .notRunning }),
            log: log, trash: trash)
    }

    @Test("moving to the Trash moves the reviewed item and reports where it went")
    func movesToTrash() async throws {
        try fixture.file("cache/a.bin", bytes: 4)
        let planned = try item("cache/a.bin")

        let results = await executor(trash: fixtureTrash).run([planned], mode: .moveToTrash)

        guard case .movedToTrash(let trashPath) = results.first?.outcome else {
            Issue.record("unexpected \(String(describing: results.first?.outcome))")
            return
        }
        #expect(!exists("cache/a.bin"))
        #expect(try SafeWalk.resolve(trashPath).snapshot.identity == planned.expected.identity)
    }

    /// The Trash of another drive: `<drive>/.Trashes` is search-only (`d-wx--x--t`), the user's folder inside it is
    /// theirs. Emptying it removes the item for good.
    @Test("removes for good through a folder that can be searched but not read")
    func irreversibleThroughSearchOnlyFolder() async throws {
        try fixture.file("cache/trashes/501/old-file.bin", bytes: 4)
        #expect(chmod(path("cache/trashes"), 0o311) == 0)
        defer { chmod(path("cache/trashes"), 0o755) }
        let planned = try item("cache/trashes/501/old-file.bin")

        let results = await executor(trash: fixtureTrash).run([planned], mode: .irreversible)

        #expect(results.first?.outcome == .removedPermanently)
        #expect(!exists("cache/trashes/501/old-file.bin"))
    }

    @Test("a dry run checks everything and changes nothing")
    func dryRun() async throws {
        try fixture.file("cache/a.bin", bytes: 4)

        let results = await executor(trash: fixtureTrash).run(
            [try item("cache/a.bin")], mode: .moveToTrash, dryRun: true)

        #expect(results.map(\.outcome) == [.wouldDelete])
        #expect(exists("cache/a.bin"))
    }

    @Test("refused items are skipped with their reason while the rest proceed")
    func refusalDoesNotStopOthers() async throws {
        try fixture.file("cache/a.bin", bytes: 4)
        try fixture.file("cache/b.bin", bytes: 4)
        let first = try item("cache/a.bin")
        let second = try item("cache/b.bin")
        try FileManager.default.removeItem(atPath: path("cache/a.bin"))

        let results = await executor(trash: fixtureTrash).run([first, second], mode: .moveToTrash)

        #expect(results[0].outcome == .skipped(.notFound))
        #expect(results[1].outcome.isMovedToTrash)
    }

    @Test("removing one of two hard links leaves the other intact (safety case S8)")
    func hardLink() async throws {
        try fixture.file("cache/a.bin", bytes: 4)
        try fixture.hardLink("keep.bin", to: "cache/a.bin")

        let results = await executor(trash: fixtureTrash).run([try item("cache/a.bin")], mode: .moveToTrash)

        #expect(results.first?.outcome.isMovedToTrash == true)
        #expect(exists("keep.bin"))
    }

    @Test("if the Trash refuses, the item stays and nothing falls back to permanent deletion (safety case S15)")
    func trashFailure() async throws {
        try fixture.file("cache/a.bin", bytes: 4)

        let results = await executor(trash: FailingTrash()).run([try item("cache/a.bin")], mode: .moveToTrash)

        #expect(results.map(\.outcome) == [.failed(errno: EPERM)])
        #expect(exists("cache/a.bin"))
    }

    @Test("an identity mismatch after moving stops the batch (safety case S16)")
    func anomalyStopsBatch() async throws {
        try fixture.file("cache/a.bin", bytes: 4)
        try fixture.file("cache/b.bin", bytes: 4)
        try fixture.file("impostor.bin", bytes: 4)
        let trash = SwappingTrash(impostor: path("impostor.bin"), inner: fixtureTrash)

        let results = await executor(trash: trash).run(
            [try item("cache/a.bin"), try item("cache/b.bin")], mode: .moveToTrash)

        #expect(results.map(\.outcome) == [.anomaly, .notAttempted])
        #expect(exists("cache/b.bin"))
    }

    @Test("a cancelled run attempts nothing (safety case S14)")
    func cancelled() async throws {
        try fixture.file("cache/a.bin", bytes: 4)
        let planned = try item("cache/a.bin")
        let deleter = executor(trash: fixtureTrash)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await deleter.run([planned], mode: .moveToTrash)
        }
        let results = await task.value

        #expect(results.map(\.outcome) == [.notAttempted])
        #expect(exists("cache/a.bin"))
    }

    @Test("irreversible removal deletes a whole tree but only unlinks symlinks inside it (safety case S17)")
    func irreversibleWithSymlink() async throws {
        try fixture.file("outside/precious.txt", bytes: 4)
        try fixture.file("cache/tool/nested/a.bin", bytes: 4)
        try fixture.symlink("cache/tool/link", to: path("outside"))

        let results = await executor(trash: fixtureTrash).run([try item("cache/tool")], mode: .irreversible)

        #expect(results.map(\.outcome) == [.removedPermanently])
        #expect(!exists("cache/tool"))
        #expect(exists("outside/precious.txt"))
    }

    @Test("every item is logged before and after it is acted on")
    func logging() async throws {
        try fixture.file("cache/a.bin", bytes: 4)

        _ = await executor(trash: fixtureTrash).run([try item("cache/a.bin")], mode: .moveToTrash)
        let records = try await log.readAll().records

        #expect(records.count == 2)
        #expect(records.first?.outcome == .intent)
        #expect(records.last?.outcome.isMovedToTrash == true)
        #expect(records.allSatisfy { $0.itemPath == path("cache/a.bin") })
    }
}
