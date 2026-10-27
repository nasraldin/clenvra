import Foundation
import Testing

@testable import ClenvraKit

@Suite("SunburstLayout")
struct SunburstLayoutTests {
    private typealias Node = SunburstLayout.Node

    private static let fullCircle = 2 * Double.pi

    private func leaf(_ path: String, _ size: Int64) -> Node { Node(path: path, size: size) }

    private func span(_ arcs: [SunburstLayout.Arc]) -> Double { arcs.reduce(0) { $0 + $1.angle } }

    /// /r (100) → a (60: a/x 40, a/y 20), b (30), c (10).
    private var tree: Node {
        Node(
            path: "/r", size: 100,
            children: [
                leaf("/r/c", 10), leaf("/r/b", 30),
                Node(path: "/r/a", size: 60, children: [leaf("/r/a/y", 20), leaf("/r/a/x", 40)]),
            ])
    }

    @Test("the first ring covers the full circle, largest first, and starts at angle zero")
    func firstRing() throws {
        let result = SunburstLayout.layout(tree, minimumAngle: 0)

        let ring = try #require(result.rings.first)
        #expect(ring.map(\.path) == ["/r/a", "/r/b", "/r/c"])
        #expect(ring.map(\.depth) == [1, 1, 1])
        #expect(ring.first?.startAngle == 0)
        #expect(abs(span(ring) - Self.fullCircle) < 1e-12)
        #expect(ring.last?.endAngle == Self.fullCircle)
        for (arc, next) in zip(ring, ring.dropFirst()) { #expect(arc.endAngle == next.startAngle) }
        #expect(abs(ring[0].angle - Self.fullCircle * 0.6) < 1e-12)
        #expect(result.totalSize == 100)
        #expect(result.rootPath == "/r")
    }

    @Test("children exactly fill their parent's arc when their sizes add up to it")
    func childrenFillParent() throws {
        let result = SunburstLayout.layout(tree, minimumAngle: 0)

        let parent = try #require(result.rings.first?.first)
        let children = try #require(result.rings.dropFirst().first)
        #expect(children.map(\.path) == ["/r/a/x", "/r/a/y"])
        #expect(children.first?.startAngle == parent.startAngle)
        #expect(children.last?.endAngle == parent.endAngle)
        #expect(abs(span(children) - parent.angle) < 1e-12)
        #expect(children.allSatisfy { $0.depth == 2 })
    }

    @Test("rings stop at the maximum depth")
    func depthLimit() {
        let deep = Node(
            path: "/r", size: 8,
            children: [
                Node(path: "/r/1", size: 8, children: [Node(path: "/r/1/2", size: 8, children: [leaf("/r/1/2/3", 8)])])
            ])

        #expect(SunburstLayout.layout(deep, maximumDepth: 2, minimumAngle: 0).rings.count == 2)
        #expect(SunburstLayout.layout(deep, maximumDepth: 5, minimumAngle: 0).rings.count == 3)
        #expect(SunburstLayout.layout(deep, maximumDepth: 0, minimumAngle: 0).rings.isEmpty)
    }

    @Test("items below the minimum angle are merged into one 'other' arc per parent, placed last")
    func merging() throws {
        let root = Node(
            path: "/r", size: 1000,
            children: [leaf("/r/big", 990), leaf("/r/t1", 4), leaf("/r/t2", 3), leaf("/r/t3", 3)])

        let ring = try #require(SunburstLayout.layout(root, minimumAngle: Self.fullCircle * 0.005).rings.first)

        #expect(ring.count == 2)
        #expect(ring[0].path == "/r/big")
        let other = ring[1]
        #expect(other.kind == .other(count: 3))
        #expect(other.path == "/r")
        #expect(other.size == 10)
        #expect(other.endAngle == Self.fullCircle)
        #expect(other.id != ring[0].id)
    }

    @Test("a single tiny item is kept as itself because merging it would hide nothing")
    func loneTinyItem() throws {
        let root = Node(path: "/r", size: 1000, children: [leaf("/r/big", 999), leaf("/r/tiny", 1)])

        let ring = try #require(SunburstLayout.layout(root, minimumAngle: 0.1).rings.first)

        #expect(ring.map(\.path) == ["/r/big", "/r/tiny"])
        #expect(ring.allSatisfy { $0.kind == .item })
    }

    @Test("children of merged items are not drawn")
    func mergedChildrenHidden() {
        let root = Node(
            path: "/r", size: 100,
            children: [
                leaf("/r/big", 98),
                Node(path: "/r/t1", size: 1, children: [leaf("/r/t1/x", 1)]),
                Node(path: "/r/t2", size: 1, children: [leaf("/r/t2/x", 1)]),
            ])

        let result = SunburstLayout.layout(root, minimumAngle: 0.1)

        #expect(result.rings.count == 1)
    }

    @Test("ties are ordered by path, zero sizes are dropped, and the layout is deterministic")
    func deterministic() throws {
        let root = Node(
            path: "/r", size: 30, children: [leaf("/r/b", 10), leaf("/r/zero", 0), leaf("/r/a", 10), leaf("/r/c", 10)])

        let first = SunburstLayout.layout(root, minimumAngle: 0)

        #expect(first.rings.first?.map(\.path) == ["/r/a", "/r/b", "/r/c"])
        #expect(first == SunburstLayout.layout(root, minimumAngle: 0))
    }

    @Test("children larger than their parent (hard links counted once above) are scaled to fit inside it")
    func oversizedChildren() throws {
        let root = Node(path: "/r", size: 10, children: [leaf("/r/a", 10), leaf("/r/b", 10)])

        let ring = try #require(SunburstLayout.layout(root, minimumAngle: 0).rings.first)

        #expect(abs(span(ring) - Self.fullCircle) < 1e-12)
        #expect(abs(ring[0].angle - Double.pi) < 1e-12)
    }

    @Test("an empty or zero-sized root has no rings")
    func emptyRoot() {
        #expect(SunburstLayout.layout(leaf("/r", 0)).rings.isEmpty)
        #expect(SunburstLayout.layout(leaf("/r", 50)).rings.isEmpty)
        #expect(SunburstLayout.layout(Node(path: "/r", size: 0, children: [leaf("/r/a", 0)])).rings.isEmpty)
    }

    // MARK: - From a storage snapshot

    private func aggregate(_ allocated: Int64, children: [String] = []) -> DirectoryAggregate {
        DirectoryAggregate(
            identity: FileIdentity(device: 1, inode: UInt64(allocated)), allocated: allocated, reclaimable: allocated,
            logical: allocated, fileCount: 0, directoryCount: children.count, latestModification: nil,
            childDirectoryNames: children)
    }

    /// /scan (1000) → Big (600: Inner 600), Small (100); 300 bytes of files directly in /scan.
    private var snapshot: StorageSnapshot {
        StorageSnapshot(
            root: "/scan",
            directories: [
                "/scan": aggregate(1000, children: ["Big", "Small"]),
                "/scan/Big": aggregate(600, children: ["Inner"]),
                "/scan/Big/Inner": aggregate(600),
                "/scan/Small": aggregate(100),
            ],
            largeFiles: [], skipped: [], isComplete: true, subtrees: [:], hardLinks: [:])
    }

    @Test("a snapshot folder's own files become a 'loose files' arc so every ring adds up to its parent")
    func snapshotLooseFiles() throws {
        let result = SunburstLayout.layout(snapshot: snapshot, root: "/scan/", minimumAngle: 0)

        #expect(result.rootPath == "/scan")
        #expect(result.totalSize == 1000)
        let ring = try #require(result.rings.first)
        #expect(ring.map(\.kind) == [.item, .looseFiles, .item])
        #expect(ring.map(\.path) == ["/scan/Big", "/scan", "/scan/Small"])
        #expect(abs(span(ring) - Self.fullCircle) < 1e-12)
        #expect(result.rings.dropFirst().first?.map(\.path) == ["/scan/Big/Inner"])
        #expect(Set(ring.map(\.id)).count == ring.count)
    }

    @Test("a snapshot layout can start below the scanned root and respects the depth limit")
    func snapshotSubfolder() throws {
        let result = SunburstLayout.layout(snapshot: snapshot, root: "/scan/Big", maximumDepth: 1, minimumAngle: 0)

        #expect(result.rings.count == 1)
        #expect(result.rings.first?.map(\.path) == ["/scan/Big/Inner"])
        #expect(result.rings.first?.first?.angle == Self.fullCircle)
    }

    @Test("a root missing from the snapshot gives an empty layout")
    func snapshotMissingRoot() {
        let result = SunburstLayout.layout(snapshot: snapshot, root: "/elsewhere")

        #expect(result.rings.isEmpty)
        #expect(result.totalSize == 0)
    }
}
