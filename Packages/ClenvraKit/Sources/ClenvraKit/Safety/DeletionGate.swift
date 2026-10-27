import Darwin
import Foundation

/// Whether the app that owns an item is running. `unknown` is treated exactly like `running`.
public enum OwnerState: Sendable, Equatable {
    case running
    case notRunning
    case unknown
}

/// One item the user reviewed and confirmed, exactly as the scanner saw it.
public struct DeletionItem: Sendable, Equatable {
    /// Canonical absolute path.
    public let path: String
    /// The folder the producing rule is allowed to clean inside of; the item must be strictly below it.
    public let ruleRoot: String
    /// The item as it was when the user reviewed it.
    public let expected: FileSnapshot
    /// Bundle identifier of the app that owns this item, when ownership matters (caches of running apps).
    public let ownerBundleID: String?
    /// Bytes expected to be freed (shown and logged; not used for decisions).
    public let freedBytes: Int64
    public let section: ActivityRecord.Section

    public init(
        path: String, ruleRoot: String, expected: FileSnapshot, ownerBundleID: String?, freedBytes: Int64,
        section: ActivityRecord.Section
    ) {
        self.path = path
        self.ruleRoot = ruleRoot
        self.expected = expected
        self.ownerBundleID = ownerBundleID
        self.freedBytes = freedBytes
        self.section = section
    }
}

/// The last check before anything is deleted (`docs/architecture/safety-model.md` §4).
///
/// It runs immediately before each item is acted on, re-validating everything the scan established, because the
/// filesystem may have changed since the user reviewed the list. Any doubt results in a refusal, never a guess.
public struct DeletionGate: Sendable {
    /// Flags that mean "do not remove": locked, append-only, restricted by SIP, or protected by a data vault.
    static let protectiveFlags: UInt32 =
        UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND)
        | UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK) | UInt32(UF_DATAVAULT)

    private let currentPolicy: @Sendable () -> ProtectionPolicy
    private let ownerState: @Sendable (String) -> OwnerState

    /// A gate with fixed rules (tests, one-off operations).
    public init(policy: ProtectionPolicy, ownerState: @escaping @Sendable (String) -> OwnerState) {
        currentPolicy = { policy }
        self.ownerState = ownerState
    }

    /// A gate that reads the app's current rules on every check.
    public init(policyProvider: PolicyProvider, ownerState: @escaping @Sendable (String) -> OwnerState) {
        currentPolicy = { policyProvider.current }
        self.ownerState = ownerState
    }

    /// Validates `item` and returns it resolved (parent folder held open) so it can be acted on without
    /// re-resolving the path.
    public func check(_ item: DeletionItem) throws(SafetyRefusal) -> ResolvedItem {
        do {
            guard try PathPolicy.isStrictlyInside(item.path, root: item.ruleRoot) else {
                throw SafetyRefusal.outsideRoot
            }
        } catch let rejection as PathRejection {
            throw .invalidPath(rejection)
        } catch {
            throw .outsideRoot
        }
        if let reason = currentPolicy().protection(for: item.path) { throw .protected(reason) }

        let resolved = try SafeWalk.resolve(item.path)
        let parentIdentity: FileIdentity
        do {
            parentIdentity = try resolved.parent.identity()
        } catch {
            throw SafeWalk.refusal(for: error)
        }
        guard resolved.snapshot.identity.device == parentIdentity.device else { throw .differentVolume }
        guard resolved.snapshot == item.expected else { throw .changedSinceScan }
        guard resolved.flags & Self.protectiveFlags == 0 else { throw .flagged }

        if let owner = item.ownerBundleID, ownerState(owner) != .notRunning { throw .inUse }

        if resolved.snapshot.kind == .directory {
            do {
                let directory = try resolved.parent.openChild(named: resolved.name)
                // An app bundle's files are the vendor's resources (e.g. bundled CA certificates), never the user's
                // secrets; flags and volume boundaries are still enforced inside it.
                let isAppBundle = (resolved.name as NSString).pathExtension.lowercased() == "app"
                try inspectContents(of: directory, device: parentIdentity.device, checkNames: !isAppBundle)
            } catch let error as FileSystemError {
                throw SafeWalk.refusal(for: error)
            } catch let refusal as SafetyRefusal {
                throw refusal
            } catch {
                throw .ioError(EIO)
            }
        }
        return resolved
    }

    /// Walks a folder (never following links) and refuses if anything inside is protected by name, flagged,
    /// or on another volume.
    private func inspectContents(of directory: borrowing OpenDirectory, device: Int32, checkNames: Bool) throws {
        for entry in try directory.entries() {
            if checkNames, let reason = ProtectionPolicy.protection(forName: entry.name) {
                throw SafetyRefusal.containsProtectedItem(reason)
            }
            guard entry.flags & Self.protectiveFlags == 0 else { throw SafetyRefusal.flagged }
            guard entry.identity.device == device, !entry.isMountPoint else { throw SafetyRefusal.differentVolume }
            if entry.kind == .directory {
                try inspectContents(
                    of: try directory.openChild(named: entry.name), device: device, checkNames: checkNames)
            }
        }
    }
}
