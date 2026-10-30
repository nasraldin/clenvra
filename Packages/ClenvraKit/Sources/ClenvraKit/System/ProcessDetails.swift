public import Darwin
public import Foundation

/// Everything Clenvra can read about one running process without special rights. Fields macOS keeps private for
/// another user's process (path, arguments, threads) are nil rather than guessed.
public struct ProcessDetails: Sendable, Equatable, Identifiable {
    /// Identifier matching the process ID.
    public var id: pid_t { pid }
    /// Darwin process identifier.
    public let pid: pid_t
    /// The process that started this one.
    public let parentPID: pid_t
    /// Process display name.
    public let name: String
    /// Absolute path of the executable, or nil when macOS does not tell.
    public let executablePath: String?
    /// The outermost `.app` bundle holding the executable, or nil for command-line tools and daemons.
    public let appBundlePath: String?
    /// The short name of the user the process runs as, or the numeric user ID when it has no name.
    public let user: String
    /// When the process started.
    public let startDate: Date?
    /// Number of threads, or nil when not permitted.
    public let threads: Int?
    /// Average CPU use since the process started, as a percentage of one core; nil when not permitted.
    public let cpuPercent: Double?
    /// Physical memory footprint in bytes; nil when not permitted.
    public let memoryBytes: UInt64?
    /// Command-line arguments including the program itself, or nil when not permitted.
    public let arguments: [String]?

    /// Creates a details record.
    public init(
        pid: pid_t,
        parentPID: pid_t,
        name: String,
        executablePath: String?,
        appBundlePath: String?,
        user: String,
        startDate: Date?,
        threads: Int?,
        cpuPercent: Double?,
        memoryBytes: UInt64?,
        arguments: [String]?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.appBundlePath = appBundlePath
        self.user = user
        self.startDate = startDate
        self.threads = threads
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.arguments = arguments
    }

    /// Reads the process now. Returns nil when it is no longer running (exited or a zombie waiting to be reaped).
    public static func read(pid: pid_t) -> ProcessDetails? {
        guard pid > 0, let kinfo = kernelInfo(pid: pid) else { return nil }
        let executablePath = path(pid: pid)
        let startTime = kinfo.kp_proc.p_un.__p_starttime
        let startDate =
            startTime.tv_sec > 0
            ? Date(timeIntervalSince1970: TimeInterval(startTime.tv_sec) + TimeInterval(startTime.tv_usec) / 1e6)
            : nil
        let usage = resourceUsage(pid: pid)
        var cpuPercent: Double?
        if let usage, let startDate {
            let elapsed = Date().timeIntervalSince(startDate)
            let cpuSeconds = Double(cpuTimeNanoseconds(usage)) / 1e9
            cpuPercent = elapsed > 0 ? max(0, cpuSeconds / elapsed * 100) : 0
        }
        let uid = kinfo.kp_eproc.e_ucred.cr_uid
        return ProcessDetails(
            pid: pid,
            parentPID: kinfo.kp_eproc.e_ppid,
            name: name(pid: pid, executablePath: executablePath),
            executablePath: executablePath,
            appBundlePath: executablePath.flatMap(ProcessSampler.findAppBundlePath(in:)),
            user: userName(uid: uid),
            startDate: startDate,
            threads: threadCount(pid: pid),
            cpuPercent: cpuPercent,
            memoryBytes: usage.map(\.ri_phys_footprint),
            arguments: arguments(pid: pid)
        )
    }

    /// The kernel's process record, or nil when the process is gone or a zombie.
    private static func kernelInfo(pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        guard info.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        return info
    }

    private static func path(pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func name(pid: pid_t, executablePath: String?) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        if length > 0 {
            return String(decoding: buffer.prefix(Int(length)).prefix { $0 != 0 }, as: UTF8.self)
        }
        if let executablePath, !executablePath.isEmpty {
            return (executablePath as NSString).lastPathComponent
        }
        return "pid-\(pid)"
    }

    /// Total user and system CPU time of the process in nanoseconds, or nil when not permitted.
    static func cpuTimeNanoseconds(pid: pid_t) -> UInt64? {
        resourceUsage(pid: pid).map(cpuTimeNanoseconds)
    }

    private static func cpuTimeNanoseconds(_ usage: rusage_info_current) -> UInt64 {
        machTicksToNanoseconds(usage.ri_user_time + usage.ri_system_time)
    }

    private static func resourceUsage(pid: pid_t) -> rusage_info_current? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        return result == 0 ? usage : nil
    }

    private static func threadCount(pid: pid_t) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard filled == size else { return nil }
        return Int(info.pti_threadnum)
    }

    /// `rusage` CPU times are Mach absolute-time ticks; on Apple silicon a tick is not a nanosecond.
    static func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return ticks }
        let (product, overflow) = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
        if overflow { return ticks / UInt64(timebase.denom) * UInt64(timebase.numer) }
        return product / UInt64(timebase.denom)
    }

    private static func userName(uid: uid_t) -> String {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        let status = buffer.withUnsafeMutableBufferPointer { raw in
            getpwuid_r(uid, &record, raw.baseAddress, raw.count, &result)
        }
        guard status == 0, result != nil, let namePointer = record.pw_name else { return "\(uid)" }
        return String(cString: namePointer)
    }

    /// The command line from `KERN_PROCARGS2`: an `Int32` argument count, the executable path, padding, then the
    /// arguments, each NUL-terminated. macOS refuses this for another user's process.
    static func arguments(pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var maxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        let maxResult = maxMib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &argMax, &argMaxSize, nil, 0)
        }
        guard maxResult == 0, argMax > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: Int(argMax))
        var size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibBuffer in
            bytes.withUnsafeMutableBytes { raw in
                sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), raw.baseAddress, &size, nil, 0)
            }
        }
        guard result == 0 else { return nil }
        return parseProcArgs(Array(bytes.prefix(size)))
    }

    /// Parses a `KERN_PROCARGS2` buffer; nil when it is malformed.
    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return nil }
        let argc = bytes.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var index = countSize
        // Skip the executable path and the NUL padding after it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < Int(argc), index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
