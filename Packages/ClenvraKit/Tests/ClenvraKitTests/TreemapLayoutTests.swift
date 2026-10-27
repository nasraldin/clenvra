import CoreGraphics
import Foundation
import Testing

@testable import ClenvraKit

@Suite("TreemapLayout")
struct TreemapLayoutTests {
    private let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)

    private func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

    @Test("rectangles fill the whole area without overlapping or leaving the bounds")
    func fillsArea() {
        let sizes: [Int64] = [600, 300, 200, 120, 80, 50, 30, 10, 5, 5]

        let rects = TreemapLayout.squarify(sizes: sizes, in: bounds)

        #expect(rects.count == sizes.count)
        #expect(abs(rects.map(area).reduce(0, +) - area(bounds)) < 0.5)
        for rect in rects {
            #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect))
        }
        for (index, rect) in rects.enumerated() {
            for other in rects[(index + 1)...] {
                let overlap = rect.intersection(other)
                #expect(overlap.isNull || area(overlap) < 0.01)
            }
        }
    }

    @Test("each rectangle's area is proportional to its size and results keep the input order")
    func proportional() {
        let sizes: [Int64] = [10, 400, 90, 500]
        let total = Double(sizes.reduce(0, +))

        let rects = TreemapLayout.squarify(sizes: sizes, in: bounds)

        for (size, rect) in zip(sizes, rects) {
            #expect(abs(area(rect) - area(bounds) * Double(size) / total) < 0.5)
        }
    }

    @Test("equal sizes in a square become equal squares")
    func squares() {
        let rects = TreemapLayout.squarify(sizes: [1, 1, 1, 1], in: CGRect(x: 0, y: 0, width: 100, height: 100))

        for rect in rects {
            #expect(abs(rect.width - 50) < 0.001 && abs(rect.height - 50) < 0.001)
        }
    }

    @Test("the layout is deterministic, also with ties")
    func deterministic() {
        let sizes: [Int64] = [5, 5, 5, 3, 3, 9, 1]

        #expect(TreemapLayout.squarify(sizes: sizes, in: bounds) == TreemapLayout.squarify(sizes: sizes, in: bounds))
    }

    @Test("zero or negative sizes and empty bounds get empty rectangles")
    func degenerate() {
        #expect(TreemapLayout.squarify(sizes: [], in: bounds).isEmpty)
        let rects = TreemapLayout.squarify(sizes: [0, 10, -3], in: bounds)
        #expect(rects[0] == .zero && rects[2] == .zero)
        #expect(abs(area(rects[1]) - area(bounds)) < 0.5)
        #expect(TreemapLayout.squarify(sizes: [0, 0], in: bounds) == [.zero, .zero])
        #expect(TreemapLayout.squarify(sizes: [4, 2], in: .zero) == [.zero, .zero])
    }
}
