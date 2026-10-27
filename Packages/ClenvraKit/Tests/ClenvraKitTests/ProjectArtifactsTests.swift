import Foundation
import Testing

@testable import ClenvraKit

@Suite("Project artifacts")
struct ProjectArtifactsTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var old: Date { now.addingTimeInterval(-90 * 86_400) }
    private var recent: Date { now.addingTimeInterval(-2 * 86_400) }

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }

    private let rule = CleanupRule(
        id: "projects.test", category: .projectArtifacts, root: .home("Sources"),
        selection: .projectArtifacts(RuleCatalog.projectArtifactKinds, inactivity: .days(30), maximumDepth: 4),
        risk: .safe, action: .moveToTrash, ownership: .none)

    /// A project folder whose own files were last touched at `modified`.
    private func project(_ name: String, marker: String, artifact: String, modified: Date, in base: String = "Sources")
        throws
    {
        let folder = "\(base)/\(name)"
        try fixture.file("\(folder)/\(marker)", bytes: 10)
        try fixture.file("\(folder)/\(artifact)/lib/x.js", bytes: 1_000)
        try fixture.setModificationDate("\(folder)/\(marker)", modified)
        try fixture.setModificationDate("\(folder)/\(artifact)", modified)
        try fixture.setModificationDate(folder, modified)
    }

    private func scan() async -> RuleScanResult {
        await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: "/Users/nobody"), ownerState: { _ in .notRunning },
            now: now)
    }

    @Test("an artifact folder next to its project marker is offered, with the project name")
    func offered() async throws {
        try project("web", marker: "package.json", artifact: "node_modules", modified: old)

        let candidates = await scan().candidates

        #expect(candidates.map(\.path) == [fixture.url("Sources/web/node_modules").path(percentEncoded: false)])
        #expect(candidates.first?.logicalSize == 1_000)
    }

    @Test("an artifact-named folder without its marker is not offered")
    func requiresMarker() async throws {
        try fixture.file("Sources/notes/node_modules/readme.txt", bytes: 10)
        #expect(await scan().candidates.isEmpty)
    }

    @Test("inactive projects are pre-selected; active projects are listed for review only")
    func activity() async throws {
        try project("old-app", marker: "package.json", artifact: "node_modules", modified: old)
        try project("current-app", marker: "package.json", artifact: "node_modules", modified: recent)

        let candidates = await scan().candidates

        #expect(candidates.count == 2)
        #expect(candidates.first { $0.path.contains("old-app") }?.isSelectedByDefault == true)
        #expect(candidates.first { $0.path.contains("current-app") }?.isSelectedByDefault == false)
        #expect(candidates.first { $0.path.contains("current-app") }?.risk == .review)
    }

    @Test("each ecosystem is recognised by its own marker")
    func ecosystems() async throws {
        try project("swift", marker: "Package.swift", artifact: ".build", modified: old)
        try project("rust", marker: "Cargo.toml", artifact: "target", modified: old)
        try project("ios", marker: "Podfile", artifact: "Pods", modified: old)
        try project("android", marker: "build.gradle.kts", artifact: ".gradle", modified: old)

        let names = Set(await scan().candidates.map { ($0.path as NSString).lastPathComponent })

        #expect(names == [".build", "target", "Pods", ".gradle"])
    }

    @Test("artifact folders and .git are never searched inside, so nested copies are not offered twice")
    func noDescentIntoArtifacts() async throws {
        try project("web", marker: "package.json", artifact: "node_modules", modified: old)
        try fixture.file("Sources/web/node_modules/dep/package.json", bytes: 1)
        try fixture.file("Sources/web/node_modules/dep/node_modules/x.js", bytes: 1)
        try fixture.file("Sources/web/.git/modules/sub/package.json", bytes: 1)
        try fixture.file("Sources/web/.git/modules/sub/node_modules/y.js", bytes: 1)

        #expect(await scan().candidates.count == 1)
    }

    @Test("projects deeper than the depth limit are not searched")
    func depthLimit() async throws {
        try project("a/b/c/d/deep", marker: "package.json", artifact: "node_modules", modified: old)
        #expect(await scan().candidates.isEmpty)
    }

    @Test("a symlinked project folder is not followed")
    func symlinkedProject() async throws {
        try project("real", marker: "package.json", artifact: "node_modules", modified: old, in: "Elsewhere")
        try fixture.directory("Sources")
        try fixture.symlink("Sources/linked", to: fixture.url("Elsewhere/real").path(percentEncoded: false))

        #expect(await scan().candidates.isEmpty)
    }
}
