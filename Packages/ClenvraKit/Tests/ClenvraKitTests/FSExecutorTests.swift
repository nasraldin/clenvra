import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

@Suite("FSExecutor")
struct FSExecutorTests {
    private struct Boom: Error, Equatable {}

    @Test("work runs on a named executor thread, not the cooperative pool")
    func runsOnNamedThread() async throws {
        let executor = FSExecutor(width: 2)

        let name = try await executor.run { Thread.current.name ?? "" }

        #expect(name.hasPrefix(FSExecutor.threadNamePrefix))
    }

    @Test("the shared executor uses named threads too")
    func sharedRunsOnNamedThread() async throws {
        let name = try await FSExecutor.shared.run { Thread.current.name ?? "" }

        #expect(name.hasPrefix(FSExecutor.threadNamePrefix))
        #expect(FSExecutor.shared.width == min(ProcessInfo.processInfo.activeProcessorCount, 8))
    }

    @Test("a width below one is clamped to one thread")
    func widthIsClamped() {
        #expect(FSExecutor(width: 0).width == 1)
    }

    @Test("with width N, at most N jobs run concurrently", .timeLimit(.minutes(1)))
    func boundedConcurrency() async throws {
        let width = 3
        let executor = FSExecutor(width: width)
        let running = Atomic<Int>(0)
        let maxSeen = Atomic<Int>(0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<(4 * width) {
                group.addTask {
                    try await executor.run {
                        let now = running.add(1, ordering: .sequentiallyConsistent).newValue
                        maxSeen.max(now, ordering: .sequentiallyConsistent)
                        usleep(20_000)
                        running.subtract(1, ordering: .sequentiallyConsistent)
                    }
                }
            }
            try await group.waitForAll()
        }

        let observed = maxSeen.load(ordering: .sequentiallyConsistent)
        #expect(observed >= 1)
        #expect(observed <= width)
    }

    @Test("results propagate to the caller")
    func resultPropagates() async throws {
        let executor = FSExecutor(width: 1)

        let value = try await executor.run { 6 * 7 }

        #expect(value == 42)
    }

    @Test("thrown errors propagate to the caller")
    func errorPropagates() async {
        let executor = FSExecutor(width: 1)

        await #expect(throws: Boom.self) {
            try await executor.run { () throws -> Int in throw Boom() }
        }
    }

    @Test("an already-cancelled task gets CancellationError and the work never runs")
    func cancelledBeforeStart() async {
        let executor = FSExecutor(width: 1)
        let ran = Atomic<Bool>(false)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.run { ran.store(true, ordering: .sequentiallyConsistent) }
        }
        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ran.load(ordering: .sequentiallyConsistent) == false)
    }

    @Test("1,000 small jobs all complete", .timeLimit(.minutes(1)))
    func manyJobsComplete() async throws {
        let executor = FSExecutor(width: 4)
        let count = 1_000

        let sum = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<count {
                group.addTask { try await executor.run { index } }
            }
            return try await group.reduce(0, +)
        }

        #expect(sum == count * (count - 1) / 2)
    }

    @Test("nested run calls complete without deadlock on a width-1 pool", .timeLimit(.minutes(1)))
    func nestedRunDoesNotDeadlock() async throws {
        let executor = FSExecutor(width: 1)

        let value = try await withTaskExecutorPreference(executor) {
            let outer = try await executor.run { 1 }
            let inner = try await withTaskExecutorPreference(executor) {
                try await executor.run { 2 }
            }
            return try await outer + inner + executor.run { 3 }
        }

        #expect(value == 6)
    }

    @Test("many nested runs in parallel complete on a width-1 pool", .timeLimit(.minutes(1)))
    func parallelNestedRunsComplete() async throws {
        let executor = FSExecutor(width: 1)

        let sum = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try await withTaskExecutorPreference(executor) {
                        let first = try await executor.run { index }
                        let second = try await executor.run { first + 1 }
                        return second
                    }
                }
            }
            return try await group.reduce(0, +)
        }

        #expect(sum == (0..<100).reduce(0, +) + 100)
    }
}
