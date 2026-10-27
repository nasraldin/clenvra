public import Foundation

/// Tunables for one storage scan; the defaults suit a whole home folder.
public struct ScanOptions: Sendable {
    /// Files whose allocated size is at least this many bytes are reported in `largeFiles`.
    public var largeFileThreshold: Int64
    /// Caps the large-file list so memory stays bounded on huge trees; the biggest files are kept.
    public var maxLargeFiles: Int
    /// Absolute paths the scan must never descend into (e.g. folders the user asked to ignore).
    public var excludedPaths: Set<String>
    /// Minimum time between progress callbacks, so the UI is not flooded with updates.
    public var progressInterval: Duration

    /// Creates options; every parameter has a default suited to scanning a home folder.
    public init(
        largeFileThreshold: Int64 = 50 * 1024 * 1024,
        maxLargeFiles: Int = 10_000,
        excludedPaths: Set<String> = [],
        progressInterval: Duration = .milliseconds(150)
    ) {
        self.largeFileThreshold = largeFileThreshold
        self.maxLargeFiles = maxLargeFiles
        self.excludedPaths = excludedPaths
        self.progressInterval = progressInterval
    }
}

/// Running counters of a scan, delivered (coalesced) so the UI can show the scan is alive.
public struct ScanProgress: Sendable, Hashable {
    public let filesScanned: Int
    public let directoriesScanned: Int
    public let allocatedBytesSeen: Int64
    /// The most recently finished directory, shown as "Scanning …".
    public let currentDirectory: String
}

/// Totals for one directory's whole subtree, so the Storage browser can show any level without re-scanning.
public struct DirectoryAggregate: Sendable, Hashable {
    public let identity: FileIdentity
    /// Bytes allocated on disk by the subtree; hard-linked data is counted once.
    public let allocated: Int64
    /// Bytes deleting the subtree would free; excludes clone-shared and hard-linked data.
    public let reclaimable: Int64
    /// Bytes of content in the subtree; hard-linked data is counted once.
    public let logical: Int64
    /// Non-directory entries (files, symlinks, others) in the subtree; each hard-link name counts.
    public let fileCount: Int
    /// Descendant directories that were scanned (this directory itself is not counted).
    public let directoryCount: Int
    /// Newest modification date of any non-directory entry in the subtree; `nil` when it has none.
    public let latestModification: Date?
    /// Names of the immediate subdirectories that were scanned, sorted.
    public let childDirectoryNames: [String]
}

/// A file big enough to list in "Large & Old files".
public struct LargeFile: Sendable, Hashable {
    public let path: String
    public let size: SizeInfo
    public let modificationDate: Date
    /// Captured at scan time so a later deletion can verify it still targets the same file.
    public let identity: FileIdentity
    /// Greater than 1 means deleting this path alone frees nothing.
    public let linkCount: UInt32
}

/// A path the scan did not (fully) look into, so the UI can say what is missing from the totals and why.
public struct SkippedPath: Sendable, Hashable {
    /// Why a path was skipped.
    public enum Reason: Sendable, Hashable {
        case permissionDenied
        case mountPoint
        case excluded
        case changedDuringScan
        case unreadableEntries(Int)
        case error(Int32)
    }

    public let path: String
    public let reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }
}

/// The read-only result of one scan: everything the Storage browser and "Large & Old files" need.
public struct StorageSnapshot: Sendable {
    /// The scanned root, without a trailing slash.
    public let root: String
    /// Subtree totals keyed by absolute path (no trailing slash); includes the root.
    public let directories: [String: DirectoryAggregate]
    /// Largest files, biggest allocated size first.
    public let largeFiles: [LargeFile]
    public let skipped: [SkippedPath]
    /// `false` when the scan was cancelled, so totals must be labelled partial.
    public let isComplete: Bool

    /// Looks up a directory, tolerating a trailing slash in `path`.
    public func aggregate(at path: String) -> DirectoryAggregate? {
        directories[StorageScanner.normalize(path)]
    }
}
