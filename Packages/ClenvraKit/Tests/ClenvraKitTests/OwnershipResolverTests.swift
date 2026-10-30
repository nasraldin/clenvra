import Foundation
import Testing

@testable import ClenvraKit

@Suite("OwnershipResolver")
struct OwnershipResolverTests {
    private let fixture: AppsFixture
    private let app: InstalledApp

    init() throws {
        fixture = try AppsFixture()
        app = try fixture.app(
            "com.example.app", name: "Example Writer", plugIns: ["Share": "com.example.app.share"],
            groups: ["ABCDE12345.com.example.shared"])
    }

    private func item(_ items: [OwnedItem], _ relative: String) -> OwnedItem? {
        items.first { $0.path == fixture.path(relative) }
    }

    private func resolve(
        _ app: InstalledApp? = nil, others: [InstalledApp]? = nil, complete: Bool = true,
        resolver: OwnershipResolver? = nil
    ) async -> [OwnedItem] {
        let target = app ?? self.app
        let installed = [target] + (others ?? [fixture.otherApp("org.unrelated.tool", name: "Unrelated")])
        return await (resolver ?? fixture.resolver()).resolve(
            target, installedApps: installed, inventoryIsComplete: complete)
    }

    // MARK: - Certain

    struct ExactCase: Sendable, CustomTestStringConvertible {
        let relative: String
        let kind: OwnedItem.Kind
        let identifier: String
        var testDescription: String { relative }
    }

    @Test(
        "exact identifier paths are Certain and pre-selected",
        arguments: [
            ExactCase(relative: "Library/Caches/com.example.app", kind: .caches, identifier: "com.example.app"),
            ExactCase(
                relative: "Library/Application Support/com.example.app", kind: .applicationSupport,
                identifier: "com.example.app"),
            ExactCase(
                relative: "Library/HTTPStorages/com.example.app", kind: .httpStorage, identifier: "com.example.app"),
            ExactCase(relative: "Library/WebKit/com.example.app", kind: .webKit, identifier: "com.example.app"),
            ExactCase(relative: "Library/Logs/com.example.app", kind: .logs, identifier: "com.example.app"),
            ExactCase(
                relative: "Library/Application Scripts/com.example.app.share", kind: .applicationScripts,
                identifier: "com.example.app.share"),
            ExactCase(
                relative: "Library/Caches/com.example.app.share", kind: .caches, identifier: "com.example.app.share"),
            ExactCase(
                relative: "Library/Preferences/com.example.app.plist", kind: .preferences, identifier: "com.example.app"
            ),
            ExactCase(
                relative: "Library/Preferences/ByHost/com.example.app.0F1E2D3C-AAAA-BBBB-CCCC-112233445566.plist",
                kind: .preferences, identifier: "com.example.app"),
            ExactCase(
                relative: "Library/Saved Application State/com.example.app.savedState", kind: .savedState,
                identifier: "com.example.app"),
            ExactCase(
                relative: "Library/Cookies/com.example.app.binarycookies", kind: .cookies,
                identifier: "com.example.app"),
        ])
    func exactPaths(_ testCase: ExactCase) async throws {
        let isFile = testCase.relative.hasSuffix(".plist") || testCase.relative.hasSuffix(".binarycookies")
        try fixture.file(isFile ? testCase.relative : testCase.relative + "/data.bin", bytes: 12_000)

        let items = await resolve()

        let found = try #require(item(items, testCase.relative))
        #expect(found.kind == testCase.kind)
        #expect(found.confidence == .certain)
        #expect(found.evidence.contains(.exactBundleIdentifierPath(testCase.identifier)))
        #expect(found.isSelectedByDefault)
        #expect(found.handling == .removable)
        #expect(found.sharedWith.isEmpty)
        #expect(found.allocatedSize > 0)
        #expect(found.ruleRoot == (fixture.path(testCase.relative) as NSString).deletingLastPathComponent)
    }

    @Test("look-alike names are not exact matches (ByHost of a sub-identifier, other suffixes)")
    func lookAlikes() async throws {
        try fixture.file("Library/Preferences/ByHost/com.example.app.helper.0F1E2D3C.plist")
        try fixture.file("Library/Preferences/com.example.application.plist")
        try fixture.file("Library/Caches/com.example.apple/blob")

        let items = await resolve()

        #expect(items.allSatisfy { $0.confidence != .certain })
    }

    @Test("identifiers match case-insensitively, like the file system")
    func caseInsensitive() async throws {
        try fixture.file("Library/Caches/COM.Example.App/blob")

        let items = await resolve()

        #expect(item(items, "Library/Caches/COM.Example.App")?.confidence == .certain)
    }

    @Test("containers are matched by metadata, never by folder name")
    func containerMetadata() async throws {
        try fixture.container("8B0E1F2A-RANDOM", identifier: "com.example.app")
        try fixture.container("com.example.app", identifier: "com.someone.else")
        try fixture.container("Share", identifier: "com.example.app.share")

        let items = await resolve()

        let byMetadata = try #require(item(items, "Library/Containers/8B0E1F2A-RANDOM"))
        #expect(byMetadata.kind == .container)
        #expect(byMetadata.confidence == .certain)
        #expect(byMetadata.evidence == [.containerMetadata("com.example.app")])
        #expect(byMetadata.isSelectedByDefault)
        #expect(byMetadata.ruleRoot == fixture.path("Library/Containers"))
        #expect(item(items, "Library/Containers/com.example.app") == nil)
        let embedded = try #require(item(items, "Library/Containers/Share"))
        #expect(embedded.evidence == [.containerMetadata("com.example.app.share")])
        #expect(embedded.isSelectedByDefault)
    }

    @Test("launch agents are Certain through AssociatedBundleIdentifiers or a program inside the bundle")
    func launchAgents() async throws {
        try fixture.plist(
            "Library/LaunchAgents/com.example.updater.plist",
            [
                "Label": "com.example.updater", "Program": "/usr/bin/true",
                "AssociatedBundleIdentifiers": ["com.example.app"],
            ])
        try fixture.plist(
            "Library/LaunchAgents/com.example.helper.plist",
            ["Label": "com.example.helper", "ProgramArguments": [app.id + "/Contents/MacOS/exe", "--daemon"]])
        try fixture.plist(
            "Library/LaunchAgents/org.other.agent.plist", ["Label": "org.other.agent", "Program": "/usr/bin/true"])

        let items = await resolve()

        let associated = try #require(item(items, "Library/LaunchAgents/com.example.updater.plist"))
        #expect(associated.kind == .launchAgent)
        #expect(associated.confidence == .certain)
        #expect(associated.evidence == [.associatedBundleIdentifier("com.example.app")])
        #expect(associated.isSelectedByDefault)
        let program = try #require(item(items, "Library/LaunchAgents/com.example.helper.plist"))
        #expect(program.evidence == [.programInsideBundle(app.id + "/Contents/MacOS/exe")])
        #expect(item(items, "Library/LaunchAgents/org.other.agent.plist") == nil)
    }

    @Test("system launch daemons pointing into the bundle are listed reveal-only")
    func systemLaunchDaemon() async throws {
        try fixture.plist(
            "System/LaunchDaemons/com.example.privileged.plist",
            ["Label": "com.example.privileged", "AssociatedBundleIdentifiers": "com.example.app"])

        let items = await resolve()

        let daemon = try #require(item(items, "System/LaunchDaemons/com.example.privileged.plist"))
        #expect(daemon.handling == .revealOnly)
        #expect(!daemon.isSelectedByDefault)
    }

    // MARK: - Likely

    @Test("the app's group container is Likely and pre-selected when no other app uses the group")
    func groupContainer() async throws {
        try fixture.file("Library/Group Containers/ABCDE12345.com.example.shared/db")

        let items = await resolve()

        let group = try #require(item(items, "Library/Group Containers/ABCDE12345.com.example.shared"))
        #expect(group.kind == .groupContainer)
        #expect(group.confidence == .likely)
        #expect(group.evidence == [.applicationGroup("ABCDE12345.com.example.shared")])
        #expect(group.isSelectedByDefault)
    }

    @Test("S19: a group container claimed by two apps is not pre-selected for either")
    func sharedGroupContainer() async throws {
        try fixture.file("Library/Group Containers/ABCDE12345.com.example.shared/db")
        let sibling = try fixture.app(
            "com.example.notes", name: "Example Notes", groups: ["ABCDE12345.com.example.shared"])

        let forApp = await resolve(app, others: [sibling])
        let forSibling = await resolve(sibling, others: [app])

        let path = "Library/Group Containers/ABCDE12345.com.example.shared"
        let first = try #require(item(forApp, path))
        let second = try #require(item(forSibling, path))
        #expect(first.sharedWith == [sibling.id])
        #expect(second.sharedWith == [app.id])
        #expect(!first.isSelectedByDefault)
        #expect(!second.isSelectedByDefault)
    }

    @Test("exact app-name folders are Likely")
    func exactName() async throws {
        try fixture.file("Library/Application Support/Example Writer/settings.json")
        try fixture.file("Library/Caches/example writer/blob")
        try fixture.file("Library/Logs/Example Writer/today.log")

        let items = await resolve()

        for relative in [
            "Library/Application Support/Example Writer", "Library/Caches/example writer",
            "Library/Logs/Example Writer",
        ] {
            let found = try #require(item(items, relative))
            #expect(found.confidence == .likely)
            #expect(found.evidence == [.exactName("Example Writer")])
            #expect(found.isSelectedByDefault)
        }
    }

    @Test("an incomplete inventory pre-selects only Certain items")
    func incompleteInventory() async throws {
        try fixture.file("Library/Caches/com.example.app/blob")
        try fixture.file("Library/Application Support/Example Writer/settings.json")

        for items in [await resolve(complete: false), await resolve(others: [])] {
            #expect(item(items, "Library/Caches/com.example.app")?.isSelectedByDefault == true)
            #expect(item(items, "Library/Application Support/Example Writer")?.isSelectedByDefault == false)
        }
    }

    // MARK: - Possible

    @Test("S20: whole-word name matches are Possible and never pre-selected")
    func nameMatch() async throws {
        try fixture.file("Library/Application Support/Example Writer Backups/old.db")

        let items = await resolve()

        let found = try #require(item(items, "Library/Application Support/Example Writer Backups"))
        #expect(found.confidence == .possible)
        #expect(found.evidence == [.nameMatch("Example Writer")])
        #expect(!found.isSelectedByDefault)
    }

    struct NameCase: Sendable, CustomTestStringConvertible {
        let appName: String
        let entry: String
        let matches: Bool
        var testDescription: String { "\(appName) ~ \(entry)" }
    }

    @Test(
        "name matching needs whole words and at least four characters",
        arguments: [
            NameCase(appName: "Zoom", entry: "Zoom Helper", matches: true),
            NameCase(appName: "Zoom", entry: "us.zoom.cache", matches: true),
            NameCase(appName: "Zoom", entry: "ZoomIt", matches: false),
            NameCase(appName: "Zoom", entry: "Kazoom", matches: false),
            NameCase(appName: "Arc", entry: "Arc Data", matches: false),
        ])
    func wholeWord(_ testCase: NameCase) {
        #expect(OwnershipResolver.containsWholeWord(testCase.appName, in: testCase.entry) == testCase.matches)
    }

    @Test("a name match also claimed by another installed app is not shown")
    func ambiguousNameMatch() async throws {
        try fixture.file("Library/Application Support/Example Writer Pro Sync/data")
        let pro = fixture.otherApp("com.vendor.pro", name: "Writer Pro")

        let items = await resolve(others: [pro])

        #expect(item(items, "Library/Application Support/Example Writer Pro Sync") == nil)
    }

    // MARK: - Shared guard and protection

    @Test("an item whose identifier shares lineage with another installed app is reported shared, not pre-selected")
    func lineage() async throws {
        try fixture.file("Library/Caches/com.example.app/blob")
        let beta = fixture.otherApp("com.example.app.beta", name: "Example Beta")

        let items = await resolve(others: [beta])

        let found = try #require(item(items, "Library/Caches/com.example.app"))
        #expect(found.sharedWith == [beta.id])
        #expect(!found.isSelectedByDefault)
    }

    @Test("another app embedding the same identifier makes the item shared")
    func embeddedByAnother() async throws {
        try fixture.file("Library/Caches/com.example.app.share/blob")
        let suite = fixture.otherApp("org.suite.main", name: "Suite", embedded: ["com.example.app.share"])

        let items = await resolve(others: [suite])

        #expect(item(items, "Library/Caches/com.example.app.share")?.sharedWith == [suite.id])
    }

    @Test("protected apps own nothing that can be offered")
    func protectedApp() async throws {
        let apple = try fixture.app("com.apple.Notes", name: "Notes", isProtected: true)
        try fixture.file("Library/Caches/com.apple.Notes/blob")

        #expect(await resolve(apple).isEmpty)
    }

    @Test("protected locations are never offered; folders holding protected files are never pre-selected")
    func protectedPaths() async throws {
        try fixture.file("Library/Caches/com.example.app/blob")
        try fixture.file("Library/Application Support/com.example.app/key.pem")
        let policy = ProtectionPolicy(
            home: fixture.home, additionalProtected: [fixture.path("Library/Caches/com.example.app")])

        let items = await resolve(resolver: fixture.resolver(policy: policy))

        #expect(item(items, "Library/Caches/com.example.app") == nil)
        let guarded = try #require(item(items, "Library/Application Support/com.example.app"))
        #expect(guarded.containsProtectedItem)
        #expect(!guarded.isSelectedByDefault)
    }

    // MARK: - Receipts

    @Test("receipt files outside the home folder are listed reveal-only")
    func receipts() async throws {
        try fixture.file("SystemLibrary/PrivilegedHelperTools/com.example.app.helper")
        let helper = fixture.path("SystemLibrary/PrivilegedHelperTools/com.example.app.helper")
        let missing = fixture.path("SystemLibrary/Gone")
        let resolver = fixture.resolver(receipts: { identifiers in
            guard identifiers.contains("com.example.app") else { return [] }
            return [
                .init(path: helper, packageIdentifier: "com.example.app.pkg"),
                .init(path: missing, packageIdentifier: "com.example.app.pkg"),
            ]
        })

        let items = await resolve(resolver: resolver)

        let found = try #require(items.first { $0.path == helper })
        #expect(found.kind == .systemFile)
        #expect(found.handling == .revealOnly)
        #expect(found.evidence == [.receipt("com.example.app.pkg")])
        #expect(!found.isSelectedByDefault)
        #expect(!items.contains { $0.path == missing })
    }

    @Test("pkgutil receipts are reduced to top-level entries below known system folders")
    func pkgutilParsing() async throws {
        let runner = FakeCommandRunner()
        runner.stub("/usr/sbin/pkgutil", ["--pkgs"], stdout: "com.apple.pkg.Core\ncom.example.app.pkg\norg.other\n")
        let info: [String: Any] = ["pkgid": "com.example.app.pkg", "volume": "/", "install-location": "/"]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        runner.stub(
            "/usr/sbin/pkgutil", ["--pkg-info-plist", "com.example.app.pkg"],
            stdout: String(decoding: infoData, as: UTF8.self))
        runner.stub(
            "/usr/sbin/pkgutil", ["--files", "com.example.app.pkg"],
            stdout: """
                .
                Applications/Example.app
                Applications/Example.app/Contents/Info.plist
                Library
                Library/Application Support
                Library/Application Support/Example
                Library/Application Support/Example/engine.bin
                Library/LaunchDaemons/com.example.app.helper.plist
                Library/PrivilegedHelperTools/com.example.app.helper
                """)
        let lookup = OwnershipResolver.pkgutilReceipts(runner: runner)

        let files = await lookup(["com.example.app"])

        #expect(
            files.map(\.path) == [
                "/Library/Application Support/Example", "/Library/LaunchDaemons/com.example.app.helper.plist",
                "/Library/PrivilegedHelperTools/com.example.app.helper",
            ])
        #expect(files.allSatisfy { $0.packageIdentifier == "com.example.app.pkg" })
    }

    // MARK: - Leftovers of removed apps

    @Test("leftovers: old reverse-DNS entries with no installed owner are Possible and never pre-selected")
    func leftovers() async throws {
        let now = Date()
        let entries = [
            "Library/Caches/com.gone.editor",  // orphan
            "Library/Application Support/com.gone.editor",  // orphan
            "Library/Caches/com.recent.gone",  // too recent
            "Library/Caches/com.example.app.cache",  // lineage of an installed app
            "Library/Caches/com.example.app.share",  // embedded id of an installed app
            "Library/Caches/com.apple.Safari.cache",  // never-flag
            "Library/Caches/org.chromium.Chromium",
            "Library/Caches/com.google.Keystone.agent",
            "Library/Caches/com.github.Electron.helper",
            "Library/Caches/org.sparkle-project.Sparkle",
            "Library/Caches/io.qt.QtWebEngine",
            "Library/Caches/com.microsoft.autoupdate2",
            "Library/Caches/gone.editor",  // only two components
        ]
        for entry in entries {
            try fixture.file(entry + "/blob")
            try fixture.age(entry, days: entry.contains("recent") ? 3 : 90, now: now)
        }
        try fixture.file("Library/Preferences/com.gone.editor.plist")
        try fixture.age("Library/Preferences/com.gone.editor.plist", days: 90, now: now)
        try fixture.container("F00D-1234", identifier: "com.gone.sandboxed")
        try fixture.age("Library/Containers/F00D-1234", days: 90, now: now)

        let found = await fixture.resolver().leftovers(installedApps: [app], now: now)

        #expect(
            Set(found.map(\.path))
                == Set(
                    [
                        "Library/Caches/com.gone.editor", "Library/Application Support/com.gone.editor",
                        "Library/Preferences/com.gone.editor.plist", "Library/Containers/F00D-1234",
                    ].map(fixture.path)))
        #expect(found.allSatisfy { !$0.isSelectedByDefault && $0.confidence == .possible })
        #expect(
            found.first { $0.path == fixture.path("Library/Containers/F00D-1234") }?.evidence == [
                .containerMetadata("com.gone.sandboxed")
            ])
    }

    @Test("leftovers are not reported without a complete inventory")
    func leftoversNeedInventory() async throws {
        let now = Date()
        try fixture.file("Library/Caches/com.gone.editor/blob")
        try fixture.age("Library/Caches/com.gone.editor", days: 90, now: now)

        #expect(await fixture.resolver().leftovers(installedApps: [], now: now).isEmpty)
        #expect(
            await fixture.resolver().leftovers(installedApps: [app], inventoryIsComplete: false, now: now).isEmpty)
    }

    // MARK: - Leftovers of apps in the Trash

    /// `~/.Trash/Foo.app` (`com.example.foo`) and its Application Support folder, modified today.
    private func trashedFoo() throws -> [InstalledApp] {
        try AppBundleFixture(identifier: "com.example.foo").create(at: fixture.path(".Trash/Foo.app"))
        try fixture.file("Library/Application Support/com.example.foo/data")
        return AppInventory.appsInTrash(trashRoots: [fixture.path(".Trash")])
    }

    @Test("data of an app in the Trash is listed even when new, as Likely and never pre-selected")
    func trashedAppDataIsListedEvenIfNew() async throws {
        let trashed = try trashedFoo()
        #expect(trashed.map(\.bundleIdentifier) == ["com.example.foo"])

        let found = await fixture.resolver().leftovers(installedApps: [app], trashedApps: trashed, now: Date())

        let leftover = try #require(item(found, "Library/Application Support/com.example.foo"))
        #expect(leftover.evidence.contains(.appInTrash("Foo")))
        #expect(leftover.evidence.contains(.exactBundleIdentifierPath("com.example.foo")))
        #expect(leftover.confidence == .likely)
        #expect(!leftover.isSelectedByDefault)
    }

    @Test("without the app in the Trash, new data stays hidden by the 30-day rule")
    func withoutTrashedAppNewDataIsHidden() async throws {
        _ = try trashedFoo()

        let found = await fixture.resolver().leftovers(installedApps: [app], now: Date())

        #expect(item(found, "Library/Application Support/com.example.foo") == nil)
    }

    @Test("an installed app with the trashed app's identifier wins: its data is never listed")
    func installedWins() async throws {
        let trashed = try trashedFoo()
        let installed = [app, fixture.otherApp("com.example.foo", name: "Foo")]

        let found = await fixture.resolver().leftovers(installedApps: installed, trashedApps: trashed, now: Date())

        #expect(item(found, "Library/Application Support/com.example.foo") == nil)
    }

    @Test("an installed app sharing the trashed app's identifier prefix keeps its data")
    func installedLineageWins() async throws {
        try AppBundleFixture(identifier: "com.example.foo.lite").create(at: fixture.path(".Trash/Foo Lite.app"))
        try fixture.file("Library/Application Support/com.example.foo.lite/data")
        try fixture.file("Library/Caches/com.example.foo/data")
        let trashed = AppInventory.appsInTrash(trashRoots: [fixture.path(".Trash")])
        let installed = [app, fixture.otherApp("com.example.foo", name: "Foo")]

        let found = await fixture.resolver().leftovers(installedApps: installed, trashedApps: trashed, now: Date())

        #expect(found.isEmpty)
    }

    @Test(
        "never-flag prefixes", arguments: OwnershipResolver.neverFlagPrefixes)
    func neverFlag(_ prefix: String) {
        #expect(OwnershipResolver.isNeverFlagged(prefix + "x.y"))
        #expect(!OwnershipResolver.isNeverFlagged("com.vendor.app"))
    }

    @Test(
        "macOS group containers are never leftovers, whatever their group or team prefix",
        arguments: [
            "group.com.apple.calendar", "systemgroup.com.apple.configurationprofiles",
            "243LU875E5.groups.com.apple.podcasts", "UBF8T346G9.group.com.apple.notes",
        ])
    func appleGroupsNeverFlagged(_ identifier: String) {
        #expect(OwnershipResolver.isNeverFlagged(identifier))
    }

    @Test("a third-party group container can still be a leftover")
    func otherGroupsCanBeFlagged() {
        #expect(!OwnershipResolver.isNeverFlagged("group.com.vendor.app"))
        #expect(!OwnershipResolver.isNeverFlagged("ABCDE12345.group.com.vendor.app"))
    }
}
