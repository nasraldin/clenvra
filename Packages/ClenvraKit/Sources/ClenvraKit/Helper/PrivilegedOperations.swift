public import Foundation

/// What the app asks of the privileged helper. A protocol so sessions can be tested with the real `HelperService`
/// in-process, without root or an installed helper.
public protocol PrivilegedOperations: Sendable {
    @concurrent func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse
    /// `nil` when the item was put back.
    @concurrent func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError?
    @concurrent func removeOrphanedLaunchItem(_ item: DeletionItem, operationID: UUID) async throws(HelperClientError)
        -> ActivityRecord.Outcome
    @concurrent func deleteLocalSnapshot(date: String) async throws(HelperClientError) -> SnapshotDeletion
    /// Disables (unload, then `launchctl disable`) or enables (`launchctl enable`, then load) a Mac-wide launch item
    /// in `/Library/LaunchAgents` or `/Library/LaunchDaemons`, after an administrator's password.
    @concurrent func setLaunchItemEnabled(_ item: DeletionItem, enabled: Bool) async throws(HelperClientError)
        -> LaunchItemChange
    /// Runs `tccutil reset <service> <bundle ID>` as root, after an administrator's password.
    @concurrent func resetPermission(service: String, bundleID: String) async throws(HelperClientError)
        -> PermissionReset
}

extension PrivilegedOperations {
    /// Helpers that do not offer the operation (an older or test helper) are treated as unavailable for it.
    @concurrent public func setLaunchItemEnabled(_ item: DeletionItem, enabled: Bool) async throws(HelperClientError)
        -> LaunchItemChange
    { throw .unavailable }

    @concurrent public func resetPermission(service: String, bundleID: String) async throws(HelperClientError)
        -> PermissionReset
    { throw .unavailable }
}

extension HelperClient: PrivilegedOperations {}

/// What the helper did with a request to disable or enable a Mac-wide startup item.
public enum LaunchItemChange: String, Codable, Sendable {
    case done
    /// Not a launch plist directly in an allowlisted folder, Apple's own, managed software, or a bad label.
    case refused
    /// The plist is not the file that was reviewed (changed, replaced or gone).
    case changedSinceReview
    /// No administrator's password was given.
    case notAuthorized
    /// `launchctl` refused.
    case failed
}

/// What the helper did with a request to reset one app's permission for every user.
public enum PermissionReset: String, Codable, Sendable {
    case reset
    /// Unknown service or malformed bundle ID; nothing was asked or run.
    case invalid
    /// No administrator's password was given.
    case notAuthorized
    /// `tccutil` refused.
    case failed
}
