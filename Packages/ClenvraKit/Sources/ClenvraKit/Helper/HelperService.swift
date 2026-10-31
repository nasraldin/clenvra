import Darwin
public import Foundation

/// One batch the app asks the helper to act on. Sent over XPC as JSON so the protocol stays one small method.
public struct HelperRequest: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case moveToTrash
        /// Only for confirmed irreversible actions: rotated system logs, and an app's system files on Uninstall when
        /// `authorization` carries the administrator's password.
        case irreversible
        /// Check everything, change nothing.
        case dryRun
    }

    public let operationID: UUID
    public let mode: Mode
    public let items: [DeletionItem]
    /// Owner bundle identifier → its app bundle path, so the helper can check the owner is not running itself.
    public let ownerBundlePaths: [String: String]
    /// The client's authorization (external form), needed only for an Uninstall's permanent removal.
    public let authorization: Data?

    public init(
        operationID: UUID, mode: Mode, items: [DeletionItem], ownerBundlePaths: [String: String],
        authorization: Data? = nil
    ) {
        self.operationID = operationID
        self.mode = mode
        self.items = items
        self.ownerBundlePaths = ownerBundlePaths
        self.authorization = authorization
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
    private let clientUID: uid_t
    private let log: ActivityLog
    private let staging: String
    private let ownPaths: [String]
    private let processPaths: @Sendable () -> [String]?
    private let fileSystem: FSExecutor
    private let runner: any CommandRunning
    private let authorize: @Sendable (Data?) -> Bool

    /// - Parameters:
    ///   - clientHome: home folder of the user whose app connected (from the connection's user ID, never from the
    ///     request).
    ///   - clientUID: that user's ID; their Trash must belong to them.
    ///   - staging: a root-only folder on the same volume where Put Back checks an item before placing it.
    ///   - log: the helper's own activity log, in a root-owned folder.
    ///   - ownPaths: Clenvra's own files (the helper's log folder, the app bundle), never removed.
    ///   - authorize: asks for an administrator's password for the client's authorization (`HelperRight.authorize`
    ///     in the helper). Changing Mac-wide startup items and permissions needs it every time; refuses by default.
    public init(
        allowlist: HelperAllowlist, clientHome: String, clientUID: uid_t, log: ActivityLog, staging: String,
        ownPaths: [String] = [],
        processPaths: @escaping @Sendable () -> [String]? = OwnerActivity.currentProcessPaths,
        fileSystem: FSExecutor = .shared, runner: any CommandRunning = ProcessCommandRunner(),
        authorize: @escaping @Sendable (Data?) -> Bool = { _ in false }
    ) {
        self.authorize = authorize
        self.allowlist = allowlist
        self.clientHome = clientHome
        self.clientUID = clientUID
        self.log = log
        self.staging = staging
        self.ownPaths = ownPaths
        self.processPaths = processPaths
        self.fileSystem = fileSystem
        self.runner = runner
    }

    @concurrent public func perform(_ request: HelperRequest) async -> HelperResponse {
        var outcomes = [ActivityRecord.Outcome?](repeating: nil, count: request.items.count)
        var accepted: [(index: Int, item: DeletionItem)] = []
        // An app's system files go for good only on Uninstall, and only after the administrator's password (asked
        // once per request, and only when such an item is in it). Cleanup items never do.
        let needsPassword =
            request.mode == .irreversible
            && request.items.contains { $0.section == .applications && !allowlist.permitsIrreversible($0) }
        let uninstallAuthorized = needsPassword && authorize(request.authorization)
        func permitsIrreversible(_ item: DeletionItem) -> Bool {
            allowlist.permitsIrreversible(item) || (item.section == .applications && uninstallAuthorized)
        }
        for (index, item) in request.items.enumerated() {
            if !allowlist.permits(item) || (request.mode == .irreversible && !permitsIrreversible(item)) {
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
            log: log, trash: UserTrash(home: clientHome, uid: clientUID), fileSystem: fileSystem)
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
    @concurrent public func restore(_ request: ActivityRecord) async -> RestoreError? {
        guard let records = try? await log.readAll().records,
            let logged = records.last(where: {
                $0.operationID == request.operationID && $0.itemPath == request.itemPath && $0.outcome.isMovedToTrash
            }),
            case .movedToTrash(let trashPath) = logged.outcome, let expected = logged.identity,
            let trashParts = try? PathPolicy.components(of: trashPath),
            let trashFolder = try? PathPolicy.components(of: clientHome + "/.Trash"),
            trashParts.count == trashFolder.count + 1, trashParts.starts(with: trashFolder)
        else { return .notRestorable }

        // Everything below goes through file descriptors opened without following links, so a symlink planted in
        // the user's (user-writable) Trash, or swapped in for it, cannot redirect root.
        let trash: OpenDirectory
        do {
            trash = try UserTrash(home: clientHome, uid: clientUID).open()
        } catch {
            return .notInTrash
        }
        let trashName = (trashPath as NSString).lastPathComponent
        let originalName = (logged.itemPath as NSString).lastPathComponent
        let parentPath = (logged.itemPath as NSString).deletingLastPathComponent
        let stage: OpenDirectory
        let parent: OpenDirectory
        do {
            stage = try SafeWalk.openDirectory(staging)
        } catch {
            return .failed(errno: EIO)
        }
        do {
            parent = try SafeWalk.openDirectory(parentPath)
        } catch {
            return .originalFolderMissing
        }

        // Take the entry out of the user's reach first, then check it: a check in the user-writable Trash could be
        // raced by a swap before the move.
        let stagedName = UUID().uuidString
        do {
            try trash.moveChild(named: trashName, into: stage, as: stagedName)
        } catch {
            return .notInTrash
        }
        let staged = Self.kind(of: stage, child: stagedName, expected: expected)
        guard let kind = staged, allowlist.permitsRestore(originalPath: logged.itemPath, kind: kind) else {
            // Not the logged object, or not allowed back: hand it back. If that fails it stays in root's folder,
            // never in a system location.
            try? stage.moveChild(named: stagedName, into: trash, as: trashName)
            return staged == nil ? .notInTrash : .notRestorable
        }

        // RENAME_EXCL: never replace what now occupies the original location.
        do {
            try stage.moveChild(named: stagedName, into: parent, as: originalName)
        } catch {
            try? stage.moveChild(named: stagedName, into: trash, as: trashName)
            return error.code == EEXIST ? .originalPathOccupied : .failed(errno: error.code)
        }
        try? await log.append(
            ActivityRecord(
                operationID: logged.operationID, date: Date(), section: logged.section, itemPath: logged.itemPath,
                bytes: logged.bytes, outcome: .restored, identity: expected))
        return nil
    }

    /// The kind of a directory's child if it is a regular file or folder with identity `expected`; never follows a
    /// link.
    private static func kind(of directory: borrowing OpenDirectory, child: String, expected: FileIdentity) -> FileKind?
    {
        guard let info = try? directory.statChild(named: child),
            FileIdentity(device: info.st_dev, inode: info.st_ino) == expected
        else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        default: return nil
        }
    }

    // MARK: - Orphaned system launch items (SB-4)

    /// Unloads an orphaned launch daemon or agent and moves its plist to the user's Trash. The label and program
    /// come from the plist itself, and only items whose program no longer exists are touched.
    /// Asks for the administrator's password (`authorization`) each time before changing anything.
    @concurrent public func removeOrphanedLaunchItem(
        _ item: DeletionItem, operationID: UUID, authorization: Data? = nil
    ) async -> ActivityRecord.Outcome {
        guard allowlist.isSystemLaunchItem(item) else { return .skipped(.outsideRoot) }
        guard authorize(authorization) else { return .notAttempted }
        guard !Self.belongsToManagedSoftware(item),
            let plist = Self.launchPlist(at: item.path), let label = Self.validLabel(plist["Label"]),
            !ManagedAgents.isManaged(identifier: label)
        else { return .skipped(.protected(.custom)) }
        let arguments = plist["ProgramArguments"] as? [String]
        guard let program = (plist["Program"] as? String) ?? arguments?.first, program.hasPrefix("/"),
            (try? PathPolicy.components(of: program)) != nil
        else { return .skipped(.protected(.custom)) }
        var info = stat()
        guard lstat(program, &info) != 0, errno == ENOENT else { return .skipped(.programStillInstalled) }

        // The full gate first: nothing is unloaded for an item that would not be removed.
        let check = await perform(
            HelperRequest(operationID: operationID, mode: .dryRun, items: [item], ownerBundlePaths: [:]))
        guard check.outcomes.first == .wouldDelete else { return check.outcomes.first ?? .notAttempted }

        // Unload by plist path, so only the job loaded from this very file can be stopped (never another job that
        // happens to share the label). A failure usually means it was not loaded; the plist is removed either way.
        let isDaemon = (item.ruleRoot as NSString).lastPathComponent == "LaunchDaemons"
        let domain = isDaemon ? "system" : "gui/\(clientUID)"
        _ = try? await runner.run(Command(executable: "/bin/launchctl", arguments: ["bootout", domain, item.path]))
        let response = await perform(
            HelperRequest(operationID: operationID, mode: .moveToTrash, items: [item], ownerBundlePaths: [:]))
        return response.outcomes.first ?? .notAttempted
    }

    /// Disables or enables a Mac-wide launch item. Only a plist directly in `/Library/LaunchAgents` or
    /// `/Library/LaunchDaemons`, exactly as the person reviewed it, with a valid non-Apple, non-managed label; and
    /// only after an administrator's password. The plist itself is never changed or moved, so this is reversible.
    @concurrent public func setLaunchItemEnabled(_ item: DeletionItem, enabled: Bool, authorization: Data?) async
        -> LaunchItemChange
    {
        guard allowlist.isSystemLaunchItem(item), !Self.belongsToManagedSoftware(item) else { return .refused }
        guard Self.isUnchanged(item) else { return .changedSinceReview }
        guard let plist = Self.launchPlist(at: item.path), let label = Self.validLabel(plist["Label"]),
            !ManagedAgents.isManaged(identifier: label)
        else { return .refused }
        guard authorize(authorization) else { return .notAuthorized }
        // The password dialog may have been open for a while: check the file again right before acting.
        guard Self.isUnchanged(item) else { return .changedSinceReview }

        let isDaemon = (item.ruleRoot as NSString).lastPathComponent == "LaunchDaemons"
        let domain = isDaemon ? "system" : "gui/\(clientUID)"
        if enabled {
            guard await launchctl(["enable", "\(domain)/\(label)"]) == 0 else { return .failed }
            // Loading it now is a bonus; once enabled it starts at the next boot or login either way.
            _ = await launchctl(["bootstrap", domain, item.path])
        } else {
            // Not loaded (3, 113) is fine: disabling still keeps it from starting again.
            guard let status = await launchctl(["bootout", domain, item.path]), [0, 3, 113].contains(status) else {
                return .failed
            }
            guard await launchctl(["disable", "\(domain)/\(label)"]) == 0 else { return .failed }
        }
        return .done
    }

    private static func isUnchanged(_ item: DeletionItem) -> Bool {
        (try? SafeWalk.resolve(item.path).snapshot) == item.expected
    }

    /// The exit status of `launchctl`, or `nil` when it did not run to completion.
    private func launchctl(_ arguments: [String]) async -> Int32? {
        let command = Command(executable: "/bin/launchctl", arguments: arguments, timeout: .seconds(15))
        guard let result = try? await runner.run(command), result.terminationReason == .exited else { return nil }
        return result.exitStatus
    }

    // MARK: - Permissions for every user

    /// Resets one app's permission for one service with `tccutil` as root. Only services System Settings shows by
    /// name and well-formed bundle IDs; never `All`, never a path; and only after an administrator's password.
    @concurrent public func resetPermission(service: String, bundleID: String, authorization: Data?) async
        -> PermissionReset
    {
        let short = PermissionService.shortName(service)
        guard PermissionService.isKnown(short), Self.isValidBundleID(bundleID) else { return .invalid }
        guard authorize(authorization) else { return .notAuthorized }
        let result = try? await runner.run(
            Command(executable: "/usr/bin/tccutil", arguments: ["reset", short, bundleID], timeout: .seconds(15)))
        guard let result, result.terminationReason == .exited, result.exitStatus == 0 else { return .failed }
        return .reset
    }

    /// Letters, digits, ".", "_" and "-", starting with a letter or digit, at most 255 characters.
    static func isValidBundleID(_ value: String) -> Bool {
        guard (1...255).contains(value.count), let first = value.unicodeScalars.first,
            first.isASCII && (first.properties.isAlphabetic || ("0"..."9").contains(first))
        else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0))
        }
    }

    /// A small, regular property list file, read without following links.
    private static func launchPlist(at path: String) -> [String: Any]? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 1_000_000,
            let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// A launchd label safe to pass as one argument: letters, digits, ".", "_" and "-", never Apple's own.
    private static func validLabel(_ value: Any?) -> String? {
        guard let label = value as? String, (1...255).contains(label.count), !label.hasPrefix("-"),
            !label.lowercased().hasPrefix("com.apple."),
            label.unicodeScalars.allSatisfy({
                $0.isASCII
                    && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0))
            })
        else { return nil }
        return label
    }

    // MARK: - Local Time Machine snapshots (SY-4)

    /// Deletes one local snapshot by date, only if the date is well formed and currently listed.
    @concurrent public func deleteLocalSnapshot(date: String) async -> SnapshotDeletion {
        guard LocalSnapshots.isValidDate(date) else { return .invalid }
        let list = try? await runner.run(
            Command(executable: "/usr/bin/tmutil", arguments: ["listlocalsnapshotdates", "/"]))
        guard let list, list.terminationReason == .exited, list.exitStatus == 0 else { return .failed }
        guard LocalSnapshots.dates(fromListOutput: list.standardOutput).contains(date) else { return .notFound }
        let result = try? await runner.run(
            Command(
                executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", date], timeout: .seconds(300)))
        guard let result, result.terminationReason == .exited, result.exitStatus == 0 else { return .failed }
        return .deleted
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
///
/// The Trash lives in a folder the user controls, so root never resolves a path into it: the folder is opened
/// component by component without following links, must be a real folder owned by the user and writable by nobody
/// else, and items are moved relative to file descriptors.
struct UserTrash: TrashOperations {
    let home: String
    let uid: uid_t

    func open() throws -> OpenDirectory {
        let trash = try SafeWalk.openDirectory(home + "/.Trash")
        let owner = try trash.ownerID()
        let mode = try trash.mode()
        guard owner == uid, mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw FileSystemError(code: EPERM, operation: "open", path: home + "/.Trash")
        }
        return trash
    }

    func moveToTrash(path: String) throws -> String {
        let trash = try open()
        let source = try SafeWalk.resolve(path)
        for attempt in 1...1_000 {
            let name = attempt == 1 ? source.name : "\(source.name) \(attempt)"
            do {
                // RENAME_EXCL: never replace something already in the Trash; a failed move never falls back to delete.
                try source.parent.moveChild(named: source.name, into: trash, as: name)
                return home + "/.Trash/" + name
            } catch  where error.code == EEXIST {
                continue
            }
        }
        throw FileSystemError(code: EEXIST, operation: "renameat", path: path)
    }
}
