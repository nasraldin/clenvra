import Darwin
import Foundation
import Synchronization

/// A tool invocation with an absolute executable and fixed argv, so nothing is ever interpreted by a shell.
public struct Command: Sendable, Hashable {
    /// Absolute path of the program; relative paths are rejected so `PATH` lookup can never pick a different binary.
    public let executable: String
    /// Passed verbatim as argv; spaces, quotes and `$` reach the child unchanged.
    public let arguments: [String]
    /// The child's whole environment; `nil` gives a minimal one so the app's variables do not leak into tools.
    public var environment: [String: String]?
    /// How long the command may run before it is terminated, so a hung tool cannot block cleanup forever.
    public var timeout: Duration
    /// Absolute directory the child starts in; `nil` inherits the app's.
    public var workingDirectory: String?

    /// Defaults to the minimal environment and a 60 s timeout, which suits every probe and cleanup command.
    public init(
        executable: String, arguments: [String] = [], environment: [String: String]? = nil,
        timeout: Duration = .seconds(60), workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.workingDirectory = workingDirectory
    }
}

/// Why a command ended, so callers can tell a tool's own failure from Clenvra stopping it.
public enum TerminationReason: Sendable, Hashable {
    /// The process called `exit`; see `CommandResult.exitStatus`.
    case exited
    /// The process was killed by this signal without Clenvra asking.
    case signaled(Int32)
    /// Clenvra stopped it because `Command.timeout` elapsed.
    case timedOut
    /// Clenvra stopped it because the calling task was cancelled.
    case cancelled
}

/// What a finished command produced, kept small enough to log and show in the UI.
public struct CommandResult: Sendable, Equatable {
    /// The exit code when `terminationReason` is `.exited`; otherwise -1.
    public let exitStatus: Int32
    /// How the process ended.
    public let terminationReason: TerminationReason
    /// Lossy UTF-8 of the first `outputLimit` bytes of stdout.
    public let standardOutput: String
    /// Lossy UTF-8 of the first `outputLimit` bytes of stderr.
    public let standardError: String
    /// True when either stream produced more than `outputLimit` bytes and was cut.
    public let outputTruncated: Bool
    /// Wall-clock time from launch to completion, for the activity log.
    public let duration: Duration

    /// Memberwise, so test doubles of `CommandRunning` can build results.
    public init(
        exitStatus: Int32, terminationReason: TerminationReason, standardOutput: String, standardError: String,
        outputTruncated: Bool, duration: Duration
    ) {
        self.exitStatus = exitStatus
        self.terminationReason = terminationReason
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputTruncated = outputTruncated
        self.duration = duration
    }
}

/// One line of live output, so the UI can show a log while a tool runs.
public struct OutputLine: Sendable, Equatable {
    /// Which pipe the line came from, so stderr can be styled differently.
    public enum Stream: Sendable, Hashable {
        case standardOutput
        case standardError
    }

    /// The pipe the line came from.
    public let stream: Stream
    /// The line without its trailing newline, decoded as lossy UTF-8.
    public let text: String

    /// Memberwise, so test doubles can emit lines.
    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// Why a command was refused before launch, so nothing unexpected is ever executed.
public enum CommandError: Error, Sendable, Equatable {
    /// The executable path does not start with `/`.
    case executableNotAbsolute(String)
    /// Nothing exists at the executable path.
    case executableNotFound(String)
    /// The path exists but is not an executable regular file.
    case notExecutable(String)
    /// The working directory is not an absolute path.
    case invalidWorkingDirectory(String)
    /// The system refused to start the process.
    case launchFailed(String)
}

/// Runs developer-tool commands, abstracted so adapters can be tested without launching real tools.
public protocol CommandRunning: Sendable {
    /// Runs `command` to completion, streaming lines to `onOutput` (on an arbitrary thread) as they arrive.
    /// Cancellation of the calling task stops the child and returns a `.cancelled` result instead of throwing.
    @concurrent func run(_ command: Command, onOutput: (@Sendable (OutputLine) -> Void)?) async throws -> CommandResult
}

extension CommandRunning {
    /// Convenience for probes that only need the final result.
    @concurrent public func run(_ command: Command) async throws -> CommandResult {
        try await run(command, onOutput: nil)
    }
}

/// Runs commands with `Foundation.Process`, without a shell, with bounded output and reliable termination.
///
/// The child is its own process-group leader (Foundation's `Process` does this on macOS), so stop signals go to
/// the whole group and reach the tool's own children. Descendants that call `setsid` leave the group and are not
/// signalled; if they keep the output pipes open, the runner stops waiting for them shortly after the child exits.
public struct ProcessCommandRunner: CommandRunning {
    /// Per-stream cap on accumulated output, large enough for any probe's JSON yet bounded for chatty tools.
    public static let defaultOutputLimit = 1 << 20

    /// Bytes kept per stream; extra output is still streamed to `onOutput` but not accumulated.
    public let outputLimit: Int

    /// `outputLimit` is configurable so callers that only need a status can keep less.
    public init(outputLimit: Int = ProcessCommandRunner.defaultOutputLimit) {
        self.outputLimit = max(0, outputLimit)
    }

    @concurrent public func run(_ command: Command, onOutput: (@Sendable (OutputLine) -> Void)?) async throws
        -> CommandResult
    {
        try Self.validate(command)
        if Task.isCancelled {
            return CommandResult(
                exitStatus: -1, terminationReason: .cancelled, standardOutput: "", standardError: "",
                outputTruncated: false, duration: .zero)
        }

        let process = Process()
        process.executableURL = URL(filePath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment ?? Self.minimalEnvironment(for: command.executable)
        if let directory = command.workingDirectory {
            process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let session = RunSession(
            outHandle: outPipe.fileHandleForReading, errHandle: errPipe.fileHandleForReading,
            limit: outputLimit, onOutput: onOutput)

        let result = try await withTaskCancellationHandler { @concurrent in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, any Error>) in
                session.begin(continuation)
                process.terminationHandler = { finished in
                    session.processExited(
                        status: finished.terminationStatus,
                        signaled: finished.terminationReason == .uncaughtSignal)
                }
                do {
                    try process.run()
                } catch {
                    session.launchFailed(CommandError.launchFailed(error.localizedDescription))
                    return
                }
                session.launched(pid: process.processIdentifier, timeout: command.timeout)
            }
        } onCancel: {
            session.stop(.cancelled)
        }
        withExtendedLifetime(process) {}
        return result
    }

    private static func validate(_ command: Command) throws {
        let path = command.executable
        guard path.hasPrefix("/") else { throw CommandError.executableNotAbsolute(path) }
        var info = stat()
        guard stat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw CommandError.executableNotFound(path) }
            throw CommandError.notExecutable(path)
        }
        guard info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 else {
            throw CommandError.notExecutable(path)
        }
        if let directory = command.workingDirectory, !directory.hasPrefix("/") {
            throw CommandError.invalidWorkingDirectory(directory)
        }
    }

    private static func minimalEnvironment(for executable: String) -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let toolDirectory = (executable as NSString).deletingLastPathComponent
        var path = ["/usr/bin", "/bin"]
        if !path.contains(toolDirectory) { path.insert(toolDirectory, at: 0) }
        return [
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "USER": environment["USER"] ?? NSUserName(),
            "PATH": path.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            // Clenvra makes no network calls; these stop tools from checking online for their own updates.
            "NO_UPDATE_NOTIFIER": "1",
            "npm_config_update_notifier": "false",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
        ]
    }
}

/// Head-capped capture plus line splitting for one pipe.
private struct StreamBuffer {
    /// A partial line longer than this is emitted as-is so a newline-free stream cannot grow memory unboundedly.
    static let maxLineLength = 64 * 1024

    var captured = Data()
    var truncated = false
    var pending = Data()
    var done = false

    mutating func append(_ chunk: Data, limit: Int) -> [String] {
        let room = max(0, limit - captured.count)
        if room > 0 { captured.append(chunk.prefix(room)) }
        if chunk.count > room { truncated = true }

        pending.append(chunk)
        var lines: [String] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[start..<newline], as: UTF8.self))
            start = pending.index(after: newline)
        }
        pending = Data(pending[start...])
        if pending.count > Self.maxLineLength {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending = Data()
        }
        return lines
    }

    mutating func finish() -> [String] {
        done = true
        defer { pending = Data() }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}

/// Shared mutable state of one run, touched from pipe handlers, the termination handler, timers and cancellation.
private struct RunState {
    var continuation: CheckedContinuation<CommandResult, any Error>?
    var pid: pid_t?
    var exit: (status: Int32, signaled: Bool)?
    var stopReason: TerminationReason?
    var stdout = StreamBuffer()
    var stderr = StreamBuffer()
    var timers: [Task<Void, Never>] = []
    var finished = false

    subscript(stream: OutputLine.Stream) -> StreamBuffer {
        get { stream == .standardOutput ? stdout : stderr }
        set {
            if stream == .standardOutput { stdout = newValue } else { stderr = newValue }
        }
    }
}

private final class RunSession: Sendable {
    /// Time between SIGTERM and SIGKILL, so well-behaved tools can clean up.
    static let killGracePeriod = Duration.seconds(5)
    /// How long to wait for pipe EOF after the child exits, in case an escaped descendant holds the pipes open.
    static let drainGracePeriod = Duration.seconds(2)

    private let state = Mutex(RunState())
    private let outHandle: FileHandle
    private let errHandle: FileHandle
    private let limit: Int
    private let onOutput: (@Sendable (OutputLine) -> Void)?
    private let start = ContinuousClock.now

    init(outHandle: FileHandle, errHandle: FileHandle, limit: Int, onOutput: (@Sendable (OutputLine) -> Void)?) {
        self.outHandle = outHandle
        self.errHandle = errHandle
        self.limit = limit
        self.onOutput = onOutput
    }

    func begin(_ continuation: CheckedContinuation<CommandResult, any Error>) {
        state.withLock { $0.continuation = continuation }
        install(outHandle, stream: .standardOutput)
        install(errHandle, stream: .standardError)
    }

    func launchFailed(_ error: CommandError) {
        for handle in [outHandle, errHandle] {
            handle.readabilityHandler = nil
            try? handle.close()
        }
        let continuation = state.withLock { state in
            state.finished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: error)
    }

    /// Records the pid, applies a stop requested before launch, and arms the timeout.
    func launched(pid: pid_t, timeout: Duration) {
        let stoppedEarly = state.withLock { state -> Bool in
            state.pid = pid
            guard state.stopReason != nil, state.exit == nil else { return false }
            Self.signalGroup(pid, SIGTERM)
            return true
        }
        if stoppedEarly { scheduleKill() }
        addTimer(after: timeout) { $0.stop(.timedOut) }
    }

    /// Sends SIGTERM to the child's process group, then SIGKILL after the grace period if it is still running.
    func stop(_ reason: TerminationReason) {
        let signalled = state.withLock { state -> Bool in
            guard !state.finished, state.exit == nil, state.stopReason == nil else { return false }
            state.stopReason = reason
            guard let pid = state.pid else { return false }
            Self.signalGroup(pid, SIGTERM)
            return true
        }
        if signalled { scheduleKill() }
    }

    func processExited(status: Int32, signaled: Bool) {
        let pipesOpen = state.withLock { state -> Bool in
            state.exit = (status, signaled)
            return !(state.stdout.done && state.stderr.done)
        }
        if pipesOpen { addTimer(after: Self.drainGracePeriod) { $0.abandonPipes() } }
        finishIfComplete()
    }

    private func scheduleKill() {
        addTimer(after: Self.killGracePeriod) { session in
            session.state.withLock { state in
                if !state.finished, state.exit == nil, let pid = state.pid { Self.signalGroup(pid, SIGKILL) }
            }
        }
    }

    /// Runs `action` after `delay` unless the run finishes first; timers are cancelled on completion.
    private func addTimer(after delay: Duration, _ action: @escaping @Sendable (RunSession) -> Void) {
        let timer = Task { @concurrent [self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            action(self)
        }
        let alreadyFinished = state.withLock { state -> Bool in
            if !state.finished { state.timers.append(timer) }
            return state.finished
        }
        if alreadyFinished { timer.cancel() }
    }

    private func install(_ handle: FileHandle, stream: OutputLine.Stream) {
        let descriptor = handle.fileDescriptor
        handle.readabilityHandler = { [self] readable in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            let lines: [String]
            if count > 0 {
                lines = state.withLock { state in
                    state[stream].done ? [] : state[stream].append(Data(buffer[0..<count]), limit: limit)
                }
            } else {
                readable.readabilityHandler = nil
                try? readable.close()
                lines = state.withLock { state in state[stream].done ? [] : state[stream].finish() }
            }
            emit(lines, stream: stream)
            if count <= 0 { finishIfComplete() }
        }
    }

    /// Stops waiting for EOF on pipes an escaped descendant still holds; the descriptors close when the pipes are released.
    private func abandonPipes() {
        let (out, err) = state.withLock { state in
            (state.stdout.done ? nil : state.stdout.finish(), state.stderr.done ? nil : state.stderr.finish())
        }
        if let out {
            outHandle.readabilityHandler = nil
            emit(out, stream: .standardOutput)
        }
        if let err {
            errHandle.readabilityHandler = nil
            emit(err, stream: .standardError)
        }
        finishIfComplete()
    }

    private func emit(_ lines: [String], stream: OutputLine.Stream) {
        guard let onOutput else { return }
        for line in lines { onOutput(OutputLine(stream: stream, text: line)) }
    }

    private func finishIfComplete() {
        let duration = ContinuousClock.now - start
        let completion = state.withLock { state -> (CheckedContinuation<CommandResult, any Error>, CommandResult)? in
            guard !state.finished, let exit = state.exit, state.stdout.done, state.stderr.done,
                let continuation = state.continuation
            else { return nil }
            state.finished = true
            state.continuation = nil
            for timer in state.timers { timer.cancel() }
            state.timers = []
            let reason = state.stopReason ?? (exit.signaled ? .signaled(exit.status) : .exited)
            let result = CommandResult(
                exitStatus: exit.signaled ? -1 : exit.status,
                terminationReason: reason,
                standardOutput: String(decoding: state.stdout.captured, as: UTF8.self),
                standardError: String(decoding: state.stderr.captured, as: UTF8.self),
                outputTruncated: state.stdout.truncated || state.stderr.truncated,
                duration: duration)
            return (continuation, result)
        }
        guard let (continuation, result) = completion else { return }
        continuation.resume(returning: result)
    }

    private static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        if kill(-pid, signal) != 0 { kill(pid, signal) }
    }
}
