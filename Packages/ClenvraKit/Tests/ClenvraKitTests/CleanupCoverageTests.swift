import Darwin
import Foundation
import Testing

@testable import ClenvraKit

/// Moves items into a folder inside the test directory that no rule scans.
private struct FixtureTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

/// Trash, browser caches and device backups: the Cleanup categories added after the first release slice.
@MainActor
@Suite("Cleanup coverage: Trash, browser caches, device backups")
struct CleanupCoverageTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("FixtureTrash")
    }

    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func scanCatalog(running: Set<String> = []) async -> [String: [CleanupCandidate]] {
        var found: [String: [CleanupCandidate]] = [:]
        for rule in RuleCatalog.standard(temporaryDirectory: path("tmp")) {
            let result = await RuleScanner.scan(
                rule, home: home, policy: ProtectionPolicy(home: home),
                ownerState: { running.contains($0) ? .running : .notRunning })
            if !result.candidates.isEmpty { found[rule.id] = result.candidates }
        }
        return found
    }

    private func session(ruleIDs: Set<String>) -> CleanupSession {
        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { _ in .notRunning }
        return CleanupSession(
            rules: RuleCatalog.standard.filter { ruleIDs.contains($0.id) }, section: .cleanup, home: home,
            policy: policy, ownerState: ownerState,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState),
                log: ActivityLog(directory: fixture.url("log")),
                trash: FixtureTrash(directory: path("FixtureTrash"))))
    }

    // MARK: - Browser caches

    @Test("each browser's cache folders are offered under Browser Caches, owned by that browser")
    func browserCaches() async throws {
        try fixture.file("Library/Caches/Google/Chrome/Default/Cache/data_1", bytes: 4_000)
        try fixture.file("Library/Caches/Google/Chrome/Profile 1/Cache/data_1", bytes: 4_000)
        try fixture.file("Library/Caches/com.apple.Safari/fsCachedData/a", bytes: 4_000)
        try fixture.file("Library/Caches/Firefox/Profiles/abc.default/cache2/entries/x", bytes: 4_000)
        try fixture.file("Library/Caches/BraveSoftware/Brave-Browser/Default/Cache/x", bytes: 4_000)

        let found = await scanCatalog()

        #expect(Set(found["browser.chrome"]?.map(\.name) ?? []) == ["Default", "Profile 1"])
        #expect(found["browser.chrome"]?.allSatisfy { $0.ownerBundleID == "com.google.Chrome" } == true)
        #expect(found["browser.safari"]?.map(\.name) == ["fsCachedData"])
        #expect(found["browser.safari"]?.first?.ownerBundleID == "com.apple.Safari")
        #expect(found["browser.firefox"]?.map(\.name) == ["abc.default"])
        #expect(found["browser.brave"]?.map(\.name) == ["Default"])
        let rules = Dictionary(uniqueKeysWithValues: RuleCatalog.standard.map { ($0.id, $0) })
        for id in ["browser.chrome", "browser.safari", "browser.firefox", "browser.brave"] {
            #expect(rules[id]?.category == .browserCaches)
        }
    }

    @Test("browser cache folders are not offered a second time as app caches; other Google caches still are")
    func browserCachesLeaveAppCaches() async throws {
        try fixture.file("Library/Caches/Google/Chrome/Default/Cache/data_1", bytes: 4_000)
        try fixture.file("Library/Caches/Google/AndroidStudio2026.2/index", bytes: 4_000)
        try fixture.file("Library/Caches/com.apple.Safari/fsCachedData/a", bytes: 4_000)
        try fixture.file("Library/Caches/com.vendor.app/blob", bytes: 4_000)

        let found = await scanCatalog()
        let appCacheNames = Set(found["caches.user"]?.map(\.name) ?? [])

        #expect(appCacheNames == ["com.vendor.app"])
        #expect(found["caches.google"]?.map(\.name) == ["AndroidStudio2026.2"])
    }

    @Test("a running browser blocks its own cache, with a reason")
    func runningBrowser() async throws {
        try fixture.file("Library/Caches/Google/Chrome/Default/Cache/data_1", bytes: 4_000)

        let found = await scanCatalog(running: ["com.google.Chrome"])

        #expect(found["browser.chrome"]?.first?.status == .inUse)
    }

    @Test("no rule's root sits inside another rule's folder unless that rule leaves it out")
    func nestedRootsNeverOverlap() {
        let home = "/Users/u"
        for outer in RuleCatalog.standard {
            guard case .children(let excluded, _) = outer.selection else { continue }
            let outerRoot = outer.root.path(home: home)
            for inner in RuleCatalog.standard where inner.id != outer.id {
                let innerRoot = inner.root.path(home: home)
                guard innerRoot.hasPrefix(outerRoot + "/") else { continue }
                let firstComponent = String(innerRoot.dropFirst(outerRoot.count + 1).split(separator: "/")[0])
                #expect(excluded.contains(firstComponent), "\(inner.id) is inside \(outer.id) at \(firstComponent)")
            }
        }
    }

    // MARK: - Editor caches

    @Test("JetBrains caches are one item per IDE version, each owned by that IDE")
    func jetBrainsCaches() async throws {
        try fixture.file("Library/Caches/JetBrains/PyCharmCE2026.2/caches/a", bytes: 4_000)
        try fixture.file("Library/Caches/JetBrains/PyCharm2026.2/caches/a", bytes: 4_000)
        try fixture.file("Library/Caches/JetBrains/IntelliJIdea2026.2/index/a", bytes: 4_000)
        try fixture.file("Library/Caches/JetBrains/SomeNewIDE2027.1/a", bytes: 4_000)

        let found = await scanCatalog()
        let owners = Dictionary(
            uniqueKeysWithValues: (found["ide.jetbrains"] ?? []).map { ($0.name, $0.ownerBundleID) })

        #expect(owners["PyCharmCE2026.2"] == "com.jetbrains.pycharm.ce")
        #expect(owners["PyCharm2026.2"] == "com.jetbrains.pycharm")
        #expect(owners["IntelliJIdea2026.2"] == "com.jetbrains.intellij")
        // An IDE Clenvra does not know is owned by an identifier no app has, so it counts as "in use".
        #expect(owners["SomeNewIDE2027.1"] == RuleCatalog.unknownJetBrainsIDE)
        #expect(found["caches.user"] == nil)
    }

    @Test("a running JetBrains IDE blocks only its own cache")
    func runningJetBrainsIDE() async throws {
        try fixture.file("Library/Caches/JetBrains/GoLand2026.2/a", bytes: 4_000)
        try fixture.file("Library/Caches/JetBrains/WebStorm2026.2/a", bytes: 4_000)

        let found = await scanCatalog(running: ["com.jetbrains.goland"])
        let status = Dictionary(uniqueKeysWithValues: (found["ide.jetbrains"] ?? []).map { ($0.name, $0.status) })

        #expect(status["GoLand2026.2"] == .inUse)
        #expect(status["WebStorm2026.2"] == .available)
    }

    @Test("Zed's cache is offered and owned by Zed; Android Studio's cache is owned by Android Studio")
    func zedAndAndroidStudio() async throws {
        try fixture.file("Library/Caches/Zed/extensions/a", bytes: 4_000)
        try fixture.file("Library/Caches/Google/AndroidStudio2026.2/a", bytes: 4_000)

        let found = await scanCatalog(running: ["com.google.android.studio"])

        #expect(found["ide.zed"]?.first?.ownerBundleID == "dev.zed.Zed")
        #expect(found["caches.google"]?.first?.status == .inUse)
    }

    // MARK: - Device backups

    @Test("iPhone and iPad backups are offered for review, named after the device")
    func deviceBackups() async throws {
        let backup = "Library/Application Support/MobileSync/Backup/00008030-001A2B3C4D5E"
        try fixture.file(backup + "/ab/ab12cd", bytes: 50_000)
        let info: [String: Any] = ["Device Name": "Nasr’s iPhone", "Last Backup Date": Date(timeIntervalSince1970: 0)]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: fixture.url(backup + "/Info.plist"))

        let found = await scanCatalog()
        let candidate = try #require(found["deviceBackups.mobileSync"]?.first)

        #expect(candidate.name == "Nasr’s iPhone")
        #expect(candidate.path == path(backup))
        #expect(candidate.risk == .review)
        #expect(!candidate.isSelectedByDefault)
    }

    @Test("a backup without readable device information keeps its folder name")
    func deviceBackupFallbackName() async throws {
        try fixture.file("Library/Application Support/MobileSync/Backup/ABCDEF/Manifest.db", bytes: 1_000)

        let found = await scanCatalog()

        #expect(found["deviceBackups.mobileSync"]?.map(\.name) == ["ABCDEF"])
    }

    @Test("downloaded iPhone and iPad software updates are offered and pre-selected")
    func firmware() async throws {
        try fixture.file("Library/iTunes/iPhone Software Updates/iPhone_18.0_Restore.ipsw", bytes: 9_000)

        let found = await scanCatalog()
        let candidate = try #require(found["deviceBackups.firmware"]?.first)

        #expect(candidate.name == "iPhone_18.0_Restore.ipsw")
        #expect(candidate.isSelectedByDefault)
    }

    // MARK: - Trash

    @Test("items in the Trash are offered for review, never pre-selected, and marked irreversible")
    func trashCandidates() async throws {
        try fixture.file(".Trash/old.zip", bytes: 8_000)
        try fixture.file(".Trash/Folder/inside.txt", bytes: 2_000)

        let found = await scanCatalog()
        let rule = try #require(RuleCatalog.standard.first { $0.id == "trash.user" })

        #expect(Set(found["trash.user"]?.map(\.name) ?? []) == ["old.zip", "Folder"])
        #expect(found["trash.user"]?.allSatisfy { !$0.isSelectedByDefault } == true)
        #expect(rule.action == .removePermanently)
        #expect(rule.category == .trash)
    }

    @Test("emptying Trash items removes them permanently instead of moving them to the Trash again")
    func emptyTrash() async throws {
        try fixture.file(".Trash/old.zip", bytes: 8_000)
        try fixture.file("Library/Caches/com.vendor.app/blob", bytes: 4_000)
        let session = session(ruleIDs: ["trash.user", "caches.user"])
        await session.scan()
        session.toggle(path(".Trash/old.zip"))

        #expect(session.selectionIncludesPermanentRemoval)
        let summary = await session.clean()

        #expect(summary.removedPermanentlyCount == 1)
        #expect(summary.movedToTrashCount == 1)
        #expect(summary.freedBytes >= 12_000)
        #expect(!FileManager.default.fileExists(atPath: path(".Trash/old.zip")))
        let parked = try FileManager.default.contentsOfDirectory(atPath: path("FixtureTrash"))
        #expect(parked.count == 1)  // only the app cache went to the Trash
    }

    @Test("a selection of Trash-first items only is not flagged as irreversible")
    func reversibleSelection() async throws {
        try fixture.file("Library/Caches/com.vendor.app/blob", bytes: 4_000)
        let session = session(ruleIDs: ["trash.user", "caches.user"])
        await session.scan()

        #expect(!session.selectionIncludesPermanentRemoval)
    }
}
