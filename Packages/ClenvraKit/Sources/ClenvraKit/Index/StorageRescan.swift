import Darwin
import Foundation

extension StorageScanner {
    /// Runs one scan; injectable so callers and tests can observe which folders are read.
    typealias ScanFunction =
        @Sendable (
            _ root: String, _ options: ScanOptions, _ executor: FSExecutor,
            _ progress: @escaping @Sendable (ScanProgress) -> Void
        ) async throws -> StorageSnapshot

    /// The real scanner as a `ScanFunction`.
    static let defaultScan: ScanFunction = { root, options, executor, progress in
        try await scan(root: root, options: options, executor: executor, progress: progress)
    }

    /// Brings `snapshot` up to date after the contents of `changedFolders` changed (items removed from them or added
    /// to them), reading only those folders instead of the whole tree. The result has the same totals as a full
    /// rescan: each changed folder's subtree is replaced and every ancestor's aggregate is recomputed.
    ///
    /// Folders outside the snapshot, or inside a folder the scan never read, are ignored: nothing of theirs was
    /// counted. A folder that no longer exists is replaced by its nearest existing ancestor. When a hard-linked
    /// object loses a name inside a rescanned folder, the folders holding its other names are rescanned too, because
    /// their link count (and so what they free) may have changed. Throws only if the scanned root itself is gone.
    static func rescan(
        _ snapshot: StorageSnapshot, changedFolders: [String], options: ScanOptions, executor: FSExecutor = .shared,
        scan: ScanFunction = defaultScan, progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> StorageSnapshot {
        var current = snapshot
        var queue = snapshot.foldersToRescan(for: changedFolders)
        var done: [String] = []
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            if done.contains(where: { isPath(candidate, inside: $0) }) { continue }
            let (folder, subtree) = try await scanNearestExisting(
                candidate, in: current, options: options, executor: executor, scan: scan, progress: progress)
            let previous = current
            current = current.replacingSubtree(with: subtree, maxLargeFiles: max(0, options.maxLargeFiles))
            done.removeAll { isPath($0, inside: folder) }
            done.append(folder)
            queue.append(contentsOf: previous.foldersWithRelinkedNames(inside: folder, after: subtree))
        }
        return current
    }

    /// Scans `folder`, or, if it can no longer be read, its nearest ancestor known to the snapshot.
    private static func scanNearestExisting(
        _ folder: String, in snapshot: StorageSnapshot, options: ScanOptions, executor: FSExecutor,
        scan: ScanFunction, progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> (folder: String, snapshot: StorageSnapshot) {
        var folder = folder
        while true {
            do {
                return (folder, try await scan(folder, options, executor, progress))
            } catch {
                guard folder != snapshot.root else { throw error }
                folder = snapshot.nearestScannedAncestor(of: parent(of: folder))
            }
        }
    }

    /// `true` when `path` is `folder` or lies below it, compared by whole components.
    static func isPath(_ path: String, inside folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}

extension StorageSnapshot {
    /// The scanned folders to read again for `changedFolders`: each mapped to itself or its nearest scanned ancestor,
    /// dropped when it lies outside the root or inside a skipped folder, and with nested folders removed.
    func foldersToRescan(for changedFolders: [String]) -> [String] {
        let skippedPaths = Set(skipped.map(\.path))
        var folders: [String] = []
        for changed in changedFolders {
            let path = StorageScanner.normalize(changed)
            guard path.hasPrefix("/"), StorageScanner.isPath(path, inside: root),
                !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            else { continue }
            var candidate = path
            while directories[candidate] == nil {
                if skippedPaths.contains(candidate) || candidate == root { break }
                candidate = StorageScanner.parent(of: candidate)
            }
            if directories[candidate] != nil { folders.append(candidate) }
        }
        var kept: [String] = []
        for folder in folders.sorted(by: { $0.count < $1.count })
        where !kept.contains(where: { StorageScanner.isPath(folder, inside: $0) }) {
            kept.append(folder)
        }
        return kept
    }

    /// The scanned directory closest to `path`, walking up; the root if none is.
    func nearestScannedAncestor(of path: String) -> String {
        var candidate = path
        while candidate != root, StorageScanner.isPath(candidate, inside: root) {
            if directories[candidate] != nil { return candidate }
            candidate = StorageScanner.parent(of: candidate)
        }
        return root
    }

    /// Directories outside `folder` holding names of hard-linked objects that have fewer names inside `folder` in
    /// `rescanned` than in this snapshot.
    func foldersWithRelinkedNames(inside folder: String, after rescanned: StorageSnapshot) -> [String] {
        var folders: [String] = []
        for (identity, record) in hardLinks {
            let inside = record.directories.filter { StorageScanner.isPath($0, inside: folder) }
            guard !inside.isEmpty, (rescanned.hardLinks[identity]?.directories.count ?? 0) < inside.count else {
                continue
            }
            for directory in record.directories
            where !StorageScanner.isPath(directory, inside: folder) && !folders.contains(directory) {
                folders.append(directory)
            }
        }
        return folders.sorted()
    }

    /// This snapshot with the subtree at `rescanned.root` replaced by `rescanned`, and every ancestor's aggregate
    /// recomputed from its own entries, its children and the hard-linked objects below it.
    func replacingSubtree(with rescanned: StorageSnapshot, maxLargeFiles: Int) -> StorageSnapshot {
        let folder = rescanned.root
        if folder == root { return rescanned }
        guard directories[folder] != nil, StorageScanner.isPath(folder, inside: root) else { return self }
        func isReplaced(_ path: String) -> Bool { StorageScanner.isPath(path, inside: folder) }

        var directories = self.directories.filter { !isReplaced($0.key) }
        directories.merge(rescanned.directories) { _, new in new }
        var subtrees = self.subtrees.filter { !isReplaced($0.key) }
        subtrees.merge(rescanned.subtrees) { _, new in new }

        var hardLinks: [FileIdentity: HardLinkRecord] = [:]
        for (identity, record) in self.hardLinks {
            let kept = record.directories.filter { !isReplaced($0) }
            if !kept.isEmpty { hardLinks[identity] = HardLinkRecord(size: record.size, directories: kept) }
        }
        for (identity, record) in rescanned.hardLinks {
            let earlier = hardLinks[identity]?.directories ?? []
            hardLinks[identity] = HardLinkRecord(size: record.size, directories: earlier + record.directories)
        }

        let ancestors = Self.ancestors(of: folder, below: root)
        for ancestor in ancestors {
            guard let totals = subtrees[ancestor], let aggregate = directories[ancestor] else { continue }
            var subtree = totals.own
            for name in aggregate.childDirectoryNames {
                if let child = subtrees[Self.join(ancestor, name)] { subtree.add(child.subtree.asChild) }
            }
            subtrees[ancestor] = SubtreeTotals(own: totals.own, subtree: subtree)
        }

        let linked = Self.hardLinkedBytes(in: ancestors, records: hardLinks.values)
        for (index, ancestor) in ancestors.enumerated() {
            guard let totals = subtrees[ancestor]?.subtree, let aggregate = directories[ancestor] else { continue }
            directories[ancestor] = DirectoryAggregate(
                identity: aggregate.identity, allocated: totals.allocated + linked[index].allocated,
                reclaimable: totals.reclaimable, logical: totals.logical + linked[index].logical,
                fileCount: totals.fileCount, directoryCount: totals.directoryCount,
                latestModification: totals.latestModification, childDirectoryNames: aggregate.childDirectoryNames)
        }

        let largeFiles = LargeFile.trimmed(
            self.largeFiles.filter { !isReplaced($0.path) } + rescanned.largeFiles, limit: maxLargeFiles)
        return StorageSnapshot(
            root: root, directories: directories, largeFiles: largeFiles,
            skipped: skipped.filter { !isReplaced($0.path) } + rescanned.skipped,
            isComplete: isComplete && rescanned.isComplete, subtrees: subtrees, hardLinks: hardLinks)
    }

    /// Strict ancestors of `folder` up to and including `root`, deepest first.
    private static func ancestors(of folder: String, below root: String) -> [String] {
        var result: [String] = []
        var current = folder
        while current != root {
            current = StorageScanner.parent(of: current)
            result.append(current)
        }
        return result
    }

    /// For each of `ancestors` (deepest first, each inside the next), the bytes of hard-linked objects with at least
    /// one name in its subtree, each object counted once.
    private static func hardLinkedBytes(
        in ancestors: [String], records: some Sequence<HardLinkRecord>
    ) -> [(allocated: Int64, logical: Int64)] {
        var bytes = Array(repeating: (allocated: Int64(0), logical: Int64(0)), count: ancestors.count)
        for record in records {
            var deepest = ancestors.count
            for directory in record.directories {
                let index = ancestors.prefix(deepest).firstIndex { StorageScanner.isPath(directory, inside: $0) }
                if let index { deepest = index }
            }
            for index in deepest..<ancestors.count {
                bytes[index].allocated += record.size.allocated
                bytes[index].logical += record.size.logical
            }
        }
        return bytes
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }
}
