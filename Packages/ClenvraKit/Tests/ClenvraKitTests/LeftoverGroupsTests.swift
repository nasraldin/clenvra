import Foundation
import Testing

@testable import ClenvraKit

@Suite("LeftoverGroups")
struct LeftoverGroupsTests {
    private func item(
        _ path: String, size: Int64, evidence: [Evidence], handling: OwnedItem.Handling = .removable
    ) -> OwnedItem {
        OwnedItem(
            path: path, ruleRoot: "/Users/test/Library", kind: .applicationSupport,
            snapshot: FileSnapshot(
                identity: FileIdentity(device: 1, inode: UInt64(path.utf8.count)), kind: .directory,
                logicalSize: size, modificationDate: nil),
            allocatedSize: size, reclaimableSize: size, modificationDate: nil, confidence: .possible,
            evidence: evidence, sharedWith: [], handling: handling, containsProtectedItem: false,
            isSelectedByDefault: false)
    }

    @Test func leftoversGroupByOwner() {
        let items = [
            item("/L/Caches/com.vendor.Editor", size: 10, evidence: [.exactBundleIdentifierPath("com.vendor.Editor")]),
            item(
                "/L/Containers/com.vendor.Editor.helper", size: 5,
                evidence: [.containerMetadata("com.vendor.Editor.helper")]),
            item(
                "/L/Preferences/com.other.Tool.plist", size: 1,
                evidence: [.exactBundleIdentifierPath("com.other.Tool"), .appInTrash("Tool")]),
            item(
                "/L/Application Support/com.other.Tool", size: 100,
                evidence: [.exactBundleIdentifierPath("com.other.Tool")]),
            item("/L/Caches/COM.VENDOR.EDITOR", size: 2, evidence: [.exactBundleIdentifierPath("COM.VENDOR.EDITOR")]),
        ]

        let groups = LeftoverGroups.groups(items)

        // Largest group first; related identifiers (helpers, other case) join the app's group.
        #expect(groups.map(\.owner) == [.app(identifier: "com.other.Tool"), .app(identifier: "com.vendor.Editor")])
        #expect(groups[0].name == "Tool")
        #expect(groups[0].totalBytes == 101)
        #expect(groups[0].items.map(\.reclaimableSize) == [100, 1])
        #expect(groups[1].name == "com.vendor.Editor")
        #expect(groups[1].items.count == 3)
        #expect(groups[1].totalBytes == 17)
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test func unknownOwnerLast() {
        let items = [
            item("/L/Caches/Mystery", size: 1_000, evidence: [.exactName("Mystery")]),
            item("/L/Caches/com.small.App", size: 1, evidence: [.exactBundleIdentifierPath("com.small.App")]),
            item("/L/Caches/Other", size: 50, evidence: []),
        ]

        let groups = LeftoverGroups.groups(items)

        #expect(groups.map(\.owner) == [.app(identifier: "com.small.App"), .unknown])
        #expect(groups.last?.items.count == 2)
        #expect(groups.last?.name == nil)
    }

    @Test func groupSelectionIncludesOnlyGivenRemovableItems() {
        let removable = item("/L/Caches/com.a.App", size: 1, evidence: [.exactBundleIdentifierPath("com.a.App")])
        let system = item(
            "/Library/Caches/com.a.App", size: 2, evidence: [.exactBundleIdentifierPath("com.a.App")],
            handling: .revealOnly)
        let group = LeftoverGroups.groups([removable, system])[0]

        #expect(group.selectablePaths { $0.handling == .removable } == [removable.path])
    }
}
