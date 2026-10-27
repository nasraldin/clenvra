import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Incremental content digest; a test seam so a forced collision can prove the byte comparison runs.
protocol ContentHasher {
    mutating func update(_ bytes: UnsafeRawBufferPointer)
    func finalize() -> [UInt8]
}

struct SHA256ContentHasher: ContentHasher {
    private var inner = SHA256()

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        inner.update(bufferPointer: bytes)
    }

    func finalize() -> [UInt8] {
        Array(inner.finalize())
    }
}

/// Test seams. Production code always uses the defaults.
struct DuplicateScanHooks: Sendable {
    var makeHasher: @Sendable () -> any ContentHasher = { SHA256ContentHasher() }
    /// Runs once, after listing and before any file is read.
    var afterListing: @Sendable () -> Void = {}
    /// Runs after a candidate group was compared byte for byte and before its files' final snapshot check.
    var beforeFinalCheck: @Sendable () -> Void = {}
}

/// Finds files with byte-identical content in user-chosen folders.
///
/// Pipeline: list regular files (never following links or crossing volumes) → collapse hard links → group by exact
/// size → digest of the first and last 64 KiB → full SHA-256 → byte-for-byte comparison → re-check every file's
/// snapshot. Each stage only reads files that survived the previous one. At most `maximumConcurrentReads` files are
/// read at once, each lane on the `FSExecutor` with one reused 1 MiB buffer pair. Hashes only narrow the search: a
/// group is reported only after its files were compared byte for byte, so a hash collision cannot produce a false
/// group. Nothing is modified.
public enum DuplicateFinder {
    /// Head and tail span of the partial digest; files up to twice this size are fully covered by it.
    static let partialSpan = 64 * 1024
    static let bufferSize = 1024 * 1024
    /// Folder names (lower-cased) and extensions whose insides are never scanned.
    private static let skippedFolderNames: Set<String> = [".git"]
    private static let skippedFolderExtensions: Set<String> = ["app", "photoslibrary"]

    /// Scans `roots` read-only. Cancelling the calling task returns early with `isComplete == false`.
    public static func scan(
        roots: [String],
        options: DuplicateScanOptions = DuplicateScanOptions(),
        policy: ProtectionPolicy,
        executor: FSExecutor = .shared,
        progress: @escaping @Sendable (DuplicateScanProgress) -> Void = { _ in }
    ) async -> DuplicateScanResult {
        await scan(
            roots: roots, options: options, policy: policy, executor: executor, progress: progress,
            hooks: DuplicateScanHooks())
    }

    static func scan(
        roots: [String],
        options: DuplicateScanOptions,
        policy: ProtectionPolicy,
        executor: FSExecutor,
        progress: @escaping @Sendable (DuplicateScanProgress) -> Void,
        hooks: DuplicateScanHooks
    ) async -> DuplicateScanResult {
        let counters = Counters()
        var skipped: [String: Int32] = [:]
        func incomplete() -> DuplicateScanResult {
            DuplicateScanResult(groups: [], skipped: skipped, isComplete: false)
        }
        guard !Task.isCancelled else { return incomplete() }

        // Stages 1 and 2: list, collapsing hard links and overlapping roots by identity.
        progress(counters.progress(.listing))
        let listed = await list(
            roots: roots, options: options, policy: policy, executor: executor, counters: counters,
            progress: progress)
        skipped.merge(listed.skipped) { first, _ in first }
        guard listed.isComplete, !Task.isCancelled else { return incomplete() }
        hooks.afterListing()
        guard !Task.isCancelled else { return incomplete() }

        // Stage 3: only files sharing an exact size can be duplicates.
        let sameSize = Dictionary(grouping: listed.candidates, by: \.size).values.filter { $0.count > 1 }
        counters.candidateFiles.store(sameSize.reduce(0) { $0 + $1.count }, ordering: .relaxed)
        progress(counters.progress(.grouping))

        // Stage 4: head and tail digest.
        progress(counters.progress(.hashing))
        let partial = await digestGroups(
            sameSize, full: false, options: options, executor: executor, hooks: hooks, counters: counters,
            progress: progress)
        skipped.merge(partial.skipped) { first, _ in first }
        guard partial.isComplete else { return incomplete() }

        // Stage 5: full digest, only for files larger than the head and tail together.
        let needsFull = partial.groups.filter { $0.members[0].size > Int64(2 * partialSpan) }
        let full = await digestGroups(
            needsFull.map(\.members), full: true, options: options, executor: executor, hooks: hooks,
            counters: counters, progress: progress)
        skipped.merge(full.skipped) { first, _ in first }
        guard full.isComplete else { return incomplete() }
        let hashGroups = partial.groups.filter { $0.members[0].size <= Int64(2 * partialSpan) } + full.groups

        // Stages 6 and 7: byte-for-byte comparison, then the final snapshot check.
        progress(counters.progress(.verifying))
        let confirmed = await runLanes(hashGroups, lanes: options.maximumConcurrentReads, executor: executor) {
            group, first, second in
            confirm(group, first, second, hooks: hooks)
        }
        var groups: [DuplicateGroup] = []
        var isComplete = !Task.isCancelled
        for outcome in confirmed {
            guard let outcome else {
                isComplete = false
                continue
            }
            skipped.merge(outcome.skipped) { first, _ in first }
            groups += outcome.groups
            if outcome.cancelled { isComplete = false }
        }
        progress(counters.progress(.verifying))

        groups.sort {
            ($0.reclaimableIfOthersRemoved, $0.size, $1.id) > ($1.reclaimableIfOthersRemoved, $1.size, $0.id)
        }
        return DuplicateScanResult(groups: groups, skipped: skipped, isComplete: isComplete)
    }

    // MARK: - Pure decisions (unit-tested)

    enum EntryAction: Equatable {
        /// A regular file worth reading.
        case consider
        /// A folder to list.
        case descend
        case ignore
    }

    /// What to do with one listed entry. Symlinks and special files are never considered or followed.
    static func classify(
        _ entry: FileEntry, at path: String, rootDevice: Int32, options: DuplicateScanOptions,
        policy: ProtectionPolicy
    ) -> EntryAction {
        let hidden = entry.name.hasPrefix(".") || entry.flags & UInt32(UF_HIDDEN) != 0
        if hidden, !options.includeHidden { return .ignore }
        if isExcluded(path, options.excludedPaths) { return .ignore }

        switch entry.kind {
        case .directory:
            if entry.isMountPoint || entry.identity.device != rootDevice { return .ignore }
            let name = entry.name.lowercased()
            if skippedFolderNames.contains(name) { return .ignore }
            if skippedFolderExtensions.contains((name as NSString).pathExtension) { return .ignore }
            return isProtectedTree(path, policy: policy) ? .ignore : .descend
        case .file:
            // A dataless file (e.g. an iCloud placeholder) would be downloaded by reading it.
            guard entry.size.logical >= max(1, options.minimumSize), entry.flags & UInt32(SF_DATALESS) == 0 else {
                return .ignore
            }
            return policy.protection(for: path) == nil ? .consider : .ignore
        case .symlink, .other:
            return .ignore
        }
    }

    /// The copy to keep by default: the oldest modification date, then the shortest path, then the
    /// lexicographically smallest path. The oldest copy is most likely the original the user filed away.
    static func suggestedKeeper(among files: [DuplicateFile]) -> DuplicateFile? {
        files.min { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate { return lhs.modificationDate < rhs.modificationDate }
            if lhs.path.utf8.count != rhs.path.utf8.count { return lhs.path.utf8.count < rhs.path.utf8.count }
            return lhs.path < rhs.path
        }
    }

    /// Whether everything inside `directory` is protected. The policy also protects folders that merely *contain*
    /// a protected item (such as the home folder), so an arbitrary child is probed instead; home-root protection
    /// of direct children is not a reason to skip a folder, only its files.
    private static func isProtectedTree(_ directory: String, policy: ProtectionPolicy) -> Bool {
        guard policy.protection(for: directory) != nil else { return false }
        guard let reason = policy.protection(for: join(directory, "clenvra-probe")) else { return false }
        return reason != .homeRoot
    }

    private static func isExcluded(_ path: String, _ excluded: Set<String>) -> Bool {
        excluded.contains { raw in
            let prefix = normalize(raw)
            return path == prefix || path.hasPrefix(prefix == "/" ? "/" : prefix + "/")
        }
    }

    private static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    // MARK: - Stage 1 and 2: listing

    private struct DirectoryJob: Sendable {
        let path: String
        /// Identity from the parent's listing; `nil` for a root.
        let expected: FileIdentity?
        /// Device of the root this folder belongs to; `nil` for a root.
        let rootDevice: Int32?
    }

    private struct DirectoryResult: Sendable {
        var identity: FileIdentity?
        var files: [Candidate] = []
        var children: [DirectoryJob] = []
        var skipped: [String: Int32] = [:]
        var seen = 0
    }

    private struct Listing {
        var candidates: [Candidate]
        var skipped: [String: Int32]
        var isComplete: Bool
    }

    private static func list(
        roots: [String], options: DuplicateScanOptions, policy: ProtectionPolicy, executor: FSExecutor,
        counters: Counters, progress: @escaping @Sendable (DuplicateScanProgress) -> Void
    ) async -> Listing {
        var skipped: [String: Int32] = [:]
        var queue: [DirectoryJob] = []
        for root in roots {
            guard let canonical = realpath(root, nil) else {
                skipped[normalize(root)] = errno
                continue
            }
            let path = String(cString: canonical)
            free(canonical)
            if isExcluded(path, options.excludedPaths) { continue }
            if isProtectedTree(path, policy: policy) {
                skipped[path] = EPERM
                continue
            }
            queue.append(DirectoryJob(path: path, expected: nil, rootDevice: nil))
        }

        var visited = Set<FileIdentity>()
        var byIdentity: [FileIdentity: Candidate] = [:]
        var cancelled = false
        await withTaskGroup(of: DirectoryResult?.self) { group in
            var head = 0
            var inFlight = 0
            while true {
                while !cancelled, inFlight < executor.width, head < queue.count {
                    let job = queue[head]
                    head += 1
                    group.addTask {
                        try? await executor.run { readDirectory(job, options: options, policy: policy) }
                    }
                    inFlight += 1
                }
                guard inFlight > 0, let next = await group.next() else { break }
                inFlight -= 1
                guard let result = next else {
                    cancelled = true
                    continue
                }
                skipped.merge(result.skipped) { first, _ in first }
                // A folder reached twice (overlapping roots) is merged once.
                guard let identity = result.identity, visited.insert(identity).inserted else { continue }
                counters.filesSeen.add(result.seen, ordering: .relaxed)
                for file in result.files {
                    // Hard-link names of one file are one file: keep the smallest path, deterministically.
                    if let existing = byIdentity[file.entry.identity], existing.path <= file.path { continue }
                    byIdentity[file.entry.identity] = file
                }
                queue.append(contentsOf: result.children)
                if Task.isCancelled { cancelled = true }
                progress(counters.progress(.listing))
            }
        }
        return Listing(
            candidates: Array(byIdentity.values), skipped: skipped, isComplete: !cancelled && !Task.isCancelled)
    }

    private static func readDirectory(
        _ job: DirectoryJob, options: DuplicateScanOptions, policy: ProtectionPolicy
    ) -> DirectoryResult {
        var result = DirectoryResult()
        let listing: DirectoryListing
        let identity: FileIdentity
        do {
            let directory = try OpenDirectory(path: job.path)
            identity = try directory.identity()
            listing = try directory.read()
        } catch {
            result.skipped[job.path] = error.code
            return result
        }
        // A folder replaced by another one between listing its parent and opening it is not scanned.
        if let expected = job.expected, expected != identity { return result }
        result.identity = identity
        let rootDevice = job.rootDevice ?? identity.device

        for entry in listing.entries {
            if entry.kind == .file { result.seen += 1 }
            let path = join(job.path, entry.name)
            switch classify(entry, at: path, rootDevice: rootDevice, options: options, policy: policy) {
            case .consider:
                result.files.append(Candidate(path: path, entry: entry))
            case .descend:
                result.children.append(DirectoryJob(path: path, expected: entry.identity, rootDevice: rootDevice))
            case .ignore:
                break
            }
        }
        return result
    }

    // MARK: - Stages 4 and 5: digests

    private struct HashGroup: Sendable {
        let digest: [UInt8]
        let members: [Candidate]
    }

    private struct DigestStage {
        var groups: [HashGroup]
        var skipped: [String: Int32]
        var isComplete: Bool
    }

    private enum FileOutcome: Sendable {
        case digest([UInt8])
        /// Unreadable; recorded as skipped with this errno.
        case failed(Int32)
        /// No longer the file that was listed; dropped.
        case changed
        case cancelled
    }

    /// Digests every file of every group and regroups each by digest, dropping singletons.
    private static func digestGroups(
        _ groups: [[Candidate]], full: Bool, options: DuplicateScanOptions, executor: FSExecutor,
        hooks: DuplicateScanHooks, counters: Counters,
        progress: @escaping @Sendable (DuplicateScanProgress) -> Void
    ) async -> DigestStage {
        let files = groups.flatMap { $0 }
        let outcomes = await runLanes(files, lanes: options.maximumConcurrentReads, executor: executor) {
            file, buffer, _ in
            let outcome: FileOutcome
            do throws(ReadFailure) {
                var hasher = hooks.makeHasher()
                if full {
                    try fullDigest(file, into: &hasher, buffer: buffer, counters: counters)
                } else {
                    try partialDigest(file, into: &hasher, buffer: buffer, counters: counters)
                }
                outcome = .digest(hasher.finalize())
            } catch {
                switch error {
                case .failed(let code): outcome = .failed(code)
                case .changed: outcome = .changed
                case .cancelled: outcome = .cancelled
                }
            }
            progress(counters.progress(.hashing))
            return outcome
        }

        var stage = DigestStage(groups: [], skipped: [:], isComplete: !Task.isCancelled)
        var byKey: [DigestKey: [Candidate]] = [:]
        for (file, outcome) in zip(files, outcomes) {
            switch outcome {
            case .digest(let digest)?:
                byKey[DigestKey(size: file.size, digest: digest), default: []].append(file)
            case .failed(let code)?:
                stage.skipped[file.path] = code
            case .changed?:
                break
            case .cancelled?, nil:
                stage.isComplete = false
            }
        }
        stage.groups = byKey.compactMap { key, members in
            members.count > 1 ? HashGroup(digest: key.digest, members: members) : nil
        }
        return stage
    }

    private struct DigestKey: Hashable {
        let size: Int64
        let digest: [UInt8]
    }

    /// Digest of the size, the first 64 KiB and the last 64 KiB. Files up to 128 KiB are covered completely.
    private static func partialDigest(
        _ file: Candidate, into hasher: inout any ContentHasher, buffer: UnsafeMutableRawBufferPointer,
        counters: Counters
    ) throws(ReadFailure) {
        let opened = try ReadableFile(file)
        let size = Int(file.size)
        withUnsafeBytes(of: file.size.littleEndian) { hasher.update($0) }
        let headCount = min(size, partialSpan)
        let tailStart = max(headCount, size - partialSpan)
        for (offset, count) in [(0, headCount), (tailStart, size - tailStart)] where count > 0 {
            try opened.read(into: buffer, count: count, at: Int64(offset))
            hasher.update(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            counters.bytesHashed.add(Int64(count), ordering: .relaxed)
        }
        try opened.verify()
    }

    /// Streaming digest of the whole content with sequential `read(2)` calls into the lane's reused buffer.
    private static func fullDigest(
        _ file: Candidate, into hasher: inout any ContentHasher, buffer: UnsafeMutableRawBufferPointer,
        counters: Counters
    ) throws(ReadFailure) {
        let opened = try ReadableFile(file)
        var remaining = file.size
        while remaining > 0 {
            if Task.isCancelled { throw .cancelled }
            let count = Int(min(remaining, Int64(buffer.count)))
            try opened.read(into: buffer, count: count, at: nil)
            hasher.update(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            counters.bytesHashed.add(Int64(count), ordering: .relaxed)
            remaining -= Int64(count)
        }
        try opened.verify()
    }

    // MARK: - Stages 6 and 7: byte comparison and final check

    private struct Confirmation: Sendable {
        var groups: [DuplicateGroup] = []
        var skipped: [String: Int32] = [:]
        var cancelled = false
    }

    private enum Comparison {
        case equal
        case different
        /// This path can no longer be used; `code` is set when it could not be read at all.
        case unusable(path: String, code: Int32?)
        case cancelled
    }

    /// Splits one digest group into classes of byte-identical files (a collision yields several classes), then keeps
    /// only files whose snapshot still matches the listing.
    private static func confirm(
        _ group: HashGroup, _ first: UnsafeMutableRawBufferPointer, _ second: UnsafeMutableRawBufferPointer,
        hooks: DuplicateScanHooks
    ) -> Confirmation {
        var confirmation = Confirmation()
        var classes: [[Candidate]] = []
        var deadClasses = Set<Int>()

        candidates: for file in group.members.sorted(by: { $0.path < $1.path }) {
            for index in classes.indices where !deadClasses.contains(index) {
                let representative = classes[index][0]
                switch compare(representative, file, first, second) {
                case .equal:
                    classes[index].append(file)
                    continue candidates
                case .different:
                    continue
                case .unusable(let path, let code):
                    if let code { confirmation.skipped[path] = code }
                    // The members so far were only proven equal to the representative, so the class is dropped.
                    guard path == representative.path else { continue candidates }
                    deadClasses.insert(index)
                case .cancelled:
                    confirmation.cancelled = true
                    return confirmation
                }
            }
            classes.append([file])
        }

        hooks.beforeFinalCheck()
        let hex = group.digest.map { String(format: "%02x", $0) }.joined()
        for (index, members) in classes.enumerated() where !deadClasses.contains(index) && members.count > 1 {
            let unchanged = members.filter(isUnchanged)
            guard unchanged.count > 1 else { continue }
            let id = "\(hex)-\(members[0].size)" + (index > 0 ? "-\(index)" : "")
            if let duplicate = makeGroup(id: id, unchanged) { confirmation.groups.append(duplicate) }
        }
        return confirmation
    }

    private static func compare(
        _ lhs: Candidate, _ rhs: Candidate, _ first: UnsafeMutableRawBufferPointer,
        _ second: UnsafeMutableRawBufferPointer
    ) -> Comparison {
        func unusable(_ file: Candidate, _ error: ReadFailure) -> Comparison {
            switch error {
            case .failed(let code): .unusable(path: file.path, code: code)
            case .changed: .unusable(path: file.path, code: nil)
            case .cancelled: .cancelled
            }
        }
        let left: ReadableFile
        let right: ReadableFile
        do throws(ReadFailure) { left = try ReadableFile(lhs) } catch { return unusable(lhs, error) }
        do throws(ReadFailure) { right = try ReadableFile(rhs) } catch { return unusable(rhs, error) }

        var remaining = lhs.size
        while remaining > 0 {
            if Task.isCancelled { return .cancelled }
            let count = Int(min(remaining, Int64(first.count)))
            do throws(ReadFailure) { try left.read(into: first, count: count, at: nil) } catch {
                return unusable(lhs, error)
            }
            do throws(ReadFailure) { try right.read(into: second, count: count, at: nil) } catch {
                return unusable(rhs, error)
            }
            guard let a = first.baseAddress, let b = second.baseAddress, memcmp(a, b, count) == 0 else {
                return .different
            }
            remaining -= Int64(count)
        }
        do throws(ReadFailure) { try left.verify() } catch { return unusable(lhs, error) }
        do throws(ReadFailure) { try right.verify() } catch { return unusable(rhs, error) }
        return .equal
    }

    /// Stage 7: walks to the path again without following symlinks and compares with the listing snapshot.
    private static func isUnchanged(_ file: Candidate) -> Bool {
        guard let item = try? SafeWalk.resolve(file.path) else { return false }
        return item.snapshot == file.snapshot
    }

    private static func makeGroup(id: String, _ members: [Candidate]) -> DuplicateGroup? {
        let files = members.map { member in
            let entry = member.entry
            return DuplicateFile(
                path: member.path, snapshot: member.snapshot, size: entry.size.logical,
                allocated: entry.size.allocated,
                // Removing one name of a hard-linked file frees nothing; a clone frees only its private blocks.
                reclaimable: entry.linkCount > 1 ? 0 : entry.size.freedIfDeleted,
                modificationDate: entry.modificationDate, cloneID: entry.cloneID)
        }
        guard let keeper = suggestedKeeper(among: files) else { return nil }
        let others = files.filter { $0.path != keeper.path }.sorted { $0.path < $1.path }
        return DuplicateGroup(
            id: id, size: keeper.size, files: [keeper] + others, suggestedKeeper: keeper.path,
            reclaimableIfOthersRemoved: others.reduce(0) { $0 + $1.reclaimable })
    }

    // MARK: - Bounded readers

    /// Runs `body` over `jobs` on at most `lanes` executor threads. Each lane owns two 1 MiB buffers for its whole
    /// life, so memory stays fixed however many files are read. Results keep the jobs' order; `nil` marks a job
    /// that never ran because the task was cancelled.
    private static func runLanes<Job: Sendable, Output: Sendable>(
        _ jobs: [Job], lanes: Int, executor: FSExecutor,
        _ body:
            @escaping @Sendable (Job, UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer) -> Output
    ) async -> [Output?] {
        guard !jobs.isEmpty else { return [] }
        let state = LaneState<Output>(count: jobs.count)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(max(1, lanes), jobs.count) {
                group.addTask {
                    _ = try? await executor.run {
                        let first = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)
                        let second = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)
                        defer {
                            first.deallocate()
                            second.deallocate()
                        }
                        while !Task.isCancelled {
                            let index = state.next.add(1, ordering: .relaxed).oldValue
                            guard index < jobs.count else { break }
                            let output = body(jobs[index], first, second)
                            state.outputs.withLock { $0[index] = output }
                        }
                    }
                }
            }
        }
        return state.outputs.withLock { $0 }
    }
}

// MARK: - Supporting types

/// A file found by listing, with the entry that later reads are checked against.
private struct Candidate: Sendable {
    let path: String
    let entry: FileEntry

    var size: Int64 { entry.size.logical }
    var snapshot: FileSnapshot { FileSnapshot(entry) }
}

private enum ReadFailure: Error {
    case failed(Int32)
    case changed
    case cancelled
}

/// A regular file opened without following a symlink, checked against its listing snapshot on open and after reading.
private struct ReadableFile: ~Copyable {
    private let fd: Int32
    private let expected: FileSnapshot

    init(_ file: Candidate) throws(ReadFailure) {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? .changed : .failed(errno) }
        if let failure = Self.mismatch(fd, file.snapshot) {
            Darwin.close(fd)
            throw failure
        }
        self.fd = fd
        expected = file.snapshot
    }

    deinit {
        Darwin.close(fd)
    }

    /// Fails with `.changed` if the open file is no longer the one that was listed (identity, size or date).
    func verify() throws(ReadFailure) {
        if let failure = Self.mismatch(fd, expected) { throw failure }
    }

    private static func mismatch(_ fd: Int32, _ expected: FileSnapshot) -> ReadFailure? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failed(errno) }
        return FileSnapshot(info) == expected ? nil : .changed
    }

    /// Fills the first `count` bytes of `buffer`, from `offset` with `pread(2)` or sequentially with `read(2)`.
    func read(into buffer: UnsafeMutableRawBufferPointer, count: Int, at offset: Int64?) throws(ReadFailure) {
        guard let base = buffer.baseAddress, count <= buffer.count else { throw .failed(EINVAL) }
        var done = 0
        while done < count {
            let result =
                if let offset {
                    pread(fd, base + done, count - done, offset + Int64(done))
                } else {
                    Darwin.read(fd, base + done, count - done)
                }
            if result < 0 {
                if errno == EINTR { continue }
                throw .failed(errno)
            }
            // Shorter than listed: the file was truncated after listing.
            guard result > 0 else { throw .changed }
            done += result
        }
    }
}

private final class LaneState<Output: Sendable>: Sendable {
    let next = Atomic<Int>(0)
    let outputs: Mutex<[Output?]>

    init(count: Int) {
        outputs = Mutex([Output?](repeating: nil, count: count))
    }
}

private final class Counters: Sendable {
    let filesSeen = Atomic<Int>(0)
    let candidateFiles = Atomic<Int>(0)
    let bytesHashed = Atomic<Int64>(0)

    func progress(_ phase: DuplicateScanProgress.Phase) -> DuplicateScanProgress {
        DuplicateScanProgress(
            phase: phase, filesSeen: filesSeen.load(ordering: .relaxed),
            candidateFiles: candidateFiles.load(ordering: .relaxed), bytesHashed: bytesHashed.load(ordering: .relaxed))
    }
}
