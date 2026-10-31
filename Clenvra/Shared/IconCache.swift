import AppKit
import ClenvraKit

/// Finder icons for list rows, made once per path and reused, so scrolling a long list never asks `NSWorkspace` (or
/// reads a bundle) again for a row it has already shown.
@MainActor
final class IconCache {
    static let shared = IconCache()

    /// Rows draw icons at 16 pt; 32 pt keeps them sharp on Retina screens.
    private static let size = NSSize(width: 32, height: 32)

    private let icons = NSCache<NSString, NSImage>()
    /// Whether a bundle declares its own icon; `NSCache` cannot hold `Bool`, so a plain dictionary (paths are few).
    private var declaresIcon: [String: Bool] = [:]

    private init() {
        icons.countLimit = 2_000
    }

    /// The Finder icon of the file or bundle at the path.
    func icon(forFile path: String) -> NSImage {
        let key = path as NSString
        if let cached = icons.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = Self.size
        icons.setObject(image, forKey: key)
        return image
    }

    /// An extension's own icon when its bundle has one, else its app's icon; `nil` when neither applies.
    func icon(for item: PluginItem) -> NSImage? {
        item.iconSources(hasOwnIcon: hasOwnIcon).first.map(icon(forFile:))
    }

    private func hasOwnIcon(_ bundlePath: String) -> Bool {
        if let known = declaresIcon[bundlePath] { return known }
        let info = Bundle(path: bundlePath)?.infoDictionary ?? [:]
        let declares = PluginItem.declaresIcon(info)
        declaresIcon[bundlePath] = declares
        return declares
    }
}
