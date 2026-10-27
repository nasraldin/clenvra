import Foundation
import Synchronization

@testable import ClenvraKit

/// Scripted `CommandRunning`: answers by exact executable + argv, records every command, and throws
/// `executableNotFound` for anything not scripted so adapters' failure paths are exercised too.
final class FakeCommandRunner: CommandRunning {
    private struct Key: Hashable {
        let executable: String
        let arguments: [String]
    }

    private struct Script {
        let result: CommandResult
        let lines: [OutputLine]
    }

    private let scripts = Mutex<[Key: Script]>([:])
    private let calls = Mutex<[Command]>([])

    /// Every command run so far, in order.
    var commands: [Command] { calls.withLock { $0 } }

    func stub(
        _ executable: String, _ arguments: [String], stdout: String = "", stderr: String = "", status: Int32 = 0,
        reason: TerminationReason = .exited, lines: [OutputLine] = []
    ) {
        let result = CommandResult(
            exitStatus: status, terminationReason: reason, standardOutput: stdout, standardError: stderr,
            outputTruncated: false, duration: .milliseconds(3))
        scripts.withLock {
            $0[Key(executable: executable, arguments: arguments)] = Script(result: result, lines: lines)
        }
    }

    func run(_ command: Command, onOutput: (@Sendable (OutputLine) -> Void)?) async throws -> CommandResult {
        calls.withLock { $0.append(command) }
        let script = scripts.withLock { $0[Key(executable: command.executable, arguments: command.arguments)] }
        guard let script else { throw CommandError.executableNotFound(command.executable) }
        for line in script.lines { onOutput?(line) }
        return script.result
    }
}
