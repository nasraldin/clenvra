import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("FullDiskAccess")
struct FullDiskAccessTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private func path(_ relative: String) -> String {
        scratch.url.appending(path: relative).path(percentEncoded: false)
    }

    @Test("a readable protected file means access is granted")
    func readableFile() throws {
        try fixture.file("Safari/Bookmarks.plist", bytes: 10)
        #expect(FullDiskAccess.probe(paths: [path("Safari/Bookmarks.plist")]) == .granted)
    }

    @Test("a listable protected folder means access is granted")
    func listableFolder() throws {
        try fixture.directory("Containers/com.apple.stocks")
        #expect(FullDiskAccess.probe(paths: [path("Containers/com.apple.stocks")]) == .granted)
    }

    @Test("a permission failure means access is not granted")
    func permissionDenied() throws {
        try fixture.file("Safari/Bookmarks.plist", bytes: 10)
        try fixture.directory("Containers/com.apple.stocks")
        chmod(path("Safari/Bookmarks.plist"), 0)
        chmod(path("Containers/com.apple.stocks"), 0)

        let status = FullDiskAccess.probe(paths: [path("Safari/Bookmarks.plist"), path("Containers/com.apple.stocks")])

        #expect(status == .notGranted)
    }

    @Test("missing probe paths leave the answer unknown")
    func missing() {
        #expect(FullDiskAccess.probe(paths: [path("nope.plist"), path("nope-dir")]) == .unknown)
        #expect(FullDiskAccess.probe(paths: []) == .unknown)
    }

    @Test("one readable path wins over a missing one")
    func firstReadableWins() throws {
        try fixture.directory("Containers/com.apple.stocks")
        #expect(
            FullDiskAccess.probe(paths: [path("missing.plist"), path("Containers/com.apple.stocks")]) == .granted)
    }

    @Test("the default probe paths live in the user's Library")
    func defaultPaths() {
        let paths = FullDiskAccess.probePaths(home: "/Users/someone")
        #expect(
            paths == [
                "/Users/someone/Library/Safari/Bookmarks.plist", "/Users/someone/Library/Containers/com.apple.stocks",
            ])
    }
}
