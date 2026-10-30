import Foundation
import Testing

@testable import ClenvraKit

@Suite("Simulator runtimes")
struct SimulatorRuntimeTests {
    /// The real `xcrun simctl runtime list -j` shape: keys are runtime UUIDs.
    private static let runtimesJSON = """
        {"EC0470CE-EF90-4B78-955C-6E37ACB0E8A1": {"identifier": "EC0470CE-EF90-4B78-955C-6E37ACB0E8A1",
         "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "version": "18.6", "build": "22G86",
         "sizeBytes": 8838255185, "deletable": true, "kind": "Cryptex Disk Image", "state": "Ready",
         "path": "/Library/Developer/CoreSimulator/Cryptex/Images/bundle/x.dmg"},
         "AAAA0000-0000-0000-0000-000000000000": {"identifier": "AAAA0000-0000-0000-0000-000000000000",
         "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "version": "11.0",
         "sizeBytes": 100, "deletable": false, "state": "Ready"}}
        """

    private static let iOSID = "EC0470CE-EF90-4B78-955C-6E37ACB0E8A1"
    private static let xcrun = "/usr/bin/xcrun"

    private func row(_ id: String, in output: String = runtimesJSON) throws -> ToolStorage {
        try #require(SimulatorAdapter.parseRuntimes(output).first { $0.id == "simulators.runtime.\(id)" })
    }

    @Test("a deletable runtime offers simctl runtime delete, for review and irreversible")
    func deletableRuntimeOffersDelete() throws {
        let row = try row(Self.iOSID)
        let cleanup = try #require(row.cleanup)
        #expect(cleanup.command.executable == Self.xcrun)
        #expect(cleanup.command.arguments == ["simctl", "runtime", "delete", Self.iOSID])
        #expect(cleanup.risk == .review)
        #expect(cleanup.isIrreversible)
        #expect(cleanup.summary == "xcrun simctl runtime delete \(Self.iOSID)")
        #expect(row.size == 8_838_255_185)
        #expect(row.category == .simulators)
        let note = try #require(row.note.map { String(localized: $0) })
        #expect(note.contains("iOS 18.6"))
        #expect(note.contains("shut down first"))
    }

    @Test("the adapter's xcrun path is used for the delete command")
    func customXcrunIsUsed() throws {
        let rows = SimulatorAdapter.parseRuntimes(Self.runtimesJSON, xcrun: "/opt/xcrun")
        let row = try #require(rows.first { $0.id == "simulators.runtime.\(Self.iOSID)" })
        #expect(row.cleanup?.command.executable == "/opt/xcrun")
    }

    @Test("a runtime marked not deletable is visibility only")
    func undeletableRuntimeIsVisibilityOnly() throws {
        let row = try row("AAAA0000-0000-0000-0000-000000000000")
        #expect(row.cleanup == nil)
        #expect(row.note.map { String(localized: $0) }?.contains("Xcode › Settings › Components") == true)
    }

    @Test("a runtime without an identifier is visibility only")
    func runtimeWithoutIdentifierIsVisibilityOnly() throws {
        let output = """
            {"BBBB0000-0000-0000-0000-000000000000": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0",
             "version": "17.0", "sizeBytes": 5, "deletable": true, "state": "Ready"}}
            """
        #expect(try row("BBBB0000-0000-0000-0000-000000000000", in: output).cleanup == nil)
    }

    @Test(
        "an identifier that is not a UUID is never passed to simctl",
        arguments: ["", "all", "--notUsedSinceDays", "-h", "EC0470CE EF90", "not-a-uuid"])
    func nonUUIDIdentifierIsVisibilityOnly(identifier: String) throws {
        let output = """
            {"CCCC0000-0000-0000-0000-000000000000": {"identifier": "\(identifier)",
             "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0", "version": "17.0",
             "deletable": true}}
            """
        #expect(try row("CCCC0000-0000-0000-0000-000000000000", in: output).cleanup == nil)
    }

    @Test("deletable must be the boolean true", arguments: [#""true""#, "1", "null"])
    func deletableMustBeBoolean(value: String) throws {
        let output = """
            {"DDDD0000-0000-0000-0000-000000000000": {"identifier": "DDDD0000-0000-0000-0000-000000000000",
             "version": "17.0", "deletable": \(value)}}
            """
        #expect(try row("DDDD0000-0000-0000-0000-000000000000", in: output).cleanup == nil)
    }
}
