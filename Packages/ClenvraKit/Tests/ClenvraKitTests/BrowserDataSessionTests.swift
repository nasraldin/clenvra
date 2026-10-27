import Darwin
import Foundation
import Testing

@testable import ClenvraKit

private struct BrowserScratchTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

@MainActor
@Suite("BrowserDataSession")
struct BrowserDataSessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
    }

    private var home: String { scratch.url.path(percentEncoded: false).trimmingTrailingSlash }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func makeSession(running: Set<String> = []) -> BrowserDataSession {
        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { running.contains($0) ? .running : .notRunning }
        return BrowserDataSession(
            home: home, policy: policy, ownerState: ownerState,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState),
                log: ActivityLog(directory: fixture.url("log")),
                trash: BrowserScratchTrash(directory: path(".Trash"))))
    }

    @Test("scan never selects browser data and selection is explicit per data type")
    func optInSelection() async throws {
        let root = "Library/Application Support/Google/Chrome/Default"
        try fixture.file(root + "/History", bytes: 100)
        try fixture.file(root + "/Cookies", bytes: 200)
        try fixture.file(root + "/Sessions/Session_1", bytes: 300)
        let session = makeSession()

        await session.scan()

        #expect(session.phase == .ready)
        #expect(session.selection.isEmpty)
        #expect(session.selectedCount == 0)
        #expect(session.groups.count == 3)
        session.setSelected(true, browser: .chrome, dataType: .history)
        #expect(session.selection == [path(root + "/History")])
        session.setSelected(true, browser: .chrome, dataType: .cookies)
        #expect(session.selection == [path(root + "/History"), path(root + "/Cookies")])
        session.setSelected(false, browser: .chrome, dataType: .history)
        #expect(session.selection == [path(root + "/Cookies")])
        #expect(session.selectedWarnings.allSatisfy { $0.contains("sign") })
    }

    @Test("dry run and cleaning use the deletion executor and preserve unselected data")
    func cleanThroughTrash() async throws {
        let root = "Library/Application Support/Google/Chrome/Default"
        try fixture.file(root + "/History", bytes: 100)
        try fixture.file(root + "/Cookies", bytes: 200)
        try fixture.file(root + "/Sessions/Session_1", bytes: 300)
        let session = makeSession()
        await session.scan()
        session.setSelected(true, browser: .chrome, dataType: .history)

        let preview = await session.clean(dryRun: true)

        #expect(preview.wouldRemoveCount == 1)
        #expect(preview.movedToTrashCount == 0)
        #expect(FileManager.default.fileExists(atPath: path(root + "/History")))

        let summary = await session.clean()

        #expect(summary.movedToTrashCount == 1)
        #expect(summary.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path(root + "/History")))
        #expect(FileManager.default.fileExists(atPath: path(root + "/Cookies")))
        #expect(FileManager.default.fileExists(atPath: path(root + "/Sessions")))
        #expect(session.selection.isEmpty)
    }

    @Test("directory-backed sessions and site data are gated and moved as complete folders")
    func cleanDirectories() async throws {
        let root = "Library/Application Support/Google/Chrome/Default"
        try fixture.file(root + "/Sessions/Session_1", bytes: 100)
        try fixture.file(root + "/Local Storage/leveldb/000003.log", bytes: 200)
        let session = makeSession()
        await session.scan()
        session.setSelected(true, browser: .chrome, dataType: .sessions)
        session.setSelected(true, browser: .chrome, dataType: .siteData)

        let summary = await session.clean()

        #expect(summary.movedToTrashCount == 2)
        #expect(summary.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path(root + "/Sessions")))
        #expect(!FileManager.default.fileExists(atPath: path(root + "/Local Storage")))
    }

    @Test("a running browser cannot be selected and the gate still blocks a stale selection")
    func runningBrowserCannotClean() async throws {
        let root = "Library/Application Support/Google/Chrome/Default"
        try fixture.file(root + "/History", bytes: 100)
        let session = makeSession(running: ["com.google.Chrome"])
        await session.scan()
        let history = path(root + "/History")

        session.toggle(history)
        #expect(session.selection.isEmpty)
        let summary = await session.clean()
        #expect(summary.movedToTrashCount == 0)
        #expect(FileManager.default.fileExists(atPath: history))
    }

    @Test("Firefox history discloses that places.sqlite also contains bookmarks")
    func firefoxWarningIsVisibleToSession() async throws {
        let root = "Library/Application Support/Firefox/Profiles/default"
        try fixture.file(root + "/places.sqlite", bytes: 100)
        try fixture.directory("Library/Application Support/Firefox")
        // A missing profiles.ini falls back to the profile directory fixture.
        let session = makeSession()
        await session.scan()

        let group = try #require(session.groups.first { $0.browser == .firefox && $0.dataType == .history })
        #expect(group.removesBookmarks)
        #expect(group.warning.contains("bookmarks"))
        #expect(group.items.allSatisfy { !$0.isSelectedByDefault })
    }
}

extension String {
    fileprivate var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
