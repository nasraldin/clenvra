import Darwin
import Foundation

/// Read-only walk of a folder tree that produces per-directory subtree totals, the largest files and skip reasons.
///
/// Directories are read breadth-first with at most `executor.width` reads in flight, each on the executor so
/// blocking syscalls stay off the cooperative pool. Memory is O(directories): only per-directory totals,
/// hard-linked identities and the bounded large-file list are kept, never a node per file.
public enum StorageScanner {
    /// Scans `root` without modifying anything; throws only if the root itself cannot be opened and read.
    /// Cancelling the calling task returns a partial snapshot with `isComplete == false`.
    @concurrent public static func scan(
        root: String,
        options: ScanOptions = ScanOptions(),
        executor: FSExecutor = .shared,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> StorageSnapshot {
        let rootPath = normalize(root)
        let context = ScanContext(
            threshold: options.largeFileThreshold,
            excludedPaths: Set(options.excludedPaths.map(normalize)))
        var state = ScanState(root: rootPath, maxLargeFiles: max(0, options.maxLargeFiles))

        let rootJob = DirectoryJob(path: rootPath, parent: nil, name: rootPath, depth: 0, expected: nil)
        let rootOutcome: JobOutcome
        do {
            rootOutcome = try await executor.run { try examine(rootJob, rootDevice: nil, context: context) }
        } catch is CancellationError {
            return state.snapshot(isComplete: false)
        }
        guard case .listed(let rootResult) = rootOutcome else {
            throw FileSystemError(code: ENOENT, operation: "open", path: rootPath)
        }
        state.merge(rootResult)
        let rootDevice = rootResult.identity.device

        var queue = JobQueue()
        queue.append(contentsOf: rootResult.children)
        var cancelled = false
        let clock = ContinuousClock()
        var lastProgress = clock.now

        await withTaskGroup(of: JobOutcome.self) { @concurrent group in
            var inFlight = 0
            while true {
                while !cancelled, inFlight < executor.width, let job = queue.popFirst() {
                    group.addTask { @concurrent in
                        await readChild(job, rootDevice: rootDevice, context: context, executor: executor)
                    }
                    inFlight += 1
                }
                guard inFlight > 0, let outcome = await group.next() else { break }
                inFlight -= 1

                switch outcome {
                case .listed(let result):
                    state.merge(result)
                    if !cancelled { queue.append(contentsOf: result.children) }
                case .skipped(let skip):
                    state.skipped.append(skip)
                case .cancelled:
                    cancelled = true
                }
                if !cancelled, Task.isCancelled {
                    cancelled = true
                    group.cancelAll()
                }
                if clock.now - lastProgress >= options.progressInterval {
                    lastProgress = clock.now
                    progress(state.progress)
                }
            }
        }

        progress(state.progress)
        return state.snapshot(isComplete: !cancelled && queue.isEmpty)
    }

    // MARK: - Pure decisions (unit-tested)

    /// Why a listed subdirectory must not be descended into, or `nil` to descend.
    static func decision(
        forDirectory entry: FileEntry, at path: String, rootDevice: Int32, excludedPaths: Set<String>
    ) -> SkippedPath.Reason? {
        if excludedPaths.contains(path) { return .excluded }
        if entry.isMountPoint || entry.identity.device != rootDevice { return .mountPoint }
        return nil
    }

    /// Detects a directory replaced between the parent's listing and opening it by path.
    static func identityMismatch(expected: FileIdentity, actual: FileIdentity) -> SkippedPath.Reason? {
        expected == actual ? nil : .changedDuringScan
    }

    /// Maps a failed open or read to the reason shown to the user.
    static func reason(for error: FileSystemError) -> SkippedPath.Reason {
        switch error.code {
        case EACCES, EPERM: .permissionDenied
        case ENOENT, ENOTDIR, ELOOP: .changedDuringScan
        default: .error(error.code)
        }
    }

    /// Absolute path without trailing slashes ("/" stays "/").
    static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    // MARK: - Reading one directory

    @concurrent private static func readChild(
        _ job: DirectoryJob, rootDevice: Int32, context: ScanContext, executor: FSExecutor
    ) async -> JobOutcome {
        do {
            return try await executor.run { try examine(job, rootDevice: rootDevice, context: context) }
        } catch let error as FileSystemError {
            return .skipped(SkippedPath(path: job.path, reason: reason(for: error)))
        } catch {
            return .cancelled
        }
    }

    /// Opens, verifies and summarises one directory. The fd is closed before returning.
    private static func examine(
        _ job: DirectoryJob, rootDevice: Int32?, context: ScanContext
    ) throws(FileSystemError) -> JobOutcome {
        let directory = try OpenDirectory(path: job.path)
        let identity = try directory.identity()
        if let expected = job.expected, let reason = identityMismatch(expected: expected, actual: identity) {
            return .skipped(SkippedPath(path: job.path, reason: reason))
        }
        let listing = try directory.read()
        return .listed(
            summarize(
                listing, of: job, identity: identity, rootDevice: rootDevice ?? identity.device, context: context))
    }

    private static func summarize(
        _ listing: DirectoryListing, of job: DirectoryJob, identity: FileIdentity, rootDevice: Int32,
        context: ScanContext
    ) -> DirectoryResult {
        var result = DirectoryResult(job: job, identity: identity)
        for entry in listing.entries {
            let path = join(job.path, entry.name)
            if entry.kind == .directory {
                if let reason = decision(
                    forDirectory: entry, at: path, rootDevice: rootDevice, excludedPaths: context.excludedPaths)
                {
                    result.skipped.append(SkippedPath(path: path, reason: reason))
                } else {
                    result.children.append(
                        DirectoryJob(
                            path: path, parent: job.path, name: entry.name, depth: job.depth + 1,
                            expected: entry.identity))
                }
                continue
            }

            result.own.fileCount += 1
            result.own.include(entry.modificationDate)
            if entry.linkCount > 1 {
                result.hardLinks.append(HardLinkName(identity: entry.identity, size: entry.size))
            } else {
                result.own.allocated += entry.size.allocated
                result.own.logical += entry.size.logical
                result.own.reclaimable += entry.size.freedIfDeleted
            }
            if entry.kind == .file, entry.size.allocated >= context.threshold {
                result.largeFiles.append(
                    LargeFile(
                        path: path, size: entry.size, modificationDate: entry.modificationDate,
                        identity: entry.identity, linkCount: entry.linkCount))
            }
        }
        if listing.unreadableCount > 0 {
            result.skipped.append(SkippedPath(path: job.path, reason: .unreadableEntries(listing.unreadableCount)))
        }
        return result
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }
}

// MARK: - Walk state

private struct ScanContext: Sendable {
    let threshold: Int64
    let excludedPaths: Set<String>
}

private struct DirectoryJob: Sendable {
    let path: String
    let parent: String?
    let name: String
    let depth: Int
    /// Identity from the parent's listing; `nil` for the root.
    let expected: FileIdentity?
}

private enum JobOutcome: Sendable {
    case listed(DirectoryResult)
    case skipped(SkippedPath)
    case cancelled
}

private struct HardLinkName: Sendable {
    let identity: FileIdentity
    let size: SizeInfo
}

private struct DirectoryResult: Sendable {
    let job: DirectoryJob
    let identity: FileIdentity
    /// Directly contained entries, excluding the bytes of hard-linked files (added once per subtree at roll-up).
    var own = ScanTotals()
    var hardLinks: [HardLinkName] = []
    var largeFiles: [LargeFile] = []
    var children: [DirectoryJob] = []
    var skipped: [SkippedPath] = []

    init(job: DirectoryJob, identity: FileIdentity) {
        self.job = job
        self.identity = identity
    }
}

private struct DirectoryNode {
    let parent: String?
    let name: String
    let depth: Int
    let identity: FileIdentity
    let own: ScanTotals
}

/// Breadth-first FIFO of directories waiting to be read.
private struct JobQueue {
    private var items: [DirectoryJob] = []
    private var head = 0

    var isEmpty: Bool { head == items.count }

    mutating func append(contentsOf jobs: [DirectoryJob]) {
        items.append(contentsOf: jobs)
    }

    mutating func popFirst() -> DirectoryJob? {
        guard head < items.count else { return nil }
        let job = items[head]
        head += 1
        if head >= 1_024, head * 2 >= items.count {
            items.removeFirst(head)
            head = 0
        }
        return job
    }
}

/// Everything the walk accumulates; merged serially on the scanning task, rolled up once at the end.
private struct ScanState {
    let root: String
    let maxLargeFiles: Int
    private var nodes: [String: DirectoryNode] = [:]
    private var hardLinks: [FileIdentity: HardLinkRecord] = [:]
    private var largeFiles: [LargeFile] = []
    var skipped: [SkippedPath] = []
    private var filesScanned = 0
    private var allocatedSeen: Int64 = 0
    private var currentDirectory: String

    init(root: String, maxLargeFiles: Int) {
        self.root = root
        self.maxLargeFiles = maxLargeFiles
        currentDirectory = root
    }

    var progress: ScanProgress {
        ScanProgress(
            filesScanned: filesScanned, directoriesScanned: nodes.count, allocatedBytesSeen: allocatedSeen,
            currentDirectory: currentDirectory)
    }

    mutating func merge(_ result: DirectoryResult) {
        let job = result.job
        nodes[job.path] = DirectoryNode(
            parent: job.parent, name: job.name, depth: job.depth, identity: result.identity, own: result.own)
        for link in result.hardLinks {
            hardLinks[link.identity, default: HardLinkRecord(size: link.size, directories: [])]
                .directories.append(job.path)
            allocatedSeen += link.size.allocated
        }
        largeFiles.append(contentsOf: result.largeFiles)
        if largeFiles.count > max(2 * maxLargeFiles, 64) { trimLargeFiles() }
        skipped.append(contentsOf: result.skipped)
        filesScanned += result.own.fileCount
        allocatedSeen += result.own.allocated
        currentDirectory = job.path
    }

    private mutating func trimLargeFiles() {
        largeFiles = LargeFile.trimmed(largeFiles, limit: maxLargeFiles)
    }

    /// Rolls per-directory totals up to their ancestors (deepest first) and adds each hard-linked object once
    /// to every directory whose subtree holds a name of it. Hard-linked bytes are never reclaimable.
    mutating func snapshot(isComplete: Bool) -> StorageSnapshot {
        var totals = nodes.mapValues(\.own)
        var childNames: [String: [String]] = [:]
        for (path, node) in nodes.sorted(by: { $0.value.depth > $1.value.depth }) {
            guard let parent = node.parent, let subtree = totals[path], totals[parent] != nil else { continue }
            totals[parent]?.add(subtree.asChild)
            childNames[parent, default: []].append(node.name)
        }
        var subtrees: [String: SubtreeTotals] = [:]
        subtrees.reserveCapacity(nodes.count)
        for (path, node) in nodes {
            subtrees[path] = SubtreeTotals(own: node.own, subtree: totals[path] ?? node.own)
        }

        for record in hardLinks.values {
            var counted = Set<String>()
            for directory in record.directories {
                var current: String? = directory
                while let path = current, counted.insert(path).inserted {
                    totals[path]?.allocated += record.size.allocated
                    totals[path]?.logical += record.size.logical
                    current = nodes[path]?.parent
                }
            }
        }

        trimLargeFiles()
        var directories: [String: DirectoryAggregate] = [:]
        directories.reserveCapacity(nodes.count)
        for (path, node) in nodes {
            guard let total = totals[path] else { continue }
            directories[path] = DirectoryAggregate(
                identity: node.identity, allocated: total.allocated, reclaimable: total.reclaimable,
                logical: total.logical, fileCount: total.fileCount, directoryCount: total.directoryCount,
                latestModification: total.latestModification,
                childDirectoryNames: (childNames[path] ?? []).sorted())
        }
        return StorageSnapshot(
            root: root, directories: directories, largeFiles: largeFiles, skipped: skipped, isComplete: isComplete,
            subtrees: subtrees, hardLinks: hardLinks)
    }
}
