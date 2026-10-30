public import Foundation

/// Overall status outcome for a system security evaluation.
public enum SecurityCheckStatus: String, Sendable, Equatable {
    /// Security control is fully active and protecting the system.
    case good
    /// Security control is disabled or requires user review.
    case attention
    /// Status could not be determined or command execution failed.
    case unknown
}

/// A discrete system security check result with status, raw detail, and optional deep link.
public struct SecurityCheck: Sendable, Equatable, Identifiable {
    /// Unique check identifier (e.g. "sip", "fileVault", "gatekeeper").
    public let id: String
    /// Security posture classification.
    public let status: SecurityCheckStatus
    /// Short factual output or explanation of the current state.
    public let detail: String
    /// Deep link to macOS System Settings preference pane when Apple provides one.
    public let settingsURL: URL?

    /// Creates a verified security check record.
    public init(
        id: String,
        status: SecurityCheckStatus,
        detail: String,
        settingsURL: URL? = nil
    ) {
        self.id = id
        self.status = status
        self.detail = detail
        self.settingsURL = settingsURL
    }
}

/// Evaluates macOS system security protections via non-intrusive read-only probes.
public final class SecurityChecker: Sendable {
    /// Provider returning version and modification date for XProtect bundle.
    public typealias XProtectReader = @Sendable () -> (version: String?, modificationDate: Date?)
    /// Provider returning automatic critical and configuration data update flags.
    public typealias SoftwareUpdateReader = @Sendable () -> (critical: Bool?, config: Bool?)

    private let runner: any CommandRunning
    private let xprotectReader: XProtectReader
    private let softwareUpdateReader: SoftwareUpdateReader

    /// Creates a security checker with injected runners and readers for unit testing.
    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        xprotectReader: XProtectReader? = nil,
        softwareUpdateReader: SoftwareUpdateReader? = nil
    ) {
        self.runner = runner
        self.xprotectReader = xprotectReader ?? Self.defaultXProtectReader
        self.softwareUpdateReader = softwareUpdateReader ?? Self.defaultSoftwareUpdateReader
    }

    /// Runs all security checks in sequence and returns structured results.
    @concurrent public func checkAll() async -> [SecurityCheck] {
        let sip = await checkSIP()
        let fileVault = await checkFileVault()
        let gatekeeper = await checkGatekeeper()
        let firewall = await checkFirewall()
        let xprotect = checkXProtect()
        let securityUpdates = checkSecurityUpdates()

        return [sip, fileVault, gatekeeper, firewall, xprotect, securityUpdates]
    }

    // MARK: - Pure Parsers

    /// Pure parser for csrutil status output.
    public static func parseSIP(output: String, exitStatus: Int32) -> SecurityCheck {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let status: SecurityCheckStatus
        if exitStatus == 0 && lower.contains("enabled") {
            status = .good
        } else if exitStatus == 0 && lower.contains("disabled") {
            status = .attention
        } else {
            status = .unknown
        }
        let detail = trimmed.isEmpty ? "System Integrity Protection status unavailable" : trimmed
        return SecurityCheck(id: "sip", status: status, detail: detail, settingsURL: nil)
    }

    /// Pure parser for fdesetup status output.
    public static func parseFileVault(output: String, exitStatus: Int32) -> SecurityCheck {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let status: SecurityCheckStatus
        if exitStatus == 0 && lower.contains("is on") {
            status = .good
        } else if exitStatus == 0 && lower.contains("is off") {
            status = .attention
        } else {
            status = .unknown
        }
        let detail = trimmed.isEmpty ? "FileVault status unavailable" : trimmed
        let url = SystemSettingsPane.fileVault.url
        return SecurityCheck(id: "fileVault", status: status, detail: detail, settingsURL: url)
    }

    /// Pure parser for spctl --status output.
    public static func parseGatekeeper(output: String, exitStatus: Int32) -> SecurityCheck {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let status: SecurityCheckStatus
        if exitStatus == 0 && lower.contains("assessments enabled") {
            status = .good
        } else if exitStatus == 0 && lower.contains("assessments disabled") {
            status = .attention
        } else {
            status = .unknown
        }
        let detail = trimmed.isEmpty ? "Gatekeeper status unavailable" : trimmed
        let url = SystemSettingsPane.gatekeeper.url
        return SecurityCheck(id: "gatekeeper", status: status, detail: detail, settingsURL: url)
    }

    /// Pure parser for socketfilterfw global state output.
    public static func parseFirewall(output: String, exitStatus: Int32) -> SecurityCheck {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let status: SecurityCheckStatus
        if exitStatus == 0 && lower.contains("firewall is enabled") {
            status = .good
        } else if exitStatus == 0 && lower.contains("firewall is disabled") {
            status = .attention
        } else {
            status = .unknown
        }
        let detail = trimmed.isEmpty ? "Firewall status unavailable" : trimmed
        let url = SystemSettingsPane.firewall.url
        return SecurityCheck(id: "firewall", status: status, detail: detail, settingsURL: url)
    }

    /// Pure parser for XProtect bundle version and update date.
    public static func parseXProtect(version: String?, modificationDate: Date?) -> SecurityCheck {
        guard let version, !version.isEmpty else {
            return SecurityCheck(
                id: "xprotect",
                status: .unknown,
                detail: "XProtect configuration unavailable",
                settingsURL: nil
            )
        }
        let dateString: String
        if let modificationDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            dateString = formatter.string(from: modificationDate)
        } else {
            dateString = "date unknown"
        }
        let detail = "Version \(version) (updated \(dateString))"
        return SecurityCheck(id: "xprotect", status: .good, detail: detail, settingsURL: nil)
    }

    /// Pure parser for background software update preferences.
    public static func parseSecurityUpdates(critical: Bool?, config: Bool?) -> SecurityCheck {
        let url = SystemSettingsPane.softwareUpdate.url
        guard let critical, let config else {
            return SecurityCheck(
                id: "securityUpdates",
                status: .unknown,
                detail: "Automatic update preferences unreadable",
                settingsURL: url
            )
        }
        if critical && config {
            return SecurityCheck(
                id: "securityUpdates",
                status: .good,
                detail: "Automatic security and system data updates enabled",
                settingsURL: url
            )
        } else {
            return SecurityCheck(
                id: "securityUpdates",
                status: .attention,
                detail: "Automatic security or data updates disabled",
                settingsURL: url
            )
        }
    }

    // MARK: - Private Probes

    @concurrent private func checkSIP() async -> SecurityCheck {
        do {
            let cmd = Command(executable: "/usr/bin/csrutil", arguments: ["status"])
            let result = try await runner.run(cmd)
            return Self.parseSIP(output: result.standardOutput, exitStatus: result.exitStatus)
        } catch {
            return SecurityCheck(
                id: "sip",
                status: .unknown,
                detail: "Failed to query System Integrity Protection",
                settingsURL: nil
            )
        }
    }

    @concurrent private func checkFileVault() async -> SecurityCheck {
        do {
            let cmd = Command(executable: "/usr/bin/fdesetup", arguments: ["status"])
            let result = try await runner.run(cmd)
            return Self.parseFileVault(output: result.standardOutput, exitStatus: result.exitStatus)
        } catch {
            let url = SystemSettingsPane.fileVault.url
            return SecurityCheck(
                id: "fileVault",
                status: .unknown,
                detail: "Failed to query FileVault status",
                settingsURL: url
            )
        }
    }

    @concurrent private func checkGatekeeper() async -> SecurityCheck {
        do {
            let cmd = Command(executable: "/usr/sbin/spctl", arguments: ["--status"])
            let result = try await runner.run(cmd)
            return Self.parseGatekeeper(output: result.standardOutput, exitStatus: result.exitStatus)
        } catch {
            let url = SystemSettingsPane.gatekeeper.url
            return SecurityCheck(
                id: "gatekeeper",
                status: .unknown,
                detail: "Failed to query Gatekeeper status",
                settingsURL: url
            )
        }
    }

    @concurrent private func checkFirewall() async -> SecurityCheck {
        do {
            let cmd = Command(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getglobalstate"]
            )
            let result = try await runner.run(cmd)
            return Self.parseFirewall(output: result.standardOutput, exitStatus: result.exitStatus)
        } catch {
            let url = SystemSettingsPane.firewall.url
            return SecurityCheck(
                id: "firewall",
                status: .unknown,
                detail: "Failed to query Firewall status",
                settingsURL: url
            )
        }
    }

    private func checkXProtect() -> SecurityCheck {
        let (version, date) = xprotectReader()
        return Self.parseXProtect(version: version, modificationDate: date)
    }

    private func checkSecurityUpdates() -> SecurityCheck {
        let (critical, config) = softwareUpdateReader()
        return Self.parseSecurityUpdates(critical: critical, config: config)
    }

    // MARK: - Default Readers

    private static func defaultXProtectReader() -> (version: String?, modificationDate: Date?) {
        let plistPath = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
        let url = URL(filePath: plistPath)
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return (nil, nil)
        }

        let version = plist["CFBundleShortVersionString"] as? String
        let attributes = try? FileManager.default.attributesOfItem(atPath: plistPath)
        let modified = attributes?[.modificationDate] as? Date
        return (version, modified)
    }

    private static func defaultSoftwareUpdateReader() -> (critical: Bool?, config: Bool?) {
        let defaults = UserDefaults(suiteName: "com.apple.SoftwareUpdate")
        let criticalObj = defaults?.object(forKey: "CriticalUpdateInstall")
        let configObj = defaults?.object(forKey: "ConfigDataInstall")

        let critical: Bool?
        if let b = criticalObj as? Bool {
            critical = b
        } else if let n = criticalObj as? NSNumber {
            critical = n.boolValue
        } else {
            critical = nil
        }

        let config: Bool?
        if let b = configObj as? Bool {
            config = b
        } else if let n = configObj as? NSNumber {
            config = n.boolValue
        } else {
            config = nil
        }

        return (critical, config)
    }
}
