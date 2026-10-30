import Darwin
public import Foundation

/// The state of an item that matters for "is this still the thing the user reviewed?".
///
/// Directories compare by identity only: their modification date and size change whenever their contents do,
/// which is normal for caches. Files, symlinks and other items also compare content size and modification date.
public struct FileSnapshot: Sendable, Hashable, Codable {
    public let identity: FileIdentity
    public let kind: FileKind
    /// `nil` for directories.
    public let logicalSize: Int64?
    /// `nil` for directories.
    public let modificationDate: Date?

    public init(identity: FileIdentity, kind: FileKind, logicalSize: Int64?, modificationDate: Date?) {
        let isDirectory = kind == .directory
        self.identity = identity
        self.kind = kind
        self.logicalSize = isDirectory ? nil : logicalSize
        self.modificationDate = isDirectory ? nil : modificationDate
    }

    /// Snapshot of an entry as it was seen during a scan.
    public init(_ entry: FileEntry) {
        self.init(
            identity: entry.identity, kind: entry.kind, logicalSize: entry.size.logical,
            modificationDate: entry.modificationDate)
    }

    init(_ info: stat) {
        let kind: FileKind =
            switch info.st_mode & S_IFMT {
            case S_IFREG: .file
            case S_IFDIR: .directory
            case S_IFLNK: .symlink
            default: .other
            }
        self.init(
            identity: FileIdentity(device: info.st_dev, inode: info.st_ino),
            kind: kind,
            logicalSize: Int64(info.st_size),
            modificationDate: Date(
                timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        )
    }
}

/// An item reached by a safe walk: its parent directory is held open, so later operations can be relative to it.
public struct ResolvedItem: ~Copyable, Sendable {
    public let parent: OpenDirectory
    public let name: String
    public let snapshot: FileSnapshot
    /// Current BSD flags (`st_flags`) of the item.
    public let flags: UInt32
    public let linkCount: UInt32
}

/// Reaches an item from "/" one component at a time without ever following a symlink.
///
/// Paths must be canonical (as produced by `realpath(3)`): `/var`, `/tmp` and `/etc` are symlinks on macOS, so
/// `/var/folders/…` is refused while `/private/var/folders/…` is accepted. This is intentional — any symlink on
/// the way, planted or not, makes the walk refuse rather than guess.
public enum SafeWalk {
    public static func resolve(_ path: String) throws(SafetyRefusal) -> ResolvedItem {
        let components: [String]
        do {
            components = try PathPolicy.components(of: path)
        } catch {
            throw .invalidPath(error)
        }
        guard let leaf = components.last else { throw .isVolumeRoot }

        do {
            let directory = try walk(to: components.dropLast())
            let info = try directory.statChild(named: leaf)
            return ResolvedItem(
                parent: directory, name: leaf, snapshot: FileSnapshot(info), flags: info.st_flags,
                linkCount: UInt32(info.st_nlink))
        } catch {
            throw refusal(for: error)
        }
    }

    /// Opens a directory by walking every component without following symlinks.
    static func openDirectory(_ path: String) throws(SafetyRefusal) -> OpenDirectory {
        let components: [String]
        do {
            components = try PathPolicy.components(of: path)
        } catch {
            throw .invalidPath(error)
        }
        do {
            return try walk(to: components[...])
        } catch {
            throw refusal(for: error)
        }
    }

    /// Opens the last of `components` normally, passing through the ones before it with search permission only.
    private static func walk(to components: ArraySlice<String>) throws(FileSystemError) -> OpenDirectory {
        var directory = try OpenDirectory(path: "/")
        for (index, component) in components.enumerated() {
            directory =
                index == components.count - 1
                ? try directory.openChild(named: component) : try directory.searchChild(named: component)
        }
        return directory
    }

    static func refusal(for error: FileSystemError) -> SafetyRefusal {
        switch error.code {
        case ENOENT: .notFound
        case EACCES, EPERM: .permissionDenied
        case ELOOP, ENOTDIR: .pathChanged
        default: .ioError(error.code)
        }
    }
}
