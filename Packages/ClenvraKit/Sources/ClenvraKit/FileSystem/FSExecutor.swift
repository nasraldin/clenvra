import Dispatch
import Foundation
import Synchronization

/// Runs blocking filesystem syscalls on a small set of dedicated threads so they never starve Swift's cooperative pool.
///
/// Workers are created once and live for the process lifetime; idle workers sleep on a semaphore.
/// `run` is async, so nested calls (from an async context that prefers this executor) suspend instead of
/// holding a worker and cannot deadlock the pool. Work closures must not *block* waiting on other jobs
/// submitted to the same executor.
public final class FSExecutor: TaskExecutor, Sendable {
    /// Prefix of every worker thread's name, so tests and Instruments can tell executor threads apart.
    public static let threadNamePrefix = "clenvra.fs."

    /// App-wide executor for blocking filesystem work, sized to the machine but capped to limit disk contention.
    public static let shared = FSExecutor(width: min(ProcessInfo.processInfo.activeProcessorCount, 8))

    /// Number of worker threads, which is the maximum number of jobs running at once.
    public let width: Int

    private let pending = Mutex(JobQueue())
    private let available = DispatchSemaphore(value: 0)

    /// Creates `width` worker threads (at least one) running at utility QoS, because scans are user-visible but not urgent.
    public init(width: Int) {
        self.width = max(1, width)
        for index in 0..<self.width {
            let thread = Thread { [self] in workLoop() }
            thread.name = "\(Self.threadNamePrefix)\(index)"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        pending.withLock { $0.push(unowned) }
        available.signal()
    }

    /// Moves blocking work off the cooperative pool while letting the caller stay async and cancellable.
    public func run<T: Sendable>(_ work: @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withTaskExecutorPreference(self) { () async throws -> T in
            try Task.checkCancellation()
            return try work()
        }
    }

    private func workLoop() {
        let executor = asUnownedTaskExecutor()
        while true {
            available.wait()
            let job = pending.withLock { $0.pop() }
            job?.runSynchronously(on: executor)
        }
    }
}

/// FIFO of submitted jobs with O(1) amortised push and pop.
private struct JobQueue: Sendable {
    private var items: [UnownedJob] = []
    private var head = 0

    mutating func push(_ job: UnownedJob) {
        items.append(job)
    }

    mutating func pop() -> UnownedJob? {
        guard head < items.count else { return nil }
        let job = items[head]
        head += 1
        if head == items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= items.count {
            items.removeFirst(head)
            head = 0
        }
        return job
    }
}
