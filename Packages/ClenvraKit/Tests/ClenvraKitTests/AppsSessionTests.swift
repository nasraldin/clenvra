import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Moves items into the fixture's `.Trash` folder.
private struct FixtureTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

/// Which apps are "running" and which were asked to quit; shared with the session's closures.
private final class AppState: Sendable {
    let running = Mutex<Set<String>>([])
    let quitRequests = Mutex<[String]>([])
}

@MainActor
@Suite("AppsSession")
struct AppsSessionTests {
    private let fixture: AppsFixture
    private let now = Date()
    private let state = AppState()

    init() throws {
        fixture = try AppsFixture()
    }

    private func session(
        lastUsed: [String: Date] = [:], team: String? = nil, homebrew: AppsSession.Homebrew? = nil,
        quitStops: Bool = true
    ) -> AppsSession {
        let home = fixture.home
        let policy = ProtectionPolicy(home: home)
        let state = state
        let ownerState: @Sendable (String) -> OwnerState = { id in
            state.running.withLock { $0 }.contains(id) ? .running : .notRunning
        }
        let log = ActivityLog(directory: URL(filePath: home + "/log"))
        return AppsSession(
            home: home, policy: policy,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState), log: log,
                trash: FixtureTrash(directory: home + "/.Trash")),
            log: log,
            resolver: OwnershipResolver(home: home, policy: policy, launchItems: fixture.launchItems),
            discover: {
                await AppInventory.discover(roots: [home + "/Applications"], homebrewCaskroom: home + "/Caskroom")
            },
            ownerState: { app in app.bundleIdentifier.map(ownerState) ?? .unknown },
            requestQuit: { app in
                state.quitRequests.withLock { $0.append(app.id) }
                if quitStops, let id = app.bundleIdentifier { _ = state.running.withLock { $0.remove(id) } }
            },
            lastUsed: { lastUsed[$0] },
            teamIdentifier: { _ in team },
            homebrew: homebrew,
            now: { [now] in now })
    }

    private func trashCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash")).count
    }

    // MARK: - Inventory

    @Test("loads the inventory with sources, and filters by search, App Store, Homebrew and unused")
    func inventory() async throws {
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let store = try fixture.app("com.example.store", name: "Store App", source: .appStore)
        try AppBundleFixture(identifier: "com.example.store", displayName: "Store App", masReceipt: true)
            .create(at: store.id)
        let old = try fixture.app("com.example.old", name: "Old Tool")
        let session = session(lastUsed: [
            old.id: now.addingTimeInterval(-200 * 86_400), writer.id: now.addingTimeInterval(-86_400),
        ])

        await session.load()

        #expect(session.phase == .ready)
        #expect(session.visibleApps.map(\.name) == ["Old Tool", "Store App", "Writer"])
        session.searchText = "writ"
        #expect(session.visibleApps.map(\.name) == ["Writer"])
        session.searchText = ""
        session.filter = .appStore
        #expect(session.visibleApps.map(\.name) == ["Store App"])
        session.filter = .unused
        #expect(session.visibleApps.map(\.name) == ["Old Tool"])
        session.filter = .homebrew
        #expect(session.visibleApps.isEmpty)
        #expect(session.lastUsed(of: writer) == now.addingTimeInterval(-86_400))
    }

    @Test("sizes are measured lazily, cached, and drive the size sort")
    func sizes() async throws {
        let small = try fixture.app("com.example.small", name: "Alpha")
        let big = try fixture.app("com.example.big", name: "Beta")
        try fixture.file("Applications/Beta.app/Contents/Resources/big.bin", bytes: 900_000)
        let session = session()
        await session.load()

        #expect(session.size(of: small) == nil)
        await session.measure(small)
        #expect((session.size(of: small) ?? 0) > 0)
        #expect(session.size(of: big) == nil)

        session.sortOrder = .size
        await session.measureAll()
        #expect(session.visibleApps.map(\.name) == ["Beta", "Alpha"])
        session.sortOrder = .name
        #expect(session.visibleApps.map(\.name) == ["Alpha", "Beta"])
    }

    @Test("sorting by last used puts the longest-unused apps first and unknown dates last")
    func lastUsedSort() async throws {
        let a = try fixture.app("com.example.a", name: "A App")
        let b = try fixture.app("com.example.b", name: "B App")
        _ = try fixture.app("com.example.c", name: "C App")
        let session = session(lastUsed: [
            a.id: now.addingTimeInterval(-10 * 86_400), b.id: now.addingTimeInterval(-90 * 86_400),
        ])
        await session.load()

        session.sortOrder = .lastUsed

        #expect(session.visibleApps.map(\.name) == ["B App", "A App", "C App"])
    }

    // MARK: - Uninstall

    @Test("uninstall moves the bundle and selected owned items to the Trash; Possible items stay")
    func fullUninstall() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer", plugIns: ["Share": "com.example.writer.share"])
        _ = try fixture.app("org.other.viewer", name: "Viewer")
        try fixture.file("Library/Caches/com.example.writer/blob", bytes: 50_000)
        try fixture.file("Library/Preferences/com.example.writer.plist")
        try fixture.container("CONTAINER-UUID", identifier: "com.example.writer.share")
        try fixture.file("Library/Application Support/Writer/doc.json")
        try fixture.file("Library/Application Support/Writer Backups/old.json")
        let session = session()
        await session.load()

        await session.select(app.id)

        let detail = try #require(session.detail)
        #expect(detail.availability == .available)
        #expect(detail.groups.map(\.confidence) == [.certain, .likely, .possible])
        #expect(!session.selection.contains(fixture.path("Library/Application Support/Writer Backups")))
        #expect(session.selectedCount == 5)  // bundle + 3 Certain + 1 Likely
        #expect(session.selectedBytes > 50_000)

        let preview = try #require(await session.uninstall(dryRun: true))
        #expect(preview.wouldRemoveCount == 5)
        #expect(fixture.exists("Applications/Writer.app"))

        let summary = try #require(await session.uninstall())

        #expect(summary.movedToTrashCount == 5)
        #expect(summary.problems.isEmpty)
        #expect(try trashCount() == 5)
        for gone in [
            "Applications/Writer.app", "Library/Caches/com.example.writer",
            "Library/Preferences/com.example.writer.plist",
            "Library/Containers/CONTAINER-UUID", "Library/Application Support/Writer",
        ] {
            #expect(!fixture.exists(gone), "\(gone) should be in the Trash")
        }
        #expect(fixture.exists("Library/Application Support/Writer Backups"))
        #expect(session.apps.map(\.name) == ["Viewer"])
        #expect(session.detail == nil)
        let records = try await ActivityLog(directory: URL(filePath: fixture.path("log"))).readAll().records
        #expect(records.contains { $0.section == .applications && $0.itemPath == app.id })
    }

    @Test("if the bundle cannot be moved, no owned item is touched")
    func bundleFailureStopsBatch() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        try fixture.file("Library/Caches/com.example.writer/blob")
        let session = session()
        await session.load()
        await session.select(app.id)
        try FileManager.default.removeItem(atPath: app.id)
        try fixture.builder.directory("Applications/Writer.app")  // a different folder now sits at the path

        let summary = try #require(await session.uninstall())

        #expect(summary.movedToTrashCount == 0)
        #expect(summary.problems.count == 2)
        #expect(fixture.exists("Library/Caches/com.example.writer"))
    }

    @Test("a running app blocks uninstall until it quits; Quit asks politely and re-checks")
    func runningApp() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        state.running.withLock { $0 = ["com.example.writer"] }
        let session = session()
        await session.load()
        await session.select(app.id)

        #expect(session.detail?.availability == .running)
        #expect(await session.uninstall() == nil)
        #expect(fixture.exists("Applications/Writer.app"))

        await session.quitSelectedApp()

        #expect(state.quitRequests.withLock { $0 } == [app.id])
        #expect(session.detail?.availability == .available)
    }

    @Test("the gate still refuses if the app is opened after review")
    func openedAfterReview() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        let session = session()
        await session.load()
        await session.select(app.id)
        state.running.withLock { $0 = ["com.example.writer"] }

        #expect(await session.uninstall() == nil)
        #expect(session.detail?.availability == .running)
        #expect(fixture.exists("Applications/Writer.app"))
    }

    @Test("protected apps are refused")
    func protectedApp() async throws {
        let app = try fixture.app(AppInventory.clenvraBundleIdentifier, name: "Clenvra")
        let session = session()
        await session.load()

        await session.select(app.id)

        #expect(session.detail?.availability == .protected)
        #expect(session.detail?.items.isEmpty == true)
        #expect(await session.uninstall() == nil)
        #expect(fixture.exists("Applications/Clenvra.app"))
    }

    @Test(
        "S23: security and MDM agents are refused, by identifier or Team ID",
        arguments: [
            ("com.crowdstrike.falcon.App", nil), ("com.jamfsoftware.selfservice.mac", nil),
            ("com.microsoft.wdav", nil), ("com.vendor.agent", "X9E956P446"),
        ] as [(String, String?)])
    func managedAgent(_ identifier: String, _ team: String?) async throws {
        let app = try fixture.app(identifier, name: "Agent", folder: "Applications/Vendor")
        try AppBundleFixture(identifier: "com.vendor.uninstaller").create(
            at: fixture.path("Applications/Vendor/Uninstall Agent.app"))
        try fixture.file("Library/Caches/\(identifier)/blob")
        let session = session(team: team)
        await session.load()

        await session.select(app.id)

        #expect(
            session.detail?.availability
                == .managed(vendorUninstaller: fixture.path("Applications/Vendor/Uninstall Agent.app")))
        #expect(session.detail?.items.isEmpty == true)
        #expect(session.selectedCount == 0)
        #expect(await session.uninstall() == nil)
        #expect(fixture.exists("Applications/Vendor/Agent.app"))
    }

    @Test("a vendor uninstaller inside the bundle is found")
    func vendorUninstallerInBundle() throws {
        let app = try fixture.app("com.sentinelone.agent", name: "Sentinel")
        try AppBundleFixture(identifier: "com.sentinelone.uninstall").create(
            at: app.id + "/Contents/Resources/Uninstall Sentinel.app")

        #expect(ManagedAgents.isManaged(app, teamIdentifier: nil))
        #expect(ManagedAgents.vendorUninstaller(for: app) == app.id + "/Contents/Resources/Uninstall Sentinel.app")
    }

    // MARK: - Reset

    @Test("reset removes selected app data but keeps the bundle, launch items, helpers and Possible items")
    func resetApp() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        _ = try fixture.app("org.other.viewer", name: "Viewer")
        try fixture.file("Library/Caches/com.example.writer/blob", bytes: 50_000)
        try fixture.file("Library/Preferences/com.example.writer.plist")
        try fixture.file("Library/Saved Application State/com.example.writer.savedState/data")
        try fixture.container("CONTAINER-UUID", identifier: "com.example.writer")
        try fixture.file("Library/Application Support/Writer/settings.json")
        try fixture.file("Library/Application Support/Writer Backups/old.json")
        try fixture.file("Library/Logs/com.example.writer/current.log")
        try fixture.plist(
            "Library/LaunchAgents/com.example.writer.helper.plist",
            [
                "Label": "com.example.writer.helper", "Program": "/usr/bin/true",
                "AssociatedBundleIdentifiers": ["com.example.writer"],
            ])
        try fixture.plist(
            "System/LaunchDaemons/com.example.writer.privileged.plist",
            ["Label": "com.example.writer.privileged", "AssociatedBundleIdentifiers": "com.example.writer"])
        let session = session()
        await session.load()

        let items = await session.resetItems(for: app)
        let paths = Set(items.map(\.path))

        #expect(paths.contains(fixture.path("Library/Caches/com.example.writer")))
        #expect(paths.contains(fixture.path("Library/Preferences/com.example.writer.plist")))
        #expect(paths.contains(fixture.path("Library/Saved Application State/com.example.writer.savedState")))
        #expect(paths.contains(fixture.path("Library/Containers/CONTAINER-UUID")))
        #expect(paths.contains(fixture.path("Library/Application Support/Writer")))
        #expect(!paths.contains(fixture.path("Library/Application Support/Writer Backups")))
        #expect(!paths.contains(fixture.path("Library/LaunchAgents/com.example.writer.helper.plist")))
        #expect(!paths.contains(fixture.path("System/LaunchDaemons/com.example.writer.privileged.plist")))
        #expect(items.allSatisfy { $0.confidence != .possible })

        let selected = items.filter { $0.isSelectedByDefault && $0.kind != .logs }
        let preview = try #require(await session.reset(app, items: selected, dryRun: true))
        #expect(preview.wouldRemoveCount == selected.count)
        #expect(fixture.exists("Library/Caches/com.example.writer"))

        let summary = try #require(await session.reset(app, items: selected))

        #expect(summary.movedToTrashCount == selected.count)
        #expect(summary.problems.isEmpty)
        #expect(fixture.exists("Applications/Writer.app"))
        #expect(fixture.exists("Library/Application Support/Writer Backups"))
        #expect(fixture.exists("Library/LaunchAgents/com.example.writer.helper.plist"))
        #expect(fixture.exists("System/LaunchDaemons/com.example.writer.privileged.plist"))
        #expect(fixture.exists("Library/Logs/com.example.writer"))
        for gone in [
            "Library/Caches/com.example.writer", "Library/Preferences/com.example.writer.plist",
            "Library/Saved Application State/com.example.writer.savedState",
            "Library/Containers/CONTAINER-UUID", "Library/Application Support/Writer",
        ] {
            #expect(!fixture.exists(gone), "\(gone) should be in the Trash")
        }
    }

    @Test("a running app blocks reset; the existing Quit flow makes it available")
    func runningAppBlocksReset() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        try fixture.file("Library/Caches/com.example.writer/blob")
        state.running.withLock { $0 = ["com.example.writer"] }
        let session = session()
        await session.load()
        await session.select(app.id)
        let items = await session.resetItems(for: app)

        #expect(session.detail?.availability == .running)
        #expect(await session.reset(app, items: items) == nil)
        #expect(fixture.exists("Library/Caches/com.example.writer"))

        await session.quitSelectedApp()

        #expect(state.quitRequests.withLock { $0 } == [app.id])
        #expect(session.detail?.availability == .available)
        let summary = try #require(await session.reset(app, items: items))
        #expect(summary.movedToTrashCount == 1)
        #expect(fixture.exists("Applications/Writer.app"))
        #expect(!fixture.exists("Library/Caches/com.example.writer"))
    }

    // MARK: - Homebrew

    @Test("Homebrew cask apps are matched by artifact name and can be removed with brew")
    func homebrew() async throws {
        let app = try fixture.app("org.mozilla.firefox", name: "Firefox")
        _ = try fixture.app("com.example.writer", name: "Writer")
        let runner = FakeCommandRunner()
        let brew = "/opt/homebrew/bin/brew"
        runner.stub(
            brew, ["info", "--json=v2", "--installed", "--cask"],
            stdout: """
                {"formulae": [], "casks": [
                  {"token": "firefox", "artifacts": [{"app": ["Firefox.app"]}, {"zap": [{"trash": ["~/x"]}]}]},
                  {"token": "renamed", "artifacts": [{"app": ["Source.app", {"target": "Other.app"}]}]}
                ]}
                """)
        runner.stub(brew, ["uninstall", "--cask", "firefox"], stdout: "==> Uninstalling Cask firefox\n")
        let session = session(homebrew: .init(brew: brew, runner: runner, caskroom: fixture.home + "/Caskroom"))
        await session.load()

        session.filter = .homebrew
        #expect(session.visibleApps.map(\.name) == ["Firefox"])
        await session.select(app.id)
        let command = try #require(session.homebrewCommand)
        #expect(command.executable == brew)
        #expect(command.arguments == ["uninstall", "--cask", "firefox"])

        try FileManager.default.removeItem(atPath: app.id)  // what brew would do
        let result = try #require(await session.uninstallWithHomebrew())

        #expect(result.exitStatus == 0)
        #expect(runner.commands.contains { $0.arguments == ["uninstall", "--cask", "firefox"] })
        #expect(session.homebrewOutput.contains("==> Uninstalling Cask firefox"))
        #expect(session.apps.map(\.name) == ["Writer"])
    }

    @Test("a cask installed with a custom --appdir is matched by the location Homebrew reports, not by name")
    func homebrewCustomAppdir() async throws {
        let app = try fixture.app("org.mozilla.firefox", name: "Firefox")
        let brew = "/opt/homebrew/bin/brew"
        let runner = FakeCommandRunner()
        runner.stub(
            brew, ["info", "--json=v2", "--installed", "--cask"],
            stdout: """
                {"casks": [
                  {"token": "firefox", "artifacts": [{"app": ["Firefox.app"], "target": "\(app.id)"}]},
                  {"token": "elsewhere", "artifacts": [{"app": ["Writer.app"], "target": "/Applications/Writer.app"}]}
                ]}
                """)
        let writer = try fixture.app("com.example.writer", name: "Writer")
        let session = session(homebrew: .init(brew: brew, runner: runner, caskroom: fixture.home + "/Caskroom"))
        await session.load()

        #expect(session.homebrewToken(for: app) == "firefox")
        #expect(session.homebrewToken(for: writer) == nil)
    }

    // MARK: - Leftovers

    @Test("leftovers are scanned, never pre-selected, and removed only when chosen")
    func leftovers() async throws {
        _ = try fixture.app("com.example.writer", name: "Writer")
        try fixture.file("Library/Caches/com.gone.editor/blob")
        try fixture.age("Library/Caches/com.gone.editor", days: 60, now: now)
        try fixture.file("Library/Logs/com.gone.other/old.log")
        try fixture.age("Library/Logs/com.gone.other", days: 60, now: now)
        let session = session()
        await session.load()

        await session.scanLeftovers()

        #expect(session.leftovers.count == 2)
        #expect(session.leftoverSelection.isEmpty)
        session.toggleLeftover(fixture.path("Library/Caches/com.gone.editor"))
        let summary = await session.removeLeftovers()

        #expect(summary.movedToTrashCount == 1)
        #expect(!fixture.exists("Library/Caches/com.gone.editor"))
        #expect(fixture.exists("Library/Logs/com.gone.other"))
        #expect(session.leftovers.map(\.path) == [fixture.path("Library/Logs/com.gone.other")])
    }

    @Test("leftovers of an app in the home Trash are found even when new, and not pre-selected")
    func trashedAppLeftovers() async throws {
        _ = try fixture.app("com.example.writer", name: "Writer")
        try AppBundleFixture(identifier: "com.example.foo").create(at: fixture.path(".Trash/Foo.app"))
        try fixture.file("Library/Caches/com.example.foo/blob")
        let session = session()
        await session.load()

        await session.scanLeftovers()

        #expect(session.leftovers.map(\.path) == [fixture.path("Library/Caches/com.example.foo")])
        #expect(session.leftovers.first?.evidence.contains(.appInTrash("Foo")) == true)
        #expect(session.leftoverSelection.isEmpty)
    }

    @Test("dropping a bundle selects that app")
    func dropSelects() async throws {
        let app = try fixture.app("com.example.writer", name: "Writer")
        let session = session()
        await session.load()

        #expect(await session.select(bundleURL: URL(filePath: app.id)))
        #expect(session.detail?.app.id == app.id)
        #expect(!(await session.select(bundleURL: URL(filePath: fixture.path("Library")))))
    }
}
