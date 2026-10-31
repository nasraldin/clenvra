import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A square Quick Look thumbnail of an image file, generated off the main thread and cached for the session.
struct PhotoThumbnail: View {
    let path: String
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Image(nsImage: IconCache.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
                    .padding(side / 5)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) { await load() }
    }

    private func load() async {
        let key = "\(Int(side * displayScale))|\(path)" as NSString
        if let cached = ThumbnailCache.shared.object(forKey: key) {
            image = cached
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(filePath: path), size: CGSize(width: side, height: side), scale: displayScale,
            representationTypes: .thumbnail)
        guard let cgImage = await Self.generate(request), !Task.isCancelled else {
            didFail = !Task.isCancelled
            return
        }
        let thumbnail = NSImage(cgImage: cgImage, size: .zero)
        ThumbnailCache.shared.setObject(thumbnail, forKey: key)
        image = thumbnail
    }

    /// Quick Look renders on its own queues; only the finished bitmap comes back.
    nonisolated private static func generate(_ request: QLThumbnailGenerator.Request) async -> CGImage? {
        await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }
}

/// Thumbnails already generated, so scrolling back does not render them again. Evicted under memory pressure.
@MainActor
private enum ThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()
}
