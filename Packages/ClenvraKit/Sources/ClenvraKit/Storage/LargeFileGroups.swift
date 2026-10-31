public import Foundation

/// How the Large & Old list is grouped.
public enum LargeFileGrouping: Sendable, Hashable, CaseIterable {
    case kind, folder, age
}

/// What a large file is: by its extension, else by where it is (developer folders, caches).
public enum LargeFileKind: Sendable, Hashable, CaseIterable {
    case video, image, audio, archive, diskImage, app, document, developer, cache, other

    private static let extensions: [LargeFileKind: Set<String>] = [
        .video: ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "flv", "mts", "m2ts", "3gp"],
        .image: [
            "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "svg", "raw", "dng", "cr2",
            "cr3", "nef", "arw", "psd", "exr",
        ],
        .audio: ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "ogg", "opus", "caf", "logicx"],
        .developer: [
            "dylib", "a", "o", "so", "jar", "aar", "war", "class", "pack", "idx", "wasm", "node", "dex", "pdb",
            "xcarchive", "dsym",
        ],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "rar", "7z", "zst", "lz", "lzma", "cpio"],
        .diskImage: ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "vdi", "qcow2", "vhd", "vhdx"],
        .app: ["app", "pkg", "mpkg", "ipa", "apk", "xip", "ipsw"],
        .document: [
            "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv", "md",
            "epub", "json", "xml", "log", "sql", "db", "sqlite",
        ],
    ]

    /// Folders whose files are build output, dependencies or debug data.
    private static let developerFolders = [
        "/.git/", "/node_modules/", "/Library/Developer/", ".dSYM/", "/DerivedData/", "/.gradle/", "/Pods/",
        "/.build/", "/target/debug/", "/target/release/",
    ]
    private static let cacheFolders = ["/Library/Caches/", "/.cache/", "/Caches/"]

    public static func classify(name: String) -> LargeFileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        return allCases.first { extensions[$0]?.contains(ext) == true } ?? .other
    }

    /// The extension decides first; a file it does not place is a developer file or a cache by its folder.
    public static func classify(path: String) -> LargeFileKind {
        let byName = classify(name: (path as NSString).lastPathComponent)
        guard byName == .other else { return byName }
        if developerFolders.contains(where: path.contains) { return .developer }
        if cacheFolders.contains(where: path.contains) { return .cache }
        return .other
    }
}

/// How long ago a large file last changed.
public enum LargeFileAgeBucket: Sendable, Hashable, CaseIterable {
    case underSixMonths, sixToTwelveMonths, oneToTwoYears, overTwoYears
    /// No modification date.
    case unknown

    static func of(_ date: Date?, now: Date) -> LargeFileAgeBucket {
        guard let date else { return .unknown }
        let calendar = Calendar(identifier: .gregorian)
        func ago(_ component: Calendar.Component, _ value: Int) -> Date {
            calendar.date(byAdding: component, value: -value, to: now) ?? now
        }
        if date > ago(.month, 6) { return .underSixMonths }
        if date > ago(.year, 1) { return .sixToTwelveMonths }
        if date > ago(.year, 2) { return .oneToTwoYears }
        return .overTwoYears
    }

    /// Display order: oldest first, unknown last.
    fileprivate var order: Int {
        switch self {
        case .overTwoYears: 0
        case .oneToTwoYears: 1
        case .sixToTwelveMonths: 2
        case .underSixMonths: 3
        case .unknown: 4
        }
    }
}

/// Large files that belong together: one kind, one folder or one age.
public struct LargeFileGroup: Sendable, Hashable, Identifiable {
    public enum Key: Sendable, Hashable {
        case kind(LargeFileKind)
        /// The top folder under the scanned folder, or the scanned folder itself for files directly in it.
        case folder(String)
        case age(LargeFileAgeBucket)
    }

    public var id: String {
        switch key {
        case .kind(let kind): "kind:\(kind)"
        case .folder(let path): "folder:" + path
        case .age(let age): "age:\(age)"
        }
    }

    public let key: Key
    /// Largest first.
    public let items: [StorageItem]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }

    public init(key: Key, items: [StorageItem]) {
        self.key = key
        self.items = items
    }
}

public enum LargeFileGroups {
    /// Groups `files` (already filtered). Kind and folder groups are largest first; age groups are oldest first.
    /// `root` is the scanned folder, for folder grouping.
    public static func groups(
        _ files: [StorageItem], by grouping: LargeFileGrouping, root: String, now: Date = Date()
    ) -> [LargeFileGroup] {
        var buckets: [LargeFileGroup.Key: [StorageItem]] = [:]
        for file in files {
            buckets[key(of: file, by: grouping, root: root, now: now), default: []].append(file)
        }
        let groups = buckets.map { key, items in
            LargeFileGroup(
                key: key,
                items: items.sorted { lhs, rhs in
                    lhs.allocatedSize != rhs.allocatedSize ? lhs.allocatedSize > rhs.allocatedSize : lhs.path < rhs.path
                })
        }
        return groups.sorted { lhs, rhs in
            if case .age(let a) = lhs.key, case .age(let b) = rhs.key { return a.order < b.order }
            return lhs.totalBytes != rhs.totalBytes ? lhs.totalBytes > rhs.totalBytes : lhs.id < rhs.id
        }
    }

    static func key(
        of file: StorageItem, by grouping: LargeFileGrouping, root: String, now: Date
    ) -> LargeFileGroup.Key {
        switch grouping {
        case .kind: .kind(LargeFileKind.classify(path: file.path))
        case .age: .age(LargeFileAgeBucket.of(file.modificationDate, now: now))
        case .folder: .folder(topFolder(of: file.path, root: root))
        }
    }

    /// `root/<first component>` when `path` is in a subfolder of `root`, otherwise `root` (or the parent folder for
    /// a path outside `root`).
    static func topFolder(of path: String, root: String) -> String {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        let prefix = base + "/"
        guard path.hasPrefix(prefix) else { return (path as NSString).deletingLastPathComponent }
        let components = path.dropFirst(prefix.count).split(separator: "/")
        guard components.count > 1, let first = components.first else { return base.isEmpty ? "/" : base }
        return prefix + first
    }
}
