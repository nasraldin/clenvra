import Foundation
import Testing

@testable import ClenvraKit

@Suite("SettingsStore")
struct SettingsStoreTests {
    private let scratch: TemporaryDirectory
    private var file: URL { scratch.url.appending(path: "settings.json") }

    init() throws {
        scratch = try TemporaryDirectory()
    }

    @Test("settings are saved and loaded back")
    func roundTrip() throws {
        let store = SettingsStore(file: file, home: "/Users/a")
        var settings = UserSettings()
        settings.exclusions = ["/Users/a/Library/Caches/com.keep", "/Volumes/Work/Projects"]
        settings.customRules = [
            try CustomCleanupRule(
                folder: "/Users/a/Work/Logs", minimumAge: .days(7), namePattern: "*.log", home: "/Users/a",
                policy: ProtectionPolicy(home: "/Users/a"))
        ]

        try store.save(settings)

        #expect(store.load() == settings)
    }

    @Test("a missing settings file gives the defaults")
    func missingFile() {
        #expect(SettingsStore(file: file, home: "/Users/a").load() == UserSettings())
    }

    @Test("a corrupted settings file gives the defaults instead of failing")
    func corruptedFile() throws {
        try Data("{ not json".utf8).write(to: file)
        #expect(SettingsStore(file: file, home: "/Users/a").load() == UserSettings())
    }

    @Test("export writes paths inside the home folder as ~/… so they work for another user name")
    func exportIsHomeRelative() throws {
        let store = SettingsStore(file: file, home: "/Users/a")
        var settings = UserSettings()
        settings.exclusions = ["/Users/a/Sources/keep", "/Volumes/Work/Projects"]
        settings.customRules = [
            try CustomCleanupRule(
                folder: "/Users/a/Sources/Logs", minimumAge: .days(2), namePattern: "*.log", home: "/Users/a",
                policy: ProtectionPolicy(home: "/Users/a"))
        ]

        let exported = try store.export(settings)
        let text = String(decoding: exported, as: UTF8.self)

        #expect(text.contains("~/Sources/keep"))
        #expect(text.contains("~/Sources/Logs"))
        #expect(!text.contains("/Users/a"))
        #expect(text.contains("/Volumes/Work/Projects"))
    }

    @Test("import on another Mac maps ~/… to that Mac's home folder")
    func importMapsHome() throws {
        let exporter = SettingsStore(file: file, home: "/Users/a")
        var settings = UserSettings()
        settings.exclusions = ["/Users/a/Sources/keep"]
        settings.customRules = [
            try CustomCleanupRule(
                folder: "/Users/a/Sources/Logs", minimumAge: .days(2), namePattern: "*.log", home: "/Users/a",
                policy: ProtectionPolicy(home: "/Users/a"))
        ]
        let data = try exporter.export(settings)

        let result = try SettingsStore(file: file, home: "/Users/b").importSettings(from: data)

        #expect(result.settings.exclusions == ["/Users/b/Sources/keep"])
        #expect(result.settings.customRules.map(\.folder) == ["/Users/b/Sources/Logs"])
        #expect(result.settings.customRules.first?.id == settings.customRules.first?.id)
        #expect(result.rejectedEntries.isEmpty)
    }

    @Test("import drops invalid or duplicate entries and reports them (safety case S28)")
    func importValidation() throws {
        let json = """
            {"version": 1, "exclusions": ["~/ok", "relative/path", "/Users/b/../etc", "~/ok", "/tmp/a\\u0000b"]}
            """
        let result = try SettingsStore(file: file, home: "/Users/b").importSettings(from: Data(json.utf8))

        #expect(result.settings.exclusions == ["/Users/b/ok"])
        #expect(result.rejectedEntries.count == 3)
    }

    @Test("old local settings and exports without custom rules keep loading")
    func oldFilesWithoutCustomRules() throws {
        let store = SettingsStore(file: file, home: "/Users/a")
        try Data(#"{"exclusions":["/Users/a/keep"]}"#.utf8).write(to: file)

        #expect(store.load().exclusions == ["/Users/a/keep"])
        #expect(store.load().customRules.isEmpty)

        let result = try store.importSettings(from: Data(#"{"version":1,"exclusions":["~/keep"]}"#.utf8))
        #expect(result.settings.exclusions == ["/Users/a/keep"])
        #expect(result.settings.customRules.isEmpty)
    }

    @Test("import rejects protected custom-rule roots and keeps valid rules (safety case S28)")
    func importRejectsProtectedCustomRules() throws {
        let json = """
            {
              "version": 1,
              "exclusions": [],
              "customRules": [
                {
                  "id": "6B6B6B6B-6B6B-4B6B-8B6B-6B6B6B6B6B6B",
                  "folder": "~",
                  "minimumAge": {"seconds": 86400},
                  "namePattern": "*.log"
                },
                {
                  "id": "7C7C7C7C-7C7C-4C7C-8C7C-7C7C7C7C7C7C",
                  "folder": "/System",
                  "minimumAge": {"seconds": 86400},
                  "namePattern": "*.log"
                },
                {
                  "id": "8D8D8D8D-8D8D-4D8D-8D8D-8D8D8D8D8D8D",
                  "folder": "~/Work/Logs",
                  "minimumAge": {"seconds": 86400},
                  "namePattern": "*.log"
                }
              ]
            }
            """

        let result = try SettingsStore(file: file, home: "/Users/b").importSettings(from: Data(json.utf8))

        #expect(result.settings.customRules.map(\.folder) == ["/Users/b/Work/Logs"])
        #expect(result.rejectedEntries == ["~", "/System"])
    }

    @Test("loading an edited local settings file drops protected custom rules instead of trusting them")
    func loadRejectsProtectedCustomRules() throws {
        let json = """
            {
              "exclusions": [],
              "customRules": [{
                "id": "6B6B6B6B-6B6B-4B6B-8B6B-6B6B6B6B6B6B",
                "folder": "/Users/a",
                "minimumAge": {"seconds": 86400},
                "namePattern": "*"
              }]
            }
            """
        try Data(json.utf8).write(to: file)

        #expect(SettingsStore(file: file, home: "/Users/a").load().customRules.isEmpty)
    }

    @Test("a file from a newer, unknown format version is refused")
    func unknownVersion() {
        let json = #"{"version": 99, "exclusions": []}"#
        #expect(throws: SettingsStore.ImportError.unsupportedVersion(99)) {
            try SettingsStore(file: file, home: "/Users/b").importSettings(from: Data(json.utf8))
        }
    }

    @Test("new settings default to off: no schedule and no network update check (D5)")
    func newDefaults() {
        let settings = UserSettings()
        #expect(!settings.scanSchedule.isEnabled)
        #expect(!settings.checksForAppUpdates)
        #expect(settings.lastScheduledScan == nil)
    }

    @Test("a settings file written before schedules existed still loads its exclusions")
    func oldFileLoads() throws {
        try Data(#"{"exclusions": ["/Users/a/keep"]}"#.utf8).write(to: file)

        let settings = SettingsStore(file: file, home: "/Users/a").load()

        #expect(settings.exclusions == ["/Users/a/keep"])
        #expect(settings.scanSchedule == ScanSchedule())
        #expect(!settings.checksForAppUpdates)
    }

    @Test("the schedule, update-check choice and last run are saved and loaded back")
    func newFieldsRoundTrip() throws {
        let store = SettingsStore(file: file, home: "/Users/a")
        var settings = UserSettings()
        settings.scanSchedule.isEnabled = true
        settings.scanSchedule.frequency = .daily
        settings.scanSchedule.hour = 7
        settings.checksForAppUpdates = true
        settings.lastScheduledScan = Date(timeIntervalSince1970: 1_800_000_000)

        try store.save(settings)

        #expect(store.load() == settings)
    }

    @Test("export and import carry the schedule and update-check choice, but not this Mac's last run")
    func exportImportNewFields() throws {
        let store = SettingsStore(file: file, home: "/Users/a")
        var settings = UserSettings()
        settings.scanSchedule.isEnabled = true
        settings.scanSchedule.weekday = 6
        settings.checksForAppUpdates = true
        settings.lastScheduledScan = Date()

        let exported = try store.export(settings)
        let result = try SettingsStore(file: file, home: "/Users/b").importSettings(from: exported)

        #expect(result.settings.scanSchedule == settings.scanSchedule)
        // Network access is never switched on by a file; the user turns it on on each Mac (decision D5).
        #expect(!result.settings.checksForAppUpdates)
        #expect(result.settings.lastScheduledScan == nil)
        #expect(!String(decoding: exported, as: UTF8.self).contains("lastScheduledScan"))
    }

    @Test("an exported file from before schedules existed imports with everything off")
    func oldExportImports() throws {
        let json = #"{"version": 1, "exclusions": ["~/ok"]}"#
        let result = try SettingsStore(file: file, home: "/Users/b").importSettings(from: Data(json.utf8))

        #expect(result.settings.exclusions == ["/Users/b/ok"])
        #expect(result.settings.scanSchedule == ScanSchedule())
        #expect(!result.settings.checksForAppUpdates)
    }
}
