import Darwin
import Foundation

/// Finds developer tools by absolute path, because a GUI app's own `PATH` misses Homebrew, nvm, volta and friends.
public struct ToolLocator: Sendable {
    /// Directories to search when the login shell cannot be asked, covering the common install locations.
    public static let fallbackSearchPath: [String] = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            home + "/.local/bin", home + "/.volta/bin", home + "/.bun/bin",
        ]
    }()

    /// The user's login shell from the password database, so their own profile decides `PATH`; `/bin/zsh` otherwise.
    public static var defaultLoginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/") { return path }
        }
        return "/bin/zsh"
    }

    /// The constant command given to the login shell; nothing is ever interpolated into it.
    static let printPathScript = #"printf %s "$PATH""#

    /// Directories searched in order.
    public let searchPath: [String]

    /// `searchPath` is usually the result of `resolveLoginPath`, computed once per app launch.
    public init(searchPath: [String]) {
        self.searchPath = searchPath
    }

    /// Resolves tool names to absolute paths using the user's login shell PATH, computed once.
    ///
    /// Runs `<shell> -l -c 'printf %s "$PATH"'` with a 3 s timeout. This is the only place Clenvra uses a shell.
    /// Only the last output line is used (startup files may print banners), relative and empty entries are dropped,
    /// and duplicates are removed keeping the first. Any failure returns `fallbackSearchPath`.
    /// Tools set up only in interactive startup files (for example nvm in `.zshrc`) are not seen by a login shell;
    /// the fallback directories and the caller's own additions cover the common cases.
    public static func resolveLoginPath(
        runner: any CommandRunning, shell: String = ToolLocator.defaultLoginShell
    ) async -> [String] {
        let command = Command(executable: shell, arguments: ["-l", "-c", printPathScript], timeout: .seconds(3))
        guard let result = try? await runner.run(command),
            result.terminationReason == .exited, result.exitStatus == 0
        else { return fallbackSearchPath }

        let lastLine = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        var seen = Set<String>()
        let directories = lastLine.split(separator: ":").map(String.init).filter { entry in
            entry.hasPrefix("/") && seen.insert(entry).inserted
        }
        return directories.isEmpty ? fallbackSearchPath : directories
    }

    /// Returns `<dir>/<tool>` for the first directory where it is an executable regular file (symlinks followed for
    /// the check, the link path returned), or `nil`. Names containing `/` and relative directories are ignored.
    public func locate(_ tool: String) -> String? {
        guard !tool.isEmpty, tool != ".", tool != "..", !tool.contains("/") else { return nil }
        for directory in searchPath where directory.hasPrefix("/") {
            let candidate = (directory as NSString).appendingPathComponent(tool)
            var info = stat()
            guard stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 else {
                continue
            }
            return candidate
        }
        return nil
    }
}
