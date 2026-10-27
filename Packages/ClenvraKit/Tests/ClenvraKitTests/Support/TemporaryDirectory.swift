import Foundation

/// A unique scratch directory for one test; removed when the owner is deallocated.
/// All filesystem tests work only inside one of these, never in real user folders.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        let requested = FileManager.default.temporaryDirectory
            .appending(path: "ClenvraTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        // Canonical path (/private/var/…, not /var/…): Clenvra's safe walk refuses symlinked ancestors such as /var.
        guard let canonical = realpath(requested.path(percentEncoded: false), nil) else {
            throw POSIXError(.ENOENT)
        }
        defer { free(canonical) }
        url = URL(filePath: String(cString: canonical), directoryHint: .isDirectory)
    }

    deinit {
        // BSD flags (e.g. UF_IMMUTABLE) block deletion even for the owner, and chmod-000 folders cannot be listed,
        // so both are reset first. Symlinks are skipped: chmod would follow them and change the link's target,
        // which may be outside the scratch directory.
        let path = url.path(percentEncoded: false)
        lchflags(path, 0)
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in enumerator {
                let entry = url.appending(path: relative).path(percentEncoded: false)
                var info = stat()
                guard lstat(entry, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { continue }
                lchflags(entry, 0)
                chmod(entry, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}
