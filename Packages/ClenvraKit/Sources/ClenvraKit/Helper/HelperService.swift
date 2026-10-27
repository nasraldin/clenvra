import Darwin
public import Foundation

/// One batch the app asks the helper to act on. Sent over XPC as JSON so the protocol stays one small method.
public struct HelperRequest: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case moveToTrash
        /// Only for confirmed irreversible actions (rotated system logs).
        case irreversible
        /// Check everything, change nothing.
        case dryRun
    }

    public let operationID: UUID
    public let mode: Mode
    public let items: [DeletionItem]
    /// Owner bundle identifier → its app bundle path, so the helper can check the owner is not running itself.
    public let ownerBundlePaths: [String: String]

    public init(operationID: UUID, mode: Mode, items: [DeletionItem], ownerBundlePaths: [String: String]) {
        self.operationID = operationID
        self.mode = mode
        self.items = items
        self.ownerBundlePaths = ownerBundlePaths
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> HelperRequest {
        try JSONDecoder().decode(HelperRequest.self, from: data)
    }
}

/// One outcome per requested item, in request order.
public struct HelperResponse: Codable, Sendable, Equatable {
    public let outcomes: [ActivityRecord.Outcome]

    public init(outcomes: [ActivityRecord.Outcome]) {
        self.outcomes = outcomes
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> HelperResponse {
        try JSONDecoder().decode(HelperResponse.self, from: data)
    }
}

/// Everything the privileged helper does, kept out of the helper binary so it is unit-tested without root.
///
/// The app's checks are never trusted: every item must pass the narrow allowlist, the managed-software check and the
/// full deletion gate again here. Removed items go to the requesting user's Trash (not root's), so they can be found
/// and put back.
public struct HelperService: Sendable {
    private let allowlist: HelperAllowlist
    private let clientHome: String
    private let log: ActivityLog
    private let ownPaths: [String]
    private let processPaths: @Sendable () -> [String]?
    private let fileSystem: FSExecutor

    /// - Parameters:
    ///   - clientHome: home folder of the user whose app connected (from the connection's user ID, never from the
    ///     request).
    ///   - log: the helper's own activity log, in a root-owned folder.
    ///   - ownPaths: Clenvra's own files (the helper's log folder, the app bundle), never removed.
    public init(
        allowlist: HelperAllowlist, clientHome: String, log: ActivityLog, ownPaths: [String] = [],
        processPaths: @escaping @Sendable () -> [String]? = OwnerActivity.currentProcessPaths,
        fileSystem: FSExecutor = .shared
    ) {
        self.allowlist = allowlist
        self.clientHome = clientHome
        self.log = log
        self.ownPaths = ownPaths
        self.processPaths = processPaths
        self.fileSystem = fileSystem
    }

    public func perform(_ request: HelperRequest) async -> HelperResponse {
        var outcomes = [ActivityRecord.Outcome?](repeating: nil, count: request.items.count)
        var accepted: [(index: Int, item: DeletionItem)] = []
        for (index, item) in request.items.enumerated() {
            if !allowlist.permits(item) {
                outcomes[index] = .skipped(.outsideRoot)
            } else if Self.belongsToManagedSoftware(item) {
                outcomes[index] = .skipped(.protected(.custom))
            } else {
                accepted.append((index, item))
            }
        }

        let activity = OwnerActivity(bundlePaths: request.ownerBundlePaths, processPaths: processPaths)
        let executor = DeletionExecutor(
            gate: DeletionGate(
                policy: ProtectionPolicy(home: clientHome, additionalProtected: ownPaths),
                ownerState: activity.state(of:)),
            log: log, trash: UserTrash(home: clientHome), fileSystem: fileSystem)
        let items = accepted.map(\.item)
        let results: [DeletionResult]
        switch request.mode {
        case .moveToTrash:
            results = await executor.run(items, mode: .moveToTrash, operationID: request.operationID)
        case .irreversible:
            results = await executor.run(items, mode: .irreversible, operationID: request.operationID)
        case .dryRun:
            results = await executor.run(items, mode: .moveToTrash, dryRun: true, operationID: request.operationID)
        }
        for (position, result) in results.enumerated() {
            outcomes[accepted[position].index] = result.outcome
        }
        return HelperResponse(outcomes: outcomes.map { $0 ?? .notAttempted })
    }

    /// Puts back an item the helper moved. Returns `nil` on success.
    ///
    /// The app's record only names which item to restore (operation and path). Everything acted on comes from the
    /// helper's own root-owned log: the Trash path, the original location and the identity. Otherwise a crafted
    /// record could make root move a user's file into a privileged folder (a launch daemon, a helper tool).
    public func restore(_ request: ActivityRecord) async -> RestoreError? {
        guard let records = try? await log.readAll().records,
            let logged = records.last(where: {
                $0.operationID == request.operationID && $0.itemPath == request.itemPath && $0.outcome.isMovedToTrash
            }),
            case .movedToTrash(let trashPath) = logged.outcome, let expected = logged.identity,
            let trashParts = try? PathPolicy.components(of: trashPath),
            let trashFolder = try? PathPolicy.components(of: clientHome + "/.Trash"),
            trashParts.count == trashFolder.count + 1, trashParts.starts(with: trashFolder)
        else { return .notRestorable }

        // The Trash entry must still be the very object the helper moved: no link, no special file, same identity.
        guard let kind = Self.kind(at: trashPath, expected: expected) else { return .notInTrash }
        guard allowlist.permitsRestore(originalPath: logged.itemPath, kind: kind) else { return .notRestorable }
        let parentPath = (logged.itemPath as NSString).deletingLastPathComponent
        guard (try? SafeWalk.resolve(parentPath))?.snapshot.kind == .directory else { return .originalFolderMissing }

        // RENAME_EXCL: never replace what now occupies the original location.
        guard renamex_np(trashPath, logged.itemPath, UInt32(RENAME_EXCL)) == 0 else {
            return errno == EEXIST ? .originalPathOccupied : .failed(errno: errno)
        }
        // Something may have swapped the entry between the check and the move: verify what landed, and undo if not.
        guard Self.kind(at: logged.itemPath, expected: expected) == kind else {
            _ = renamex_np(logged.itemPath, trashPath, UInt32(RENAME_EXCL))
            return .notInTrash
        }
        try? await log.append(
            ActivityRecord(
                operationID: logged.operationID, date: Date(), section: logged.section, itemPath: logged.itemPath,
                bytes: logged.bytes, outcome: .restored, identity: expected))
        return nil
    }

    /// The kind of the object at `path` if it is a regular file or folder with identity `expected`; never follows a
    /// link.
    private static func kind(at path: String, expected: FileIdentity) -> FileKind? {
        var info = stat()
        guard lstat(path, &info) == 0, FileIdentity(device: info.st_dev, inode: info.st_ino) == expected else {
            return nil
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        default: return nil
        }
    }

    /// Security, VPN and management agents are never touched, even when their files sit in allowlisted folders.
    static func belongsToManagedSoftware(_ item: DeletionItem) -> Bool {
        if let owner = item.ownerBundleID, ManagedAgents.isManaged(identifier: owner) { return true }
        let rootCount = (try? PathPolicy.components(of: item.ruleRoot).count) ?? 0
        let names = ((try? PathPolicy.components(of: item.path)) ?? []).dropFirst(rootCount)
        return names.contains { name in
            let stem =
                ["plist", "app"].contains((name as NSString).pathExtension.lowercased())
                ? (name as NSString).deletingPathExtension : name
            return ManagedAgents.isManaged(identifier: stem)
        }
    }
}

/// The requesting user's Trash. Items keep their owner, so a launch daemon put back still belongs to root.
struct UserTrash: TrashOperations {
    let home: String

    func moveToTrash(path: String) throws -> String {
        let folder = home + "/.Trash"
        let name = (path as NSString).lastPathComponent
        for attempt in 1...1_000 {
            let destination = folder + "/" + (attempt == 1 ? name : "\(name) \(attempt)")
            // RENAME_EXCL: never replace something already in the Trash; a failed rename never falls back to delete.
            if renamex_np(path, destination, UInt32(RENAME_EXCL)) == 0 { return destination }
            guard errno == EEXIST else { throw FileSystemError.current("rename", path) }
        }
        throw FileSystemError(code: EEXIST, operation: "rename", path: path)
    }
}
