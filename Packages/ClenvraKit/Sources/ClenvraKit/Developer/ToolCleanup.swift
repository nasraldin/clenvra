public import Foundation

/// One row of the Developer section: how much space a tool's store uses and how the tool itself can shrink it.
public struct ToolStorage: Sendable, Hashable, Identifiable {
    /// Stable across scans (for example `pnpm.store`), so the UI can keep selection between refreshes.
    public let id: String
    /// Display name of the tool or store (localized via the app's String Catalog).
    public let tool: LocalizedStringResource
    /// Section the row belongs to: package caches, simulators or containers.
    public let category: CleanupCategory
    /// Absolute path that was measured or reported, so the user can reveal it.
    public let location: String?
    /// Allocated bytes, measured or reported by the tool; `nil` when unknown.
    public let size: Int64?
    /// The tool's own command; `nil` when only visibility is offered.
    public let cleanup: ToolCleanupAction?
    /// Short plain explanation of what the command does or what is lost (localized).
    public let note: LocalizedStringResource?

    /// Memberwise, so adapters and previews can build rows.
    public init(
        id: String, tool: LocalizedStringResource, category: CleanupCategory, location: String?, size: Int64?,
        cleanup: ToolCleanupAction?, note: LocalizedStringResource?
    ) {
        self.id = id
        self.tool = tool
        self.category = category
        self.location = location
        self.size = size
        self.cleanup = cleanup
        self.note = note
    }
}

/// A tool command that frees space, shown verbatim before it runs because it bypasses the Trash.
public struct ToolCleanupAction: Sendable, Hashable {
    /// Absolute executable and fixed argv; never interpreted by a shell.
    public let command: Command
    /// `.safe` actions may be pre-selected; `.review` ones cost a re-download or similar.
    public let risk: Risk
    /// Tool commands do not use the Trash, so the confirmation sheet must list them as irreversible.
    public let isIrreversible: Bool
    /// Exactly what will run, for the confirmation sheet, for example `pnpm store prune`.
    public let summary: String

    /// Tool commands are irreversible unless a caller knows otherwise.
    public init(command: Command, risk: Risk, isIrreversible: Bool = true, summary: String) {
        self.command = command
        self.risk = risk
        self.isIrreversible = isIrreversible
        self.summary = summary
    }

    /// Builds the command with the cleanup timeout and a summary of the tool's name plus its arguments.
    init(executable: String, arguments: [String], risk: Risk) {
        let name = (executable as NSString).lastPathComponent
        self.init(
            command: Command(executable: executable, arguments: arguments, timeout: ToolProbe.cleanupTimeout),
            risk: risk, summary: ([name] + arguments).joined(separator: " "))
    }
}

/// Reports one developer tool's storage, detected per Mac, so absent tools cost nothing.
public protocol ToolAdapter: Sendable {
    /// Stable identifier of the adapter, for example `pnpm`.
    var id: String { get }
    /// Returns nothing when the tool is not installed. Read-only: only probe commands and size measurement.
    func inspect(locator: ToolLocator, runner: any CommandRunning, home: String) async -> [ToolStorage]
}

/// Runs a confirmed tool cleanup, kept separate from inspection so only an explicit user action can reach it.
public enum ToolCleanupRunner {
    /// Runs `action.command` unchanged, streaming its output, and returns the result for the activity log.
    public static func run(
        _ action: ToolCleanupAction, runner: any CommandRunning, onOutput: (@Sendable (OutputLine) -> Void)?
    ) async throws -> CommandResult {
        try await runner.run(action.command, onOutput: onOutput)
    }
}

/// Shared helpers for adapters: bounded read-only probes and folder measurement.
enum ToolProbe {
    static let probeTimeout = Duration.seconds(10)
    static let cleanupTimeout = Duration.seconds(600)

    /// Standard output of a probe that exited 0, or `nil` for any failure, timeout or launch error.
    static func output(_ runner: any CommandRunning, _ executable: String, _ arguments: [String]) async -> String? {
        let command = Command(executable: executable, arguments: arguments, timeout: probeTimeout)
        guard let result = try? await runner.run(command), result.terminationReason == .exited,
            result.exitStatus == 0
        else { return nil }
        return result.standardOutput
    }

    /// The last non-empty line of `output`, trimmed, if it is an absolute path; tools may print warnings first.
    static func absolutePath(in output: String?) -> String? {
        guard let output else { return nil }
        let line = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let line, line.hasPrefix("/") else { return nil }
        return line
    }

    /// Allocated bytes of the directory at `path`, or `nil` when it is not a directory or cannot be read.
    static func allocatedSize(of path: String?) async -> Int64? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
            let snapshot = try? await StorageScanner.scan(root: path)
        else { return nil }
        return snapshot.aggregate(at: path)?.allocated
    }
}

extension ToolStorage {
    /// Localized text compares by its key; everything else compares by value.
    public static func == (lhs: ToolStorage, rhs: ToolStorage) -> Bool {
        lhs.id == rhs.id && lhs.tool.key == rhs.tool.key && lhs.category == rhs.category
            && lhs.location == rhs.location && lhs.size == rhs.size && lhs.cleanup == rhs.cleanup
            && lhs.note?.key == rhs.note?.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(location)
        hasher.combine(size)
    }
}
