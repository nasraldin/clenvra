public import Foundation

/// The user's choices that change what Clenvra may touch and when it may work on its own.
public struct UserSettings: Codable, Equatable, Sendable {
    /// Folders Clenvra never offers or deletes anything inside (absolute, canonical paths).
    public var exclusions: [String] = []
    /// Background scans that only report (SA-9); off by default.
    public var scanSchedule = ScanSchedule()
    /// Whether Clenvra may contact update feeds and the App Store (AP-9); off by default (D5).
    public var checksForAppUpdates = false
    /// When the last scheduled scan ran on this Mac; local state, never exported.
    public var lastScheduledScan: Date?

    public init() {}

    /// Keys added after the first release are optional, so settings files from older versions still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exclusions = try container.decodeIfPresent([String].self, forKey: .exclusions) ?? []
        scanSchedule = (try? container.decodeIfPresent(ScanSchedule.self, forKey: .scanSchedule)) ?? ScanSchedule()
        checksForAppUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .checksForAppUpdates)) ?? false
        lastScheduledScan = try? container.decodeIfPresent(Date.self, forKey: .lastScheduledScan)
    }
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

    /// The portable file format; paths inside the home folder are written as `~/…`. Fields added later are
    /// optional and the version stays 1, so older Clenvra builds still import the exclusions of newer files.
    private struct Portable: Codable {
        var version: Int
        var exclusions: [String]
        var scanSchedule: ScanSchedule?
        var checksForAppUpdates: Bool?
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
            Portable(
                version: Self.formatVersion, exclusions: settings.exclusions.map(homeRelative),
                scanSchedule: settings.scanSchedule, checksForAppUpdates: nil))
    }

    public func importSettings(from data: Data) throws -> ImportResult {
        guard let portable = try? JSONDecoder().decode(Portable.self, from: data) else { throw ImportError.malformed }
        guard portable.version <= Self.formatVersion else { throw ImportError.unsupportedVersion(portable.version) }

        var settings = UserSettings()
        settings.scanSchedule = portable.scanSchedule ?? ScanSchedule()
        // Never imported: network access is switched on by the user on each Mac, not by a file (decision D5).
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
