import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("DeletionGate")
struct DeletionGateTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private var root: String { scratch.url.path(percentEncoded: false).trimmingSuffix("/") }

    init() throws {
        let scratch = try TemporaryDirectory()
        self.scratch = scratch
        fixture = FixtureBuilder(root: scratch.url)
    }

    private func path(_ relative: String) -> String {
        scratch.url.appending(path: relative).path(percentEncoded: false)
    }

    /// A plan item exactly as a scanner would produce it right now.
    private func scannedItem(_ relative: String, root ruleRoot: String? = nil, owner: String? = nil) throws
        -> DeletionItem
    {
        let resolved = try SafeWalk.resolve(path(relative))
        return DeletionItem(
            path: path(relative), ruleRoot: ruleRoot ?? root, expected: resolved.snapshot, ownerBundleID: owner,
            freedBytes: 0, section: .cleanup)
    }

    private func gate(
        home: String = "/Users/nobody", exclusions: [String] = [],
        owner: @escaping @Sendable (String) -> OwnerState = { _ in .notRunning }
    ) -> DeletionGate {
        DeletionGate(policy: ProtectionPolicy(home: home, exclusions: exclusions), ownerState: owner)
    }

    @Test("an unchanged, unprotected item inside its root passes and keeps its parent open")
    func passes() throws {
        try fixture.file("cache/a.bin", bytes: 4)
        let item = try scannedItem("cache/a.bin")

        let checked = try gate().check(item)

        #expect(checked.name == "a.bin")
        #expect(checked.snapshot == item.expected)
    }

    @Test("an item outside its rule root, or the root itself, is refused (safety case S6)")
    func outsideRoot() throws {
        try fixture.file("cache/a.bin", bytes: 4)
        try fixture.file("other/b.bin", bytes: 4)

        #expect(throws: SafetyRefusal.outsideRoot) {
            _ = try gate().check(try scannedItem("other/b.bin", root: path("cache")))
        }
        #expect(throws: SafetyRefusal.outsideRoot) {
            _ = try gate().check(try scannedItem("cache", root: path("cache")))
        }
    }

    @Test("a protected location is refused with its reason (safety case S7)")
    func protected() throws {
        try fixture.file("cache/server.pem", bytes: 4)
        #expect(throws: SafetyRefusal.protected(.secret)) { _ = try gate().check(try scannedItem("cache/server.pem")) }
    }

    @Test("a file replaced by a new file with the same name is refused (safety case S3)")
    func replaced() throws {
        try fixture.file("cache/a.bin", bytes: 4)
        let item = try scannedItem("cache/a.bin")
        try FileManager.default.removeItem(atPath: path("cache/a.bin"))
        try fixture.file("cache/a.bin", bytes: 4)

        #expect(throws: SafetyRefusal.changedSinceScan) { _ = try gate().check(item) }
    }

    @Test("an item that disappeared is reported as not found")
    func vanished() throws {
        try fixture.file("cache/a.bin", bytes: 4)
        let item = try scannedItem("cache/a.bin")
        try FileManager.default.removeItem(atPath: path("cache/a.bin"))

        #expect(throws: SafetyRefusal.notFound) { _ = try gate().check(item) }
    }

    @Test("files with protective flags are refused (safety case S11)")
    func flagged() throws {
        try fixture.file("cache/locked.bin", bytes: 4)
        try fixture.setFlags("cache/locked.bin", UInt32(UF_IMMUTABLE))

        #expect(throws: SafetyRefusal.flagged) { _ = try gate().check(try scannedItem("cache/locked.bin")) }
    }

    @Test("an item whose owner app is running is refused (safety case S12)")
    func ownerRunning() throws {
        try fixture.file("cache/com.example.app/data", bytes: 4)
        let item = try scannedItem("cache/com.example.app", owner: "com.example.app")

        #expect(throws: SafetyRefusal.inUse) {
            _ = try gate(owner: { $0 == "com.example.app" ? .running : .notRunning }).check(item)
        }
    }

    @Test("an item whose owner state cannot be determined is refused (safety case S13)")
    func ownerUnknown() throws {
        try fixture.file("cache/com.example.app/data", bytes: 4)
        let item = try scannedItem("cache/com.example.app", owner: "com.example.app")

        #expect(throws: SafetyRefusal.inUse) { _ = try gate(owner: { _ in .unknown }).check(item) }
    }

    @Test("an exclusion added after the scan is honoured at deletion time (safety case S18)")
    func exclusionAfterScan() throws {
        try fixture.file("cache/keep/data", bytes: 4)
        let item = try scannedItem("cache/keep")

        #expect(throws: SafetyRefusal.protected(.excluded)) {
            _ = try gate(exclusions: [path("cache/keep")]).check(item)
        }
    }

    @Test("a gate reads the current policy, so exclusions added after it was created still apply (S18)")
    func liveExclusions() throws {
        try fixture.file("cache/keep/data", bytes: 4)
        let provider = PolicyProvider(ProtectionPolicy(home: "/Users/nobody"))
        let gate = DeletionGate(policyProvider: provider, ownerState: { _ in .notRunning })
        let item = try scannedItem("cache/keep")

        provider.update(ProtectionPolicy(home: "/Users/nobody", exclusions: [path("cache/keep")]))

        #expect(throws: SafetyRefusal.protected(.excluded)) { _ = try gate.check(item) }
    }

    @Test("a folder that contains a secret file is refused (safety case S21)")
    func containsSecret() throws {
        try fixture.file("cache/tool/deep/id_ed25519", bytes: 4)
        #expect(throws: SafetyRefusal.containsProtectedItem(.secret)) {
            _ = try gate().check(try scannedItem("cache/tool"))
        }
    }

    @Test("an application bundle may contain certificate files: they are the vendor's, not the user's secrets")
    func appBundleWithCertificate() throws {
        try fixture.file("cache/Example.app/Contents/Resources/cacert.pem", bytes: 4)
        try fixture.file("cache/Example.app/Contents/MacOS/Example", bytes: 4)

        _ = try gate().check(try scannedItem("cache/Example.app"))
    }

    @Test("a secret inside a folder that only looks like a bundle elsewhere is still refused")
    func secretInsideAppNamedCache() throws {
        try fixture.file("cache/tool/Example.app.backup/id_ed25519", bytes: 4)
        #expect(throws: SafetyRefusal.containsProtectedItem(.secret)) {
            _ = try gate().check(try scannedItem("cache/tool"))
        }
    }

    @Test("a folder that contains a symlink is fine: links inside are never followed")
    func containsSymlink() throws {
        try fixture.file("cache/tool/a", bytes: 4)
        try fixture.symlink("cache/tool/link", to: "/Users")

        _ = try gate().check(try scannedItem("cache/tool"))
    }

    @Test("a directory snapshot only needs a matching identity, since caches change constantly")
    func directoryContentsChanged() throws {
        try fixture.file("cache/tool/a", bytes: 4)
        let item = try scannedItem("cache/tool")
        try fixture.file("cache/tool/b", bytes: 4)

        _ = try gate().check(item)
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self
    }
}
