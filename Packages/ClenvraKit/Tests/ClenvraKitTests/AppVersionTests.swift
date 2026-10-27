import Foundation
import Testing

@testable import ClenvraKit

@Suite("AppVersion")
struct AppVersionTests {
    private func version(_ text: String) throws -> AppVersion {
        try #require(AppVersion(text), "\(text) should parse")
    }

    @Test(
        "numeric components compare as numbers, not text",
        arguments: [
            ("1.10", "1.9"), ("2.0", "1.99.99"), ("1.2.10", "1.2.9"), ("10", "9.9"), ("1.0.1", "1.0"),
        ])
    func numeric(newer: String, older: String) throws {
        #expect(try version(older) < version(newer))
    }

    @Test("missing trailing components are zero", arguments: [("1.0", "1"), ("1.0.0", "1"), ("v2.1", "2.1.0")])
    func trailingZeros(lhs: String, rhs: String) throws {
        #expect(try version(lhs) == version(rhs))
    }

    @Test(
        "pre-releases come before the release and are ordered alpha < beta < rc",
        arguments: [
            ("1.0a1", "1.0b1"), ("1.0-beta.2", "1.0-beta.10"), ("1.0b3", "1.0rc1"), ("1.0rc2", "1.0"),
            ("1.0-alpha", "1.0-beta"), ("1.0 beta 9", "1.0"), ("1.9", "2.0b1"), ("1.0-dev", "1.0a1"),
        ])
    func prerelease(older: String, newer: String) throws {
        #expect(try version(older) < version(newer))
    }

    @Test("build metadata in parentheses or after + is ignored")
    func metadata() throws {
        #expect(try version("2.0 (1234)") == version("2.0"))
        #expect(try version("2.0+build.5") == version("2.0"))
    }

    @Test(
        "text that is not a version is unknown instead of guessed",
        arguments: ["", "   ", "latest", "beta", "..", "abc1.0", String(repeating: "9", count: 40)])
    func garbage(text: String) {
        #expect(AppVersion(text) == nil)
    }
}
