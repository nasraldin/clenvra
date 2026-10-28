import Foundation

/// The developer tools Clenvra knows how to inspect; each detects itself, so absent tools produce no rows.
public enum ToolAdapters {
    /// Every built-in adapter, in display order.
    public static let standard: [any ToolAdapter] = [
        PathToolAdapter(
            id: "npm", rowID: "npm.cache", tool: "npm", executable: "npm",
            location: .probe(["config", "get", "cache"], fallback: [".npm"]), measuredSubpath: "_cacache",
            cleanup: (["cache", "clean", "--force"], .safe),
            note: "Removes npm's download cache. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "pnpm", rowID: "pnpm.store", tool: "pnpm", executable: "pnpm",
            location: .probe(["store", "path"]),
            cleanup: (["store", "prune"], .safe),
            note: "Removes packages no project references. They are downloaded again when needed."),
        PathToolAdapter(
            id: "yarn", rowID: "yarn.cache", tool: "Yarn", executable: "yarn",
            location: .probe(["cache", "dir"]),
            cleanup: (["cache", "clean"], .safe),
            note: "Removes Yarn's download cache. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "bun", rowID: "bun.cache", tool: "Bun", executable: "bun",
            location: .home([".bun/install/cache"]),
            cleanup: (["pm", "cache", "rm"], .safe),
            note: "Removes Bun's download cache. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "homebrew", rowID: "homebrew.cache", tool: "Homebrew", executable: "brew",
            location: .probe(["--cache"]),
            cleanup: (["cleanup", "-s"], .safe),
            note: "Removes old versions of installed packages and cached downloads."),
        PathToolAdapter(
            id: "uv", rowID: "uv.cache", tool: "uv", executable: "uv",
            location: .probe(["cache", "dir"]),
            cleanup: (["cache", "clean"], .safe),
            note: "Removes uv's cache. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "pip", rowID: "pip.cache", tool: "pip", executable: "pip3",
            location: .probe(["cache", "dir"]),
            cleanup: (["cache", "purge"], .safe),
            note: "Removes pip's cache of downloaded and built packages. They are downloaded again when needed."),
        PathToolAdapter(
            id: "conda", rowID: "conda.pkgs", tool: "conda", executable: "conda",
            location: .probe(
                ["info", "--json"], format: .jsonPaths(key: "pkgs_dirs"),
                fallback: ["miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs", "mambaforge/pkgs"]),
            detection: .folder, cleanup: (["clean", "--all", "--yes"], .review),
            note:
                "Removes conda's cached package downloads and packages no environment uses. Environments are not changed."
        ),
        PathToolAdapter(
            id: "cocoapods", rowID: "cocoapods.cache", tool: "CocoaPods", executable: "pod",
            location: .home(["Library/Caches/CocoaPods"]),
            cleanup: (["cache", "clean", "--all"], .safe),
            note: "Removes downloaded pods. They are downloaded again on the next pod install."),
        PathToolAdapter(
            id: "swiftpm", rowID: "swiftpm.cache", tool: "Swift Package Manager", executable: "swift",
            location: .home(["Library/Caches/org.swift.swiftpm"]),
            detection: .folder, cleanup: (["package", "purge-cache"], .safe),
            note: "Removes SwiftPM's shared cache of package checkouts. Packages are downloaded again when needed."),
        PathToolAdapter(
            id: "gradle", rowID: "gradle.caches", tool: "Gradle", executable: nil,
            location: .home([".gradle/caches"]), cleanup: nil,
            note: "Gradle has no safe command to clear its global cache. Cleanup rules can remove it instead."),
        PathToolAdapter(
            id: "maven", rowID: "maven.repository", tool: "Maven repository", executable: nil,
            location: .home([".m2/repository"]), cleanup: nil,
            note: "Maven has no command to clear its local repository. Shown for information."),
        PathToolAdapter(
            id: "nuget", rowID: "nuget.packages", tool: "NuGet", executable: "dotnet",
            location: .home([".nuget/packages"]),
            detection: .folder, cleanup: (["nuget", "locals", "all", "--clear"], .safe),
            note: "Removes NuGet's package and download caches. Packages are downloaded again on the next restore."),
        PathToolAdapter(
            id: "go", rowID: "go.modcache", tool: "Go modules", executable: "go",
            location: .probe(["env", "GOMODCACHE"]),
            cleanup: (["clean", "-modcache"], .review),
            note: "Removes every downloaded Go module. Builds download them again, which can take a while."),
        PathToolAdapter(
            id: "cargo", rowID: "cargo.registry", tool: "Cargo registry", executable: nil,
            location: .home([".cargo/registry"]), cleanup: nil,
            note: "Cargo has no built-in command to clear its registry cache. Shown for information."),
        SimulatorAdapter(),
        ContainerEngineAdapter.docker,
        ContainerEngineAdapter.podman,
        PathToolAdapter(
            id: "orbstack", rowID: "orbstack.data", tool: "OrbStack", executable: nil,
            location: .home(["Library/Group Containers/HUAQ24HBR6.dev.orbstack", ".orbstack"]),
            category: .containers, cleanup: nil,
            note:
                "OrbStack's machines, containers and volumes. Shown for information; unused Docker images are pruned in the Docker rows."
        ),
        PathToolAdapter(
            id: "colima-cache", rowID: "colima.cache", tool: "Colima downloads", executable: "colima",
            location: .home(["Library/Caches/colima"]), category: .containers,
            cleanup: (["prune", "--force"], .safe),
            note:
                "Removes Colima's cached downloads, such as VM images. Virtual machines and their disks are not touched."
        ),
        ColimaAdapter(),
        LimaAdapter(),
        AndroidAdapter(),
        OllamaAdapter(),
        LMStudioAdapter(),
        HuggingFaceAdapter(),
    ]
}

/// A tool whose store is one folder, found at a fixed home path or by asking the tool, with an optional prune.
struct PathToolAdapter: ToolAdapter {
    enum Location: Sendable {
        /// Candidates relative to the home folder (or absolute); the first existing folder is measured.
        case home([String])
        /// Printed by the tool for these arguments; `fallback` candidates are tried after the tool's answer.
        case probe([String], format: ProbeFormat = .path, fallback: [String] = [])
    }

    /// How a probe's standard output names the folder.
    enum ProbeFormat: Sendable {
        /// The last non-empty line is an absolute path.
        case path
        /// A JSON object whose `key` holds an array of paths; absolute strings are kept in order.
        case jsonPaths(key: String)
    }

    /// What makes the row appear, so a tool that is always installed (like the `swift` shim) cannot add empty rows.
    enum Detection: Sendable {
        /// The executable is found; the folder may still be unknown.
        case tool
        /// The folder exists; the command is offered only when the executable is also found.
        case folder
    }

    let id: String
    let rowID: String
    let tool: LocalizedStringResource
    /// `nil` for visibility-only tools, which are detected by their folder existing instead.
    let executable: String?
    let location: Location
    let measuredSubpath: String?
    let detection: Detection
    let category: CleanupCategory
    let cleanup: (arguments: [String], risk: Risk)?
    let note: LocalizedStringResource

    init(
        id: String, rowID: String, tool: LocalizedStringResource, executable: String?, location: Location,
        measuredSubpath: String? = nil, detection: Detection? = nil, category: CleanupCategory = .packageCaches,
        cleanup: (arguments: [String], risk: Risk)?, note: LocalizedStringResource
    ) {
        self.id = id
        self.rowID = rowID
        self.tool = tool
        self.executable = executable
        self.location = location
        self.measuredSubpath = measuredSubpath
        self.detection = detection ?? (executable == nil ? .folder : .tool)
        self.category = category
        self.cleanup = cleanup
        self.note = note
    }

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        let toolPath = executable.flatMap(locator.locate)
        if detection == .tool, toolPath == nil { return [] }

        var candidates: [String] = []
        switch location {
        case .home(let paths):
            candidates = paths
        case .probe(let arguments, let format, let fallback):
            if let toolPath {
                candidates = format.paths(in: await ToolProbe.output(runner, toolPath, arguments))
            }
            candidates += fallback
        }

        var directory: String?
        var size: Int64?
        for candidate in candidates {
            var path = candidate.hasPrefix("/") ? candidate : home + "/" + candidate
            if let subpath = measuredSubpath { path += "/" + subpath }
            if let measured = await ToolProbe.allocatedSize(of: path) {
                (directory, size) = (path, measured)
                break
            }
        }
        if detection == .folder, size == nil { return [] }

        let action = both(toolPath, cleanup).map { path, cleanup in
            ToolCleanupAction(executable: path, arguments: cleanup.arguments, risk: cleanup.risk)
        }
        return [
            ToolStorage(
                id: rowID, tool: tool, category: category, location: directory, size: size, cleanup: action,
                note: note)
        ]
    }
}

extension PathToolAdapter.ProbeFormat {
    /// Absolute paths named by `output`, in order; empty for a failed probe or output of another shape.
    func paths(in output: String?) -> [String] {
        switch self {
        case .path:
            return ToolProbe.absolutePath(in: output).map { [$0] } ?? []
        case .jsonPaths(let key):
            guard let output, let list = LenientJSON.object(output)?[key] as? [Any] else { return [] }
            return list.compactMap { ($0 as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } }
        }
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

    /// A JSON array of objects, or else one object per line, since tools have printed both over versions.
    static func records(_ text: String) -> [[String: Any]] {
        if let data = text.data(using: .utf8),
            let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        {
            return array.compactMap { $0 as? [String: Any] }
        }
        return lines(text)
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

/// Docker-compatible engines (Docker Desktop, OrbStack, Colima, Podman): image and build-cache sizes with safe prunes
/// only. Volumes, containers and VM disks are never offered: they can hold user data.
struct ContainerEngineAdapter: ToolAdapter {
    /// One `system df` category shown as a row, with the prune that only touches unused data of that category.
    struct Row: Sendable {
        let type: String
        let id: String
        let tool: LocalizedStringResource
        let prune: [String]
        let risk: Risk
        let note: LocalizedStringResource
    }

    let id: String
    let executable: String
    let name: LocalizedStringResource
    let notRunning: LocalizedStringResource
    let rows: [Row]

    static let docker = ContainerEngineAdapter(
        id: "docker", executable: "docker", name: "Docker", notRunning: "Docker is not running.",
        rows: [
            Row(
                type: "Images", id: "docker.images", tool: "Docker images", prune: ["image", "prune", "-f"],
                risk: .review, note: "Removes dangling images only: untagged layers that no image or container uses."),
            Row(
                type: "Build Cache", id: "docker.buildCache", tool: "Docker build cache",
                prune: ["builder", "prune", "-f"], risk: .safe,
                note: "Removes the build cache. Later builds may take longer."),
        ])

    static let podman = ContainerEngineAdapter(
        id: "podman", executable: "podman", name: "Podman", notRunning: "Podman is not running.",
        rows: [
            Row(
                type: "Images", id: "podman.images", tool: "Podman images", prune: ["image", "prune", "-f"],
                risk: .review, note: "Removes dangling images only: untagged layers that no image or container uses.")
        ])

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        guard let path = locator.locate(executable) else { return [] }
        guard let output = await ToolProbe.output(runner, path, ["system", "df", "--format", "{{json .}}"]) else {
            return [
                ToolStorage(
                    id: id, tool: name, category: .containers, location: nil, size: nil, cleanup: nil,
                    note: notRunning)
            ]
        }
        let entries = LenientJSON.records(output)
        return rows.compactMap { row in
            guard let entry = entries.first(where: { $0["Type"] as? String == row.type }) else { return nil }
            let size = (entry["Size"] as? String).flatMap(Self.parseSize) ?? LenientJSON.int64(entry["Size"])
            return ToolStorage(
                id: row.id, tool: row.tool, category: .containers, location: nil, size: size,
                cleanup: ToolCleanupAction(executable: path, arguments: row.prune, risk: row.risk), note: row.note)
        }
    }

    /// Parses human sizes such as `1.2GB` or `800MB (66%)`; Docker and Podman use decimal (1000-based) units.
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

/// Colima profiles: each profile's VM folder and data disk, for information only.
struct ColimaAdapter: ToolAdapter {
    let id = "colima"

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        guard let colima = locator.locate("colima"),
            let output = await ToolProbe.output(runner, colima, ["list", "--json"])
        else { return [] }
        let root = [home + "/.colima", home + "/.config/colima"].first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        var rows: [ToolStorage] = []
        for profile in LenientJSON.records(output) {
            guard let name = profile["name"] as? String, Self.isProfileName(name) else { continue }
            // Colima names the Lima instance behind the default profile `colima`, and others `colima-<profile>`.
            let instance = name == "default" ? "colima" : "colima-" + name
            let folder = root.map { $0 + "/_lima/" + instance }
            let disk = root.map { $0 + "/_lima/_disks/" + instance }
            let folderSize = await ToolProbe.allocatedSize(of: folder)
            let diskSize = await ToolProbe.allocatedSize(of: disk)
            let size = Self.sum(folderSize, diskSize)
            rows.append(
                ToolStorage(
                    id: "colima.\(name)", tool: "Colima (\(name))", category: .containers,
                    location: folderSize != nil ? folder : (diskSize != nil ? disk : nil), size: size, cleanup: nil,
                    note: "A Colima virtual machine and its disk. Shown for information."))
        }
        return rows
    }

    /// Profile names become path components, so anything that could leave the Colima folder is ignored.
    static func isProfileName(_ name: String) -> Bool {
        guard let first = name.first, first != "." else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private static func sum(_ first: Int64?, _ second: Int64?) -> Int64? {
        guard first != nil || second != nil else { return nil }
        let (total, overflow) = (first ?? 0).addingReportingOverflow(second ?? 0)
        return overflow ? nil : total
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

/// Android SDK components and virtual devices.
struct AndroidAdapter: ToolAdapter {
    let id: String
    private let environment: [String: String]?

    init(id: String = "android", environment: [String: String]? = nil) {
        self.id = id
        self.environment = environment
    }

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        let sdkPath = resolveSDKPath(home: home)
        let avdRoot = home + "/.android/avd"

        var isDir: ObjCBool = false
        let sdkExists = FileManager.default.fileExists(atPath: sdkPath, isDirectory: &isDir) && isDir.boolValue
        let avdExists = FileManager.default.fileExists(atPath: avdRoot, isDirectory: &isDir) && isDir.boolValue

        let sdkmanager = locateTool("sdkmanager", locator: locator, sdkPath: sdkPath)
        let avdmanager = locateTool("avdmanager", locator: locator, sdkPath: sdkPath)

        if !sdkExists && !avdExists && sdkmanager == nil && avdmanager == nil {
            return []
        }

        var rows: [ToolStorage] = []
        if sdkExists || sdkmanager != nil {
            rows += await inspectSDK(sdkPath: sdkPath, sdkmanager: sdkmanager)
        }
        if avdExists || avdmanager != nil {
            rows += await inspectAVDs(avdRoot: avdRoot, avdmanager: avdmanager)
        }
        return rows
    }

    private func resolveSDKPath(home: String) -> String {
        if let custom = environment?["ANDROID_HOME"], !custom.isEmpty {
            return custom.hasPrefix("/") ? custom : home + "/" + custom
        }
        if let custom = environment?["ANDROID_SDK_ROOT"], !custom.isEmpty {
            return custom.hasPrefix("/") ? custom : home + "/" + custom
        }
        return home + "/Library/Android/sdk"
    }

    private func locateTool(_ name: String, locator: ToolLocator, sdkPath: String) -> String? {
        if let found = locator.locate(name) { return found }
        let candidates = [
            sdkPath + "/cmdline-tools/latest/bin/" + name,
            sdkPath + "/tools/bin/" + name,
        ]
        for candidate in candidates {
            var info = stat()
            if stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    /// Reads installed packages from disk. sdkmanager is never run here: it now hands off to Google's Android CLI,
    /// which downloads the online catalogue. A package's ID is its folder path with `;` (`platforms;android-34`).
    private func inspectSDK(sdkPath: String, sdkmanager: String?) async -> [ToolStorage] {
        func uninstall(_ package: String) -> ToolCleanupAction? {
            guard let sdkmanager, Self.isValidPackageName(package) else { return nil }
            return ToolCleanupAction(executable: sdkmanager, arguments: ["--uninstall", package], risk: .review)
        }
        func folders(in directory: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { !$0.hasPrefix(".") }
        }

        var rows: [ToolStorage] = []
        let emulatorDir = sdkPath + "/emulator"
        if let size = await ToolProbe.allocatedSize(of: emulatorDir) {
            rows.append(
                ToolStorage(
                    id: "android.emulator",
                    tool: LocalizedStringResource("Android Emulator"),
                    category: .packageCaches,
                    location: emulatorDir,
                    size: size,
                    cleanup: uninstall("emulator"),
                    note: LocalizedStringResource("The Android Emulator application and support files.")
                ))
        }

        let platformsDir = sdkPath + "/platforms"
        for name in folders(in: platformsDir).sorted() {
            let folder = platformsDir + "/" + name
            guard let size = await ToolProbe.allocatedSize(of: folder) else { continue }
            rows.append(
                ToolStorage(
                    id: "android.platform.\(name)",
                    tool: LocalizedStringResource("Android Platform (\(name))"),
                    category: .packageCaches,
                    location: folder,
                    size: size,
                    cleanup: uninstall("platforms;" + name),
                    note: LocalizedStringResource("Android SDK platform files and system headers.")
                ))
        }

        let sysImgDir = sdkPath + "/system-images"
        for folder in (Self.findSystemImageFolders(root: sysImgDir) ?? []).sorted() {
            let rel = String(folder.dropFirst(sysImgDir.count + 1))
            rows.append(
                ToolStorage(
                    id: "android.system-image.\(rel.replacingOccurrences(of: "/", with: "."))",
                    tool: LocalizedStringResource("Android System Image (\(rel))"),
                    category: .packageCaches,
                    location: folder,
                    size: await ToolProbe.allocatedSize(of: folder),
                    cleanup: uninstall("system-images;" + rel.replacingOccurrences(of: "/", with: ";")),
                    note: LocalizedStringResource("Android system image for emulator virtual devices.")
                ))
        }

        // Only older build-tools: projects usually use the latest one, which is kept.
        let btDir = sdkPath + "/build-tools"
        for version in folders(in: btDir).sorted(by: Self.isVersion).dropLast() {
            let folder = btDir + "/" + version
            rows.append(
                ToolStorage(
                    id: "android.build-tools.\(version)",
                    tool: LocalizedStringResource("Android Build-Tools (\(version))"),
                    category: .packageCaches,
                    location: folder,
                    size: await ToolProbe.allocatedSize(of: folder),
                    cleanup: uninstall("build-tools;" + version),
                    note: LocalizedStringResource(
                        "An older version of Android build tools. Current projects usually use the latest version."
                    )
                ))
        }
        return rows
    }

    /// AVDs are `<name>.avd` folders with a `<name>.ini` beside them; avdmanager is not run to list them (see above).
    private func inspectAVDs(avdRoot: String, avdmanager: String?) async -> [ToolStorage] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: avdRoot) else { return [] }
        var rows: [ToolStorage] = []
        for entry in entries.sorted() where entry.hasSuffix(".avd") {
            let name = String(entry.dropLast(".avd".count))
            guard Self.isValidAVDName(name) else { continue }
            let iniFile = avdRoot + "/" + name + ".ini"
            guard FileManager.default.fileExists(atPath: iniFile) else { continue }
            let avdDir = avdRoot + "/" + entry
            let size = await ToolProbe.allocatedSize(of: avdDir)

            let cleanup = avdmanager.map {
                ToolCleanupAction(executable: $0, arguments: ["delete", "avd", "-n", name], risk: .review)
            }

            rows.append(
                ToolStorage(
                    id: "android.avd.\(name)",
                    tool: LocalizedStringResource("Android AVD (\(name))"),
                    category: .simulators,
                    location: avdDir,
                    size: size,
                    cleanup: cleanup,
                    note: LocalizedStringResource(
                        "An Android Virtual Device and its storage. Deleting it removes its state and installed apps."
                    )
                ))
        }
        return rows
    }

    static func isValidPackageName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix(".") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ";_-.".contains($0)) }
    }

    static func isValidAVDName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix(".") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
    }

    static func isVersion(_ lhs: String, olderThan rhs: String) -> Bool {
        let lParts = lhs.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        let rParts = rhs.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        for (l, r) in zip(lParts, rParts) {
            if l != r { return l < r }
        }
        return lParts.count < rParts.count
    }

    static func findSystemImageFolders(root: String) -> [String]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return nil }
        var leaves: [String] = []
        var queue = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard
                let children = try? FileManager.default.contentsOfDirectory(atPath: current).filter({
                    !$0.hasPrefix(".")
                })
            else { continue }
            var hasSubdir = false
            for child in children {
                let childPath = current + "/" + child
                var childIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: childPath, isDirectory: &childIsDir), childIsDir.boolValue {
                    hasSubdir = true
                    queue.append(childPath)
                }
            }
            if !hasSubdir && current != root {
                leaves.append(current)
            }
        }
        return leaves.isEmpty ? nil : leaves
    }
}

/// Ollama local model store: per-model rows with removal via ollama rm and store sizing.
struct OllamaAdapter: ToolAdapter {
    let id = "ollama"

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        let storePath = home + "/.ollama/models"
        var isDir: ObjCBool = false
        let storeExists = FileManager.default.fileExists(atPath: storePath, isDirectory: &isDir) && isDir.boolValue
        let ollamaPath = locator.locate("ollama")

        if !storeExists && ollamaPath == nil {
            return []
        }

        if let ollamaPath {
            guard let output = await ToolProbe.output(runner, ollamaPath, ["list"]) else {
                return [
                    ToolStorage(
                        id: "ollama",
                        tool: LocalizedStringResource("Ollama"),
                        category: .aiModels,
                        location: storeExists ? storePath : nil,
                        size: nil,
                        cleanup: nil,
                        note: LocalizedStringResource("Ollama is not running.")
                    )
                ]
            }

            let models = Self.parseModels(output)
            return models.map { model in
                ToolStorage(
                    id: "ollama.\(model.name)",
                    tool: LocalizedStringResource("Ollama (\(model.name))"),
                    category: .aiModels,
                    location: storeExists ? storePath : nil,
                    size: model.size,
                    cleanup: ToolCleanupAction(
                        executable: ollamaPath,
                        arguments: ["rm", model.name],
                        risk: .review
                    ),
                    note: LocalizedStringResource("An Ollama model. It can be downloaded again with ollama pull.")
                )
            }
        } else {
            return [
                ToolStorage(
                    id: "ollama.models",
                    tool: LocalizedStringResource("Ollama models"),
                    category: .aiModels,
                    location: storePath,
                    size: await ToolProbe.allocatedSize(of: storePath),
                    cleanup: nil,
                    note: LocalizedStringResource("Ollama's local model store. Shown for information.")
                )
            ]
        }
    }

    static func parseModels(_ output: String) -> [(name: String, size: Int64?)] {
        var models: [(name: String, size: Int64?)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("NAME") { continue }
            let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 2 else { continue }
            let name = tokens[0]
            guard isValidModelName(name), isValidID(tokens[1]) else { continue }
            let size: Int64?
            if tokens.count >= 4, let bytes = parseSize(tokens[2] + tokens[3]) {
                size = bytes
            } else if tokens.count >= 3, let bytes = parseSize(tokens[2]) {
                size = bytes
            } else {
                size = nil
            }
            models.append((name: name, size: size))
        }
        return models
    }

    static func isValidModelName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix(".") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ":/._-".contains($0)) }
    }

    static func isValidID(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.hasPrefix("sha256:") {
            return text.dropFirst("sha256:".count).allSatisfy(\.isHexDigit)
        }
        return text.allSatisfy(\.isHexDigit)
    }

    static func parseSize(_ text: String) -> Int64? {
        ContainerEngineAdapter.parseSize(text)
    }
}

/// LM Studio local model stores: folder sizes under ~/.lmstudio/models and legacy ~/.cache/lm-studio/models.
struct LMStudioAdapter: ToolAdapter {
    let id = "lmstudio"

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        let roots: [(path: String, isLegacy: Bool)] = [
            (home + "/.lmstudio/models", false),
            (home + "/.cache/lm-studio/models", true),
        ]

        var rows: [ToolStorage] = []
        for (root, isLegacy) in roots {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard
                let children = try? FileManager.default.contentsOfDirectory(atPath: root).filter({
                    !$0.hasPrefix(".")
                })
            else { continue }

            for child in children.sorted() {
                let childPath = root + "/" + child
                var childIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: childPath, isDirectory: &childIsDir), childIsDir.boolValue
                else { continue }

                let subchildren =
                    (try? FileManager.default.contentsOfDirectory(atPath: childPath))?
                    .filter { !$0.hasPrefix(".") } ?? []
                var subdirs: [String] = []
                for sub in subchildren {
                    let subPath = childPath + "/" + sub
                    var subIsDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: subPath, isDirectory: &subIsDir), subIsDir.boolValue {
                        subdirs.append(sub)
                    }
                }

                if !subdirs.isEmpty {
                    for sub in subdirs.sorted() {
                        let modelFolder = childPath + "/" + sub
                        let modelName = child + "/" + sub
                        let idPrefix = isLegacy ? "lmstudio.legacy." : "lmstudio."
                        let safeId = idPrefix + modelName.replacingOccurrences(of: "/", with: ".")
                        rows.append(
                            ToolStorage(
                                id: safeId,
                                tool: LocalizedStringResource("LM Studio (\(modelName))"),
                                category: .aiModels,
                                location: modelFolder,
                                size: await ToolProbe.allocatedSize(of: modelFolder),
                                cleanup: nil,
                                note: LocalizedStringResource("An LM Studio model. Shown for information.")
                            ))
                    }
                } else {
                    let idPrefix = isLegacy ? "lmstudio.legacy." : "lmstudio."
                    let safeId = idPrefix + child
                    rows.append(
                        ToolStorage(
                            id: safeId,
                            tool: LocalizedStringResource("LM Studio (\(child))"),
                            category: .aiModels,
                            location: childPath,
                            size: await ToolProbe.allocatedSize(of: childPath),
                            cleanup: nil,
                            note: LocalizedStringResource("An LM Studio model. Shown for information.")
                        ))
                }
            }
        }
        return rows
    }
}

/// Hugging Face hub cache: model repository directories under $HF_HOME/hub or ~/.cache/huggingface/hub.
struct HuggingFaceAdapter: ToolAdapter {
    let id: String
    private let environment: [String: String]?

    init(id: String = "huggingface", environment: [String: String]? = nil) {
        self.id = id
        self.environment = environment
    }

    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage] {
        let hubPath: String = {
            if let custom = environment?["HF_HOME"], !custom.isEmpty {
                let base = custom.hasPrefix("/") ? custom : home + "/" + custom
                return base + "/hub"
            }
            return home + "/.cache/huggingface/hub"
        }()

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hubPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard
            let entries = try? FileManager.default.contentsOfDirectory(atPath: hubPath).filter({
                $0.hasPrefix("models--")
            })
        else { return [] }

        var rows: [ToolStorage] = []
        for entry in entries.sorted() {
            let folder = hubPath + "/" + entry
            var entryIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &entryIsDir), entryIsDir.boolValue
            else { continue }

            let modelParts = entry.dropFirst("models--".count).components(separatedBy: "--")
            let modelName = modelParts.joined(separator: "/")

            rows.append(
                ToolStorage(
                    id: "huggingface.\(entry)",
                    tool: LocalizedStringResource("Hugging Face (\(modelName))"),
                    category: .aiModels,
                    location: folder,
                    size: await ToolProbe.allocatedSize(of: folder),
                    cleanup: nil,
                    note: LocalizedStringResource("A cached Hugging Face model. Shown for information.")
                ))
        }
        return rows
    }
}
