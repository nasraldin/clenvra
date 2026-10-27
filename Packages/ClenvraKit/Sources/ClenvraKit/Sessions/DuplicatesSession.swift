import Darwin
import Foundation
public import Observation

/// The find-review-remove workflow for duplicate files (Storage → Duplicates).
///
/// Safety rule S26 lives here, not in the UI: no call can leave every copy of a group marked for removal, and the
/// deletion plan re-checks it per group (and that a kept copy is still on disk) immediately before deleting.
@MainActor
@Observable
public final class DuplicatesSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case scanning(DuplicateScanProgress)
        case ready
        case removing
    }

    /// A set of identical files as currently shown; shrinks as copies are moved to the Trash.
    public struct Group: Sendable, Equatable, Identifiable {
        public let id: String
        /// Logical size of one copy.
        public let size: Int64
        /// At least two copies; the suggested keeper comes first.
        public let files: [DuplicateFile]
        /// The copy kept by default (the oldest).
        public let suggestedKeeper: String

        /// Space freed by keeping only the suggested copy: clones and hard links add nothing.
        public var reclaimableIfOthersRemoved: Int64 {
            files.reduce(0) { $0 + ($1.path == suggestedKeeper ? 0 : $1.reclaimable) }
        }

        /// True when removing the extra copies frees almost nothing because they share storage (APFS clones).
        public var sharesStorage: Bool { reclaimableIfOthersRemoved * 20 < size }

        init(id: String, size: Int64, files: [DuplicateFile], suggestedKeeper: String) {
            self.id = id
            self.size = size
            self.files = files
            self.suggestedKeeper = suggestedKeeper
        }

        init(_ group: DuplicateGroup) {
            self.init(id: group.id, size: group.size, files: group.files, suggestedKeeper: group.suggestedKeeper)
        }
    }

    /// Minimum-size choices offered in the UI (decimal units, as Finder shows them).
    public static let minimumSizeChoices: [Int64] = [100_000, 1_000_000, 10_000_000, 100_000_000]
    /// Folders searched by default, relative to the home folder, when they exist.
    public static let defaultFolderNames = ["Documents", "Downloads", "Desktop", "Pictures", "Movies", "Music"]

    public private(set) var phase = Phase.idle
    /// Folders the next scan searches.
    public private(set) var roots: [String] = []
    /// Ignore files smaller than this.
    public var minimumSize: Int64 = 1_000_000
    /// Canonical folders the current results came from; deletions are confined to them.
    public private(set) var scannedRoots: [String] = []
    /// Groups, largest reclaimable space first.
    public private(set) var groups: [Group] = []
    /// Paths marked to be moved to the Trash. Never contains every copy of a group.
    public internal(set) var marked: Set<String> = []
    /// `false` when the last scan was cancelled, so the results may be incomplete.
    public private(set) var lastScanWasComplete = true
    /// Number of files the last scan could not read.
    public private(set) var unreadableCount = 0
    public private(set) var lastSummary: CleanupSummary?

    private let home: String
    private let policy: ProtectionPolicy
    private let deleter: DeletionExecutor
    private let executor: FSExecutor
    private var didLoadDefaults = false
    private var scanTask: Task<ScanOutcome, Never>?
    private var scanGeneration = 0
    /// Every mark decision ever shown, so a rescan keeps the user's choices for files it finds again.
    private var rememberedMarks: [String: Bool] = [:]

    public init(home: String, policy: ProtectionPolicy, deleter: DeletionExecutor, executor: FSExecutor = .shared) {
        self.home = home
        self.policy = policy
        self.deleter = deleter
        self.executor = executor
    }

    // MARK: - Folders

    /// Fills `roots` with the default folders that exist, once; does nothing if the user already chose folders.
    public func loadDefaultRoots() async {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        let candidates = Self.defaultFolderNames.map { (home.hasSuffix("/") ? home : home + "/") + $0 }
        let existing = (try? await executor.run { candidates.filter(Self.isDirectory) }) ?? []
        if roots.isEmpty { roots = existing }
    }

    public func addRoot(_ path: String) {
        didLoadDefaults = true
        let path = Self.trimmed(path)
        guard !roots.contains(path) else { return }
        roots.append(path)
    }

    public func removeRoot(_ path: String) {
        didLoadDefaults = true
        roots.removeAll { $0 == path }
    }

    // MARK: - Scanning

    /// Finds duplicates in `roots`. A newer scan or `cancelScan()` stops this one; cancelled scans keep what was
    /// fully verified.
    public func scan() async {
        guard phase != .removing else { return }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning(DuplicateScanProgress(phase: .listing, filesSeen: 0, candidateFiles: 0, bytesHashed: 0))
        groups = []
        marked = []

        let (updates, continuation) = AsyncStream.makeStream(
            of: DuplicateScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let requested = roots
        let options = DuplicateScanOptions(minimumSize: minimumSize)
        let policy = policy
        let executor = executor
        let task = Task<ScanOutcome, Never> {
            defer { continuation.finish() }
            let canonical = (try? await executor.run { Self.canonicalRoots(requested) }) ?? []
            guard !canonical.isEmpty else {
                let result = DuplicateScanResult(groups: [], skipped: [:], isComplete: !Task.isCancelled)
                return ScanOutcome(roots: [], result: result)
            }
            let result = await DuplicateFinder.scan(
                roots: canonical, options: options, policy: policy, executor: executor,
                progress: { continuation.yield($0) })
            return ScanOutcome(roots: canonical, result: result)
        }
        scanTask = task

        await withTaskCancellationHandler {
            for await update in updates where generation == scanGeneration {
                phase = .scanning(update)
            }
        } onCancel: {
            task.cancel()
        }
        let outcome = await task.value
        guard generation == scanGeneration else { return }
        scanTask = nil
        scannedRoots = outcome.roots
        lastScanWasComplete = outcome.result.isComplete
        unreadableCount = outcome.result.skipped.count
        apply(outcome.result.groups.map(Group.init))
        phase = .ready
    }

    /// Stops a running scan; groups verified so far are kept.
    public func cancelScan() {
        scanTask?.cancel()
    }

    /// Replaces the groups, keeping earlier choices for files seen before and enforcing S26.
    private func apply(_ newGroups: [Group]) {
        groups = newGroups.sorted {
            ($0.reclaimableIfOthersRemoved, $0.size, $1.id) > ($1.reclaimableIfOthersRemoved, $1.size, $0.id)
        }
        var updated = Set<String>()
        for group in groups {
            for file in group.files {
                let isMarked = rememberedMarks[file.path] ?? (file.path != group.suggestedKeeper)
                if isMarked { updated.insert(file.path) }
            }
        }
        marked = updated
        enforceKeepRule()
    }

    // MARK: - Marking

    public func isMarked(_ path: String) -> Bool { marked.contains(path) }

    /// Number of copies marked for the Trash.
    public var markedCount: Int { marked.count }

    /// Estimated bytes freed by the marked copies (clone- and hard-link-aware).
    public var markedBytes: Int64 {
        groups.reduce(0) { $0 + markedBytes(in: $1) }
    }

    public func markedBytes(in group: Group) -> Int64 {
        group.files.reduce(0) { $0 + (marked.contains($1.path) ? $1.reclaimable : 0) }
    }

    /// Whether `path` can be marked now without leaving its group with no kept copy.
    public func canMark(_ path: String) -> Bool {
        guard phase == .ready, let group = group(containing: path) else { return false }
        if marked.contains(path) { return true }
        return group.files.contains { $0.path != path && !marked.contains($0.path) }
    }

    /// Marks or unmarks one copy. Returns `false` (and changes nothing) when marking would remove every copy.
    @discardableResult
    public func setMarked(_ isMarked: Bool, path: String) -> Bool {
        guard phase == .ready, group(containing: path) != nil else { return false }
        if isMarked {
            guard canMark(path) else { return false }
            marked.insert(path)
        } else {
            marked.remove(path)
        }
        remember()
        return true
    }

    /// Keeps exactly this copy and marks the other copies of its group.
    @discardableResult
    public func keepOnly(_ path: String) -> Bool {
        guard phase == .ready, let group = group(containing: path) else { return false }
        keep([path], in: group)
        remember()
        return true
    }

    /// In every group, keeps the most recently modified copy.
    public func keepNewest() {
        bulkKeep { group in
            group.files.max { $0.modificationDate < $1.modificationDate }.map { [$0.path] } ?? []
        }
    }

    /// In every group, keeps the least recently modified copy.
    public func keepOldest() {
        bulkKeep { group in
            group.files.min { $0.modificationDate < $1.modificationDate }.map { [$0.path] } ?? []
        }
    }

    /// In groups with copies inside `folder`, keeps those copies and marks the rest; other groups are unchanged.
    public func keepCopies(inFolder folder: String) {
        let folder = Self.trimmed(folder)
        bulkKeep { group in
            group.files.map(\.path).filter { Self.isInside($0, folder: folder) }
        }
    }

    /// Keeps every copy.
    public func unmarkAll() {
        guard phase == .ready else { return }
        marked = []
        remember()
    }

    private func bulkKeep(_ choose: (Group) -> [String]) {
        guard phase == .ready else { return }
        for group in groups {
            let kept = choose(group)
            if !kept.isEmpty { keep(kept, in: group) }
        }
        remember()
    }

    /// Marks every copy of `group` except `kept` (which must belong to the group and not be empty).
    private func keep(_ kept: [String], in group: Group) {
        let paths = group.files.map(\.path)
        let kept = Set(kept).intersection(paths)
        guard !kept.isEmpty else { return }
        for path in paths {
            if kept.contains(path) { marked.remove(path) } else { marked.insert(path) }
        }
    }

    /// Removes marks for files not shown, and unmarks the suggested keeper of any group with every copy marked.
    private func enforceKeepRule() {
        let shown = Set(groups.flatMap { $0.files.map(\.path) })
        marked.formIntersection(shown)
        for group in groups where group.files.allSatisfy({ marked.contains($0.path) }) {
            marked.remove(group.suggestedKeeper)
            if group.files.allSatisfy({ marked.contains($0.path) }), let first = group.files.first {
                marked.remove(first.path)
            }
        }
        remember()
    }

    private func remember() {
        for group in groups {
            for file in group.files { rememberedMarks[file.path] = marked.contains(file.path) }
        }
    }

    private func group(containing path: String) -> Group? {
        groups.first { $0.files.contains { $0.path == path } }
    }

    // MARK: - Removing

    /// One group's part of a removal: the copies to move and the copies that must still be there afterwards.
    struct PlannedGroup: Sendable {
        let items: [DeletionItem]
        let kept: [DuplicateFile]
    }

    /// Builds the removal, re-checking S26 per group: a group whose copies would all go is left out entirely.
    func deletionPlan() -> [PlannedGroup] {
        groups.compactMap { group in
            let removing = group.files.filter { marked.contains($0.path) }
            let kept = group.files.filter { !marked.contains($0.path) }
            guard !removing.isEmpty, !kept.isEmpty, removing.count + kept.count == group.files.count else {
                return nil
            }
            let items = removing.compactMap { file -> DeletionItem? in
                guard let root = root(containing: file.path) else { return nil }
                return DeletionItem(
                    path: file.path, ruleRoot: root, expected: file.snapshot, ownerBundleID: nil,
                    freedBytes: file.reclaimable, section: .storage)
            }
            return items.isEmpty ? nil : PlannedGroup(items: items, kept: kept)
        }
    }

    /// Moves the marked copies to the Trash, then drops them (and groups left with one copy) from the results.
    @discardableResult
    public func moveMarkedToTrash() async -> CleanupSummary {
        guard phase == .ready else { return CleanupSummary() }
        let plan = deletionPlan()
        phase = .removing

        // S26 on disk: a group is only touched while one of its kept copies is still exactly as reviewed.
        let keptChecks = plan.map(\.kept)
        let keptPresent =
            (try? await executor.run { keptChecks.map { $0.contains(where: Self.isUnchanged) } })
            ?? Array(repeating: false, count: plan.count)
        var summary = CleanupSummary()
        var items: [DeletionItem] = []
        for (planned, present) in zip(plan, keptPresent) {
            if present {
                items += planned.items
            } else {
                summary.problems += planned.items.map { .init(path: $0.path, reason: .skipped(.changedSinceScan)) }
            }
        }

        let results = await deleter.run(items, mode: .moveToTrash)
        summary.add(results)
        // Files that are no longer where they were (moved, or already gone) leave their groups.
        let gone = Set(
            results.filter { $0.outcome.isMovedToTrash || $0.outcome == .skipped(.notFound) }.map(\.item.path))

        groups = groups.compactMap { group in
            let files = group.files.filter { !gone.contains($0.path) }
            guard files.count >= 2 else { return nil }
            let keeper = files.contains { $0.path == group.suggestedKeeper } ? group.suggestedKeeper : files[0].path
            return Group(id: group.id, size: group.size, files: files, suggestedKeeper: keeper)
        }
        .sorted {
            ($0.reclaimableIfOthersRemoved, $0.size, $1.id) > ($1.reclaimableIfOthersRemoved, $1.size, $0.id)
        }
        for path in gone { rememberedMarks.removeValue(forKey: path) }
        enforceKeepRule()
        lastSummary = summary
        phase = .ready
        return summary
    }

    // MARK: - Helpers

    private struct ScanOutcome: Sendable {
        let roots: [String]
        let result: DuplicateScanResult
    }

    /// The most specific scanned root that strictly contains `path`.
    private func root(containing path: String) -> String? {
        scannedRoots.filter { Self.isInside(path, folder: $0) }.max { $0.count < $1.count }
    }

    nonisolated static func isInside(_ path: String, folder: String) -> Bool {
        (try? PathPolicy.isStrictlyInside(path, root: folder)) ?? false
    }

    nonisolated private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    nonisolated private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Existing folders resolved with `realpath(3)`, without duplicates, in the requested order.
    nonisolated private static func canonicalRoots(_ paths: [String]) -> [String] {
        var result: [String] = []
        for path in paths {
            guard let resolved = realpath(path, nil) else { continue }
            let canonical = String(cString: resolved)
            free(resolved)
            if isDirectory(canonical), !result.contains(canonical) { result.append(canonical) }
        }
        return result
    }

    nonisolated private static func isUnchanged(_ file: DuplicateFile) -> Bool {
        guard let resolved = try? SafeWalk.resolve(file.path) else { return false }
        return resolved.snapshot == file.snapshot
    }
}
