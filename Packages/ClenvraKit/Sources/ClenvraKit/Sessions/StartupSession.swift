import Darwin
import Foundation
public import Observation

/// Everything that starts automatically, with orphaned items first, and safe removal of the user's own agents.
@MainActor
@Observable
public final class StartupSession {
    public enum RemovalOutcome: Sendable, Equatable {
        case removed
        /// Only the user's own, non-Apple launch agents can be removed here; system items are revealed in Finder.
        case notAllowed
        /// `launchctl` could not stop the job, so its plist was kept (removing it would leave it running).
        case couldNotStop
        /// The deletion gate or the Trash refused; the reason is in the outcome.
        case refused(ActivityRecord.Outcome)
    }

    public private(set) var items: [LaunchItem] = []
    public private(set) var isLoading = false
    /// Whether the privileged helper is installed and answering; orphaned system items can be removed only then.
    public var helperAvailable = false

    private let reader: LaunchItemReader
    private let runner: any CommandRunning
    private let userID: UInt32
    private let deleter: DeletionExecutor
    private let executor: FSExecutor
    private let privileged: (any PrivilegedOperations)?

    /// `launchctl` exit statuses meaning "this job is not loaded", i.e. already stopped.
    private static let notLoadedStatuses: Set<Int32> = [3, 113]

    public init(
        reader: LaunchItemReader, runner: any CommandRunning, userID: UInt32? = nil, deleter: DeletionExecutor,
        executor: FSExecutor = .shared, privileged: (any PrivilegedOperations)? = nil
    ) {
        self.reader = reader
        self.runner = runner
        self.userID = userID ?? getuid()
        self.deleter = deleter
        self.executor = executor
        self.privileged = privileged
    }

    /// Items whose program no longer exists: leftovers of uninstalled apps.
    public var problemCount: Int { items.filter { $0.programState == .missing }.count }

    public func load(installedApps: [InstalledApp]) async {
        isLoading = true
        let reader = reader
        items = (try? await executor.run { reader.read(installedApps: installedApps) }) ?? []
        isLoading = false
    }

    public func canRemove(_ item: LaunchItem) -> Bool {
        guard !item.isApple, !isManaged(item) else { return false }
        return item.domain == .userAgent || needsHelper(item) && helperAvailable && privileged != nil
    }

    /// A system agent or daemon whose program is gone (SB-4): only the privileged helper can remove it.
    public func needsHelper(_ item: LaunchItem) -> Bool {
        item.domain != .userAgent && item.programState == .missing && !item.isApple && !isManaged(item)
    }

    /// Belongs to company management or security software ("Managed by your organisation"); never removed here.
    public func isManaged(_ item: LaunchItem) -> Bool {
        ([item.label].compactMap { $0 } + item.associatedBundleIdentifiers).contains(where: ManagedAgents.isManaged)
    }

    /// Stops the agent for this login session, then moves its plist to the Trash (so it does not start again).
    public func remove(_ item: LaunchItem) async -> RemovalOutcome {
        guard canRemove(item) else { return .notAllowed }
        if item.domain != .userAgent { return await removeThroughHelper(item) }

        let stop = Command(
            executable: "/bin/launchctl", arguments: ["bootout", "gui/\(userID)", item.plistPath], timeout: .seconds(15)
        )
        guard let result = try? await runner.run(stop), result.terminationReason == .exited,
            result.exitStatus == 0 || Self.notLoadedStatuses.contains(result.exitStatus)
        else { return .couldNotStop }

        let snapshot: FileSnapshot
        do {
            snapshot = try SafeWalk.resolve(item.plistPath).snapshot
        } catch {
            return .refused(.skipped(error))
        }
        let deletion = DeletionItem(
            path: item.plistPath, ruleRoot: (item.plistPath as NSString).deletingLastPathComponent,
            expected: snapshot, ownerBundleID: nil, freedBytes: 0, section: .startup)
        let outcome = await deleter.run([deletion], mode: .moveToTrash).first?.outcome ?? .notAttempted
        guard case .movedToTrash = outcome else { return .refused(outcome) }
        items.removeAll { $0.id == item.id }
        return .removed
    }

    /// The helper re-reads the plist, confirms the program is gone, unloads the job and moves the plist to the Trash.
    private func removeThroughHelper(_ item: LaunchItem) async -> RemovalOutcome {
        guard let privileged else { return .notAllowed }
        let snapshot: FileSnapshot
        do {
            snapshot = try SafeWalk.resolve(item.plistPath).snapshot
        } catch {
            return .refused(.skipped(error))
        }
        let deletion = DeletionItem(
            path: item.plistPath, ruleRoot: (item.plistPath as NSString).deletingLastPathComponent,
            expected: snapshot, ownerBundleID: nil, freedBytes: 0, section: .startup)
        let operationID = UUID()
        let outcome: ActivityRecord.Outcome
        do {
            outcome = try await privileged.removeOrphanedLaunchItem(deletion, operationID: operationID)
        } catch {
            outcome = .notAttempted
        }
        await deleter.recordPrivileged([DeletionResult(item: deletion, outcome: outcome)], operationID: operationID)
        guard case .movedToTrash = outcome else { return .refused(outcome) }
        items.removeAll { $0.id == item.id }
        return .removed
    }
}
