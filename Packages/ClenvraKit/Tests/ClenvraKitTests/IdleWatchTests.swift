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

    @Test("check intervals keep their whole seconds (the production interval is 15 s)")
    func intervalConversion() {
        #expect(IdleWatch.dispatchInterval(.seconds(15)) == .nanoseconds(15_000_000_000))
        #expect(IdleWatch.dispatchInterval(.milliseconds(1_500)) == .nanoseconds(1_500_000_000))
    }
}
