import CoreGraphics
import CoreImage
import Testing

@testable import ClenvraKit

@Suite("PhotoQuality")
struct PhotoQualityTests {
    @Test("a score below the threshold is low")
    func lowScoreIsLow() {
        #expect(PhotoQuality(score: -0.3, isUtility: false).isLow)
    }

    @Test("a utility image (screenshot, receipt) is never low")
    func utilityIsNeverLow() {
        #expect(!PhotoQuality(score: -0.9, isUtility: true).isLow)
    }

    @Test("a good score is not low")
    func goodScoreIsNotLow() {
        #expect(!PhotoQuality(score: 0.7, isUtility: false).isLow)
    }

    @Test("the threshold itself is not low")
    func thresholdIsExclusive() {
        #expect(!PhotoQuality(score: PhotoQuality.lowThreshold, isUtility: false).isLow)
        #expect(!PhotoQuality(score: -0.1, isUtility: false).isLow)
    }

    @Test("blurred and dark copies score lower than the original")
    func scoresDegradedImages() async throws {
        let original = try Self.detailedImage(side: 512)
        let context = CIContext()
        let input = CIImage(cgImage: original)
        let blurred = try Self.render(
            input.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: input.extent), context)
        let dark = try Self.render(
            input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -4]), context)

        let originalQuality = try #require(await PhotoQuality.measure(original))
        let blurredQuality = try #require(await PhotoQuality.measure(blurred))
        let darkQuality = try #require(await PhotoQuality.measure(dark))

        #expect(blurredQuality.score < originalQuality.score)
        #expect(darkQuality.score < originalQuality.score)
    }

    // MARK: - Fixtures

    private struct Failure: Error {}

    private static func render(_ image: CIImage, _ context: CIContext) throws -> CGImage {
        guard let result = context.createCGImage(image, from: image.extent) else { throw Failure() }
        return result
    }

    /// A colourful checkerboard with fine squares, so blurring visibly removes detail.
    private static func detailedImage(side: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure() }
        let cell = 16
        for column in 0..<(side / cell) {
            for row in 0..<(side / cell) {
                let even = (column + row).isMultiple(of: 2)
                let hue = CGFloat(column) / CGFloat(side / cell)
                context.setFillColor(
                    CGColor(red: even ? 0.95 : hue, green: even ? 0.95 : 0.4, blue: even ? 0.9 : 1 - hue, alpha: 1))
                context.fill(CGRect(x: column * cell, y: row * cell, width: cell, height: cell))
            }
        }
        guard let image = context.makeImage() else { throw Failure() }
        return image
    }
}
