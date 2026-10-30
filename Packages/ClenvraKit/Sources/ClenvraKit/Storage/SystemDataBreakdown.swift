public import Foundation

/// The parts of macOS "System Data" that Clenvra can measure without privileges. Each value is `nil` when it could
/// not be measured, which is different from zero.
public struct SystemDataBreakdown: Sendable, Equatable {
    /// Bytes of swap in use (`vm.swapusage`).
    public var swapUsed: Int64?
    /// Names of the local APFS snapshots of the startup disk (`tmutil listlocalsnapshots /`).
    public var localSnapshots: [String]
    /// Total size of the installed simulator runtimes (`simctl runtime list -j`).
    public var simulatorRuntimes: Int64?
    /// Space macOS frees by itself when needed, estimated from the startup volume.
    public var purgeable: Int64?

    public init(swapUsed: Int64?, localSnapshots: [String], simulatorRuntimes: Int64?, purgeable: Int64?) {
        self.swapUsed = swapUsed
        self.localSnapshots = localSnapshots
        self.simulatorRuntimes = simulatorRuntimes
        self.purgeable = purgeable
    }
}

/// Reads a `SystemDataBreakdown`. Read-only: only listing commands are run.
public enum SystemDataReader {
    @concurrent public static func read(
        runner: any CommandRunning, rootVolume: Volume?, home: String = NSHomeDirectory(),
        xcrun: String = "/usr/bin/xcrun", tmutil: String = "/usr/bin/tmutil"
    ) async -> SystemDataBreakdown {
        async let runtimes = simulatorRuntimesSize(runner: runner, home: home, xcrun: xcrun)
        async let snapshots = ToolProbe.output(runner, tmutil, ["listlocalsnapshots", "/"])
        return SystemDataBreakdown(
            swapUsed: swapUsed(), localSnapshots: await snapshots.map(parseSnapshots) ?? [],
            simulatorRuntimes: await runtimes, purgeable: rootVolume?.purgeableEstimate)
    }

    /// Snapshot names in `tmutil listlocalsnapshots` output; the "Snapshots for disk /:" header and blank lines are
    /// skipped.
    public static func parseSnapshots(_ tmutilOutput: String) -> [String] {
        tmutilOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") && !$0.contains(where: \.isWhitespace) }
    }

    /// Bytes of swap in use, or `nil` when the sysctl cannot be read.
    public static func swapUsed() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0, size == MemoryLayout<xsw_usage>.size else {
            return nil
        }
        return Int64(exactly: usage.xsu_used)
    }

    /// Sum of the runtime sizes, or `nil` when there are no developer tools, the probe fails or no runtime reports a
    /// size. Same guard as `SimulatorAdapter`: without a CoreSimulator folder the xcrun shim is never woken.
    @concurrent static func simulatorRuntimesSize(runner: any CommandRunning, home: String, xcrun: String) async
        -> Int64?
    {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: home + "/Library/Developer/CoreSimulator", isDirectory: &isDirectory),
            isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: xcrun),
            let output = await ToolProbe.output(runner, xcrun, ["simctl", "runtime", "list", "-j"])
        else { return nil }
        var total: Int64?
        for size in SimulatorAdapter.parseRuntimes(output).compactMap(\.size) {
            let (sum, overflow) = (total ?? 0).addingReportingOverflow(size)
            total = overflow ? total : sum
        }
        return total
    }
}
