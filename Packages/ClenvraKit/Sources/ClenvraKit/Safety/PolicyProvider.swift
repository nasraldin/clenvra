import Synchronization

/// The app's current protection policy, readable from any thread. Updated when the user changes exclusions,
/// so every deletion gate applies the latest rules at deletion time, not the rules from when it was created.
public final class PolicyProvider: Sendable {
    private let policy: Mutex<ProtectionPolicy>

    public init(_ policy: ProtectionPolicy) {
        self.policy = Mutex(policy)
    }

    public var current: ProtectionPolicy { policy.withLock { $0 } }

    public func update(_ newPolicy: ProtectionPolicy) {
        policy.withLock { $0 = newPolicy }
    }
}
