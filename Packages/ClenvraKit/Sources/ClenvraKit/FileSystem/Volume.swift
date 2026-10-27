public import Foundation

/// Represents a user-visible storage volume for capacity reporting and cleanup analysis in overview screens.
public struct Volume: Sendable, Hashable, Identifiable {
    /// Distinguishes storage media categories so the user interface can display appropriate icons and warnings.
    public enum Kind: Sendable, Hashable {
        /// Identifies fixed internal storage where operating system files and primary user data reside.
        case `internal`
        /// Identifies removable physical media or disk images attached to the local machine.
        case external
        /// Identifies remote shares that may incur network latency and require distinct handling.
        case network
        /// Identifies virtual disk images when detectable from volume metadata.
        case diskImage
        /// Fallback for storage devices whose locality or transport could not be determined.
        case other
    }

    /// Serves as the stable identifier and filesystem mount point for volume operations.
    public let id: URL
    /// Provides the user-facing display name matching Finder and System Settings.
    public let name: String
    /// Informs user presentation and safety rules about the media backing this volume.
    public let kind: Kind
    /// Enables filesystem-specific features such as APFS snapshotting or clone detection.
    public let fileSystem: String?
    /// Distinguishes the startup volume from secondary drives to prevent accidental disruption.
    public let isRoot: Bool
    /// Prevents attempting deletion or cleanup actions on write-protected filesystems.
    public let isReadOnly: Bool
    /// Indicates whether the volume can be unmounted or ejected by the user.
    public let isEjectable: Bool
    /// Establishes the upper bound for storage bar gauges and usage percentages.
    public let totalCapacity: Int64
    /// Matches standard Finder available space without accounting for purgeable files.
    public let availableCapacity: Int64
    /// Reflects maximum available space when macOS purges eligible system caches.
    public let availableForImportantUsage: Int64?

    /// Supplies non-negative consumed byte count for progress gauges and breakdown charts.
    public var usedCapacity: Int64 {
        max(0, totalCapacity - availableCapacity)
    }

    /// Quantifies reclaimable cache space that macOS can free automatically under pressure.
    public var purgeableEstimate: Int64 {
        guard let important = availableForImportantUsage else {
            return 0
        }
        return max(0, important - availableCapacity)
    }

    /// Creates an immutable volume snapshot with validated capacity values.
    public init(
        id: URL,
        name: String,
        kind: Kind,
        fileSystem: String?,
        isRoot: Bool,
        isReadOnly: Bool,
        isEjectable: Bool,
        totalCapacity: Int64,
        availableCapacity: Int64,
        availableForImportantUsage: Int64?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fileSystem = fileSystem
        self.isRoot = isRoot
        self.isReadOnly = isReadOnly
        self.isEjectable = isEjectable
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
    }
}

extension Volume: Comparable {
    /// Orders the startup root volume ahead of secondary volumes, then sorts by localized name.
    public static func < (lhs: Volume, rhs: Volume) -> Bool {
        if lhs.isRoot != rhs.isRoot {
            return lhs.isRoot && !rhs.isRoot
        }
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return lhs.id.path < rhs.id.path
    }
}

/// Discovers and filters mounted storage devices to present user-visible filesystems.
public enum VolumeInventory {
    /// Isolates filesystem resource values so volume classification logic can be tested in isolation.
    public struct RawValues: Sendable {
        /// Identifies the mount path of the target volume.
        public var url: URL
        /// Stores the localized or primary volume name for display.
        public var name: String?
        /// Indicates whether the volume is backed by non-removable internal hardware.
        public var isInternal: Bool?
        /// Differentiates local storage hardware from remote network mounts.
        public var isLocal: Bool?
        /// Flags media that can be physically detached or disconnected by the user.
        public var isRemovable: Bool?
        /// Flags volumes that support programmatic or user-initiated unmounting.
        public var isEjectable: Bool?
        /// Marks the designated boot filesystem volume hosting macOS.
        public var isRootFileSystem: Bool?
        /// Protects read-only filesystems from modification attempts.
        public var isReadOnly: Bool?
        /// Hides internal macOS service volumes that should not appear in user inventories.
        public var isBrowsable: Bool?
        /// Identifies virtual disk image mounts when known or specified.
        public var isDiskImage: Bool?
        /// Records filesystem driver format for capability checks.
        public var fileSystemTypeName: String?
        /// Establishes the total disk size in bytes.
        public var totalCapacity: Int64?
        /// Establishes immediately available storage space in bytes.
        public var availableCapacity: Int64?
        /// Reports available space when purgeable caches are considered.
        public var availableForImportantUsage: Int64?

        /// Assembles raw volume attributes with defaults for unit testing and mocked scenarios.
        public init(
            url: URL,
            name: String? = nil,
            isInternal: Bool? = nil,
            isLocal: Bool? = nil,
            isRemovable: Bool? = nil,
            isEjectable: Bool? = nil,
            isRootFileSystem: Bool? = nil,
            isReadOnly: Bool? = nil,
            isBrowsable: Bool? = nil,
            isDiskImage: Bool? = nil,
            fileSystemTypeName: String? = nil,
            totalCapacity: Int64? = nil,
            availableCapacity: Int64? = nil,
            availableForImportantUsage: Int64? = nil
        ) {
            self.url = url
            self.name = name
            self.isInternal = isInternal
            self.isLocal = isLocal
            self.isRemovable = isRemovable
            self.isEjectable = isEjectable
            self.isRootFileSystem = isRootFileSystem
            self.isReadOnly = isReadOnly
            self.isBrowsable = isBrowsable
            self.isDiskImage = isDiskImage
            self.fileSystemTypeName = fileSystemTypeName
            self.totalCapacity = totalCapacity
            self.availableCapacity = availableCapacity
            self.availableForImportantUsage = availableForImportantUsage
        }

        /// Extracts volume resource values from Foundation URL cache without triggering disk I/O.
        public init(url: URL, values: URLResourceValues) {
            self.url = url
            self.name = values.volumeLocalizedName ?? values.volumeName
            self.isInternal = values.volumeIsInternal
            self.isLocal = values.volumeIsLocal
            self.isRemovable = values.volumeIsRemovable
            self.isEjectable = values.volumeIsEjectable
            self.isRootFileSystem = values.volumeIsRootFileSystem
            self.isReadOnly = values.volumeIsReadOnly
            self.isBrowsable = values.volumeIsBrowsable
            self.isDiskImage = nil
            self.fileSystemTypeName = values.volumeTypeName
            self.totalCapacity = values.volumeTotalCapacity.map(Int64.init)
            self.availableCapacity = values.volumeAvailableCapacity.map(Int64.init)
            self.availableForImportantUsage = values.volumeAvailableCapacityForImportantUsage
        }
    }

    /// Converts raw volume attributes into a validated volume, discarding hidden system mounts.
    ///
    /// Disk images mounted via diskutil or hdiutil expose URL resource values identical to external removable drives
    /// (`volumeIsLocal == true`, `volumeIsInternal == nil`, `volumeIsRemovable == true`). Because public URL keys do not
    /// report virtual transport bus details, disk images map consistently to `.external` unless explicitly marked.
    public static func makeVolume(_ raw: RawValues) -> Volume? {
        guard let totalCapacity = raw.totalCapacity, totalCapacity > 0 else {
            return nil
        }
        if raw.isBrowsable == false {
            return nil
        }
        let path = raw.url.path
        if path.hasPrefix("/System/Volumes") || path == "/Volumes/Recovery" {
            return nil
        }
        let companionNames: Set<String> = ["preboot", "vm", "recovery", "update", "hardware", "xarts", "iscpreboot"]
        if raw.isInternal == true, let name = raw.name?.lowercased(), companionNames.contains(name) {
            return nil
        }

        let isRoot = path == "/" || raw.isRootFileSystem == true
        // macOS always reports a localized name for real volumes; the mount point name is only a fallback.
        let name = raw.name.flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.displayName(atPath: path)

        let kind: Volume.Kind
        if raw.isDiskImage == true {
            kind = .diskImage
        } else if raw.isLocal == false {
            kind = .network
        } else if let fs = raw.fileSystemTypeName?.lowercased(), ["smbfs", "nfs", "afpfs", "webdav"].contains(fs) {
            kind = .network
        } else if raw.isLocal == true {
            if raw.isInternal == true {
                kind = .internal
            } else {
                kind = .external
            }
        } else {
            if raw.isInternal == true {
                kind = .internal
            } else if raw.isInternal == false {
                kind = .external
            } else {
                kind = .other
            }
        }

        return Volume(
            id: raw.url,
            name: name,
            kind: kind,
            fileSystem: raw.fileSystemTypeName,
            isRoot: isRoot,
            isReadOnly: raw.isReadOnly ?? false,
            isEjectable: raw.isEjectable ?? raw.isRemovable ?? false,
            totalCapacity: totalCapacity,
            availableCapacity: raw.availableCapacity ?? 0,
            availableForImportantUsage: raw.availableForImportantUsage
        )
    }

    /// Orders volumes deterministically with root first followed by localized alphabetical name.
    public static func sort(_ volumes: [Volume]) -> [Volume] {
        volumes.sorted()
    }

    /// Collects all user-visible mounted volumes sorted with startup disk first.
    public static func mountedVolumes(fileManager: FileManager = .default) -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeURLKey,
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTypeNameKey,
            .volumeIsRootFileSystemKey,
            .volumeIsReadOnlyKey,
            .volumeIsBrowsableKey,
        ]
        let urls =
            fileManager.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]
            ) ?? []

        var seenPaths = Set<String>()
        var volumes: [Volume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            let raw = RawValues(url: url, values: values)
            guard let volume = makeVolume(raw) else {
                continue
            }
            if seenPaths.insert(volume.id.path).inserted {
                volumes.append(volume)
            }
        }
        return sort(volumes)
    }
}
