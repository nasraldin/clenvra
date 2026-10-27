public import Foundation

/// The user's choices that change what Clenvra may touch.
public struct UserSettings: Codable, Equatable, Sendable {
    /// Folders Clenvra never offers or deletes anything inside (absolute, canonical paths).
    public var exclusions: [String] = []

    public init() {}
}

/// Saves settings on this Mac and moves them between Macs.
public struct SettingsStore: Sendable {
    public enum ImportError: Error, Equatable {
        case unsupportedVersion(Int)
        case malformed
    }

    public struct ImportResult: Sendable, Equatable {
        public let settings: UserSettings
        /// Entries that were not valid paths; shown to the user so nothing is dropped silently.
        public let rejectedEntries: [String]
    }

    /// The portable file format; paths inside the home folder are written as `~/…`.
    private struct Portable: Codable {
        var version: Int
        var exclusions: [String]
    }

    private static let formatVersion = 1
    private let file: URL
    private let home: String

    public init(file: URL, home: String) {
        self.file = file
        self.home = home
    }

    /// The saved settings, or the defaults when there are none or the file is unreadable.
    public func load() -> UserSettings {
        guard let data = try? Data(contentsOf: file),
            let settings = try? JSONDecoder().decode(UserSettings.self, from: data)
        else { return UserSettings() }
        return settings
    }

    public func save(_ settings: UserSettings) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }

    public func export(_ settings: UserSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Portable(version: Self.formatVersion, exclusions: settings.exclusions.map(homeRelative)))
    }

    public func importSettings(from data: Data) throws -> ImportResult {
        guard let portable = try? JSONDecoder().decode(Portable.self, from: data) else { throw ImportError.malformed }
        guard portable.version <= Self.formatVersion else { throw ImportError.unsupportedVersion(portable.version) }

        var settings = UserSettings()
        var rejected: [String] = []
        for entry in portable.exclusions {
            let path = absolute(entry)
            guard (try? PathPolicy.components(of: path)) != nil else {
                rejected.append(entry)
                continue
            }
            if !settings.exclusions.contains(path) { settings.exclusions.append(path) }
        }
        return ImportResult(settings: settings, rejectedEntries: rejected)
    }

    private func homeRelative(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func absolute(_ entry: String) -> String {
        entry == "~" ? home : entry.hasPrefix("~/") ? home + entry.dropFirst(1) : entry
    }
}
