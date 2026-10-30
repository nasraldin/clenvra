import CoreGraphics
import Vision

/// How macOS image analysis rates a photo, used to find blurry, dark or otherwise failed shots.
///
/// The score is Vision's aesthetics score (−1 … 1). Measured on Apple wallpapers: originals rate +0.65 … +0.79,
/// blurred or underexposed copies −0.16 … −0.42. Utility images (screenshots, receipts, documents) are never low:
/// they are not meant to be beautiful.
public struct PhotoQuality: Sendable, Hashable {
    /// Scores strictly below this are low. Chosen between the measured originals and degraded copies, close to the
    /// degraded end so that a merely plain photo is not listed; nothing is removed without review.
    public static let lowThreshold: Float = -0.1

    /// Vision's overall aesthetics score, −1 (worst) … 1 (best).
    public let score: Float
    /// Whether Vision considers the image a utility image (screenshot, document, receipt).
    public let isUtility: Bool

    /// Whether the photo is offered as blurry or dark.
    public var isLow: Bool { !isUtility && score < Self.lowThreshold }

    public init(score: Float, isUtility: Bool) {
        self.score = score
        self.isUtility = isUtility
    }

    /// Rates `image` with Vision, or `nil` when analysis fails (the photo is then simply not rated).
    static func measure(_ image: CGImage) async -> PhotoQuality? {
        guard let observation = try? await CalculateImageAestheticsScoresRequest().perform(on: image) else {
            return nil
        }
        return PhotoQuality(score: observation.overallScore, isUtility: observation.isUtility)
    }
}
