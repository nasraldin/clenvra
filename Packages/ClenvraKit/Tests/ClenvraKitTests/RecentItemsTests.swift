import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// The Apple menu and Finder lists, recorded instead of touching the real ones.
private final class FakeRecentListStore: RecentListStore {
    private let contents: Mutex<[RecentList: [String]]>
    private let clears = Mutex<[RecentList]>([])
    let clearSucceeds: Bool

    init(_ contents: [RecentList: [String]], clearSucceeds: Bool = true) {
        self.contents = Mutex(contents)
        self.clearSucceeds = clearSucceeds
    }

    var cleared: [RecentList] { clears.withLock { $0 } }

    func names(in list: RecentList) async -> [String] { contents.withLock { $0[list] ?? [] } }

    func clear(_ list: RecentList) async -> Bool {
        clears.withLock { $0.append(list) }
        if clearSucceeds { contents.withLock { $0[list] = [] } }
        return clearSucceeds
    }
}

/// Moves items into a `.Trash` folder inside the test directory.
private struct RecentTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

@MainActor
@Suite("Recent items")
struct RecentItemsTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let runner = FakeCommandRunner()
    private let kickstart = [
        "kickstart", "-k", "gui/\(getuid())/com.apple.coreservices.sharedfilelistd",
    ]

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try fixture.directory("lists")
        _ = try fixture.file("docs/a.txt", bytes: 1)
        _ = try fixture.file("docs/b.txt", bytes: 1)
    }

    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    /// Writes an app's recent-documents list the way macOS archives it: `items`, each with a `Bookmark`.
    private func writeList(_ bundleID: String, documents: [String]) throws {
        let items = try documents.map { ["Bookmark": try URL(filePath: path($0)).bookmarkData()] }
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: ["items": items, "properties": [:]] as NSDictionary, requiringSecureCoding: false)
        try data.write(to: fixture.url("lists/\(bundleID).sfl4"))
    }

    private func session(
        store: FakeRecentListStore = FakeRecentListStore([:]), running: Set<String> = []
    ) -> RecentItemsSession {
        RecentItemsSession(
            store: store, appListsDirectory: path("lists"),
            deleter: DeletionExecutor(
                gate: DeletionGate(
                    policy: ProtectionPolicy(home: path("home")),
                    ownerState: { running.contains($0) ? .running : .notRunning }),
                log: ActivityLog(directory: fixture.url("log")), trash: RecentTrash(directory: path(".Trash"))),
            runner: runner)
    }

    @Test("an app's Open Recent list is read from its archive, newest first, and empty lists are left out")
    func readsAppLists() throws {
        try writeList("com.example.writer", documents: ["docs/b.txt", "docs/a.txt"])
        try writeList("com.example.empty", documents: [])
        try Data("not an archive".utf8).write(to: fixture.url("lists/com.example.broken.sfl4"))
        try Data().write(to: fixture.url("lists/notes.txt"))

        let lists = AppRecentListReader.read(directory: path("lists"))

        #expect(lists.map(\.bundleIdentifier) == ["com.example.writer"])
        #expect(lists.first?.documents == [path("docs/b.txt"), path("docs/a.txt")])
        #expect(lists.first?.file == path("lists/com.example.writer.sfl4"))
    }

    @Test("a document that no longer exists is still listed by its recorded path")
    func listsMissingDocuments() throws {
        try writeList("com.example.writer", documents: ["docs/a.txt"])
        try FileManager.default.removeItem(atPath: path("docs/a.txt"))

        #expect(AppRecentListReader.read(directory: path("lists")).first?.documents == [path("docs/a.txt")])
    }

    @Test("loading reads every list and selects nothing")
    func load() async throws {
        try writeList("com.example.writer", documents: ["docs/a.txt"])
        let session = session(store: FakeRecentListStore([.applications: ["Mail"], .finderFolders: ["Documents"]]))

        await session.load()

        #expect(session.names(in: .applications) == ["Mail"])
        #expect(session.names(in: .finderFolders) == ["Documents"])
        #expect(session.names(in: .servers).isEmpty)
        #expect(session.appLists.map(\.bundleIdentifier) == ["com.example.writer"])
        #expect(session.selectedLists.isEmpty && session.selectedApps.isEmpty)
    }

    @Test("clearing empties only the chosen Mac lists and reads them again")
    func clearsChosenLists() async {
        let store = FakeRecentListStore([.applications: ["Mail"], .documents: ["a.txt"], .finderFolders: ["Documents"]])
        let session = session(store: store)
        await session.load()
        session.setSelected(true, list: .documents)
        session.setSelected(true, list: .finderFolders)
        session.setSelected(true, list: .servers)  // empty: nothing to clear, not selectable

        let failed = await session.clearSelectedLists()

        #expect(failed.isEmpty)
        #expect(Set(store.cleared) == [.documents, .finderFolders])
        #expect(session.names(in: .documents).isEmpty)
        #expect(session.names(in: .applications) == ["Mail"])
        #expect(session.selectedLists.isEmpty)
    }

    @Test("a list that does not read back empty is reported")
    func reportsFailedClear() async {
        let session = session(store: FakeRecentListStore([.documents: ["a.txt"]], clearSucceeds: false))
        await session.load()
        session.setSelected(true, list: .documents)

        #expect(await session.clearSelectedLists() == [.documents])
    }

    @Test("clearing an app's list moves it to the Trash and restarts the list service once")
    func clearsAppLists() async throws {
        try writeList("com.example.writer", documents: ["docs/a.txt"])
        try writeList("com.example.viewer", documents: ["docs/b.txt"])
        runner.stub("/bin/launchctl", kickstart)
        let session = session()
        await session.load()
        session.toggleApp("com.example.writer")
        session.toggleApp("com.example.viewer")

        let summary = await session.clearSelectedApps()

        #expect(summary.movedToTrashCount == 2)
        #expect(!FileManager.default.fileExists(atPath: path("lists/com.example.writer.sfl4")))
        #expect(runner.commands.filter { $0.arguments == kickstart }.count == 1)
        #expect(session.appLists.isEmpty)
        #expect(session.selectedApps.isEmpty)
    }

    @Test("an app that is open keeps its list, and the list service is not restarted")
    func refusesOpenApp() async throws {
        try writeList("com.example.writer", documents: ["docs/a.txt"])
        let session = session(running: ["com.example.writer"])
        await session.load()
        session.toggleApp("com.example.writer")

        let summary = await session.clearSelectedApps()

        #expect(summary.movedToTrashCount == 0)
        #expect(FileManager.default.fileExists(atPath: path("lists/com.example.writer.sfl4")))
        #expect(runner.commands.isEmpty)
    }
}
