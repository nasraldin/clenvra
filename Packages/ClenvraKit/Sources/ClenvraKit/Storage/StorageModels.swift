public import Foundation

/// What a storage scan covers; the startup volume is scanned at its data volume because "/" would cross firmlinks.
public struct ScanTarget: Sendable, Hashable, Identifiable {
    /// Lets the UI name and badge the target.
    public enum Kind: Sendable, Hashable {
        case home
        case startupVolume
        case volume(Volume.Kind)
    }

    public var id: String { root }
    /// Canonical folder the scan starts at; also the root every deletion from this scan must stay strictly inside.
    public let root: String
    /// Volume name; the UI shows a localized "Home folder" for `.home`.
    public let name: String
    public let kind: Kind

    public init(root: String, name: String, kind: Kind) {
        self.root = root
        self.name = name
        self.kind = kind
    }

    /// Where a volume is scanned: the startup volume at `/System/Volumes/Data`, any other volume at its mount point.
    public static func target(for volume: Volume) -> ScanTarget {
        if volume.isRoot {
            return ScanTarget(root: "/System/Volumes/Data", name: volume.name, kind: .startupVolume)
        }
        return ScanTarget(
            root: StorageScanner.normalize(volume.id.path(percentEncoded: false)), name: volume.name,
            kind: .volume(volume.kind))
    }
}

/// One row in any Storage list (folder browser, Large & Old, Downloads & Screenshots), with what deleting it needs.
public struct StorageItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: FileKind
    /// Bytes on disk (whole subtree for folders).
    public let allocatedSize: Int64
    /// Bytes moving it to the Trash and emptying the Trash would free ("frees ≈").
    public let reclaimableSize: Int64
    /// Bytes of content (whole subtree for folders); breaks ties between equally allocated items.
    public let logicalSize: Int64
    /// Files in the subtree (1 for a file).
    public let fileCount: Int
    /// Folders in the subtree, not counting the item itself.
    public let folderCount: Int
    /// Newest modification inside a folder, or the file's own modification date.
    public let modificationDate: Date?
    /// Why the item can never be deleted; `nil` when it may be selected.
    public let protection: ProtectionReason?
    /// The folder deletions of this item are confined to.
    let ruleRoot: String
    /// The item as the scan saw it, re-checked by the deletion gate.
    let snapshot: FileSnapshot

    public var isSelectable: Bool { protection == nil }

    func deletionItem() -> DeletionItem {
        DeletionItem(
            path: path, ruleRoot: ruleRoot, expected: snapshot, ownerBundleID: nil, freedBytes: reclaimableSize,
            section: .storage)
    }
}

/// How the Downloads & Screenshots review groups files, so related clutter can be judged together.
public enum ClutterKind: Sendable, Hashable, CaseIterable {
    case screenshot, screenRecording, installer, archive, image, video, audio, document, other

    private static let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "mov"]
    private static let screenshotPrefixes = ["Screenshot", "Screen Shot", "لقطة شاشة"]
    private static let recordingPrefixes = ["Screen Recording", "تسجيل الشاشة"]
    private static let extensions: [ClutterKind: Set<String>] = [
        .installer: ["dmg", "pkg", "mpkg", "iso", "xip"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z"],
        .image: ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "webp", "bmp", "svg"],
        .video: ["mov", "mp4", "m4v", "avi", "mkv", "webm"],
        .audio: ["mp3", "m4a", "aac", "wav", "aiff", "flac"],
        .document: [
            "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv", "md",
        ],
    ]

    /// `.screenshot` or `.screenRecording` when the name follows the system's screenshot naming (English or
    /// Arabic), otherwise `nil`; other files in the screenshots folder are the user's and are not listed.
    public static func screenshotKind(forName name: String) -> ClutterKind? {
        let folded = name.precomposedStringWithCanonicalMapping
        let ext = (folded as NSString).pathExtension.lowercased()
        guard screenshotExtensions.contains(ext) else { return nil }
        if recordingPrefixes.contains(where: { folded.hasPrefix($0) }) { return .screenRecording }
        if screenshotPrefixes.contains(where: { folded.hasPrefix($0) }) { return .screenshot }
        return nil
    }

    /// Kind of a file in Downloads, by screenshot name first and then by extension.
    public static func classify(name: String) -> ClutterKind {
        if let kind = screenshotKind(forName: name) { return kind }
        let ext = (name as NSString).pathExtension.lowercased()
        return allCases.first { extensions[$0]?.contains(ext) == true } ?? .other
    }
}

/// Age of a file relative to now, so old clutter stands out.
public enum ClutterAge: Sendable, Hashable, CaseIterable {
    case thisWeek, thisMonth, thisYear, older

    static func of(_ date: Date?, now: Date) -> ClutterAge {
        guard let date else { return .older }
        let days = now.timeIntervalSince(date) / 86_400
        if days < 7 { return .thisWeek }
        if days < 30 { return .thisMonth }
        if days < 365 { return .thisYear }
        return .older
    }
}

/// Where a reviewed file came from.
public enum ClutterSource: Sendable, Hashable {
    case downloads, screenshots
}

/// A file in Downloads or the screenshots folder. Always "Review" risk and never pre-selected.
public struct ClutterItem: Sendable, Hashable, Identifiable {
    public var id: String { item.path }
    public let item: StorageItem
    public let kind: ClutterKind
    public let age: ClutterAge
    public let source: ClutterSource
}

/// A section of the Downloads & Screenshots review.
public struct ClutterGroup: Sendable, Hashable, Identifiable {
    /// What the items have in common.
    public enum Key: Sendable, Hashable {
        case kind(ClutterKind)
        case age(ClutterAge)
    }

    public var id: Key { key }
    public let key: Key
    /// Largest first.
    public let items: [ClutterItem]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.item.allocatedSize } }
}

/// How the Downloads & Screenshots review is grouped.
public enum ClutterGrouping: Sendable, Hashable {
    case kind, age
}

/// "Not modified in" filter of Large & Old files.
public enum LargeFileAge: Sendable, Hashable, CaseIterable {
    case any, sixMonths, oneYear, twoYears

    /// Files modified at or after this date are hidden; `nil` hides nothing.
    func cutoff(now: Date) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        return switch self {
        case .any: nil
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: now)
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: now)
        case .twoYears: calendar.date(byAdding: .year, value: -2, to: now)
        }
    }
}

/// Which Storage list is visible; selection and deletion apply to the visible list only.
public enum StorageList: Sendable, Hashable, CaseIterable {
    case browser, largeFiles, clutter
}
