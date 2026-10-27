import Foundation

/// The developer tools Clenvra knows how to inspect; each detects itself, so absent tools produce no rows.
public enum ToolAdapters {
    /// Every built-in adapter, in display order.
    public static let standard: [any ToolAdapter] = [
        PathToolAdapter(
            id: "npm", rowID: "npm.cache", tool: "npm", executable: "npm",
            location: .probe(["config", "get", "cache"], fallback: ".npm"), measuredSubpath: "_cacache",
            cleanup: (["cache", "clean", "--force"], .safe),
            note: "Removes npm's download cache. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "pnpm", rowID: "pnpm.store", tool: "pnpm", executable: "pnpm",
            location: .probe(["store", "path"], fallback: nil),
            cleanup: (["store", "prune"], .safe),
            note: "Removes packages no project references. They are downloaded again when needed."),
        PathToolAdapter(
            id: "yarn", rowID: "yarn.cache", tool: "Yarn", executable: "yarn",
            location: .probe(["cache", "dir"], fallback: nil),
            cleanup: (["cache", "clean"], .safe),
            note: "Removes Yarn's download cache. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "bun", rowID: "bun.cache", tool: "Bun", executable: "bun",
            location: .home(".bun/install/cache"),
            cleanup: (["pm", "cache", "rm"], .safe),
            note: "Removes Bun's download cache. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "homebrew", rowID: "homebrew.cache", tool: "Homebrew", executable: "brew",
            location: .probe(["--cache"], fallback: nil),
            cleanup: (["cleanup", "-s"], .safe),
            note: "Removes old versions of installed packages and cached downloads."),
        PathToolAdapter(
            id: "uv", rowID: "uv.cache", tool: "uv", executable: "uv",
            location: .probe(["cache", "dir"], fallback: nil),
            cleanup: (["cache", "clean"], .safe),
            note: "Removes uv's cache. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "pip", rowID: "pip.cache", tool: "pip", executable: "pip3",
            location: .probe(["cache", "dir"], fallback: nil),
            cleanup: (["cache", "purge"], .safe),
            note: "Removes pip's cache of downloaded and built packages. They are downloaded again when needed."),
        PathToolAdapter(
            id: "cocoapods", rowID: "cocoapods.cache", tool: "CocoaPods", executable: "pod",
            location: .home("Library/Caches/CocoaPods"),
            cleanup: (["cache", "clean", "--all"], .safe),
            note: "Removes downloaded pods. They are downloaded again on the next pod install."),
        PathToolAdapter(
            id: "gradle", rowID: "gradle.caches", tool: "Gradle", executable: nil,
            location: .home(".gradle/caches"), cleanup: nil,
            note: "Gradle has no safe command to clear its global cache. Cleanup rules can remove it instead."),
        PathToolAdapter(
            id: "go", rowID: "go.modcache", tool: "Go modules", executable: "go",
            location: .probe(["env", "GOMODCACHE"], fallback: nil),
            cleanup: (["clean", "-modcache"], .review),
            note: "Removes every downloaded Go module. Builds download them again, which can take a while."),
        PathToolAdapter(
            id: "cargo", rowID: "cargo.registry", tool: "Cargo registry", executable: nil,
            location: .home(".cargo/registry"), cleanup: nil,
            note: "Cargo has no built-in command to clear its registry cache. Shown for information."),
        SimulatorAdapter(),
        DockerAdapter(),
        LimaAdapter(),
    ]
}

/// A tool whose store is one folder, found at a fixed home path or by asking the tool, with an optional prune.
struct PathToolAdapter: ToolAdapter {
    enum Location: Sendable {
        /// Relative to the home folder.
        case home(String)
        /// Printed by the tool for these arguments; `fallback` is relative to home and used when the probe fails.
        case probe([String], fallback: String?)
    }

    let id: String
    let rowID: String
    let tool: LocalizedStringResource
    /// `nil` for visibility-only tools, which are detected by their folder existing instead.
    let executable: String?
    let location: Location
    let measuredSubpath: String?
    let cleanup: (arguments: [String], risk: Risk)?
    let note: LocalizedStringResource

    init(
        id: String, rowID: String, tool: LocalizedStringResource, executable: String?, location: Location,
        measuredSubpath: String? = nil, cleanup: (arguments: [String], risk: Risk)?, note: LocalizedStringResource
    ) {
        self.id = id
        self.rowID = rowID
        self.tool = tool
        self.executable = executable
        self.location = location
        self.measuredSubpath = measuredSubpath
        self.cleanup = cleanup
        self.note = note
    }

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        let toolPath = executable.flatMap(locator.locate)
        if executable != nil, toolPath == nil { return [] }

        var directory: String?
        switch location {
        case .home(let relative):
            directory = home + "/" + relative
        case .probe(let arguments, let fallback):
            if let toolPath {
                directory = ToolProbe.absolutePath(in: await ToolProbe.output(runner, toolPath, arguments))
            }
            if directory == nil, let fallback { directory = home + "/" + fallback }
        }
        if let subpath = measuredSubpath { directory = directory.map { $0 + "/" + subpath } }

        let size = await ToolProbe.allocatedSize(of: directory)
        if toolPath == nil, size == nil { return [] }

        let action = both(toolPath, cleanup).map { path, cleanup in
            ToolCleanupAction(executable: path, arguments: cleanup.arguments, risk: cleanup.risk)
        }
        return [
            ToolStorage(
                id: rowID, tool: tool, category: .packageCaches, location: size == nil ? nil : directory, size: size,
                cleanup: action, note: note)
        ]
    }
}

private func both<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}

/// Parses tool JSON leniently, so one odd field drops only that value, never the whole row or the scan.
private enum LenientJSON {
    static func object(_ text: some StringProtocol) -> [String: Any]? {
        guard let data = String(text).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One object per line, the format `docker --format '{{json .}}'` and `limactl list --json` use.
    static func lines(_ text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { object($0) }
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < 9.2e18, double == double.rounded() else { return nil }
        return number.int64Value
    }
}

/// Xcode simulators: unavailable devices (deletable with simctl) and installed runtimes (visibility only).
struct SimulatorAdapter: ToolAdapter {
    struct DeviceSummary: Equatable {
        let unavailableCount: Int
        /// Sum of `dataPathSize` over unavailable devices that report it; `nil` when none do.
        let unavailableBytes: Int64?
    }

    let id = "simulators"
    var xcrun = "/usr/bin/xcrun"

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        // Without a CoreSimulator folder there is nothing to report, and the xcrun shim is never woken on Macs
        // without developer tools (it would offer to install them).
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: home + "/Library/Developer/CoreSimulator", isDirectory: &isDirectory),
            isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: xcrun)
        else { return [] }

        var rows: [ToolStorage] = []
        let devices = await ToolProbe.output(runner, xcrun, ["simctl", "list", "-j", "devices"])
        if let summary = devices.flatMap(Self.parseDevices), summary.unavailableCount > 0 {
            rows.append(
                ToolStorage(
                    id: "simulators.unavailable", tool: "Unavailable simulators", category: .simulators,
                    location: nil, size: summary.unavailableBytes,
                    cleanup: ToolCleanupAction(
                        executable: xcrun, arguments: ["simctl", "delete", "unavailable"], risk: .safe),
                    note:
                        "\(summary.unavailableCount) simulators whose runtime is no longer installed. Deleting them also removes their apps and data."
                ))
        }
        let runtimes = await ToolProbe.output(runner, xcrun, ["simctl", "runtime", "list", "-j"])
        rows += runtimes.map(Self.parseRuntimes) ?? []
        return rows
    }

    /// Counts devices marked unavailable in `simctl list -j devices`; `nil` when the JSON is not that shape.
    static func parseDevices(_ output: String) -> DeviceSummary? {
        guard let groups = LenientJSON.object(output)?["devices"] as? [String: Any] else { return nil }
        var count = 0
        var bytes: Int64?
        for case let devices as [Any] in groups.values {
            for case let device as [String: Any] in devices {
                let legacyUnavailable = (device["availability"] as? String)?.contains("unavailable") ?? false
                guard device["isAvailable"] as? Bool == false || legacyUnavailable else { continue }
                count += 1
                if let size = LenientJSON.int64(device["dataPathSize"]) {
                    let (sum, overflow) = (bytes ?? 0).addingReportingOverflow(size)
                    bytes = overflow ? bytes : sum
                }
            }
        }
        return DeviceSummary(unavailableCount: count, unavailableBytes: bytes)
    }

    /// One row per runtime from `simctl runtime list -j`, sorted by identifier; malformed entries are skipped.
    static func parseRuntimes(_ output: String) -> [ToolStorage] {
        guard let runtimes = LenientJSON.object(output) else { return [] }
        return runtimes.keys.sorted().compactMap { key in
            guard let runtime = runtimes[key] as? [String: Any] else { return nil }
            let platform = (runtime["runtimeIdentifier"] as? String)
                .flatMap { $0.split(separator: ".").last?.split(separator: "-").first }
                .map(String.init)
            let name = [platform, runtime["version"] as? String].compactMap { $0 }.joined(separator: " ")
            return ToolStorage(
                id: "simulators.runtime.\(key)",
                tool: name.isEmpty ? LocalizedStringResource("Simulator runtime") : "\(name) Simulator runtime",
                category: .simulators, location: runtime["path"] as? String,
                size: LenientJSON.int64(runtime["sizeBytes"]), cleanup: nil,
                note: "Remove unused runtimes in Xcode › Settings › Components.")
        }
    }
}

/// Docker-compatible engines (Docker Desktop, OrbStack, Colima): image and build-cache sizes with safe prunes only.
/// Volumes, containers and VM disks are never offered: they can hold user data.
struct DockerAdapter: ToolAdapter {
    let id = "docker"

    private static let rows:
        [(
            type: String, id: String, tool: LocalizedStringResource, prune: [String], risk: Risk,
            note: LocalizedStringResource
        )] = [
            (
                "Images", "docker.images", "Docker images", ["image", "prune", "-f"], .review,
                "Removes dangling images only: untagged layers that no image or container uses."
            ),
            (
                "Build Cache", "docker.buildCache", "Docker build cache", ["builder", "prune", "-f"], .safe,
                "Removes the build cache. Later builds may take longer."
            ),
        ]

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        guard let docker = locator.locate("docker") else { return [] }
        guard let output = await ToolProbe.output(runner, docker, ["system", "df", "--format", "{{json .}}"]) else {
            return [
                ToolStorage(
                    id: "docker", tool: "Docker", category: .containers, location: nil, size: nil, cleanup: nil,
                    note: "Docker is not running.")
            ]
        }
        let entries = LenientJSON.lines(output)
        return Self.rows.compactMap { row in
            guard let entry = entries.first(where: { $0["Type"] as? String == row.type }) else { return nil }
            return ToolStorage(
                id: row.id, tool: row.tool, category: .containers, location: nil,
                size: (entry["Size"] as? String).flatMap(Self.parseSize),
                cleanup: ToolCleanupAction(executable: docker, arguments: row.prune, risk: row.risk), note: row.note)
        }
    }

    /// Parses Docker's human sizes such as `1.2GB` or `800MB (66%)`; Docker uses decimal (1000-based) units.
    static func parseSize(_ text: String) -> Int64? {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        guard let unitStart = token.firstIndex(where: \.isLetter) else { return nil }
        let multipliers: [String: Double] = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15]
        guard let value = Double(token[..<unitStart]), let multiplier = multipliers[token[unitStart...].uppercased()]
        else { return nil }
        let bytes = (value * multiplier).rounded()
        guard bytes.isFinite, bytes >= 0, bytes < 9.2e18 else { return nil }
        return Int64(bytes)
    }
}

/// Lima instances (also used by Colima): each instance folder's size, for information only.
struct LimaAdapter: ToolAdapter {
    let id = "lima"

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        guard let limactl = locator.locate("limactl"),
            let output = await ToolProbe.output(runner, limactl, ["list", "--json"])
        else { return [] }
        var rows: [ToolStorage] = []
        for instance in LenientJSON.lines(output) {
            guard let name = instance["name"] as? String, !name.isEmpty else { continue }
            let directory = (instance["dir"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            rows.append(
                ToolStorage(
                    id: "lima.\(name)", tool: "Lima (\(name))", category: .containers, location: directory,
                    size: await ToolProbe.allocatedSize(of: directory), cleanup: nil,
                    note: "A Lima virtual machine and its disk. Shown for information."))
        }
        return rows
    }
}
