public import Foundation
public import Observation
import Synchronization

/// Developer-tool storage (package managers, simulators, containers): sizes plus each tool's own cleanup command.
///
/// Tool commands bypass the Trash, so every run is logged before and after and its output is kept for the UI.
@MainActor
@Observable
public final class ToolStorageSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case inspecting
        case ready
        case running(rowID: String)
    }

    /// The most recent command run, for the output sheet.
    public struct Run: Sendable {
        public let rowID: String
        /// The tool's name when it ran, so results read the same after the sizes are refreshed.
        public let tool: LocalizedStringResource
        public let summary: String
        public var output: [OutputLine] = []
        public var result: CommandResult?
    }

    public private(set) var phase = Phase.idle
    public private(set) var rows: [ToolStorage] = []
    public private(set) var lastRun: Run?
    /// Rows checked for "Clean N Tools…"; only rows with a cleanup command can be checked.
    public private(set) var checked: Set<String> = []
    /// The runs of the most recent batch, in the order they ran.
    public private(set) var lastBatch: [Run]?

    private let adapters: [any ToolAdapter]
    private let locator: ToolLocator
    private let runner: any CommandRunning
    private let home: String
    private let log: ActivityLog

    public init(
        adapters: [any ToolAdapter] = ToolAdapters.standard, locator: ToolLocator, runner: any CommandRunning,
        home: String, log: ActivityLog
    ) {
        self.adapters = adapters
        self.locator = locator
        self.runner = runner
        self.home = home
        self.log = log
    }

    /// Asks every adapter, in parallel, what its tool stores; absent tools add nothing.
    public func inspect() async {
        phase = .inspecting
        var found: [(index: Int, rows: [ToolStorage])] = []
        await withTaskGroup(of: (Int, [ToolStorage]).self) { group in
            for (index, adapter) in adapters.enumerated() {
                group.addTask { @concurrent [locator, runner, home] in
                    (index, await adapter.inspect(locator: locator, runner: runner, home: home))
                }
            }
            for await result in group { found.append(result) }
        }
        rows = found.sorted { $0.index < $1.index }.flatMap(\.rows)
        // A tool that is gone, or no longer offers a command, cannot stay checked.
        checked = checked.filter(isCheckable)
        phase = .ready
    }

    // MARK: - Checking several tools

    /// The checked rows, in the order shown (and run).
    public var checkedRows: [ToolStorage] { rows.filter { checked.contains($0.id) } }

    /// Checks or unchecks one row; rows without a cleanup command are ignored.
    public func toggleChecked(_ rowID: String) {
        if checked.contains(rowID) {
            checked.remove(rowID)
        } else if isCheckable(rowID) {
            checked.insert(rowID)
        }
    }

    /// Replaces the checks; rows without a cleanup command, or unknown rows, are dropped.
    public func setChecked(_ rowIDs: Set<String>) {
        checked = rowIDs.filter(isCheckable)
    }

    private func isCheckable(_ rowID: String) -> Bool {
        rows.contains { $0.id == rowID && $0.cleanup != nil }
    }

    /// Runs each checked row's cleanup in the order shown, then refreshes all sizes once. A failing tool does not stop
    /// the others; every run is logged and returned (also kept in `lastBatch`).
    @discardableResult
    public func runCheckedCleanups() async -> [Run] {
        let batch = checkedRows
        checked = []
        var runs: [Run] = []
        for row in batch {
            if let run = await execute(row) { runs.append(run) }
        }
        lastBatch = runs
        await inspect()
        return runs
    }

    /// Runs the confirmed cleanup for one row, then refreshes all sizes. Returns `nil` when the row has no command.
    @discardableResult
    public func runCleanup(rowID: String) async -> CommandResult? {
        guard let row = rows.first(where: { $0.id == rowID }), let run = await execute(row) else { return nil }
        await inspect()
        return run.result
    }

    /// Runs one row's command, logged before and after; `nil` when the row has no command.
    private func execute(_ row: ToolStorage) async -> Run? {
        guard let action = row.cleanup else { return nil }
        let rowID = row.id
        let operationID = UUID()
        let itemPath = row.location ?? action.summary
        await record(.intent, path: itemPath, bytes: row.size ?? 0, operationID: operationID)

        phase = .running(rowID: rowID)
        lastRun = Run(rowID: rowID, tool: row.tool, summary: action.summary)
        let lines = LineCollector()
        let result = try? await ToolCleanupRunner.run(action, runner: runner) { line in lines.append(line) }
        lastRun?.output = lines.lines
        lastRun?.result = result

        let outcome: ActivityRecord.Outcome =
            if let result, result.terminationReason == .exited, result.exitStatus == 0 {
                .removedPermanently
            } else {
                .failed(errno: result?.exitStatus ?? -1)
            }
        await record(outcome, path: itemPath, bytes: row.size ?? 0, operationID: operationID)
        return lastRun
    }

    private func record(_ outcome: ActivityRecord.Outcome, path: String, bytes: Int64, operationID: UUID) async {
        try? await log.append(
            ActivityRecord(
                operationID: operationID, date: Date(), section: .developer, itemPath: path, bytes: bytes,
                outcome: outcome))
    }
}

/// Collects streamed output lines from any thread.
private final class LineCollector: Sendable {
    private let storage = Mutex<[OutputLine]>([])

    func append(_ line: OutputLine) { storage.withLock { $0.append(line) } }
    var lines: [OutputLine] { storage.withLock { $0 } }
}
