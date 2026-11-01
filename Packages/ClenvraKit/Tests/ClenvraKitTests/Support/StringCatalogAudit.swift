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

    /// Returns `"<key> (<language> <form>)"` for every translation in which a placeholder reads an argument as
    /// another type than the key does, which crashes at run time (a count read as `%@`). Translations may leave
    /// an argument out (an Arabic "one" form without the number), but a later one must then name its position (`%2$@`).
    static func mismatchedPlaceholders(in catalog: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: catalog) as? [String: Any],
            let strings = root["strings"] as? [String: Any]
        else { throw MalformedCatalog() }
        var mismatched: [String] = []
        for key in strings.keys.sorted() {
            let expected = placeholders(in: key).map(\.kind)
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for language in localizations.keys.sorted() {
                for (form, value) in values(of: localizations[language]) {
                    var next = 0
                    let wrong = placeholders(in: value).contains { placeholder in
                        let index = placeholder.position.map { $0 - 1 } ?? next
                        next = index + 1
                        return index >= expected.count || expected[index] != placeholder.kind
                    }
                    if wrong { mismatched.append("\(key) (\(language) \(form))") }
                }
            }
        }
        return mismatched
    }

    private enum ArgumentKind { case object, integer, double }

    /// The format placeholders of a string in order: their explicit position (`%2$@`), if any, and argument kind.
    private static func placeholders(in string: String) -> [(position: Int?, kind: ArgumentKind)] {
        let pattern = /%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp%])/
        return string.matches(of: pattern).compactMap { match in
            let kind: ArgumentKind
            switch match.output.2 {
            case "%": return nil
            case "@", "s", "S", "p", "c", "C": kind = .object
            case "f", "F", "e", "E", "g", "G", "a", "A": kind = .double
            default: kind = .integer
            }
            return (match.output.1.flatMap { Int($0) }, kind)
        }
    }

    /// Each string of a localization: its unit (`"unit"`) and every variant, named by its form.
    private static func values(of node: Any?) -> [(form: String, value: String)] {
        guard let node = node as? [String: Any] else { return [] }
        if let value = (node["stringUnit"] as? [String: Any])?["value"] as? String { return [("unit", value)] }
        let variations = node["variations"] as? [String: Any] ?? [:]
        return variations.values.flatMap { kind -> [(form: String, value: String)] in
            let variants = kind as? [String: Any] ?? [:]
            return variants.keys.sorted().flatMap { form in values(of: variants[form]).map { (form, $0.value) } }
        }
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
        guard let root = repositoryRoot(from: filePath),
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

    /// The nearest ancestor holding `Clenvra.xcworkspace`. Found by marker, not by counting folders, so the audit
    /// never wanders into sibling projects next to the checkout.
    static func repositoryRoot(from filePath: String) -> URL? {
        var directory = URL(filePath: filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appending(path: "Clenvra.xcworkspace").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
