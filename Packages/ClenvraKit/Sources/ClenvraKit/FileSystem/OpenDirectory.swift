import Darwin
import Foundation

/// An open directory file descriptor that never follows symlinks and closes itself.
///
/// Every traversal in Clenvra goes through this type: children are opened relative to their parent with
/// `openat(…, O_NOFOLLOW)`, so a path component swapped for a symlink during a scan or a deletion cannot redirect it.
/// Entries are read in bulk with `getattrlistbulk(2)`, one syscall per batch instead of several per file.
public struct OpenDirectory: ~Copyable, Sendable {
    private static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let bufferSize = 128 * 1024

    private let fd: Int32
    /// The path or child name this directory was opened with; used in error messages only.
    public let label: String

    /// Opens an absolute path. The final component must be a real directory, not a symlink.
    public init(path: String) throws(FileSystemError) {
        let fd = Darwin.open(path, Self.openFlags)
        guard fd >= 0 else { throw .current("open", path) }
        self.fd = fd
        label = path
    }

    private init(fd: Int32, label: String) {
        self.fd = fd
        self.label = label
    }

    deinit {
        Darwin.close(fd)
    }

    /// Opens a direct child directory by name, relative to this directory, without following symlinks.
    public func openChild(named name: String) throws(FileSystemError) -> OpenDirectory {
        guard Self.isPlainName(name) else {
            throw FileSystemError(code: EINVAL, operation: "open", path: name)
        }
        let child = Darwin.openat(fd, name, Self.openFlags)
        guard child >= 0 else { throw .current("open", name) }
        return OpenDirectory(fd: child, label: name)
    }

    /// `lstat` of a direct child, relative to this directory (never follows a symlink).
    func statChild(named name: String) throws(FileSystemError) -> stat {
        guard Self.isPlainName(name) else {
            throw FileSystemError(code: EINVAL, operation: "fstatat", path: name)
        }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .current("fstatat", name) }
        return info
    }

    /// Permanently removes a direct child. Directories are emptied recursively through file descriptors only:
    /// nothing is re-resolved by path and symlinks inside are unlinked, never followed.
    func removeChild(named name: String, kind: FileKind) throws(FileSystemError) {
        guard Self.isPlainName(name) else {
            throw FileSystemError(code: EINVAL, operation: "unlinkat", path: name)
        }
        if kind == .directory {
            let child = try openChild(named: name)
            for entry in try child.entries() {
                try child.removeChild(named: entry.name, kind: entry.kind)
            }
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw .current("rmdir", name) }
        } else {
            guard unlinkat(fd, name, 0) == 0 else { throw .current("unlink", name) }
        }
    }

    /// Identity of this directory itself.
    public func identity() throws(FileSystemError) -> FileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .current("fstat", label) }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// All entries of this directory (excluding "." and ".."); entries the kernel could not read are skipped.
    public func entries() throws(FileSystemError) -> [FileEntry] {
        try read().entries
    }

    /// Entries plus the number of entries that could not be read (reported to the user as "skipped").
    public func read() throws(FileSystemError) -> DirectoryListing {
        // Rewind so the listing is complete even if this directory was read before.
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw .current("lseek", label) }

        var request = Self.attributeRequest()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var listing = DirectoryListing()
        while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress, buffer.count, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count < 0 {
                if errno == EINTR { continue }
                throw .current("getattrlistbulk", label)
            }
            if count == 0 { break }

            var recordStart = 0
            for _ in 0..<count {
                let length = Int(buffer.loadUnaligned(fromByteOffset: recordStart, as: UInt32.self))
                guard length > 0, recordStart + length <= buffer.count else {
                    throw FileSystemError(code: EIO, operation: "getattrlistbulk", path: label)
                }
                let record = UnsafeRawBufferPointer(rebasing: buffer[recordStart..<(recordStart + length)])
                switch Self.parse(record) {
                case .entry(let entry): listing.entries.append(entry)
                case .unreadable: listing.unreadableCount += 1
                }
                recordStart += length
            }
        }
        return listing
    }

    // MARK: - Private

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    private static func attributeRequest() -> attrlist {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        let common: [attrgroup_t] = [
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS), attrgroup_t(ATTR_CMN_NAME), attrgroup_t(ATTR_CMN_DEVID),
            attrgroup_t(ATTR_CMN_OBJTYPE), attrgroup_t(ATTR_CMN_MODTIME), attrgroup_t(ATTR_CMN_FLAGS),
            attrgroup_t(ATTR_CMN_FILEID), attrgroup_t(ATTR_CMN_ERROR),
        ]
        request.commonattr = common.reduce(0, |)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr =
            attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // With FSOPT_ATTR_CMN_EXTENDED the fork group carries the extended common attributes.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)
        return request
    }

    private enum ParsedRecord {
        case entry(FileEntry)
        case unreadable
    }

    /// Parses one record. Layout (getattrlist(2), getattrlistbulk(2)): length, returned-attributes set, per-entry
    /// error, then common attributes in bit order, directory, file, and extended common attributes. Only attributes
    /// flagged in the returned set are present; every field is 4-byte aligned.
    private static func parse(_ record: UnsafeRawBufferPointer) -> ParsedRecord {
        var cursor = RecordCursor(record: record, offset: MemoryLayout<UInt32>.size)
        let returned = cursor.read(attribute_set_t.self)
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0, cursor.read(UInt32.self) != 0 {
            return .unreadable
        }
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0, let name = cursor.readName() else { return .unreadable }
        let device = common & attrgroup_t(ATTR_CMN_DEVID) != 0 ? cursor.read(Int32.self) : 0
        let objectType = common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 ? cursor.read(UInt32.self) : 0
        let modified = common & attrgroup_t(ATTR_CMN_MODTIME) != 0 ? cursor.read(timespec.self) : timespec()
        let flags = common & attrgroup_t(ATTR_CMN_FLAGS) != 0 ? cursor.read(UInt32.self) : 0
        guard common & attrgroup_t(ATTR_CMN_FILEID) != 0 else { return .unreadable }
        let inode = cursor.read(UInt64.self)

        var isMountPoint = false
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            isMountPoint = cursor.read(UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
        }

        let file = returned.fileattr
        let linkCount = file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 ? cursor.read(UInt32.self) : 1
        let logical = file & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 ? cursor.read(Int64.self) : 0
        let allocated = file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 ? cursor.read(Int64.self) : 0

        let extended = returned.forkattr
        let reclaimable = extended & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 ? cursor.read(Int64.self) : nil
        let cloneID = extended & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 ? cursor.read(UInt64.self) : nil

        return .entry(
            FileEntry(
                name: name,
                kind: kind(of: objectType),
                identity: FileIdentity(device: device, inode: inode),
                linkCount: linkCount,
                flags: flags,
                modificationDate: Date(
                    timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9),
                size: SizeInfo(logical: logical, allocated: allocated, reclaimable: reclaimable),
                cloneID: cloneID,
                isMountPoint: isMountPoint
            ))
    }

    private static func kind(of objectType: UInt32) -> FileKind {
        switch objectType {
        case UInt32(VREG.rawValue): .file
        case UInt32(VDIR.rawValue): .directory
        case UInt32(VLNK.rawValue): .symlink
        default: .other
        }
    }
}

/// Result of reading one directory.
public struct DirectoryListing: Sendable {
    public var entries: [FileEntry] = []
    /// Entries the kernel reported an error for (e.g. a race with deletion); shown as "skipped".
    public var unreadableCount = 0
}

/// Sequential reader over one getattrlistbulk record. Bounds-checked: reading past the end yields zero values
/// instead of touching memory outside the record.
private struct RecordCursor {
    let record: UnsafeRawBufferPointer
    var offset: Int

    mutating func read<T: BitwiseCopyable>(_: T.Type) -> T {
        let size = MemoryLayout<T>.size
        defer { offset += size }
        guard offset >= 0, offset + size <= record.count else { return zeroValue(T.self) }
        return record.loadUnaligned(fromByteOffset: offset, as: T.self)
    }

    /// Reads an `attrreference_t` and decodes the UTF-8 name it points to (relative to the reference itself).
    mutating func readName() -> String? {
        let referenceOffset = offset
        let reference = read(attrreference_t.self)
        let start = referenceOffset + Int(reference.attr_dataoffset)
        let length = Int(reference.attr_length)
        guard length > 0, start >= 0, start + length <= record.count else { return nil }
        var bytes = UnsafeRawBufferPointer(rebasing: record[start..<(start + length)])
        if bytes.last == 0 { bytes = UnsafeRawBufferPointer(rebasing: bytes.dropLast()) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func zeroValue<T: BitwiseCopyable>(_: T.Type) -> T {
        withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { storage in
            let raw = UnsafeMutableRawBufferPointer(storage)
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            return raw.loadUnaligned(as: T.self)
        }
    }
}
