import Darwin
import Foundation
public import Observation

/// The find-review-remove workflow for similar photos (Storage → Similar Photos).
///
/// Similar is not identical, so nothing is marked by a scan: the user opts in per image, per group (`keepOnly`) or
/// for all groups (`markAllButSuggested`). The keep-one rule lives here, not in the UI: no call can leave every image
/// of a group marked, and the deletion plan re-checks it per group (and that a kept image is still on disk)
/// immediately before moving anything to the Trash.
@MainActor
@Observable
public final class SimilarPhotosSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case scanning(SimilarPhotoScanProgress)
        case ready
        case removing
    }

    /// Folders searched by default, relative to the home folder, when they exist. The Photos library is never searched.
    public static let defaultFolderNames = ["Pictures", "Desktop", "Downloads", "Documents"]

    public private(set) var phase = Phase.idle
    /// Folders the next scan searches.
    public private(set) var roots: [String] = []
    /// How alike two images must be; lower is stricter. Applies to the next scan.
    public var distanceThreshold = SimilarPhotoFinder.defaultDistanceThreshold
    /// Canonical folders the current results came from; removals are confined to them.
    public private(set) var scannedRoots: [String] = []
    /// Groups, largest reclaimable space first; each shrinks as images are moved to the Trash.
    public private(set) var groups: [SimilarPhotoGroup] = []
    /// Paths marked to be moved to the Trash. Never contains every image of a group.
    public internal(set) var marked: Set<String> = []
    /// `false` when the last scan was cancelled, so there are no results.
    public private(set) var lastScanWasComplete = true
    /// Folders and images the last scan left out, each with its reason.
    public private(set) var skipped: [String: SimilarPhotoSkipReason] = [:]
    public private(set) var lastSummary: CleanupSummary?

    private let home: String
    private let policy: ProtectionPolicy
    private let deleter: DeletionExecutor
    private let executor: FSExecutor
    private var didLoadDefaults = false
    private var scanTask: Task<ScanOutcome, Never>?
    private var scanGeneration = 0

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

    /// Finds similar photos in `roots`. A newer scan or `cancelScan()` stops this one; a cancelled scan has no groups.
    public func scan() async {
        guard phase != .removing else { return }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning(SimilarPhotoScanProgress(phase: .listing, filesSeen: 0, imagesFound: 0, imagesAnalyzed: 0))
        groups = []
        marked = []

        let (updates, continuation) = AsyncStream.makeStream(
            of: SimilarPhotoScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let requested = roots
        let options = SimilarPhotoScanOptions(distanceThreshold: distanceThreshold)
        let policy = policy
        let executor = executor
        let task = Task<ScanOutcome, Never> {
            defer { continuation.finish() }
            let canonical = (try? await executor.run { Self.canonicalRoots(requested) }) ?? []
            guard !canonical.isEmpty else {
                let result = SimilarPhotoScanResult(groups: [], skipped: [:], isComplete: !Task.isCancelled)
                return ScanOutcome(roots: [], result: result)
            }
            let result = await SimilarPhotoFinder.scan(
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
        skipped = outcome.result.skipped
        groups = outcome.result.groups
        marked = []
        phase = .ready
    }

    /// Stops a running scan.
    public func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: - Marking

    public func isMarked(_ path: String) -> Bool { marked.contains(path) }

    /// Number of images marked for the Trash.
    public var markedCount: Int { marked.count }

    /// Estimated bytes freed by the marked images (clone- and hard-link-aware).
    public var markedBytes: Int64 {
        groups.reduce(0) { $0 + markedBytes(in: $1) }
    }

    public func markedBytes(in group: SimilarPhotoGroup) -> Int64 {
        group.photos.reduce(0) { $0 + (marked.contains($1.path) ? $1.reclaimable : 0) }
    }

    /// Whether `path` can be marked now without leaving its group with no kept image.
    public func canMark(_ path: String) -> Bool {
        guard phase == .ready, let group = group(containing: path) else { return false }
        if marked.contains(path) { return true }
        return group.photos.contains { $0.path != path && !marked.contains($0.path) }
    }

    /// Marks or unmarks one image. Returns `false` (and changes nothing) when marking would remove every image.
    @discardableResult
    public func setMarked(_ isMarked: Bool, path: String) -> Bool {
        guard phase == .ready, group(containing: path) != nil else { return false }
        if isMarked {
            guard canMark(path) else { return false }
            marked.insert(path)
        } else {
            marked.remove(path)
        }
        return true
    }

    /// Keeps exactly this image and marks the other images of its group.
    @discardableResult
    public func keepOnly(_ path: String) -> Bool {
        guard phase == .ready, let group = group(containing: path) else { return false }
        for photo in group.photos {
            if photo.path == path { marked.remove(photo.path) } else { marked.insert(photo.path) }
        }
        return true
    }

    /// The user's explicit opt-in: in every group, marks every image except the suggested keeper.
    public func markAllButSuggested() {
        guard phase == .ready else { return }
        for group in groups {
            for photo in group.photos {
                if photo.path == group.suggestedKeeper { marked.remove(photo.path) } else { marked.insert(photo.path) }
            }
        }
    }

    /// Keeps every image.
    public func unmarkAll() {
        guard phase == .ready else { return }
        marked = []
    }

    /// Removes marks for images not shown, and unmarks the suggested keeper of any group with every image marked.
    private func enforceKeepRule() {
        let shown = Set(groups.flatMap { $0.photos.map(\.path) })
        marked.formIntersection(shown)
        for group in groups where group.photos.allSatisfy({ marked.contains($0.path) }) {
            marked.remove(group.suggestedKeeper)
        }
    }

    private func group(containing path: String) -> SimilarPhotoGroup? {
        groups.first { $0.photos.contains { $0.path == path } }
    }

    // MARK: - Removing

    /// One group's part of a removal: the images to move and the images that must still be there afterwards.
    struct PlannedGroup: Sendable {
        let items: [DeletionItem]
        let kept: [SimilarPhoto]
    }

    /// Builds the removal, re-checking the keep-one rule per group: a group whose images would all go is left out.
    func deletionPlan() -> [PlannedGroup] {
        groups.compactMap { group in
            let removing = group.photos.filter { marked.contains($0.path) }
            let kept = group.photos.filter { !marked.contains($0.path) }
            guard !removing.isEmpty, !kept.isEmpty else { return nil }
            let items = removing.compactMap { photo -> DeletionItem? in
                guard let root = root(containing: photo.path) else { return nil }
                return DeletionItem(
                    path: photo.path, ruleRoot: root, expected: photo.snapshot, ownerBundleID: nil,
                    freedBytes: photo.reclaimable, section: .storage)
            }
            return items.isEmpty ? nil : PlannedGroup(items: items, kept: kept)
        }
    }

    /// Moves the marked images to the Trash, then drops them (and groups left with one image) from the results.
    @discardableResult
    public func moveMarkedToTrash() async -> CleanupSummary {
        guard phase == .ready else { return CleanupSummary() }
        let plan = deletionPlan()
        phase = .removing

        // Keep-one on disk: a group is only touched while one of its kept images is still exactly as reviewed.
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
        // Images that are no longer where they were (moved, or already gone) leave their groups.
        let gone = Set(
            results.filter { $0.outcome.isMovedToTrash || $0.outcome == .skipped(.notFound) }.map(\.item.path))

        groups = groups.compactMap { group in
            let photos = group.photos.filter { !gone.contains($0.path) }
            guard photos.count >= 2 else { return nil }
            let keeper =
                photos.contains { $0.path == group.suggestedKeeper }
                ? group.suggestedKeeper : (SimilarPhotoFinder.suggestedKeeper(among: photos)?.path ?? photos[0].path)
            let ordered = photos.filter { $0.path == keeper } + photos.filter { $0.path != keeper }
            return SimilarPhotoGroup(id: group.id, photos: ordered, suggestedKeeper: keeper)
        }
        .sorted { ($0.reclaimableIfOthersRemoved, $1.id) > ($1.reclaimableIfOthersRemoved, $0.id) }
        enforceKeepRule()
        lastSummary = summary
        phase = .ready
        return summary
    }

    // MARK: - Helpers

    private struct ScanOutcome: Sendable {
        let roots: [String]
        let result: SimilarPhotoScanResult
    }

    /// The most specific scanned root that strictly contains `path`.
    private func root(containing path: String) -> String? {
        scannedRoots.filter { Self.isInside(path, folder: $0) }.max { $0.count < $1.count }
    }

    nonisolated private static func isInside(_ path: String, folder: String) -> Bool {
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

    nonisolated private static func isUnchanged(_ photo: SimilarPhoto) -> Bool {
        guard let resolved = try? SafeWalk.resolve(photo.path) else { return false }
        return resolved.snapshot == photo.snapshot
    }
}
