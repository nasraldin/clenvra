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

    public enum ChangeOutcome: Sendable, Equatable {
        case done
        /// Apple's own, managed, unreadable, or Mac-wide without the helper.
        case notAllowed
        /// The plist is not the file that was listed; refresh and review it again.
        case changedSinceReview
        /// The administrator's password was not given.
        case notAuthorized
        /// `launchctl` or the helper refused.
        case failed
    }

    public private(set) var items: [LaunchItem] = []
    public private(set) var isLoading = false
    /// Labels launchd keeps from starting in this login (`launchctl print-disabled gui/<uid>`).
    public private(set) var disabledInLogin: Set<String> = []
    /// Labels launchd keeps from starting for the whole Mac (`launchctl print-disabled system`).
    public private(set) var disabledSystemWide: Set<String> = []
    /// Each plist as it was when listed; disabling or enabling refuses a file that changed since.
    private var reviewed: [LaunchItem.ID: FileSnapshot] = [:]
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
        let read = try? await executor.run {
            let items = reader.read(installedApps: installedApps)
            var snapshots: [LaunchItem.ID: FileSnapshot] = [:]
            for item in items {
                snapshots[item.id] = try? SafeWalk.resolve(item.plistPath).snapshot
            }
            return (items, snapshots)
        }
        items = read?.0 ?? []
        reviewed = read?.1 ?? [:]
        isLoading = false
    }

    // MARK: - Disable and enable

    /// Whether the item can be kept from starting (and allowed again). The person's own agents directly; Mac-wide
    /// items only through the helper, with an administrator's password each time. Never Apple's or managed items.
    public func canDisable(_ item: LaunchItem) -> Bool { mayDisable(item) && !waitsForHelper(item) }

    /// Allowed to be disabled, perhaps once the helper is installed or updated (`waitsForHelper`).
    public func mayDisable(_ item: LaunchItem) -> Bool {
        !item.isApple && !isManaged(item) && !item.parseError && item.label != nil
    }

    /// A Mac-wide item that Disable, Enable or Remove would change through the helper, which is not installed or is
    /// from another version: the page offers the action and asks for the helper instead of greying it out.
    public func waitsForHelper(_ item: LaunchItem) -> Bool {
        item.domain != .userAgent && !(helperAvailable && privileged != nil)
    }

    public func isDisabled(_ item: LaunchItem) -> Bool {
        guard let label = item.label else { return false }
        return item.domain == .systemDaemon ? disabledSystemWide.contains(label) : disabledInLogin.contains(label)
    }

    /// macOS is waiting for the person to allow this item in Login Items Settings; only there can it be allowed.
    public func needsLoginItemsSettings(_ item: LaunchItem) -> Bool { item.status == .requiresApproval }

    /// Unloads the item and tells launchd not to start it again. Its plist stays, so Enable undoes it.
    /// Runs one action on several items (Disable, Enable, Remove) under one authorization: one administrator's
    /// password for the whole action.
    public func withOneAuthorization<T>(
        isolation: isolated (any Actor)? = #isolation, _ body: () async -> T
    ) async -> T {
        guard let privileged else { return await body() }
        return await privileged.withOneAuthorization(isolation: isolation, body)
    }

    public func disable(_ item: LaunchItem) async -> ChangeOutcome { await setEnabled(false, item) }

    /// Tells launchd it may start the item again, and loads it.
    public func enable(_ item: LaunchItem) async -> ChangeOutcome { await setEnabled(true, item) }

    /// Reads which items launchd keeps from starting. Separate from `load`, which only reads files.
    public func loadDisabledState() async {
        disabledInLogin = await disabledLabels(in: "gui/\(userID)") ?? disabledInLogin
        disabledSystemWide = await disabledLabels(in: "system") ?? disabledSystemWide
    }

    /// Labels marked `disabled` (or `true` on older systems) in `launchctl print-disabled` output.
    public nonisolated static func disabledLabels(fromPrintDisabled output: String) -> Set<String> {
        var labels: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let match = line.wholeMatch(of: /\s*"([^"]+)"\s*=>\s*(\w+)\s*/) else { continue }
            if ["disabled", "true"].contains(match.output.2.lowercased()) { labels.insert(String(match.output.1)) }
        }
        return labels
    }

    private func disabledLabels(in domain: String) async -> Set<String>? {
        guard let result = await launchctl(["print-disabled", domain]), result.exitStatus == 0 else { return nil }
        return Self.disabledLabels(fromPrintDisabled: result.standardOutput)
    }

    private func setEnabled(_ enabled: Bool, _ item: LaunchItem) async -> ChangeOutcome {
        guard canDisable(item), let label = item.label else { return .notAllowed }
        guard let expected = reviewed[item.id], (try? SafeWalk.resolve(item.plistPath).snapshot) == expected else {
            return .changedSinceReview
        }
        let outcome =
            item.domain == .userAgent
            ? await setOwnAgentEnabled(enabled, plist: item.plistPath, label: label)
            : await setThroughHelper(enabled, item: item, expected: expected)
        guard outcome == .done else { return outcome }
        switch (item.domain, enabled) {
        case (.systemDaemon, true): disabledSystemWide.remove(label)
        case (.systemDaemon, false): disabledSystemWide.insert(label)
        case (_, true): disabledInLogin.remove(label)
        case (_, false): disabledInLogin.insert(label)
        }
        return .done
    }

    private func setOwnAgentEnabled(_ enabled: Bool, plist: String, label: String) async -> ChangeOutcome {
        let domain = "gui/\(userID)"
        if enabled {
            guard await launchctl(["enable", "\(domain)/\(label)"])?.exitStatus == 0 else { return .failed }
            // Loading it now is a bonus; once enabled it starts at the next login either way.
            _ = await launchctl(["bootstrap", domain, plist])
        } else {
            guard let stop = await launchctl(["bootout", domain, plist]),
                stop.exitStatus == 0 || Self.notLoadedStatuses.contains(stop.exitStatus)
            else { return .failed }
            guard await launchctl(["disable", "\(domain)/\(label)"])?.exitStatus == 0 else { return .failed }
        }
        return .done
    }

    /// The helper checks the plist, the label and the folder again, and asks for the administrator's password.
    private func setThroughHelper(_ enabled: Bool, item: LaunchItem, expected: FileSnapshot) async -> ChangeOutcome {
        guard let privileged else { return .notAllowed }
        let request = DeletionItem(
            path: item.plistPath, ruleRoot: (item.plistPath as NSString).deletingLastPathComponent,
            expected: expected, ownerBundleID: nil, freedBytes: 0, section: .startup)
        do {
            switch try await privileged.setLaunchItemEnabled(request, enabled: enabled) {
            case .done: return .done
            case .refused: return .notAllowed
            case .changedSinceReview: return .changedSinceReview
            case .notAuthorized: return .notAuthorized
            case .failed: return .failed
            }
        } catch {
            return .failed
        }
    }

    public func canRemove(_ item: LaunchItem) -> Bool { mayRemove(item) && !waitsForHelper(item) }

    /// Allowed to be removed, perhaps once the helper is ready: the person's own agents, and Mac-wide items whose
    /// program is gone. A Mac-wide item of an installed app is disabled instead, so the app keeps working.
    public func mayRemove(_ item: LaunchItem) -> Bool {
        !item.isApple && !isManaged(item) && (item.domain == .userAgent || needsHelper(item))
    }

    /// A system agent or daemon whose program is gone (SB-4): only the privileged helper can remove it.
    public func needsHelper(_ item: LaunchItem) -> Bool {
        item.domain != .userAgent && item.programState == .missing && !item.isApple && !isManaged(item)
    }

    /// Belongs to company management or security software ("Managed by your organisation"); never removed here.
    public func isManaged(_ item: LaunchItem) -> Bool {
        ([item.label].compactMap { $0 } + item.associatedBundleIdentifiers).contains(where: ManagedAgents.isManaged)
    }

    /// The person's own agent whose program exists: it can be stopped and started for this login session (F9).
    public func canControl(_ item: LaunchItem) -> Bool {
        item.domain == .userAgent && !item.isApple && !isManaged(item) && item.programState != .missing
    }

    /// Unloads the agent for this login session. Its plist stays, so it starts again at the next login.
    public func stop(_ item: LaunchItem) async -> Bool {
        guard canControl(item) else { return false }
        guard let result = await launchctl(["bootout", "gui/\(userID)", item.plistPath]) else { return false }
        return result.exitStatus == 0 || Self.notLoadedStatuses.contains(result.exitStatus)
    }

    /// Loads the agent again for this login session.
    public func start(_ item: LaunchItem) async -> Bool {
        guard canControl(item) else { return false }
        return await launchctl(["bootstrap", "gui/\(userID)", item.plistPath])?.exitStatus == 0
    }

    /// Whether the agent is loaded in this login session; nil when launchctl cannot tell.
    public func isRunning(_ item: LaunchItem) async -> Bool? {
        guard item.domain == .userAgent, let label = item.label,
            let result = await launchctl(["print", "gui/\(userID)/\(label)"])
        else { return nil }
        if result.exitStatus == 0 { return true }
        return Self.notLoadedStatuses.contains(result.exitStatus) ? false : nil
    }

    private func launchctl(_ arguments: [String]) async -> CommandResult? {
        let command = Command(executable: "/bin/launchctl", arguments: arguments, timeout: .seconds(15))
        guard let result = try? await runner.run(command), result.terminationReason == .exited else { return nil }
        return result
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
