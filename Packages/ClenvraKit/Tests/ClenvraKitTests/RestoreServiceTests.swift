import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("RestoreService")
struct RestoreServiceTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        let scratch = try TemporaryDirectory()
        self.scratch = scratch
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory(".Trash")
        try fixture.directory("cache")
    }

    private func path(_ relative: String) -> String {
        scratch.url.appending(path: relative).path(percentEncoded: false)
    }

    private func identity(_ relative: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path(relative), &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Simulates an item that Clenvra moved to the Trash: returns the activity record describing it.
    private func trashed(_ name: String) throws -> ActivityRecord {
        try fixture.file(".Trash/\(name)", bytes: 3)
        return ActivityRecord(
            operationID: UUID(), date: Date(), section: .cleanup, itemPath: path("cache/\(name)"), bytes: 3,
            outcome: .movedToTrash(trashPath: path(".Trash/\(name)")), identity: identity(".Trash/\(name)"))
    }

    @Test("an item still in the Trash is put back where it came from")
    func restores() throws {
        let record = try trashed("a.bin")

        try RestoreService.restore(record)

        #expect(identity("cache/a.bin") == record.identity)
        #expect(identity(".Trash/a.bin") == nil)
    }

    @Test("restoring never overwrites an item that now occupies the original path (safety case S22)")
    func occupied() throws {
        let record = try trashed("a.bin")
        try fixture.file("cache/a.bin", bytes: 1)

        #expect(throws: RestoreError.originalPathOccupied) { try RestoreService.restore(record) }
        #expect(identity(".Trash/a.bin") == record.identity)
    }

    @Test("an item in the Trash that is not the one Clenvra moved is not restored")
    func differentItem() throws {
        let record = try trashed("a.bin")
        try FileManager.default.removeItem(atPath: path(".Trash/a.bin"))
        try fixture.file(".Trash/a.bin", bytes: 2)

        #expect(throws: RestoreError.notInTrash) { try RestoreService.restore(record) }
    }

    @Test("an item already removed from the Trash cannot be restored")
    func emptied() throws {
        let record = try trashed("a.bin")
        try FileManager.default.removeItem(atPath: path(".Trash/a.bin"))

        #expect(throws: RestoreError.notInTrash) { try RestoreService.restore(record) }
    }

    @Test("when the original folder no longer exists, restore is refused instead of recreating folders")
    func parentMissing() throws {
        let record = try trashed("a.bin")
        try FileManager.default.removeItem(atPath: path("cache"))

        #expect(throws: RestoreError.originalFolderMissing) { try RestoreService.restore(record) }
    }

    @Test("records that are not Trash moves cannot be restored")
    func notRestorable() {
        let record = ActivityRecord(
            operationID: UUID(), date: Date(), section: .cleanup, itemPath: "/x", bytes: 0, outcome: .removedPermanently
        )
        #expect(throws: RestoreError.notRestorable) { try RestoreService.restore(record) }
    }
}
