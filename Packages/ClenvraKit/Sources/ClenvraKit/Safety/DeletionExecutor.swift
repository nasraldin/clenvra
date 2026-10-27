import Darwin
public import Foundation

/// Moving items to the Trash. A protocol only so tests can use a fixture Trash and simulate failures.
public protocol TrashOperations: Sendable {
    /// Moves the item and returns its new path in the Trash.
    func moveToTrash(path: String) throws -> String
}

/// The real Trash, via Foundation (handles per-volume Trash folders and name collisions).
public struct SystemTrash: TrashOperations {
    public init() {}

    public func moveToTrash(path: String) throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: &resulting)
        guard let moved = (resulting as URL?)?.path(percentEncoded: false) else {
            throw FileSystemError(code: EIO, operation: "trash", path: path)
        }
        return moved
    }
}

public enum DeletionMode: Sendable {
    /// Default for every file deletion: recoverable from the Trash.
    case moveToTrash
    /// Only for actions the user confirmed as irreversible (e.g. emptying the Trash).
    case irreversible
}

public struct DeletionResult: Sendable, Equatable {
    public let item: DeletionItem
    public let outcome: ActivityRecord.Outcome
}

/// Executes confirmed deletions one at a time, each guarded by `DeletionGate` immediately before acting.
///
/// Guarantees: every item is logged before and after; a refusal or failure affects only that item; an identity
/// mismatch after moving (something swapped the path) stops the whole batch; a failed move to the Trash never falls
/// back to permanent deletion; cancellation stops before the next item.
public actor DeletionExecutor {
    private let gate: DeletionGate
    private let log: ActivityLog
    private let trash: any TrashOperations
    private let fileSystem: FSExecutor
    private let now: @Sendable () -> Date

    public init(
        gate: DeletionGate,
        log: ActivityLog,
        trash: any TrashOperations = SystemTrash(),
        fileSystem: FSExecutor = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gate = gate
        self.log = log
        self.trash = trash
        self.fileSystem = fileSystem
        self.now = now
    }

    public func run(
        _ items: [DeletionItem], mode: DeletionMode, dryRun: Bool = false, operationID: UUID = UUID()
    ) async -> [DeletionResult] {
        var results: [DeletionResult] = []
        var stopped = false
        for item in items {
            let outcome: ActivityRecord.Outcome
            if stopped || Task.isCancelled {
                outcome = .notAttempted
            } else if !dryRun, !(await record(.intent, for: item, operationID)) {
                outcome = .failed(errno: EIO)  // never act on an item we could not log
            } else {
                outcome = await perform(item, mode: mode, dryRun: dryRun)
            }
            if outcome == .anomaly { stopped = true }
            results.append(DeletionResult(item: item, outcome: outcome))
            await record(outcome, for: item, operationID)
        }
        return results
    }

    /// Logs outcomes of work the privileged helper did, so Activity shows them and Put Back can find them.
    public func recordPrivileged(_ results: [DeletionResult], operationID: UUID) async {
        for result in results {
            let entry = ActivityRecord(
                operationID: operationID, date: now(), section: result.item.section, itemPath: result.item.path,
                bytes: result.item.freedBytes, outcome: result.outcome, identity: result.item.expected.identity,
                privileged: true)
            try? await log.append(entry)
        }
    }

    // MARK: - Private

    private func perform(_ item: DeletionItem, mode: DeletionMode, dryRun: Bool) async -> ActivityRecord.Outcome {
        let gate = gate
        let trash = trash
        do {
            return try await fileSystem.run {
                Self.act(on: item, mode: mode, dryRun: dryRun, gate: gate, trash: trash)
            }
        } catch {
            return .notAttempted  // cancelled before the work started
        }
    }

    private static func act(
        on item: DeletionItem, mode: DeletionMode, dryRun: Bool, gate: DeletionGate, trash: any TrashOperations
    ) -> ActivityRecord.Outcome {
        let resolved: ResolvedItem
        do {
            resolved = try gate.check(item)
        } catch {
            return .skipped(error)
        }
        if dryRun { return .wouldDelete }

        switch mode {
        case .moveToTrash:
            let trashPath: String
            do {
                trashPath = try trash.moveToTrash(path: item.path)
            } catch {
                return .failed(errno: errnoCode(of: error))
            }
            var info = stat()
            let moved = lstat(trashPath, &info) == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
            return moved == resolved.snapshot.identity ? .movedToTrash(trashPath: trashPath) : .anomaly

        case .irreversible:
            do {
                try resolved.parent.removeChild(named: resolved.name, kind: resolved.snapshot.kind)
                return .removedPermanently
            } catch {
                return .failed(errno: error.code)
            }
        }
    }

    private static func errnoCode(of error: any Error) -> Int32 {
        if let error = error as? FileSystemError { return error.code }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain
        {
            return Int32(underlying.code)
        }
        return EIO
    }

    @discardableResult
    private func record(_ outcome: ActivityRecord.Outcome, for item: DeletionItem, _ operationID: UUID) async -> Bool {
        let entry = ActivityRecord(
            operationID: operationID, date: now(), section: item.section, itemPath: item.path, bytes: item.freedBytes,
            outcome: outcome, identity: item.expected.identity)
        do {
            try await log.append(entry)
            return true
        } catch {
            return false
        }
    }
}
