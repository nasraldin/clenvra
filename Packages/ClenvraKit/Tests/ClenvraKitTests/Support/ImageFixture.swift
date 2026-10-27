import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws small synthetic pictures and writes them as image files, so similar-photo tests need no real photos.
enum ImageFixture {
    enum Scene {
        /// Sky, grass, sun and a tree.
        case landscape
        /// Red and white squares.
        case checkerboard
        /// White nested rectangles on a dark background.
        case frames
    }

    enum Format {
        case png
        case jpeg(quality: Double)

        var type: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            }
        }
    }

    struct Failure: Error {}

    /// Writes `scene` drawn at `width` × `height` pixels to `url`, creating its folder.
    static func write(_ scene: Scene, width: Int, height: Int, format: Format, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = try render(scene, width: width, height: height)
        guard
            let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw Failure() }
        var properties: [CFString: Any] = [:]
        if case .jpeg(let quality) = format { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure() }
    }

    static func render(_ scene: Scene, width: Int, height: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure() }
        // Every scene is drawn on a 400 × 300 canvas, so sizes differ only in resolution.
        context.scaleBy(x: CGFloat(width) / 400, y: CGFloat(height) / 300)
        func fill(_ rect: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, ellipse: Bool = false) {
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            if ellipse { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        switch scene {
        case .landscape:
            fill(CGRect(x: 0, y: 0, width: 400, height: 300), 0.2, 0.5, 0.9)
            fill(CGRect(x: 0, y: 0, width: 400, height: 110), 0.1, 0.6, 0.2)
            fill(CGRect(x: 280, y: 190, width: 70, height: 70), 1, 0.85, 0.1, ellipse: true)
            fill(CGRect(x: 80, y: 110, width: 30, height: 90), 0.5, 0.3, 0.1)
            fill(CGRect(x: 40, y: 170, width: 110, height: 100), 0, 0.4, 0.1, ellipse: true)
        case .checkerboard:
            for column in 0..<8 {
                for row in 0..<6 {
                    let red = (column + row).isMultiple(of: 2)
                    fill(CGRect(x: column * 50, y: row * 50, width: 50, height: 50), 0.9, red ? 0.1 : 1, red ? 0.1 : 1)
                }
            }
        case .frames:
            fill(CGRect(x: 0, y: 0, width: 400, height: 300), 0.05, 0.05, 0.1)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.setLineWidth(6)
            for step in 0..<10 {
                context.stroke(
                    CGRect(x: 20 + step * 15, y: 20 + step * 10, width: 360 - step * 30, height: 260 - step * 20))
            }
        }
        guard let image = context.makeImage() else { throw Failure() }
        return image
    }
}
