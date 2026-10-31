import Foundation
public import Observation

/// The explicit-opt-in review and Trash workflow for browser history, cookies, sessions and site data.
@MainActor
@Observable
public final class BrowserDataSession {
    public enum Phase: Sendable, Equatable {
        case idle, scanning, ready, cleaning
    }

    public private(set) var phase = Phase.idle
    public private(set) var groups: [BrowserDataGroup] = []
    public private(set) var skipped: [SkippedPath] = []
    public private(set) var selection: Set<String> = []
    public private(set) var lastSummary: CleanupSummary?

    private let home: String
    private let policy: ProtectionPolicy
    private let ownerState: @Sendable (String) -> OwnerState
    private let deleter: DeletionExecutor
    private let executor: FSExecutor
    private var itemsByPath: [String: BrowserDataItem] = [:]

    /// All visible items, grouped by profile and data type; no item is selected merely because it was found.
    public var items: [BrowserDataItem] { groups.flatMap(\.items) }
    public var selectedCount: Int { selection.count }
    public var selectedBytes: Int64 {
        selection.reduce(0) { $0 + (itemsByPath[$1]?.candidate.reclaimableSize ?? 0) }
    }

    public init(
        home: String, policy: ProtectionPolicy, ownerState: @escaping @Sendable (String) -> OwnerState,
        deleter: DeletionExecutor, executor: FSExecutor = .shared
    ) {
        self.home = home
        self.policy = policy
        self.ownerState = ownerState
        self.deleter = deleter
        self.executor = executor
    }

    /// Refreshes review data without changing any files and without selecting newly discovered items.
    public func scan() async {
        phase = .scanning
        let result = await BrowserDataScanner.scan(
            home: home, policy: policy, ownerState: ownerState, executor: executor)
        groups = result.groups
        skipped = result.skipped
        itemsByPath = Dictionary(result.items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        selection = selection.filter { itemsByPath[$0]?.status == .available }
        phase = .ready
    }

    /// Toggles one exact path only when it was scanned and is currently available.
    public func toggle(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else if itemsByPath[path]?.status == .available {
            selection.insert(path)
        }
    }

    /// Selects or deselects every available path in one browser/data-type pair, never any other type.
    public func setSelected(_ selected: Bool, browser: Browser, dataType: BrowserDataType) {
        let paths = groups.filter { $0.browser == browser && $0.dataType == dataType }
            .flatMap(\.items).filter { $0.status == .available }.map(\.path)
        if selected {
            selection.formUnion(paths)
        } else {
            selection.subtract(paths)
        }
    }

    /// Selects or deselects one profile's data-type group, leaving all other groups untouched.
    public func setSelected(_ selected: Bool, groupID: String) {
        let paths = groups.first { $0.id == groupID }?.items.filter { $0.status == .available }.map(\.path) ?? []
        if selected {
            selection.formUnion(paths)
        } else {
            selection.subtract(paths)
        }
    }

    /// Sends only the reviewed selection through the existing gate and Trash executor, then refreshes the list.
    @discardableResult
    public func clean(dryRun: Bool = false) async -> CleanupSummary {
        let items = selection.sorted().compactMap { itemsByPath[$0]?.deletionItem(section: .cleanup) }
        phase = .cleaning
        let results = await deleter.run(items, mode: .moveToTrash, dryRun: dryRun)
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
