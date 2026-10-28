import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// Canned HTTP responses by URL; anything else fails like a network error. Never touches the network.
private final class FakeFetcher: HTTPFetching {
    private let responses: [String: Data]
    private let calls = Mutex<[URL]>([])

    init(_ responses: [String: String] = [:]) {
        self.responses = responses.mapValues { Data($0.utf8) }
    }

    var urls: [URL] { calls.withLock { $0 } }

    func data(from url: URL) async throws -> Data {
        calls.withLock { $0.append(url) }
        guard let data = responses[url.absoluteString] else { throw FetchError.requestFailed }
        return data
    }
}

@MainActor
@Suite("UpdateCheckSession")
struct UpdateCheckSessionTests {
    private let scratch: TemporaryDirectory
    private let brew = "/opt/homebrew/bin/brew"
    private let outdatedArguments = ["outdated", "--cask", "--greedy", "--json=v2"]

    init() throws {
        scratch = try TemporaryDirectory()
    }

    private func app(
        _ name: String, version: String?, build: String? = nil, source: InstalledApp.Source = .other,
        identifier: String? = nil, feed: String? = nil, isProtected: Bool = false
    ) throws -> InstalledApp {
        let path = scratch.url.appending(path: "\(name).app").path(percentEncoded: false)
        let contents = URL(filePath: path).appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [:]
        plist["SUFeedURL"] = feed
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return InstalledApp(
            id: path, url: URL(filePath: path, directoryHint: .isDirectory),
            bundleIdentifier: identifier ?? "com.example.\(name.lowercased())", name: name, version: version,
            build: build, source: source, isProtected: isProtected, embeddedBundleIdentifiers: [])
    }

    private static func appcast(short: String, build: String) -> String {
        """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure url="https://example.com/a.zip" sparkle:version="\(build)" sparkle:shortVersionString="\(short)"/>
        </item></channel></rss>
        """
    }

    private func session(
        enabled: Bool = true, fetcher: FakeFetcher, runner: FakeCommandRunner? = nil
    ) -> UpdateCheckSession {
        UpdateCheckSession(
            isEnabled: { enabled }, fetcher: fetcher,
            homebrew: runner.map { AppsSession.Homebrew(brew: brew, runner: $0) },
            systemVersion: AppVersion(major: 26))
    }

    @Test("with the setting off nothing is fetched or run, and the session says so (D5)")
    func refusesWhenDisabled() async throws {
        let fetcher = FakeFetcher()
        let runner = FakeCommandRunner()
        let apps = [
            try app("Sparkly", version: "1.0", feed: "https://example.com/appcast.xml"),
            try app("Store", version: "1.0", source: .appStore),
            try app("Brewed", version: "1.0", source: .homebrew(token: "brewed")),
        ]
        let session = session(enabled: false, fetcher: fetcher, runner: runner)

        await session.check(apps) { _ in nil }

        #expect(session.phase == .disabled)
        #expect(session.results.isEmpty)
        #expect(fetcher.urls.isEmpty)
        #expect(runner.commands.isEmpty)
    }

    @Test("Sparkle feeds are compared by build number, and the short version is shown")
    func sparkle() async throws {
        let fetcher = FakeFetcher([
            "https://example.com/old.xml": Self.appcast(short: "2.1", build: "210"),
            "https://example.com/same.xml": Self.appcast(short: "2.0", build: "200"),
        ])
        let old = try app("Old", version: "2.0", build: "200", feed: "https://example.com/old.xml")
        let same = try app("Same", version: "2.0", build: "200", feed: "https://example.com/same.xml")
        let session = session(fetcher: fetcher)

        await session.check([old, same]) { _ in nil }

        #expect(session.phase == .ready)
        #expect(session.results[old.id]?.status == .available(version: "2.1"))
        #expect(session.results[old.id]?.source == .sparkle)
        #expect(session.results[same.id]?.status == .upToDate)
        #expect(session.availableUpdates.map(\.id) == [old.id])
    }

    @Test("http feeds are never fetched")
    func insecureFeed() async throws {
        let fetcher = FakeFetcher()
        let app = try app("Plain", version: "1.0", feed: "http://example.com/appcast.xml")
        let session = session(fetcher: fetcher)

        await session.check([app]) { _ in nil }

        #expect(session.results[app.id]?.status == .unknown(.insecureFeed))
        #expect(fetcher.urls.isEmpty)
    }

    @Test("App Store apps are compared with the iTunes lookup version")
    func appStore() async throws {
        let store = try app("Store", version: "4.1", source: .appStore, identifier: "com.vendor.store")
        let url = try #require(UpdateSources.appStoreLookupURL(bundleIdentifier: "com.vendor.store"))
        let fetcher = FakeFetcher([
            url.absoluteString: #"{"resultCount":1,"results":[{"bundleId":"com.vendor.store","version":"4.2"}]}"#
        ])
        let session = session(fetcher: fetcher)

        await session.check([store]) { _ in nil }

        #expect(session.results[store.id]?.status == .available(version: "4.2"))
        #expect(session.results[store.id]?.source == .appStore)
        #expect(fetcher.urls == [url])
    }

    @Test("Homebrew casks use one brew outdated run; an app that updated itself is not reported")
    func homebrew() async throws {
        let runner = FakeCommandRunner()
        runner.stub(
            brew, outdatedArguments,
            stdout: """
                {"formulae": [], "casks": [
                  {"name": "firefox", "installed_versions": ["120.0"], "current_version": "121.0"},
                  {"name": "chrome", "installed_versions": ["100"], "current_version": "131.0,6778.70"}
                ]}
                """)
        let firefox = try app("Firefox", version: "120.0")
        let chrome = try app("Chrome", version: "131.0.6778.70")
        let zed = try app("Zed", version: "0.150", source: .homebrew(token: "zed"))
        let tokens = [firefox.id: "firefox", chrome.id: "chrome"]
        let session = session(fetcher: FakeFetcher(), runner: runner)

        await session.check([firefox, chrome, zed]) { tokens[$0.id] }

        #expect(session.results[firefox.id]?.status == .available(version: "121.0"))
        #expect(session.results[firefox.id]?.source == .homebrew(token: "firefox"))
        #expect(session.results[chrome.id]?.status == .upToDate)
        #expect(session.results[zed.id]?.status == .upToDate)
        #expect(runner.commands.count == 1)
        #expect(runner.commands.first?.environment?["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test("a failing brew is unknown, not up to date")
    func homebrewFailure() async throws {
        let runner = FakeCommandRunner()
        runner.stub(brew, outdatedArguments, stderr: "Error", status: 1)
        let zed = try app("Zed", version: "0.150", source: .homebrew(token: "zed"))
        let session = session(fetcher: FakeFetcher(), runner: runner)

        await session.check([zed]) { _ in nil }

        #expect(session.results[zed.id]?.status == .unknown(.requestFailed))
    }

    @Test("network failures, garbage responses and unreadable versions are unknown, never a crash")
    func failures() async throws {
        let failing = try app("Failing", version: "1.0", feed: "https://example.com/missing.xml")
        let garbage = try app("Garbage", version: "1.0", feed: "https://example.com/garbage.xml")
        let noVersion = try app("NoVersion", version: nil, source: .appStore, identifier: "com.vendor.nov")
        let lookup = try #require(UpdateSources.appStoreLookupURL(bundleIdentifier: "com.vendor.nov"))
        let fetcher = FakeFetcher([
            lookup.absoluteString: #"{"results":[{"bundleId":"com.vendor.nov","version":"2.0"}]}"#,
            "https://example.com/garbage.xml": "<<<>>>",
        ])
        let session = session(fetcher: fetcher)

        await session.check([failing, garbage, noVersion]) { _ in nil }

        #expect(session.results[failing.id]?.status == .unknown(.requestFailed))
        #expect(session.results[garbage.id]?.status == .unknown(.unreadableResponse))
        #expect(session.results[noVersion.id]?.status == .unknown(.unreadableVersion))
    }

    @Test("apps without a known update source are unknown; Apple and Clenvra itself are skipped")
    func noSource() async throws {
        let plain = try app("Plain", version: "1.0")
        let apple = try app("Safari", version: "26.0", source: .apple, isProtected: true)
        let session = session(fetcher: FakeFetcher())

        await session.check([plain, apple]) { _ in nil }

        #expect(session.results[plain.id]?.status == .unknown(.noUpdateSource))
        #expect(session.results[apple.id] == nil)
    }

    @Test("turning the setting off during a check stops further requests")
    func disabledMidway() async throws {
        let enabled = Mutex(true)
        let fetcher = FakeFetcher()
        var apps: [InstalledApp] = []
        for index in 0..<20 {
            apps.append(try app("App\(index)", version: "1.0", feed: "https://example.com/\(index).xml"))
        }
        let session = UpdateCheckSession(
            isEnabled: {
                defer { enabled.withLock { $0 = false } }
                return enabled.withLock { $0 }
            },
            fetcher: fetcher, homebrew: nil, systemVersion: AppVersion(major: 26))

        await session.check(apps) { _ in nil }

        #expect(fetcher.urls.count < apps.count)
        #expect(session.phase == .disabled)
    }
}
