import Foundation
import Testing

@testable import ClenvraKit

@Suite("LargeFileGroups")
struct LargeFileGroupsTests {
    private let root = "/Users/test"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ path: String, size: Int64, daysAgo: Double?) -> StorageItem {
        let date = daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        return StorageItem(
            path: path, name: (path as NSString).lastPathComponent, kind: .file, allocatedSize: size,
            reclaimableSize: size, logicalSize: size, fileCount: 1, folderCount: 0, modificationDate: date,
            protection: nil, ruleRoot: root,
            snapshot: FileSnapshot(
                identity: FileIdentity(device: 1, inode: UInt64(path.utf8.count)), kind: .file, logicalSize: size,
                modificationDate: date))
    }

    @Test func largeFilesGroupByKind() {
        let files = [
            file("/Users/test/Movies/a.mov", size: 500, daysAgo: 10),
            file("/Users/test/Movies/b.MP4", size: 400, daysAgo: 10),
            file("/Users/test/Downloads/x.dmg", size: 300, daysAgo: 10),
            file("/Users/test/Downloads/x.zip", size: 100, daysAgo: 10),
            file("/Users/test/Pictures/p.heic", size: 50, daysAgo: 10),
            file("/Users/test/Documents/r.pdf", size: 60, daysAgo: 10),
            file("/Users/test/Downloads/Tool.pkg", size: 70, daysAgo: 10),
            file("/Users/test/data.bin", size: 1_000, daysAgo: 10),
        ]

        let groups = LargeFileGroups.groups(files, by: .kind, root: root, now: now)

        #expect(
            groups.map(\.key) == [
                .kind(.other), .kind(.video), .kind(.diskImage), .kind(.archive), .kind(.app), .kind(.document),
                .kind(.image),
            ])
        #expect(groups[1].items.map(\.name) == ["a.mov", "b.MP4"])
        #expect(groups[1].totalBytes == 900)
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test func largeFilesGroupByFolder() {
        let files = [
            file("/Users/test/Movies/Trip/a.mov", size: 500, daysAgo: 10),
            file("/Users/test/Movies/b.mov", size: 400, daysAgo: 10),
            file("/Users/test/Downloads/x.dmg", size: 1_000, daysAgo: 10),
            file("/Users/test/loose.bin", size: 10, daysAgo: 10),
        ]

        let groups = LargeFileGroups.groups(files, by: .folder, root: root, now: now)

        #expect(
            groups.map(\.key) == [
                .folder("/Users/test/Downloads"), .folder("/Users/test/Movies"), .folder("/Users/test"),
            ])
        #expect(groups[1].items.count == 2)
        #expect(groups[1].totalBytes == 900)
    }

    @Test func largeFilesGroupByAge() {
        let files = [
            file("/Users/test/new.mov", size: 1_000, daysAgo: 30),
            file("/Users/test/mid.mov", size: 10, daysAgo: 250),
            file("/Users/test/old.mov", size: 10, daysAgo: 500),
            file("/Users/test/ancient.mov", size: 10, daysAgo: 1_000),
            file("/Users/test/ancient2.mov", size: 20, daysAgo: 2_000),
            file("/Users/test/unknown.mov", size: 5_000, daysAgo: nil),
        ]

        let groups = LargeFileGroups.groups(files, by: .age, root: root, now: now)

        // Oldest first; files without a date last.
        #expect(
            groups.map(\.key) == [
                .age(.overTwoYears), .age(.oneToTwoYears), .age(.sixToTwelveMonths), .age(.underSixMonths),
                .age(.unknown),
            ])
        #expect(groups[0].items.map(\.name) == ["ancient2.mov", "ancient.mov"])
    }

    @Test func kindClassification() {
        #expect(LargeFileKind.classify(name: "Movie.MKV") == .video)
        #expect(LargeFileKind.classify(name: "disk.sparseimage") == .diskImage)
        #expect(LargeFileKind.classify(name: "backup.tar.gz") == .archive)
        #expect(LargeFileKind.classify(name: "noextension") == .other)
    }
}
