import Foundation
import Testing

@testable import ClenvraKit

@MainActor
@Suite("Local snapshots session")
struct SnapshotsSessionTests {
    private struct FakeHelper: PrivilegedOperations {
        let answer: SnapshotDeletion
        func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse {
            throw .unavailable
        }
        func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError? { throw .unavailable }
        func removeOrphanedLaunchItem(_ item: DeletionItem, operationID: UUID) async throws(HelperClientError)
            -> ActivityRecord.Outcome
        { throw .unavailable }
        func deleteLocalSnapshot(date: String) async throws(HelperClientError) -> SnapshotDeletion { answer }
    }

    private func runner(listing: String) -> FakeCommandRunner {
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"], stdout: listing)
        return runner
    }

    @Test("lists snapshots newest first, without needing the helper")
    func lists() async {
        let session = SnapshotsSession(
            runner: runner(listing: "Snapshot dates for all disks:\n2026-10-25-101500\n2026-10-27-093012\n"),
            privileged: nil)

        await session.load()

        #expect(session.snapshots == ["2026-10-27-093012", "2026-10-25-101500"])
        #expect(!session.canDelete)
    }

    @Test("deleting goes through the helper and reloads; without the helper nothing happens")
    func deletes() async {
        let session = SnapshotsSession(
            runner: runner(listing: "Snapshot dates for all disks:\n2026-10-27-093012\n"),
            privileged: FakeHelper(answer: .deleted))
        await session.load()
        #expect(await session.delete("2026-10-27-093012") == nil)  // helper not confirmed yet

        session.helperAvailable = true
        #expect(session.canDelete)
        #expect(await session.delete("2026-10-27-093012") == .deleted)
    }
}
