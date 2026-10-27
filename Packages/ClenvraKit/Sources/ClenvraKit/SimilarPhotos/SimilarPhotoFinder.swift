import Accelerate
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import Vision

/// Finds images that look alike (re-encoded, resized or re-saved copies of one picture) in user-chosen folders.
///
/// Pipeline: list regular image files (never following links, crossing volumes or entering a Photos library) →
/// collapse hard links → read each file through a descriptor opened without following links and checked against its
/// listing snapshot → decode a small thumbnail → Vision feature print → cluster around seeds. At most
/// `maximumConcurrentAnalyses` images are read and analysed at once; file reads run on the `FSExecutor`. Nothing is
/// modified.
public enum SimilarPhotoFinder {
    /// Squared distance between Vision feature prints (revision 2: unit vectors, so 0 … 4) at or below which two
    /// images are similar. Measured on fixtures: re-encoded or resized copies of one picture land between 0.005 and
    /// 0.46 (the high end for a heavily downscaled JPEG), clearly different pictures at 0.67 and above. 0.5 sits in
    /// that gap; nothing is ever removed without review, so a slightly generous value costs only a look.
    public static let defaultDistanceThreshold = 0.5
    /// Longest side of the decoded thumbnail; Vision scales its input down further, so more pixels add only cost.
    static let thumbnailSize = 512
    /// Folder names (lower-cased) and extensions whose insides are never scanned.
    private static let skippedFolderNames: Set<String> = [".git"]
    private static let skippedFolderExtensions: Set<String> = ["app", "photoslibrary"]

    /// Scans `roots` read-only. Cancelling the calling task returns early with `isComplete == false` and no groups.
    public static func scan(
        roots: [String],
        options: SimilarPhotoScanOptions = SimilarPhotoScanOptions(),
        policy: ProtectionPolicy,
        executor: FSExecutor = .shared,
        progress: @escaping @Sendable (SimilarPhotoScanProgress) -> Void = { _ in }
    ) async -> SimilarPhotoScanResult {
        let counters = Counters()
        var skipped: [String: SimilarPhotoSkipReason] = [:]
        func incomplete() -> SimilarPhotoScanResult {
            SimilarPhotoScanResult(groups: [], skipped: skipped, isComplete: false)
        }
        guard !Task.isCancelled else { return incomplete() }

        progress(counters.progress(.listing))
        let listed = await list(roots: roots, options: options, policy: policy, executor: executor, counters: counters)
        {
            progress(counters.progress(.listing))
        }
        skipped.merge(listed.skipped) { first, _ in first }
        guard listed.isComplete, !Task.isCancelled else { return incomplete() }

        progress(counters.progress(.analyzing))
        let analysed = await analyzeAll(listed.candidates, options: options, executor: executor) {
            counters.imagesAnalyzed.add(1, ordering: .relaxed)
            progress(counters.progress(.analyzing))
        }
        var photos: [(photo: SimilarPhoto, vector: [Float])] = []
        for (candidate, analysis) in zip(listed.candidates, analysed) {
            switch analysis {
            case .analysed(let vector, let width, let height)?:
                photos.append((candidate.photo(width: width, height: height), vector))
            case .skipped(let reason)?:
                skipped[candidate.path] = reason
            case .changed?:
                break
            case .cancelled?, nil:
                return incomplete()
            }
        }
        guard !Task.isCancelled else { return incomplete() }

        progress(counters.progress(.grouping))
        // Seeds are taken in keeper order, so every group is built around the image it would suggest keeping.
        photos.sort { isPreferred($0.photo, over: $1.photo) }
        var groups: [SimilarPhotoGroup] = []
        for members in cluster(photos.map(\.vector), threshold: options.distanceThreshold) {
            if let group = makeGroup(members.map { photos[$0].photo }) { groups.append(group) }
        }
        groups.sort { ($0.reclaimableIfOthersRemoved, $1.id) > ($1.reclaimableIfOthersRemoved, $0.id) }
        return SimilarPhotoScanResult(groups: groups, skipped: skipped, isComplete: !Task.isCancelled)
    }

    // MARK: - Pure decisions (unit-tested)

    /// Whether a file name's extension names an image type the system knows.
    static func isImageName(_ name: String) -> Bool {
        let fileExtension = (name as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// The image to keep by default: the most pixels (the best copy), then the newest, then the smallest path.
    static func suggestedKeeper(among photos: [SimilarPhoto]) -> SimilarPhoto? {
        photos.min { isPreferred($0, over: $1) }
    }

    private static func isPreferred(_ lhs: SimilarPhoto, over rhs: SimilarPhoto) -> Bool {
        if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
        if lhs.modificationDate != rhs.modificationDate { return lhs.modificationDate > rhs.modificationDate }
        return lhs.path < rhs.path
    }

    /// Groups of indices (two or more) built around seeds in input order: each not-yet-grouped vector collects every
    /// later not-yet-grouped vector within `threshold` of it. Unlike linking neighbours, a chain of small steps
    /// cannot join two pictures that are far apart.
    static func cluster(_ vectors: [[Float]], threshold: Double) -> [[Int]] {
        var grouped = [Bool](repeating: false, count: vectors.count)
        var clusters: [[Int]] = []
        for seed in vectors.indices where !grouped[seed] {
            grouped[seed] = true
            var members = [seed]
            for other in vectors.indices.dropFirst(seed + 1)
            where !grouped[other] && distance(vectors[seed], vectors[other]) <= threshold {
                grouped[other] = true
                members.append(other)
            }
            if members.count > 1 { clusters.append(members) }
        }
        return clusters
    }

    /// Squared Euclidean distance, the measure `FeaturePrintObservation.distance(to:)` reports.
    static func distance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        var result: Float = 0
        vDSP_distancesq(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return Double(result)
    }

    /// The feature print's elements, or `nil` when its data does not hold what it claims.
    static func vector(of print: FeaturePrintObservation) -> [Float]? {
        let data = print.data
        let count = print.elementCount
        switch print.elementType {
        case .float:
            guard count > 0, data.count == count * MemoryLayout<Float>.size else { return nil }
            return data.withUnsafeBytes { bytes in
                (0..<count).map { bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
            }
        case .double:
            guard count > 0, data.count == count * MemoryLayout<Double>.size else { return nil }
            return data.withUnsafeBytes { bytes in
                (0..<count).map {
                    Float(bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Double>.size, as: Double.self))
                }
            }
        @unknown default:
            return nil
        }
    }

    private static func makeGroup(_ photos: [SimilarPhoto]) -> SimilarPhotoGroup? {
        guard photos.count > 1, let keeper = suggestedKeeper(among: photos) else { return nil }
        let others = photos.filter { $0.path != keeper.path }.sorted { $0.path < $1.path }
        return SimilarPhotoGroup(id: keeper.path, photos: [keeper] + others, suggestedKeeper: keeper.path)
    }

    // MARK: - Listing

    private enum EntryAction {
        case consider
        case descend
        case ignore
    }

    /// What to do with one listed entry. Symlinks and special files are never considered or followed.
    private static func classify(
        _ entry: FileEntry, at path: String, rootDevice: Int32, options: SimilarPhotoScanOptions,
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
            guard entry.size.logical > 0, entry.flags & UInt32(SF_DATALESS) == 0, isImageName(entry.name) else {
                return .ignore
            }
            return policy.protection(for: path) == nil ? .consider : .ignore
        case .symlink, .other:
            return .ignore
        }
    }

    /// Whether everything inside `directory` is protected (home-root protection covers only the folder itself).
    private static func isProtectedTree(_ directory: String, policy: ProtectionPolicy) -> Bool {
        guard policy.protection(for: directory) != nil else { return false }
        guard let reason = policy.protection(for: join(directory, "clenvra-probe")) else { return false }
        return reason != .homeRoot
    }

    private static func isInsidePhotosLibrary(_ path: String) -> Bool {
        path.split(separator: "/").contains { ($0.lowercased() as NSString).pathExtension == "photoslibrary" }
    }

    private static func isExcluded(_ path: String, _ excluded: Set<String>) -> Bool {
        excluded.contains { raw in
            var prefix = raw
            while prefix.count > 1, prefix.hasSuffix("/") { prefix.removeLast() }
            return path == prefix || path.hasPrefix(prefix == "/" ? "/" : prefix + "/")
        }
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

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
        var skipped: [String: SimilarPhotoSkipReason] = [:]
        var seen = 0
    }

    private struct Listing {
        var candidates: [Candidate]
        var skipped: [String: SimilarPhotoSkipReason]
        var isComplete: Bool
    }

    private static func list(
        roots: [String], options: SimilarPhotoScanOptions, policy: ProtectionPolicy, executor: FSExecutor,
        counters: Counters, listed: @Sendable () -> Void
    ) async -> Listing {
        var skipped: [String: SimilarPhotoSkipReason] = [:]
        var queue: [DirectoryJob] = []
        for root in roots {
            guard let canonical = realpath(root, nil) else {
                skipped[root] = .unreadable(errno)
                continue
            }
            let path = String(cString: canonical)
            free(canonical)
            if isExcluded(path, options.excludedPaths) { continue }
            if isInsidePhotosLibrary(path) {
                skipped[path] = .insidePhotosLibrary
            } else if isProtectedTree(path, policy: policy) {
                skipped[path] = .protected
            } else {
                queue.append(DirectoryJob(path: path, expected: nil, rootDevice: nil))
            }
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
                    // Hard-link names of one file are one image: keep the smallest path, deterministically.
                    if let existing = byIdentity[file.entry.identity], existing.path <= file.path { continue }
                    byIdentity[file.entry.identity] = file
                }
                counters.imagesFound.store(byIdentity.count, ordering: .relaxed)
                queue.append(contentsOf: result.children)
                if Task.isCancelled { cancelled = true }
                listed()
            }
        }
        let candidates = byIdentity.values.sorted { $0.path < $1.path }
        return Listing(candidates: candidates, skipped: skipped, isComplete: !cancelled && !Task.isCancelled)
    }

    private static func readDirectory(
        _ job: DirectoryJob, options: SimilarPhotoScanOptions, policy: ProtectionPolicy
    ) -> DirectoryResult {
        var result = DirectoryResult()
        let listing: DirectoryListing
        let identity: FileIdentity
        do {
            let directory = try OpenDirectory(path: job.path)
            identity = try directory.identity()
            listing = try directory.read()
        } catch {
            result.skipped[job.path] = .unreadable(error.code)
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

    // MARK: - Analysis

    private enum Analysis: Sendable {
        case analysed(vector: [Float], width: Int, height: Int)
        case skipped(SimilarPhotoSkipReason)
        /// No longer the file that was listed; dropped.
        case changed
        case cancelled
    }

    private enum Decoding: Sendable {
        case image(CGImage, width: Int, height: Int)
        case skipped(SimilarPhotoSkipReason)
        case changed
    }

    /// Analyses every candidate on at most `maximumConcurrentAnalyses` lanes. Results keep the candidates' order;
    /// `nil` marks a candidate that was never analysed because the task was cancelled.
    private static func analyzeAll(
        _ candidates: [Candidate], options: SimilarPhotoScanOptions, executor: FSExecutor,
        analysed: @escaping @Sendable () -> Void
    ) async -> [Analysis?] {
        guard !candidates.isEmpty else { return [] }
        let next = NextIndex()
        var results = [Analysis?](repeating: nil, count: candidates.count)
        await withTaskGroup(of: [(Int, Analysis)].self) { group in
            for _ in 0..<min(max(1, options.maximumConcurrentAnalyses), candidates.count) {
                group.addTask {
                    var done: [(Int, Analysis)] = []
                    while !Task.isCancelled {
                        let index = next.value.add(1, ordering: .relaxed).oldValue
                        guard index < candidates.count else { break }
                        done.append((index, await analyze(candidates[index], options: options, executor: executor)))
                        analysed()
                    }
                    return done
                }
            }
            for await lane in group {
                for (index, analysis) in lane { results[index] = analysis }
            }
        }
        return results
    }

    private static func analyze(
        _ candidate: Candidate, options: SimilarPhotoScanOptions, executor: FSExecutor
    ) async -> Analysis {
        guard candidate.entry.size.logical <= options.maximumFileSize else { return .skipped(.tooLarge) }
        let decoding: Decoding
        do {
            decoding = try await executor.run { decode(candidate) }
        } catch {
            return .cancelled
        }
        switch decoding {
        case .skipped(let reason):
            return .skipped(reason)
        case .changed:
            return .changed
        case .image(let image, let width, let height):
            do {
                let print = try await GenerateImageFeaturePrintRequest().perform(on: image)
                guard let vector = vector(of: print) else { return .skipped(.analysisFailed) }
                return .analysed(vector: vector, width: width, height: height)
            } catch {
                return Task.isCancelled ? .cancelled : .skipped(.analysisFailed)
            }
        }
    }

    /// Reads the file through a descriptor that refuses symlinks and must match the listing snapshot before and after
    /// reading, then decodes its pixel size and a thumbnail (rotated upright) from those bytes.
    private static func decode(_ candidate: Candidate) -> Decoding {
        let fd = Darwin.open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ELOOP ? .changed : .skipped(.unreadable(errno)) }
        defer { Darwin.close(fd) }
        func matchesListing() -> Bool {
            var info = stat()
            return fstat(fd, &info) == 0 && FileSnapshot(info) == candidate.snapshot
        }
        guard matchesListing() else { return .changed }

        var data = Data(count: Int(candidate.entry.size.logical))
        let readError: Int32? = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return EINVAL }
            var done = 0
            while done < buffer.count {
                let result = Darwin.read(fd, base + done, buffer.count - done)
                if result < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                // Shorter than listed: the file was truncated after listing.
                guard result > 0 else { return 0 }
                done += result
            }
            return nil
        }
        if let readError { return readError == 0 ? .changed : .skipped(.unreadable(readError)) }
        guard matchesListing() else { return .changed }

        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return .skipped(.notDecodable) }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return .skipped(.notDecodable)
        }
        return .image(thumbnail, width: width, height: height)
    }
}

// MARK: - Supporting types

/// An image file found by listing, with the entry that later reads are checked against.
private struct Candidate: Sendable {
    let path: String
    let entry: FileEntry

    var snapshot: FileSnapshot { FileSnapshot(entry) }

    func photo(width: Int, height: Int) -> SimilarPhoto {
        SimilarPhoto(
            path: path, snapshot: snapshot, size: entry.size.logical,
            // Removing one name of a hard-linked file frees nothing; a clone frees only its private blocks.
            reclaimable: entry.linkCount > 1 ? 0 : entry.size.freedIfDeleted,
            modificationDate: entry.modificationDate, pixelWidth: width, pixelHeight: height)
    }
}

private final class NextIndex: Sendable {
    let value = Atomic<Int>(0)
}

private final class Counters: Sendable {
    let filesSeen = Atomic<Int>(0)
    let imagesFound = Atomic<Int>(0)
    let imagesAnalyzed = Atomic<Int>(0)

    func progress(_ phase: SimilarPhotoScanProgress.Phase) -> SimilarPhotoScanProgress {
        SimilarPhotoScanProgress(
            phase: phase, filesSeen: filesSeen.load(ordering: .relaxed),
            imagesFound: imagesFound.load(ordering: .relaxed), imagesAnalyzed: imagesAnalyzed.load(ordering: .relaxed))
    }
}
