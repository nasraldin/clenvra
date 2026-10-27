import ClenvraKit
import SwiftUI

/// Rings of the current folder's subfolders, four levels deep; clicking a folder opens it, clicking the centre goes
/// up. The alternative to `StorageTreemap`, with the same colours.
///
/// Angles run clockwise from the top in every language: a chart is not text, so it is not mirrored in right-to-left
/// layouts (only the surrounding controls are).
struct StorageSunburst: View {
    let session: StorageSession

    @State private var rings: SunburstLayout.Rings?
    @State private var hovered: Target?
    @State private var pointer = CGPoint.zero

    var body: some View {
        GeometryReader { proxy in
            let geometry = SunburstGeometry(size: proxy.size, ringCount: rings?.rings.count ?? 0)
            ZStack {
                if let rings {
                    chart(rings: rings, geometry: geometry)
                    centre(rings: rings, geometry: geometry)
                    tooltip(in: proxy.size)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    pointer = location
                    hovered = rings.flatMap { geometry.target(at: location, in: $0) }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                guard let rings, let target = geometry.target(at: location, in: rings) else { return }
                activate(target, rings: rings)
            }
            .pointerStyle(
                hovered?.isClickable(currentPath: session.currentPath, canGoUp: session.canGoUp) == true ? .link : nil
            )
            // Coordinates and angles stay left-to-right; the chart itself is never mirrored.
            .environment(\.layoutDirection, .leftToRight)
        }
        .task(
            id: LayoutKey(root: session.snapshot?.root, path: session.currentPath, aggregate: session.currentAggregate)
        ) {
            await relayout()
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Space map"))
        .accessibilityValue(Text(firstRingNames))
    }

    // MARK: - Drawing

    private func chart(rings: SunburstLayout.Rings, geometry: SunburstGeometry) -> some View {
        Canvas { context, _ in
            let separator = Color(nsColor: .windowBackgroundColor)
            for ring in rings.rings {
                for arc in ring {
                    let wedge = geometry.wedge(for: arc)
                    let isHovered = hovered == .arc(arc)
                    context.fill(wedge, with: .color(Self.fill(for: arc, isHovered: isHovered)))
                    context.stroke(wedge, with: .color(separator), lineWidth: 1)
                }
            }
            let centre = Path(ellipseIn: geometry.centreRect)
            context.fill(centre, with: .color(.secondary.opacity(hovered == .centre ? 0.2 : 0.1)))
        }
    }

    /// The treemap's colours: folders in the accent colour, files in grey, fainter the farther out.
    private static func fill(for arc: SunburstLayout.Arc, isHovered: Bool) -> Color {
        switch arc.kind {
        case .item:
            let base = max(0.2, 0.5 - 0.08 * Double(arc.depth - 1))
            return Color.accentColor.opacity(isHovered ? base + 0.3 : base)
        case .looseFiles:
            return Color.secondary.opacity(isHovered ? 0.5 : 0.3)
        case .other:
            return Color.secondary.opacity(0.15)
        }
    }

    private func centre(rings: SunburstLayout.Rings, geometry: SunburstGeometry) -> some View {
        VStack(spacing: 2) {
            if session.canGoUp {
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: Self.name(of: rings.rootPath))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(rings.totalSize, format: .byteCount(style: .file))
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: max(0, geometry.centreRadius * 1.8))
        .position(geometry.centre)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func tooltip(in size: CGSize) -> some View {
        if case .arc(let arc) = hovered {
            VStack(alignment: .leading, spacing: 2) {
                title(of: arc)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(arc.size, format: .byteCount(style: .file))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 240, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
            .position(
                x: min(max(pointer.x + 70, 80), max(80, size.width - 80)),
                y: min(max(pointer.y - 26, 20), max(20, size.height - 20))
            )
            .allowsHitTesting(false)
        }
    }

    private func title(of arc: SunburstLayout.Arc) -> Text {
        switch arc.kind {
        case .item: Text(verbatim: Self.name(of: arc.path))
        case .looseFiles: Text("Files in \(Self.name(of: arc.path))")
        case .other(let count): Text("\(count) smaller items")
        }
    }

    // MARK: - Behaviour

    private func activate(_ target: Target, rings: SunburstLayout.Rings) {
        switch target {
        case .centre:
            Task { await session.goUp() }
        case .arc(let arc):
            guard target.isClickable(currentPath: session.currentPath, canGoUp: session.canGoUp) else { return }
            Task { await session.open(arc.path) }
        }
    }

    /// The layout walks the scan's folder tree, so it runs off the main thread.
    private func relayout() async {
        guard let snapshot = session.snapshot else {
            rings = nil
            return
        }
        let path = session.currentPath
        let layout = await Task.detached(priority: .userInitiated) {
            SunburstLayout.layout(snapshot: snapshot, root: path)
        }.value
        guard !Task.isCancelled else { return }
        hovered = nil
        rings = layout
    }

    private var firstRingNames: String {
        (rings?.rings.first ?? []).prefix(5).compactMap { arc -> String? in
            if case .item = arc.kind { return Self.name(of: arc.path) }
            return nil
        }
        .joined(separator: ", ")
    }

    private static func name(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    // MARK: - Types

    private struct LayoutKey: Hashable {
        let root: String?
        let path: String
        let aggregate: DirectoryAggregate?
    }

    fileprivate enum Target: Equatable {
        case centre
        case arc(SunburstLayout.Arc)

        /// Folders open (also the files of a subfolder, which open that folder); "other" wedges do nothing.
        func isClickable(currentPath: String, canGoUp: Bool) -> Bool {
            switch self {
            case .centre: canGoUp
            case .arc(let arc):
                switch arc.kind {
                case .item: true
                case .looseFiles: arc.path != currentPath
                case .other: false
                }
            }
        }
    }
}

/// Where the centre and each ring sit for a given size; angle 0 is at the top, increasing clockwise.
private struct SunburstGeometry {
    let centre: CGPoint
    let centreRadius: CGFloat
    let ringWidth: CGFloat

    init(size: CGSize, ringCount: Int) {
        centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(0, min(size.width, size.height) / 2 - 4)
        // The centre is as wide as one ring and a half, so the folder name fits.
        ringWidth = radius / (CGFloat(max(ringCount, 1)) + 1.5)
        centreRadius = ringWidth * 1.5
    }

    var centreRect: CGRect {
        CGRect(
            x: centre.x - centreRadius, y: centre.y - centreRadius, width: centreRadius * 2, height: centreRadius * 2)
    }

    func innerRadius(depth: Int) -> CGFloat { centreRadius + CGFloat(depth - 1) * ringWidth }

    func point(radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(x: centre.x + radius * CGFloat(sin(angle)), y: centre.y - radius * CGFloat(cos(angle)))
    }

    func wedge(for arc: SunburstLayout.Arc) -> Path {
        let inner = innerRadius(depth: arc.depth)
        let outer = inner + ringWidth
        // About one point per two degrees: smooth at this size, cheap to draw.
        let steps = max(2, Int((arc.angle / (2 * Double.pi)) * 180))
        var path = Path()
        for step in 0...steps {
            let angle = arc.startAngle + arc.angle * Double(step) / Double(steps)
            let point = point(radius: outer, angle: angle)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        for step in (0...steps).reversed() {
            path.addLine(to: point(radius: inner, angle: arc.startAngle + arc.angle * Double(step) / Double(steps)))
        }
        path.closeSubpath()
        return path
    }

    fileprivate func target(at location: CGPoint, in rings: SunburstLayout.Rings) -> StorageSunburst.Target? {
        let dx = Double(location.x - centre.x)
        let dy = Double(location.y - centre.y)
        let distance = CGFloat((dx * dx + dy * dy).squareRoot())
        if distance <= centreRadius { return .centre }
        guard ringWidth > 0 else { return nil }
        let depth = Int((distance - centreRadius) / ringWidth) + 1
        guard depth >= 1, depth <= rings.rings.count else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * Double.pi }
        return rings.rings[depth - 1].first { $0.startAngle <= angle && angle < $0.endAngle }.map { .arc($0) }
    }
}
