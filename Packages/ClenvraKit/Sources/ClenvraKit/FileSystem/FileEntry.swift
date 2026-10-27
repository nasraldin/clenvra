public import Foundation

/// What kind of filesystem object an entry is. Symlinks are never followed, so a link is always `.symlink`.
public enum FileKind: Sendable, Hashable, Codable {
    case file
    case directory
    case symlink
    case other
}

/// Stable identity of a filesystem object on a mounted volume: (device, inode).
/// Two paths with equal identity are the same object (hard links, firmlinks, case variants).
public struct FileIdentity: Sendable, Hashable, Codable {
    public let device: Int32
    public let inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Sizes of one object, in bytes.
public struct SizeInfo: Sendable, Hashable, Codable {
    /// Bytes of content (`st_size` for files, 0 for directories).
    public let logical: Int64
    /// Bytes allocated on disk.
    public let allocated: Int64
    /// Bytes freed immediately if this object were deleted (not shared with clones or snapshots).
    /// `nil` when the volume cannot report it; callers then fall back to `allocated` and label it an estimate.
    public let reclaimable: Int64?

    public init(logical: Int64, allocated: Int64, reclaimable: Int64?) {
        self.logical = logical
        self.allocated = allocated
        self.reclaimable = reclaimable
    }

    /// Best available "frees" figure.
    public var freedIfDeleted: Int64 { reclaimable ?? allocated }
}

/// One directory entry as read from disk, without following symlinks.
public struct FileEntry: Sendable, Hashable {
    public let name: String
    public let kind: FileKind
    public let identity: FileIdentity
    /// Number of hard links; > 1 means deleting this path alone frees nothing for the shared data.
    public let linkCount: UInt32
    /// BSD file flags (`st_flags`), e.g. `UF_IMMUTABLE`, `UF_DATAVAULT`, `SF_RESTRICTED`.
    public let flags: UInt32
    public let modificationDate: Date
    public let size: SizeInfo
    /// APFS clone family identifier, when the volume reports one.
    public let cloneID: UInt64?
    /// A directory where another volume is mounted; scanners stop here instead of crossing into it.
    public let isMountPoint: Bool

    public init(
        name: String,
        kind: FileKind,
        identity: FileIdentity,
        linkCount: UInt32,
        flags: UInt32,
        modificationDate: Date,
        size: SizeInfo,
        cloneID: UInt64?,
        isMountPoint: Bool = false
    ) {
        self.isMountPoint = isMountPoint
        self.name = name
        self.kind = kind
        self.identity = identity
        self.linkCount = linkCount
        self.flags = flags
        self.modificationDate = modificationDate
        self.size = size
        self.cloneID = cloneID
    }
}
