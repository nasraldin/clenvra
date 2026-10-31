import Darwin
import Foundation
public import Observation

/// The find-review-remove workflow for similar photos (Storage → Similar Photos).
///
/// Every group has a keeper (the suggested one until the person picks another with `setKeeper`), which is never
/// marked. A scan pre-selects the suggestion (`selectSuggested`): every image except each group's keeper, and every
/// blurry or dark photo (`lowQualityPhotos`) that is not a keeper. The person can clear it (`clearSelection`) and
/// opt in again. Changing a group's keeper marks the group's other images. The keep-one rule lives here, not in the
/// UI: no call can mark a keeper or leave every image of a group marked, and the deletion plan re-checks it per group
/// (and that a kept image is still on disk) immediately before moving anything to the Trash.
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
    /// Photos rated blurry or dark, lowest score first. Pre-selected unless one is its group's keeper; one that is
    /// also in a group follows that group's keep-one rule.
    public private(set) var lowQualityPhotos: [SimilarPhoto] = []
    /// Paths marked to be moved to the Trash. Never contains a keeper or every image of a group.
    public internal(set) var marked: Set<String> = []
    /// Keepers the person chose, by group id; a group not listed keeps its suggested keeper.
    private var chosenKeepers: [String: String] = [:]
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
        lowQualityPhotos = []
        marked = []
        chosenKeepers = [:]

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
        apply(outcome.result, roots: outcome.roots)
    }

    /// Shows a scan's results from canonical `roots`, with the suggested keepers and everything else selected.
    func apply(_ result: SimilarPhotoScanResult, roots: [String]) {
        scannedRoots = roots
        lastScanWasComplete = result.isComplete
        skipped = result.skipped
        groups = result.groups
        lowQualityPhotos = result.lowQuality
        marked = []
        chosenKeepers = [:]
        phase = .ready
        selectSuggested()
    }

    /// Stops a running scan.
    public func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: - Marking

    public func isMarked(_ path: String) -> Bool { marked.contains(path) }

    /// Number of images marked for the Trash.
    public var markedCount: Int { marked.count }

    /// Estimated bytes freed by the marked images (clone- and hard-link-aware). A photo that is both in a group and
    /// rated low counts once.
    public var markedBytes: Int64 {
        groups.reduce(0) { $0 + markedBytes(in: $1) } + markedLowQualityBytes
    }

    public func markedBytes(in group: SimilarPhotoGroup) -> Int64 {
        group.photos.reduce(0) { $0 + (marked.contains($1.path) ? $1.reclaimable : 0) }
    }

    /// Estimated bytes freed by the marked blurry or dark photos, including those that are also in a group.
    public var markedBytesInLowQuality: Int64 {
        lowQualityPhotos.reduce(0) { $0 + (marked.contains($1.path) ? $1.reclaimable : 0) }
    }

    /// Marked low-rated photos that are in no group (those in a group are counted with it).
    private var markedLowQualityBytes: Int64 {
        looseLowQualityPhotos.reduce(0) { $0 + (marked.contains($1.path) ? $1.reclaimable : 0) }
    }

    /// Whether `path` can be marked now: a photo in a group only when it is not the group's keeper and another image
    /// of its group stays kept; a blurry or dark photo in no group always.
    public func canMark(_ path: String) -> Bool {
        guard phase == .ready else { return false }
        guard let group = group(containing: path) else { return isLowQuality(path) }
        if marked.contains(path) { return true }
        guard path != keeper(of: group) else { return false }
        return group.photos.contains { $0.path != path && !marked.contains($0.path) }
    }

    // MARK: - Keepers

    /// The image `group` keeps: the one the person chose, else the suggested keeper.
    public func keeper(of group: SimilarPhotoGroup) -> String {
        if let chosen = chosenKeepers[group.id], group.photos.contains(where: { $0.path == chosen }) { return chosen }
        return group.suggestedKeeper
    }

    /// Whether `path` is the keeper of the group it is in.
    public func isKeeper(_ path: String) -> Bool {
        guard let group = group(containing: path) else { return false }
        return keeper(of: group) == path
    }

    /// The group's images, its keeper first, the rest in the group's order.
    public func photosKeeperFirst(in group: SimilarPhotoGroup) -> [SimilarPhoto] {
        let keeper = keeper(of: group)
        return group.photos.filter { $0.path == keeper } + group.photos.filter { $0.path != keeper }
    }

    /// The keeper to compare `path` with: its group's keeper photo, or `nil` for a photo in no group.
    public func keeperPhoto(comparedWith path: String) -> SimilarPhoto? {
        guard let group = group(containing: path) else { return nil }
        let keeper = keeper(of: group)
        return group.photos.first { $0.path == keeper }
    }

    /// Makes `path` its group's keeper and selects every other image of the group. Returns `false` (and changes
    /// nothing) for a photo in no group, or while not ready.
    @discardableResult
    public func setKeeper(_ path: String) -> Bool {
        guard phase == .ready, let group = group(containing: path) else { return false }
        chosenKeepers[group.id] = path
        for photo in group.photos {
            if photo.path == path { marked.remove(photo.path) } else { marked.insert(photo.path) }
        }
        return true
    }

    /// Marks or unmarks one image. Returns `false` (and changes nothing) when marking would remove every image.
    @discardableResult
    public func setMarked(_ isMarked: Bool, path: String) -> Bool {
        guard phase == .ready, group(containing: path) != nil || isLowQuality(path) else { return false }
        if isMarked {
            guard canMark(path) else { return false }
            marked.insert(path)
        } else {
            marked.remove(path)
        }
        return true
    }

    /// Keeps exactly this image (it becomes the keeper) and marks the other images of its group.
    @discardableResult
    public func keepOnly(_ path: String) -> Bool {
        setKeeper(path)
    }

    /// The suggestion, also applied after every scan: in every group, marks every image except its keeper (the one
    /// the person chose, else the suggested one), and marks every blurry or dark photo that is not a keeper.
    public func selectSuggested() {
        guard phase == .ready else { return }
        var keepers = Set<String>()
        for group in groups {
            let keeper = keeper(of: group)
            keepers.insert(keeper)
            for photo in group.photos {
                if photo.path == keeper { marked.remove(photo.path) } else { marked.insert(photo.path) }
            }
        }
        for photo in lowQualityPhotos where !keepers.contains(photo.path) {
            marked.insert(photo.path)
        }
    }

    /// Keeps every image (Clear Selection). Keepers stay as chosen.
    public func clearSelection() {
        guard phase == .ready else { return }
        marked = []
    }

    /// Same as `clearSelection()`.
    public func unmarkAll() {
        clearSelection()
    }

    /// Removes marks for images not shown, forgets keepers no longer shown, and unmarks every group's keeper.
    private func enforceKeepRule() {
        let shown = Set(groups.flatMap { $0.photos.map(\.path) } + lowQualityPhotos.map(\.path))
        marked.formIntersection(shown)
        let groupIDs = Set(groups.map(\.id))
        chosenKeepers = chosenKeepers.filter { groupIDs.contains($0.key) && shown.contains($0.value) }
        for group in groups {
            marked.remove(keeper(of: group))
        }
    }

    private func group(containing path: String) -> SimilarPhotoGroup? {
        groups.first { $0.photos.contains { $0.path == path } }
    }

    private func isLowQuality(_ path: String) -> Bool {
        lowQualityPhotos.contains { $0.path == path }
    }

    /// Blurry or dark photos that are in no group, so no keep-one rule applies to them.
    private var looseLowQualityPhotos: [SimilarPhoto] {
        let grouped = Set(groups.flatMap { $0.photos.map(\.path) })
        return lowQualityPhotos.filter { !grouped.contains($0.path) }
    }

    // MARK: - Removing

    /// One group's part of a removal: the images to move and the images that must still be there afterwards.
    struct PlannedGroup: Sendable {
        let items: [DeletionItem]
        /// Images of the group that stay, one of which must still be on disk as reviewed; `nil` for blurry or dark
        /// photos in no group, which have no keep-one rule.
        let kept: [SimilarPhoto]?
    }

    /// Builds the removal, re-checking the keep-one rule per group: a group whose images would all go is left out.
    /// Marked blurry or dark photos in no group follow as one last part.
    func deletionPlan() -> [PlannedGroup] {
        var plan: [PlannedGroup] = groups.compactMap { group in
            let removing = group.photos.filter { marked.contains($0.path) }
            let kept = group.photos.filter { !marked.contains($0.path) }
            guard !removing.isEmpty, !kept.isEmpty else { return nil }
            let items = removing.compactMap(deletionItem)
            return items.isEmpty ? nil : PlannedGroup(items: items, kept: kept)
        }
        let loose = looseLowQualityPhotos.filter { marked.contains($0.path) }.compactMap(deletionItem)
        if !loose.isEmpty { plan.append(PlannedGroup(items: loose, kept: nil)) }
        return plan
    }

    private func deletionItem(_ photo: SimilarPhoto) -> DeletionItem? {
        guard let root = root(containing: photo.path) else { return nil }
        return DeletionItem(
            path: photo.path, ruleRoot: root, expected: photo.snapshot, ownerBundleID: nil,
            freedBytes: photo.reclaimable, section: .storage)
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
            (try? await executor.run { keptChecks.map { $0?.contains(where: Self.isUnchanged) ?? true } })
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

        // Chosen keepers are kept by group id (`chosenKeepers`), so they survive the groups being rebuilt.
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
        lowQualityPhotos.removeAll { gone.contains($0.path) }
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
