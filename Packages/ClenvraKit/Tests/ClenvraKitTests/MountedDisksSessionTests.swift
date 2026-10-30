import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Records the volumes the session asked to eject.
private final class EjectLog: Sendable {
    private let paths = Mutex<[String]>([])
    func add(_ path: String) { paths.withLock { $0.append(path) } }
    var all: [String] { paths.withLock { $0 } }
}

@Suite("Mounted disks")
@MainActor
struct MountedDisksSessionTests {
    nonisolated private static func volume(_ name: String, _ kind: Volume.Kind, root: Bool = false) -> Volume {
        Volume(
            id: URL(filePath: root ? "/" : "/Volumes/\(name)/"), name: name, kind: kind, fileSystem: "apfs",
            isRoot: root, isReadOnly: kind == .diskImage, isEjectable: !root, totalCapacity: 20_000_000,
            availableCapacity: 10_000_000, availableForImportantUsage: nil)
    }

    nonisolated private static let all = [
        volume("Macintosh HD", .internal, root: true), volume("Clenvra 1.0.0", .diskImage),
        volume("Kiro CLI", .diskImage), volume("Backup", .external), volume("Share", .network),
    ]

    private func session(
        ejected: EjectLog = EjectLog(), failing: Set<String> = []
    ) -> MountedDisksSession {
        MountedDisksSession(
            volumes: { Self.all },
            imagePaths: { ["/Volumes/Clenvra 1.0.0": "/Users/me/Downloads/Clenvra-1.0.0.dmg"] },
            eject: { url in
                let path = url.path(percentEncoded: false)
                if failing.contains(path) { throw CocoaError(.fileWriteUnknown) }
                ejected.add(path)
            })
    }

    @Test("groups mounted disks; the startup disk is never listed")
    func groups() async {
        let session = session()
        await session.load()
        #expect(session.images.map { $0.volume.name } == ["Clenvra 1.0.0", "Kiro CLI"])
        #expect(session.drives.map { $0.volume.name } == ["Backup"])
        #expect(session.network.map { $0.volume.name } == ["Share"])
        #expect(session.images.first?.imagePath == "/Users/me/Downloads/Clenvra-1.0.0.dmg")
    }

    @Test("ejecting one disk removes it from the list")
    func ejectOne() async throws {
        let ejected = EjectLog()
        let session = session(ejected: ejected)
        await session.load()
        let disk = try #require(session.images.first)

        #expect(await session.eject(disk))
        #expect(ejected.all == ["/Volumes/Clenvra 1.0.0/"])
    }

    @Test("Eject All touches disk images only, never drives or network shares")
    func ejectAllImagesOnly() async {
        let ejected = EjectLog()
        let session = session(ejected: ejected)
        await session.load()

        let failed = await session.ejectAllImages()

        #expect(failed.isEmpty)
        #expect(ejected.all == ["/Volumes/Clenvra 1.0.0/", "/Volumes/Kiro CLI/"])
    }

    @Test("a disk in use is reported, not dropped from the list")
    func ejectFailure() async throws {
        let session = session(failing: ["/Volumes/Kiro CLI/"])
        await session.load()

        let failed = await session.ejectAllImages()

        #expect(failed.map { $0.volume.name } == ["Kiro CLI"])
    }
}
