import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Sample `pluginkit -mAvvv` output in the format macOS 26 prints; identifiers and paths are made up.
enum PluginKitSample {
    static func output(home: String) -> String {
        """
        +    com.example.notes.ShareExtension(2.1)
        \t            Path = /Applications/Notes Pro.app/Contents/PlugIns/Share.appex
        \t            UUID = 0A1B2C3D-0000-4000-8000-000000000001
        \t       Timestamp = 2026-01-02 10:00:00 +0000
        \t             SDK = com.apple.share-services
        \t   Parent Bundle = /Applications/Notes Pro.app
        \t    Display Name = Notes Pro Share
        \t      Short Name = Share
        \t     Parent Name = Notes Pro
        \t        Platform = macOS

        -    com.example.blocker.Safari(1.0)
        \t            Path = \(home)/Applications/Blocker.app/Contents/PlugIns/Blocker Safari.appex
        \t            UUID = 0A1B2C3D-0000-4000-8000-000000000002
        \t             SDK = com.apple.Safari.content-blocker
        \t   Parent Bundle = \(home)/Applications/Blocker.app
        \t    Display Name = Blocker
        \t        Platform = macOS

             com.apple.reminders.quicklookextension(7.0)
        \t            Path = /System/Applications/Reminders.app/Contents/PlugIns/RemindersQuickLookExtension.appex
        \t             SDK = com.apple.quicklook.preview
        \t   Parent Bundle = /System/Applications/Reminders.app
        \t    Display Name = Reminders
        \t        Platform = macOS

             com.example.poster.Gradient((null))
        \t            Path = /Library/ExtensionKit/Extensions/Gradient.appex
        \t             SDK = com.apple.posterkit.provider
        \t    Display Name = Gradient
        \t        Platform = Mac Catalyst

        +    com.microsoft.wdav.finder(1.0)
        \t            Path = /Applications/Defender.app/Contents/PlugIns/Finder.appex
        \t             SDK = com.apple.FinderSync
        \t   Parent Bundle = /Applications/Defender.app
        \t    Display Name = Defender Finder
        \t        Platform = macOS

         (5 plug-ins)

        """
    }
}

/// Sample `systemextensionsctl list` output in the format macOS 26 prints; identifiers are made up.
enum SystemExtensionsSample {
    static let output = """
        3 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & \
        Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tAB12CD34EF\tcom.example.firewall.extension (4.5.3/4.5.3)\tFirewall\t[activated enabled]
        --- com.apple.system_extension.driver_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t\tZZ98YY76XX\tcom.example.audio.driver (2.0/200)\tExample Audio Driver\t[activated disabled]
        --- com.apple.system_extension.endpoint_security
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tQQ11WW22EE\tcom.example.shield (10.1/380)\tShield\t[activated enabled]

        """
}

@Suite("PluginReader")
struct PluginReaderTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let runner = FakeCommandRunner()

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("home")
        try fixture.directory("system")
    }

    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func reader(teams: [String: String] = [:]) -> PluginReader {
        PluginReader(
            home: path("home"), systemRoot: path("system"), runner: runner,
            teamIdentifier: { teams[$0] })
    }

    /// A bundle with `Contents/Info.plist`; `info` nil writes no Info.plist.
    @discardableResult
    private func bundle(_ relative: String, info: [String: String]? = [:]) throws -> String {
        try fixture.directory(relative + "/Contents/MacOS")
        try fixture.file(relative + "/Contents/MacOS/exe", bytes: 64)
        if let info {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: fixture.url(relative + "/Contents/Info.plist"))
        }
        return path(relative)
    }

    private func item(_ items: [PluginItem], at relative: String) throws -> PluginItem {
        try #require(items.first { $0.path == path(relative) })
    }

    // MARK: - File-based plug-ins

    @Test(
        "every plug-in folder of the user's Library is read, with metadata and the folder as removal root",
        arguments: [
            ("Library/PreferencePanes", "Pane.prefPane", PluginItem.Kind.preferencePane),
            ("Library/QuickLook", "Preview.qlgenerator", .quickLook),
            ("Library/Spotlight", "Importer.mdimporter", .spotlightImporter),
            ("Library/Audio/Plug-Ins/Components", "Synth.component", .audioUnit),
            ("Library/Audio/Plug-Ins/VST", "Synth.vst", .vstPlugIn),
            ("Library/Audio/Plug-Ins/VST3", "Synth.vst3", .vst3PlugIn),
            ("Library/Audio/Plug-Ins/HAL", "Loopback.driver", .halPlugIn),
            ("Library/Audio/Plug-Ins/MAS", "Effect.mas", .masPlugIn),
            ("Library/Internet Plug-Ins", "Player.plugin", .internetPlugIn),
        ])
    func userFolders(folder: String, name: String, kind: PluginItem.Kind) throws {
        try bundle(
            "home/\(folder)/\(name)",
            info: [
                "CFBundleIdentifier": "com.example.thing", "CFBundleName": "Thing",
                "CFBundleShortVersionString": "3.2", "CFBundleVersion": "320",
            ])

        let items = reader().readBundles().items

        #expect(items.count == 1)
        let found = try item(items, at: "home/\(folder)/\(name)")
        #expect(found.kind == kind)
        #expect(found.name == "Thing")
        #expect(found.bundleIdentifier == "com.example.thing")
        #expect(found.version == "3.2")
        #expect(found.domain == .user)
        #expect(found.handling == .removable)
        #expect(found.ruleRoot == path("home/\(folder)"))
        #expect(found.snapshot != nil)
        #expect((found.size ?? 0) > 0)
    }

    @Test("the display name wins over the bundle name, and a bundle without Info.plist is named after its file")
    func names() throws {
        try bundle(
            "home/Library/PreferencePanes/A.prefPane",
            info: ["CFBundleDisplayName": "Shown", "CFBundleName": "Plain", "CFBundleVersion": "7"])
        try bundle("home/Library/PreferencePanes/Bare.prefPane", info: nil)

        let items = reader().readBundles().items

        let shown = try item(items, at: "home/Library/PreferencePanes/A.prefPane")
        #expect(shown.name == "Shown")
        #expect(shown.version == "7")
        let bare = try item(items, at: "home/Library/PreferencePanes/Bare.prefPane")
        #expect(bare.name == "Bare")
        #expect(bare.bundleIdentifier == nil)
        #expect(bare.handling == .removable)
    }

    @Test("system-domain plug-ins are listed but can only be revealed")
    func systemDomain() throws {
        try bundle("system/Library/QuickLook/Sys.qlgenerator", info: ["CFBundleIdentifier": "com.example.sys"])

        let found = try item(reader().readBundles().items, at: "system/Library/QuickLook/Sys.qlgenerator")

        #expect(found.domain == .system)
        #expect(found.handling == .revealOnly)
        #expect(found.deletionItem() == nil)
    }

    @Test("Apple's own plug-ins are never removable, even in the user's Library")
    func applePlugIn() throws {
        try bundle("home/Library/QuickLook/Apple.qlgenerator", info: ["CFBundleIdentifier": "com.apple.qlthing"])

        let found = try item(reader().readBundles().items, at: "home/Library/QuickLook/Apple.qlgenerator")

        #expect(found.isApple)
        #expect(found.handling == .revealOnly)
    }

    @Test("plug-ins of security or management software are managed, by identifier or by signing team (S23)")
    func managed() throws {
        try bundle(
            "home/Library/PreferencePanes/Agent.prefPane", info: ["CFBundleIdentifier": "com.crowdstrike.pane"])
        let signed = try bundle(
            "home/Library/Internet Plug-Ins/Vpn.plugin", info: ["CFBundleIdentifier": "com.unfamiliar.vpn"])

        let items = reader(teams: [signed: "X9E956P446"]).readBundles().items

        #expect(try item(items, at: "home/Library/PreferencePanes/Agent.prefPane").handling == .managed)
        #expect(try item(items, at: "home/Library/Internet Plug-Ins/Vpn.plugin").handling == .managed)
    }

    @Test("a symlinked plug-in is shown but never followed or offered for removal")
    func symlink() throws {
        let target = try bundle("elsewhere/Real.component", info: ["CFBundleIdentifier": "com.example.real"])
        try fixture.directory("home/Library/Audio/Plug-Ins/Components")
        try fixture.symlink("home/Library/Audio/Plug-Ins/Components/Link.component", to: target)
        let asked = Mutex<[String]>([])
        let recorder = PluginReader(
            home: path("home"), systemRoot: path("system"), runner: runner,
            teamIdentifier: { path in
                asked.withLock { $0.append(path) }
                return nil
            })

        let found = try item(
            recorder.readBundles().items, at: "home/Library/Audio/Plug-Ins/Components/Link.component")

        #expect(found.handling == .revealOnly)
        #expect(found.bundleIdentifier == nil)
        #expect(found.name == "Link")
        #expect(asked.withLock { $0.isEmpty })
    }

    @Test("hidden entries and loose files are ignored; missing folders are not a problem")
    func ignored() throws {
        try fixture.file("home/Library/PreferencePanes/.DS_Store", bytes: 10)
        try fixture.file("home/Library/PreferencePanes/notes.txt", bytes: 10)

        let result = reader().readBundles()

        #expect(result.items.isEmpty)
        #expect(result.issues.isEmpty)
    }

    // MARK: - App extensions

    @Test("pluginkit output becomes view-only app extensions with state, extension point and containing app")
    func appExtensions() async throws {
        let home = path("home")
        runner.stub("/usr/bin/pluginkit", ["-mAvvv"], stdout: PluginKitSample.output(home: home))

        let result = await reader().readAppExtensions()

        #expect(result.issues.isEmpty)
        #expect(result.items.count == 5)
        #expect(result.items.allSatisfy { $0.kind == .appExtension })
        let share = try #require(result.items.first { $0.bundleIdentifier == "com.example.notes.ShareExtension" })
        #expect(share.name == "Notes Pro Share")
        #expect(share.version == "2.1")
        #expect(share.isEnabled == true)
        #expect(share.extensionPoint == "com.apple.share-services")
        #expect(share.containingApp == "/Applications/Notes Pro.app")
        #expect(share.domain == .appBundle)
        #expect(share.path == "/Applications/Notes Pro.app/Contents/PlugIns/Share.appex")
        #expect(share.handling == .revealOnly)
        #expect(share.deletionItem() == nil)

        let blocker = try #require(result.items.first { $0.bundleIdentifier == "com.example.blocker.Safari" })
        #expect(blocker.isEnabled == false)
        #expect(blocker.containingApp == home + "/Applications/Blocker.app")

        let reminders = try #require(result.items.first { $0.bundleIdentifier?.hasPrefix("com.apple.") == true })
        #expect(reminders.isApple)
        #expect(reminders.isEnabled == nil)

        let gradient = try #require(result.items.first { $0.bundleIdentifier == "com.example.poster.Gradient" })
        #expect(gradient.version == nil)
        #expect(gradient.domain == .system)
        #expect(gradient.containingApp == nil)

        let defender = try #require(result.items.first { $0.bundleIdentifier == "com.microsoft.wdav.finder" })
        #expect(defender.handling == .managed)
    }

    @Test(
        "unreadable pluginkit output gives no items and a reason",
        arguments: ["", "hello world\nthis is not pluginkit\n", "+ (garbage\n\tPath = /x\n", "\u{0}\u{1}\u{2}"])
    func pluginKitGarbage(output: String) async {
        runner.stub("/usr/bin/pluginkit", ["-mAvvv"], stdout: output)

        let result = await reader().readAppExtensions()

        #expect(result.items.isEmpty)
        #expect(result.issues == [.unreadableOutput(.appExtensions)])
    }

    @Test("a pluginkit that fails or cannot be run gives no items and a reason")
    func pluginKitFailure() async {
        runner.stub("/usr/bin/pluginkit", ["-mAvvv"], stderr: "boom", status: 1)
        #expect(await reader().readAppExtensions().issues == [.commandFailed(.appExtensions)])

        let missing = PluginReader(
            home: path("home"), systemRoot: path("system"), runner: FakeCommandRunner(), teamIdentifier: { _ in nil })
        #expect(await missing.readAppExtensions().issues == [.commandFailed(.appExtensions)])
    }

    // MARK: - System extensions

    @Test("systemextensionsctl output becomes view-only system extensions; security and network ones are managed")
    func systemExtensions() async throws {
        runner.stub("/usr/bin/systemextensionsctl", ["list"], stdout: SystemExtensionsSample.output)

        let result = await reader().readSystemExtensions()

        #expect(result.issues.isEmpty)
        #expect(result.items.count == 3)
        #expect(result.items.allSatisfy { $0.kind == .systemExtension && $0.domain == .system && $0.path == nil })
        let firewall = try #require(result.items.first { $0.bundleIdentifier == "com.example.firewall.extension" })
        #expect(firewall.name == "Firewall")
        #expect(firewall.version == "4.5.3")
        #expect(firewall.teamIdentifier == "AB12CD34EF")
        #expect(firewall.isEnabled == true)
        #expect(firewall.extensionPoint == "com.apple.system_extension.network_extension")
        #expect(firewall.state == "activated enabled")
        #expect(firewall.handling == .managed)

        let driver = try #require(result.items.first { $0.bundleIdentifier == "com.example.audio.driver" })
        #expect(driver.isEnabled == false)
        #expect(driver.version == "2.0")
        #expect(driver.handling == .revealOnly)

        let shield = try #require(result.items.first { $0.bundleIdentifier == "com.example.shield" })
        #expect(shield.handling == .managed)
    }

    @Test("a Mac without system extensions is not a problem")
    func noSystemExtensions() async {
        runner.stub("/usr/bin/systemextensionsctl", ["list"], stdout: "0 extension(s)\n")

        let result = await reader().readSystemExtensions()

        #expect(result.items.isEmpty)
        #expect(result.issues.isEmpty)
    }

    @Test(
        "unreadable systemextensionsctl output gives no items and a reason",
        arguments: [
            "", "nonsense\n", "2 extension(s)\n--- x\nenabled\tactive\n*\tbroken row\n",
            "1 extension(s)\n*\t*\tTEAM\tno-version-here\tName\t[activated enabled]\n",
        ])
    func systemExtensionsGarbage(output: String) async {
        runner.stub("/usr/bin/systemextensionsctl", ["list"], stdout: output)

        let result = await reader().readSystemExtensions()

        #expect(result.items.isEmpty)
        #expect(result.issues == [.unreadableOutput(.systemExtensions)])
    }

    @Test("both commands are run read-only, by absolute path, with fixed arguments")
    func commands() async {
        runner.stub("/usr/bin/pluginkit", ["-mAvvv"], stdout: PluginKitSample.output(home: path("home")))
        runner.stub("/usr/bin/systemextensionsctl", ["list"], stdout: SystemExtensionsSample.output)

        _ = await reader().read()

        #expect(
            Set(runner.commands.map { [$0.executable] + $0.arguments }) == [
                ["/usr/bin/pluginkit", "-mAvvv"], ["/usr/bin/systemextensionsctl", "list"],
            ])
    }
}
