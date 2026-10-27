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

        let exported = try store.export(settings)
        let text = String(decoding: exported, as: UTF8.self)

        #expect(text.contains("~/Sources/keep"))
        #expect(!text.contains("/Users/a"))
        #expect(text.contains("/Volumes/Work/Projects"))
    }

    @Test("import on another Mac maps ~/… to that Mac's home folder")
    func importMapsHome() throws {
        let exporter = SettingsStore(file: file, home: "/Users/a")
        var settings = UserSettings()
        settings.exclusions = ["/Users/a/Sources/keep"]
        let data = try exporter.export(settings)

        let result = try SettingsStore(file: file, home: "/Users/b").importSettings(from: data)

        #expect(result.settings.exclusions == ["/Users/b/Sources/keep"])
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

    @Test("a file from a newer, unknown format version is refused")
    func unknownVersion() {
        let json = #"{"version": 99, "exclusions": []}"#
        #expect(throws: SettingsStore.ImportError.unsupportedVersion(99)) {
            try SettingsStore(file: file, home: "/Users/b").importSettings(from: Data(json.utf8))
        }
    }
}
