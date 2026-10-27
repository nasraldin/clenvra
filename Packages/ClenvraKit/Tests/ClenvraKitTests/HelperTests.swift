import Darwin
import Foundation
import Security
import Testing

@testable import ClenvraKit

/// The privileged helper's own checks (`technical-architecture.md` §6a): a narrow allowlist, the full deletion gate
/// run again, removal into the requesting user's Trash, and a pinned code signature. A temporary folder stands in
/// for both the system root and the user's home, so nothing here needs root or touches the real system.
@Suite("Privileged helper")
struct HelperTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("home/.Trash")
    }

    private var system: String { String(scratch.url.path(percentEncoded: false).dropLast()) + "/system" }
    private var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) + "/home" }
    private func path(_ relative: String) -> String { fixture.url(relative).path(percentEncoded: false) }

    private var allowlist: HelperAllowlist { HelperAllowlist(systemRoot: system) }

    /// A plan item exactly as the app's scanner would produce it now.
    private func item(_ relative: String, root: String, owner: String? = nil) throws -> DeletionItem {
        let full = path("system/" + relative)
        return DeletionItem(
            path: full, ruleRoot: system + "/" + root, expected: try SafeWalk.resolve(full).snapshot,
            ownerBundleID: owner, freedBytes: 10, section: .cleanup)
    }

    private func service(
        protecting ownPaths: [String] = [], processPaths: @escaping @Sendable () -> [String]? = { [] }
    ) -> HelperService {
        HelperService(
            allowlist: allowlist, clientHome: home, clientUID: getuid(),
            log: ActivityLog(directory: fixture.url("helper-log")), ownPaths: ownPaths, processPaths: processPaths)
    }

    private func request(_ items: [DeletionItem], owners: [String: String] = [:]) -> HelperRequest {
        HelperRequest(operationID: UUID(), mode: .moveToTrash, items: items, ownerBundlePaths: owners)
    }

    // MARK: - Allowlist

    @Test("the allowlist accepts only the documented system locations")
    func allowlistAccepts() throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        try fixture.file("system/Library/Logs/Vendor/old.log", bytes: 10)
        try fixture.file("system/Library/Application Support/Vendor/data", bytes: 10)
        try fixture.file("system/Library/LaunchDaemons/com.vendor.helper.plist", bytes: 10)
        try fixture.file("system/Library/LaunchAgents/com.vendor.agent.plist", bytes: 10)
        try fixture.file("system/Library/PrivilegedHelperTools/com.vendor.helper", bytes: 10)
        try fixture.file("system/Applications/Old.app/Contents/Info.plist", bytes: 10)
        try fixture.file("system/private/var/log/system.log.0.gz", bytes: 10)

        #expect(allowlist.permits(try item("Library/Caches/com.vendor.app", root: "Library/Caches")))
        #expect(allowlist.permits(try item("Library/Logs/Vendor/old.log", root: "Library/Logs")))
        #expect(allowlist.permits(try item("Library/Application Support/Vendor", root: "Library/Application Support")))
        #expect(
            allowlist.permits(try item("Library/LaunchDaemons/com.vendor.helper.plist", root: "Library/LaunchDaemons")))
        #expect(
            allowlist.permits(try item("Library/LaunchAgents/com.vendor.agent.plist", root: "Library/LaunchAgents")))
        #expect(
            allowlist.permits(
                try item("Library/PrivilegedHelperTools/com.vendor.helper", root: "Library/PrivilegedHelperTools")))
        #expect(allowlist.permits(try item("Applications/Old.app", root: "Applications")))
        #expect(allowlist.permits(try item("private/var/log/system.log.0.gz", root: "private/var/log")))
    }

    @Test("anything else is refused by the allowlist, whatever the app claims")
    func allowlistRefusals() throws {
        try fixture.file("system/Library/Preferences/com.vendor.plist", bytes: 10)
        try fixture.file("system/Library/LaunchDaemons/sub/com.vendor.plist", bytes: 10)
        try fixture.file("system/Library/LaunchDaemons/notes.txt", bytes: 10)
        try fixture.directory("system/Library/LaunchDaemons/folder.plist")
        try fixture.file("system/Applications/Vendor/Tool.app/Contents/x", bytes: 10)
        try fixture.file("system/Applications/readme.txt", bytes: 10)
        try fixture.file("system/Applications/Fake.app", bytes: 10)
        try fixture.file("system/private/var/log/system.log", bytes: 10)
        try fixture.file("system/Library/Caches/x/blob", bytes: 10)

        // Root not on the list.
        #expect(!allowlist.permits(try item("Library/Preferences/com.vendor.plist", root: "Library/Preferences")))
        // Launch items only directly in their folder, only .plist files.
        #expect(
            !allowlist.permits(try item("Library/LaunchDaemons/sub/com.vendor.plist", root: "Library/LaunchDaemons")))
        #expect(!allowlist.permits(try item("Library/LaunchDaemons/notes.txt", root: "Library/LaunchDaemons")))
        #expect(!allowlist.permits(try item("Library/LaunchDaemons/folder.plist", root: "Library/LaunchDaemons")))
        // Apps only as bundles directly in /Applications.
        #expect(!allowlist.permits(try item("Applications/Vendor/Tool.app", root: "Applications")))
        #expect(!allowlist.permits(try item("Applications/readme.txt", root: "Applications")))
        #expect(!allowlist.permits(try item("Applications/Fake.app", root: "Applications")))
        // Logs in /private/var/log only as rotated archives.
        #expect(!allowlist.permits(try item("private/var/log/system.log", root: "private/var/log")))
        // A root that is a real allowlisted folder, but the item claims a narrower root that is not on the list.
        #expect(!allowlist.permits(try item("Library/Caches/x/blob", root: "Library/Caches/x")))
        // The root itself, or an item outside the root it claims.
        #expect(!allowlist.permits(try item("Library/Caches", root: "Library/Caches")))
        #expect(!allowlist.permits(try item("Library/Preferences/com.vendor.plist", root: "Library/Caches")))
    }

    // MARK: - Performing requests

    @Test("a path outside the allowlist is refused by the helper even though the app sent it (safety case S24)")
    func refusesOutsideAllowlist() async throws {
        try fixture.file("system/Library/Preferences/com.vendor.plist", bytes: 10)
        let outside = try item("Library/Preferences/com.vendor.plist", root: "Library/Preferences")

        let response = await service().perform(request([outside]))

        #expect(response.outcomes == [.skipped(.outsideRoot)])
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("allowed items go to the requesting user's Trash, never root's, and the helper logs them")
    func movesToUserTrash() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        let cache = try item("Library/Caches/com.vendor.app", root: "Library/Caches")

        let response = await service().perform(request([cache]))

        guard case .movedToTrash(let trashPath) = response.outcomes.first else {
            Issue.record("expected a move to the Trash, got \(response.outcomes)")
            return
        }
        #expect(trashPath == home + "/.Trash/com.vendor.app")
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        let logged = try await ActivityLog(directory: fixture.url("helper-log")).readAll().records
        #expect(logged.map(\.outcome).contains(.movedToTrash(trashPath: trashPath)))
    }

    @Test("a name already in the Trash is never overwritten")
    func trashNameCollision() async throws {
        try fixture.file("home/.Trash/com.vendor.app", bytes: 5)
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)

        let response = await service().perform(
            request([try item("Library/Caches/com.vendor.app", root: "Library/Caches")]))

        guard case .movedToTrash(let trashPath) = response.outcomes.first else {
            Issue.record("expected a move to the Trash, got \(response.outcomes)")
            return
        }
        #expect(trashPath != home + "/.Trash/com.vendor.app")
        #expect(trashPath.hasPrefix(home + "/.Trash/com.vendor.app"))
        #expect(try Data(contentsOf: URL(filePath: home + "/.Trash/com.vendor.app")).count == 5)
    }

    @Test("an owned item is refused unless its owner app is known and not running")
    func ownerChecks() async throws {
        try fixture.file("system/Library/Caches/com.vendor.a/blob", bytes: 10)
        try fixture.file("system/Library/Caches/com.vendor.b/blob", bytes: 10)
        try fixture.file("system/Library/Caches/com.vendor.c/blob", bytes: 10)
        let unknownOwner = try item("Library/Caches/com.vendor.a", root: "Library/Caches", owner: "com.vendor.a")
        let running = try item("Library/Caches/com.vendor.b", root: "Library/Caches", owner: "com.vendor.b")
        let idle = try item("Library/Caches/com.vendor.c", root: "Library/Caches", owner: "com.vendor.c")
        let owners = ["com.vendor.b": "/Applications/B.app", "com.vendor.c": "/Applications/C.app"]

        let response = await service(processPaths: { ["/Applications/B.app/Contents/MacOS/B"] })
            .perform(request([unknownOwner, running, idle], owners: owners))

        #expect(response.outcomes.count == 3)
        #expect(response.outcomes[0] == .skipped(.inUse))
        #expect(response.outcomes[1] == .skipped(.inUse))
        #expect(response.outcomes[2].isMovedToTrash)
    }

    @Test("items of security and management agents are refused (safety case S23, in the helper too)")
    func refusesManagedAgents() async throws {
        try fixture.file("system/Library/LaunchDaemons/com.crowdstrike.falcon.plist", bytes: 10)
        try fixture.file("system/Library/Caches/com.jamf.agent/blob", bytes: 10)

        let response = await service().perform(
            request([
                try item("Library/LaunchDaemons/com.crowdstrike.falcon.plist", root: "Library/LaunchDaemons"),
                try item("Library/Caches/com.jamf.agent", root: "Library/Caches"),
            ]))

        #expect(response.outcomes == [.skipped(.protected(.custom)), .skipped(.protected(.custom))])
    }

    @Test("the helper never removes its own log or the Clenvra app it ships in")
    func protectsItself() async throws {
        try fixture.file("system/Library/Application Support/Clenvra/Helper/activity.jsonl", bytes: 10)
        try fixture.file("system/Applications/Clenvra.app/Contents/Info.plist", bytes: 10)
        let own = [system + "/Library/Application Support/Clenvra", system + "/Applications/Clenvra.app"]

        let response = await service(protecting: own).perform(
            request([
                try item("Library/Application Support/Clenvra", root: "Library/Application Support"),
                try item("Applications/Clenvra.app", root: "Applications"),
            ]))

        #expect(response.outcomes == [.skipped(.protected(.custom)), .skipped(.protected(.custom))])
    }

    @Test("an item that changed after the app scanned it is refused by the helper's own gate")
    func helperRunsTheGate() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app", bytes: 10)
        let scanned = try item("Library/Caches/com.vendor.app", root: "Library/Caches")
        try FileManager.default.removeItem(atPath: scanned.path)
        try fixture.file("system/Library/Caches/com.vendor.app", bytes: 10)

        let response = await service().perform(request([scanned]))

        #expect(response.outcomes == [.skipped(.changedSinceScan)])
    }

    @Test("a dry run checks everything and changes nothing")
    func dryRun() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        let cache = try item("Library/Caches/com.vendor.app", root: "Library/Caches")

        let response = await service().perform(
            HelperRequest(operationID: UUID(), mode: .dryRun, items: [cache], ownerBundlePaths: [:]))

        #expect(response.outcomes == [.wouldDelete])
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    // MARK: - Put Back

    @Test("an item the helper moved can be put back to its system location")
    func restore() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        let cache = try item("Library/Caches/com.vendor.app", root: "Library/Caches")
        let service = service()
        let response = await service.perform(request([cache]))
        guard case .movedToTrash = response.outcomes.first else {
            Issue.record("expected a move first")
            return
        }
        let record = try #require(try await ActivityLog(directory: fixture.url("helper-log")).readAll().records.last)

        #expect(await service.restore(record) == nil)
        #expect(FileManager.default.fileExists(atPath: cache.path + "/blob"))
    }

    @Test("Put Back only restores what the helper itself moved: a forged record is refused (privilege escalation)")
    func restoreRefusesForgedRecord() async throws {
        // The user drops their own file in the Trash and asks the helper to "put it back" into a launch daemon
        // folder, with the file's real identity. Root must never move it there.
        try fixture.directory("system/Library/LaunchDaemons")
        try fixture.file("home/.Trash/evil.plist", bytes: 10)
        let identity = try SafeWalk.resolve(home + "/.Trash/evil.plist").snapshot.identity
        let forged = ActivityRecord(
            operationID: UUID(), date: Date(), section: .startup,
            itemPath: system + "/Library/LaunchDaemons/evil.plist", bytes: 10,
            outcome: .movedToTrash(trashPath: home + "/.Trash/evil.plist"), identity: identity)

        #expect(await service().restore(forged) == .notRestorable)
        #expect(!FileManager.default.fileExists(atPath: system + "/Library/LaunchDaemons/evil.plist"))
        #expect(FileManager.default.fileExists(atPath: home + "/.Trash/evil.plist"))
    }

    @Test("Put Back uses the helper's own record: changed paths in the app's copy are ignored")
    func restoreIgnoresClientPaths() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        try fixture.directory("system/Library/LaunchDaemons")
        let service = service()
        _ = await service.perform(request([try item("Library/Caches/com.vendor.app", root: "Library/Caches")]))
        let logged = try #require(try await ActivityLog(directory: fixture.url("helper-log")).readAll().records.last)
        // Same operation and item, but the app claims a different destination.
        let tampered = ActivityRecord(
            operationID: logged.operationID, date: logged.date, section: logged.section,
            itemPath: system + "/Library/LaunchDaemons/com.vendor.app", bytes: 10, outcome: logged.outcome,
            identity: logged.identity)

        #expect(await service.restore(tampered) == .notRestorable)
        #expect(!FileManager.default.fileExists(atPath: system + "/Library/LaunchDaemons/com.vendor.app"))
    }

    @Test("Put Back refuses when the Trash entry was replaced, including by a symlink")
    func restoreRefusesSwappedEntry() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app", bytes: 10)
        let service = service()
        _ = await service.perform(request([try item("Library/Caches/com.vendor.app", root: "Library/Caches")]))
        let logged = try #require(try await ActivityLog(directory: fixture.url("helper-log")).readAll().records.last)
        guard case .movedToTrash(let trashPath) = logged.outcome else {
            Issue.record("expected a move first")
            return
        }
        try FileManager.default.removeItem(atPath: trashPath)
        #expect(symlink(home + "/Documents", trashPath) == 0)

        #expect(await service.restore(logged) == .notInTrash)
        #expect(!FileManager.default.fileExists(atPath: system + "/Library/Caches/com.vendor.app"))
    }

    // MARK: - The user's Trash is the user's, not root's

    @Test("if the user's Trash is a symlink, nothing is moved through it (root would follow it anywhere)")
    func trashSymlinkRefused() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        try fixture.directory("system/Library/LaunchDaemons")
        try FileManager.default.removeItem(atPath: home + "/.Trash")
        #expect(symlink(system + "/Library/LaunchDaemons", home + "/.Trash") == 0)
        let cache = try item("Library/Caches/com.vendor.app", root: "Library/Caches")

        let response = await service().perform(request([cache]))

        #expect(!(response.outcomes.first?.isMovedToTrash ?? true))
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: system + "/Library/LaunchDaemons").isEmpty)
    }

    @Test("if the user's Trash belongs to someone else, nothing is moved into it")
    func trashOwnerChecked() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        let cache = try item("Library/Caches/com.vendor.app", root: "Library/Caches")
        let stranger = HelperService(
            allowlist: allowlist, clientHome: home, clientUID: getuid() + 1,
            log: ActivityLog(directory: fixture.url("helper-log")), processPaths: { [] })

        let response = await stranger.perform(request([cache]))

        #expect(!(response.outcomes.first?.isMovedToTrash ?? true))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Put Back refuses when the user's Trash was swapped for a symlink after the move")
    func restoreThroughSymlinkedTrash() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app", bytes: 10)
        let service = service()
        _ = await service.perform(request([try item("Library/Caches/com.vendor.app", root: "Library/Caches")]))
        let logged = try #require(try await ActivityLog(directory: fixture.url("helper-log")).readAll().records.last)
        // Move the real Trash aside and point ~/.Trash at it through a symlink.
        #expect(rename(home + "/.Trash", home + "/RealTrash") == 0)
        #expect(symlink(home + "/RealTrash", home + "/.Trash") == 0)

        #expect(await service.restore(logged) != nil)
        #expect(!FileManager.default.fileExists(atPath: system + "/Library/Caches/com.vendor.app"))
    }

    // MARK: - Irreversible removal and who may connect

    @Test("permanent removal is allowed only for rotated system logs")
    func irreversibleOnlyForLogArchives() async throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        try fixture.file("system/private/var/log/system.log.0.gz", bytes: 10)
        let cache = try item("Library/Caches/com.vendor.app", root: "Library/Caches")
        let archive = try item("private/var/log/system.log.0.gz", root: "private/var/log")

        let response = await service().perform(
            HelperRequest(operationID: UUID(), mode: .irreversible, items: [cache, archive], ownerBundlePaths: [:]))

        #expect(response.outcomes == [.skipped(.outsideRoot), .removedPermanently])
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test("only administrators may use the helper")
    func administratorsOnly() throws {
        let groups = try #require(groupNames(of: getuid()))
        #expect(HelperAuthorization.isAdministrator(uid: getuid()) == groups.contains("admin"))
        #expect(!HelperAuthorization.isAdministrator(uid: 4_000_000))  // no such user
    }

    private func groupNames(of uid: uid_t) -> Set<String>? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/id")
        process.arguments = ["-Gn", String(uid)]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    // MARK: - Transport and identity

    @Test("requests and responses survive the trip over XPC as JSON")
    func codableRoundTrip() throws {
        try fixture.file("system/Library/Caches/com.vendor.app/blob", bytes: 10)
        let original = request(
            [try item("Library/Caches/com.vendor.app", root: "Library/Caches", owner: "com.vendor.app")],
            owners: ["com.vendor.app": "/Applications/V.app"])
        let response = HelperResponse(outcomes: [.movedToTrash(trashPath: "/x"), .skipped(.outsideRoot)])

        #expect(try HelperRequest.decode(original.encoded()) == original)
        #expect(try HelperResponse.decode(response.encoded()) == response)
        #expect(throws: (any Error).self) { try HelperRequest.decode(Data("not json".utf8)) }
    }

    @Test("a client signed ad hoc with Clenvra's identifier does not meet the helper's requirement (safety case S25)")
    func rejectsImpostorClient() throws {
        let impostor = path("impostor")
        #expect(copyfile("/usr/bin/true", impostor, nil, copyfile_flags_t(COPYFILE_ALL)) == 0)
        #expect(run("/usr/bin/codesign", ["-s", "-", "-f", "-i", HelperIdentity.appIdentifier, impostor]) == 0)

        #expect(!HelperIdentity.satisfies(path: impostor, requirement: HelperIdentity.clientRequirement))
        #expect(!HelperIdentity.satisfies(path: "/usr/bin/true", requirement: HelperIdentity.clientRequirement))
        #expect(HelperIdentity.clientRequirement.contains(HelperIdentity.teamIdentifier))
        #expect(HelperIdentity.helperRequirement.contains(HelperIdentity.helperIdentifier))
    }

    private func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
