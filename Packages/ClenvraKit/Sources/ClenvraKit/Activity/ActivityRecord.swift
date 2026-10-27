public import Foundation

/// One audited action on one item, as written to the activity log.
public struct ActivityRecord: Codable, Equatable, Sendable {
    public enum Section: String, Codable, Sendable {
        case overview, storage, cleanup, developer, applications, startup, system
    }

    public enum Outcome: Codable, Equatable, Sendable {
        /// Written just before acting, so an interrupted run still leaves a trace.
        case intent
        case movedToTrash(trashPath: String)
        case removedPermanently
        /// Dry run: everything was checked, nothing was changed.
        case wouldDelete
        case skipped(SafetyRefusal)
        case failed(errno: Int32)
        /// The item in the Trash is not the item that was checked; the batch was stopped.
        case anomaly
        /// Not attempted because the batch was cancelled or stopped.
        case notAttempted
        /// The user put the item back from the Trash.
        case restored
    }

    public let operationID: UUID
    public let date: Date
    public let section: Section
    public let itemPath: String
    public let bytes: Int64
    public let outcome: Outcome
    /// Identity of the item acted on; lets Restore verify the Trash still holds the same object.
    public let identity: FileIdentity?

    public init(
        operationID: UUID,
        date: Date,
        section: Section,
        itemPath: String,
        bytes: Int64,
        outcome: Outcome,
        identity: FileIdentity? = nil
    ) {
        self.operationID = operationID
        self.date = date
        self.section = section
        self.itemPath = itemPath
        self.bytes = bytes
        self.outcome = outcome
        self.identity = identity
    }
}

extension ActivityRecord.Outcome {
    /// True for a successful move to the Trash, whatever the resulting path.
    public var isMovedToTrash: Bool {
        if case .movedToTrash = self { true } else { false }
    }
}
