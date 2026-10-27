import Foundation

/// The only system locations the privileged helper may act on (`technical-architecture.md` §6a).
///
/// Narrower than anything the app can ask for: the helper refuses every item whose rule root is not exactly one of
/// these folders, or whose shape does not fit the folder (a launch item must be a `.plist` file directly inside its
/// folder, an app a bundle directly inside `/Applications`, a system log a rotated archive).
public struct HelperAllowlist: Sendable {
    enum Shape: Sendable {
        /// Anything inside, at any depth.
        case tree
        /// A `.plist` file directly inside.
        case directPlist
        /// A file directly inside.
        case directFile
        /// A `.app` bundle directly inside.
        case directAppBundle
        /// A rotated, compressed log file at most two levels deep.
        case logArchive
    }

    private struct Root: Sendable {
        let components: [String]
        let shape: Shape
    }

    private static let layout: [(String, Shape)] = [
        ("Library/Caches", .tree),
        ("Library/Logs", .tree),
        ("Library/Application Support", .tree),
        ("Library/LaunchAgents", .directPlist),
        ("Library/LaunchDaemons", .directPlist),
        ("Library/PrivilegedHelperTools", .directFile),
        ("private/var/log", .logArchive),
        ("Applications", .directAppBundle),
    ]

    private static let logArchiveExtensions: Set<String> = ["gz", "bz2", "xz", "zip"]

    private let roots: [Root]

    /// - Parameter systemRoot: "/" in production; a test folder in tests.
    public init(systemRoot: String = "/") {
        let base = systemRoot.hasSuffix("/") ? systemRoot : systemRoot + "/"
        roots = Self.layout.compactMap { relative, shape in
            (try? PathPolicy.components(of: base + relative)).map { Root(components: $0, shape: shape) }
        }
    }

    /// Whether the helper may act on `item`: its rule root is exactly an allowlisted folder and the item fits it.
    public func permits(_ item: DeletionItem) -> Bool {
        guard let rootParts = try? PathPolicy.components(of: item.ruleRoot),
            let root = roots.first(where: { $0.components == rootParts })
        else { return false }
        return fits(item.path, root: root, kind: item.expected.kind)
    }

    /// Whether `item` may be deleted for good: only rotated system logs; everything else goes to the Trash.
    public func permitsIrreversible(_ item: DeletionItem) -> Bool {
        guard permits(item), let rootParts = try? PathPolicy.components(of: item.ruleRoot) else { return false }
        return roots.first { $0.components == rootParts }?.shape == .logArchive
    }

    /// Whether putting an item of `kind` back at `originalPath` would land inside an allowlisted folder.
    public func permitsRestore(originalPath: String, kind: FileKind) -> Bool {
        guard let parts = try? PathPolicy.components(of: originalPath) else { return false }
        return roots.contains { root in
            parts.count > root.components.count && parts.starts(with: root.components)
                && fits(originalPath, root: root, kind: kind)
        }
    }

    private func fits(_ path: String, root: Root, kind: FileKind) -> Bool {
        guard let parts = try? PathPolicy.components(of: path),
            parts.count > root.components.count, parts.starts(with: root.components)
        else { return false }
        let relative = parts.dropFirst(root.components.count)
        let name = relative.last ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        switch root.shape {
        case .tree:
            return true
        case .directPlist:
            return relative.count == 1 && ext == "plist" && kind == .file
        case .directFile:
            return relative.count == 1 && kind == .file
        case .directAppBundle:
            return relative.count == 1 && ext == "app" && kind == .directory
        case .logArchive:
            return relative.count <= 2 && Self.logArchiveExtensions.contains(ext) && kind == .file
        }
    }
}
