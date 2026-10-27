import Foundation

/// Checks `.xcstrings` catalogs for keys that are not fully translated.
enum StringCatalogAudit {
    struct MalformedCatalog: Error {}

    /// Returns `"<key> (<language>)"` for every key whose translation is missing or not in the `translated` state,
    /// including any plural or device variant. Keys marked `shouldTranslate: false` are ignored.
    static func untranslatedKeys(in catalog: Data, languages: [String]) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: catalog) as? [String: Any],
            let strings = root["strings"] as? [String: Any]
        else { throw MalformedCatalog() }

        var missing: [String] = []
        for key in strings.keys.sorted() {
            let entry = strings[key] as? [String: Any] ?? [:]
            if entry["shouldTranslate"] as? Bool == false { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in languages where !isTranslated(localizations[language]) {
                missing.append("\(key) (\(language))")
            }
        }
        return missing
    }

    /// Keys the last sync could no longer find in source code (`extractionState: stale`).
    static func staleKeys(in catalog: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: catalog) as? [String: Any],
            let strings = root["strings"] as? [String: Any]
        else { throw MalformedCatalog() }
        return strings.compactMap { key, value in
            (value as? [String: Any])?["extractionState"] as? String == "stale" ? key : nil
        }.sorted()
    }

    /// A localization is translated when its string unit is, or when every leaf of its variations is.
    private static func isTranslated(_ node: Any?) -> Bool {
        guard let node = node as? [String: Any] else { return false }
        if let unit = node["stringUnit"] as? [String: Any] {
            return unit["state"] as? String == "translated"
        }
        guard let variations = node["variations"] as? [String: Any], !variations.isEmpty else { return false }
        return variations.values.allSatisfy { kind in
            guard let variants = kind as? [String: Any], !variants.isEmpty else { return false }
            return variants.values.allSatisfy(isTranslated)
        }
    }

    /// All `.xcstrings` files in the repository, excluding build output.
    static func catalogsInRepository(filePath: String = #filePath) -> [URL] {
        // …/Packages/ClenvraKit/Tests/ClenvraKitTests/Support/StringCatalogAudit.swift → repository root
        var root = URL(filePath: filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "DerivedData" || url.lastPathComponent == "docs" {
                enumerator.skipDescendants()
            } else if url.pathExtension == "xcstrings" {
                found.append(url)
            }
        }
        return found
    }
}
