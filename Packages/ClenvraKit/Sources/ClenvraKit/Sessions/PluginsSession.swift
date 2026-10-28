import Foundation
public import Observation

/// The Extensions & plug-ins section: everything that adds code to macOS or other apps, grouped by kind, with
/// removal of the user's own plug-in bundles through the deletion gate.
@MainActor
@Observable
public final class PluginsSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case scanning
        case ready
        case removing
    }

    /// Items of one kind, by name; only kinds with visible items are present.
    public struct Group: Sendable, Identifiable {
        public var id: PluginItem.Kind { kind }
        public let kind: PluginItem.Kind
        public let items: [PluginItem]
    }

    public private(set) var phase = Phase.idle
    public private(set) var groups: [Group] = []
    /// IDs (paths) of selected removable items. Nothing is selected by default: plug-ins are the user's choice.
    public private(set) var selection: Set<String> = []
    /// Sources that could not be read in the last scan, so the UI can say what is missing.
    public private(set) var issues: [PluginInventory.Issue] = []
    public private(set) var lastSummary: CleanupSummary?
    /// Apple's own extensions are many and never actionable, so they are hidden unless the user asks.
    public var showsAppleItems = false {
        didSet { regroup() }
    }

    private let reader: PluginReader
    private let deleter: DeletionExecutor
    private let executor: FSExecutor
    private var items: [PluginItem] = []
    private var itemsByID: [String: PluginItem] = [:]

    public init(reader: PluginReader, deleter: DeletionExecutor, executor: FSExecutor = .shared) {
        self.reader = reader
        self.deleter = deleter
        self.executor = executor
    }

    // MARK: - Scanning

    public func scan() async {
        phase = .scanning
        let inventory = await reader.read(executor: executor)
        items = inventory.items
        issues = inventory.issues
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selection = selection.filter { itemsByID[$0]?.handling == .removable }
        regroup()
        phase = .ready
    }

    private func regroup() {
        let visible = items.filter { showsAppleItems || !$0.isApple }
        let byKind = Dictionary(grouping: visible, by: \.kind)
        groups = PluginItem.Kind.allCases.compactMap { kind in
            guard let items = byKind[kind], !items.isEmpty else { return nil }
            let sorted = items.sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
            return Group(kind: kind, items: sorted)
        }
    }

    // MARK: - Selection

    /// Items the user could remove here, across all kinds.
    public var removableCount: Int { items.filter { $0.handling == .removable }.count }

    public var selectedCount: Int { selection.count }

    /// Estimated bytes the selection frees.
    public var selectedBytes: Int64 { selection.reduce(0) { $0 + (itemsByID[$1]?.size ?? 0) } }

    public func canSelect(_ item: PluginItem) -> Bool { item.handling == .removable }

    /// Selects or deselects one item; anything not removable (system, extensions, managed) cannot be selected.
    public func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else if let item = itemsByID[id], canSelect(item) {
            selection.insert(id)
        }
    }

    public func setSelected(_ selected: Bool, kind: PluginItem.Kind) {
        let ids = items.filter { $0.kind == kind && canSelect($0) }.map(\.id)
        if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    // MARK: - Removal

    /// Moves the selection to the Trash (or only checks it, when `dryRun`), then rescans.
    @discardableResult
    public func remove(dryRun: Bool = false) async -> CleanupSummary {
        let deletions = selection.sorted().compactMap { itemsByID[$0]?.deletionItem() }
        phase = .removing
        let results = await deleter.run(deletions, mode: .moveToTrash, dryRun: dryRun)
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
