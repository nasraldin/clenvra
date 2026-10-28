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
}

extension HelperClient: PrivilegedOperations {}
