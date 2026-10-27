public import Darwin
import Foundation
import Synchronization

/// Process resource snapshot with CPU and memory metrics and application bundle attribution.
public struct ProcessInfoItem: Sendable, Equatable, Identifiable {
    /// Identifier matching the process ID for SwiftUI lists and tables.
    public var id: pid_t { pid }
    /// Darwin process identifier.
    public let pid: pid_t
    /// Process display name.
    public let name: String
    /// Absolute filesystem path of the executable binary.
    public let executablePath: String
    /// Path to the enclosing `.app` bundle, or nil for command-line tools and daemons.
    public let appBundlePath: String?
    /// CPU utilization percentage across all cores during the sampling window.
    public let cpuPercent: Double
    /// Physical memory footprint in bytes (`ri_phys_footprint`).
    public let memoryBytes: UInt64

    /// Creates an immutable process metric snapshot.
    public init(
        pid: pid_t,
        name: String,
        executablePath: String,
        appBundlePath: String?,
        cpuPercent: Double,
        memoryBytes: UInt64
    ) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.appBundlePath = appBundlePath
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// Point-in-time snapshot of raw Darwin kernel process resource counters.
public struct RawProcessSample: Sendable, Equatable {
    /// Darwin process identifier.
    public let pid: pid_t
    /// Process executable name.
    public let name: String
    /// Absolute path to executable.
    public let executablePath: String
    /// Cumulative user and system CPU time in nanoseconds.
    public let cpuTimeNanoseconds: UInt64
    /// Physical memory footprint in bytes.
    public let physicalFootprint: UInt64
    /// Monotonic timestamp when this sample was gathered.
    public let timestampNanoseconds: UInt64

    /// Creates a raw process counter record.
    public init(
        pid: pid_t,
        name: String,
        executablePath: String,
        cpuTimeNanoseconds: UInt64,
        physicalFootprint: UInt64,
        timestampNanoseconds: UInt64
    ) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.physicalFootprint = physicalFootprint
        self.timestampNanoseconds = timestampNanoseconds
    }
}

/// Grouped process rankings by CPU and physical memory consumption.
public struct ProcessMetricsResult: Sendable, Equatable {
    /// Top processes ordered by CPU usage percentage descending.
    public let topByCPU: [ProcessInfoItem]
    /// Top processes ordered by physical memory footprint descending.
    public let topByMemory: [ProcessInfoItem]

    /// Creates a ranked process metrics result.
    public init(topByCPU: [ProcessInfoItem], topByMemory: [ProcessInfoItem]) {
        self.topByCPU = topByCPU
        self.topByMemory = topByMemory
    }
}

/// Collects process statistics and determines heavy resource consumers.
public final class ProcessSampler: Sendable {
    /// Closure type that gathers instantaneous raw process statistics from the operating system.
    public typealias SampleSource = @Sendable () throws -> [RawProcessSample]

    private let sampleSource: SampleSource
    private let previousSamples = Mutex<[pid_t: RawProcessSample]?>(nil)

    /// Creates a process sampler with an optional injected sampling source for testing.
    public init(sampleSource: SampleSource? = nil) {
        self.sampleSource = sampleSource ?? Self.defaultSampleSource
    }

    /// Samples running processes and computes CPU utilization deltas and memory footprints.
    public func sample(limit: Int = 15) async throws -> ProcessMetricsResult {
        let current = try sampleSource()
        let previous = previousSamples.withLock { saved in
            let old = saved
            var map: [pid_t: RawProcessSample] = [:]
            for item in current { map[item.pid] = item }
            saved = map
            return old
        }

        if let previous {
            return Self.computeMetrics(previous: previous, current: current, limit: limit)
        }

        // On first run without history, wait a brief interval to calculate an immediate CPU delta.
        try await Task.sleep(for: .milliseconds(120))
        let second = try sampleSource()
        var secondMap: [pid_t: RawProcessSample] = [:]
        for item in second { secondMap[item.pid] = item }
        previousSamples.withLock { $0 = secondMap }

        var firstMap: [pid_t: RawProcessSample] = [:]
        for item in current { firstMap[item.pid] = item }
        return Self.computeMetrics(previous: firstMap, current: second, limit: limit)
    }

    /// Pure extraction of the outermost enclosing application bundle path from an executable path.
    public static func findAppBundlePath(in executablePath: String) -> String? {
        guard executablePath.contains(".app") else { return nil }
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        var accumulated: [Substring] = []
        for component in components {
            accumulated.append(component)
            if component.hasSuffix(".app") {
                return accumulated.joined(separator: "/")
            }
        }
        return nil
    }

    /// Pure calculation ranking top processes across CPU and memory.
    public static func computeMetrics(
        previous: [pid_t: RawProcessSample],
        current: [RawProcessSample],
        limit: Int = 15
    ) -> ProcessMetricsResult {
        var items: [ProcessInfoItem] = []
        items.reserveCapacity(current.count)

        for curr in current {
            let prev = previous[curr.pid]
            let cpuPercent: Double
            if let prev, curr.timestampNanoseconds > prev.timestampNanoseconds {
                let deltaWall = curr.timestampNanoseconds - prev.timestampNanoseconds
                let deltaCPU =
                    curr.cpuTimeNanoseconds >= prev.cpuTimeNanoseconds
                    ? curr.cpuTimeNanoseconds - prev.cpuTimeNanoseconds
                    : 0
                cpuPercent = (Double(deltaCPU) / Double(deltaWall)) * 100.0
            } else {
                cpuPercent = 0.0
            }

            let appBundle = findAppBundlePath(in: curr.executablePath)
            items.append(
                ProcessInfoItem(
                    pid: curr.pid,
                    name: curr.name,
                    executablePath: curr.executablePath,
                    appBundlePath: appBundle,
                    cpuPercent: cpuPercent,
                    memoryBytes: curr.physicalFootprint
                )
            )
        }

        let sortedByCPU = items.sorted { $0.cpuPercent > $1.cpuPercent }
        let sortedByMemory = items.sorted { $0.memoryBytes > $1.memoryBytes }

        let topCPU = Array(sortedByCPU.prefix(limit))
        let topMemory = Array(sortedByMemory.prefix(limit))
        return ProcessMetricsResult(topByCPU: topCPU, topByMemory: topMemory)
    }

    /// Live Darwin implementation reading process lists and resource usage without external utilities.
    public static func defaultSampleSource() throws -> [RawProcessSample] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }

        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &now)
        let timestampNs = UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)

        var pathBuffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var nameBuffer = [UInt8](repeating: 0, count: 256)
        var samples: [RawProcessSample] = []
        samples.reserveCapacity(Int(filled))

        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var rusage = rusage_info_current()
            let rusageResult = withUnsafeMutablePointer(to: &rusage) { ptr in
                ptr.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
                }
            }
            guard rusageResult == 0 else { continue }

            let pathLength = pathBuffer.withUnsafeMutableBytes { raw in
                proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
            }
            let execPath: String
            if pathLength > 0 {
                execPath = String(decoding: pathBuffer.prefix(Int(pathLength)), as: UTF8.self)
            } else {
                execPath = ""
            }

            let nameLength = nameBuffer.withUnsafeMutableBytes { raw in
                proc_name(pid, raw.baseAddress, UInt32(raw.count))
            }
            let procName: String
            if nameLength > 0 {
                let cStrBytes = nameBuffer.prefix(Int(nameLength)).prefix { $0 != 0 }
                procName = String(decoding: cStrBytes, as: UTF8.self)
            } else if !execPath.isEmpty {
                procName = (execPath as NSString).lastPathComponent
            } else {
                procName = "pid-\(pid)"
            }

            let totalCpuNs = rusage.ri_user_time + rusage.ri_system_time
            samples.append(
                RawProcessSample(
                    pid: pid,
                    name: procName,
                    executablePath: execPath,
                    cpuTimeNanoseconds: totalCpuNs,
                    physicalFootprint: rusage.ri_phys_footprint,
                    timestampNanoseconds: timestampNs
                )
            )
        }

        return samples
    }
}
