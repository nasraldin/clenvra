import Foundation
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
        public let summary: String
        public var output: [OutputLine] = []
        public var result: CommandResult?
    }

    public private(set) var phase = Phase.idle
    public private(set) var rows: [ToolStorage] = []
    public private(set) var lastRun: Run?

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
        phase = .ready
    }

    /// Runs the confirmed cleanup for one row, then refreshes all sizes. Returns `nil` when the row has no command.
    @discardableResult
    public func runCleanup(rowID: String) async -> CommandResult? {
        guard let row = rows.first(where: { $0.id == rowID }), let action = row.cleanup else { return nil }
        let operationID = UUID()
        let itemPath = row.location ?? action.summary
        await record(.intent, path: itemPath, bytes: row.size ?? 0, operationID: operationID)

        phase = .running(rowID: rowID)
        lastRun = Run(rowID: rowID, summary: action.summary)
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
        await inspect()
        return result
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
