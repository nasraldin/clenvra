import Darwin
import Foundation

/// Where a downloaded file came from, read from the `kMDItemWhereFroms` extended attribute browsers and Mail set,
/// so the Downloads review can group files by website.
enum DownloadSource {
    /// Extended attribute holding a binary property list array of the download's URL strings.
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"
    /// Real values are a few hundred bytes; anything larger is not worth reading for a label.
    private static let maximumAttributeSize = 64 * 1024

    /// The website host of the file at `path` (e.g. "github.com"), or `nil` when the attribute is missing, too large
    /// or not a list of URLs. A symlink is never followed: only the link's own attribute is read.
    static func host(atPath path: String) -> String? {
        let size = getxattr(path, whereFromsAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= maximumAttributeSize else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBytes { bytes in
            getxattr(path, whereFromsAttribute, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
        guard read > 0, read <= size else { return nil }
        return host(fromWhereFroms: Data(buffer.prefix(read)))
    }

    /// The first URL in the attribute's value that has a host, lowercased and without a leading "www.".
    static func host(fromWhereFroms data: Data) -> String? {
        guard !data.isEmpty,
            let urls = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any]
        else { return nil }
        for case let string as String in urls {
            guard let host = URL(string: string)?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
                continue
            }
            return host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host
        }
        return nil
    }
}
