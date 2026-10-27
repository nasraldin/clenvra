import Foundation
import ServiceManagement
import Testing

@testable import ClenvraKit

@Suite("LaunchItemReader")
struct LaunchItemReaderTests {
    private let scratch: TemporaryDirectory

    init() throws {
        scratch = try TemporaryDirectory()
    }

    private func subpath(_ relative: String) -> String {
        scratch.url.appending(path: relative).path(percentEncoded: false)
    }

    private func createDirectory(_ relative: String) throws -> String {
        let path = subpath(relative)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    private func writePlist(
        _ dictionary: [String: Any],
        to relativePath: String,
        format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
        let filePath = subpath(relativePath)
        try FileManager.default.createDirectory(
            atPath: (filePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try data.write(to: URL(filePath: filePath))
        return filePath
    }

    private func makeApp(
        bundlePath: String,
        bundleIdentifier: String?,
        embeddedBundleIdentifiers: [String] = []
    ) -> InstalledApp {
        InstalledApp(
            id: bundlePath,
            url: URL(filePath: bundlePath, directoryHint: .isDirectory),
            bundleIdentifier: bundleIdentifier,
            name: (bundlePath as NSString).lastPathComponent,
            version: "1.0",
            build: "1",
            source: .other,
            isProtected: false,
            embeddedBundleIdentifiers: embeddedBundleIdentifiers
        )
    }

    // MARK: - Schedule derivation

    @Test("schedule derivation for RunAtLoad, KeepAlive, StartInterval, StartCalendarInterval, and none")
    func scheduleDerivation() throws {
        let userAgents = try createDirectory("userAgents")
        let systemAgents = try createDirectory("systemAgents")
        let systemDaemons = try createDirectory("systemDaemons")

        try writePlist(["Label": "job.atLoad", "RunAtLoad": true], to: "userAgents/job.atLoad.plist")
        try writePlist(["Label": "job.keepAliveBool", "KeepAlive": true], to: "userAgents/job.keepAliveBool.plist")
        try writePlist(
            ["Label": "job.keepAliveDict", "KeepAlive": ["SuccessfulExit": false]],
            to: "userAgents/job.keepAliveDict.plist"
        )
        try writePlist(["Label": "job.interval", "StartInterval": 300], to: "userAgents/job.interval.plist")
        try writePlist(
            ["Label": "job.calendarDict", "StartCalendarInterval": ["Hour": 3, "Minute": 15]],
            to: "userAgents/job.calendarDict.plist"
        )
        try writePlist(
            ["Label": "job.calendarArray", "StartCalendarInterval": [["Hour": 6], ["Hour": 18]]],
            to: "userAgents/job.calendarArray.plist"
        )
        try writePlist(
            ["Label": "job.none", "MachServices": ["com.test.service": true]],
            to: "userAgents/job.none.plist"
        )
        try writePlist(
            ["Label": "job.combined", "RunAtLoad": true, "KeepAlive": true, "StartInterval": 60],
            to: "userAgents/job.combined.plist"
        )
        try writePlist(
            ["Label": "job.falseSchedules", "RunAtLoad": false, "KeepAlive": false],
            to: "userAgents/job.falseSchedules.plist"
        )

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: systemAgents,
            systemDaemons: systemDaemons,
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        let itemMap = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.label.map { ($0, item) }
            }
        )

        #expect(itemMap["job.atLoad"]?.schedules == [.atLoad])
        #expect(itemMap["job.keepAliveBool"]?.schedules == [.keepAlive])
        #expect(itemMap["job.keepAliveDict"]?.schedules == [.keepAlive])
        #expect(itemMap["job.interval"]?.schedules == [.interval(seconds: 300)])
        #expect(itemMap["job.calendarDict"]?.schedules == [.calendar])
        #expect(itemMap["job.calendarArray"]?.schedules == [.calendar])
        #expect(itemMap["job.none"]?.schedules == [.onDemand])
        #expect(itemMap["job.combined"]?.schedules == [.atLoad, .keepAlive, .interval(seconds: 60)])
        #expect(itemMap["job.falseSchedules"]?.schedules == [.onDemand])
    }

    // MARK: - Program and arguments

    @Test("program from Program vs ProgramArguments[0] and arguments vector")
    func programAndArguments() throws {
        let userAgents = try createDirectory("userAgents")

        try writePlist(
            [
                "Label": "prog.explicit",
                "Program": "/bin/echo",
                "ProgramArguments": ["custom_arg0", "hello", "world"],
            ],
            to: "userAgents/prog.explicit.plist"
        )
        try writePlist(
            [
                "Label": "prog.fromArgs",
                "ProgramArguments": ["/bin/sleep", "10"],
            ],
            to: "userAgents/prog.fromArgs.plist"
        )
        try writePlist(
            ["Label": "prog.none"],
            to: "userAgents/prog.none.plist"
        )

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: try createDirectory("sysAgents"),
            systemDaemons: try createDirectory("sysDaemons"),
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        let itemMap = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.label.map { ($0, item) }
            }
        )

        let explicit = try #require(itemMap["prog.explicit"])
        #expect(explicit.program == "/bin/echo")
        #expect(explicit.arguments == ["custom_arg0", "hello", "world"])

        let fromArgs = try #require(itemMap["prog.fromArgs"])
        #expect(fromArgs.program == "/bin/sleep")
        #expect(fromArgs.arguments == ["/bin/sleep", "10"])

        let none = try #require(itemMap["prog.none"])
        #expect(none.program == nil)
        #expect(none.arguments.isEmpty)
    }

    // MARK: - ProgramState

    @Test("programState present, missing, and unknown")
    func programStateResolution() throws {
        let userAgents = try createDirectory("userAgents")
        let existingBinary = subpath("bin/existing")
        try FileManager.default.createDirectory(
            atPath: (existingBinary as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: existingBinary, contents: Data("test".utf8)))

        let missingBinary = subpath("bin/missing_binary")

        try writePlist(
            ["Label": "state.present", "Program": existingBinary],
            to: "userAgents/state.present.plist"
        )
        try writePlist(
            ["Label": "state.missing", "Program": missingBinary],
            to: "userAgents/state.missing.plist"
        )
        try writePlist(
            ["Label": "state.relative", "Program": "relative/tool"],
            to: "userAgents/state.relative.plist"
        )
        try writePlist(
            ["Label": "state.bundleProgram", "BundleProgram": "Contents/MacOS/Helper"],
            to: "userAgents/state.bundleProgram.plist"
        )
        try writePlist(
            ["Label": "state.unparseable"],
            to: "userAgents/state.unparseable.plist"
        )

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: try createDirectory("sysAgents"),
            systemDaemons: try createDirectory("sysDaemons"),
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        let itemMap = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.label.map { ($0, item) }
            }
        )

        #expect(itemMap["state.present"]?.programState == .present)
        #expect(itemMap["state.missing"]?.programState == .missing)
        #expect(itemMap["state.relative"]?.programState == .unknown)
        #expect(itemMap["state.bundleProgram"]?.programState == .unknown)
        #expect(itemMap["state.unparseable"]?.programState == .unknown)
    }

    // MARK: - AssociatedBundleIdentifiers

    @Test("associatedBundleIdentifiers as string and as array")
    func associatedBundleIdentifiersParsing() throws {
        let userAgents = try createDirectory("userAgents")

        try writePlist(
            ["Label": "assoc.single", "AssociatedBundleIdentifiers": "com.example.single"],
            to: "userAgents/assoc.single.plist"
        )
        try writePlist(
            [
                "Label": "assoc.array",
                "AssociatedBundleIdentifiers": ["com.example.first", "com.example.second"],
            ],
            to: "userAgents/assoc.array.plist"
        )
        try writePlist(
            ["Label": "assoc.absent"],
            to: "userAgents/assoc.absent.plist"
        )

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: try createDirectory("sysAgents"),
            systemDaemons: try createDirectory("sysDaemons"),
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        let itemMap = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.label.map { ($0, item) }
            }
        )

        #expect(itemMap["assoc.single"]?.associatedBundleIdentifiers == ["com.example.single"])
        #expect(itemMap["assoc.array"]?.associatedBundleIdentifiers == ["com.example.first", "com.example.second"])
        #expect(itemMap["assoc.absent"]?.associatedBundleIdentifiers.isEmpty == true)
    }

    // MARK: - Owner matching

    @Test("owner matching by the three rules and no fuzzy matching")
    func ownerMatching() throws {
        let userAgents = try createDirectory("userAgents")

        let appA = makeApp(
            bundlePath: subpath("Applications/AppA.app"),
            bundleIdentifier: "com.vendor.appA",
            embeddedBundleIdentifiers: ["com.vendor.appA.helper"]
        )
        let appB = makeApp(
            bundlePath: subpath("Applications/AppB.app"),
            bundleIdentifier: "com.vendor.appB"
        )
        let installedApps = [appA, appB]

        // Rule 1: AssociatedBundleIdentifiers matches app identifier or embedded identifier
        try writePlist(
            [
                "Label": "owner.rule1a",
                "AssociatedBundleIdentifiers": "com.vendor.appA",
                "Program": "/outside/tool",
            ],
            to: "userAgents/owner.rule1a.plist"
        )
        try writePlist(
            [
                "Label": "owner.rule1b",
                "AssociatedBundleIdentifiers": ["com.vendor.appA.helper"],
                "Program": "/outside/tool",
            ],
            to: "userAgents/owner.rule1b.plist"
        )

        // Rule 2: Program path starts with app bundle path + "/"
        try writePlist(
            [
                "Label": "owner.rule2",
                "Program": subpath("Applications/AppB.app/Contents/MacOS/Daemon"),
            ],
            to: "userAgents/owner.rule2.plist"
        )

        // Rule 3: Label equals bundleIdentifier, embedded identifier, or starts with "<bundleIdentifier>."
        try writePlist(
            [
                "Label": "com.vendor.appB",
                "Program": "/outside/tool",
            ],
            to: "userAgents/owner.rule3.exact.plist"
        )
        try writePlist(
            [
                "Label": "com.vendor.appA.helper",
                "Program": "/outside/tool",
            ],
            to: "userAgents/owner.rule3.embedded.plist"
        )
        try writePlist(
            [
                "Label": "com.vendor.appB.updater",
                "Program": "/outside/tool",
            ],
            to: "userAgents/owner.rule3.prefix.plist"
        )

        // No fuzzy match: similar names must NOT match
        try writePlist(
            [
                "Label": "com.vendorX.updater",
                "Program": "/outside/tool",
            ],
            to: "userAgents/owner.fuzzyX.plist"
        )
        try writePlist(
            [
                "Label": "com.vendor.app",
                "Program": "/outside/tool",
            ],
            to: "userAgents/owner.fuzzyShort.plist"
        )

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: try createDirectory("sysAgents"),
            systemDaemons: try createDirectory("sysDaemons"),
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: installedApps)
        let itemMap = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.label.map { ($0, item) }
            }
        )

        #expect(itemMap["owner.rule1a"]?.ownerAppPath == appA.id)
        #expect(itemMap["owner.rule1b"]?.ownerAppPath == appA.id)
        #expect(itemMap["owner.rule2"]?.ownerAppPath == appB.id)
        #expect(itemMap["com.vendor.appB"]?.ownerAppPath == appB.id)
        #expect(itemMap["com.vendor.appA.helper"]?.ownerAppPath == appA.id)
        #expect(itemMap["com.vendor.appB.updater"]?.ownerAppPath == appB.id)
        #expect(itemMap["com.vendorX.updater"]?.ownerAppPath == nil)
        #expect(itemMap["com.vendor.app"]?.ownerAppPath == nil)
    }

    // MARK: - isApple

    @Test("isApple returns true only when label starts with com.apple.")
    func isAppleCheck() throws {
        let userAgents = try createDirectory("userAgents")

        try writePlist(["Label": "com.apple.softwareupdate"], to: "userAgents/apple.true.plist")
        try writePlist(["Label": "com.apple"], to: "userAgents/apple.nodot.plist")
        try writePlist(["Label": "com.example.agent"], to: "userAgents/apple.false.plist")
        try writePlist(["RunAtLoad": true], to: "userAgents/apple.nolabel.plist")

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: try createDirectory("sysAgents"),
            systemDaemons: try createDirectory("sysDaemons"),
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        let itemByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.plistPath, $0) })

        #expect(itemByPath[subpath("userAgents/apple.true.plist")]?.isApple == true)
        #expect(itemByPath[subpath("userAgents/apple.nodot.plist")]?.isApple == false)
        #expect(itemByPath[subpath("userAgents/apple.false.plist")]?.isApple == false)
        #expect(itemByPath[subpath("userAgents/apple.nolabel.plist")]?.isApple == false)
    }

    // MARK: - Error handling and edge cases

    @Test("malformed plist, non-dictionary, oversized file, and symlink are listed with parseError")
    func errorHandling() throws {
        let userAgents = try createDirectory("userAgents")

        // 1. Malformed binary/XML
        let malformedPath = subpath("userAgents/malformed.plist")
        try Data("not a plist at all".utf8).write(to: URL(filePath: malformedPath))

        // 2. Non-dictionary plist (array)
        let arrayData = try PropertyListSerialization.data(
            fromPropertyList: ["first", "second"],
            format: .xml,
            options: 0
        )
        let arrayPath = subpath("userAgents/array.plist")
        try arrayData.write(to: URL(filePath: arrayPath))

        // 3. Oversized file (> 1 MiB)
        let oversizedPath = subpath("userAgents/oversized.plist")
        let bigData = Data(repeating: 0x41, count: (1024 * 1024) + 10)
        try bigData.write(to: URL(filePath: oversizedPath))

        // 4. Symlinked plist
        let realPlistPath = try writePlist(["Label": "real.target"], to: "realTarget.plist")
        let symlinkPath = subpath("userAgents/symlinked.plist")
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realPlistPath)

        // 5. Non-plist files and subdirectories should be ignored
        let textPath = subpath("userAgents/notes.txt")
        try Data("notes".utf8).write(to: URL(filePath: textPath))
        try FileManager.default.createDirectory(
            atPath: subpath("userAgents/nested.plist"),
            withIntermediateDirectories: true
        )

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: try createDirectory("sysAgents"),
            systemDaemons: try createDirectory("sysDaemons"),
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        let itemByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.plistPath, $0) })

        let malformed = try #require(itemByPath[malformedPath])
        #expect(malformed.parseError)
        #expect(malformed.label == nil)

        let arrayItem = try #require(itemByPath[arrayPath])
        #expect(arrayItem.parseError)

        let oversized = try #require(itemByPath[oversizedPath])
        #expect(oversized.parseError)

        let symlinked = try #require(itemByPath[symlinkPath])
        #expect(symlinked.parseError)

        #expect(itemByPath[textPath] == nil)
        #expect(itemByPath[subpath("userAgents/nested.plist")] == nil)
    }

    // MARK: - Status closure

    @Test("status closure result is propagated to LaunchItem")
    func statusClosurePropagation() throws {
        let userAgents = try createDirectory("userAgents")
        try writePlist(["Label": "status.a"], to: "userAgents/status.a.plist")
        try writePlist(["Label": "status.b"], to: "userAgents/status.b.plist")

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: try createDirectory("sysAgents"),
            systemDaemons: try createDirectory("sysDaemons"),
            status: { path in
                path.contains("status.a") ? .enabled : .requiresApproval
            }
        )
        let items = reader.read(installedApps: [])
        let itemMap = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.label.map { ($0, item) }
            }
        )

        #expect(itemMap["status.a"]?.status == .enabled)
        #expect(itemMap["status.b"]?.status == .requiresApproval)
    }

    @Test("serviceManagementStatus maps SMAppService status for arbitrary paths")
    func serviceManagementStatusMapping() {
        let status = LaunchItemReader.serviceManagementStatus("/Library/LaunchDaemons/nonexistent.plist")
        #expect(status == .notRegistered || status == .unknown)
    }

    // MARK: - Sorting

    @Test("sorting lists missing programs first, then by label")
    func sortingOrder() throws {
        let userAgents = try createDirectory("userAgents")
        let existingBinary = subpath("bin/live")
        try FileManager.default.createDirectory(
            atPath: (existingBinary as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: existingBinary, contents: Data("ok".utf8)))

        let missingA = subpath("bin/missing_a")
        let missingZ = subpath("bin/missing_z")

        try writePlist(["Label": "alpha.present", "Program": existingBinary], to: "userAgents/alpha.plist")
        try writePlist(["Label": "beta.present", "Program": existingBinary], to: "userAgents/beta.plist")
        try writePlist(["Label": "zebra.missing", "Program": missingZ], to: "userAgents/zebra.plist")
        try writePlist(["Label": "apple.missing", "Program": missingA], to: "userAgents/apple.plist")

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: try createDirectory("sysAgents"),
            systemDaemons: try createDirectory("sysDaemons"),
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        let labels = items.compactMap(\.label)

        #expect(labels == ["apple.missing", "zebra.missing", "alpha.present", "beta.present"])
    }

    // MARK: - Missing folder

    @Test("missing folder produces empty list without error")
    func missingFolderYieldsEmpty() {
        let reader = LaunchItemReader(
            userAgents: subpath("nonexistent_user_agents"),
            systemAgents: subpath("nonexistent_sys_agents"),
            systemDaemons: subpath("nonexistent_sys_daemons"),
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        #expect(items.isEmpty)
    }

    // MARK: - Domain assignment

    @Test("domain is correctly assigned per folder")
    func domainAssignment() throws {
        let userAgents = try createDirectory("userAgents")
        let systemAgents = try createDirectory("systemAgents")
        let systemDaemons = try createDirectory("systemDaemons")

        try writePlist(["Label": "user.item"], to: "userAgents/user.plist")
        try writePlist(["Label": "sys.agent.item"], to: "systemAgents/agent.plist")
        try writePlist(["Label": "sys.daemon.item"], to: "systemDaemons/daemon.plist")

        let reader = LaunchItemReader(
            userAgents: userAgents,
            systemAgents: systemAgents,
            systemDaemons: systemDaemons,
            status: { _ in .enabled }
        )
        let items = reader.read(installedApps: [])
        let itemMap = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.label.map { ($0, item) }
            }
        )

        #expect(itemMap["user.item"]?.domain == .userAgent)
        #expect(itemMap["sys.agent.item"]?.domain == .systemAgent)
        #expect(itemMap["sys.daemon.item"]?.domain == .systemDaemon)
    }

    // MARK: - Real filesystem integration test (read-only, asserts no crash)

    @Test("reading real user and system launch locations does not crash")
    func realLaunchLocationsReadDoesNotCrash() {
        let reader = LaunchItemReader()
        let items = reader.read(installedApps: [])
        // Asserts reading does not crash and returns a non-crashing list.
        #expect(items.count >= 0)
    }
}

@Suite("LaunchItemReader dangling links")
struct LaunchItemReaderDanglingLinkTests {
    @Test("a program path that is a symlink to a deleted file counts as missing")
    func danglingProgramLink() throws {
        let scratch = try TemporaryDirectory()
        let fixture = FixtureBuilder(root: scratch.url)
        try fixture.directory("agents")
        let link = try fixture.symlink(
            "bin/tool", to: fixture.url("Cellar/tool/1.0/bin/tool").path(percentEncoded: false))
        let plist: [String: Any] = ["Label": "com.example.tool", "Program": link.path(percentEncoded: false)]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: fixture.url("agents/com.example.tool.plist"))

        let reader = LaunchItemReader(
            userAgents: fixture.url("agents").path(percentEncoded: false), systemAgents: "/nonexistent",
            systemDaemons: "/nonexistent", status: { _ in .enabled })

        #expect(reader.read().first?.programState == .missing)
    }
}
