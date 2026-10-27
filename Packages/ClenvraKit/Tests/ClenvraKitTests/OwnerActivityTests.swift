import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("OwnerActivity")
struct OwnerActivityTests {
    /// Folder containing this test process's executable; treated as a fake "bundle".
    private static var ownExecutableFolder: String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        let path = String(decoding: buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).deletingLastPathComponent
    }

    @Test("an app is running when a process executable lives inside its bundle")
    func runningByProcessPath() {
        let activity = OwnerActivity(bundlePaths: ["com.example.self": Self.ownExecutableFolder])
        #expect(activity.state(of: "com.example.self") == .running)
    }

    @Test("an app with no process inside its bundle is not running")
    func notRunning() {
        let activity = OwnerActivity(bundlePaths: ["com.example.none": "/Applications/Definitely Not Installed 123.app"]
        )
        #expect(activity.state(of: "com.example.none") == .notRunning)
    }

    @Test("a bundle path prefix must match a whole folder name")
    func wholeComponentMatch() {
        let folder = Self.ownExecutableFolder
        let truncated = String(folder.dropLast())
        let activity = OwnerActivity(bundlePaths: ["com.example.prefix": truncated])
        #expect(activity.state(of: "com.example.prefix") == .notRunning)
    }

    @Test("a running app is found by bundle identifier even without a known bundle path")
    func runningByBundleIdentifier() {
        let activity = OwnerActivity(bundlePaths: [:], runningBundleIdentifiers: { ["com.example.listed"] })
        #expect(activity.state(of: "com.example.listed") == .running)
    }

    @Test("when processes cannot be listed the answer is unknown, never 'not running'")
    func unknownWhenListingFails() {
        let activity = OwnerActivity(
            bundlePaths: ["com.example.app": "/Applications/Example.app"], processPaths: { nil })
        #expect(activity.state(of: "com.example.app") == .unknown)
    }

    @Test("the real process list includes this test process")
    func realProcessList() throws {
        let paths = try #require(OwnerActivity.currentProcessPaths())
        #expect(paths.contains { $0.hasPrefix(Self.ownExecutableFolder + "/") })
    }
}
