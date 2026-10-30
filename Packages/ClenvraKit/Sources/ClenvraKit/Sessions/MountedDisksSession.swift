public import Foundation
public import Observation

/// Disks mounted besides the startup disk: disk images (installers and other `.dmg` files), other drives and network
/// shares, with ejecting. Read-only apart from ejecting, which only unmounts: nothing on a disk is changed.
@MainActor
@Observable
public final class MountedDisksSession {
    public struct Disk: Sendable, Hashable, Identifiable {
        public let volume: Volume
        /// The `.dmg` file a disk image comes from; `nil` for drives and shares, or when hdiutil does not say.
        public let imagePath: String?
        public var id: URL { volume.id }
    }

    public private(set) var images: [Disk] = []
    /// Other internal and external drives.
    public private(set) var drives: [Disk] = []
    public private(set) var network: [Disk] = []
    public private(set) var hasLoaded = false

    private let volumes: @Sendable () -> [Volume]
    private let imagePaths: @Sendable () -> [String: String]
    private let eject: @Sendable (URL) async throws -> Void

    /// `eject` unmounts and ejects a volume (the app passes `NSWorkspace.unmountAndEjectDevice(at:)`).
    public init(
        volumes: @escaping @Sendable () -> [Volume] = { VolumeInventory.mountedVolumes() },
        imagePaths: @escaping @Sendable () -> [String: String] = { DiskImageInfo.read() },
        eject: @escaping @Sendable (URL) async throws -> Void
    ) {
        self.volumes = volumes
        self.imagePaths = imagePaths
        self.eject = eject
    }

    public func load() async {
        let read = await Self.read(volumes: volumes, imagePaths: imagePaths)
        images = read.filter { $0.volume.kind == .diskImage }
        drives = read.filter { $0.volume.kind == .internal || $0.volume.kind == .external || $0.volume.kind == .other }
        network = read.filter { $0.volume.kind == .network }
        hasLoaded = true
    }

    /// Ejects one disk; `false` when macOS refused (usually because a file on it is open). Reloads either way.
    public func eject(_ disk: Disk) async -> Bool {
        let succeeded = (try? await eject(disk.volume.id)) != nil
        await load()
        return succeeded
    }

    /// Ejects every disk image (never drives or shares); returns the images macOS would not eject.
    public func ejectAllImages() async -> [Disk] {
        var failed: [Disk] = []
        for disk in images where (try? await eject(disk.volume.id)) == nil {
            failed.append(disk)
        }
        await load()
        return failed
    }

    @concurrent private static func read(
        volumes: @Sendable () -> [Volume], imagePaths: @Sendable () -> [String: String]
    ) async -> [Disk] {
        let mounted = volumes().filter { !$0.isRoot }
        let paths = mounted.contains { $0.kind == .diskImage } ? imagePaths() : [:]
        return mounted.map { Disk(volume: $0, imagePath: DiskImageInfo.imagePath(of: $0, in: paths)) }
    }
}
