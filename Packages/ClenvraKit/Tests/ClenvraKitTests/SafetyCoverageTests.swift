import Darwin
import Foundation
import Testing

@testable import ClenvraKit

/// Safety cases S9, S10 and S27 (`docs/architecture/safety-model.md`), end to end through the rule scanner and
/// the deletion executor.
@Suite("Safety cases S9, S10, S27")
struct SafetyCoverageTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func filesRule(_ root: String) -> CleanupRule {
        CleanupRule(
            id: "test.files", category: .appCaches, root: .home(root),
            selection: .files(extensions: ["bin"], minimumAge: nil, maximumDepth: 3), risk: .safe,
            action: .moveToTrash, ownership: .none)
    }

    private func childrenRule(_ root: String) -> CleanupRule {
        CleanupRule(
            id: "test.children", category: .appCaches, root: .home(root), selection: .children(), risk: .safe,
            action: .moveToTrash, ownership: .none)
    }

    private func scan(_ rule: CleanupRule) async -> RuleScanResult {
        await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: "/Users/nobody"), ownerState: { _ in .notRunning })
    }

    private func executor() -> DeletionExecutor {
        DeletionExecutor(
            gate: DeletionGate(policy: ProtectionPolicy(home: "/Users/nobody"), ownerState: { _ in .notRunning }),
            log: ActivityLog(directory: scratch.url.appending(path: "log")), trash: RenamingTrash(home: home))
    }

    // MARK: - S9

    @Test("an APFS clone of a big file is not counted as space freed (safety case S9)")
    func cloneIsNotReclaimable() async throws {
        try fixture.file("Cache/original.bin", bytes: 2_000_000)
        try fixture.clone("Cache/copy.bin", of: "Cache/original.bin")

        let result = await scan(filesRule("Cache"))
        let copy = try #require(result.candidates.first { $0.name == "copy.bin" })

        #expect(copy.allocatedSize >= 2_000_000)
        #expect(copy.reclaimableSize < 100_000)
    }

    // MARK: - S10

    @Test("a folder the user cannot read is reported as skipped and the rest is still offered (safety case S10)")
    func permissionDeniedAtScan() async throws {
        try fixture.file("Cache/open/a.bin", bytes: 4_000)
        try fixture.file("Cache/locked/b.bin", bytes: 4_000)
        try fixture.setPermissions("Cache/locked", 0o000)
        defer { try? fixture.setPermissions("Cache/locked", 0o755) }

        let result = await scan(filesRule("Cache"))

        #expect(result.candidates.map(\.name) == ["a.bin"])
        #expect(result.skipped.map(\.path) == [path("Cache/locked")])
    }

    @Test("if a permission problem is reached at deletion, that item fails with a reason and the batch continues (S10)")
    func permissionDeniedAtDeletion() async throws {
        try fixture.file("Cache/first/a.bin", bytes: 4_000)
        try fixture.file("Cache/second/b.bin", bytes: 4_000)
        let candidates = await scan(childrenRule("Cache")).candidates
        let items = candidates.sorted { $0.name < $1.name }.map { $0.deletionItem(section: .cleanup) }
        try fixture.setPermissions("Cache/first", 0o000)
        defer { try? fixture.setPermissions("Cache/first", 0o755) }

        let results = await executor().run(items, mode: .moveToTrash)

        #expect(results.count == 2)
        if case .movedToTrash = results[0].outcome { Issue.record("an unreadable folder must not be moved") }
        guard case .movedToTrash = results[1].outcome else {
            Issue.record("the next item must still be cleaned, got \(results[1].outcome)")
            return
        }
    }

    // MARK: - S27

    @Test(
        "an item on a disk that was ejected after the scan is skipped, never acted on (safety case S27)",
        .timeLimit(.minutes(1)))
    func ejectedVolume() async throws {
        let image = path("disk.dmg")
        let mountPoint = path("mnt")
        try fixture.directory("mnt")
        // Disk images on virtualised CI Macs sometimes fail to attach on the first try, so each step is retried.
        let create = await hdiutilRetrying([
            "create", "-ov", "-size", "8m", "-fs", "APFS", "-volname", "ClenvraS27", "-layout", "NONE", "-quiet", image,
        ])
        let attach =
            create.status == 0
            ? await hdiutilRetrying([
                "attach", image, "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint, "-quiet",
            ]) : create
        guard attach.status == 0 else {
            Issue.record("could not create or attach a test disk image: \(attach.error)")
            return
        }
        var attached = true
        defer { if attached { _ = hdiutil(["detach", mountPoint, "-force", "-quiet"]) } }

        try Data(repeating: 0x41, count: 64_000).write(to: URL(filePath: mountPoint + "/cache.bin"))
        // Only the snapshot is kept: a resolved item holds its folder open, which would keep the disk busy.
        let snapshot = try SafeWalk.resolve(mountPoint + "/cache.bin").snapshot
        let item = DeletionItem(
            path: mountPoint + "/cache.bin", ruleRoot: mountPoint, expected: snapshot, ownerBundleID: nil,
            freedBytes: 64_000, section: .cleanup)

        // Unplugging a disk does not wait for anyone; a forced detach is the closest equivalent.
        #expect(hdiutil(["detach", mountPoint, "-force", "-quiet"]).status == 0)
        attached = false
        let results = await executor().run([item], mode: .irreversible)

        #expect(results.map(\.outcome) == [.skipped(.notFound)])
    }

    private func hdiutil(_ arguments: [String]) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func hdiutilRetrying(_ arguments: [String]) async -> (status: Int32, error: String) {
        var result = hdiutil(arguments)
        for _ in 0..<2 where result.status != 0 {
            try? await Task.sleep(for: .seconds(2))
            result = hdiutil(arguments)
        }
        return result
    }
}

/// Moves items into a folder next to the fixture, standing in for the Trash.
private struct RenamingTrash: TrashOperations {
    let home: String

    func moveToTrash(path: String) throws -> String {
        let folder = home + "/FixtureTrash"
        mkdir(folder, 0o755)
        let destination = folder + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}
