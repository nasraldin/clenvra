import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("RuleScanner")
struct RuleScannerTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private var home: String { scratch.url.path(percentEncoded: false).trimmingTrailingSlash }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func scan(
        _ rule: CleanupRule, exclusions: [String] = [],
        owner: @escaping @Sendable (String) -> OwnerState = { _ in .notRunning }
    ) async -> RuleScanResult {
        await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: "/Users/nobody", exclusions: exclusions),
            ownerState: owner, now: now)
    }

    private func cachesRule(risk: Risk = .safe) -> CleanupRule {
        CleanupRule(
            id: "test.caches", category: .appCaches, root: .home("Library/Caches"), selection: .children(),
            risk: risk, action: .moveToTrash, ownership: .bundleIdentifierFromName)
    }

    @Test("each child of the root becomes a candidate with its subtree size")
    func childrenWithSizes() async throws {
        try fixture.file("Library/Caches/com.example.one/a.bin", bytes: 10_000)
        try fixture.file("Library/Caches/com.example.one/sub/b.bin", bytes: 5_000)
        try fixture.file("Library/Caches/loose.db", bytes: 2_000)

        let result = await scan(cachesRule())
        let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["com.example.one", "loose.db"])
        #expect(byName["com.example.one"]?.logicalSize == 15_000)
        #expect(byName["com.example.one"]?.kind == .directory)
        #expect(byName["loose.db"]?.logicalSize == 2_000)
        #expect(
            try byName["com.example.one"]?.snapshot == SafeWalk.resolve(path("Library/Caches/com.example.one")).snapshot
        )
    }

    @Test("a missing root (tool not installed) yields no candidates and no error")
    func missingRoot() async {
        let result = await scan(cachesRule())
        #expect(result.candidates.isEmpty)
        #expect(result.rootExists == false)
    }

    @Test("safe rules pre-select available items; review rules never pre-select")
    func preselection() async throws {
        try fixture.file("Library/Caches/com.example.one/a", bytes: 1)

        #expect(await scan(cachesRule(risk: .safe)).candidates.first?.isSelectedByDefault == true)
        #expect(await scan(cachesRule(risk: .review)).candidates.first?.isSelectedByDefault == false)
    }

    @Test("a child named like a bundle identifier is owned by that app; running owners are marked in use")
    func ownership() async throws {
        try fixture.file("Library/Caches/com.example.running/a", bytes: 1)
        try fixture.file("Library/Caches/com.example.idle/a", bytes: 1)
        try fixture.file("Library/Caches/not-an-id/a", bytes: 1)

        let result = await scan(cachesRule(), owner: { $0 == "com.example.running" ? .running : .notRunning })
        let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.name, $0) })

        #expect(byName["com.example.running"]?.ownerBundleID == "com.example.running")
        #expect(byName["com.example.running"]?.status == .inUse)
        #expect(byName["com.example.running"]?.isSelectedByDefault == false)
        #expect(byName["com.example.idle"]?.status == .available)
        #expect(byName["not-an-id"]?.ownerBundleID == nil)
    }

    @Test("protected or excluded items are listed with their reason and never pre-selected")
    func protectedItems() async throws {
        try fixture.file("Library/Caches/com.keep/a", bytes: 1)

        let result = await scan(cachesRule(), exclusions: [path("Library/Caches/com.keep")])

        #expect(result.candidates.first?.status == .protected(.excluded))
        #expect(result.candidates.first?.isSelectedByDefault == false)
    }

    @Test("items the current user cannot remove are marked as managed by macOS")
    func notPermitted() async throws {
        try fixture.file("Library/Caches/com.locked/a", bytes: 1)
        try fixture.setPermissions("Library/Caches/com.locked", 0o555)

        let result = await scan(cachesRule())

        #expect(result.candidates.first?.status == .systemManaged)
    }

    @Test("file rules match by extension and minimum age, searching nested folders")
    func filesByExtensionAndAge() async throws {
        let old = now.addingTimeInterval(-10 * 86_400)
        let recent = now.addingTimeInterval(-1 * 86_400)
        try fixture.file("Library/Logs/app/old.log", bytes: 100)
        try fixture.setModificationDate("Library/Logs/app/old.log", old)
        try fixture.file("Library/Logs/app/new.log", bytes: 100)
        try fixture.setModificationDate("Library/Logs/app/new.log", recent)
        try fixture.file("Library/Logs/app/old.txt", bytes: 100)
        try fixture.setModificationDate("Library/Logs/app/old.txt", old)
        let rule = CleanupRule(
            id: "test.logs", category: .logs, root: .home("Library/Logs"),
            selection: .files(extensions: ["log", "ips"], minimumAge: .days(7), maximumDepth: 4),
            risk: .safe, action: .moveToTrash, ownership: .none)

        let result = await scan(rule)

        #expect(result.candidates.map(\.name) == ["old.log"])
    }

    @Test("a candidate converts to a deletion item bound to its rule root")
    func toDeletionItem() async throws {
        try fixture.file("Library/Caches/com.example.one/a", bytes: 1)
        let candidate = try #require(await scan(cachesRule()).candidates.first)

        let item = candidate.deletionItem(section: .cleanup)

        #expect(item.path == path("Library/Caches/com.example.one"))
        #expect(item.ruleRoot == path("Library/Caches"))
        #expect(item.expected == candidate.snapshot)
        #expect(item.ownerBundleID == "com.example.one")
    }

    @Test("symlinks inside a root are never followed")
    func symlinks() async throws {
        try fixture.file("Elsewhere/big.bin", bytes: 50_000)
        try fixture.directory("Library/Caches")
        try fixture.symlink("Library/Caches/link", to: path("Elsewhere"))

        let result = await scan(cachesRule())

        // The link takes no space, so it is not offered; the target folder is never reached through it.
        #expect(result.candidates.allSatisfy { $0.kind != .directory && $0.logicalSize < 50_000 })
    }
}

extension String {
    fileprivate var trimmingTrailingSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}

@Suite("RuleScanner selections")
struct RuleScannerSelectionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.file("Support/Code/Cache/a", bytes: 10)
        try fixture.file("Support/Code/GPUCache/b", bytes: 10)
        try fixture.file("Support/Code/User/settings.json", bytes: 10)
    }

    private func names(_ selection: Selection) async -> Set<String> {
        let rule = CleanupRule(
            id: "t", category: .ideCaches, root: .home("Support/Code"), selection: selection, risk: .safe,
            action: .moveToTrash, ownership: .none)
        let home = String(scratch.url.path(percentEncoded: false).dropLast())
        let result = await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: "/Users/nobody"), ownerState: { _ in .notRunning })
        return Set(result.candidates.map(\.name))
    }

    @Test("named selection offers only the listed children")
    func named() async {
        #expect(await names(.named(["Cache", "GPUCache", "Missing"])) == ["Cache", "GPUCache"])
    }

    @Test("children selection can exclude names owned by more specific rules")
    func excluding() async {
        #expect(await names(.children(excluding: ["User", "GPUCache"])) == ["Cache"])
    }
}

@Suite("RuleScanner ordering and noise")
struct RuleScannerOrderingTests {
    @Test("items that take no space are not listed, and items are ordered by what they free")
    func orderingAndEmptyItems() async throws {
        let scratch = try TemporaryDirectory()
        let fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("Library/Caches/com.empty.app")
        try fixture.file("Library/Caches/com.small.app/a", bytes: 10_000)
        try fixture.file("Library/Caches/com.big.app/a", bytes: 400_000)
        try fixture.file("Library/Caches/com.linked.app/a", bytes: 900_000)
        try fixture.hardLink("elsewhere/link", to: "Library/Caches/com.linked.app/a")
        let rule = try #require(RuleCatalog.standard.first { $0.id == "caches.user" })
        let home = String(scratch.url.path(percentEncoded: false).dropLast())

        let result = await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: home), ownerState: { _ in .notRunning })

        #expect(result.candidates.map(\.name) == ["com.big.app", "com.small.app", "com.linked.app"])
    }
}
