/// Why Clenvra refused to act on an item. Every case maps to a plain-language explanation in the UI;
/// a refusal is a normal outcome ("skipped"), never a crash.
public enum SafetyRefusal: Error, Sendable, Equatable, Codable {
    /// The path string itself is malformed or ambiguous.
    case invalidPath(PathRejection)
    /// "/" or another volume root can never be a target.
    case isVolumeRoot
    /// A folder on the way to the item is now a symlink or no longer a folder.
    case pathChanged
    /// The item no longer exists.
    case notFound
    /// macOS denied access (permissions, privacy protection, or System Integrity Protection).
    case permissionDenied
    /// The item is not strictly inside the folder the cleanup rule allows (or is that folder itself).
    case outsideRoot
    /// The location is protected (system, home roots, secrets, personal data, exclusions).
    case protected(ProtectionReason)
    /// A folder contains something protected (a secret file, …); deleting the folder would delete it too.
    case containsProtectedItem(ProtectionReason)
    /// The item is not the one that was reviewed: replaced, modified, or a different kind.
    case changedSinceScan
    /// The item is on another volume than its parent folder (a mount point), or contains one.
    case differentVolume
    /// macOS flags mark the item (or something inside it) as locked, append-only or system-restricted.
    case flagged
    /// The app that owns this item is running, or Clenvra could not tell whether it is.
    case inUse
    /// A startup item whose program is still installed, so it is not orphaned.
    case programStillInstalled
    /// Any other filesystem error, with its errno.
    case ioError(Int32)
}
