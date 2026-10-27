import Darwin
import Foundation
import Synchronization

/// Answers "is the app that owns this item running?" for the deletion gate.
///
/// An app counts as running when its bundle identifier is reported as running, or when any process executable lives
/// inside its bundle (helpers, agents and XPC services are often not reported as applications). When processes
/// cannot be listed, or the bundle location is unknown, the answer is `.unknown`, which the gate treats as running.
public final class OwnerActivity: Sendable {
    private let bundlePaths: [String: String]
    private let runningBundleIdentifiers: @Sendable () -> Set<String>
    private let processPaths: @Sendable () -> [String]?
    private let cache = Mutex<(date: ContinuousClock.Instant, paths: [String]?)?>(nil)
    private static let cacheLifetime = Duration.seconds(1)

    /// - Parameters:
    ///   - bundlePaths: bundle identifier → canonical bundle path, from the app inventory.
    ///   - runningBundleIdentifiers: identifiers macOS reports as running (the app layer passes `NSWorkspace` data).
    ///   - processPaths: executable paths of all processes; `nil` means "could not list".
    public init(
        bundlePaths: [String: String],
        runningBundleIdentifiers: @escaping @Sendable () -> Set<String> = { [] },
        processPaths: @escaping @Sendable () -> [String]? = OwnerActivity.currentProcessPaths
    ) {
        self.bundlePaths = bundlePaths
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.processPaths = processPaths
    }

    public func state(of bundleIdentifier: String) -> OwnerState {
        if runningBundleIdentifiers().contains(bundleIdentifier) { return .running }
        guard let bundlePath = bundlePaths[bundleIdentifier] else { return .unknown }
        guard let paths = recentProcessPaths() else { return .unknown }
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        return paths.contains { $0.hasPrefix(prefix) } ? .running : .notRunning
    }

    /// Executable paths of every process this user can see; `nil` if the process table cannot be read.
    public static func currentProcessPaths() -> [String]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return nil }

        var paths: [String] = []
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = buffer.withUnsafeMutableBytes { raw in
                proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
            }
            if length > 0 { paths.append(String(decoding: buffer.prefix(Int(length)), as: UTF8.self)) }
        }
        return paths
    }

    private func recentProcessPaths() -> [String]? {
        let now = ContinuousClock.now
        if let cached = cache.withLock({ $0 }), now - cached.date < Self.cacheLifetime { return cached.paths }
        let paths = processPaths()
        cache.withLock { $0 = (now, paths) }
        return paths
    }
}
