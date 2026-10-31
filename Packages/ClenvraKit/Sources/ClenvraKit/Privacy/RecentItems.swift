import Foundation
public import Observation

/// A Mac-wide recent list: the three in the Apple menu's Recent Items, and Finder's Go › Recent Folders.
public enum RecentList: String, CaseIterable, Sendable, Hashable {
    case applications, documents, servers, finderFolders
}

/// Reads and empties the Mac-wide lists. The app passes the live store (Apple's shared file lists and Finder's
/// settings); tests pass a fake.
public protocol RecentListStore: Sendable {
    /// The names in the list, newest first.
    func names(in list: RecentList) async -> [String]
    /// Empties the list; `true` when it was emptied. Finder's list can fill again at once with the folders of the
    /// windows Finder reopens.
    func clear(_ list: RecentList) async -> Bool
}

/// One app's File › Open Recent list.
public struct AppRecentList: Sendable, Identifiable, Equatable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    /// The list's file, which macOS keeps per app.
    public let file: String
    /// Paths of the documents, newest first, as recorded (the document may no longer exist).
    public let documents: [String]

    public init(bundleIdentifier: String, file: String, documents: [String]) {
        self.bundleIdentifier = bundleIdentifier
        self.file = file
        self.documents = documents
    }
}

/// Reads the per-app lists macOS keeps in `~/Library/Application Support/com.apple.sharedfilelist`.
public enum AppRecentListReader {
    public static let defaultDirectory =
        FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        + "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"

    /// Lists with at least one document, by bundle identifier. Unreadable files are left out.
    public static func read(directory: String) -> [AppRecentList] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.sorted().compactMap { name in
            let file = (directory as NSString).appendingPathComponent(name)
            let ext = (name as NSString).pathExtension
            guard ext.hasPrefix("sfl"), let data = FileManager.default.contents(atPath: file),
                let documents = documents(inArchive: data), !documents.isEmpty
            else { return nil }
            return AppRecentList(
                bundleIdentifier: (name as NSString).deletingPathExtension, file: file, documents: documents)
        }
    }

    /// The archive's `items`, each a bookmark, as paths. Bookmarks are read, never resolved: nothing is mounted or
    /// looked up, and a document that was moved or deleted keeps its recorded path.
    static func documents(inArchive data: Data) -> [String]? {
        let classes: [AnyClass] = [
            NSDictionary.self, NSArray.self, NSData.self, NSString.self, NSNumber.self, NSUUID.self, NSDate.self,
        ]
        guard let root = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSDictionary,
            let items = root["items"] as? [NSDictionary]
        else { return nil }
        return items.compactMap { item in
            guard let bookmark = item["Bookmark"] as? Data else { return nil }
            return URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
        }
    }
}

/// The Recent Items page: the Mac-wide lists (cleared whole, like the menus' Clear Menu) and each app's own list
/// (moved to the Trash while the app is closed). Nothing is selected by default.
@MainActor
@Observable
public final class RecentItemsSession {
    public private(set) var isLoading = false
    public private(set) var isWorking = false
    public private(set) var appLists: [AppRecentList] = []
    public private(set) var selectedLists: Set<RecentList> = []
    public private(set) var selectedApps: Set<String> = []
    private var lists: [RecentList: [String]] = [:]

    private let store: any RecentListStore
    private let appListsDirectory: String
    private let deleter: DeletionExecutor
    private let runner: any CommandRunning

    public init(
        store: any RecentListStore, appListsDirectory: String = AppRecentListReader.defaultDirectory,
        deleter: DeletionExecutor, runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.store = store
        self.appListsDirectory = appListsDirectory
        self.deleter = deleter
        self.runner = runner
    }

    public func names(in list: RecentList) -> [String] { lists[list] ?? [] }

    public func load() async {
        isLoading = true
        var read: [RecentList: [String]] = [:]
        for list in RecentList.allCases { read[list] = await store.names(in: list) }
        lists = read
        let directory = appListsDirectory
        appLists = await Task.detached { AppRecentListReader.read(directory: directory) }.value
        selectedLists = selectedLists.filter { !names(in: $0).isEmpty }
        selectedApps = selectedApps.intersection(appLists.map(\.id))
        isLoading = false
    }

    // MARK: - Mac-wide lists

    /// Only a list with something in it can be chosen.
    public func setSelected(_ selected: Bool, list: RecentList) {
        if selected, !names(in: list).isEmpty {
            selectedLists.insert(list)
        } else {
            selectedLists.remove(list)
        }
    }

    /// Empties the chosen lists and reads everything again. Returns the lists that did not read back empty.
    public func clearSelectedLists() async -> Set<RecentList> {
        isWorking = true
        var failed: Set<RecentList> = []
        for list in RecentList.allCases where selectedLists.contains(list) {
            if await !store.clear(list) { failed.insert(list) }
        }
        selectedLists = []
        await load()
        isWorking = false
        return failed
    }

    // MARK: - Apps' lists

    public func toggleApp(_ bundleIdentifier: String) {
        if selectedApps.contains(bundleIdentifier) {
            selectedApps.remove(bundleIdentifier)
        } else if appLists.contains(where: { $0.id == bundleIdentifier }) {
            selectedApps.insert(bundleIdentifier)
        }
    }

    public func setSelectedApps(_ bundleIdentifiers: Set<String>) {
        selectedApps = bundleIdentifiers.intersection(appLists.map(\.id))
    }

    /// Moves the chosen apps' lists to the Trash, then restarts macOS's list service so it does not write the old
    /// lists back from memory. The gate refuses the list of an app that is open, since the app keeps its own copy.
    public func clearSelectedApps() async -> CleanupSummary {
        isWorking = true
        let deletions = appLists.filter { selectedApps.contains($0.id) }.compactMap { list -> DeletionItem? in
            guard let snapshot = try? SafeWalk.resolve(list.file).snapshot else { return nil }
            return DeletionItem(
                path: list.file, ruleRoot: appListsDirectory, expected: snapshot, ownerBundleID: list.bundleIdentifier,
                freedBytes: 0, section: .cleanup)
        }
        let results = await deleter.run(deletions, mode: .moveToTrash)
        let summary = CleanupSummary(results: results)
        if summary.movedToTrashCount > 0 { await restartListService() }
        selectedApps = []
        await load()
        isWorking = false
        return summary
    }

    /// `launchctl kickstart -k` restarts the person's own list service; launchd keeps it running.
    private func restartListService() async {
        let command = Command(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", "gui/\(getuid())/com.apple.coreservices.sharedfilelistd"],
            timeout: .seconds(15))
        _ = try? await runner.run(command)
    }
}
