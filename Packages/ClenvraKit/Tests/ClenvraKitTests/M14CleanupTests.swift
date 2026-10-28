import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("M14 cleanup additions (CL-9, CL-10, ST-6)")
struct M14CleanupTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private var home: String { scratch.url.path(percentEncoded: false).trimmingTrailingSlash }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    // MARK: - CL-9: Mail attachments

    @Test("CL-9: downloaded copies in Mail Downloads are offered for review, owned by Mail")
    func mailDownloadsFoundAndOwned() async throws {
        let containerRel = "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/contract.pdf"
        let legacyRel = "Library/Mail Downloads/invoice.zip"
        try fixture.file(containerRel, bytes: 50_000)
        try fixture.file(legacyRel, bytes: 30_000)

        let rules = RuleCatalog.mailAttachments
        #expect(rules.count == 2)

        var foundCandidates: [CleanupCandidate] = []
        for rule in rules {
            let result = await RuleScanner.scan(
                rule, home: home, policy: ProtectionPolicy(home: home), ownerState: { _ in .notRunning }, now: now)
            foundCandidates.append(contentsOf: result.candidates)
        }

        let names = Set(foundCandidates.map(\.name))
        #expect(names == ["contract.pdf", "invoice.zip"])
        for candidate in foundCandidates {
            #expect(candidate.risk == .review)
            #expect(candidate.isSelectedByDefault == false)
            #expect(candidate.ownerBundleID == "com.apple.mail")
            #expect(candidate.status == .available)
        }
    }

    @Test("CL-9: a running Mail app blocks mail attachment cleanup")
    func runningMailBlocksAttachments() async throws {
        let rel = "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/photo.jpg"
        try fixture.file(rel, bytes: 20_000)

        let rule = try #require(RuleCatalog.mailAttachments.first { $0.id == "mailAttachments.container" })
        let result = await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: home),
            ownerState: { $0 == "com.apple.mail" ? .running : .notRunning }, now: now)

        let item = try #require(result.candidates.first)
        #expect(item.status == .inUse)
        #expect(item.isSelectedByDefault == false)
    }

    @Test("CL-9: mailbox itself is protected and never offered")
    func mailboxIsProtected() throws {
        let policy = ProtectionPolicy(home: home)
        #expect(policy.protection(for: home + "/Library/Mail") == .userData)
        #expect(policy.protection(for: home + "/Library/Mail/V10") == .userData)
        #expect(policy.protection(for: home + "/Library/Mail/V10/MailData") == .userData)
    }

    // MARK: - CL-10: Temporary files

    @Test("CL-10: items older than 3 days in TMPDIR are offered for review; newer items are skipped")
    func temporaryFilesAgeFiltering() async throws {
        let tmpDir = path("custom_tmp")
        try fixture.directory("custom_tmp")

        // 4 days old (should be offered)
        let oldFilePath = "custom_tmp/old_cache.tmp"
        try fixture.file(oldFilePath, bytes: 10_000)
        let fourDaysAgo = now.addingTimeInterval(-4 * 86_400)
        try setModificationDate(fourDaysAgo, at: path(oldFilePath))

        // 1 day old (should be skipped)
        let newFilePath = "custom_tmp/new_file.tmp"
        try fixture.file(newFilePath, bytes: 10_000)
        let oneDayAgo = now.addingTimeInterval(-1 * 86_400)
        try setModificationDate(oneDayAgo, at: path(newFilePath))

        // Old folder with old file (should be offered)
        let oldFolderPath = "custom_tmp/old_folder/data.bin"
        try fixture.file(oldFolderPath, bytes: 20_000)
        try setModificationDate(fourDaysAgo, at: path(oldFolderPath))
        try setModificationDate(fourDaysAgo, at: path("custom_tmp/old_folder"))

        // Folder with recently modified file inside (should be skipped)
        let activeFolderPath = "custom_tmp/active_folder/fresh.bin"
        try fixture.file(activeFolderPath, bytes: 20_000)
        try setModificationDate(oneDayAgo, at: path(activeFolderPath))
        try setModificationDate(fourDaysAgo, at: path("custom_tmp/active_folder"))

        let rule = RuleCatalog.temporaryFilesRule(root: tmpDir)
        let result = await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: home), ownerState: { _ in .notRunning }, now: now)

        let names = Set(result.candidates.map(\.name))
        #expect(names.contains("old_cache.tmp"))
        #expect(names.contains("old_folder"))
        #expect(!names.contains("new_file.tmp"))
        #expect(!names.contains("active_folder"))

        for candidate in result.candidates {
            #expect(candidate.risk == .review)
            #expect(candidate.isSelectedByDefault == false)
        }
    }

    @Test("CL-10: sockets and special files are skipped; items of running apps are marked in use")
    func temporaryFilesSocketsAndInUse() async throws {
        let tmpDir = path("custom_tmp")
        try fixture.directory("custom_tmp")

        let fourDaysAgo = now.addingTimeInterval(-4 * 86_400)

        // Regular file older than 3 days
        let regularPath = "custom_tmp/regular.tmp"
        try fixture.file(regularPath, bytes: 5_000)
        try setModificationDate(fourDaysAgo, at: path(regularPath))

        // Create a unix domain socket in custom_tmp
        let socketPath = path("custom_tmp/service.sock")
        let sockFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if sockFD >= 0 {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let socketBytes = socketPath.utf8CString
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                socketBytes.withUnsafeBufferPointer { buf in
                    memcpy(ptr, buf.baseAddress, min(Int(buf.count), 104))
                }
            }
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(sockFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            close(sockFD)
            #expect(bindResult == 0)
        }

        // Temporary folder named like a bundle identifier
        let appTempFolder = "custom_tmp/com.example.runningapp"
        try fixture.file(appTempFolder + "/scratch.bin", bytes: 10_000)
        try setModificationDate(fourDaysAgo, at: path(appTempFolder + "/scratch.bin"))
        try setModificationDate(fourDaysAgo, at: path(appTempFolder))

        let rule = RuleCatalog.temporaryFilesRule(root: tmpDir)
        let result = await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: home),
            ownerState: { $0 == "com.example.runningapp" ? .running : .notRunning }, now: now)

        let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.name, $0) })
        #expect(byName["regular.tmp"]?.status == .available)
        #expect(byName["service.sock"] == nil, "sockets must be skipped")
        #expect(byName["com.example.runningapp"]?.status == .inUse)
    }

    // MARK: - ST-6: Empty folders

    @Test("ST-6: empty folders and folders with only .DS_Store are found in Downloads, Desktop, Documents")
    func emptyFoldersFound() async throws {
        // Downloads: empty folder
        try fixture.directory("Downloads/EmptyFolder")

        // Downloads: folder with only .DS_Store
        try fixture.file("Downloads/FolderWithDSStore/.DS_Store", bytes: 6_148)

        // Downloads: nested empty subfolders
        try fixture.directory("Downloads/OuterEmpty/InnerEmpty/DeeperEmpty")

        // Downloads: non-empty folder (has a regular file)
        try fixture.file("Downloads/NonEmpty/file.txt", bytes: 100)

        // Desktop: empty folder
        try fixture.directory("Desktop/OldProject")

        // Documents: empty folder
        try fixture.directory("Documents/EmptyDocs")

        let rules = RuleCatalog.emptyFolders
        var allCandidates: [CleanupCandidate] = []
        for rule in rules {
            let result = await RuleScanner.scan(
                rule, home: home, policy: ProtectionPolicy(home: home), ownerState: { _ in .notRunning }, now: now)
            allCandidates.append(contentsOf: result.candidates)
        }

        let names = Set(allCandidates.map(\.name))
        #expect(names.contains("EmptyFolder"))
        #expect(names.contains("FolderWithDSStore"))
        #expect(names.contains("OuterEmpty"))
        #expect(!names.contains("InnerEmpty"), "outermost empty folder is offered")
        #expect(!names.contains("NonEmpty"))
        #expect(names.contains("OldProject"))
        #expect(names.contains("EmptyDocs"))

        // Root folders themselves are never offered
        #expect(!names.contains("Downloads"))
        #expect(!names.contains("Desktop"))
        #expect(!names.contains("Documents"))

        for candidate in allCandidates {
            #expect(candidate.risk == .review)
            #expect(candidate.isSelectedByDefault == false)
        }
    }

    @Test("ST-6: packages and dot-folder markers (.git) are never offered or descended into")
    func emptyFoldersIgnoresPackagesAndDotFolders() async throws {
        // Folder containing .git marker
        try fixture.file("Downloads/GitRepo/.git/config", bytes: 50)
        try fixture.directory("Downloads/GitRepo/EmptySubfolder")

        // Dot folder itself
        try fixture.directory("Downloads/.hidden_empty")

        // Package (.app bundle)
        try fixture.directory("Downloads/Test.app/Contents/Resources/EmptyDir")

        // Photos library package
        try fixture.directory("Downloads/Library.photoslibrary/EmptyDir")

        // .bundle
        try fixture.directory("Downloads/Plugin.bundle/Contents/EmptyDir")

        let rule = try #require(RuleCatalog.emptyFolders.first { $0.id == "emptyFolders.downloads" })
        let result = await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: home), ownerState: { _ in .notRunning }, now: now)

        let paths = Set(result.candidates.map(\.path))
        #expect(!paths.contains(where: { $0.contains("GitRepo") }))
        #expect(!paths.contains(where: { $0.contains(".hidden") }))
        #expect(!paths.contains(where: { $0.contains(".app") }))
        #expect(!paths.contains(where: { $0.contains(".photoslibrary") }))
        #expect(!paths.contains(where: { $0.contains(".bundle") }))
    }

    @Test("ST-6: empty folders can be safely moved to Trash")
    func emptyFoldersDeletion() async throws {
        try fixture.directory("Downloads/TrashableEmpty")
        try fixture.file("Downloads/TrashableWithDS/.DS_Store", bytes: 4_096)

        let rule = try #require(RuleCatalog.emptyFolders.first { $0.id == "emptyFolders.downloads" })
        let result = await RuleScanner.scan(
            rule, home: home, policy: ProtectionPolicy(home: home), ownerState: { _ in .notRunning }, now: now)

        #expect(result.candidates.count == 2)

        let policy = ProtectionPolicy(home: home)
        let ownerState: @Sendable (String) -> OwnerState = { _ in .notRunning }
        let deleter = DeletionExecutor(
            gate: DeletionGate(policy: policy, ownerState: ownerState),
            log: ActivityLog(directory: fixture.url("log")),
            trash: FixtureTrash(directory: path("FixtureTrash")))

        let items = result.candidates.map {
            DeletionItem(
                path: $0.path,
                ruleRoot: $0.ruleRoot,
                expected: $0.snapshot,
                ownerBundleID: nil,
                freedBytes: $0.reclaimableSize,
                section: .cleanup)
        }

        let deletionResults = await deleter.run(items, mode: .moveToTrash)
        #expect(
            deletionResults.allSatisfy {
                if case .movedToTrash = $0.outcome { true } else { false }
            })
        #expect(!FileManager.default.fileExists(atPath: path("Downloads/TrashableEmpty")))
        #expect(!FileManager.default.fileExists(atPath: path("Downloads/TrashableWithDS")))
    }

    // MARK: - Section classification

    @Test("CleanupCategory section property maps developer vs cleanup categories")
    func categorySectionMapping() {
        #expect(CleanupCategory.mailAttachments.section == .cleanup)
        #expect(CleanupCategory.temporaryFiles.section == .cleanup)
        #expect(CleanupCategory.emptyFolders.section == .cleanup)
        #expect(CleanupCategory.appCaches.section == .cleanup)
        #expect(CleanupCategory.xcode.section == .developer)
        #expect(CleanupCategory.projectArtifacts.section == .developer)
    }

    // MARK: - Helper

    private func setModificationDate(_ date: Date, at path: String) throws {
        var times = [
            timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0),
            timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0),
        ]
        guard utimes(path, &times) == 0 else {
            throw FileSystemError(code: errno, operation: "utimes", path: path)
        }
    }
}

extension String {
    fileprivate var trimmingTrailingSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}

/// Moves items into a folder inside the test directory that no rule scans.
private struct FixtureTrash: TrashOperations {
    let directory: String

    func moveToTrash(path: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        let dest = directory + "/" + name
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return dest
    }
}
