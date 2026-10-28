import Darwin
import Foundation
import Testing

@testable import ClenvraKit

/// Moves items into a `.Trash` folder inside the test directory.
private struct PluginTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

@MainActor
@Suite("PluginsSession")
struct PluginsSessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let runner = FakeCommandRunner()

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try bundle("home/Library/PreferencePanes/Mine.prefPane", id: "com.example.mine")
        try bundle("home/Library/Audio/Plug-Ins/VST3/Synth.vst3", id: "com.example.synth")
        try bundle("home/Library/QuickLook/Apple.qlgenerator", id: "com.apple.qlthing")
        try bundle("system/Library/PreferencePanes/Shared.prefPane", id: "com.example.shared")
        runner.stub("/usr/bin/pluginkit", ["-mAvvv"], stdout: PluginKitSample.output(home: path("home")))
        runner.stub("/usr/bin/systemextensionsctl", ["list"], stdout: SystemExtensionsSample.output)
    }

    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func bundle(_ relative: String, id: String) throws {
        try fixture.file(relative + "/Contents/MacOS/exe", bytes: 2_000)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        try data.write(to: fixture.url(relative + "/Contents/Info.plist"))
    }

    private func session() -> PluginsSession {
        let policy = ProtectionPolicy(home: path("home"))
        return PluginsSession(
            reader: PluginReader(
                home: path("home"), systemRoot: path("system"), runner: runner, teamIdentifier: { _ in nil }),
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: { _ in .notRunning }),
                log: ActivityLog(directory: fixture.url("log")), trash: PluginTrash(directory: path(".Trash"))))
    }

    @Test("scanning groups items by kind, hides Apple's own items by default and selects nothing")
    func scan() async {
        let session = session()

        await session.scan()

        #expect(session.phase == .ready)
        #expect(session.groups.map(\.kind) == [.preferencePane, .vst3PlugIn, .appExtension, .systemExtension])
        #expect(!session.groups.flatMap(\.items).contains { $0.isApple })
        #expect(session.selection.isEmpty)
        #expect(session.removableCount == 2)
        #expect(session.issues.isEmpty)
    }

    @Test("Apple's items can be shown on request")
    func showApple() async {
        let session = session()
        await session.scan()

        session.showsAppleItems = true

        #expect(session.groups.map(\.kind).contains(.quickLook))
        #expect(
            session.groups.flatMap(\.items).contains { $0.bundleIdentifier == "com.apple.reminders.quicklookextension" }
        )
    }

    @Test("only removable items can be selected")
    func selection() async {
        let session = session()
        await session.scan()

        session.toggle(path("system/Library/PreferencePanes/Shared.prefPane"))
        session.toggle("/Applications/Notes Pro.app/Contents/PlugIns/Share.appex")
        #expect(session.selection.isEmpty)

        session.toggle(path("home/Library/PreferencePanes/Mine.prefPane"))
        #expect(session.selection == [path("home/Library/PreferencePanes/Mine.prefPane")])
        #expect(session.selectedBytes >= 2_000)
        session.toggle(path("home/Library/PreferencePanes/Mine.prefPane"))
        #expect(session.selection.isEmpty)

        session.setSelected(true, kind: .preferencePane)
        #expect(session.selection == [path("home/Library/PreferencePanes/Mine.prefPane")])
        session.setSelected(false, kind: .preferencePane)
        #expect(session.selection.isEmpty)
    }

    @Test("removing a user pane moves it to the Trash through the gate, logs it and rescans")
    func remove() async throws {
        let pane = path("home/Library/PreferencePanes/Mine.prefPane")
        let session = session()
        await session.scan()
        session.toggle(pane)

        let summary = await session.remove()

        #expect(summary.movedToTrashCount == 1)
        #expect(summary.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pane))
        #expect(try FileManager.default.contentsOfDirectory(atPath: path(".Trash")).count == 1)
        #expect(session.phase == .ready)
        #expect(!session.groups.flatMap(\.items).contains { $0.path == pane })
        #expect(session.selection.isEmpty)
        #expect(session.lastSummary == summary)
        let records = try await ActivityLog(directory: fixture.url("log")).readAll().records
        #expect(records.last?.section == .applications)
        #expect(records.last?.itemPath == pane)
    }

    @Test("a dry run checks the selection and changes nothing")
    func dryRun() async {
        let pane = path("home/Library/PreferencePanes/Mine.prefPane")
        let session = session()
        await session.scan()
        session.toggle(pane)

        let summary = await session.remove(dryRun: true)

        #expect(summary.wouldRemoveCount == 1)
        #expect(FileManager.default.fileExists(atPath: pane))
        #expect(session.selection == [pane])
    }

    @Test("a plug-in replaced after the scan is skipped and explained")
    func changedAfterScan() async throws {
        let pane = path("home/Library/PreferencePanes/Mine.prefPane")
        let session = session()
        await session.scan()
        session.toggle(pane)
        try FileManager.default.removeItem(atPath: pane)
        try bundle("home/Library/PreferencePanes/Mine.prefPane", id: "com.example.impostor")

        let summary = await session.remove()

        #expect(summary.movedToTrashCount == 0)
        #expect(summary.problems.map(\.path) == [pane])
        #expect(summary.problems.first?.reason == .skipped(.changedSinceScan))
        #expect(FileManager.default.fileExists(atPath: pane))
    }

    @Test("command problems are reported while file-based plug-ins are still listed")
    func issues() async {
        runner.stub("/usr/bin/pluginkit", ["-mAvvv"], stdout: "garbage")
        runner.stub("/usr/bin/systemextensionsctl", ["list"], status: 1)
        let session = session()

        await session.scan()

        #expect(Set(session.issues) == [.unreadableOutput(.appExtensions), .commandFailed(.systemExtensions)])
        #expect(session.groups.map(\.kind) == [.preferencePane, .vst3PlugIn])
    }
}
