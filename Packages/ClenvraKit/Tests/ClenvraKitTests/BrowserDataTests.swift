import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("BrowserData")
struct BrowserDataTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private var home: String { scratch.url.path(percentEncoded: false).trimmingTrailingSlash }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func write(_ relative: String, _ contents: String) throws {
        let url = fixture.url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func scan(
        running: Set<String> = [], policy: ProtectionPolicy? = nil
    ) async -> BrowserDataScanResult {
        await BrowserDataScanner.scan(
            home: home, policy: policy ?? ProtectionPolicy(home: home),
            ownerState: { running.contains($0) ? .running : .notRunning })
    }

    @Test("the catalog covers every browser and data type, with warnings and no forbidden targets")
    func catalogCoverage() {
        #expect(Browser.allCases.count == 9)
        let forbidden = [
            "Login Data", "Passwords", "Bookmarks", "Web Data", "Preferences", "Secure Preferences", "Autofill",
            "Extensions", "Extension State", "Sync Data",
        ]
        for browser in Browser.allCases {
            let rows = BrowserDataCatalog.locations.filter { $0.browser == browser }
            #expect(Set(rows.map(\.dataType)) == Set(BrowserDataType.allCases), "missing rows for \(browser)")
            for row in rows {
                #expect(!row.warning.isEmpty)
                #expect(!row.relativePaths.isEmpty)
                #expect(
                    row.relativePaths.allSatisfy { relative in
                        !forbidden.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") })
                    })
            }
        }
        #expect(BrowserDataType.history.warning.contains("history"))
        #expect(BrowserDataType.cookies.warning.contains("sign"))
        #expect(BrowserDataType.sessions.warning.contains("tabs"))
        #expect(BrowserDataType.siteData.warning.contains("site"))
        let firefoxHistory = BrowserDataCatalog.locations.first {
            $0.browser == .firefox && $0.dataType == .history
        }
        #expect(firefoxHistory?.removesBookmarks == true)
        #expect(firefoxHistory?.warning.contains("bookmarks") == true)
    }

    @Test("every catalog target is outside the protection policy's secret and personal-data names")
    func catalogTargetsAreNotProtected() {
        let policy = ProtectionPolicy(home: "/Users/u")
        for location in BrowserDataCatalog.locations {
            let root: String
            switch location.root {
            case .profile:
                root = "/Users/u/Library/Application Support/Example/Default"
            case .home(let relative):
                root = "/Users/u/" + relative
            }
            for relative in location.relativePaths {
                #expect(policy.protection(for: root + "/" + relative) == nil, "protected target: \(relative)")
            }
        }
    }

    @Test("Chromium reads Local State profile names and only offers allowlisted data")
    func chromiumLocalState() async throws {
        let root = "Library/Application Support/Google/Chrome"
        try write(
            root + "/Local State",
            #"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 7":{"name":"Work"}}}}"#)
        try fixture.file(root + "/Profile 7/History", bytes: 100)
        try fixture.file(root + "/Profile 7/History-wal", bytes: 20)
        try fixture.file(root + "/Profile 7/Network/Cookies", bytes: 200)
        try fixture.file(root + "/Profile 7/Sessions/Session_1", bytes: 300)
        try fixture.file(root + "/Profile 7/Local Storage/leveldb/000003.log", bytes: 400)
        try fixture.file(root + "/Profile 7/Login Data", bytes: 500)
        try fixture.file(root + "/Profile 7/Bookmarks", bytes: 500)
        try fixture.file(root + "/Profile 7/Preferences", bytes: 500)
        try fixture.file(root + "/Profile 7/Extensions/extension.js", bytes: 500)
        try fixture.file(root + "/Default/History", bytes: 50)

        let result = await scan()
        let work = try #require(result.profiles.first { $0.name == "Work" })
        #expect(work.path == path(root + "/Profile 7"))
        let workItems = result.items.filter { $0.profile.path == work.path }
        #expect(workItems.map(\.path).contains(path(root + "/Profile 7/History")))
        #expect(workItems.map(\.path).contains(path(root + "/Profile 7/History-wal")))
        #expect(workItems.map(\.path).contains(path(root + "/Profile 7/Network/Cookies")))
        #expect(workItems.map(\.path).contains(path(root + "/Profile 7/Sessions")))
        #expect(workItems.map(\.path).contains(path(root + "/Profile 7/Local Storage")))
        #expect(workItems.allSatisfy { !$0.path.contains("Login Data") && !$0.path.contains("Bookmarks") })
        #expect(workItems.allSatisfy { !$0.path.contains("Preferences") && !$0.path.contains("Extensions") })
        #expect(workItems.allSatisfy { $0.ruleRoot == work.path })
        #expect(workItems.allSatisfy { !$0.isSelectedByDefault && $0.risk == .review })
        #expect(Set(workItems.map(\.dataType)) == Set(BrowserDataType.allCases))
        #expect(result.items.contains { $0.profile.name == "Personal" && $0.dataType == .history })
    }

    @Test("Local State profile keys remain usable when their display name is absent")
    func chromiumProfileWithoutDisplayName() async throws {
        let root = "Library/Application Support/Google/Chrome"
        try write(root + "/Local State", #"{"profile":{"info_cache":{"Profile 8":{}}}}"#)
        try fixture.file(root + "/Profile 8/History", bytes: 100)

        let result = await scan()

        #expect(result.profiles.contains { $0.path == path(root + "/Profile 8") && $0.name == "Profile 8" })
        #expect(result.items.contains { $0.path == path(root + "/Profile 8/History") })
    }

    @Test("Chromium falls back to Default and numbered profiles when Local State is unusable")
    func chromiumFallbackProfiles() async throws {
        let root = "Library/Application Support/Google/Chrome"
        try write(root + "/Local State", "not json")
        try fixture.file(root + "/Default/History", bytes: 10)
        try fixture.file(root + "/Profile 2/Cookies", bytes: 20)
        try fixture.file(root + "/Profile 2/Current Session", bytes: 30)
        try fixture.file(root + "/Profile nope/History", bytes: 40)
        try fixture.file(root + "/Unlisted/History", bytes: 40)

        let result = await scan()

        #expect(Set(result.profiles.map(\.path)) == [path(root + "/Default"), path(root + "/Profile 2")])
        #expect(result.items.contains { $0.path == path(root + "/Default/History") })
        #expect(result.items.contains { $0.path == path(root + "/Profile 2/Cookies") })
        #expect(result.items.contains { $0.path == path(root + "/Profile 2/Current Session") })
        #expect(result.items.allSatisfy { !$0.path.contains("Profile nope") && !$0.path.contains("Unlisted") })
    }

    @Test("Firefox profiles.ini supports relative and home-contained absolute profiles and warns about bookmarks")
    func firefoxProfilesINI() async throws {
        let root = "Library/Application Support/Firefox"
        let absolute = path("Elsewhere/WorkProfile")
        try write(
            root + "/profiles.ini",
            """
            [General]
            StartWithLastProfile=1
            [Profile0]
            Name=Personal
            IsRelative=1
            Path=Profiles/abc.default
            [Profile1]
            Name=Work
            IsRelative=0
            Path=\(absolute)
            """)
        try fixture.file(root + "/Profiles/abc.default/places.sqlite", bytes: 100)
        try fixture.file(root + "/Profiles/abc.default/cookies.sqlite", bytes: 200)
        try fixture.file(root + "/Profiles/abc.default/sessionstore.jsonlz4", bytes: 300)
        try fixture.file(root + "/Profiles/abc.default/sessionstore-backups/recovery.jsonlz4", bytes: 300)
        try fixture.file(root + "/Profiles/abc.default/storage/default/example/data", bytes: 400)
        try fixture.file("Elsewhere/WorkProfile/places.sqlite", bytes: 500)
        try fixture.file(root + "/Profiles/abc.default/bookmarkbackups/bookmarks.json", bytes: 500)

        let result = await scan()

        #expect(Set(result.profiles.map(\.name)).isSuperset(of: ["Personal", "Work"]))
        let personal = result.items.filter { $0.profile.name == "Personal" }
        #expect(personal.contains { $0.path == path(root + "/Profiles/abc.default/places.sqlite") })
        #expect(personal.contains { $0.path == path(root + "/Profiles/abc.default/cookies.sqlite") })
        #expect(personal.contains { $0.path == path(root + "/Profiles/abc.default/sessionstore.jsonlz4") })
        #expect(personal.contains { $0.path == path(root + "/Profiles/abc.default/sessionstore-backups") })
        #expect(personal.contains { $0.path == path(root + "/Profiles/abc.default/storage") })
        #expect(personal.allSatisfy { !$0.path.contains("bookmarkbackups") })
        #expect(personal.first { $0.dataType == .history }?.removesBookmarks == true)
        #expect(result.items.contains { $0.profile.name == "Work" && $0.dataType == .history })
    }

    @Test("Safari finds history, both cookie locations and container sessions with FDA metadata")
    func safariLocations() async throws {
        try fixture.file("Library/Safari/History.db", bytes: 100)
        try fixture.file("Library/Safari/History.db-wal", bytes: 20)
        try fixture.file("Library/Safari/LastSession.plist", bytes: 30)
        try fixture.file("Library/Cookies/Cookies.binarycookies", bytes: 40)
        try fixture.file("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies", bytes: 50)
        try fixture.file("Library/Containers/com.apple.Safari/Data/Library/Safari/LocalStorage/data", bytes: 60)

        let result = await scan()

        let safari = try #require(result.profiles.first { $0.browser == .safari })
        #expect(safari.requiresFullDiskAccess)
        #expect(result.items.contains { $0.path == path("Library/Safari/History.db") })
        #expect(result.items.contains { $0.path == path("Library/Safari/History.db-wal") })
        #expect(result.items.contains { $0.path == path("Library/Cookies/Cookies.binarycookies") })
        #expect(
            result.items.contains {
                $0.path == path("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
            })
        #expect(result.items.contains { $0.path == path("Library/Safari/LastSession.plist") })
        #expect(
            result.items.contains {
                $0.path == path("Library/Containers/com.apple.Safari/Data/Library/Safari/LocalStorage")
            })
        #expect(
            result.items.first { $0.path == path("Library/Cookies/Cookies.binarycookies") }?.ruleRoot
                == path("Library/Cookies"))
        #expect(
            result.items.first { $0.path == path("Library/Safari/History.db") }?.ruleRoot
                == path("Library/Safari"))
    }

    @Test("a running browser marks every one of its items in use")
    func runningBrowserBlocksItems() async throws {
        let root = "Library/Application Support/Google/Chrome/Default"
        try fixture.file(root + "/History", bytes: 100)
        try fixture.file(root + "/Cookies", bytes: 100)
        try fixture.file(root + "/Sessions/Session_1", bytes: 100)

        let result = await scan(running: ["com.google.Chrome"])

        #expect(!result.items.isEmpty)
        #expect(result.items.allSatisfy { $0.status == .inUse && $0.ownerBundleID == "com.google.Chrome" })
        #expect(result.items.allSatisfy { !$0.isSelectedByDefault })
    }

    @Test("a folder containing a secret-looking name is not selectable")
    func protectedDirectoryContents() async throws {
        let root = "Library/Application Support/Google/Chrome/Default"
        try fixture.file(root + "/Local Storage/id_ed25519", bytes: 100)
        try fixture.file(root + "/History", bytes: 100)

        let result = await scan()

        #expect(result.items.first { $0.dataType == .siteData }?.status == .protected(.secret))
        #expect(result.items.first { $0.dataType == .history }?.status == .available)
    }

    @Test("unreadable Safari data is reported as skipped instead of failing the scan")
    func unreadableSafariIsSkipped() async throws {
        try fixture.file("Library/Safari/History.db", bytes: 100)
        try fixture.setPermissions("Library/Safari", 0)

        let result = await scan()

        #expect(result.items.isEmpty)
        #expect(result.skipped.contains { $0.path == path("Library/Safari") && $0.reason == .permissionDenied })
    }

    @Test("profile symlinks and targets outside the fixture home are never followed")
    func rejectsUnsafeProfilePaths() async throws {
        let root = "Library/Application Support/Firefox"
        try write(
            root + "/profiles.ini",
            """
            [Profile0]
            Name=Outside
            IsRelative=0
            Path=/outside/profile
            [Profile1]
            Name=BadRelative
            IsRelative=1
            Path=../outside
            """)
        try fixture.directory(root + "/Profiles")
        try fixture.symlink(root + "/Profiles/link", to: "/outside")
        try fixture.file("Outside/History", bytes: 100)

        let result = await scan()

        #expect(result.items.isEmpty)
        #expect(result.skipped.allSatisfy { !$0.path.hasPrefix("/outside") })
    }
}

extension String {
    fileprivate var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
