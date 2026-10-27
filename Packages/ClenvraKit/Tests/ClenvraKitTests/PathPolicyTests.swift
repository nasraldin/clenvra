import Testing

@testable import ClenvraKit

@Suite("PathPolicy")
struct PathPolicyTests {
    @Test("an absolute path is split into its components")
    func components() throws {
        #expect(try PathPolicy.components(of: "/Users/u/Library/Caches") == ["Users", "u", "Library", "Caches"])
        #expect(try PathPolicy.components(of: "/") == [])
    }

    @Test("a single trailing slash is accepted")
    func trailingSlash() throws {
        #expect(try PathPolicy.components(of: "/Users/u/") == ["Users", "u"])
    }

    @Test(
        "unsafe paths are rejected",
        arguments: [
            ("", PathRejection.notAbsolute),
            ("Users/u", .notAbsolute),
            ("/Users//u", .emptyComponent),
            ("/Users/./u", .dotComponent),
            ("/Users/../etc", .dotComponent),
            ("/Users/u\u{0}x", .controlCharacter),
            ("/Users/u\nx", .controlCharacter),
            ("/Users/u\u{7F}x", .controlCharacter),
        ])
    func rejected(path: String, reason: PathRejection) {
        #expect(throws: reason) { _ = try PathPolicy.components(of: path) }
    }

    @Test("names that only contain dots are fine when they are not . or ..")
    func dottedNames() throws {
        #expect(try PathPolicy.components(of: "/a/.../b..c/.hidden") == ["a", "...", "b..c", ".hidden"])
    }

    @Test("paths longer than PATH_MAX are rejected")
    func tooLong() {
        let path = "/" + String(repeating: "a", count: 1_100)
        #expect(throws: PathRejection.tooLong) { _ = try PathPolicy.components(of: path) }
    }

    @Test(
        "containment is component-wise and strict",
        arguments: [
            ("/Users/u/Library/Caches/x", "/Users/u/Library/Caches", true),
            ("/Users/u/Library/Caches/x/y", "/Users/u/Library/Caches", true),
            ("/Users/u/Library/Caches", "/Users/u/Library/Caches", false),
            ("/Users/u/Library/CachesX/y", "/Users/u/Library/Caches", false),
            ("/Users/u/Library", "/Users/u/Library/Caches", false),
            ("/anything", "/", true),
        ])
    func containment(path: String, root: String, inside: Bool) throws {
        #expect(try PathPolicy.isStrictlyInside(path, root: root) == inside)
    }
}
