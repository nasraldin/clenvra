import Darwin
import Foundation
import Observation
import Synchronization
import Testing

@testable import ClenvraKit

/// Moves items into a `.Trash` folder inside the test directory.
private struct ScratchTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

@MainActor
@Suite("CleanupSession")
struct CleanupSessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try fixture.file("Library/Caches/com.vendor.big/blob", bytes: 300_000)
        try fixture.file("Library/Caches/com.vendor.small/blob", bytes: 1_000)
        try fixture.file("Downloads/Installer.dmg", bytes: 5_000)
    }

    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private var rules: [CleanupRule] {
        RuleCatalog.standard.filter { ["caches.user", "installers.downloads"].contains($0.id) }
    }

    private func session(running: Set<String> = []) -> CleanupSession {
        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { running.contains($0) ? .running : .notRunning }
        return CleanupSession(
            rules: rules, section: .cleanup, home: home, policy: policy, ownerState: ownerState,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState),
                log: ActivityLog(directory: fixture.url("log")),
                trash: ScratchTrash(directory: path(".Trash"))))
    }

    @Test("scanning groups candidates by category and pre-selects only safe, available items")
    func scan() async {
        let session = session()

        await session.scan()

        #expect(session.phase == .ready)
        #expect(session.groups.map(\.category) == [.appCaches, .installers])
        #expect(session.selection == [path("Library/Caches/com.vendor.big"), path("Library/Caches/com.vendor.small")])
        #expect(session.selectedCount == 2)
        #expect(session.selectedBytes >= 301_000)
    }

    @Test("the session records when its last scan finished, and has none before the first scan")
    func recordsScanTime() async throws {
        let session = session()
        #expect(session.lastScanned == nil)

        let before = Date()
        await session.scan()

        let scanned = try #require(session.lastScanned)
        #expect(scanned >= before && scanned <= Date())
    }

    @Test("rules whose folders do not exist on this Mac are hidden")
    func hidesAbsentRules() async throws {
        try FileManager.default.removeItem(atPath: path("Downloads"))
        let session = session()

        await session.scan()

        #expect(session.groups.map(\.category) == [.appCaches])
    }

    @Test("selection can be toggled per item and per category; unavailable items cannot be selected")
    func selection() async {
        let session = session(running: ["com.vendor.small"])
        await session.scan()

        #expect(!session.selection.contains(path("Library/Caches/com.vendor.small")))
        session.toggle(path("Library/Caches/com.vendor.small"))
        #expect(!session.selection.contains(path("Library/Caches/com.vendor.small")))

        session.setSelected(true, category: .installers)
        #expect(session.selection.contains(path("Downloads/Installer.dmg")))
        session.toggle(path("Downloads/Installer.dmg"))
        #expect(!session.selection.contains(path("Downloads/Installer.dmg")))
    }

    @Test("an item the user deselected stays deselected after a rescan; new items get their default")
    func selectionSurvivesRescan() async throws {
        let session = session()
        await session.scan()
        session.toggle(path("Library/Caches/com.vendor.big"))
        try fixture.file("Library/Caches/com.vendor.new/blob", bytes: 10)

        await session.scan()

        #expect(!session.selection.contains(path("Library/Caches/com.vendor.big")))
        #expect(session.selection.contains(path("Library/Caches/com.vendor.new")))
    }

    @Test("results appear group by group while the scan is still running")
    func progressiveResults() async {
        let session = session()
        let phaseAtFirstResults = Mutex<CleanupSession.Phase?>(nil)
        // Observation calls this synchronously, on the main actor, just before the first change to `groups`; the
        // scan is still running if fewer rules than the total have finished at that moment.
        withObservationTracking {
            _ = session.groups
        } onChange: {
            MainActor.assumeIsolated { phaseAtFirstResults.withLock { $0 = session.phase } }
        }

        await session.scan()

        let phase = phaseAtFirstResults.withLock { $0 }
        guard case .scanning(let completed, let total)? = phase else {
            Issue.record("groups changed outside a scan: \(String(describing: phase))")
            return
        }
        #expect(completed < total)
        #expect(!session.groups.isEmpty)
    }

    @Test("a dry run reports what would be removed and changes nothing")
    func preview() async throws {
        let session = session()
        await session.scan()

        let summary = await session.clean(dryRun: true)

        #expect(summary.wouldRemoveCount == 2)
        #expect(summary.movedToTrashCount == 0)
        #expect(FileManager.default.fileExists(atPath: path("Library/Caches/com.vendor.big")))
    }

    @Test("cleaning moves the selection to the Trash, reports the result and rescans")
    func clean() async throws {
        let session = session()
        await session.scan()

        let summary = await session.clean()

        #expect(summary.movedToTrashCount == 2)
        #expect(summary.freedBytes >= 301_000)
        #expect(summary.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path("Library/Caches/com.vendor.big")))
        #expect(session.phase == .ready)
        #expect(session.groups.first { $0.category == .appCaches }?.candidates.isEmpty ?? true)
        #expect(session.selection.isEmpty)
    }

    @Test("items that changed after review are skipped and explained, the rest are cleaned")
    func partialFailure() async throws {
        let session = session()
        await session.scan()
        try FileManager.default.removeItem(atPath: path("Library/Caches/com.vendor.small"))

        let summary = await session.clean()

        #expect(summary.movedToTrashCount == 1)
        #expect(summary.problems.map(\.path) == [path("Library/Caches/com.vendor.small")])
        #expect(summary.problems.first?.reason == .skipped(.notFound))
    }

    @Test("rules can be replaced, and the next scan uses the new ones")
    func replacesRules() async throws {
        let session = session()
        await session.scan()
        #expect(session.groups.map(\.category) == [.appCaches, .installers])

        session.setRules(RuleCatalog.standard.filter { $0.id == "installers.downloads" })
        await session.scan()

        #expect(session.groups.map(\.category) == [.installers])
    }
}
