public import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk), kept pure so the Storage map can be tested without a view.
public enum TreemapLayout {
    /// One rectangle per size, in input order, whose areas are proportional to the sizes and together fill `bounds`.
    /// Sizes of zero or less get `.zero`. Ties are broken by input order, so the same input always gives the same
    /// layout.
    public static func squarify(sizes: [Int64], in bounds: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: sizes.count)
        let total = sizes.reduce(0.0) { $0 + Double(max($1, 0)) }
        let boundsArea = Double(bounds.width) * Double(bounds.height)
        guard total > 0, boundsArea > 0 else { return result }

        let scale = boundsArea / total
        let order = sizes.indices.filter { sizes[$0] > 0 }.sorted {
            sizes[$0] != sizes[$1] ? sizes[$0] > sizes[$1] : $0 < $1
        }
        let areas = order.map { (index: $0, area: Double(sizes[$0]) * scale) }

        var remaining = bounds
        var row: [(index: Int, area: Double)] = []
        for item in areas {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [item], side: side) <= worst(row, side: side) {
                row.append(item)
            } else {
                remaining = place(row, in: remaining, into: &result)
                row = [item]
            }
        }
        if !row.isEmpty { _ = place(row, in: remaining, into: &result) }
        return result
    }

    /// The largest aspect ratio in a row laid along a side of length `side`; lower is squarer.
    private static func worst(_ row: [(index: Int, area: Double)], side: Double) -> Double {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, side > 0, let largest = row.map(\.area).max(), let smallest = row.map(\.area).min(),
            smallest > 0
        else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }

    /// Lays `row` along the shorter side of `rect` and returns the space left over.
    private static func place(_ row: [(index: Int, area: Double)], in rect: CGRect, into result: inout [CGRect])
        -> CGRect
    {
        let sum = row.reduce(0) { $0 + $1.area }
        if rect.width >= rect.height {
            // A column on the leading side, items stacked top to bottom.
            let width = rect.height > 0 ? sum / Double(rect.height) : 0
            var y = Double(rect.minY)
            for (offset, item) in row.enumerated() {
                let isLast = offset == row.count - 1
                let height = isLast ? Double(rect.maxY) - y : (width > 0 ? item.area / width : 0)
                result[item.index] = CGRect(x: Double(rect.minX), y: y, width: width, height: height)
                y += height
            }
            return CGRect(
                x: Double(rect.minX) + width, y: Double(rect.minY), width: max(0, Double(rect.width) - width),
                height: Double(rect.height))
        } else {
            // A row along the top, items placed leading to trailing.
            let height = rect.width > 0 ? sum / Double(rect.width) : 0
            var x = Double(rect.minX)
            for (offset, item) in row.enumerated() {
                let isLast = offset == row.count - 1
                let width = isLast ? Double(rect.maxX) - x : (height > 0 ? item.area / height : 0)
                result[item.index] = CGRect(x: x, y: Double(rect.minY), width: width, height: height)
                x += width
            }
            return CGRect(
                x: Double(rect.minX), y: Double(rect.minY) + height, width: Double(rect.width),
                height: max(0, Double(rect.height) - height))
        }
    }
}
