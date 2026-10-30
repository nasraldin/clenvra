public import Foundation

/// One image in a similar-photo group, with the snapshot that a later removal re-checks before acting on it.
public struct SimilarPhoto: Sendable, Hashable {
    public let path: String
    /// State at listing time; the image is only offered while the file on disk still matches it.
    public let snapshot: FileSnapshot
    /// Logical size in bytes.
    public let size: Int64
    /// Bytes freed by moving only this file away: 0 for a hard-linked file, less for an APFS clone.
    public let reclaimable: Int64
    public let modificationDate: Date
    /// Stored pixel dimensions, before any EXIF rotation.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// How image analysis rated the picture; `nil` when it could not be rated.
    public let quality: PhotoQuality?

    /// Resolution used to suggest which copy to keep.
    public var pixelCount: Int { pixelWidth * pixelHeight }

    public init(
        path: String, snapshot: FileSnapshot, size: Int64, reclaimable: Int64, modificationDate: Date,
        pixelWidth: Int, pixelHeight: Int, quality: PhotoQuality? = nil
    ) {
        self.path = path
        self.snapshot = snapshot
        self.size = size
        self.reclaimable = reclaimable
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.quality = quality
    }
}

/// Images that look alike (not necessarily byte-identical), so the user can review them and keep the best one.
public struct SimilarPhotoGroup: Sendable, Hashable, Identifiable {
    /// The suggested keeper's path at scan time; unique because an image belongs to at most one group.
    public let id: String
    /// At least two images; the suggested keeper comes first, the rest by path.
    public let photos: [SimilarPhoto]
    /// The image kept by default: the most pixels, then the newest, then the smallest path.
    public let suggestedKeeper: String

    /// Space freed by keeping only the suggested image: the sum of every other image's own `reclaimable`.
    public var reclaimableIfOthersRemoved: Int64 {
        photos.reduce(0) { $0 + ($1.path == suggestedKeeper ? 0 : $1.reclaimable) }
    }

    public init(id: String, photos: [SimilarPhoto], suggestedKeeper: String) {
        self.id = id
        self.photos = photos
        self.suggestedKeeper = suggestedKeeper
    }
}

/// What to compare and how strictly.
public struct SimilarPhotoScanOptions: Sendable {
    /// Images whose Vision feature prints are at most this far apart (squared Euclidean distance between unit
    /// vectors, 0 … 4) are similar. See `SimilarPhotoFinder.defaultDistanceThreshold` for why 0.5.
    public var distanceThreshold: Double
    /// Whether names starting with "." and items flagged `UF_HIDDEN` are scanned.
    public var includeHidden: Bool
    /// Folders or files (and everything inside them) that are never scanned.
    public var excludedPaths: Set<String>
    /// Upper bound on images read and analysed at the same time, to keep disks and memory in check.
    public var maximumConcurrentAnalyses: Int
    /// Larger files are skipped (`.tooLarge`), because each analysed file is read into memory whole.
    public var maximumFileSize: Int64

    public init(
        distanceThreshold: Double = SimilarPhotoFinder.defaultDistanceThreshold, includeHidden: Bool = false,
        excludedPaths: Set<String> = [], maximumConcurrentAnalyses: Int = 4,
        maximumFileSize: Int64 = 200 * 1024 * 1024
    ) {
        self.distanceThreshold = distanceThreshold
        self.includeHidden = includeHidden
        self.excludedPaths = excludedPaths
        self.maximumConcurrentAnalyses = maximumConcurrentAnalyses
        self.maximumFileSize = maximumFileSize
    }
}

/// Progress of a similar-photo scan, so the UI can show which stage is running and how far it got.
public struct SimilarPhotoScanProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case listing
        case analyzing
        case grouping
    }

    public var phase: Phase
    /// Files (of any type) seen while listing.
    public var filesSeen: Int
    /// Image files found, the only ones that are read.
    public var imagesFound: Int
    /// Images read and analysed so far, including those that were skipped.
    public var imagesAnalyzed: Int

    public init(phase: Phase, filesSeen: Int, imagesFound: Int, imagesAnalyzed: Int) {
        self.phase = phase
        self.filesSeen = filesSeen
        self.imagesFound = imagesFound
        self.imagesAnalyzed = imagesAnalyzed
    }
}

/// Why a folder or image was left out, so the UI can say what was not compared.
public enum SimilarPhotoSkipReason: Sendable, Hashable {
    /// Could not be opened or read; carries the `errno` (e.g. `EACCES`).
    case unreadable(Int32)
    /// Has an image extension but could not be decoded.
    case notDecodable
    /// Larger than `SimilarPhotoScanOptions.maximumFileSize`.
    case tooLarge
    /// Decoded, but Vision could not compute a feature print.
    case analysisFailed
    /// A folder inside a Photos library, which only Photos may change.
    case insidePhotosLibrary
    /// A folder whose whole contents are protected.
    case protected
}

/// Outcome of a similar-photo scan.
public struct SimilarPhotoScanResult: Sendable {
    /// Groups, largest reclaimable space first.
    public var groups: [SimilarPhotoGroup]
    /// Photos rated blurry, dark or otherwise failed (`PhotoQuality.isLow`), lowest score first. A photo may also be
    /// in a group.
    public var lowQuality: [SimilarPhoto]
    /// Paths left out, each with its reason.
    public var skipped: [String: SimilarPhotoSkipReason]
    /// `false` when the scan was cancelled; `groups` and `lowQuality` then hold no results.
    public var isComplete: Bool

    public init(
        groups: [SimilarPhotoGroup], lowQuality: [SimilarPhoto] = [], skipped: [String: SimilarPhotoSkipReason],
        isComplete: Bool
    ) {
        self.groups = groups
        self.lowQuality = lowQuality
        self.skipped = skipped
        self.isComplete = isComplete
    }
}
