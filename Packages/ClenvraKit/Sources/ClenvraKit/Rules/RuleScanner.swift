import Darwin
public import Foundation

/// Runs one `CleanupRule` read-only and returns review candidates with sizes, ownership and status.
public enum RuleScanner {
    @concurrent public static func scan(
        _ rule: CleanupRule,
        home: String,
        policy: ProtectionPolicy,
        ownerState: @escaping @Sendable (String) -> OwnerState,
        now: Date = Date(),
        executor: FSExecutor = .shared
    ) async -> RuleScanResult {
        let rootPath = rule.root.path(home: home)
        let found: FoundItems
        do {
            switch rule.selection {
            case .children(let excluded, let minimumAge):
                let cutoff = minimumAge.map { now.addingTimeInterval(-$0.seconds) }
                found = try await children(of: rootPath, cutoff: cutoff, executor: executor) { !excluded.contains($0) }
            case .named(let names):
                found = try await children(of: rootPath, cutoff: nil, executor: executor) { names.contains($0) }
            case .projectArtifacts(let kinds, let inactivity, let maximumDepth):
                let cutoff = now.addingTimeInterval(-inactivity.seconds)
                found = try await projectArtifacts(
                    below: rootPath, kinds: kinds, activeSince: cutoff, maximumDepth: maximumDepth, executor: executor)
            case .files(let extensions, let minimumAge, let maximumDepth):
                let cutoff = minimumAge.map { now.addingTimeInterval(-$0.seconds) }
                let lowercased = Set(extensions.map { $0.lowercased() })
                found = try await executor.run {
                    try files(below: rootPath, cutoff: cutoff, maximumDepth: maximumDepth) { name in
                        lowercased.contains((name as NSString).pathExtension.lowercased())
                    }
                }
            case .matchingFiles(let pattern, let minimumAge, let maximumDepth):
                let cutoff = minimumAge.map { now.addingTimeInterval(-$0.seconds) }
                found = try await executor.run {
                    try files(below: rootPath, cutoff: cutoff, maximumDepth: maximumDepth) { name in
                        fnmatch(pattern, name, 0) == 0
                    }
                }
            case .emptyFolders(let maximumDepth):
                found = try await executor.run {
                    try emptyFolders(below: rootPath, maximumDepth: maximumDepth)
                }
            }
        } catch let error as FileSystemError where error.code == ENOENT || error.code == ENOTDIR {
            return RuleScanResult(rule: rule, rootExists: false, candidates: [], skipped: [])
        } catch let error as FileSystemError {
            return RuleScanResult(
                rule: rule, rootExists: true, candidates: [],
                skipped: [SkippedPath(path: rootPath, reason: StorageScanner.reason(for: error))])
        } catch {
            return RuleScanResult(rule: rule, rootExists: true, candidates: [], skipped: [])
        }

        let candidates = found.items.map { item in
            let owner = owner(of: item, hint: rule.ownership)
            return CleanupCandidate(
                ruleID: rule.id, name: displayName(of: item, label: rule.label), path: item.path, ruleRoot: rootPath,
                kind: item.entry.kind,
                logicalSize: item.logical, allocatedSize: item.allocated, reclaimableSize: item.reclaimable,
                modificationDate: item.entry.modificationDate, snapshot: FileSnapshot(item.entry),
                ownerBundleID: owner,
                status: status(
                    of: item, owner: owner, policy: policy, ownerState: ownerState, elevated: rule.elevation == .helper),
                risk: item.isRecentlyActive ? .review : rule.risk)
        }
        .filter {
            switch rule.selection {
            case .emptyFolders: true
            default: $0.allocatedSize > 0
            }
        }
        .sorted(by: CleanupCandidate.largestFreedFirst)

        return RuleScanResult(rule: rule, rootExists: true, candidates: candidates, skipped: found.skipped)
    }

    // MARK: - Collecting items

    struct FoundItem: Sendable {
        let path: String
        let name: String
        let entry: FileEntry
        let logical: Int64
        let allocated: Int64
        let reclaimable: Int64
        /// Belongs to a project touched recently; offered for review only.
        var isRecentlyActive = false
    }

    struct FoundItems: Sendable {
        var items: [FoundItem] = []
        var skipped: [SkippedPath] = []
    }

    /// Direct children of the root; folder sizes come from one storage scan of the root.
    @concurrent private static func children(
        of rootPath: String, cutoff: Date?, executor: FSExecutor, including isIncluded: (String) -> Bool
    ) async throws -> FoundItems {
        let listing = try await executor.run { try OpenDirectory(path: rootPath).read() }
        let entries = listing.entries.filter { isIncluded($0.name) }
        // One storage pass over the root sizes every folder; per-folder scans would repeat setup hundreds of times.
        let snapshot: StorageSnapshot? =
            entries.contains { $0.kind == .directory }
            ? try? await StorageScanner.scan(root: rootPath, executor: executor) : nil
        let skipped = snapshot?.skipped ?? []

        var found = FoundItems()
        for entry in entries {
            let path = rootPath + "/" + entry.name
            if cutoff != nil {
                // When age filtering is active (e.g. temporary files), skip sockets and anything not a regular file or folder.
                guard entry.kind == .file || entry.kind == .directory else { continue }
            } else {
                guard entry.kind != .other else { continue }
            }
            if entry.kind == .directory {
                let aggregate = snapshot?.aggregate(at: path)
                if let cutoff {
                    if entry.modificationDate > cutoff { continue }
                    if let latest = aggregate?.latestModification, latest > cutoff { continue }
                }
                found.items.append(
                    FoundItem(
                        path: path, name: entry.name, entry: entry, logical: aggregate?.logical ?? 0,
                        allocated: aggregate?.allocated ?? 0, reclaimable: aggregate?.reclaimable ?? 0))
            } else {
                if let cutoff, entry.modificationDate > cutoff { continue }
                found.items.append(item(entry, at: path))
            }
        }
        found.skipped = skipped
        return found
    }

    /// Matching files below the root, never following links or crossing into another volume.
    private static func files(
        below rootPath: String, cutoff: Date?, maximumDepth: Int, matching isMatch: (String) -> Bool
    ) throws(FileSystemError) -> FoundItems {
        var found = FoundItems()
        let root = try OpenDirectory(path: rootPath)
        let device = try root.identity().device
        collect(
            in: root, path: rootPath, depth: 0, device: device, cutoff: cutoff, maximumDepth: maximumDepth,
            matching: isMatch, into: &found)
        return found
    }

    private static func collect(
        in directory: borrowing OpenDirectory, path: String, depth: Int, device: Int32,
        cutoff: Date?, maximumDepth: Int, matching isMatch: (String) -> Bool, into found: inout FoundItems
    ) {
        let entries: [FileEntry]
        do {
            entries = try directory.entries()
        } catch {
            found.skipped.append(SkippedPath(path: path, reason: StorageScanner.reason(for: error)))
            return
        }
        for entry in entries {
            let childPath = path + "/" + entry.name
            switch entry.kind {
            case .directory:
                guard depth < maximumDepth, !entry.isMountPoint, entry.identity.device == device else { continue }
                do {
                    let child = try directory.openChild(named: entry.name)
                    collect(
                        in: child, path: childPath, depth: depth + 1, device: device, cutoff: cutoff,
                        maximumDepth: maximumDepth, matching: isMatch, into: &found)
                } catch {
                    found.skipped.append(SkippedPath(path: childPath, reason: StorageScanner.reason(for: error)))
                }
            case .file:
                guard isMatch(entry.name) else { continue }
                if let cutoff, entry.modificationDate > cutoff { continue }
                found.items.append(item(entry, at: childPath))
            case .symlink, .other:
                continue
            }
        }
    }

    /// Artifact folders found by walking the root; sizes come from a storage scan of each folder.
    @concurrent private static func projectArtifacts(
        below rootPath: String, kinds: [ArtifactKind], activeSince cutoff: Date, maximumDepth: Int,
        executor: FSExecutor
    ) async throws -> FoundItems {
        var located = try await executor.run {
            var found = FoundItems()
            let root = try OpenDirectory(path: rootPath)
            let device = try root.identity().device
            findArtifacts(
                in: root, path: rootPath, depth: 0, device: device, kinds: kinds, cutoff: cutoff,
                maximumDepth: maximumDepth, into: &found)
            return found
        }
        guard !located.items.isEmpty,
            let snapshot = try? await StorageScanner.scan(root: rootPath, executor: executor)
        else { return located }
        located.items = located.items.map { item in
            guard let aggregate = snapshot.aggregate(at: item.path) else { return item }
            return FoundItem(
                path: item.path, name: item.name, entry: item.entry, logical: aggregate.logical,
                allocated: aggregate.allocated, reclaimable: aggregate.reclaimable,
                isRecentlyActive: item.isRecentlyActive)
        }
        return located
    }

    private static func findArtifacts(
        in directory: borrowing OpenDirectory, path: String, depth: Int, device: Int32, kinds: [ArtifactKind],
        cutoff: Date, maximumDepth: Int, into found: inout FoundItems
    ) {
        let entries: [FileEntry]
        do {
            entries = try directory.entries()
        } catch {
            found.skipped.append(SkippedPath(path: path, reason: StorageScanner.reason(for: error)))
            return
        }
        let names = Set(entries.map(\.name))
        let artifactFolderNames = Set(kinds.map(\.folder))
        var matched: Set<String> = []
        for kind in kinds where !kind.markers.isDisjoint(with: names) {
            guard let entry = entries.first(where: { $0.name == kind.folder && $0.kind == .directory }) else {
                continue
            }
            matched.insert(entry.name)
            // Project activity: newest change among the project's own entries, not its build output or .git.
            let latest = entries.filter { !artifactFolderNames.contains($0.name) && $0.name != ".git" }
                .map(\.modificationDate).max()
            var item = FoundItem(
                path: path + "/" + entry.name, name: entry.name, entry: entry, logical: 0, allocated: 0,
                reclaimable: 0)
            item.isRecentlyActive = (latest ?? .distantPast) > cutoff
            found.items.append(item)
        }
        guard depth < maximumDepth else { return }
        for entry in entries
        where entry.kind == .directory && !entry.name.hasPrefix(".") && !matched.contains(entry.name)
            && !entry.isMountPoint && entry.identity.device == device
        {
            guard let child = try? directory.openChild(named: entry.name) else { continue }
            findArtifacts(
                in: child, path: path + "/" + entry.name, depth: depth + 1, device: device, kinds: kinds,
                cutoff: cutoff, maximumDepth: maximumDepth, into: &found)
        }
    }

    // MARK: - Empty folders

    private static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "bundle", "framework", "plugin", "kext", "savedstate", "pkg", "download",
        "prefpane", "qlgenerator", "component", "xpc", "appex",
    ]

    private static func isPackage(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return packageExtensions.contains(ext)
    }

    private static func isDotMarker(name: String) -> Bool {
        name.hasPrefix(".") && name != ".DS_Store"
    }

    private struct EmptyFolderReport {
        let isEmpty: Bool
        let allocatedSize: Int64
        let logicalSize: Int64
    }

    /// Finds empty folders strictly below rootPath up to maximumDepth folders deep.
    private static func emptyFolders(below rootPath: String, maximumDepth: Int) throws(FileSystemError) -> FoundItems {
        var found = FoundItems()
        let root = try OpenDirectory(path: rootPath)
        let device = try root.identity().device
        _ = checkEmptyFolder(
            in: root, path: rootPath, isRoot: true, depth: 0, device: device, maximumDepth: maximumDepth, into: &found)
        return found
    }

    private static func checkEmptyFolder(
        in directory: borrowing OpenDirectory, path: String, isRoot: Bool, depth: Int, device: Int32,
        maximumDepth: Int, into found: inout FoundItems
    ) -> EmptyFolderReport {
        let entries: [FileEntry]
        do {
            entries = try directory.entries()
        } catch {
            found.skipped.append(SkippedPath(path: path, reason: StorageScanner.reason(for: error)))
            return EmptyFolderReport(isEmpty: false, allocatedSize: 0, logicalSize: 0)
        }

        var hasDisqualifier = false
        var dsAllocated: Int64 = 0
        var dsLogical: Int64 = 0
        var subdirs: [FileEntry] = []

        for entry in entries {
            switch entry.kind {
            case .file:
                if entry.name == ".DS_Store" {
                    dsAllocated += entry.size.allocated
                    dsLogical += entry.size.logical
                } else {
                    hasDisqualifier = true
                }
            case .directory:
                if isDotMarker(name: entry.name) {
                    // A folder with a dot-folder marker (.git, etc.) is never an empty folder candidate and never descended into.
                    return EmptyFolderReport(isEmpty: false, allocatedSize: 0, logicalSize: 0)
                } else if isPackage(name: entry.name) {
                    hasDisqualifier = true
                } else if !entry.isMountPoint && entry.identity.device == device {
                    subdirs.append(entry)
                } else {
                    hasDisqualifier = true
                }
            case .symlink, .other:
                hasDisqualifier = true
            }
        }

        if depth >= maximumDepth && !subdirs.isEmpty {
            hasDisqualifier = true
        }

        var emptyChildren: [(entry: FileEntry, path: String, report: EmptyFolderReport)] = []
        var allSubdirsEmpty = true

        for subdir in subdirs {
            let childPath = path + "/" + subdir.name
            let childDir: OpenDirectory
            do {
                childDir = try directory.openChild(named: subdir.name)
            } catch {
                found.skipped.append(SkippedPath(path: childPath, reason: StorageScanner.reason(for: error)))
                allSubdirsEmpty = false
                continue
            }
            let childReport = checkEmptyFolder(
                in: childDir, path: childPath, isRoot: false, depth: depth + 1, device: device,
                maximumDepth: maximumDepth, into: &found)
            if childReport.isEmpty {
                dsAllocated += childReport.allocatedSize
                dsLogical += childReport.logicalSize
                emptyChildren.append((subdir, childPath, childReport))
            } else {
                allSubdirsEmpty = false
            }
        }

        let isThisFolderEmpty = !hasDisqualifier && allSubdirsEmpty
        if isThisFolderEmpty {
            if isRoot {
                for child in emptyChildren {
                    found.items.append(
                        FoundItem(
                            path: child.path, name: child.entry.name, entry: child.entry,
                            logical: child.report.logicalSize, allocated: child.report.allocatedSize,
                            reclaimable: child.report.allocatedSize))
                }
            }
            return EmptyFolderReport(isEmpty: true, allocatedSize: dsAllocated, logicalSize: dsLogical)
        } else {
            for child in emptyChildren {
                found.items.append(
                    FoundItem(
                        path: child.path, name: child.entry.name, entry: child.entry,
                        logical: child.report.logicalSize, allocated: child.report.allocatedSize,
                        reclaimable: child.report.allocatedSize))
            }
            return EmptyFolderReport(isEmpty: false, allocatedSize: dsAllocated, logicalSize: dsLogical)
        }
    }

    private static func item(_ entry: FileEntry, at path: String) -> FoundItem {
        // Deleting one name of a hard-linked file frees nothing.
        let reclaimable = entry.linkCount > 1 ? 0 : entry.size.freedIfDeleted
        return FoundItem(
            path: path, name: entry.name, entry: entry, logical: entry.size.logical, allocated: entry.size.allocated,
            reclaimable: reclaimable)
    }

    // MARK: - Naming

    private static func displayName(of item: FoundItem, label: ItemLabel) -> String {
        switch label {
        case .fileName: item.name
        case .deviceBackup: deviceName(inBackup: item.path) ?? item.name
        }
    }

    /// The device name from a backup's `Info.plist`, read only when it is a small regular file (never a link).
    static func deviceName(inBackup path: String) -> String? {
        let plistPath = path + "/Info.plist"
        var info = stat()
        guard lstat(plistPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 4_000_000,
            let data = FileManager.default.contents(atPath: plistPath),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let name = plist["Device Name"] as? String,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return name
    }

    // MARK: - Status

    private static func owner(of item: FoundItem, hint: OwnershipHint) -> String? {
        switch hint {
        case .none: nil
        case .fixed(let identifier): identifier
        case .bundleIdentifierFromName: isBundleIdentifierLike(item.name) ? item.name : nil
        case .namePrefix(let owners, let fallback):
            owners.filter { item.name.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?
                .bundleIdentifier ?? fallback
        }
    }

    /// Reverse-DNS shaped: at least three non-empty components of letters, digits, "-" and "_".
    static func isBundleIdentifierLike(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                    || "._-".unicodeScalars.contains(scalar))
        }
    }

    private static func status(
        of item: FoundItem, owner: String?, policy: ProtectionPolicy,
        ownerState: @Sendable (String) -> OwnerState, elevated: Bool
    ) -> CandidateStatus {
        if let reason = policy.protection(for: item.path) { return .protected(reason) }
        // The helper acts as root, so folder permissions don't apply; protective flags and SIP still do.
        if elevated {
            if item.entry.flags & DeletionGate.protectiveFlags != 0 { return .systemManaged }
        } else if !isRemovableByCurrentUser(item) {
            return .systemManaged
        }
        if let owner, ownerState(owner) != .notRunning { return .inUse }
        if item.entry.kind == .file && isFileLocked(item.path) { return .inUse }
        return .available
    }

    /// Checks if a regular file is currently locked by another process via an advisory write lock.
    private static func isFileLocked(_ path: String) -> Bool {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        if fcntl(fd, F_GETLK, &fl) == 0 && fl.l_type != F_UNLCK {
            return true
        }
        return false
    }

    /// Removing needs write access to the parent; emptying a folder needs write access to the folder itself.
    private static func isRemovableByCurrentUser(_ item: FoundItem) -> Bool {
        guard item.entry.flags & DeletionGate.protectiveFlags == 0 else { return false }
        let parent = (item.path as NSString).deletingLastPathComponent
        guard access(parent, W_OK) == 0 else { return false }
        return item.entry.kind != .directory || access(item.path, W_OK) == 0
    }
}
