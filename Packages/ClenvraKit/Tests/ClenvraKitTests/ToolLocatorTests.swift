import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

@Suite("ToolLocator")
struct ToolLocatorTests {
    /// Returns a canned result (or error) and records the command it was asked to run.
    private final class FakeRunner: CommandRunning {
        let outcome: Result<CommandResult, CommandError>
        let received = Mutex<[Command]>([])

        init(outcome: Result<CommandResult, CommandError>) {
            self.outcome = outcome
        }

        func run(_ command: Command, onOutput: (@Sendable (OutputLine) -> Void)?) async throws -> CommandResult {
            received.withLock { $0.append(command) }
            return try outcome.get()
        }
    }

    private static func result(
        stdout: String, status: Int32 = 0, reason: TerminationReason = .exited
    ) -> CommandResult {
        CommandResult(
            exitStatus: status, terminationReason: reason, standardOutput: stdout, standardError: "",
            outputTruncated: false, duration: .milliseconds(5))
    }

    private func makeDirectory(_ name: String, in root: TemporaryDirectory) throws -> String {
        let url = root.url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path(percentEncoded: false)
    }

    private func makeFile(_ name: String, in directory: String, mode: mode_t) throws -> String {
        let path = (directory as NSString).appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8)))
        #expect(chmod(path, mode) == 0)
        return path
    }

    // MARK: locate

    @Test("locate returns the executable from the first directory in search order")
    func firstMatchWins() throws {
        let root = try TemporaryDirectory()
        let first = try makeDirectory("first", in: root)
        let second = try makeDirectory("second", in: root)
        let expected = try makeFile("pnpm", in: first, mode: 0o755)
        _ = try makeFile("pnpm", in: second, mode: 0o755)

        #expect(ToolLocator(searchPath: [first, second]).locate("pnpm") == expected)
        #expect(
            ToolLocator(searchPath: [second, first]).locate("pnpm")
                == (second as NSString).appendingPathComponent("pnpm"))
    }

    @Test("locate skips non-executable files and directories with the tool's name")
    func skipsNonExecutables() throws {
        let root = try TemporaryDirectory()
        let plain = try makeDirectory("plain", in: root)
        let folder = try makeDirectory("folder", in: root)
        let good = try makeDirectory("good", in: root)
        _ = try makeFile("npm", in: plain, mode: 0o644)
        try FileManager.default.createDirectory(
            atPath: (folder as NSString).appendingPathComponent("npm"), withIntermediateDirectories: false)
        let expected = try makeFile("npm", in: good, mode: 0o755)

        #expect(ToolLocator(searchPath: [plain, folder, good]).locate("npm") == expected)
        #expect(ToolLocator(searchPath: [plain, folder]).locate("npm") == nil)
    }

    @Test("locate follows symlinks for the executability check and returns the link path")
    func followsSymlinks() throws {
        let root = try TemporaryDirectory()
        let cellar = try makeDirectory("Cellar", in: root)
        let bin = try makeDirectory("bin", in: root)
        let target = try makeFile("brew-real", in: cellar, mode: 0o755)
        let link = (bin as NSString).appendingPathComponent("brew")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let plainTarget = try makeFile("data", in: cellar, mode: 0o644)
        try FileManager.default.createSymbolicLink(
            atPath: (bin as NSString).appendingPathComponent("data"), withDestinationPath: plainTarget)
        try FileManager.default.createSymbolicLink(
            atPath: (bin as NSString).appendingPathComponent("dangling"), withDestinationPath: "/nonexistent/x")

        let locator = ToolLocator(searchPath: [bin])
        #expect(locator.locate("brew") == link)
        #expect(locator.locate("data") == nil)
        #expect(locator.locate("dangling") == nil)
    }

    @Test(
        "locate rejects names containing a slash, empty names and dot names",
        arguments: ["", ".", "..", "a/b", "/bin/sh", "../sh"])
    func rejectsBadNames(name: String) {
        #expect(ToolLocator(searchPath: ["/bin", "/usr/bin"]).locate(name) == nil)
    }

    @Test("locate ignores relative search directories")
    func ignoresRelativeDirectories() {
        #expect(ToolLocator(searchPath: ["bin", "."]).locate("sh") == nil)
        #expect(ToolLocator(searchPath: ["bin", "/bin"]).locate("sh") == "/bin/sh")
    }

    @Test("searchPath is kept in the given order")
    func keepsSearchPath() {
        #expect(ToolLocator(searchPath: ["/b", "/a"]).searchPath == ["/b", "/a"])
    }

    // MARK: fallback

    @Test("the fallback search path lists standard tool directories with ~ expanded")
    func fallbackSearchPath() {
        let home = NSHomeDirectory()
        #expect(
            ToolLocator.fallbackSearchPath == [
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                home + "/.local/bin", home + "/.volta/bin", home + "/.bun/bin",
            ])
    }

    // MARK: resolveLoginPath

    @Test("resolveLoginPath runs the login shell with a constant command and a 3 s timeout")
    func loginShellCommand() async {
        let runner = FakeRunner(outcome: .success(Self.result(stdout: "/usr/bin")))

        _ = await ToolLocator.resolveLoginPath(runner: runner, shell: "/bin/zsh")

        let commands = runner.received.withLock { $0 }
        #expect(commands.count == 1)
        #expect(commands.first?.executable == "/bin/zsh")
        #expect(commands.first?.arguments == ["-l", "-c", #"printf %s "$PATH""#])
        #expect(commands.first?.timeout == .seconds(3))
    }

    @Test("resolveLoginPath splits on ':', drops empty and relative entries and dedupes in order")
    func parsesPath() async {
        let stdout = "/opt/homebrew/bin::/usr/bin:/opt/homebrew/bin:.:relative/bin:/Users/x/.volta/bin:/usr/bin:"
        let runner = FakeRunner(outcome: .success(Self.result(stdout: stdout)))

        let path = await ToolLocator.resolveLoginPath(runner: runner, shell: "/bin/zsh")

        #expect(path == ["/opt/homebrew/bin", "/usr/bin", "/Users/x/.volta/bin"])
    }

    @Test("resolveLoginPath ignores noise printed by shell startup files before the PATH")
    func ignoresStartupNoise() async {
        let runner = FakeRunner(outcome: .success(Self.result(stdout: "Welcome!\nmotd line\n/a/bin:/b/bin")))

        #expect(await ToolLocator.resolveLoginPath(runner: runner, shell: "/bin/zsh") == ["/a/bin", "/b/bin"])
    }

    @Test(
        "resolveLoginPath falls back to the standard directories when the shell fails",
        arguments: [
            Result<CommandResult, CommandError>.success(result(stdout: "/a/bin", status: 1)),
            .success(result(stdout: "/a/bin", status: -1, reason: .timedOut)),
            .success(result(stdout: "/a/bin", status: -1, reason: .signaled(SIGKILL))),
            .success(result(stdout: "")),
            .success(result(stdout: "::relative")),
            .failure(.executableNotFound("/bin/zsh")),
        ])
    func fallsBack(outcome: Result<CommandResult, CommandError>) async {
        let runner = FakeRunner(outcome: outcome)

        #expect(await ToolLocator.resolveLoginPath(runner: runner, shell: "/bin/zsh") == ToolLocator.fallbackSearchPath)
    }

    @Test("resolveLoginPath works end to end with the real runner and /bin/sh")
    func realShell() async {
        let path = await ToolLocator.resolveLoginPath(runner: ProcessCommandRunner(), shell: "/bin/sh")

        #expect(!path.isEmpty)
        #expect(path.allSatisfy { $0.hasPrefix("/") })
        #expect(path.contains("/usr/bin"))
    }

    @Test("the default login shell is an absolute path")
    func defaultShell() {
        #expect(ToolLocator.defaultLoginShell.hasPrefix("/"))
    }
}
