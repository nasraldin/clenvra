import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("DownloadSource")
struct DownloadSourceTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private func setWhereFroms(_ relative: String, _ value: Data, noFollow: Bool = true) throws {
        let result = value.withUnsafeBytes { buffer in
            setxattr(
                path(relative), DownloadSource.whereFromsAttribute, buffer.baseAddress, buffer.count, 0,
                noFollow ? XATTR_NOFOLLOW : 0)
        }
        guard result == 0 else { throw POSIXError(.EIO) }
    }

    private func plist(_ urls: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0)
    }

    @Test("the host comes from the first URL in kMDItemWhereFroms, lowercased and without www.")
    func readsHost() throws {
        try fixture.file("tool.dmg", bytes: 10)
        try setWhereFroms("tool.dmg", plist(["https://WWW.GitHub.com/a/b/releases/tool.dmg", "https://example.org/"]))

        #expect(DownloadSource.host(atPath: path("tool.dmg")) == "github.com")
    }

    @Test("entries without a host are skipped in favour of the next URL")
    func skipsHostlessEntries() throws {
        try fixture.file("mail.pdf", bytes: 10)
        try setWhereFroms("mail.pdf", plist(["message:%3Cabc@x%3E", "", "https://mail.example.com/inbox"]))

        #expect(DownloadSource.host(atPath: path("mail.pdf")) == "mail.example.com")
    }

    @Test("a file without the attribute has no source")
    func missingAttribute() throws {
        try fixture.file("plain.zip", bytes: 10)

        #expect(DownloadSource.host(atPath: path("plain.zip")) == nil)
        #expect(DownloadSource.host(atPath: path("nowhere.zip")) == nil)
    }

    @Test("malformed attributes give no source")
    func malformedAttribute() throws {
        try fixture.file("garbage.bin", bytes: 10)
        try setWhereFroms("garbage.bin", Data([0x00, 0xFF, 0x13, 0x37]))
        try fixture.file("dictionary.bin", bytes: 10)
        try setWhereFroms(
            "dictionary.bin",
            PropertyListSerialization.data(
                fromPropertyList: ["url": "https://github.com"], format: .binary, options: 0))
        try fixture.file("numbers.bin", bytes: 10)
        try setWhereFroms(
            "numbers.bin", PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0))

        #expect(DownloadSource.host(atPath: path("garbage.bin")) == nil)
        #expect(DownloadSource.host(atPath: path("dictionary.bin")) == nil)
        #expect(DownloadSource.host(atPath: path("numbers.bin")) == nil)
    }

    @Test("a symlink is not followed: the target's attribute is never read")
    func symlinkNotFollowed() throws {
        try fixture.file("target.dmg", bytes: 10)
        try setWhereFroms("target.dmg", plist(["https://github.com/x.dmg"]))
        try fixture.symlink("link.dmg", to: path("target.dmg"))

        #expect(DownloadSource.host(atPath: path("target.dmg")) == "github.com")
        #expect(DownloadSource.host(atPath: path("link.dmg")) == nil)
    }

    @Test("host parsing is pure and strips only a leading www.")
    func hostParsing() throws {
        #expect(DownloadSource.host(fromWhereFroms: try plist(["http://www.example.com:8080/x"])) == "example.com")
        #expect(DownloadSource.host(fromWhereFroms: try plist(["https://wwwserver.net/"])) == "wwwserver.net")
        #expect(DownloadSource.host(fromWhereFroms: try plist([])) == nil)
        #expect(DownloadSource.host(fromWhereFroms: Data()) == nil)
    }
}
