import Darwin
import Foundation
import ServiceManagement

/// Discovers launch agents and daemons across user and system domains to inspect background jobs.
public struct LaunchItemReader: Sendable {
    /// Default user LaunchAgents path in the active user's home folder.
    public static let defaultUserAgents: String = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/LaunchAgents")
        .path(percentEncoded: false)

    /// Queries ServiceManagement for legacy launchd plist registration status.
    public static let serviceManagementStatus: @Sendable (String) -> LaunchItem.Status = { plistPath in
        let url = URL(filePath: plistPath)
        switch SMAppService.statusForLegacyPlist(at: url) {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .notRegistered
        @unknown default:
            return .unknown
        }
    }

    private let userAgents: String
    private let systemAgents: String
    private let systemDaemons: String
    private let status: @Sendable (String) -> LaunchItem.Status

    /// Creates a launch item reader targeting specified roots with a ServiceManagement status resolver.
    public init(
        userAgents: String = LaunchItemReader.defaultUserAgents,
        systemAgents: String = "/Library/LaunchAgents",
        systemDaemons: String = "/Library/LaunchDaemons",
        status: @escaping @Sendable (String) -> LaunchItem.Status = LaunchItemReader.serviceManagementStatus
    ) {
        self.userAgents = userAgents
        self.systemAgents = systemAgents
        self.systemDaemons = systemDaemons
        self.status = status
    }

    /// Discovers all launch items across configured domains and attributes them to installed apps.
    public func read(installedApps: [InstalledApp] = []) -> [LaunchItem] {
        var items: [LaunchItem] = []
        items.append(contentsOf: readDirectory(at: userAgents, domain: .userAgent, installedApps: installedApps))
        items.append(contentsOf: readDirectory(at: systemAgents, domain: .systemAgent, installedApps: installedApps))
        items.append(contentsOf: readDirectory(at: systemDaemons, domain: .systemDaemon, installedApps: installedApps))

        return items.sorted { lhs, rhs in
            let lhsMissing = lhs.programState == .missing
            let rhsMissing = rhs.programState == .missing
            if lhsMissing != rhsMissing {
                return lhsMissing && !rhsMissing
            }
            let lhsLabel = lhs.label ?? ""
            let rhsLabel = rhs.label ?? ""
            let comparison = lhsLabel.localizedStandardCompare(rhsLabel)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.plistPath < rhs.plistPath
        }
    }

    private func readDirectory(
        at path: String,
        domain: LaunchItem.Domain,
        installedApps: [InstalledApp]
    ) -> [LaunchItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        var results: [LaunchItem] = []
        for entry in entries {
            guard !entry.hasPrefix("."), entry.hasSuffix(".plist") else { continue }
            let itemPath = (path as NSString).appendingPathComponent(entry)
            var statInfo = stat()
            guard lstat(itemPath, &statInfo) == 0 else { continue }

            let fileType = statInfo.st_mode & S_IFMT
            if fileType == S_IFLNK {
                results.append(makeParseErrorItem(plistPath: itemPath, domain: domain))
            } else if fileType == S_IFREG {
                if statInfo.st_size > (1024 * 1024) {
                    results.append(makeParseErrorItem(plistPath: itemPath, domain: domain))
                } else {
                    guard let data = try? Data(contentsOf: URL(filePath: itemPath)),
                        let plist =
                            (try? PropertyListSerialization.propertyList(
                                from: data,
                                options: [],
                                format: nil
                            )) as? [String: Any]
                    else {
                        results.append(makeParseErrorItem(plistPath: itemPath, domain: domain))
                        continue
                    }
                    results.append(
                        parseItem(
                            plist: plist,
                            plistPath: itemPath,
                            domain: domain,
                            installedApps: installedApps
                        )
                    )
                }
            }
        }
        return results
    }

    private func parseItem(
        plist: [String: Any],
        plistPath: String,
        domain: LaunchItem.Domain,
        installedApps: [InstalledApp]
    ) -> LaunchItem {
        let label = plist["Label"] as? String
        let isApple = label?.hasPrefix("com.apple.") ?? false

        let rawProgram = plist["Program"] as? String
        let arguments: [String] =
            if let args = plist["ProgramArguments"] as? [String] {
                args
            } else if let anyArgs = plist["ProgramArguments"] as? [Any] {
                anyArgs.compactMap { $0 as? String }
            } else {
                []
            }

        let program: String? =
            if let rawProgram, !rawProgram.isEmpty {
                rawProgram
            } else if let firstArg = arguments.first, !firstArg.isEmpty {
                firstArg
            } else if let bundleProg = plist["BundleProgram"] as? String, !bundleProg.isEmpty {
                bundleProg
            } else {
                nil
            }

        var schedules = Set<LaunchItem.Schedule>()
        if let runAtLoad = plist["RunAtLoad"] as? Bool, runAtLoad {
            schedules.insert(.atLoad)
        } else if let num = plist["RunAtLoad"] as? NSNumber, num.boolValue {
            schedules.insert(.atLoad)
        }

        if let keepAliveBool = plist["KeepAlive"] as? Bool {
            if keepAliveBool {
                schedules.insert(.keepAlive)
            }
        } else if let keepAliveNum = plist["KeepAlive"] as? NSNumber {
            if keepAliveNum.boolValue {
                schedules.insert(.keepAlive)
            }
        } else if plist["KeepAlive"] is [String: Any] {
            schedules.insert(.keepAlive)
        }

        if let interval = plist["StartInterval"] as? Int {
            schedules.insert(.interval(seconds: interval))
        } else if let num = plist["StartInterval"] as? NSNumber {
            schedules.insert(.interval(seconds: num.intValue))
        }

        if plist["StartCalendarInterval"] is [String: Any] || plist["StartCalendarInterval"] is [Any] {
            schedules.insert(.calendar)
        }

        if schedules.isEmpty {
            schedules.insert(.onDemand)
        }

        let programState: LaunchItem.ProgramState =
            if plist["BundleProgram"] != nil {
                .unknown
            } else if let program, program.hasPrefix("/") {
                programFileState(at: program)
            } else {
                .unknown
            }

        let associatedBundleIdentifiers: [String] =
            if let single = plist["AssociatedBundleIdentifiers"] as? String {
                [single]
            } else if let array = plist["AssociatedBundleIdentifiers"] as? [String] {
                array
            } else if let anyArray = plist["AssociatedBundleIdentifiers"] as? [Any] {
                anyArray.compactMap { $0 as? String }
            } else {
                []
            }

        let ownerAppPath = Self.matchOwnerApp(
            associatedBundleIdentifiers: associatedBundleIdentifiers,
            program: program,
            label: label,
            installedApps: installedApps
        )

        return LaunchItem(
            plistPath: plistPath,
            domain: domain,
            label: label,
            program: program,
            arguments: arguments,
            schedules: schedules,
            programState: programState,
            associatedBundleIdentifiers: associatedBundleIdentifiers,
            ownerAppPath: ownerAppPath,
            isApple: isApple,
            status: status(plistPath),
            parseError: false
        )
    }

    /// Follows symlinks: a link whose target was deleted (common after uninstalling Homebrew packages) cannot run,
    /// so it counts as missing.
    private func programFileState(at path: String) -> LaunchItem.ProgramState {
        var statInfo = stat()
        if stat(path, &statInfo) == 0 {
            return .present
        }
        if errno == ENOENT {
            return .missing
        }
        return .unknown
    }

    private func makeParseErrorItem(plistPath: String, domain: LaunchItem.Domain) -> LaunchItem {
        LaunchItem(
            plistPath: plistPath,
            domain: domain,
            label: nil,
            program: nil,
            arguments: [],
            schedules: [],
            programState: .unknown,
            associatedBundleIdentifiers: [],
            ownerAppPath: nil,
            isApple: false,
            status: status(plistPath),
            parseError: true
        )
    }

    private static func matchOwnerApp(
        associatedBundleIdentifiers: [String],
        program: String?,
        label: String?,
        installedApps: [InstalledApp]
    ) -> String? {
        for assocID in associatedBundleIdentifiers {
            if let app = installedApps.first(where: {
                $0.bundleIdentifier == assocID || $0.embeddedBundleIdentifiers.contains(assocID)
            }) {
                return app.id
            }
        }

        if let program {
            let matches = installedApps.filter { app in
                program.hasPrefix(app.id + "/")
            }
            if let longestMatch = matches.max(by: { $0.id.count < $1.id.count }) {
                return longestMatch.id
            }
        }

        if let label {
            if let exactMatch = installedApps.first(where: {
                $0.bundleIdentifier == label || $0.embeddedBundleIdentifiers.contains(label)
            }) {
                return exactMatch.id
            }
            let prefixMatches = installedApps.compactMap { app -> (app: InstalledApp, length: Int)? in
                guard let bundleID = app.bundleIdentifier, label.hasPrefix(bundleID + ".") else {
                    return nil
                }
                return (app, bundleID.count)
            }
            if let bestPrefix = prefixMatches.max(by: { $0.length < $1.length }) {
                return bestPrefix.app.id
            }
        }

        return nil
    }
}
