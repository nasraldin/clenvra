import Foundation
public import Observation

/// Local Time Machine snapshots (SY-4): listed as the user, deleted only through the privileged helper.
@MainActor
@Observable
public final class SnapshotsSession {
    /// Snapshot dates, newest first.
    public private(set) var snapshots: [String] = []
    public private(set) var isLoading = false
    /// Whether the privileged helper is installed and answering.
    public var helperAvailable = false

    private let runner: any CommandRunning
    private let privileged: (any PrivilegedOperations)?

    public init(runner: any CommandRunning, privileged: (any PrivilegedOperations)?) {
        self.runner = runner
        self.privileged = privileged
    }

    public var canDelete: Bool { helperAvailable && privileged != nil }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        let result = try? await runner.run(
            Command(executable: "/usr/bin/tmutil", arguments: ["listlocalsnapshotdates", "/"]))
        guard let result, result.terminationReason == .exited, result.exitStatus == 0 else {
            snapshots = []
            return
        }
        snapshots = LocalSnapshots.dates(fromListOutput: result.standardOutput).sorted(by: >)
    }

    /// Deletes one snapshot through the helper, then reloads. `nil` when the helper is not available.
    @discardableResult
    public func delete(_ date: String) async -> SnapshotDeletion? {
        guard canDelete, let privileged else { return nil }
        let outcome = (try? await privileged.deleteLocalSnapshot(date: date)) ?? .failed
        await load()
        return outcome
    }
}
