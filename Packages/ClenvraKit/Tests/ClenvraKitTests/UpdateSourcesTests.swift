import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

@Suite("UpdateSources")
struct UpdateSourcesTests {
    // MARK: - Sparkle appcast

    private static let appcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Example</title>
            <item>
              <title>1.9</title>
              <enclosure url="https://example.com/1.9.zip" sparkle:version="190" sparkle:shortVersionString="1.9"/>
            </item>
            <item>
              <title>1.10</title>
              <sparkle:version>200</sparkle:version>
              <sparkle:shortVersionString>1.10</sparkle:shortVersionString>
              <enclosure url="https://example.com/1.10.zip"/>
            </item>
            <item>
              <title>2.0 beta</title>
              <sparkle:channel>beta</sparkle:channel>
              <enclosure url="https://example.com/2.0b1.zip" sparkle:version="300" sparkle:shortVersionString="2.0b1"/>
            </item>
            <item>
              <title>1.11 needs a future macOS</title>
              <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.com/1.11.zip" sparkle:version="210" sparkle:shortVersionString="1.11"/>
            </item>
          </channel>
        </rss>
        """

    @Test("the newest default-channel item this macOS can run is picked, by number not by text or order")
    func newestAppcastItem() throws {
        let latest = try #require(
            UpdateSources.latestAppcastRelease(
                from: Data(Self.appcast.utf8), systemVersion: AppVersion(major: 26, minor: 1)))
        #expect(latest.build == "200")
        #expect(latest.shortVersion == "1.10")
    }

    @Test("an item with only a short version still counts")
    func shortVersionOnly() throws {
        let xml = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><enclosure sparkle:shortVersionString="3.1"/></item>
            </channel></rss>
            """
        let latest = try #require(
            UpdateSources.latestAppcastRelease(from: Data(xml.utf8), systemVersion: AppVersion(major: 26)))
        #expect(latest.shortVersion == "3.1")
        #expect(latest.build == nil)
    }

    @Test(
        "garbage feeds give no release instead of crashing",
        arguments: [
            "", "not xml at all", "<rss><channel></channel></rss>", "<rss><channel><item><title>x</title></item>",
            String(repeating: "<item>", count: 5_000),
        ])
    func garbageAppcast(text: String) throws {
        #expect(
            UpdateSources.latestAppcastRelease(from: Data(text.utf8), systemVersion: AppVersion(major: 26))
                == nil)
    }

    private static func bundle(in root: URL, name: String, plist: [String: Any]) throws -> String {
        let contents = root.appending(path: "\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return root.appending(path: "\(name).app").path(percentEncoded: false)
    }

    @Test("the feed URL is read from the bundle's Info.plist and must be HTTPS")
    func feedURL() throws {
        let scratch = try TemporaryDirectory()
        let secure = try Self.bundle(
            in: scratch.url, name: "Secure", plist: ["SUFeedURL": "https://example.com/appcast.xml"])
        let insecure = try Self.bundle(
            in: scratch.url, name: "Insecure", plist: ["SUFeedURL": "http://example.com/appcast.xml"])
        let none = try Self.bundle(in: scratch.url, name: "None", plist: ["CFBundleIdentifier": "com.x"])
        let garbage = try Self.bundle(in: scratch.url, name: "Garbage", plist: ["SUFeedURL": 42])
        let expected = try #require(URL(string: "https://example.com/appcast.xml"))

        #expect(UpdateSources.sparkleFeed(ofBundle: secure) == .https(expected))
        #expect(UpdateSources.sparkleFeed(ofBundle: insecure) == .insecure)
        #expect(UpdateSources.sparkleFeed(ofBundle: none) == nil)
        #expect(UpdateSources.sparkleFeed(ofBundle: garbage) == nil)
        #expect(UpdateSources.sparkleFeed(ofBundle: scratch.url.path(percentEncoded: false) + "Missing.app") == nil)
    }

    // MARK: - Homebrew

    @Test("brew outdated JSON maps each outdated cask to its newest version")
    func brewOutdated() {
        let json = """
            {"formulae": [{"name": "wget", "current_version": "9"}],
             "casks": [
               {"name": "firefox", "installed_versions": ["120.0"], "current_version": "121.0"},
               {"name": "zed", "installed_versions": "0.1", "current_version": "0.2"},
               {"name": 7, "current_version": "1"},
               {"name": "broken"}
             ]}
            """
        #expect(UpdateSources.outdatedCasks(fromJSON: Data(json.utf8)) == ["firefox": "121.0", "zed": "0.2"])
    }

    @Test("unreadable brew output is nil, which means unknown rather than up to date")
    func brewGarbage() {
        #expect(UpdateSources.outdatedCasks(fromJSON: Data("Error: oops".utf8)) == nil)
        #expect(UpdateSources.outdatedCasks(fromJSON: Data(#"{"formulae": []}"#.utf8)) == nil)
    }

    // MARK: - App Store

    @Test("the iTunes lookup URL is HTTPS and escapes the bundle identifier")
    func lookupURL() throws {
        let url = try #require(UpdateSources.appStoreLookupURL(bundleIdentifier: "com.vendor.app&x=1"))
        #expect(url.scheme == "https")
        #expect(url.host() == "itunes.apple.com")
        #expect(url.absoluteString.contains("bundleId=com.vendor.app%26x%3D1"))
        #expect(url.absoluteString.contains("entity=macSoftware"))
    }

    @Test("the lookup response gives the store's version for the matching bundle")
    func lookupResponse() {
        let json = """
            {"resultCount": 2, "results": [
              {"bundleId": "com.other", "version": "9.0"},
              {"bundleId": "com.vendor.app", "version": "4.2.1", "trackViewUrl": "https://apps.apple.com/app/id1"}
            ]}
            """
        #expect(UpdateSources.appStoreVersion(fromJSON: Data(json.utf8), bundleIdentifier: "com.vendor.app") == "4.2.1")
        #expect(UpdateSources.appStoreVersion(fromJSON: Data(json.utf8), bundleIdentifier: "com.missing") == nil)
        #expect(UpdateSources.appStoreVersion(fromJSON: Data("[]".utf8), bundleIdentifier: "com.vendor.app") == nil)
    }

    // MARK: - Fetcher

    @Test("the real fetcher refuses non-HTTPS URLs before any connection is made")
    func fetcherRefusesHTTP() async throws {
        let fetcher = URLSessionFetcher()
        for text in ["http://example.com/a", "file:///etc/passwd", "ftp://example.com/a"] {
            let url = try #require(URL(string: text))
            await #expect(throws: FetchError.insecureURL) { try await fetcher.data(from: url) }
        }
    }

    @Test("a download over the size limit is cut off while it streams, not after it arrived")
    func streamingLimit() async throws {
        final class Counter: Sendable {
            let value = Mutex(0)
        }
        let consumed = Counter()
        struct Counting: AsyncSequence {
            typealias Element = UInt8
            let total: Int
            let consumed: Counter
            struct Iterator: AsyncIteratorProtocol {
                var remaining: Int
                let consumed: Counter
                mutating func next() async -> UInt8? {
                    guard remaining > 0 else { return nil }
                    remaining -= 1
                    consumed.value.withLock { $0 += 1 }
                    return 0x41
                }
            }
            func makeAsyncIterator() -> Iterator { Iterator(remaining: total, consumed: consumed) }
        }

        await #expect(throws: FetchError.tooLarge) {
            _ = try await URLSessionFetcher.collect(Counting(total: 1_000_000, consumed: consumed), limit: 10)
        }
        #expect(consumed.value.withLock { $0 } <= 11)
        let small = try await URLSessionFetcher.collect(Counting(total: 5, consumed: Counter()), limit: 10)
        #expect(small.count == 5)
    }
}
