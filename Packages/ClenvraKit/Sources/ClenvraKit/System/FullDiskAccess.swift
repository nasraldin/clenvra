import Darwin

/// Guesses whether Clenvra has Full Disk Access, so the Overview can explain why some areas may be skipped.
///
/// macOS offers no API for this; reading a file that only Full Disk Access unlocks is the usual signal.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case notGranted
        /// None of the probe paths exist on this Mac, so the answer cannot be told.
        case unknown
    }

    /// Items macOS protects behind Full Disk Access that exist on most Macs.
    public static func probePaths(home: String) -> [String] {
        [home + "/Library/Safari/Bookmarks.plist", home + "/Library/Containers/com.apple.stocks"]
    }

    /// Opens each path read-only (listing folders): any success means granted; a permission error means not granted.
    public static func probe(paths: [String]) -> Status {
        var denied = false
        for path in paths {
            switch check(path) {
            case .granted: return .granted
            case .notGranted: denied = true
            case .unknown: continue
            }
        }
        return denied ? .notGranted : .unknown
    }

    private static func check(_ path: String) -> Status {
        var info = stat()
        if stat(path, &info) != 0 { return status(for: errno) }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard let directory = opendir(path) else { return status(for: errno) }
            closedir(directory)
            return .granted
        }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return status(for: errno) }
        close(descriptor)
        return .granted
    }

    private static func status(for error: Int32) -> Status {
        error == EPERM || error == EACCES ? .notGranted : .unknown
    }
}
