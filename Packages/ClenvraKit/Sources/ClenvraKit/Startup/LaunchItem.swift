import Foundation

/// An automatic background or startup job managed by launchd, exposed to detect orphaned items and review background execution.
public struct LaunchItem: Sendable, Hashable, Identifiable {
    /// Domain of the launch item determining whether it runs in the user session or as root system-wide.
    public enum Domain: Sendable, Hashable {
        /// User agent running in the per-user GUI session.
        case userAgent
        /// System-wide agent running in GUI login sessions for all users.
        case systemAgent
        /// System daemon running in the background as root independently of user sessions.
        case systemDaemon
    }

    /// Trigger conditions deciding when launchd spawns the process.
    public enum Schedule: Sendable, Hashable {
        /// Runs immediately when loaded into launchd.
        case atLoad
        /// Kept running continuously or restarted upon specified conditions.
        case keepAlive
        /// Runs periodically at a recurring time interval in seconds.
        case interval(seconds: Int)
        /// Runs at scheduled calendar times.
        case calendar
        /// Runs on demand when triggered by Mach messages, sockets, or file paths.
        case onDemand
    }

    /// Disk presence state of the job binary to identify orphaned background leftovers.
    public enum ProgramState: Sendable, Hashable {
        /// Executable exists on disk at the indicated path.
        case present
        /// Executable is missing from disk, identifying an orphaned residue of a deleted app.
        case missing
        /// Executable path is relative, bundle-relative, or could not be determined.
        case unknown
    }

    /// Authorization and enable status managed by macOS ServiceManagement.
    public enum Status: Sendable, Hashable {
        /// Job is allowed and enabled to run.
        case enabled
        /// Job has been explicitly disabled.
        case disabled
        /// Job requires user approval in System Settings before macOS allows it to run.
        case requiresApproval
        /// Job is not registered with ServiceManagement.
        case notRegistered
        /// Status could not be determined.
        case unknown
    }

    /// Unique identifier matching the configuration plist path.
    public let id: String
    /// Filesystem path to the launchd plist file.
    public let plistPath: String
    /// Launchd execution domain.
    public let domain: Domain
    /// Unique service label defined in the plist.
    public let label: String?
    /// Executable path run by the job.
    public let program: String?
    /// Command-line arguments passed when executing the job.
    public let arguments: [String]
    /// Set of schedule conditions triggering job execution.
    public let schedules: Set<Schedule>
    /// Disk presence status of the program executable.
    public let programState: ProgramState
    /// Bundle identifiers declared by the launch item as its owner.
    public let associatedBundleIdentifiers: [String]
    /// Bundle path of the installed app owning this launch item.
    public let ownerAppPath: String?
    /// Whether the service belongs to macOS itself to protect system components.
    public let isApple: Bool
    /// ServiceManagement registration and approval status.
    public let status: Status
    /// Indicates if reading or parsing the plist file failed.
    public let parseError: Bool

    /// Creates a launch item for display and cleanup analysis.
    public init(
        id: String? = nil,
        plistPath: String,
        domain: Domain,
        label: String?,
        program: String?,
        arguments: [String],
        schedules: Set<Schedule>,
        programState: ProgramState,
        associatedBundleIdentifiers: [String],
        ownerAppPath: String?,
        isApple: Bool,
        status: Status,
        parseError: Bool
    ) {
        self.id = id ?? plistPath
        self.plistPath = plistPath
        self.domain = domain
        self.label = label
        self.program = program
        self.arguments = arguments
        self.schedules = schedules
        self.programState = programState
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
        self.ownerAppPath = ownerAppPath
        self.isApple = isApple
        self.status = status
        self.parseError = parseError
    }
}
