import Foundation
import Testing

@testable import ClenvraKit

/// Startup Items shows who signed the program an item runs (F8).
@Suite("Code signature")
struct CodeSignatureTests {
    @Test("a macOS program is signed by Apple")
    func apple() throws {
        let signature = try #require(CodeSignature.read(at: "/bin/ls"))
        #expect(signature.kind == .apple)
    }

    @Test("a plain file is not signed")
    func unsigned() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "clenvra-unsigned-\(UUID()).sh")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(CodeSignature.read(at: file.path(percentEncoded: false))?.kind == .unsigned)
    }

    @Test("a missing file has no signature to read")
    func missing() {
        #expect(CodeSignature.read(at: "/nonexistent/clenvra-\(UUID())") == nil)
    }
}
