import Dispatch
import Synchronization

/// Ends the privileged helper once no request has arrived for `idleLimit`, so it never stays resident as root.
public final class IdleWatch: Sendable {
    private let lastActivity = Mutex(ContinuousClock.now)
    private let busy = Mutex(0)
    private let idleLimit: Duration
    private let checkInterval: Duration
    private let onIdle: @Sendable () -> Void
    /// Held for the helper's lifetime: GCD cancels a timer source once nothing references it, and the helper would
    /// then never exit.
    private let timer = DispatchSource.makeTimerSource(queue: .global())

    public init(
        idleLimit: Duration = .seconds(60), checkInterval: Duration = .seconds(15),
        onIdle: @escaping @Sendable () -> Void
    ) {
        self.idleLimit = idleLimit
        self.checkInterval = checkInterval
        self.onIdle = onIdle
    }

    public func begin() {
        busy.withLock { $0 += 1 }
        lastActivity.withLock { $0 = .now }
    }

    public func end() {
        busy.withLock { $0 -= 1 }
        lastActivity.withLock { $0 = .now }
    }

    public func start() {
        let (seconds, attoseconds) = checkInterval.components
        let interval = DispatchTimeInterval.nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [self] in
            let idle = busy.withLock { $0 } == 0 && ContinuousClock.now - lastActivity.withLock { $0 } > idleLimit
            if idle { onIdle() }
        }
        timer.resume()
    }
}
