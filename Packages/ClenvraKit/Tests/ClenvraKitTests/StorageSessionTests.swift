import Darwin
import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Moves items into a `.Trash` folder inside the test directory.
private struct StorageScratchTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let destination = directory + "/" + UUID().uuidString
        guard rename(path, destination) == 0 else { throw FileSystemError.current("rename", path) }
        return destination
    }
}

@MainActor
@Suite("StorageSession")
struct StorageSessionTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let now = Date()

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try fixture.file("Projects/big/video.mov", bytes: 3_000_000)
        try fixture.file("Projects/big/recent.bin", bytes: 2_000_000)
        try fixture.file("Projects/small/a.txt", bytes: 1_000)
        try fixture.file("Projects/notes.txt", bytes: 2_000)
        try fixture.file("Projects/.env", bytes: 10)
        try fixture.file(".ssh/id_ed25519", bytes: 10)
        try fixture.file("Downloads/Installer.dmg", bytes: 5_000)
        try fixture.file("Downloads/.localized", bytes: 0)
        try fixture.file("Downloads/.DS_Store", bytes: 600)
        try fixture.file("Downloads/photos.zip", bytes: 4_000)
        try fixture.file("Downloads/Screenshot 2026-01-01 at 10.00.00.png", bytes: 300)
        try fixture.directory("Downloads/Unpacked")
        try fixture.file("Desktop/Screenshot 2026-02-01 at 09.00.00.png", bytes: 700)
        try fixture.file("Desktop/Screen Recording 2026-02-01 at 09.05.00.mov", bytes: 900)
        try fixture.file("Desktop/لقطة شاشة 2026-02-02.png", bytes: 500)
        try fixture.file("Desktop/report.pdf", bytes: 800)
        try fixture.file("Desktop/Screenshot notes.txt", bytes: 100)
        try setModified("Projects/big/video.mov", daysAgo: 800)
        try setModified("Downloads/photos.zip", daysAgo: 400)
    }

    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }
    private func path(_ relative: String) -> String { home + "/" + relative }

    private func setModified(_ relative: String, daysAgo: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: path(relative))
    }

    private var sessionOptions: ScanOptions {
        ScanOptions(largeFileThreshold: 1_000_000, excludedPaths: [path("log"), path(".Trash")])
    }

    private func session(volumes: [Volume] = [], screenshotsLocation: String? = nil) -> StorageSession {
        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { _ in .notRunning }
        return StorageSession(
            home: home, policy: policy,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: ownerState),
                log: ActivityLog(directory: fixture.url("log")),
                trash: StorageScratchTrash(directory: path(".Trash"))),
            screenshotsLocation: screenshotsLocation,
            options: sessionOptions,
            volumes: { volumes }, now: { [now] in now })
    }

    private func volume(_ path: String, name: String, root: Bool, kind: Volume.Kind = .internal) -> Volume {
        Volume(
            id: URL(filePath: path, directoryHint: .isDirectory), name: name, kind: kind, fileSystem: "apfs",
            isRoot: root, isReadOnly: false, isEjectable: !root, totalCapacity: 1_000, availableCapacity: 400,
            availableForImportantUsage: 500)
    }

    // MARK: - Targets

    @Test("targets are the home folder, the startup volume's data volume and external volumes at their mount point")
    func targets() async {
        let session = session(volumes: [
            volume("/", name: "Macintosh HD", root: true),
            volume("/Volumes/Backup", name: "Backup", root: false, kind: .external),
        ])

        await session.refreshVolumes()

        #expect(session.volumes.map(\.name) == ["Macintosh HD", "Backup"])
        #expect(session.targets.map(\.root) == [home, "/System/Volumes/Data", "/Volumes/Backup"])
        #expect(session.targets.map(\.kind) == [.home, .startupVolume, .volume(.external)])
        #expect(session.target.kind == .home)

        session.select(session.targets[2])
        #expect(session.target.root == "/Volumes/Backup")
        #expect(session.currentPath == "/Volumes/Backup")
        #expect(session.snapshot == nil)
    }

    // MARK: - Scanning and browsing

    @Test(
        "scanning lists the root's children by size; macOS's home folders and keys are protected, the person's own folders are selectable"
    )
    func scanAndProtection() async throws {
        let session = session()

        await session.scan()

        #expect(session.phase == .ready)
        #expect(session.isPartial == false)
        #expect(session.currentPath == home)
        let names = session.children.map(\.name)
        #expect(names.first == "Projects")
        #expect(Set(names).isSuperset(of: ["Projects", "Downloads", "Desktop", ".ssh"]))
        let projects = try #require(session.children.first { $0.name == "Projects" })
        #expect(projects.kind == .directory)
        #expect(projects.allocatedSize >= 5_000_000)
        #expect(projects.fileCount == 5)
        #expect(projects.folderCount == 2)
        // A folder the person made at the top of home can be reviewed and moved to the Trash (F1).
        #expect(projects.protection == nil)
        #expect(projects.isSelectable)
        let downloads = try #require(session.children.first { $0.name == "Downloads" })
        #expect(downloads.protection == .homeRoot)

        session.setSelection([projects.path, path(".ssh"), downloads.path])
        #expect(session.selection == [projects.path])
    }

    @Test("drill into a folder, see files and subfolders, go back up; breadcrumbs follow")
    func browse() async throws {
        let session = session()
        await session.scan()

        await session.open(path("Projects"))

        #expect(session.currentPath == path("Projects"))
        #expect(session.breadcrumbs.map(\.path) == [home, path("Projects")])
        #expect(session.children.map(\.name) == ["big", "notes.txt", "small", ".env"])
        let notes = try #require(session.children.first { $0.name == "notes.txt" })
        #expect(notes.kind == .file && notes.fileCount == 1 && notes.isSelectable)
        #expect(session.children.first { $0.name == ".env" }?.protection == .secret)
        #expect(session.canGoUp)

        await session.open(path("Projects/big"))
        #expect(session.breadcrumbs.count == 3)

        await session.goUp()
        #expect(session.currentPath == path("Projects"))
        await session.goUp()
        #expect(session.currentPath == home)
        #expect(!session.canGoUp)
        await session.goUp()
        #expect(session.currentPath == home)

        await session.open(path("Projects/notes.txt"))
        #expect(session.currentPath == home)
    }

    @Test("cancelling a scan keeps a partial snapshot and says so")
    func cancellation() async {
        let session = session()
        // The fixture is tiny, so a real scan can finish before the cancel arrives. Hold the scan until it is
        // cancelled, then let the real scanner run under cancellation.
        session.scanFunction = { root, options, executor, progress in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return try await StorageScanner.defaultScan(root, options, executor, progress)
        }

        let running = Task { await session.scan() }
        while session.phase == .idle { await Task.yield() }
        session.cancelScan()
        await running.value

        #expect(session.phase == .ready)
        #expect(session.isPartial)
        #expect(session.snapshot?.isComplete == false)
    }

    @Test("a missing root fails the scan without crashing")
    func missingRoot() async {
        let session = session(volumes: [volume(path("Nowhere"), name: "Gone", root: false, kind: .external)])
        await session.refreshVolumes()
        session.select(session.targets[1])

        await session.scan()

        #expect(session.phase == .failed)
        #expect(session.snapshot == nil)
    }

    // MARK: - Large & Old

    @Test("large files are filtered by minimum size and age")
    func largeFiles() async {
        let session = session()
        await session.scan()
        session.list = .largeFiles

        session.largeFileMinimum = 1_000_000
        #expect(session.largeFiles.map(\.name) == ["video.mov", "recent.bin"])

        session.largeFileMinimum = 2_500_000
        #expect(session.largeFiles.map(\.name) == ["video.mov"])

        session.largeFileMinimum = 1_000_000
        session.largeFileAge = .oneYear
        #expect(session.largeFiles.map(\.name) == ["video.mov"])
        session.largeFileAge = .sixMonths
        #expect(session.largeFiles.map(\.name) == ["video.mov"])
        session.largeFileAge = .twoYears
        #expect(session.largeFiles.map(\.name) == ["video.mov"])
        try? setModified("Projects/big/video.mov", daysAgo: 0)
        #expect(session.largeFiles.map(\.name) == ["video.mov"])  // the list reflects the scan, not the disk

        session.largeFileAge = .any
        session.largeFileMinimum = 50_000_000
        #expect(session.largeFiles.isEmpty)
    }

    // MARK: - Downloads & Screenshots

    @Test("screenshot names match the system patterns in English and Arabic")
    func screenshotNames() {
        #expect(ClutterKind.screenshotKind(forName: "Screenshot 2026-01-01 at 10.00.00.png") == .screenshot)
        #expect(ClutterKind.screenshotKind(forName: "Screen Shot 2019-01-01 at 10.00.00.PNG") == .screenshot)
        #expect(ClutterKind.screenshotKind(forName: "Screenshot 2026.heic") == .screenshot)
        #expect(ClutterKind.screenshotKind(forName: "Screenshot 2026.jpg") == .screenshot)
        #expect(ClutterKind.screenshotKind(forName: "Screen Recording 2026-01-01.mov") == .screenRecording)
        #expect(ClutterKind.screenshotKind(forName: "لقطة شاشة 2026-01-01.png") == .screenshot)
        #expect(ClutterKind.screenshotKind(forName: "تسجيل الشاشة 2026-01-01.mov") == .screenRecording)
        #expect(ClutterKind.screenshotKind(forName: "Screenshot notes.txt") == nil)
        #expect(ClutterKind.screenshotKind(forName: "Holiday.png") == nil)
        #expect(ClutterKind.classify(name: "Installer.DMG") == .installer)
        #expect(ClutterKind.classify(name: "photos.zip") == .archive)
        #expect(ClutterKind.classify(name: "song.mp3") == .audio)
        #expect(ClutterKind.classify(name: "README") == .other)
    }

    @Test("the screenshots folder defaults to the Desktop and expands a configured location")
    func screenshotsFolder() {
        func folder(_ configured: String?) -> String {
            StorageSession.screenshotsFolder(configured: configured, home: "/Users/a")
        }
        #expect(folder(nil) == "/Users/a/Desktop")
        #expect(folder("  ") == "/Users/a/Desktop")
        #expect(folder("~/Pictures/Shots/") == "/Users/a/Pictures/Shots")
        #expect(folder("/Volumes/X/Shots") == "/Volumes/X/Shots")
        #expect(folder("relative") == "/Users/a/Desktop")
    }

    @Test("downloads and screenshots are listed, grouped by kind and age, and never pre-selected")
    func clutter() async throws {
        let session = session()
        // Hidden files (.localized, .DS_Store) belong to macOS and are never listed.
        // Nothing is listed until the person asks (F3).
        #expect(!session.hasLoadedClutter)

        await session.loadClutter()
        #expect(session.hasLoadedClutter)
        session.list = .clutter

        #expect(session.screenshotsPath == path("Desktop"))
        #expect(
            Set(session.clutter.map(\.item.name)) == [
                "Installer.dmg", "photos.zip", "Screenshot 2026-01-01 at 10.00.00.png",
                "Screenshot 2026-02-01 at 09.00.00.png", "Screen Recording 2026-02-01 at 09.05.00.mov",
                "لقطة شاشة 2026-02-02.png",
            ])
        #expect(session.selection.isEmpty)
        #expect(session.clutter.allSatisfy { $0.item.isSelectable })

        let byKind = session.clutterGroups(by: .kind)
        #expect(byKind.map(\.key) == [.kind(.screenshot), .kind(.screenRecording), .kind(.installer), .kind(.archive)])
        #expect(byKind[0].items.count == 3)
        #expect(byKind[0].totalBytes > 0)

        let byAge = session.clutterGroups(by: .age)
        #expect(byAge.map(\.key) == [.age(.thisWeek), .age(.older)])
        #expect(byAge[1].items.map(\.item.name) == ["photos.zip"])
    }

    @Test("Downloads can be narrowed by age and by size before grouping (F7)")
    func clutterFilter() async {
        let session = session()
        await session.loadClutter()
        func names(_ filter: ClutterFilter) -> Set<String> {
            Set(session.clutterGroups(by: .kind, filter: filter).flatMap(\.items).map(\.item.name))
        }

        #expect(names(ClutterFilter()).count == 6)
        #expect(names(ClutterFilter(modifiedBefore: now.addingTimeInterval(-30 * 86_400))) == ["photos.zip"])
        let lastWeek = names(ClutterFilter(modifiedAfter: now.addingTimeInterval(-7 * 86_400)))
        #expect(lastWeek.count == 5 && !lastWeek.contains("photos.zip"))
        #expect(names(ClutterFilter(minimumBytes: 6_000)) == ["Installer.dmg"])
        // A custom range: older than a week but newer than two years.
        #expect(
            names(
                ClutterFilter(
                    modifiedBefore: now.addingTimeInterval(-7 * 86_400),
                    modifiedAfter: now.addingTimeInterval(-730 * 86_400))) == ["photos.zip"])
    }

    @Test("the clutter filter keeps one source or both")
    func filterBySource() async {
        let session = session()
        await session.loadClutter()
        func names(_ source: ClutterSource?) -> Set<String> {
            Set(
                session.clutterGroups(by: .kind, filter: ClutterFilter(source: source)).flatMap(\.items).map(
                    \.item.name))
        }
        let downloads: Set<String> = ["Installer.dmg", "photos.zip", "Screenshot 2026-01-01 at 10.00.00.png"]
        let screenshots: Set<String> = [
            "Screenshot 2026-02-01 at 09.00.00.png", "Screen Recording 2026-02-01 at 09.05.00.mov",
            "لقطة شاشة 2026-02-02.png",
        ]

        #expect(names(.downloads) == downloads)
        #expect(names(.screenshots) == screenshots)
        #expect(names(nil) == downloads.union(screenshots))
    }

    @Test("the clutter filter matches the file name, ignoring case and spaces around the text")
    func filterByName() async {
        let session = session()
        await session.loadClutter()
        func names(_ text: String) -> Set<String> {
            Set(
                session.clutterGroups(by: .kind, filter: ClutterFilter(nameContains: text)).flatMap(\.items).map(
                    \.item.name))
        }
        #expect(names("  INSTALLER ") == ["Installer.dmg"])
        #expect(names("لقطة") == ["لقطة شاشة 2026-02-02.png"])
        #expect(names("nothing like this").isEmpty)
        #expect(names("").count == 6)
    }

    @Test("the selection holds only files of the visible tab, and switching tabs clears it")
    func selectionFollowsSource() async {
        let session = session()
        await session.loadClutter()
        session.list = .clutter
        let download = path("Downloads/Installer.dmg")
        let shot = path("Desktop/Screenshot 2026-02-01 at 09.00.00.png")

        session.clutterSource = .downloads
        session.setSelection([download, shot])
        #expect(session.selection == [download])

        session.clutterSource = .screenshots
        #expect(session.selection.isEmpty)
        session.setSelection([download, shot])
        #expect(session.selection == [shot])

        session.clutterSource = nil
        session.setSelection([download, shot])
        #expect(session.selection == [download, shot])
    }

    @Test("a screenshot saved into Downloads is listed once, as a download")
    func screenshotInDownloadsCountsOnce() async {
        for location in [path("Downloads"), "~/Downloads/", path("Downloads/../Downloads")] {
            let session = session(screenshotsLocation: location)
            await session.loadClutter()

            let shots = session.clutter.filter { $0.item.name == "Screenshot 2026-01-01 at 10.00.00.png" }
            #expect(shots.count == 1, "\(location)")
            #expect(shots.first?.source == .downloads, "\(location)")
            #expect(session.clutter.allSatisfy { $0.source == .downloads }, "\(location)")
            #expect(Set(session.clutter.map(\.item.path)).count == session.clutter.count, "\(location)")
            #expect(session.clutterGroups(by: .kind, filter: ClutterFilter(source: .screenshots)).isEmpty)
        }
    }

    private func setWhereFroms(_ relative: String, _ urls: [String]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0)
        let result = data.withUnsafeBytes { buffer in
            setxattr(
                path(relative), DownloadSource.whereFromsAttribute, buffer.baseAddress, buffer.count, 0,
                XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw POSIXError(.EIO) }
    }

    @Test("downloads carry the website they came from and group by it, largest first, unknown last")
    func clutterBySource() async throws {
        try setWhereFroms(
            "Downloads/Installer.dmg", ["https://www.github.com/x/Installer.dmg", "https://github.com/x"])
        try setWhereFroms("Downloads/photos.zip", ["https://dropbox.com/s/photos.zip"])
        try fixture.file("Downloads/zeta.txt", bytes: 3_000)
        try setWhereFroms("Downloads/zeta.txt", ["https://zeta.example/z"])
        try fixture.file("Downloads/alpha.txt", bytes: 3_000)
        try setWhereFroms("Downloads/alpha.txt", ["https://alpha.example/a"])
        let session = session()

        await session.loadClutter()

        let installer = try #require(session.clutter.first { $0.item.name == "Installer.dmg" })
        #expect(installer.sourceHost == "github.com")
        #expect(session.clutter.first { $0.item.name == "Screenshot 2026-02-01 at 09.00.00.png" }?.sourceHost == nil)

        let groups = session.clutterGroups(by: .sourceHost)
        #expect(
            groups.map(\.key) == [
                .sourceHost("github.com"), .sourceHost("alpha.example"), .sourceHost("dropbox.com"),
                .sourceHost("zeta.example"), .sourceHost(nil),
            ])
        // The three middle groups each hold one block-sized file, so they tie and fall back to host order.
        #expect(Set(groups[1...3].map(\.totalBytes)).count == 1)
        #expect(groups[0].totalBytes > groups[1].totalBytes)
        #expect(groups.last?.items.count == 4)
        #expect(groups.last.map { $0.totalBytes > groups[0].totalBytes } == true)
        #expect(groups.flatMap(\.items).count == session.clutter.count)
    }

    @Test("a configured screenshots location is used")
    func configuredScreenshots() async throws {
        try fixture.file("Shots/Screenshot 1.png", bytes: 10)
        let session = session(screenshotsLocation: path("Shots") + "/")

        await session.loadClutter()

        #expect(session.screenshotsPath == path("Shots"))
        #expect(session.clutter.contains { $0.item.name == "Screenshot 1.png" && $0.kind == .screenshot })
        #expect(!session.clutter.contains { $0.item.name == "Screenshot 2026-02-01 at 09.00.00.png" })
    }

    // MARK: - Deleting

    @Test("selection only holds selectable items of the visible list, and switching lists clears it")
    func selectionScope() async {
        let session = session()
        await session.scan()
        await session.open(path("Projects"))

        session.setSelection([path("Projects/notes.txt"), path("Projects/.env"), path("Projects/big/video.mov")])
        #expect(session.selection == [path("Projects/notes.txt")])
        #expect(session.selectedCount == 1)
        #expect(session.selectedBytes >= 2_000)

        session.list = .largeFiles
        #expect(session.selection.isEmpty)
    }

    @Test("after moving items to the Trash, the disks are read again so free space is current (F2)")
    func volumesRefreshAfterCleanup() async throws {
        let reads = Mutex(0)
        let before = volume("/", name: "Before", root: true)
        let after = volume("/", name: "After", root: true)
        let policy = ProtectionPolicy(home: home)
        let session = StorageSession(
            home: home, policy: policy,
            deleter: DeletionExecutor(
                gate: DeletionGate(policy: policy, ownerState: { _ in .notRunning }),
                log: ActivityLog(directory: fixture.url("log")),
                trash: StorageScratchTrash(directory: path(".Trash"))),
            screenshotsLocation: nil, options: sessionOptions,
            volumes: {
                reads.withLock { count in
                    count += 1
                    return count == 1 ? [before] : [after]
                }
            }, now: { [now] in now })
        await session.refreshVolumes()
        #expect(session.volumes.map(\.name) == ["Before"])
        await session.scan()
        await session.open(path("Projects"))
        session.setSelection([path("Projects/notes.txt")])

        _ = await session.moveSelectionToTrash()

        #expect(session.volumes.map(\.name) == ["After"])
    }

    @Test("moving browser items to the Trash rescans and updates the totals")
    func deleteFromBrowser() async throws {
        let session = session()
        await session.scan()
        await session.open(path("Projects"))
        let before = try #require(session.snapshot?.aggregate(at: path("Projects"))?.fileCount)
        session.setSelection([path("Projects/notes.txt"), path("Projects/small")])

        let summary = await session.moveSelectionToTrash()

        #expect(summary.movedToTrashCount == 2)
        #expect(summary.problems.isEmpty)
        #expect(summary.freedBytes > 0)
        #expect(session.lastSummary == summary)
        #expect(!FileManager.default.fileExists(atPath: path("Projects/notes.txt")))
        #expect(session.phase == .ready)
        #expect(!session.isStale)
        #expect(session.selection.isEmpty)
        #expect(session.currentPath == path("Projects"))
        #expect(session.children.map(\.name) == ["big", ".env"])
        #expect(session.snapshot?.aggregate(at: path("Projects"))?.fileCount == before - 2)
    }

    @Test("after deleting the folder being browsed, the browser moves to the nearest remaining ancestor")
    func deleteCurrentAncestor() async throws {
        let session = session()
        await session.scan()
        await session.open(path("Projects"))
        await session.open(path("Projects/big"))
        session.list = .largeFiles
        session.largeFileMinimum = 1_000_000
        session.setSelection([path("Projects/big/video.mov")])

        let summary = await session.moveSelectionToTrash()

        #expect(summary.movedToTrashCount == 1)
        #expect(session.largeFiles.map(\.name) == ["recent.bin"])
        #expect(session.currentPath == path("Projects/big"))

        try FileManager.default.removeItem(atPath: path("Projects/big"))
        await session.scan()
        #expect(session.currentPath == path("Projects"))
    }

    @Test("after a partial deletion only the folder that changed is rescanned, and totals match a full rescan")
    func rescanOnlyAffectedFolder() async throws {
        let session = session()
        let recorder = ScanRecorder()
        session.scanFunction = recorder.scan
        await session.scan()
        #expect(recorder.all == [home])
        await session.open(path("Projects"))
        session.setSelection([path("Projects/notes.txt"), path("Projects/small")])
        try FileManager.default.removeItem(atPath: path("Projects/small"))
        try fixture.file("Projects/small/b.txt", bytes: 3_000)
        recorder.reset()

        let summary = await session.moveSelectionToTrash()

        #expect(summary.movedToTrashCount == 1)
        #expect(summary.problems.map(\.path) == [path("Projects/small")])
        #expect(recorder.all == [path("Projects")])
        #expect(session.phase == .ready)
        #expect(!session.isStale)
        #expect(session.children.map(\.name) == ["big", "small", ".env"])
        let full = try await StorageScanner.scan(root: home, options: sessionOptions)
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.directories[home] == full.directories[home])
        #expect(snapshot.directories[path("Projects")] == full.directories[path("Projects")])
        #expect(snapshot.directories == full.directories)
        #expect(Set(snapshot.largeFiles) == Set(full.largeFiles))
    }

    @Test("an item changed after the scan is skipped with a reason, not deleted")
    func changedSinceScan() async throws {
        let session = session()
        await session.scan()
        await session.open(path("Projects"))
        session.setSelection([path("Projects/notes.txt")])
        try FileManager.default.removeItem(atPath: path("Projects/notes.txt"))
        try fixture.file("Projects/notes.txt", bytes: 2_000)

        let summary = await session.moveSelectionToTrash()

        #expect(summary.movedToTrashCount == 0)
        #expect(summary.problems.map(\.path) == [path("Projects/notes.txt")])
        #expect(FileManager.default.fileExists(atPath: path("Projects/notes.txt")))
    }

    @Test("deleting downloads and screenshots reloads that list")
    func deleteClutter() async throws {
        let session = session()
        await session.loadClutter()
        session.list = .clutter
        session.setSelection([path("Downloads/Installer.dmg"), path("Desktop/Screenshot 2026-02-01 at 09.00.00.png")])

        let summary = await session.moveSelectionToTrash()

        #expect(summary.movedToTrashCount == 2)
        #expect(!session.clutter.contains { $0.item.name == "Installer.dmg" })
        #expect(session.clutter.count == 4)
        #expect(session.snapshot == nil)
    }
}
