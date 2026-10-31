import Foundation
import Testing

@testable import ClenvraKit

@Suite("AppInventory")
struct AppInventoryTests {
    private let scratch: TemporaryDirectory

    init() throws {
        scratch = try TemporaryDirectory()
    }

    private func path(_ relative: String) -> String {
        scratch.url.appending(path: relative).path(percentEncoded: false)
    }

    private func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    private func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }

    /// Fake system, Setapp and Caskroom locations inside the scratch directory.
    private var locations: AppInventory.Locations {
        AppInventory.Locations(
            systemRoots: [path("System/Applications")],
            setappRoots: [path("Applications/Setapp")],
            homebrewCaskroom: path("Caskroom")
        )
    }

    private func discover(_ roots: [String]) async -> [InstalledApp] {
        await AppInventory.discover(roots: roots.map(path), locations: locations)
    }

    private func app(_ relative: String) -> InstalledApp? {
        AppInventory.app(at: path(relative), locations: locations)
    }

    // MARK: - app(at:)

    @Test("reads identifier, name, version and build from Info.plist")
    func readsInfoPlist() throws {
        var fixture = AppBundleFixture()
        fixture.identifier = "com.example.editor"
        fixture.displayName = "Editor Pro"
        fixture.bundleName = "Editor"
        fixture.version = "2.3.1"
        fixture.build = "2310"
        try fixture.create(at: path("Applications/Editor.app"))

        let result = try #require(app("Applications/Editor.app"))

        #expect(result.id == path("Applications/Editor.app"))
        #expect(result.url == URL(filePath: path("Applications/Editor.app"), directoryHint: .isDirectory))
        #expect(result.bundleIdentifier == "com.example.editor")
        #expect(result.name == "Editor Pro")
        #expect(result.version == "2.3.1")
        #expect(result.build == "2310")
        #expect(result.source == .other)
        #expect(!result.isProtected)
        #expect(result.applicationGroups == nil)
    }

    @Test("name falls back from display name to bundle name to file name")
    func nameFallback() throws {
        var named = AppBundleFixture()
        named.bundleName = "Bundle Name"
        try named.create(at: path("A/First.app"))
        try AppBundleFixture().create(at: path("A/File Name.app"))

        #expect(app("A/First.app")?.name == "Bundle Name")
        #expect(app("A/File Name.app")?.name == "File Name")
    }

    @Test("an app without a bundle identifier is still listed and not protected")
    func missingIdentifier() throws {
        var fixture = AppBundleFixture()
        fixture.identifier = nil
        try fixture.create(at: path("A/Anon.app"))

        let result = try #require(app("A/Anon.app"))
        #expect(result.bundleIdentifier == nil)
        #expect(!result.isProtected)
    }

    @Test("missing Info.plist or a non-.app path yields nil")
    func notAnApp() throws {
        var fixture = AppBundleFixture()
        fixture.writeInfoPlist = false
        try fixture.create(at: path("A/Broken.app"))
        try AppBundleFixture().create(at: path("A/Thing.bundle"))

        #expect(app("A/Broken.app") == nil)
        #expect(app("A/Thing.bundle") == nil)
        #expect(app("A/Missing.app") == nil)
    }

    @Test("collects embedded bundle identifiers from extensions, login items, XPC services and helpers")
    func embeddedIdentifiers() throws {
        var fixture = AppBundleFixture()
        fixture.plugIns = ["Share": "com.example.app.share", "Widget": "com.example.app.widget"]
        fixture.loginItems = ["Launcher": "com.example.app.launcher"]
        fixture.xpcServices = ["Renderer": "com.example.app.renderer"]
        fixture.launchServicesHelpers = ["com.example.app.privileged-helper"]
        try fixture.create(at: path("A/Host.app"))

        let result = try #require(app("A/Host.app"))
        #expect(
            result.embeddedBundleIdentifiers == [
                "com.example.app.launcher", "com.example.app.privileged-helper", "com.example.app.renderer",
                "com.example.app.share", "com.example.app.widget",
            ])
    }

    // MARK: - Source

    @Test("an App Store receipt marks the app as App Store")
    func appStoreSource() throws {
        var fixture = AppBundleFixture()
        fixture.masReceipt = true
        try fixture.create(at: path("Applications/Store.app"))

        #expect(app("Applications/Store.app")?.source == .appStore)
    }

    @Test("apps under the Setapp folder are Setapp apps")
    func setappSource() throws {
        try AppBundleFixture().create(at: path("Applications/Setapp/Tool.app"))

        #expect(app("Applications/Setapp/Tool.app")?.source == .setapp)
    }

    @Test("a symlink into the Caskroom is listed at its real path as a Homebrew app")
    func homebrewSymlink() async throws {
        try AppBundleFixture().create(at: path("Caskroom/my-tool/1.2.0/My Tool.app"))
        try makeDirectory("Applications")
        try symlink("Applications/My Tool.app", to: path("Caskroom/my-tool/1.2.0/My Tool.app"))

        let apps = await discover(["Applications"])

        let result = try #require(apps.first)
        #expect(apps.count == 1)
        #expect(result.id == path("Caskroom/my-tool/1.2.0/My Tool.app"))
        #expect(result.source == .homebrew(token: "my-tool"))
        #expect(app("Applications/My Tool.app")?.source == .homebrew(token: "my-tool"))
    }

    // MARK: - Protection

    @Test("apps in a system root are Apple apps and protected")
    func systemRootProtected() async throws {
        var fixture = AppBundleFixture()
        fixture.identifier = "com.apple.calculator"
        try fixture.create(at: path("System/Applications/Calculator.app"))

        let result = try #require(await discover(["System/Applications"]).first)
        #expect(result.source == .apple)
        #expect(result.isProtected)
    }

    @Test("a symlink into a system root (like Safari) is listed as a protected Apple app")
    func systemSymlinkProtected() async throws {
        var fixture = AppBundleFixture()
        fixture.identifier = "com.apple.Safari"
        try fixture.create(at: path("System/Applications/Safari.app"))
        try makeDirectory("Applications")
        try symlink("Applications/Safari.app", to: "../System/Applications/Safari.app")

        let apps = await discover(["Applications"])
        let result = try #require(apps.first)
        #expect(apps.count == 1)
        #expect(result.id == path("System/Applications/Safari.app"))
        #expect(result.isProtected)
    }

    @Test("Clenvra itself is protected wherever it is installed")
    func selfProtected() throws {
        var fixture = AppBundleFixture()
        fixture.identifier = AppInventory.clenvraBundleIdentifier
        try fixture.create(at: path("Applications/Clenvra.app"))

        #expect(app("Applications/Clenvra.app")?.isProtected == true)
    }

    @Test("a com.apple id outside a system root is not protected by its id alone")
    func appleIdentifierOutsideSystem() throws {
        var fixture = AppBundleFixture()
        fixture.identifier = "com.apple.dt.Xcode"
        try fixture.create(at: path("Applications/Xcode.app"))

        #expect(app("Applications/Xcode.app")?.isProtected == false)
    }

    // MARK: - discover()

    @Test("finds apps in nested folders, sorted by name")
    func nestedFolders() async throws {
        var zeta = AppBundleFixture()
        zeta.bundleName = "zeta"
        try zeta.create(at: path("Applications/Zeta.app"))
        try AppBundleFixture().create(at: path("Applications/Utilities/Console Tool.app"))
        try AppBundleFixture().create(at: path("Applications/Vendor/Suite/Alpha.app"))

        let names = await discover(["Applications"]).map(\.name)

        #expect(names == ["Alpha", "Console Tool", "zeta"])
    }

    @Test("descends at most three folder levels below a root")
    func depthLimit() async throws {
        try AppBundleFixture().create(at: path("R/1/2/3/Deep.app"))
        try AppBundleFixture().create(at: path("R/1/2/3/4/TooDeep.app"))

        let names = await discover(["R"]).map(\.name)

        #expect(names == ["Deep"])
    }

    @Test("never descends into a bundle")
    func noDescentIntoBundles() async throws {
        var fixture = AppBundleFixture()
        fixture.loginItems = ["Helper": "com.example.helper"]
        try fixture.create(at: path("R/Host.app"))
        try AppBundleFixture().create(at: path("R/Host.app/Contents/Nested.app"))

        let names = await discover(["R"]).map(\.name)

        #expect(names == ["Host"])
    }

    @Test("an app reachable from several roots is listed once")
    func dedupe() async throws {
        try AppBundleFixture().create(at: path("Applications/Setapp/Tool.app"))

        let apps = await discover(["Applications", "Applications/Setapp", "Applications"])

        #expect(apps.map(\.name) == ["Tool"])
        #expect(apps.first?.source == .setapp)
    }

    @Test("symlinks to folders or apps outside the root are not followed")
    func symlinksNotFollowed() async throws {
        try AppBundleFixture().create(at: path("Outside/Folder/Hidden.app"))
        try AppBundleFixture().create(at: path("Outside/Stray.app"))
        try makeDirectory("R")
        try symlink("R/Folder", to: path("Outside/Folder"))
        try symlink("R/Stray.app", to: path("Outside/Stray.app"))

        #expect(await discover(["R"]).isEmpty)
    }

    @Test("missing roots are skipped")
    func missingRoot() async throws {
        try AppBundleFixture().create(at: path("R/One.app"))

        #expect(await discover(["Nope", "R"]).map(\.name) == ["One"])
    }

    @Test("scanning 300 bundles finishes quickly", .timeLimit(.minutes(1)))
    func manyBundles() async throws {
        for index in 0..<300 {
            var fixture = AppBundleFixture()
            fixture.identifier = "com.example.app\(index)"
            fixture.plugIns = ["Ext": "com.example.app\(index).ext"]
            try fixture.create(at: path("R/Group\(index % 10)/App\(index).app"))
        }

        #expect(await discover(["R"]).count == 300)
    }

    // MARK: - Code signature

    @Test("reads application groups from an ad-hoc signature; unsigned yields none")
    func applicationGroupsFromSignature() throws {
        let bundle = path("A/Signed.app")
        try AppBundleFixture().create(at: bundle)
        let executable = bundle + "/Contents/MacOS/exe"
        try FileManager.default.removeItem(atPath: executable)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable)

        #expect(AppInventory.applicationGroups(of: bundle) == [])

        let entitlements: [String: [String]] = [
            "com.apple.security.application-groups": ["ABCDE12345.com.example.shared"]
        ]
        let entitlementsPath = path("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            .write(to: URL(filePath: entitlementsPath))
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--entitlements", entitlementsPath, bundle]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0)

        #expect(AppInventory.applicationGroups(of: bundle) == ["ABCDE12345.com.example.shared"])
    }

    @Test("last used date is nil for a bundle Spotlight has never seen opened")
    func lastUsedUnknown() throws {
        try AppBundleFixture().create(at: path("A/Fresh.app"))

        #expect(AppInventory.lastUsedDate(of: path("A/Fresh.app")) == nil)
        #expect(AppInventory.lastUsedDate(of: path("A/Missing.app")) == nil)
    }

    // MARK: - appsInTrash

    @Test("apps in the Trash are read from their Info.plist")
    func appsInTrashReadsBundles() throws {
        var foo = AppBundleFixture()
        foo.identifier = "com.example.foo"
        try foo.create(at: path("Trash/Foo.app"))
        try makeDirectory("Trash/Notes")

        let apps = AppInventory.appsInTrash(trashRoots: [path("Trash"), path("Missing")])

        #expect(apps.map(\.bundleIdentifier) == ["com.example.foo"])
        #expect(apps.map(\.name) == ["Foo"])
    }

    @Test("an app in the Trash without a bundle identifier or Info.plist is skipped")
    func appWithoutBundleIDIsIgnored() throws {
        var noIdentifier = AppBundleFixture()
        noIdentifier.identifier = nil
        try noIdentifier.create(at: path("Trash/NoID.app"))
        var noPlist = AppBundleFixture()
        noPlist.writeInfoPlist = false
        try noPlist.create(at: path("Trash/NoPlist.app"))
        try makeDirectory("Trash/Broken.app/Contents")
        try Data("not a plist".utf8).write(to: URL(filePath: path("Trash/Broken.app/Contents/Info.plist")))

        #expect(AppInventory.appsInTrash(trashRoots: [path("Trash")]).isEmpty)
    }

    @Test("only apps directly inside the Trash are returned, and symlinks are not followed")
    func appsInTrashDepthOne() throws {
        var bar = AppBundleFixture()
        bar.identifier = "com.example.bar"
        try bar.create(at: path("Trash/folder/Bar.app"))
        try bar.create(at: path("Elsewhere/Bar.app"))
        try makeDirectory("Trash")
        try symlink("Trash/Link.app", to: path("Elsewhere/Bar.app"))

        #expect(AppInventory.appsInTrash(trashRoots: [path("Trash")]).isEmpty)
    }

    // MARK: - Read-only integration with the real system

    @Test("the real /System/Applications contains a protected Calculator")
    func realSystemApplications() async throws {
        let apps = await AppInventory.discover(roots: ["/System/Applications"])

        let calculator = try #require(
            apps.first { $0.bundleIdentifier == "com.apple.calculator" || $0.id.hasSuffix("/Calculator.app") })
        #expect(calculator.isProtected)
        #expect(calculator.source == .apple)
    }

    @Test("signature and Spotlight queries on a real signed app do not fail")
    func realSignedApp() {
        let groups = AppInventory.applicationGroups(of: "/System/Applications/Calculator.app")
        let lastUsed = AppInventory.lastUsedDate(of: "/System/Applications/Calculator.app")

        #expect(groups.allSatisfy { !$0.isEmpty })
        if let lastUsed { #expect(lastUsed <= Date.now) }
    }
}
