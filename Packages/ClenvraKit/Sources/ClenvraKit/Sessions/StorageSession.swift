import Darwin
public import Foundation
public import Observation

/// The Storage section: volume capacity, a scanned space map to browse, Large & Old files, and the
/// Downloads & Screenshots review, with deletion of selected items through the deletion gate.
///
/// The UI binds to this model; directory reads, scans and deletions run off the main actor.
@MainActor
@Observable
public final class StorageSession {
    public enum Phase: Sendable, Equatable {
        case idle
        /// `nil` until the scanner reports its first counters.
        case scanning(ScanProgress?)
        case ready
        /// The target folder could not be opened.
        case failed
        case deleting
    }

    /// One level of the path bar.
    public struct Breadcrumb: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let name: String
        public let path: String
    }

    // MARK: State

    public private(set) var volumes: [Volume] = []
    public private(set) var target: ScanTarget
    public private(set) var phase = Phase.idle
    public private(set) var snapshot: StorageSnapshot?
    /// Set when items were deleted after the scan, until the rescan finishes.
    public private(set) var isStale = false
    public private(set) var currentPath: String
    /// Children of `currentPath`, largest first.
    public private(set) var children: [StorageItem] = []
    public private(set) var clutter: [ClutterItem] = []
    public private(set) var isLoadingClutter = false
    /// Downloads and screenshots have been listed at least once; until then the page offers a Scan button.
    public private(set) var hasLoadedClutter = false
    /// Canonical screenshots folder, once Downloads & Screenshots has been loaded.
    public private(set) var screenshotsPath: String?
    /// What Move to Trash removes: on the Space Map, the selected rows and the checked ones are the same set.
    public private(set) var selection: Set<String> = []
    public private(set) var lastSummary: CleanupSummary?

    /// The visible list; changing it clears the selection so only what the user sees can be deleted.
    public var list = StorageList.browser {
        didSet { if list != oldValue { selection = [] } }
    }
    /// Which source of the clutter list is visible (the Downloads tab or the Other tab; `nil` shows both). Changing
    /// it clears the selection, so a file chosen on one tab is never moved to the Trash from the other.
    public var clutterSource: ClutterSource? {
        didSet { if clutterSource != oldValue { selection = [] } }
    }
    /// Minimum allocated size of Large & Old files, in bytes.
    public var largeFileMinimum: Int64 = 50_000_000 {
        didSet { pruneSelection() }
    }
    public var largeFileAge = LargeFileAge.any {
        didSet { pruneSelection() }
    }

    // MARK: Dependencies

    private let home: String
    private let policy: ProtectionPolicy
    private let deleter: DeletionExecutor
    private let screenshotsLocation: String?
    private let options: ScanOptions
    private let loadVolumes: @Sendable () -> [Volume]
    private let executor: FSExecutor
    private let now: @Sendable () -> Date
    private var scanTask: Task<StorageSnapshot, any Error>?
    private var scanGeneration = 0
    /// Reads one folder tree; replaced in tests to observe which folders are scanned.
    var scanFunction: StorageScanner.ScanFunction = StorageScanner.defaultScan

    /// - Parameters:
    ///   - home: canonical home folder, the default scan target.
    ///   - screenshotsLocation: the `location` value of the `com.apple.screencapture` defaults, if set.
    ///   - options: scan tunables; the large-file threshold should not exceed the smallest Large & Old filter.
    ///   - volumes: lists mounted volumes; injected so tests do not depend on this Mac's disks.
    public init(
        home: String, policy: ProtectionPolicy, deleter: DeletionExecutor, screenshotsLocation: String? = nil,
        options: ScanOptions = ScanOptions(largeFileThreshold: 50_000_000),
        // Real disks only: disk images (installers) have their own page, Mounted Disks.
        volumes: @escaping @Sendable () -> [Volume] = { VolumeInventory.mountedVolumes().filter(\.isRealDisk) },
        executor: FSExecutor = .shared, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let home = StorageScanner.normalize(home)
        self.home = home
        self.policy = policy
        self.deleter = deleter
        self.screenshotsLocation = screenshotsLocation
        self.options = options
        self.loadVolumes = volumes
        self.executor = executor
        self.now = now
        target = ScanTarget(root: home, name: (home as NSString).lastPathComponent, kind: .home)
        currentPath = home
    }

    // MARK: - Volumes and targets

    /// The home folder first, then one target per mounted volume.
    public var targets: [ScanTarget] {
        [ScanTarget(root: home, name: (home as NSString).lastPathComponent, kind: .home)]
            + volumes.map(ScanTarget.target(for:))
    }

    public func refreshVolumes() async {
        let load = loadVolumes
        volumes = (try? await executor.run { load() }) ?? volumes
    }

    /// Switches the scan target; the previous snapshot is discarded and a running scan is stopped.
    public func select(_ newTarget: ScanTarget) {
        guard newTarget != target else { return }
        cancelScan()
        scanGeneration += 1
        target = newTarget
        snapshot = nil
        isStale = false
        children = []
        selection = []
        currentPath = newTarget.root
        phase = .idle
    }

    // MARK: - Scanning

    /// `true` when the scan was cancelled, so totals are lower bounds.
    public var isPartial: Bool { snapshot?.isComplete == false }

    /// Scans the current target, showing progress; cancelling (or `cancelScan()`) keeps a partial snapshot.
    public func scan() async {
        let root = target.root
        let options = options
        let executor = executor
        let scan = scanFunction
        await runScan { @concurrent progress in try await scan(root, options, executor, progress) }
    }

    /// Updates the snapshot after items moved out of (or into) `changedFolders`, reading only those folders.
    private func rescan(changedFolders: [String]) async {
        guard let snapshot else { return await scan() }
        let options = options
        let executor = executor
        let scan = scanFunction
        await runScan { @concurrent progress in
            try await StorageScanner.rescan(
                snapshot, changedFolders: changedFolders, options: options, executor: executor, scan: scan,
                progress: progress)
        }
    }

    /// Runs `work` as the current scan, showing its progress, and installs the snapshot it returns.
    private func runScan(
        _ work:
            @escaping @Sendable @concurrent (_ progress: @escaping @Sendable (ScanProgress) -> Void) async throws ->
            StorageSnapshot
    ) async {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning(nil)
        let task = Task<StorageSnapshot, any Error> {
            try await work { progress in
                Task { @MainActor in self.report(progress, generation: generation) }
            }
        }
        scanTask = task
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        guard generation == scanGeneration else { return }
        scanTask = nil
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            isStale = false
            currentPath = nearestScannedFolder(to: currentPath, in: snapshot)
            await loadChildren()
            phase = .ready
        case .failure:
            snapshot = nil
            children = []
            phase = .failed
        }
    }

    /// Stops a running scan; the folders read so far are kept and labelled partial.
    public func cancelScan() {
        scanTask?.cancel()
    }

    private func report(_ progress: ScanProgress, generation: Int) {
        guard generation == scanGeneration, case .scanning = phase else { return }
        phase = .scanning(progress)
    }

    private func nearestScannedFolder(to path: String, in snapshot: StorageSnapshot) -> String {
        var candidate = path
        while candidate.hasPrefix(snapshot.root), candidate != snapshot.root {
            if snapshot.directories[candidate] != nil { return candidate }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return snapshot.root
    }

    // MARK: - Browsing

    /// The path bar, from the scanned root to the current folder.
    public var breadcrumbs: [Breadcrumb] {
        let root = target.root
        let rootName = target.kind == .home ? (root as NSString).lastPathComponent : target.name
        var crumbs = [Breadcrumb(name: rootName, path: root)]
        guard currentPath.hasPrefix(root + "/") || (root == "/" && currentPath != "/") else { return crumbs }
        var path = root
        for name in currentPath.dropFirst(root.count).split(separator: "/") {
            path = path == "/" ? "/" + name : path + "/" + name
            crumbs.append(Breadcrumb(name: String(name), path: path))
        }
        return crumbs
    }

    /// Totals of the folder being browsed.
    public var currentAggregate: DirectoryAggregate? { snapshot?.aggregate(at: currentPath) }

    public var canGoUp: Bool { snapshot != nil && currentPath != target.root }

    /// Shows a scanned folder's children; files and unscanned folders are ignored.
    public func open(_ path: String) async {
        let path = StorageScanner.normalize(path)
        guard snapshot?.directories[path] != nil, path != currentPath else { return }
        currentPath = path
        selection = []
        await loadChildren()
    }

    /// Goes to the parent folder (stops at the scanned root).
    public func goUp() async {
        guard canGoUp else { return }
        await open((currentPath as NSString).deletingLastPathComponent)
    }

    private func loadChildren() async {
        guard let snapshot, let aggregate = snapshot.directories[currentPath] else {
            children = []
            return
        }
        let path = currentPath
        let entries = (try? await executor.run { try OpenDirectory(path: path).entries() }) ?? []
        guard path == currentPath, self.snapshot?.root == snapshot.root else { return }

        var items: [StorageItem] = []
        for name in aggregate.childDirectoryNames {
            let childPath = Self.join(path, name)
            guard let child = snapshot.directories[childPath] else { continue }
            items.append(
                StorageItem(
                    path: childPath, name: name, kind: .directory, allocatedSize: child.allocated,
                    reclaimableSize: child.reclaimable, logicalSize: child.logical, fileCount: child.fileCount,
                    folderCount: child.directoryCount, modificationDate: child.latestModification,
                    protection: policy.protection(for: childPath), ruleRoot: snapshot.root,
                    snapshot: FileSnapshot(
                        identity: child.identity, kind: .directory, logicalSize: nil, modificationDate: nil)))
        }
        for entry in entries where entry.kind != .directory {
            items.append(fileItem(entry, in: path, ruleRoot: snapshot.root))
        }
        children = Self.sorted(items)
        pruneSelection()
    }

    private func fileItem(_ entry: FileEntry, in folder: String, ruleRoot: String) -> StorageItem {
        let path = Self.join(folder, entry.name)
        return StorageItem(
            path: path, name: entry.name, kind: entry.kind, allocatedSize: entry.size.allocated,
            reclaimableSize: entry.linkCount > 1 ? 0 : entry.size.freedIfDeleted,
            logicalSize: entry.size.logical, fileCount: 1, folderCount: 0,
            modificationDate: entry.modificationDate, protection: policy.protection(for: path), ruleRoot: ruleRoot,
            snapshot: FileSnapshot(entry))
    }

    /// Largest first; ties by content size, then name, so the order is stable.
    private static func sorted(_ items: [StorageItem]) -> [StorageItem] {
        items.sorted { lhs, rhs in
            if lhs.allocatedSize != rhs.allocatedSize { return lhs.allocatedSize > rhs.allocatedSize }
            if lhs.logicalSize != rhs.logicalSize { return lhs.logicalSize > rhs.logicalSize }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private nonisolated static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    // MARK: - Large & Old

    /// Large files of the last scan that match the size and age filters, largest first.
    public var largeFiles: [StorageItem] {
        guard let snapshot else { return [] }
        let cutoff = largeFileAge.cutoff(now: now())
        return snapshot.largeFiles
            .filter { [largeFileMinimum] in $0.size.allocated >= largeFileMinimum }
            .filter { file in cutoff.map { file.modificationDate < $0 } ?? true }
            .map { file in
                StorageItem(
                    path: file.path, name: (file.path as NSString).lastPathComponent, kind: .file,
                    allocatedSize: file.size.allocated,
                    reclaimableSize: file.linkCount > 1 ? 0 : file.size.freedIfDeleted,
                    logicalSize: file.size.logical, fileCount: 1, folderCount: 0,
                    modificationDate: file.modificationDate, protection: policy.protection(for: file.path),
                    ruleRoot: snapshot.root,
                    snapshot: FileSnapshot(
                        identity: file.identity, kind: .file, logicalSize: file.size.logical,
                        modificationDate: file.modificationDate))
            }
    }

    // MARK: - Downloads & Screenshots

    /// The folder screenshots are saved to: the configured location (with `~` expanded) or the Desktop.
    public nonisolated static func screenshotsFolder(configured: String?, home: String) -> String {
        let fallback = join(home, "Desktop")
        guard let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty
        else { return fallback }
        var path = configured
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = join(home, String(path.dropFirst(2)))
        }
        guard path.hasPrefix("/") else { return fallback }
        return StorageScanner.normalize(path)
    }

    /// Reads ~/Downloads (files only, source `.downloads`) and the screenshots folder (system-named screenshots and
    /// recordings only, source `.screenshots`). A file in Downloads is always `.downloads` and is listed once.
    public func loadClutter() async {
        isLoadingClutter = true
        defer {
            isLoadingClutter = false
            hasLoadedClutter = true
        }
        let downloads = Self.join(home, "Downloads")
        let shots = Self.screenshotsFolder(configured: screenshotsLocation, home: home)
        let read = try? await executor.run {
            let entries = ((try? OpenDirectory(path: downloads).entries()) ?? []).filter { $0.kind == .file }
            var hosts: [String: String] = [:]
            for entry in entries {
                hosts[entry.name] = DownloadSource.host(atPath: Self.join(downloads, entry.name))
            }
            let canonical = Self.canonical(shots)
            let shotEntries = canonical.flatMap { try? OpenDirectory(path: $0).entries() } ?? []
            return ClutterRead(
                downloads: entries, downloadHosts: hosts, screenshotsFolder: canonical, screenshots: shotEntries)
        }
        let downloadEntries = read?.downloads ?? []
        let downloadHosts = read?.downloadHosts ?? [:]
        let shotsFolder = read?.screenshotsFolder
        let shotEntries = read?.screenshots ?? []
        let date = now()
        var items: [String: ClutterItem] = [:]
        // Hidden files (.localized, .DS_Store) belong to macOS and Finder, not to the person's downloads.
        for entry in downloadEntries where !entry.name.hasPrefix(".") {
            let item = fileItem(entry, in: downloads, ruleRoot: downloads)
            items[item.path] = ClutterItem(
                item: item, kind: ClutterKind.classify(name: entry.name), age: .of(entry.modificationDate, now: date),
                source: .downloads, sourceHost: downloadHosts[entry.name])
        }
        // A screenshot saved into Downloads is a download: the Downloads tab lists it, the Other tab does not.
        if let shotsFolder, shotsFolder != downloads {
            for entry in shotEntries where entry.kind == .file {
                guard let kind = ClutterKind.screenshotKind(forName: entry.name) else { continue }
                let item = fileItem(entry, in: shotsFolder, ruleRoot: shotsFolder)
                if items[item.path] != nil { continue }
                items[item.path] = ClutterItem(
                    item: item, kind: kind, age: .of(entry.modificationDate, now: date), source: .screenshots,
                    sourceHost: nil)
            }
        }
        screenshotsPath = shotsFolder
        clutter = items.values.sorted { lhs, rhs in
            lhs.item.allocatedSize != rhs.item.allocatedSize
                ? lhs.item.allocatedSize > rhs.item.allocatedSize : lhs.item.path < rhs.item.path
        }
        pruneSelection()
    }

    /// Downloads & Screenshots grouped by kind or by age (fixed order) or by website (largest first, unknown last);
    /// empty groups are left out.
    public func clutterGroups(by grouping: ClutterGrouping, filter: ClutterFilter = ClutterFilter()) -> [ClutterGroup] {
        let clutter = self.clutter.filter(filter.matches)
        switch grouping {
        case .kind:
            return ClutterKind.allCases.compactMap { kind in
                let items = clutter.filter { $0.kind == kind }
                return items.isEmpty ? nil : ClutterGroup(key: .kind(kind), items: items)
            }
        case .age:
            return ClutterAge.allCases.compactMap { age in
                let items = clutter.filter { $0.age == age }
                return items.isEmpty ? nil : ClutterGroup(key: .age(age), items: items)
            }
        case .sourceHost:
            return Self.groupedBySourceHost(clutter)
        }
    }

    /// One group per website, largest total first (ties by host name), then the files of unknown origin.
    private static func groupedBySourceHost(_ items: [ClutterItem]) -> [ClutterGroup] {
        var byHost: [String: [ClutterItem]] = [:]
        var unknown: [ClutterItem] = []
        for item in items {
            if let host = item.sourceHost {
                byHost[host, default: []].append(item)
            } else {
                unknown.append(item)
            }
        }
        var groups = byHost.map { ClutterGroup(key: .sourceHost($0.key), items: $0.value) }
            .sorted { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.hostName < rhs.hostName
            }
        if !unknown.isEmpty { groups.append(ClutterGroup(key: .sourceHost(nil), items: unknown)) }
        return groups
    }

    private nonisolated static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Selection

    /// Items of the visible list, by path.
    private var visibleItems: [String: StorageItem] {
        let items: [StorageItem] =
            switch list {
            case .browser: children
            case .largeFiles: largeFiles
            case .clutter: clutter.filter { clutterSource == nil || $0.source == clutterSource }.map(\.item)
            }
        return Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Replaces the selection; protected items and items not in the visible list are dropped.
    public func setSelection(_ paths: Set<String>) {
        let visible = visibleItems
        selection = paths.filter { visible[$0]?.isSelectable == true }
    }

    /// Checks or unchecks one item for Move to Trash; protected items and items not shown cannot be checked.
    public func toggleChecked(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else {
            setSelection(selection.union([path]))
        }
    }

    public var selectedCount: Int { selection.count }

    /// Estimated bytes the selection frees.
    public var selectedBytes: Int64 {
        let visible = visibleItems
        return selection.reduce(0) { $0 + (visible[$1]?.reclaimableSize ?? 0) }
    }

    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        setSelection(selection)
    }

    // MARK: - Deleting

    /// The folders an item left and the Trash folders it arrived in; only moved items changed anything.
    private nonisolated static func changedFolders(after results: [DeletionResult]) -> [String] {
        results.flatMap { result -> [String] in
            guard case .movedToTrash(let trashPath) = result.outcome else { return [] }
            return [StorageScanner.parent(of: result.item.path), StorageScanner.parent(of: trashPath)]
        }
    }

    /// Moves the selection to the Trash through the deletion gate, then rescans only the folders that changed.
    @discardableResult
    public func moveSelectionToTrash() async -> CleanupSummary {
        let visible = visibleItems
        let items = selection.sorted().compactMap { visible[$0]?.deletionItem() }
        let previousPhase = phase
        phase = .deleting
        let results = await deleter.run(items, mode: .moveToTrash)

        let summary = CleanupSummary(results: results)
        lastSummary = summary
        selection = []

        if !clutter.isEmpty || list == .clutter { await loadClutter() }
        if snapshot != nil, summary.movedToTrashCount > 0 {
            isStale = true
            await rescan(changedFolders: Self.changedFolders(after: results))
        } else {
            phase = previousPhase
        }
        // Free space and the disk bars reflect the cleanup (space in the Trash is freed once it is emptied).
        await refreshVolumes()
        return summary
    }
}

/// What `loadClutter` read on the executor.
private struct ClutterRead: Sendable {
    /// Regular files only.
    let downloads: [FileEntry]
    /// Website of each download, by file name; read only for the files listed.
    let downloadHosts: [String: String]
    let screenshotsFolder: String?
    let screenshots: [FileEntry]
}

extension ClutterGroup {
    /// Sort key of a website group.
    fileprivate var hostName: String {
        if case .sourceHost(let host) = key { return host ?? "" }
        return ""
    }
}
