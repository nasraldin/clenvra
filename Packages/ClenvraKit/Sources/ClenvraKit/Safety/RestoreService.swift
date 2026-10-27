import Darwin

/// Why an item could not be put back from the Trash.
public enum RestoreError: Error, Sendable, Equatable {
    /// The log entry is not a move to the Trash (or predates identity logging).
    case notRestorable
    /// The Trash no longer holds the object Clenvra moved (emptied, or replaced by another item).
    case notInTrash
    /// The folder the item came from is gone; Clenvra does not recreate folders.
    case originalFolderMissing
    /// Something new now occupies the original path; it is never overwritten.
    case originalPathOccupied
    case failed(errno: Int32)
}

/// Puts items that Clenvra moved to the Trash back where they were.
public enum RestoreService {
    public static func restore(_ record: ActivityRecord) throws(RestoreError) {
        guard case .movedToTrash(let trashPath) = record.outcome, let expected = record.identity else {
            throw .notRestorable
        }
        var info = stat()
        guard lstat(trashPath, &info) == 0, FileIdentity(device: info.st_dev, inode: info.st_ino) == expected else {
            throw .notInTrash
        }

        let components = (try? PathPolicy.components(of: record.itemPath)) ?? []
        guard !components.isEmpty else { throw .notRestorable }
        let parentPath = "/" + components.dropLast().joined(separator: "/")
        do {
            let parent = try SafeWalk.resolve(parentPath)
            guard parent.snapshot.kind == .directory else { throw RestoreError.originalFolderMissing }
        } catch {
            throw .originalFolderMissing
        }

        // RENAME_EXCL: atomically fails instead of replacing whatever now exists at the original path.
        guard renamex_np(trashPath, record.itemPath, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? .originalPathOccupied : .failed(errno: errno)
        }
    }
}
