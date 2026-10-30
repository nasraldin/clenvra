import Foundation

/// Which `.dmg` file each mounted disk image comes from, from `hdiutil info -plist` (read-only).
public enum DiskImageInfo {
    /// Mount point → image file path, for every mounted disk image; empty when hdiutil cannot be read.
    public static func read() -> [String: String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? parse(data) : [:]
    }

    /// The image file of a mounted volume (a volume's URL path ends in "/", hdiutil's mount points do not).
    public static func imagePath(of volume: Volume, in paths: [String: String]) -> String? {
        var mountPoint = volume.id.path(percentEncoded: false)
        if mountPoint.count > 1, mountPoint.hasSuffix("/") { mountPoint.removeLast() }
        return paths[mountPoint]
    }

    /// Mount point → image file path from hdiutil's property list; images that are not mounted are left out.
    static func parse(_ data: Data) -> [String: String] {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else { return [:] }
        var paths: [String: String] = [:]
        for image in images {
            guard let path = image["image-path"] as? String,
                let entities = image["system-entities"] as? [[String: Any]]
            else { continue }
            for case let mountPoint as String in entities.map({ $0["mount-point"] }) {
                paths[mountPoint] = path
            }
        }
        return paths
    }
}
