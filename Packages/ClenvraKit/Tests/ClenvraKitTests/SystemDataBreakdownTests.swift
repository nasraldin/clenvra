import Foundation
import Testing

@testable import ClenvraKit

@Suite("System Data breakdown")
struct SystemDataBreakdownTests {
    static let snapshotOutput =
        "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-30-101500.local\ncom.apple.os.update-ABC\n"

    static let runtimeJSON = """
        {"EC0470CE-EF90-4B78-955C-6E37ACB0E8A1": {"identifier": "EC0470CE-EF90-4B78-955C-6E37ACB0E8A1",
         "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "version": "18.6", "build": "22G86",
         "sizeBytes": 8838255185, "deletable": true, "kind": "Cryptex Disk Image", "state": "Ready",
         "path": "/Library/Developer/CoreSimulator/Cryptex/Images/bundle/x.dmg"},
         "AAAA0000-0000-0000-0000-000000000000": {"identifier": "AAAA0000-0000-0000-0000-000000000000",
         "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "version": "11.0",
         "sizeBytes": 100, "deletable": false, "state": "Ready"}}
        """

    /// A scratch home with a CoreSimulator folder, so the runtime probe is not skipped.
    static func simulatorHome() throws -> TemporaryDirectory {
        let home = try TemporaryDirectory()
        try FileManager.default.createDirectory(
            at: home.url.appending(path: "Library/Developer/CoreSimulator"), withIntermediateDirectories: true)
        return home
    }

    @Test("parseSnapshots lists the snapshot names and skips the header")
    func parseSnapshotsListsNames() {
        #expect(
            SystemDataReader.parseSnapshots(Self.snapshotOutput) == [
                "com.apple.TimeMachine.2026-10-30-101500.local", "com.apple.os.update-ABC",
            ])
        #expect(SystemDataReader.parseSnapshots("Snapshots for disk /:\n").isEmpty)
        #expect(SystemDataReader.parseSnapshots("").isEmpty)
    }

    @Test("read sums simulator runtime sizes and counts local snapshots")
    func readSumsRuntimes() async throws {
        let home = try Self.simulatorHome()
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], stdout: Self.runtimeJSON)
        runner.stub("/usr/bin/tmutil", ["listlocalsnapshots", "/"], stdout: Self.snapshotOutput)

        let breakdown = await SystemDataReader.read(
            runner: runner, rootVolume: nil, home: home.url.path(percentEncoded: false))

        let expected: Int64 = 8_838_255_185 + 100
        #expect(breakdown.simulatorRuntimes == expected)
        #expect(breakdown.localSnapshots.count == 2)
        #expect(breakdown.purgeable == nil)
    }

    @Test("failing tools give no runtime size and no snapshots")
    func missingToolsGiveNil() async throws {
        let home = try Self.simulatorHome()
        let runner = FakeCommandRunner()

        let breakdown = await SystemDataReader.read(
            runner: runner, rootVolume: nil, home: home.url.path(percentEncoded: false))

        #expect(breakdown.simulatorRuntimes == nil)
        #expect(breakdown.localSnapshots.isEmpty)
    }

    @Test("without a CoreSimulator folder xcrun is never run")
    func noCoreSimulatorSkipsXcrun() async throws {
        let home = try TemporaryDirectory()
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], stdout: Self.runtimeJSON)

        let breakdown = await SystemDataReader.read(
            runner: runner, rootVolume: nil, home: home.url.path(percentEncoded: false))

        #expect(breakdown.simulatorRuntimes == nil)
        #expect(!runner.commands.contains { $0.executable == "/usr/bin/xcrun" })
    }

    @Test("purgeable comes from the root volume")
    func purgeableFromRootVolume() async throws {
        let home = try TemporaryDirectory()
        let volume = Volume(
            id: URL(filePath: "/"), name: "Macintosh HD", kind: .internal, fileSystem: "apfs", isRoot: true,
            isReadOnly: false, isEjectable: false, totalCapacity: 1_000, availableCapacity: 200,
            availableForImportantUsage: 350)

        let breakdown = await SystemDataReader.read(
            runner: FakeCommandRunner(), rootVolume: volume, home: home.url.path(percentEncoded: false))

        #expect(breakdown.purgeable == 150)
    }

    @Test("swap usage is readable on this Mac")
    func swapUsedIsReadable() {
        #expect(SystemDataReader.swapUsed() != nil)
    }
}
