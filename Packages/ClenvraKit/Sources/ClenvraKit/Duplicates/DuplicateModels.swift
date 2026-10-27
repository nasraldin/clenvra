public import Foundation

/// One copy in a duplicate group, with the snapshot that later deletion re-checks before acting on it.
public struct DuplicateFile: Sendable, Hashable {
    public let path: String
    /// State at listing time; the copy is only offered while the file on disk still matches it.
    public let snapshot: FileSnapshot
    /// Logical size in bytes.
    public let size: Int64
    /// Bytes allocated on disk.
    public let allocated: Int64
    /// Bytes freed by moving only this copy away: 0 for an APFS clone sharing its blocks or a hard-linked file.
    public let reclaimable: Int64
    public let modificationDate: Date
    /// APFS clone family, so the UI can explain why removing a clone frees nothing.
    public let cloneID: UInt64?

    public init(
        path: String, snapshot: FileSnapshot, size: Int64, allocated: Int64, reclaimable: Int64,
        modificationDate: Date, cloneID: UInt64?
    ) {
        self.path = path
        self.snapshot = snapshot
        self.size = size
        self.allocated = allocated
        self.reclaimable = reclaimable
        self.modificationDate = modificationDate
        self.cloneID = cloneID
    }
}

/// Files proven byte-for-byte identical, so the user can keep one and move the rest to the Trash.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    /// Content digest (hex), the size, and a suffix when one digest held several distinct contents.
    public let id: String
    /// Logical size of one copy.
    public let size: Int64
    /// At least two distinct files (hard-link names of one file count once); the suggested keeper comes first.
    public let files: [DuplicateFile]
    /// The copy kept by default: the oldest, then the shortest path, then the lexicographically smallest path.
    public let suggestedKeeper: String
    /// Honest space estimate: the sum of every non-keeper's own `reclaimable`, so clones and hard links add nothing.
    public let reclaimableIfOthersRemoved: Int64
}

/// What to look at; the defaults avoid hashing many small files that would free little space.
public struct DuplicateScanOptions: Sendable {
    /// Files smaller than this are ignored. Empty files are always ignored.
    public var minimumSize: Int64
    /// Whether names starting with "." and items flagged `UF_HIDDEN` are scanned.
    public var includeHidden: Bool
    /// Folders or files (and everything inside them) that are never scanned.
    public var excludedPaths: Set<String>
    /// Upper bound on files read at the same time, to keep disks responsive.
    public var maximumConcurrentReads: Int

    public init(
        minimumSize: Int64 = 1024 * 1024, includeHidden: Bool = false, excludedPaths: Set<String> = [],
        maximumConcurrentReads: Int = 4
    ) {
        self.minimumSize = minimumSize
        self.includeHidden = includeHidden
        self.excludedPaths = excludedPaths
        self.maximumConcurrentReads = maximumConcurrentReads
    }
}

/// Progress of a duplicate scan, so the UI can show which stage is running and how much has been read.
public struct DuplicateScanProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case listing
        case grouping
        case hashing
        case verifying
    }

    public var phase: Phase
    /// Files (of any size) seen while listing.
    public var filesSeen: Int
    /// Files sharing their exact size with at least one other file, the only ones that are read.
    public var candidateFiles: Int
    public var bytesHashed: Int64

    public init(phase: Phase, filesSeen: Int, candidateFiles: Int, bytesHashed: Int64) {
        self.phase = phase
        self.filesSeen = filesSeen
        self.candidateFiles = candidateFiles
        self.bytesHashed = bytesHashed
    }
}

/// Outcome of a duplicate scan.
public struct DuplicateScanResult: Sendable {
    /// Verified groups, largest reclaimable space first.
    public var groups: [DuplicateGroup]
    /// Paths that could not be read, with the `errno` that stopped them (e.g. `EACCES`).
    public var skipped: [String: Int32]
    /// `false` when the scan was cancelled; `groups` then holds only groups fully verified before that.
    public var isComplete: Bool

    public init(groups: [DuplicateGroup], skipped: [String: Int32], isComplete: Bool) {
        self.groups = groups
        self.skipped = skipped
        self.isComplete = isComplete
    }
}
