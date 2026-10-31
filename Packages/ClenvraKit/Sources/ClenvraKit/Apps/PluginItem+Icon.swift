import Foundation

extension PluginItem {
    /// The app the item ships in, by name (`/Applications/Notes Pro.app` → `Notes Pro`).
    public var containingAppName: String? {
        guard let containingApp else { return nil }
        let name = (containingApp as NSString).lastPathComponent
        let stem = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        return stem.isEmpty ? nil : stem
    }

    /// Files whose Finder icon may stand for the item, best first: its own bundle when it declares an icon, then
    /// the app it ships in. Empty when neither applies (the UI then shows a generic symbol).
    public func iconSources(hasOwnIcon: (String) -> Bool) -> [String] {
        var sources: [String] = []
        if let path, hasOwnIcon(path) { sources.append(path) }
        if let containingApp, !sources.contains(containingApp) { sources.append(containingApp) }
        return sources
    }

    /// Whether a bundle's Info.plist names an icon of its own (otherwise Finder shows a generic bundle icon).
    public static func declaresIcon(_ info: [String: Any]) -> Bool {
        for key in ["CFBundleIconFile", "CFBundleIconName"] {
            if let name = info[key] as? String, !name.isEmpty { return true }
        }
        if let icons = info["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
        {
            if let files = primary["CFBundleIconFiles"] as? [String], !files.isEmpty { return true }
            if let name = primary["CFBundleIconName"] as? String, !name.isEmpty { return true }
        }
        return false
    }
}
