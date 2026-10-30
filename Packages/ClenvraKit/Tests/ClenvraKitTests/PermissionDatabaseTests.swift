import Foundation
import Testing

@testable import ClenvraKit

@Suite("Permissions database")
struct PermissionDatabaseTests {
    private static let rows: [TCCFixture.Row] = [
        .init(
            service: "kTCCServiceCamera", client: "us.zoom.xos", clientType: 0, authValue: 2,
            lastModified: 1_700_000_000),
        .init(service: "kTCCServiceMicrophone", client: "/usr/local/bin/tool", clientType: 1, authValue: 2),
        .init(service: "kTCCServiceCamera", client: "com.denied", clientType: 0, authValue: 0),
        .init(service: "kTCCServicePhotos", client: "com.limited", clientType: 0, authValue: 3),
    ]

    @Test("reads every grant: allowed, limited, denied, bundle IDs and paths")
    func readsGrants() throws {
        let folder = try TemporaryDirectory()
        let path = folder.url.appending(path: "TCC.db").path(percentEncoded: false)
        try TCCFixture.write(Self.rows, to: path)

        let grants = try PermissionDatabase.read(at: path, scope: .user)

        #expect(grants.count == 4)
        let zoom = try #require(grants.first { $0.client == "us.zoom.xos" })
        #expect(zoom.isAllowed)
        #expect(zoom.clientIsBundleID)
        #expect(zoom.service == "kTCCServiceCamera")
        #expect(zoom.scope == .user)
        #expect(zoom.lastModified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(zoom.id == "user:kTCCServiceCamera:us.zoom.xos")
        let tool = try #require(grants.first { $0.client == "/usr/local/bin/tool" })
        #expect(!tool.clientIsBundleID)
        #expect(tool.lastModified == nil)
        #expect(grants.first { $0.client == "com.denied" }?.isAllowed == false)
        #expect(grants.first { $0.client == "com.limited" }?.isAllowed == true)
    }

    @Test("a database that does not exist is unreadable, never empty")
    func missingFileThrowsUnreadable() throws {
        let folder = try TemporaryDirectory()
        let path = folder.url.appending(path: "absent.db").path(percentEncoded: false)

        #expect(throws: PermissionDatabase.Error.unreadable) {
            try PermissionDatabase.read(at: path, scope: .user)
        }
        #expect(!FileManager.default.fileExists(atPath: path), "reading must not create the file")
    }

    @Test("a file that is not a database is unreadable")
    func notADatabaseThrowsUnreadable() throws {
        let folder = try TemporaryDirectory()
        let url = folder.url.appending(path: "TCC.db")
        try Data("not a database, just some text that is long enough".utf8).write(to: url)

        #expect(throws: PermissionDatabase.Error.unreadable) {
            try PermissionDatabase.read(at: url.path(percentEncoded: false), scope: .system)
        }
    }

    @Test("services have readable names, and unknown ones show their short name")
    func serviceNames() {
        #expect(PermissionService.shortName("kTCCServiceCamera") == "Camera")
        #expect(PermissionService.shortName("kTCCServiceSomethingNew") == "SomethingNew")
        #expect(String(localized: PermissionService.title("kTCCServiceSomethingNew")) == "SomethingNew")
        #expect(String(localized: PermissionService.title("kTCCServiceListenEvent")) == "Input Monitoring")
        #expect(PermissionService.anchor("kTCCServiceCamera") == "Privacy_Camera")
        #expect(PermissionService.anchor("kTCCServiceSomethingNew") == nil)
    }
}
