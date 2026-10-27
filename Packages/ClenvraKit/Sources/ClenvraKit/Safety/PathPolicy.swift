import Darwin

/// Why a path was refused before any filesystem access.
public enum PathRejection: Error, Sendable, Equatable, Codable {
    case notAbsolute
    case emptyComponent
    case dotComponent
    case controlCharacter
    case tooLong
}

/// Strict, string-level rules every path must pass before Clenvra touches it.
///
/// These checks are deliberately conservative: paths produced by Clenvra's own scanners never contain
/// `.`/`..`, doubled slashes or control characters, so anything that does is treated as hostile or corrupt.
/// String checks are only the first gate; identity checks on open file descriptors follow (see `DeletionGate`).
public enum PathPolicy {
    /// Splits an absolute path into components, rejecting anything ambiguous. "/" yields no components.
    public static func components(of path: String) throws(PathRejection) -> [String] {
        guard path.hasPrefix("/") else { throw .notAbsolute }
        guard path.utf8.count < Int(PATH_MAX) else { throw .tooLong }
        guard !path.unicodeScalars.contains(where: isControl) else { throw .controlCharacter }

        var parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if parts.last == "" { parts.removeLast() }  // a single trailing slash is harmless
        for part in parts {
            if part.isEmpty { throw .emptyComponent }
            if part == "." || part == ".." { throw .dotComponent }
        }
        return parts
    }

    /// True when `path` is below `root` by whole components; a path is never inside itself.
    public static func isStrictlyInside(_ path: String, root: String) throws(PathRejection) -> Bool {
        let pathParts = try components(of: path)
        let rootParts = try components(of: root)
        return pathParts.count > rootParts.count && pathParts.starts(with: rootParts)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}
