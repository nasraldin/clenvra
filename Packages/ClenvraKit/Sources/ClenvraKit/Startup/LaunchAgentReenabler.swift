import Darwin
import Foundation

/// Loads a user launch agent again after its plist was put back from the Trash, so undoing a Startup removal
/// restores behaviour and not just the file (SB-3). Only the user's own agents qualify, and only after the plist
/// has been checked the way launchd would check it.
public struct LaunchAgentReenabler: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// `launchctl bootstrap` loaded the agent.
        case enabled
        /// The agent was already loaded; nothing was run.
        case alreadyEnabled
        /// The record is not a Startup removal of a plist directly inside the user's LaunchAgents folder.
        case notAllowed
        /// The plist is missing, unsafe (symlink, wrong owner, writable by others) or has no sane Label.
        case invalidPlist
        /// `launchctl` refused; `nil` when it could not be run or did not exit normally.
        case failed(exitStatus: Int32?)
    }

    private let runner: any CommandRunning
    private let userAgentsDirectory: String
    private let userID: UInt32

    private static let launchctl = "/bin/launchctl"
    private static let maxPlistSize: off_t = 1024 * 1024
    private static let maxLabelLength = 255
    private static let labelCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// - Parameters:
    ///   - userAgentsDirectory: the user's `~/Library/LaunchAgents`, the only folder whose agents are re-enabled.
    ///   - userID: the GUI domain to load into; defaults to the current user.
    public init(
        runner: any CommandRunning, userAgentsDirectory: String = LaunchItemReader.defaultUserAgents,
        userID: UInt32? = nil
    ) {
        self.runner = runner
        self.userAgentsDirectory = Self.withoutTrailingSlash(userAgentsDirectory)
        self.userID = userID ?? getuid()
    }

    /// Whether the record is a Startup removal this type may undo; checks only the record, not the disk.
    public func canReenable(_ record: ActivityRecord) -> Bool {
        guard record.section == .startup, record.outcome.isMovedToTrash else { return false }
        let path = record.itemPath
        guard path.hasPrefix(userAgentsDirectory + "/") else { return false }
        let name = path.dropFirst(userAgentsDirectory.count + 1)
        return !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.hasSuffix(".plist")
    }

    /// Validates the plist at the record's path and, unless the agent is already loaded, runs
    /// `/bin/launchctl bootstrap gui/<uid> <plist>` (fixed argv, never a shell).
    @concurrent public func reenable(_ record: ActivityRecord) async -> Outcome {
        guard canReenable(record) else { return .notAllowed }
        let path = record.itemPath
        guard let label = validatedLabel(at: path) else { return .invalidPlist }

        let domain = "gui/\(userID)"
        let print = Command(
            executable: Self.launchctl, arguments: ["print", domain + "/" + label], timeout: .seconds(15))
        if let loaded = try? await runner.run(print), loaded.terminationReason == .exited, loaded.exitStatus == 0 {
            return .alreadyEnabled
        }

        let bootstrap = Command(
            executable: Self.launchctl, arguments: ["bootstrap", domain, path], timeout: .seconds(15))
        guard let result = try? await runner.run(bootstrap), result.terminationReason == .exited else {
            return .failed(exitStatus: nil)
        }
        return result.exitStatus == 0 ? .enabled : .failed(exitStatus: result.exitStatus)
    }

    /// The plist's Label when the file is a small regular file owned by the user and not writable by others
    /// (launchd refuses anything else), and the Label is plain, non-Apple and not managed software.
    private func validatedLabel(at path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == userID,
            info.st_mode & (S_IWGRP | S_IWOTH) == 0, info.st_size <= Self.maxPlistSize,
            let data = FileManager.default.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let label = plist["Label"] as? String
        else { return nil }
        guard !label.isEmpty, label.count <= Self.maxLabelLength, label.first != "-",
            label.allSatisfy(Self.labelCharacters.contains), !label.hasPrefix("com.apple."),
            !ManagedAgents.isManaged(identifier: label)
        else { return nil }
        return label
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
