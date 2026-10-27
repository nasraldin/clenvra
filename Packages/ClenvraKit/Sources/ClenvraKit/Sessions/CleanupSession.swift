import Foundation
public import Observation

/// What a cleanup did, for the result sheet and the Activity view.
public struct CleanupSummary: Sendable, Equatable {
    public struct Problem: Sendable, Equatable {
        public let path: String
        public let reason: ActivityRecord.Outcome
    }

    public var movedToTrashCount = 0
    /// Items deleted for good (emptying the Trash).
    public var removedPermanentlyCount = 0
    /// Dry run only: items that passed every check.
    public var wouldRemoveCount = 0
    /// Estimated bytes freed by items actually moved or removed (what the user reviewed, clone- and hard-link-aware).
    public var freedBytes: Int64 = 0
    /// Items skipped, failed or not attempted, each with its reason.
    public var problems: [Problem] = []

    public init() {}

    /// The summary of one deletion run. Every section builds its result sheet this way.
    public init(results: [DeletionResult]) {
        self.init()
        add(results)
    }

    /// Counts moved, previewed and problem items; anything skipped, failed or not attempted keeps its reason.
    public mutating func add(_ results: [DeletionResult]) {
        for result in results {
            switch result.outcome {
            case .movedToTrash:
                movedToTrashCount += 1
                freedBytes += result.item.freedBytes
            case .wouldDelete:
                wouldRemoveCount += 1
            case .removedPermanently:
                removedPermanentlyCount += 1
                freedBytes += result.item.freedBytes
            case .intent, .restored:
                break
            case .skipped, .failed, .anomaly, .notAttempted:
                problems.append(Problem(path: result.item.path, reason: result.outcome))
            }
        }
    }
}

/// The review-and-clean workflow for a set of cleanup rules (Cleanup and Developer sections).
///
/// The UI binds to this model; all filesystem work happens off the main actor in the scanner and deletion executor.
@MainActor
@Observable
public final class CleanupSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case scanning(completed: Int, total: Int)
        case ready
        case cleaning
    }

    /// Candidates of one category, largest first; only categories that exist on this Mac are present.
    public struct Group: Sendable, Identifiable {
        public var id: CleanupCategory { category }
        public let category: CleanupCategory
        public let candidates: [CleanupCandidate]
        public let skipped: [SkippedPath]
    }

    public private(set) var phase = Phase.idle
    public private(set) var groups: [Group] = []
    public private(set) var selection: Set<String> = []
    public private(set) var lastSummary: CleanupSummary?

    private let rules: [CleanupRule]
    private let actionsByRule: [String: CleanupAction]
    private let section: ActivityRecord.Section
    private let home: String
    private let policy: ProtectionPolicy
    private let ownerState: @Sendable (String) -> OwnerState
    private let deleter: DeletionExecutor
    private let executor: FSExecutor
    private var candidatesByPath: [String: CleanupCandidate] = [:]
    /// Every item ever shown in this session, so rescans respect earlier selection choices.
    private var seenPaths: Set<String> = []

    public init(
        rules: [CleanupRule], section: ActivityRecord.Section, home: String, policy: ProtectionPolicy,
        ownerState: @escaping @Sendable (String) -> OwnerState, deleter: DeletionExecutor,
        executor: FSExecutor = .shared
    ) {
        self.rules = rules
        actionsByRule = Dictionary(rules.map { ($0.id, $0.action) }, uniquingKeysWith: { first, _ in first })
        self.section = section
        self.home = home
        self.policy = policy
        self.ownerState = ownerState
        self.deleter = deleter
        self.executor = executor
    }

    // MARK: - Scanning

    public func scan() async {
        let total = rules.count
        phase = .scanning(completed: 0, total: total)
        var results: [RuleScanResult] = []
        await withTaskGroup(of: RuleScanResult.self) { group in
            for rule in rules {
                group.addTask { [home, policy, ownerState, executor] in
                    await RuleScanner.scan(
                        rule, home: home, policy: policy, ownerState: ownerState, executor: executor)
                }
            }
            for await result in group {
                results.append(result)
                // Show each rule's results as soon as it finishes; slow rules (large project folders) don't block.
                apply(results)
                phase = .scanning(completed: results.count, total: total)
            }
        }
        apply(results)
        phase = .ready
    }

    private func apply(_ results: [RuleScanResult]) {
        let byCategory = Dictionary(grouping: results.filter(\.rootExists), by: \.rule.category)
        groups = CleanupCategory.allCases.compactMap { category in
            guard let results = byCategory[category] else { return nil }
            let candidates = results.flatMap(\.candidates).sorted(by: CleanupCandidate.largestFreedFirst)
            return Group(category: category, candidates: candidates, skipped: results.flatMap(\.skipped))
        }
        candidatesByPath = Dictionary(
            groups.flatMap(\.candidates).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // Keep the user's choices for items already shown; only items seen for the first time get their default.
        var updated = Set<String>()
        for candidate in candidatesByPath.values where candidate.status == .available {
            let isNew = !seenPaths.contains(candidate.path)
            if isNew ? candidate.isSelectedByDefault : selection.contains(candidate.path) {
                updated.insert(candidate.path)
            }
        }
        seenPaths.formUnion(candidatesByPath.keys)
        selection = updated
    }

    // MARK: - Selection

    public var selectedCount: Int { selection.count }

    /// Estimated bytes the selection frees.
    public var selectedBytes: Int64 {
        selection.reduce(0) { $0 + (candidatesByPath[$1]?.reclaimableSize ?? 0) }
    }

    /// Selects or deselects one item; items that are protected, in use or managed by macOS cannot be selected.
    public func toggle(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else if candidatesByPath[path]?.status == .available {
            selection.insert(path)
        }
    }

    public func setSelected(_ selected: Bool, category: CleanupCategory) {
        let paths =
            groups.first { $0.category == category }?.candidates.filter { $0.status == .available }
            .map(\.path) ?? []
        if selected { selection.formUnion(paths) } else { selection.subtract(paths) }
    }

    // MARK: - Cleaning

    /// True when the selection holds items that are deleted for good (Trash contents), so the confirmation must
    /// say it cannot be undone.
    public var selectionIncludesPermanentRemoval: Bool {
        selection.contains { action(for: $0) == .removePermanently }
    }

    private func action(for path: String) -> CleanupAction? {
        candidatesByPath[path].flatMap { actionsByRule[$0.ruleID] }
    }

    /// Moves the selection to the Trash and empties selected Trash items (or checks both, when `dryRun`), then
    /// rescans. Reveal-only items are never acted on.
    @discardableResult
    public func clean(dryRun: Bool = false) async -> CleanupSummary {
        let paths = selection.sorted()
        func items(_ action: CleanupAction) -> [DeletionItem] {
            paths.filter { self.action(for: $0) == action }
                .compactMap { candidatesByPath[$0]?.deletionItem(section: section) }
        }
        let toTrash = items(.moveToTrash)
        let toRemove = items(.removePermanently)
        phase = .cleaning
        var results = await deleter.run(toTrash, mode: .moveToTrash, dryRun: dryRun)
        if !toRemove.isEmpty {
            results += await deleter.run(toRemove, mode: .irreversible, dryRun: dryRun)
        }

        let summary = CleanupSummary(results: results)
        lastSummary = summary
        if dryRun {
            phase = .ready
        } else {
            await scan()
        }
        return summary
    }
}
