import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

@Suite("ProcessCommandRunner")
struct CommandRunnerTests {
    private let runner = ProcessCommandRunner()

    /// Writes an executable `/bin/sh` script into `directory` and returns its absolute path.
    private func makeScript(_ body: String, named name: String = "script.sh", in directory: TemporaryDirectory) throws
        -> String
    {
        let path = directory.url.appending(path: name).path(percentEncoded: false)
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(chmod(path, 0o755) == 0)
        return path
    }

    private func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private func readPid(at path: String) throws -> pid_t {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func waitForFile(_ path: String) async throws {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The script writes the file before sleeping; give the write a moment to land.
        try await Task.sleep(for: .milliseconds(50))
    }

    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    // MARK: Exit status and capture

    @Test("a successful command reports exit status 0 and its stdout")
    func exitZero() async throws {
        let result = try await runner.run(Command(executable: "/bin/echo", arguments: ["hello", "world"]))

        #expect(result.exitStatus == 0)
        #expect(result.terminationReason == .exited)
        #expect(result.standardOutput == "hello world\n")
        #expect(result.standardError.isEmpty)
        #expect(!result.outputTruncated)
    }

    @Test("a failing command reports its non-zero exit status")
    func exitNonZero() async throws {
        let result = try await runner.run(Command(executable: "/usr/bin/false"))

        #expect(result.exitStatus != 0)
        #expect(result.terminationReason == .exited)
    }

    @Test("a specific exit code and separate stdout/stderr are captured")
    func separateStreams() async throws {
        let result = try await runner.run(
            Command(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 7"]))

        #expect(result.exitStatus == 7)
        #expect(result.standardOutput == "out\n")
        #expect(result.standardError == "err\n")
    }

    @Test("a child killed by a signal reports .signaled")
    func signaled() async throws {
        let result = try await runner.run(Command(executable: "/bin/sh", arguments: ["-c", "kill -KILL $$"]))

        #expect(result.terminationReason == .signaled(SIGKILL))
    }

    // MARK: Argument fidelity

    @Test(
        "arguments reach the child verbatim, with no shell interpretation",
        arguments: ["two words", "it's \"quoted\"", "$HOME", "a; rm -rf /", "line1\nline2", "`id`", "*", ""])
    func argumentsVerbatim(argument: String) async throws {
        let directory = try TemporaryDirectory()
        let script = try makeScript(#"printf '%s' "$1""#, in: directory)

        let result = try await runner.run(Command(executable: script, arguments: [argument]))

        #expect(result.exitStatus == 0)
        #expect(result.standardOutput == argument)
    }

    // MARK: Validation before launch

    @Test("a relative executable is rejected before launch")
    func relativeRejected() async throws {
        await #expect(throws: CommandError.executableNotAbsolute("echo")) {
            try await runner.run(Command(executable: "echo"))
        }
        await #expect(throws: CommandError.executableNotAbsolute("bin/echo")) {
            try await runner.run(Command(executable: "bin/echo"))
        }
    }

    @Test("a missing executable is rejected before launch")
    func missingRejected() async throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.appending(path: "nope").path(percentEncoded: false)

        await #expect(throws: CommandError.executableNotFound(path)) {
            try await runner.run(Command(executable: path))
        }
    }

    @Test("a non-executable file or a directory is rejected before launch")
    func nonExecutableRejected() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.url.appending(path: "ran").path(percentEncoded: false)
        let script = try makeScript("touch '\(marker)'", in: directory)
        #expect(chmod(script, 0o644) == 0)

        await #expect(throws: CommandError.notExecutable(script)) {
            try await runner.run(Command(executable: script))
        }
        #expect(!FileManager.default.fileExists(atPath: marker))

        let folder = directory.url.path(percentEncoded: false)
        await #expect(throws: CommandError.notExecutable(folder)) {
            try await runner.run(Command(executable: folder))
        }
    }

    @Test("a relative working directory is rejected; an absolute one is used")
    func workingDirectory() async throws {
        await #expect(throws: CommandError.invalidWorkingDirectory("tmp")) {
            try await runner.run(Command(executable: "/bin/pwd", workingDirectory: "tmp"))
        }

        let directory = try TemporaryDirectory()
        let cwd = directory.url.path(percentEncoded: false)
        let result = try await runner.run(Command(executable: "/bin/pwd", workingDirectory: cwd))
        let expected = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        #expect(result.standardOutput == expected + "\n")
    }

    // MARK: Large output, cap and streaming

    @Test("5 MB on both streams does not deadlock; output is capped at the head", .timeLimit(.minutes(1)))
    func largeOutputBothStreams() async throws {
        let script = "head -c 5000000 /dev/zero | tr '\\0' 'o' & head -c 5000000 /dev/zero | tr '\\0' 'e' >&2; wait"
        let capped = ProcessCommandRunner(outputLimit: 1000)

        let result = try await capped.run(Command(executable: "/bin/sh", arguments: ["-c", script]))

        #expect(result.exitStatus == 0)
        #expect(result.outputTruncated)
        #expect(result.standardOutput == String(repeating: "o", count: 1000))
        #expect(result.standardError == String(repeating: "e", count: 1000))
    }

    @Test("the default cap is 1 MiB per stream")
    func defaultCap() async throws {
        let result = try await runner.run(
            Command(executable: "/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' 'x'"]))

        #expect(ProcessCommandRunner.defaultOutputLimit == 1 << 20)
        #expect(result.outputTruncated)
        #expect(result.standardOutput.utf8.count == 1 << 20)
    }

    @Test("output exactly at the cap is not marked truncated")
    func exactlyAtCap() async throws {
        let capped = ProcessCommandRunner(outputLimit: 6)

        let result = try await capped.run(Command(executable: "/bin/echo", arguments: ["hello"]))

        #expect(result.standardOutput == "hello\n")
        #expect(!result.outputTruncated)
    }

    @Test("onOutput receives every line in order for each stream, including a final unterminated line")
    func streamedLinesInOrder() async throws {
        let lines = Mutex<[OutputLine]>([])
        let script = "i=1; while [ $i -le 500 ]; do echo out$i; echo err$i >&2; i=$((i+1)); done; printf tail"

        let result = try await runner.run(Command(executable: "/bin/sh", arguments: ["-c", script])) { line in
            lines.withLock { $0.append(line) }
        }

        let received = lines.withLock { $0 }
        let out = received.filter { $0.stream == .standardOutput }.map(\.text)
        let err = received.filter { $0.stream == .standardError }.map(\.text)
        #expect(out == (1...500).map { "out\($0)" } + ["tail"])
        #expect(err == (1...500).map { "err\($0)" })
        #expect(result.standardOutput.hasSuffix("out500\ntail"))
    }

    @Test("lines keep streaming after the accumulated output is capped")
    func streamingContinuesPastCap() async throws {
        let count = Atomic<Int>(0)
        let capped = ProcessCommandRunner(outputLimit: 10)

        let script = "i=0; while [ $i -lt 100 ]; do echo line; i=$((i+1)); done"

        let result = try await capped.run(Command(executable: "/bin/sh", arguments: ["-c", script])) { _ in
            count.add(1, ordering: .relaxed)
        }

        #expect(result.outputTruncated)
        #expect(count.load(ordering: .relaxed) == 100)
    }

    @Test("invalid UTF-8 is decoded lossily rather than dropped")
    func lossyDecoding() async throws {
        let result = try await runner.run(Command(executable: "/usr/bin/printf", arguments: ["a\\377b"]))

        #expect(result.standardOutput == "a\u{FFFD}b")
    }

    // MARK: Timeout

    @Test("a command that outlives its timeout is stopped and reported as .timedOut", .timeLimit(.minutes(1)))
    func timeout() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await runner.run(Command(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(1)))

        #expect(result.terminationReason == .timedOut)
        #expect(clock.now - start < .seconds(4))
    }

    @Test("a child that ignores SIGTERM is killed with SIGKILL after the grace period", .timeLimit(.minutes(1)))
    func timeoutEscalatesToKill() async throws {
        let directory = try TemporaryDirectory()
        let pidFile = directory.url.appending(path: "pid").path(percentEncoded: false)
        let script = try makeScript("trap '' TERM\necho $$ > '\(pidFile)'\nsleep 60", in: directory)
        let clock = ContinuousClock()
        let start = clock.now

        // The timeout leaves the shell ample time to install its trap even on a loaded machine; a shorter one
        // let SIGTERM arrive before the trap existed, which made this test flaky.
        let result = try await runner.run(Command(executable: script, timeout: .seconds(3)))

        let elapsed = clock.now - start
        #expect(result.terminationReason == .timedOut)
        #expect(elapsed >= .seconds(3 + 5))
        #expect(elapsed < .seconds(3 + 6 + 3))
        #expect(!processExists(try readPid(at: pidFile)))
    }

    // MARK: Cancellation

    @Test("cancelling the calling task stops the child promptly and reports .cancelled", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        let directory = try TemporaryDirectory()
        let pidFile = directory.url.appending(path: "pid").path(percentEncoded: false)
        let childPidFile = directory.url.appending(path: "child").path(percentEncoded: false)
        let script = try makeScript(
            "echo $$ > '\(pidFile)'\nsleep 60 &\necho $! > '\(childPidFile)'\nwait", in: directory)
        let runner = self.runner

        let task = Task { try await runner.run(Command(executable: script)) }
        try await waitForFile(childPidFile)
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let result = try await task.value

        #expect(result.terminationReason == .cancelled)
        #expect(clock.now - start < .seconds(3))
        #expect(!processExists(try readPid(at: pidFile)))
        // The grandchild shares the process group, so it is signalled too.
        let grandchild = try readPid(at: childPidFile)
        for _ in 0..<50 where processExists(grandchild) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!processExists(grandchild))
    }

    @Test("a task cancelled before run never launches the command")
    func cancelledBeforeLaunch() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.url.appending(path: "ran").path(percentEncoded: false)
        let runner = self.runner

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(Command(executable: "/usr/bin/touch", arguments: [marker]))
        }
        let result = try await task.value

        #expect(result.terminationReason == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    // MARK: Environment

    @Test("the default environment is minimal and does not leak parent variables")
    func defaultEnvironment() async throws {
        setenv("CLENVRA_TEST_SENTINEL", "leaked", 1)
        defer { unsetenv("CLENVRA_TEST_SENTINEL") }

        let result = try await runner.run(Command(executable: "/usr/bin/env"))

        let variables = Dictionary(
            result.standardOutput.split(separator: "\n").compactMap { line -> (String, String)? in
                guard let equals = line.firstIndex(of: "=") else { return nil }
                return (String(line[..<equals]), String(line[line.index(after: equals)...]))
            },
            uniquingKeysWith: { first, _ in first })
        #expect(variables["CLENVRA_TEST_SENTINEL"] == nil)
        #expect(variables["HOME"]?.isEmpty == false)
        #expect(variables["USER"]?.isEmpty == false)
        #expect(variables["LANG"] == "en_US.UTF-8")
        #expect(variables["PATH"] == "/usr/bin:/bin")
        #expect(Set(variables.keys) == ["HOME", "USER", "LANG", "PATH"])
    }

    @Test("the default PATH starts with the tool's own directory")
    func defaultPathIncludesToolDirectory() async throws {
        let directory = try TemporaryDirectory()
        let script = try makeScript(#"printf '%s' "$PATH""#, in: directory)

        let result = try await runner.run(Command(executable: script))

        let toolDirectory = (script as NSString).deletingLastPathComponent
        #expect(result.standardOutput == "\(toolDirectory):/usr/bin:/bin")
    }

    @Test("an explicit environment replaces the default one")
    func explicitEnvironment() async throws {
        let result = try await runner.run(
            Command(executable: "/usr/bin/env", environment: ["ONLY": "this"]))

        #expect(result.standardOutput == "ONLY=this\n")
    }

    // MARK: Resource hygiene

    @Test("running commands does not leak file descriptors")
    func noDescriptorLeak() async throws {
        _ = try await runner.run(Command(executable: "/usr/bin/true"))
        let before = try openDescriptorCount()

        for _ in 0..<100 {
            _ = try await runner.run(Command(executable: "/bin/echo", arguments: ["x"]))
        }

        // Other tests run in parallel and open descriptors too; allow jitter, but not 100+ leaked pipe ends.
        #expect(try openDescriptorCount() - before < 40)
    }

    @Test("the command's default timeout is 60 seconds")
    func defaultTimeout() {
        #expect(Command(executable: "/usr/bin/true").timeout == .seconds(60))
    }
}
