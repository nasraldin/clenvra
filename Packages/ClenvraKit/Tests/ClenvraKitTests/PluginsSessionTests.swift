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

    private func session(apps: PluginsSession.AppControl = .none) -> PluginsSession {
        let policy = ProtectionPolicy(home: path("home"))
        return PluginsSession(
            reader: PluginReader(
                home: path("home"), systemRoot: path("system"), runner: runner, teamIdentifier: { _ in nil }),
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: { _ in .notRunning }),
                log: ActivityLog(directory: fixture.url("log")), trash: PluginTrash(directory: path(".Trash"))),
            apps: apps)
    }

    private func item(_ path: String, in session: PluginsSession) -> PluginItem? {
        session.groups.flatMap(\.items).first { $0.path == path }
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

    // MARK: - Containing apps

    @Test("an extension whose app is open names that app; others, managed and macOS apps do not")
    func containingAppIsRunning() async throws {
        let apps = FakeApps(running: ["/Applications/Notes Pro.app/", "/Applications/Defender.app"])
        let session = session(apps: apps.control)
        await session.scan()
        session.showsAppleItems = true

        let share = try #require(item("/Applications/Notes Pro.app/Contents/PlugIns/Share.appex", in: session))
        let blocker = try #require(
            item(path("home") + "/Applications/Blocker.app/Contents/PlugIns/Blocker Safari.appex", in: session))
        let defender = try #require(item("/Applications/Defender.app/Contents/PlugIns/Finder.appex", in: session))
        let pane = try #require(item(path("home/Library/PreferencePanes/Mine.prefPane"), in: session))

        #expect(session.runningApp(for: share) == "/Applications/Notes Pro.app")
        #expect(session.runningApp(for: blocker) == nil)
        #expect(session.runningApp(for: defender) == nil)  // security software is never acted on
        #expect(session.runningApp(for: pane) == nil)

        apps.running = []
        #expect(session.runningApp(for: share) == "/Applications/Notes Pro.app")  // until refreshed
        session.refreshRunningApps()
        #expect(session.runningApp(for: share) == nil)
    }

    @Test("an app inside /System is never offered for quitting")
    func systemAppIsNotQuittable() async throws {
        let apps = FakeApps(running: ["/System/Applications/Reminders.app"])
        let session = session(apps: apps.control)
        await session.scan()
        session.showsAppleItems = true

        let reminders = try #require(
            item("/System/Applications/Reminders.app/Contents/PlugIns/RemindersQuickLookExtension.appex", in: session))
        #expect(session.runningApp(for: reminders) == nil)
        #expect(!session.quitApp("/System/Applications/Reminders.app", force: false))
        #expect(apps.quits.isEmpty)
    }

    @Test("quitting asks politely first; when that fails, Force Quit is offered and used")
    func quitThenForceQuit() async {
        let apps = FakeApps(running: ["/Applications/Notes Pro.app"])
        apps.politeSucceeds = false
        let session = session(apps: apps.control)
        await session.scan()
        #expect(!session.needsForceQuit("/Applications/Notes Pro.app"))

        #expect(!session.quitApp("/Applications/Notes Pro.app", force: false))
        #expect(session.needsForceQuit("/Applications/Notes Pro.app"))

        #expect(session.quitApp("/Applications/Notes Pro.app", force: true))
        #expect(apps.quits.map(\.path) == ["/Applications/Notes Pro.app", "/Applications/Notes Pro.app"])
        #expect(apps.quits.map(\.force) == [false, true])
    }

    @Test("an app that is not running is not quit")
    func quitNotRunning() async {
        let apps = FakeApps(running: [])
        let session = session(apps: apps.control)
        await session.scan()

        #expect(!session.quitApp("/Applications/Notes Pro.app", force: true))
        #expect(apps.quits.isEmpty)
    }

    // MARK: - Icons

    @Test("an extension's icon comes from its own bundle, then its app, then none")
    func iconSources() {
        let appex = PluginItem(
            name: "Share", kind: .appExtension, path: "/A.app/Contents/PlugIns/S.appex", bundleIdentifier: "x",
            version: nil, domain: .appBundle, containingApp: "/A.app", handling: .revealOnly)
        #expect(appex.iconSources(hasOwnIcon: { _ in true }) == ["/A.app/Contents/PlugIns/S.appex", "/A.app"])
        #expect(appex.iconSources(hasOwnIcon: { _ in false }) == ["/A.app"])

        let system = PluginItem(
            name: "Net", kind: .systemExtension, path: nil, bundleIdentifier: "y", version: nil, domain: .system,
            handling: .revealOnly)
        #expect(system.iconSources(hasOwnIcon: { _ in true }).isEmpty)
    }

    @Test("a bundle has its own icon when its Info.plist names one")
    func ownIcon() {
        #expect(PluginItem.declaresIcon(["CFBundleIconFile": "AppIcon"]))
        #expect(PluginItem.declaresIcon(["CFBundleIconName": "AppIcon"]))
        #expect(PluginItem.declaresIcon(["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["i"]]]]))
        #expect(!PluginItem.declaresIcon(["CFBundleIdentifier": "x"]))
        #expect(!PluginItem.declaresIcon(["CFBundleIconFile": ""]))
    }

    @Test("the containing app is shown by its name")
    func containingAppName() {
        let appex = PluginItem(
            name: "Share", kind: .appExtension, path: nil, bundleIdentifier: "x", version: nil, domain: .appBundle,
            containingApp: "/Applications/Notes Pro.app", handling: .revealOnly)
        #expect(appex.containingAppName == "Notes Pro")
    }
}

/// Running apps and quit requests, recorded instead of touching real apps.
@MainActor
private final class FakeApps {
    var running: Set<String>
    var politeSucceeds = true
    private(set) var quits: [(path: String, force: Bool)] = []

    init(running: Set<String>) { self.running = running }

    var control: PluginsSession.AppControl {
        PluginsSession.AppControl(
            runningAppPaths: { [unowned self] in running },
            quit: { [unowned self] path, force in
                quits.append((path, force))
                return force || politeSucceeds
            })
    }
}
