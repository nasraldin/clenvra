import ClenvraKit
import SwiftUI

/// Squarified treemap of a folder's children; clicking a folder opens it.
struct StorageTreemap: View {
    let items: [StorageItem]
    let open: (StorageItem) -> Void

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { geometry in
            let rects = layout(in: geometry.size)
            Canvas { context, _ in
                for (item, rect) in zip(items, rects) where rect.width >= 1 && rect.height >= 1 {
                    let tile = rect.insetBy(dx: 1, dy: 1)
                    let shape = Path(roundedRect: tile, cornerRadius: 3)
                    let tint: Color = item.kind == .directory ? .accentColor : .secondary
                    context.fill(shape, with: .color(tint.opacity(item.protection == nil ? 0.35 : 0.15)))
                    context.stroke(shape, with: .color(tint.opacity(0.6)), lineWidth: 0.5)
                    if tile.width > 60, tile.height > 18 {
                        var label = context.resolve(Text(verbatim: item.name).font(.caption))
                        label.shading = .color(.primary)
                        context.draw(label, in: tile.insetBy(dx: 4, dy: 2))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let index = rects.firstIndex(where: { $0.contains(location) }),
                    items[index].kind == .directory
                else { return }
                open(items[index])
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Space map"))
        .accessibilityValue(Text(items.prefix(5).map(\.name).joined(separator: ", ")))
    }

    /// Mirrors horizontally in right-to-left layouts so the largest tile sits at the leading edge.
    private func layout(in size: CGSize) -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: size)
        let rects = TreemapLayout.squarify(sizes: items.map(\.allocatedSize), in: bounds)
        guard layoutDirection == .rightToLeft else { return rects }
        return rects.map { CGRect(x: size.width - $0.maxX, y: $0.minY, width: $0.width, height: $0.height) }
    }
}
