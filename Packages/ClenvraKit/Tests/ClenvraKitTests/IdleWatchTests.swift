import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

/// The privileged helper must not stay resident: it exits once no request has arrived for a while.
@Suite("Helper idle exit")
struct IdleWatchTests {
    @Test("with no requests, the idle action runs once the limit has passed")
    func firesWhenIdle() async throws {
        let fired = Mutex(false)
        let watch = IdleWatch(idleLimit: .milliseconds(100), checkInterval: .milliseconds(20)) {
            fired.withLock { $0 = true }
        }
        watch.start()
        // Polls instead of one fixed wait: the full suite runs in parallel and can delay the timer's queue.
        for _ in 0..<100 where !fired.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fired.withLock { $0 })
    }

    @Test("while a request is running, the idle action does not run")
    func staysWhileBusy() async throws {
        let fired = Mutex(false)
        let watch = IdleWatch(idleLimit: .milliseconds(100), checkInterval: .milliseconds(20)) {
            fired.withLock { $0 = true }
        }
        watch.begin()
        watch.start()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!fired.withLock { $0 })
        watch.end()
    }

    @Test("a whole-second check interval is honored (the production interval is 15 s)")
    func wholeSecondInterval() async throws {
        let fired = Mutex(false)
        let watch = IdleWatch(idleLimit: .zero, checkInterval: .seconds(1)) { fired.withLock { $0 = true } }
        watch.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!fired.withLock { $0 }, "checked before the first interval elapsed")
        for _ in 0..<100 where !fired.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fired.withLock { $0 })
    }
}
