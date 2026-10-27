/// Radial (sunburst) layout of a folder tree, kept pure so the Storage map's alternative view can be tested without
/// a view.
///
/// Angles are in radians, measured from 0 to 2π in the direction the view chooses; ring `n` (depth `n`) sits `n`
/// steps out from the centre, which stands for the root. Children are ordered largest first (ties by path) and
/// together span their parent's arc in proportion to their sizes.
public enum SunburstLayout {
    /// Rings drawn by default; deeper levels are reached by making a child the new root.
    public static let defaultMaximumDepth = 4
    /// One degree: about 2.6 points at a 150-point radius, the thinnest wedge that can still be seen and clicked.
    public static let defaultMinimumAngle = Double.pi / 180

    /// One item of the tree to lay out.
    public struct Node: Sendable, Hashable {
        public let path: String
        /// Bytes this item stands for, including its children.
        public let size: Int64
        public let children: [Node]
        /// Stands for the files directly inside the folder at `path`, not for an item of its own.
        public let isLooseFiles: Bool

        public init(path: String, size: Int64, children: [Node] = [], isLooseFiles: Bool = false) {
            self.path = path
            self.size = size
            self.children = children
            self.isLooseFiles = isLooseFiles
        }
    }

    /// One wedge of a ring.
    public struct Arc: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            /// A folder or file; `path` is the item.
            case item
            /// The files directly inside the folder at `path`, which have no ring of their own.
            case looseFiles
            /// `count` items of the folder at `path`, each too thin to show on its own.
            case other(count: Int)
        }

        /// Unique within a layout, so views can animate wedges between layouts.
        public let id: String
        public let kind: Kind
        public let path: String
        /// 1 for the innermost ring.
        public let depth: Int
        public let startAngle: Double
        public let endAngle: Double
        /// Bytes shown by this wedge.
        public let size: Int64

        public var angle: Double { endAngle - startAngle }
    }

    /// A complete layout: the centre and its rings.
    public struct Rings: Sendable, Equatable {
        /// The centre of the chart.
        public let rootPath: String
        /// Bytes that the full circle stands for.
        public let totalSize: Int64
        /// `rings[0]` is depth 1; each ring's arcs are ordered by start angle.
        public let rings: [[Arc]]
    }

    /// Lays out `root`. Items whose wedge would be thinner than `minimumAngle` are merged into one `.other` arc per
    /// parent (a single thin item is kept as itself); merged items and loose files are never expanded further.
    public static func layout(
        _ root: Node, maximumDepth: Int = defaultMaximumDepth, minimumAngle: Double = defaultMinimumAngle
    ) -> Rings {
        var rings: [[Arc]] = []
        place(
            root, depth: 1, start: 0, span: 2 * Double.pi, maximumDepth: maximumDepth, minimumAngle: minimumAngle,
            into: &rings)
        return Rings(rootPath: root.path, totalSize: max(0, root.size), rings: rings)
    }

    /// Lays out the folder `root` of a storage scan by allocated size. Bytes of a folder with subfolders that are not in
    /// any of them become a `.looseFiles` arc, so each such folder's children fill its whole wedge.
    public static func layout(
        snapshot: StorageSnapshot, root: String, maximumDepth: Int = defaultMaximumDepth,
        minimumAngle: Double = defaultMinimumAngle
    ) -> Rings {
        let path = StorageScanner.normalize(root)
        guard let tree = node(at: path, in: snapshot, levels: max(0, maximumDepth)) else {
            return Rings(rootPath: path, totalSize: 0, rings: [])
        }
        return layout(tree, maximumDepth: maximumDepth, minimumAngle: minimumAngle)
    }

    // MARK: - Private

    private static func place(
        _ node: Node, depth: Int, start: Double, span: Double, maximumDepth: Int, minimumAngle: Double,
        into rings: inout [[Arc]]
    ) {
        guard depth <= maximumDepth, span > 0 else { return }
        let children = node.children.filter { $0.size > 0 }.sorted {
            $0.size != $1.size
                ? $0.size > $1.size : ($0.path, $0.isLooseFiles ? 1 : 0) < ($1.path, $1.isLooseFiles ? 1 : 0)
        }
        let childTotal = children.reduce(Int64(0)) { $0 + $1.size }
        // Children can add up to more than their parent when hard-linked data is counted once above them.
        let denominator = Double(max(node.size, childTotal))
        guard denominator > 0, !children.isEmpty else { return }

        var visible = children.filter { span * Double($0.size) / denominator >= minimumAngle }
        var thin = Array(children[visible.count...])
        if thin.count == 1 {
            visible += thin
            thin = []
        }

        if rings.count < depth { rings.append([]) }
        var before: Int64 = 0
        func angle(at offset: Int64) -> Double { start + span * Double(offset) / denominator }

        for child in visible {
            let arcStart = angle(at: before)
            before += child.size
            let arcEnd = angle(at: before)
            let kind: Arc.Kind = child.isLooseFiles ? .looseFiles : .item
            let id = child.isLooseFiles ? "files:" + child.path : "item:" + child.path
            rings[depth - 1].append(
                Arc(
                    id: id, kind: kind, path: child.path, depth: depth, startAngle: arcStart, endAngle: arcEnd,
                    size: child.size))
            if !child.isLooseFiles {
                place(
                    child, depth: depth + 1, start: arcStart, span: arcEnd - arcStart, maximumDepth: maximumDepth,
                    minimumAngle: minimumAngle, into: &rings)
            }
        }
        if !thin.isEmpty {
            let size = thin.reduce(Int64(0)) { $0 + $1.size }
            let arcStart = angle(at: before)
            rings[depth - 1].append(
                Arc(
                    id: "other:" + node.path, kind: .other(count: thin.count), path: node.path, depth: depth,
                    startAngle: arcStart, endAngle: angle(at: before + size), size: size))
        }
    }

    /// The scanned folder at `path` and `levels` levels of subfolders below it.
    private static func node(at path: String, in snapshot: StorageSnapshot, levels: Int) -> Node? {
        guard let aggregate = snapshot.directories[path] else { return nil }
        guard levels > 0 else { return Node(path: path, size: aggregate.allocated) }
        var children = aggregate.childDirectoryNames.compactMap { name in
            node(at: path == "/" ? "/" + name : path + "/" + name, in: snapshot, levels: levels - 1)
        }
        let loose = aggregate.allocated - children.reduce(Int64(0)) { $0 + $1.size }
        // A folder without scanned subfolders is all files; repeating it as one full-width wedge would add nothing.
        if loose > 0, !children.isEmpty { children.append(Node(path: path, size: loose, isLooseFiles: true)) }
        return Node(path: path, size: aggregate.allocated, children: children)
    }
}
