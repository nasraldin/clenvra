import Darwin
import Foundation

/// A fixture syscall failed; the path and the OS error text identify exactly which call failed.
struct FixtureError: Error, CustomStringConvertible {
    let operation: String
    let path: String
    let code: Int32

    var description: String {
        "\(operation) failed at \(path): \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// Builds realistic filesystem fixtures inside a TemporaryDirectory so scanner and safety tests
/// can stage symlinks, hard links, APFS clones, sparse files, BSD flags and permission walls in one line.
struct FixtureBuilder {
    let root: URL

    // MARK: - Creating entries

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let components = try pathComponents(of: relativePath)
        try createDirectories(for: components)
        return url(for: components)
    }

    @discardableResult
    func file(_ relativePath: String, bytes: Int, fill: UInt8 = 0x41) throws -> URL {
        let (components, url) = try resolve(relativePath)
        try createDirectories(for: Array(components.dropLast()))
        let path = url.path(percentEncoded: false)
        let fd = try posixFD("open", path) { open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
        defer { _ = close(fd) }
        // Buffered in chunks so large fixtures never allocate the whole payload at once.
        var remaining = bytes
        while remaining > 0 {
            let chunkLength = min(remaining, 1 << 20)
            let chunk = Data(repeating: fill, count: chunkLength)
            try chunk.withUnsafeBytes { raw in
                guard let start = raw.baseAddress else {
                    throw FixtureError(operation: "write", path: path, code: EINVAL)
                }
                var offset = 0
                while offset < chunkLength {
                    let written = try posix("write", path) { Int(write(fd, start + offset, chunkLength - offset)) }
                    guard written > 0 else {
                        throw FixtureError(operation: "write", path: path, code: EIO)
                    }
                    offset += written
                }
            }
            remaining -= chunkLength
        }
        return url
    }

    @discardableResult
    func sparseFile(_ relativePath: String, logicalSize: Int64) throws -> URL {
        let (components, url) = try resolve(relativePath)
        try createDirectories(for: Array(components.dropLast()))
        let path = url.path(percentEncoded: false)
        let fd = try posixFD("open", path) { open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        defer { _ = close(fd) }
        try posix("ftruncate", path) { ftruncate(fd, logicalSize) }
        return url
    }

    @discardableResult
    func symlink(_ relativePath: String, to target: String) throws -> URL {
        let (components, url) = try resolve(relativePath)
        try createDirectories(for: Array(components.dropLast()))
        let linkPath = url.path(percentEncoded: false)
        // The target is stored verbatim; relative, absolute and dangling targets are all allowed.
        try posix("symlink", linkPath) {
            linkPath.withCString { linkC in
                target.withCString { targetC in
                    Darwin.symlink(targetC, linkC)
                }
            }
        }
        return url
    }

    @discardableResult
    func hardLink(_ relativePath: String, to existingRelativePath: String) throws -> URL {
        let (components, url) = try resolve(relativePath)
        try createDirectories(for: Array(components.dropLast()))
        let existingURL = try resolve(existingRelativePath).url
        let newPath = url.path(percentEncoded: false)
        let existingPath = existingURL.path(percentEncoded: false)
        try posix("link", newPath) {
            existingPath.withCString { existingC in
                newPath.withCString { newC in
                    link(existingC, newC)
                }
            }
        }
        return url
    }

    @discardableResult
    func clone(_ relativePath: String, of existingRelativePath: String) throws -> URL {
        let (components, url) = try resolve(relativePath)
        try createDirectories(for: Array(components.dropLast()))
        let existingURL = try resolve(existingRelativePath).url
        let newPath = url.path(percentEncoded: false)
        let existingPath = existingURL.path(percentEncoded: false)
        try posix("clonefile", newPath) {
            existingPath.withCString { existingC in
                newPath.withCString { newC in
                    clonefile(existingC, newC, 0)
                }
            }
        }
        return url
    }

    // MARK: - Mutating entries

    func setFlags(_ relativePath: String, _ flags: UInt32) throws {
        let path = try resolve(relativePath).url.path(percentEncoded: false)
        try posix("lchflags", path) {
            path.withCString { lchflags($0, flags) }
        }
    }

    func setPermissions(_ relativePath: String, _ mode: mode_t) throws {
        let path = try resolve(relativePath).url.path(percentEncoded: false)
        do {
            try posix("fchmodat", path) {
                path.withCString { fchmodat(AT_FDCWD, $0, mode, AT_SYMLINK_NOFOLLOW) }
            }
        } catch let error as FixtureError where [EINVAL, ENOSYS, ENOTSUP].contains(error.code) {
            var entry = stat()
            guard lstat(path, &entry) == 0 else {
                throw FixtureError(operation: "lstat", path: path, code: errno)
            }
            // Without AT_SYMLINK_NOFOLLOW support, chmod would follow a symlink, so refuse
            // to fall back for one rather than changing the target's permissions by accident.
            guard (entry.st_mode & S_IFMT) != S_IFLNK else {
                throw FixtureError(operation: "setPermissions", path: path, code: error.code)
            }
            try posix("chmod", path) { chmod(path, mode) }
        }
    }

    func setModificationDate(_ relativePath: String, _ date: Date) throws {
        let path = try resolve(relativePath).url.path(percentEncoded: false)
        // UTIME_OMIT in tv_nsec leaves the access time unchanged.
        let times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0),
        ]
        try posix("utimensat", path) {
            times.withUnsafeBufferPointer { buffer in
                path.withCString { pathC in
                    utimensat(AT_FDCWD, pathC, buffer.baseAddress, AT_SYMLINK_NOFOLLOW)
                }
            }
        }
    }

    /// Resolves a relative fixture path inside the scratch root without touching the filesystem.
    func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    // MARK: - Path resolution

    /// Splits and validates a relative path so fixtures can never escape the scratch root.
    private func pathComponents(of relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw FixtureError(operation: "resolvePath", path: relativePath, code: EINVAL)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else {
            throw FixtureError(operation: "resolvePath", path: relativePath, code: EINVAL)
        }
        for component in components where component == "." || component == ".." {
            throw FixtureError(operation: "resolvePath", path: relativePath, code: EINVAL)
        }
        return components
    }

    private func url(for components: [String]) -> URL {
        var result = root
        for component in components {
            result.append(component: component)
        }
        return result
    }

    private func resolve(_ relativePath: String) throws -> (components: [String], url: URL) {
        let components = try pathComponents(of: relativePath)
        return (components, url(for: components))
    }

    // MARK: - Syscall plumbing

    private func posixFD(_ operation: String, _ path: String, _ call: () -> Int32) throws -> Int32 {
        let fd = call()
        guard fd != -1 else {
            throw FixtureError(operation: operation, path: path, code: errno)
        }
        return fd
    }

    @discardableResult
    private func posix(_ operation: String, _ path: String, _ call: () -> Int32) throws -> Int32 {
        let result = call()
        guard result != -1 else {
            throw FixtureError(operation: operation, path: path, code: errno)
        }
        return result
    }

    @discardableResult
    private func posix(_ operation: String, _ path: String, _ call: () -> Int) throws -> Int {
        let result = call()
        guard result != -1 else {
            throw FixtureError(operation: operation, path: path, code: errno)
        }
        return result
    }

    /// Creates each missing path component as a directory, tolerating components that already exist.
    private func createDirectories(for components: [String]) throws {
        var current = root
        for component in components {
            current = current.appending(component: component)
            let path = current.path(percentEncoded: false)
            if mkdir(path, 0o755) == -1 {
                guard errno == EEXIST else {
                    throw FixtureError(operation: "mkdir", path: path, code: errno)
                }
                var entry = stat()
                guard stat(path, &entry) == 0, (entry.st_mode & S_IFMT) == S_IFDIR else {
                    throw FixtureError(operation: "mkdir (non-directory in path)", path: path, code: errno)
                }
            }
        }
    }
}
