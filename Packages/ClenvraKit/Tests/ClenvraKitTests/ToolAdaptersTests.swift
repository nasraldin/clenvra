import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// A fake home and a fake tool directory of empty executables, both inside one `TemporaryDirectory`.
private final class ToolFixture {
    let root: TemporaryDirectory
    let home: String
    let bin: String

    init() throws {
        root = try TemporaryDirectory()
        home = root.url.appending(path: "home").path(percentEncoded: false)
        bin = root.url.appending(path: "bin").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    }

    var locator: ToolLocator { ToolLocator(searchPath: [bin]) }

    func tool(_ name: String) -> String { bin + "/" + name }

    func install(_ names: String...) throws {
        for name in names {
            let path = tool(name)
            #expect(FileManager.default.createFile(atPath: path, contents: Data()))
            #expect(chmod(path, 0o755) == 0)
        }
    }

    /// Creates `path` (absolute, or relative to home) holding one file of `bytes` bytes; returns the absolute path.
    @discardableResult
    func fill(_ path: String, bytes: Int = 10_000) throws -> String {
        let directory = path.hasPrefix("/") ? path : home + "/" + path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: directory + "/blob", contents: Data(count: bytes)))
        return directory
    }

    func measured(_ directory: String) async throws -> Int64? {
        try await StorageScanner.scan(root: directory).aggregate(at: directory)?.allocated
    }
}

private func adapter(_ id: String) throws -> any ToolAdapter {
    try #require(ToolAdapters.standard.first { $0.id == id })
}

private func inspect(_ id: String, _ fixture: ToolFixture, _ runner: FakeCommandRunner) async throws -> [ToolStorage] {
    try await adapter(id).inspect(locator: fixture.locator, runner: runner, home: fixture.home)
}

@Suite("Tool adapters")
struct ToolAdaptersTests {
    // MARK: Path-measured package managers

    @Test("no tool installed and no tool folders: no rows and no commands run")
    func absentToolsProduceNothing() async throws {
        let fixture = try ToolFixture()
        let runner = FakeCommandRunner()
        for adapter in ToolAdapters.standard {
            let rows = await adapter.inspect(locator: fixture.locator, runner: runner, home: fixture.home)
            #expect(rows.isEmpty, "\(adapter.id)")
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("adapter ids are unique")
    func uniqueIDs() {
        let ids = ToolAdapters.standard.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("pnpm: probes the store path, measures it and offers the exact prune command")
    func pnpmRow() async throws {
        let fixture = try ToolFixture()
        try fixture.install("pnpm")
        let store = try fixture.fill("Library/pnpm/store/v10", bytes: 50_000)
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("pnpm"), ["store", "path"], stdout: store + "\n")

        let rows = try await inspect("pnpm", fixture, runner)

        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == "pnpm.store")
        #expect(row.tool == "pnpm")
        #expect(row.category == .packageCaches)
        #expect(row.location == store)
        #expect(row.size == (try await fixture.measured(store)))
        #expect((row.size ?? 0) > 0)
        #expect(row.note.map { String(localized: $0) }?.isEmpty == false)
        let cleanup = try #require(row.cleanup)
        #expect(
            cleanup.command
                == Command(executable: fixture.tool("pnpm"), arguments: ["store", "prune"], timeout: .seconds(600)))
        #expect(cleanup.summary == "pnpm store prune")
        #expect(cleanup.risk == .safe)
        #expect(cleanup.isIrreversible)
        #expect(
            runner.commands
                == [Command(executable: fixture.tool("pnpm"), arguments: ["store", "path"], timeout: .seconds(10))])
    }

    @Test("pnpm: an unusable store path keeps the row with unknown size")
    func pnpmUnknownStore() async throws {
        let fixture = try ToolFixture()
        try fixture.install("pnpm")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("pnpm"), ["store", "path"], stdout: "ERR_PNPM something\n", status: 1)

        let row = try #require(try await inspect("pnpm", fixture, runner).first)
        #expect(row.location == nil)
        #expect(row.size == nil)
        #expect(row.cleanup?.summary == "pnpm store prune")
    }

    @Test("npm: cache path output with surrounding whitespace is trimmed and _cacache measured")
    func npmTrimsOutput() async throws {
        let fixture = try ToolFixture()
        try fixture.install("npm")
        let custom = fixture.root.url.appending(path: "npm-cache").path(percentEncoded: false)
        let cacache = try fixture.fill(custom + "/_cacache")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("npm"), ["config", "get", "cache"], stdout: "  \(custom)  \n\n")

        let row = try #require(try await inspect("npm", fixture, runner).first)
        #expect(row.id == "npm.cache")
        #expect(row.location == cacache)
        #expect(row.size == (try await fixture.measured(cacache)))
        #expect(
            row.cleanup?.command
                == Command(
                    executable: fixture.tool("npm"), arguments: ["cache", "clean", "--force"], timeout: .seconds(600)))
        #expect(row.cleanup?.summary == "npm cache clean --force")
        #expect(row.cleanup?.risk == .safe)
    }

    @Test(
        "npm: a failed, thrown or non-path probe falls back to ~/.npm",
        arguments: ["fail", "throw", "garbage"])
    func npmFallback(mode: String) async throws {
        let fixture = try ToolFixture()
        try fixture.install("npm")
        let cacache = try fixture.fill(".npm/_cacache")
        let runner = FakeCommandRunner()
        switch mode {
        case "fail": runner.stub(fixture.tool("npm"), ["config", "get", "cache"], stderr: "boom", status: 1)
        case "garbage": runner.stub(fixture.tool("npm"), ["config", "get", "cache"], stdout: "undefined\n")
        default: break
        }

        let row = try #require(try await inspect("npm", fixture, runner).first)
        #expect(row.location == cacache)
        #expect(row.size == (try await fixture.measured(cacache)))
    }

    @Test("a timed-out probe is not trusted even if it printed a path")
    func timedOutProbeIgnored() async throws {
        let fixture = try ToolFixture()
        try fixture.install("yarn")
        let cache = try fixture.fill("Library/Caches/Yarn/v6")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("yarn"), ["cache", "dir"], stdout: cache, status: -1, reason: .timedOut)

        let row = try #require(try await inspect("yarn", fixture, runner).first)
        #expect(row.location == nil)
        #expect(row.size == nil)
    }

    @Test(
        "probe-located tools measure the reported folder and offer their own command",
        arguments: [
            ("yarn", "yarn", ["cache", "dir"], "yarn.cache", ["cache", "clean"], Risk.safe),
            ("homebrew", "brew", ["--cache"], "homebrew.cache", ["cleanup", "-s"], Risk.safe),
            ("uv", "uv", ["cache", "dir"], "uv.cache", ["cache", "clean"], Risk.safe),
            ("pip", "pip3", ["cache", "dir"], "pip.cache", ["cache", "purge"], Risk.safe),
            ("go", "go", ["env", "GOMODCACHE"], "go.modcache", ["clean", "-modcache"], Risk.review),
        ])
    func probedTools(
        adapterID: String, executable: String, probe: [String], rowID: String, prune: [String], risk: Risk
    ) async throws {
        let fixture = try ToolFixture()
        try fixture.install(executable)
        let cache = try fixture.fill("caches/\(adapterID)")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool(executable), probe, stdout: cache + "\n")

        let row = try #require(try await inspect(adapterID, fixture, runner).first)
        #expect(row.id == rowID)
        #expect(row.location == cache)
        #expect(row.size == (try await fixture.measured(cache)))
        #expect(
            row.cleanup?.command
                == Command(executable: fixture.tool(executable), arguments: prune, timeout: .seconds(600)))
        #expect(row.cleanup?.summary == ([executable] + prune).joined(separator: " "))
        #expect(row.cleanup?.risk == risk)
        #expect(row.cleanup?.isIrreversible == true)
    }

    @Test("only the Python tools that are installed produce rows")
    func onlyPresentPythonTools() async throws {
        let fixture = try ToolFixture()
        try fixture.install("uv")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("uv"), ["cache", "dir"], stdout: try fixture.fill(".cache/uv"))

        #expect(try await inspect("uv", fixture, runner).count == 1)
        #expect(try await inspect("pip", fixture, runner).isEmpty)
    }

    @Test(
        "fixed-path tools measure their folder under home",
        arguments: [
            ("bun", "bun", ".bun/install/cache", "bun.cache", ["pm", "cache", "rm"]),
            ("cocoapods", "pod", "Library/Caches/CocoaPods", "cocoapods.cache", ["cache", "clean", "--all"]),
        ])
    func fixedPathTools(
        adapterID: String, executable: String, relative: String, rowID: String, prune: [String]
    ) async throws {
        let fixture = try ToolFixture()
        try fixture.install(executable)
        let cache = try fixture.fill(relative)
        let runner = FakeCommandRunner()

        let row = try #require(try await inspect(adapterID, fixture, runner).first)
        #expect(row.id == rowID)
        #expect(row.location == cache)
        #expect(row.size == (try await fixture.measured(cache)))
        #expect(
            row.cleanup?.command
                == Command(executable: fixture.tool(executable), arguments: prune, timeout: .seconds(600)))
        #expect(row.cleanup?.risk == .safe)
        #expect(runner.commands.isEmpty)
    }

    @Test(
        "visibility-only tools are detected by their folder and never offer a command",
        arguments: [
            ("gradle", ".gradle/caches", "gradle.caches"), ("cargo", ".cargo/registry", "cargo.registry"),
            ("maven", ".m2/repository", "maven.repository"),
        ])
    func visibilityOnly(adapterID: String, relative: String, rowID: String) async throws {
        let fixture = try ToolFixture()
        let runner = FakeCommandRunner()
        #expect(try await inspect(adapterID, fixture, runner).isEmpty)

        let cache = try fixture.fill(relative)
        let row = try #require(try await inspect(adapterID, fixture, runner).first)
        #expect(row.id == rowID)
        #expect(row.location == cache)
        #expect(row.size == (try await fixture.measured(cache)))
        #expect(row.cleanup == nil)
        #expect(row.note.map { String(localized: $0) }?.isEmpty == false)
        #expect(runner.commands.isEmpty)
    }

    // MARK: Docker

    @Test(
        "Docker size strings use decimal units",
        arguments: [
            ("1.2GB", Int64(1_200_000_000)), ("800MB (66%)", 800_000_000), ("0B", 0), ("12.5kB", 12_500),
            ("512B", 512), ("3.4TB", 3_400_000_000_000), ("1.5KB", 1_500),
        ])
    func dockerSizes(text: String, bytes: Int64) {
        #expect(ContainerEngineAdapter.parseSize(text) == bytes)
    }

    @Test("unparseable Docker sizes are nil", arguments: ["", "GB", "abc", "1.2XB", "-1GB", "1e400GB", "N/A"])
    func dockerBadSizes(text: String) {
        #expect(ContainerEngineAdapter.parseSize(text) == nil)
    }

    private static let dockerDF = """
        {"Active":"3","Reclaimable":"800MB (66%)","Size":"1.2GB","TotalCount":"7","Type":"Images"}
        {"Active":"1","Reclaimable":"0B (0%)","Size":"24.6kB","TotalCount":"2","Type":"Containers"}
        {"Active":"2","Reclaimable":"3.1GB (100%)","Size":"3.1GB","TotalCount":"4","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"512.4MB","Size":"512.4MB","TotalCount":"31","Type":"Build Cache"}

        """

    @Test("docker system df lines become image and build-cache rows with only the two safe prunes")
    func dockerRows() async throws {
        let fixture = try ToolFixture()
        try fixture.install("docker")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("docker"), ["system", "df", "--format", "{{json .}}"], stdout: Self.dockerDF)

        let rows = try await inspect("docker", fixture, runner)

        #expect(rows.map(\.id) == ["docker.images", "docker.buildCache"])
        #expect(rows.allSatisfy { $0.category == .containers && $0.location == nil })
        #expect(rows[0].size == 1_200_000_000)
        #expect(
            rows[0].cleanup?.command
                == Command(
                    executable: fixture.tool("docker"), arguments: ["image", "prune", "-f"], timeout: .seconds(600)))
        #expect(rows[0].cleanup?.risk == .review)
        #expect(rows[0].cleanup?.summary == "docker image prune -f")
        #expect(rows[1].size == 512_400_000)
        #expect(
            rows[1].cleanup?.command
                == Command(
                    executable: fixture.tool("docker"), arguments: ["builder", "prune", "-f"], timeout: .seconds(600)))
        #expect(rows[1].cleanup?.risk == .safe)
        #expect(
            runner.commands
                == [
                    Command(
                        executable: fixture.tool("docker"), arguments: ["system", "df", "--format", "{{json .}}"],
                        timeout: .seconds(10))
                ])
    }

    @Test("an unparseable size keeps the Docker row with unknown size")
    func dockerUnknownSize() async throws {
        let fixture = try ToolFixture()
        try fixture.install("docker")
        let runner = FakeCommandRunner()
        runner.stub(
            fixture.tool("docker"), ["system", "df", "--format", "{{json .}}"],
            stdout: #"{"Type":"Build Cache","Size":"lots","Reclaimable":"?"}"# + "\nnot json\n[1,2]\n")

        let rows = try await inspect("docker", fixture, runner)
        #expect(rows.map(\.id) == ["docker.buildCache"])
        #expect(rows.first?.size == nil)
    }

    @Test("Docker daemon not running: one row with unknown size, a note and no command", arguments: ["fail", "throw"])
    func dockerDown(mode: String) async throws {
        let fixture = try ToolFixture()
        try fixture.install("docker")
        let runner = FakeCommandRunner()
        if mode == "fail" {
            runner.stub(
                fixture.tool("docker"), ["system", "df", "--format", "{{json .}}"],
                stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.", status: 1)
        }

        let rows = try await inspect("docker", fixture, runner)
        #expect(rows.count == 1)
        #expect(rows.first?.id == "docker")
        #expect(rows.first?.size == nil)
        #expect(rows.first?.cleanup == nil)
        #expect(rows.first?.note == "Docker is not running.")
    }

    // MARK: Simulators

    private static let devicesJSON = """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-5" : [
              {
                "availabilityError" : "runtime profile not found using \\u201cSystem\\u201d match policy",
                "dataPath" : "\\/Users\\/someone\\/Library\\/Developer\\/CoreSimulator\\/Devices\\/A\\/data",
                "dataPathSize" : 18337792,
                "udid" : "13C1B140-E868-4429-93DF-28FBAD9A698A",
                "isAvailable" : false,
                "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro",
                "state" : "Shutdown",
                "name" : "iPhone 15 Pro"
              },
              {
                "udid" : "C9BE40D2-62C2-47CC-879F-C2A138995873",
                "isAvailable" : false,
                "state" : "Shutdown",
                "name" : "iPad Air"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
              {
                "dataPathSize" : 999999,
                "udid" : "189C5BCD-8883-4106-8FAE-734896CDD0D6",
                "isAvailable" : true,
                "state" : "Booted",
                "name" : "iPhone 17"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-10-0" : [
              {
                "udid" : "0000",
                "availability" : "(unavailable, runtime profile not found)",
                "dataPathSize" : 1000,
                "name" : "Old Watch"
              }
            ]
          }
        }
        """

    private static let runtimesJSON = """
        {
          "DB299C15-2AB3-4D7D-8740-4AE9600BE250" : {
            "build" : "24A94425",
            "deletable" : true,
            "identifier" : "DB299C15-2AB3-4D7D-8740-4AE9600BE250",
            "kind" : "Patchable Cryptex Disk Image",
            "path" : "\\/Library\\/Developer\\/CoreSimulator\\/Images\\/iOS.dmg",
            "platformIdentifier" : "com.apple.platform.iphonesimulator",
            "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
            "sizeBytes" : 7874743137,
            "state" : "Ready",
            "version" : "27.1"
          },
          "EC0470CE-EF90-4B78-955C-6E37ACB0E8A1" : {
            "identifier" : "EC0470CE-EF90-4B78-955C-6E37ACB0E8A1",
            "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
            "sizeBytes" : "not a number",
            "version" : "11.0"
          }
        }
        """

    private static let xcrun = "/usr/bin/xcrun"

    private func simulatorFixture() throws -> ToolFixture {
        let fixture = try ToolFixture()
        try fixture.fill("Library/Developer/CoreSimulator/Devices")
        return fixture
    }

    @Test("unavailable simulators are counted and the delete-unavailable command offered")
    func unavailableSimulators() async throws {
        let fixture = try simulatorFixture()
        let runner = FakeCommandRunner()
        runner.stub(Self.xcrun, ["simctl", "list", "-j", "devices"], stdout: Self.devicesJSON)

        let rows = try await inspect("simulators", fixture, runner)

        let row = try #require(rows.first { $0.id == "simulators.unavailable" })
        #expect(row.category == .simulators)
        #expect(row.size == Int64(18_337_792 + 1000))
        #expect(row.note.map { String(localized: $0) }?.contains("3") == true)
        #expect(
            row.cleanup?.command
                == Command(
                    executable: Self.xcrun, arguments: ["simctl", "delete", "unavailable"], timeout: .seconds(600)))
        #expect(row.cleanup?.summary == "xcrun simctl delete unavailable")
        #expect(row.cleanup?.risk == .safe)
        #expect(
            runner.commands.first
                == Command(
                    executable: Self.xcrun, arguments: ["simctl", "list", "-j", "devices"], timeout: .seconds(10)))
    }

    @Test("all simulators available: no delete command is offered")
    func noUnavailableSimulators() async throws {
        let fixture = try simulatorFixture()
        let runner = FakeCommandRunner()
        runner.stub(
            Self.xcrun, ["simctl", "list", "-j", "devices"],
            stdout: #"{"devices":{"r":[{"isAvailable":true,"name":"x","udid":"1"}]}}"#)

        let rows = try await inspect("simulators", fixture, runner)
        #expect(rows.allSatisfy { $0.cleanup == nil })
        #expect(!rows.contains { $0.id == "simulators.unavailable" })
    }

    @Test("runtimes are listed by size for review only")
    func runtimes() async throws {
        let fixture = try simulatorFixture()
        let runner = FakeCommandRunner()
        runner.stub(Self.xcrun, ["simctl", "runtime", "list", "-j"], stdout: Self.runtimesJSON)

        let rows = try await inspect("simulators", fixture, runner)

        #expect(
            rows.map(\.id) == [
                "simulators.runtime.DB299C15-2AB3-4D7D-8740-4AE9600BE250",
                "simulators.runtime.EC0470CE-EF90-4B78-955C-6E37ACB0E8A1",
            ])
        #expect(String(localized: rows[0].tool) == "iOS 27.1 Simulator runtime")
        #expect(rows[0].size == 7_874_743_137)
        #expect(rows[0].location == "/Library/Developer/CoreSimulator/Images/iOS.dmg")
        #expect(String(localized: rows[1].tool) == "watchOS 11.0 Simulator runtime")
        #expect(rows[1].size == nil)
        #expect(rows.allSatisfy { $0.cleanup == nil && $0.category == .simulators })
        #expect(
            rows.allSatisfy { $0.note.map { String(localized: $0) }?.contains("Xcode › Settings › Components") == true }
        )
    }

    @Test("garbage simctl output yields no rows", arguments: ["", "{", "[]", #"{"devices":[1]}"#, "null"])
    func simctlGarbage(output: String) async throws {
        let fixture = try simulatorFixture()
        let runner = FakeCommandRunner()
        runner.stub(Self.xcrun, ["simctl", "list", "-j", "devices"], stdout: output)
        runner.stub(Self.xcrun, ["simctl", "runtime", "list", "-j"], stdout: output)

        #expect(try await inspect("simulators", fixture, runner).isEmpty)
    }

    // MARK: Lima

    @Test("Lima instances are listed with their folder size and no command")
    func limaInstances() async throws {
        let fixture = try ToolFixture()
        try fixture.install("limactl")
        let instance = try fixture.fill(".lima/default", bytes: 30_000)
        let missing = fixture.home + "/.lima/gone"
        let runner = FakeCommandRunner()
        runner.stub(
            fixture.tool("limactl"), ["list", "--json"],
            stdout: """
                {"name":"default","status":"Running","dir":"\(instance)","vmType":"vz","disk":107374182400}
                {"name":"gone","status":"Broken","dir":"\(missing)"}
                not json
                {"status":"Stopped"}

                """)

        let rows = try await inspect("lima", fixture, runner)

        #expect(rows.map(\.id) == ["lima.default", "lima.gone"])
        #expect(String(localized: rows[0].tool) == "Lima (default)")
        #expect(rows[0].location == instance)
        #expect(rows[0].size == (try await fixture.measured(instance)))
        #expect(rows[1].size == nil)
        #expect(rows.allSatisfy { $0.cleanup == nil && $0.category == .containers })
    }

    @Test("limactl failing yields no rows")
    func limaFailure() async throws {
        let fixture = try ToolFixture()
        try fixture.install("limactl")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("limactl"), ["list", "--json"], stderr: "fatal", status: 1)
        #expect(try await inspect("lima", fixture, runner).isEmpty)
    }

    // MARK: Folder-detected caches with an optional tool command

    @Test(
        "folder-detected caches show their size and offer the tool's command only when the tool is found",
        arguments: [
            ("nuget", "dotnet", ".nuget/packages", "nuget.packages", ["nuget", "locals", "all", "--clear"]),
            ("swiftpm", "swift", "Library/Caches/org.swift.swiftpm", "swiftpm.cache", ["package", "purge-cache"]),
        ])
    func folderDetectedTools(
        adapterID: String, executable: String, relative: String, rowID: String, command: [String]
    ) async throws {
        let fixture = try ToolFixture()
        let runner = FakeCommandRunner()
        try fixture.install(executable)
        #expect(try await inspect(adapterID, fixture, runner).isEmpty, "a tool without its folder shows nothing")

        let cache = try fixture.fill(relative)
        let row = try #require(try await inspect(adapterID, fixture, runner).first)
        #expect(row.id == rowID)
        #expect(row.category == .packageCaches)
        #expect(row.location == cache)
        #expect(row.size == (try await fixture.measured(cache)))
        #expect(
            row.cleanup?.command
                == Command(executable: fixture.tool(executable), arguments: command, timeout: .seconds(600)))
        #expect(row.cleanup?.summary == ([executable] + command).joined(separator: " "))
        #expect(row.cleanup?.risk == .safe)
        #expect(row.note.map { String(localized: $0) }?.isEmpty == false)
        #expect(runner.commands.isEmpty)

        let withoutTool = try ToolFixture()
        try withoutTool.fill(relative)
        let sizeOnly = try #require(try await inspect(adapterID, withoutTool, runner).first)
        #expect(sizeOnly.id == rowID)
        #expect((sizeOnly.size ?? 0) > 0)
        #expect(sizeOnly.cleanup == nil)
    }

    // MARK: conda

    private static let condaInfo = ["info", "--json"]

    @Test("conda: measures the first existing pkgs_dirs entry and offers conda clean for review")
    func condaProbe() async throws {
        let fixture = try ToolFixture()
        try fixture.install("conda")
        let pkgs = try fixture.fill("custom/conda/pkgs", bytes: 40_000)
        let runner = FakeCommandRunner()
        runner.stub(
            fixture.tool("conda"), Self.condaInfo,
            stdout: """
                {"conda_version": "25.1.0", "root_prefix": "/somewhere",
                 "pkgs_dirs": ["\(fixture.home)/missing/pkgs", 7, "relative/pkgs", "\(pkgs)"]}
                """)

        let rows = try await inspect("conda", fixture, runner)

        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == "conda.pkgs")
        #expect(row.category == .packageCaches)
        #expect(row.location == pkgs)
        #expect(row.size == (try await fixture.measured(pkgs)))
        #expect(
            row.cleanup?.command
                == Command(
                    executable: fixture.tool("conda"), arguments: ["clean", "--all", "--yes"], timeout: .seconds(600)))
        #expect(row.cleanup?.summary == "conda clean --all --yes")
        #expect(row.cleanup?.risk == .review)
        #expect(
            runner.commands
                == [Command(executable: fixture.tool("conda"), arguments: Self.condaInfo, timeout: .seconds(10))])
    }

    @Test(
        "conda: unusable info output falls back to the common install roots",
        arguments: ["", "not json", "[]", #"{"pkgs_dirs": "nope"}"#, #"{"pkgs_dirs": []}"#, "fail"])
    func condaFallback(output: String) async throws {
        let fixture = try ToolFixture()
        try fixture.install("conda")
        let pkgs = try fixture.fill("miniforge3/pkgs")
        let runner = FakeCommandRunner()
        if output == "fail" {
            runner.stub(fixture.tool("conda"), Self.condaInfo, stderr: "boom", status: 1)
        } else {
            runner.stub(fixture.tool("conda"), Self.condaInfo, stdout: output)
        }

        let row = try #require(try await inspect("conda", fixture, runner).first)
        #expect(row.location == pkgs)
        #expect(row.size == (try await fixture.measured(pkgs)))
        #expect(row.cleanup?.summary == "conda clean --all --yes")
    }

    @Test("conda: without the tool a known pkgs folder is shown for information only")
    func condaWithoutTool() async throws {
        let runner = FakeCommandRunner()
        for root in ["miniconda3", "anaconda3", "miniforge3"] {
            let fixture = try ToolFixture()
            let pkgs = try fixture.fill("\(root)/pkgs")
            let row = try #require(try await inspect("conda", fixture, runner).first)
            #expect(row.location == pkgs)
            #expect(row.cleanup == nil)
        }
        #expect(try await inspect("conda", try ToolFixture(), runner).isEmpty)
        #expect(runner.commands.isEmpty)
    }

    @Test("conda installed but no pkgs folder anywhere: no row")
    func condaNoFolder() async throws {
        let fixture = try ToolFixture()
        try fixture.install("conda")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("conda"), Self.condaInfo, stdout: #"{"pkgs_dirs": ["/nonexistent/clenvra/pkgs"]}"#)
        #expect(try await inspect("conda", fixture, runner).isEmpty)
    }

    // MARK: OrbStack

    @Test(
        "OrbStack data is shown for information only",
        arguments: ["Library/Group Containers/HUAQ24HBR6.dev.orbstack", ".orbstack"])
    func orbStack(relative: String) async throws {
        let fixture = try ToolFixture()
        let runner = FakeCommandRunner()
        #expect(try await inspect("orbstack", fixture, runner).isEmpty)

        let data = try fixture.fill(relative, bytes: 20_000)
        let row = try #require(try await inspect("orbstack", fixture, runner).first)
        #expect(row.id == "orbstack.data")
        #expect(row.category == .containers)
        #expect(row.location == data)
        #expect(row.size == (try await fixture.measured(data)))
        #expect(row.cleanup == nil)
        #expect(row.note.map { String(localized: $0) }?.isEmpty == false)
        #expect(runner.commands.isEmpty)
    }

    @Test("OrbStack: with both folders the group container is measured")
    func orbStackPrefersGroupContainer() async throws {
        let fixture = try ToolFixture()
        try fixture.fill(".orbstack")
        let container = try fixture.fill("Library/Group Containers/HUAQ24HBR6.dev.orbstack")
        let row = try #require(try await inspect("orbstack", fixture, FakeCommandRunner()).first)
        #expect(row.location == container)
    }

    // MARK: Colima

    @Test("Colima: the download cache is measured and colima prune --force offered")
    func colimaCache() async throws {
        let fixture = try ToolFixture()
        let runner = FakeCommandRunner()
        let cache = try fixture.fill("Library/Caches/colima")
        #expect(try await inspect("colima-cache", fixture, runner).isEmpty, "no colima, no row")

        try fixture.install("colima")
        let row = try #require(try await inspect("colima-cache", fixture, runner).first)
        #expect(row.id == "colima.cache")
        #expect(row.category == .containers)
        #expect(row.location == cache)
        #expect(row.size == (try await fixture.measured(cache)))
        #expect(
            row.cleanup?.command
                == Command(executable: fixture.tool("colima"), arguments: ["prune", "--force"], timeout: .seconds(600)))
        #expect(row.cleanup?.summary == "colima prune --force")
        #expect(row.cleanup?.risk == .safe)
        #expect(runner.commands.isEmpty)
    }

    @Test("Colima profiles are listed with their measured VM folders and no command")
    func colimaProfiles() async throws {
        let fixture = try ToolFixture()
        try fixture.install("colima")
        let instance = try fixture.fill(".colima/_lima/colima", bytes: 30_000)
        let disk = try fixture.fill(".colima/_lima/_disks/colima", bytes: 50_000)
        let runner = FakeCommandRunner()
        runner.stub(
            fixture.tool("colima"), ["list", "--json"],
            stdout: """
                {"name":"default","status":"Running","arch":"aarch64","cpus":2,"memory":2147483648,"disk":64424509440}
                {"name":"work","status":"Stopped","disk":"lots"}
                not json
                {"status":"Stopped"}
                {"name":"../evil"}

                """)

        let rows = try await inspect("colima", fixture, runner)

        #expect(rows.map(\.id) == ["colima.default", "colima.work"])
        #expect(String(localized: rows[0].tool) == "Colima (default)")
        #expect(rows[0].location == instance)
        let instanceSize = try #require(try await fixture.measured(instance))
        let diskSize = try #require(try await fixture.measured(disk))
        #expect(rows[0].size == instanceSize + diskSize)
        #expect(rows[1].location == nil)
        #expect(rows[1].size == nil)
        #expect(rows.allSatisfy { $0.cleanup == nil && $0.category == .containers })
        #expect(
            runner.commands
                == [Command(executable: fixture.tool("colima"), arguments: ["list", "--json"], timeout: .seconds(10))])
    }

    @Test("Colima: a JSON array listing is accepted too")
    func colimaArray() async throws {
        let fixture = try ToolFixture()
        try fixture.install("colima")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("colima"), ["list", "--json"], stdout: #"[{"name":"default"},{"name":"dev"}]"#)
        let rows = try await inspect("colima", fixture, runner)
        #expect(rows.map(\.id) == ["colima.default", "colima.dev"])
    }

    @Test("Colima: a failing or absent colima yields no profile rows", arguments: ["fail", "absent"])
    func colimaFailure(mode: String) async throws {
        let fixture = try ToolFixture()
        let runner = FakeCommandRunner()
        if mode == "fail" {
            try fixture.install("colima")
            runner.stub(fixture.tool("colima"), ["list", "--json"], stderr: "fatal", status: 1)
        }
        #expect(try await inspect("colima", fixture, runner).isEmpty)
    }

    // MARK: Podman

    private static let podmanDF = ["system", "df", "--format", "{{json .}}"]

    @Test("podman system df becomes an images row with only the dangling-image prune")
    func podmanRows() async throws {
        let fixture = try ToolFixture()
        try fixture.install("podman")
        let runner = FakeCommandRunner()
        runner.stub(
            fixture.tool("podman"), Self.podmanDF,
            stdout: """
                {"Type":"Images","Total":5,"Active":2,"Size":"1.208GB","Reclaimable":"600MB (50%)"}
                {"Type":"Containers","Total":2,"Active":1,"Size":"12kB","Reclaimable":"0B (0%)"}
                {"Type":"Local Volumes","Total":1,"Active":1,"Size":"3GB","Reclaimable":"0B (0%)"}

                """)

        let rows = try await inspect("podman", fixture, runner)

        let row = try #require(rows.first)
        #expect(rows.map(\.id) == ["podman.images"])
        #expect(row.category == .containers)
        #expect(row.size == 1_208_000_000)
        #expect(
            row.cleanup?.command
                == Command(
                    executable: fixture.tool("podman"), arguments: ["image", "prune", "-f"], timeout: .seconds(600)))
        #expect(row.cleanup?.summary == "podman image prune -f")
        #expect(row.cleanup?.risk == .review)
        #expect(
            runner.commands
                == [Command(executable: fixture.tool("podman"), arguments: Self.podmanDF, timeout: .seconds(10))])
    }

    @Test("podman: a JSON array and numeric sizes are accepted; an odd size is unknown")
    func podmanVariants() async throws {
        let fixture = try ToolFixture()
        try fixture.install("podman")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("podman"), Self.podmanDF, stdout: #"[{"Type":"Images","Size":4096}]"#)
        #expect(try await inspect("podman", fixture, runner).first?.size == 4096)

        runner.stub(fixture.tool("podman"), Self.podmanDF, stdout: #"{"Type":"Images","Size":"huge"}"#)
        let row = try #require(try await inspect("podman", fixture, runner).first)
        #expect(row.size == nil)
        #expect(row.cleanup?.summary == "podman image prune -f")
    }

    @Test("podman machine not running: one row with unknown size, a note and no command")
    func podmanDown() async throws {
        let fixture = try ToolFixture()
        try fixture.install("podman")
        let runner = FakeCommandRunner()
        runner.stub(fixture.tool("podman"), Self.podmanDF, stderr: "Cannot connect to Podman.", status: 125)

        let rows = try await inspect("podman", fixture, runner)
        #expect(rows.map(\.id) == ["podman"])
        #expect(rows.first?.size == nil)
        #expect(rows.first?.cleanup == nil)
        #expect(rows.first?.note == "Podman is not running.")
    }

    // MARK: Invariants

    @Test("no adapter offers or runs anything that removes volumes, containers, VMs or other user data")
    func noDestructiveCommands() async throws {
        let fixture = try simulatorFixture()
        let tools = [
            "npm", "pnpm", "yarn", "bun", "brew", "uv", "pip3", "pod", "go", "docker", "limactl", "dotnet", "swift",
            "conda", "colima", "podman",
        ]
        for tool in tools { try fixture.install(tool) }
        for relative in [
            ".gradle/caches", ".cargo/registry", ".bun/install/cache", "Library/Caches/CocoaPods", ".m2/repository",
            ".nuget/packages", "Library/Caches/org.swift.swiftpm", "miniconda3/pkgs", ".orbstack",
            "Library/Caches/colima", ".colima/_lima/colima",
        ] {
            try fixture.fill(relative)
        }
        let runner = FakeCommandRunner()
        let probes: [(String, [String])] = [
            ("npm", ["config", "get", "cache"]), ("pnpm", ["store", "path"]), ("yarn", ["cache", "dir"]),
            ("brew", ["--cache"]), ("uv", ["cache", "dir"]), ("pip3", ["cache", "dir"]),
            ("go", ["env", "GOMODCACHE"]),
        ]
        for (tool, arguments) in probes {
            runner.stub(fixture.tool(tool), arguments, stdout: try fixture.fill("caches/\(tool)") + "\n")
        }
        runner.stub(fixture.tool("docker"), ["system", "df", "--format", "{{json .}}"], stdout: Self.dockerDF)
        runner.stub(
            fixture.tool("limactl"), ["list", "--json"], stdout: #"{"name":"default","dir":"/nonexistent"}"# + "\n")
        runner.stub(fixture.tool("colima"), ["list", "--json"], stdout: #"{"name":"default"}"# + "\n")
        runner.stub(fixture.tool("podman"), Self.podmanDF, stdout: #"{"Type":"Images","Size":"1GB"}"# + "\n")
        runner.stub(Self.xcrun, ["simctl", "list", "-j", "devices"], stdout: Self.devicesJSON)
        runner.stub(Self.xcrun, ["simctl", "runtime", "list", "-j"], stdout: Self.runtimesJSON)

        var rows: [ToolStorage] = []
        for adapter in ToolAdapters.standard {
            rows += await adapter.inspect(locator: fixture.locator, runner: runner, home: fixture.home)
        }

        #expect(rows.count >= 25)
        #expect(Set(rows.map(\.id)).count == rows.count)
        let actions = rows.compactMap(\.cleanup)
        #expect(actions.count == 17)
        let forbidden = ["volume", "--volumes", "system prune", "rm ", "delete", "erase", "kill", "stop"]
        for action in actions {
            #expect(action.command.executable.hasPrefix("/"))
            #expect(action.isIrreversible)
            #expect(action.command.timeout == .seconds(600))
            let line = ([action.command.executable] + action.command.arguments).joined(separator: " ")
            let allowed = action.command.arguments == ["simctl", "delete", "unavailable"]
            for word in forbidden where !(allowed && word == "delete") {
                #expect(!line.contains(word), "\(line) contains \(word)")
            }
        }
        let cleanupCommands = Set(actions.map(\.command))
        for probe in runner.commands {
            #expect(probe.timeout == .seconds(10))
            #expect(!cleanupCommands.contains(probe), "inspect ran a cleanup command")
            let line = probe.arguments.joined(separator: " ")
            #expect(!["prune", "clean", "delete", "purge", " rm"].contains { line.contains($0) }, "\(line)")
        }
    }

    // MARK: Running a cleanup

    @Test("ToolCleanupRunner runs the exact command, streams output and returns the result")
    func runnerRunsExactCommand() async throws {
        let runner = FakeCommandRunner()
        let lines = [
            OutputLine(stream: .standardOutput, text: "Removed 12 packages"),
            OutputLine(stream: .standardError, text: "warn: something"),
        ]
        runner.stub("/opt/bin/pnpm", ["store", "prune"], stdout: "Removed 12 packages\n", lines: lines)
        let action = ToolCleanupAction(
            command: Command(executable: "/opt/bin/pnpm", arguments: ["store", "prune"], timeout: .seconds(600)),
            risk: .safe, summary: "pnpm store prune")
        let received = Mutex<[OutputLine]>([])

        let result = try await ToolCleanupRunner.run(action, runner: runner) { line in
            received.withLock { $0.append(line) }
        }

        #expect(runner.commands == [action.command])
        #expect(received.withLock { $0 } == lines)
        #expect(result.exitStatus == 0)
        #expect(result.standardOutput == "Removed 12 packages\n")
    }

    @Test("ToolCleanupRunner propagates a launch failure")
    func runnerThrows() async {
        let action = ToolCleanupAction(
            command: Command(executable: "/missing/pnpm", arguments: ["store", "prune"]), risk: .safe,
            summary: "pnpm store prune")
        await #expect(throws: CommandError.executableNotFound("/missing/pnpm")) {
            try await ToolCleanupRunner.run(action, runner: FakeCommandRunner(), onOutput: nil)
        }
    }

    // MARK: Integration (read-only)

    @Test(
        "real simctl device list parses without crashing",
        .enabled(if: FileManager.default.fileExists(atPath: "/usr/bin/xcrun")), .timeLimit(.minutes(1)))
    func realSimctl() async throws {
        let command = Command(
            executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "-j", "devices"], timeout: .seconds(50))
        let result = try await ProcessCommandRunner().run(command)
        let summary = SimulatorAdapter.parseDevices(result.standardOutput)
        if result.terminationReason == .exited, result.exitStatus == 0, !result.outputTruncated {
            #expect(summary != nil)
        }
        #expect((summary?.unavailableCount ?? 0) >= 0)
    }
}
