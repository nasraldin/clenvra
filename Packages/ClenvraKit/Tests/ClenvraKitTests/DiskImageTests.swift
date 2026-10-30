import Foundation
import Testing

@testable import ClenvraKit

/// Disk images (installers and other `.dmg` files) are told apart from real disks: Overview and Space Map show real
/// disks only, Mounted Disks lists the images with their source file, and no image ever gets a Trash rule.
@Suite("Disk images", .serialized)
struct DiskImageTests {
    @Test("a mounted disk image is a disk image, not an external drive")
    func mountedDiskImageIsDetected() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "clenvra-dmg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(path: "test.dmg").path(percentEncoded: false)
        let name = "ClenvraTest\(Int.random(in: 1000...9999))"
        try run("/usr/bin/hdiutil", ["create", "-size", "8m", "-fs", "APFS", "-volname", name, image])
        try run("/usr/bin/hdiutil", ["attach", image])
        defer { try? run("/usr/bin/hdiutil", ["detach", "/Volumes/\(name)", "-force"]) }

        let volume = try #require(VolumeInventory.mountedVolumes().first { $0.name == name })
        #expect(volume.kind == .diskImage)
        #expect(!volume.isRealDisk)
        // hdiutil reports the canonical path (/private/var/…).
        let canonical = URL(filePath: image).resolvingSymlinksInPath().path(percentEncoded: false)
        #expect(DiskImageInfo.imagePath(of: volume, in: DiskImageInfo.read()) == canonical)
    }

    @Test("the startup disk is a real disk")
    func startupDiskIsReal() throws {
        let root = try #require(VolumeInventory.mountedVolumes().first { $0.isRoot })
        #expect(root.isRealDisk)
    }

    @Test("image paths come from hdiutil's list, keyed by mount point")
    func parsesImagePaths() throws {
        let plist: [String: Any] = [
            "images": [
                [
                    "image-path": "/Users/me/Downloads/Clenvra-1.0.0.dmg",
                    "system-entities": [["dev-entry": "/dev/disk9"], ["mount-point": "/Volumes/Clenvra 1.0.0"]],
                ],
                ["image-path": "/tmp/unmounted.dmg", "system-entities": [["dev-entry": "/dev/disk10"]]],
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        #expect(DiskImageInfo.parse(data) == ["/Volumes/Clenvra 1.0.0": "/Users/me/Downloads/Clenvra-1.0.0.dmg"])
        #expect(DiskImageInfo.parse(Data("not a plist".utf8)).isEmpty)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
}
