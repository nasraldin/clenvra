import Darwin
public import Foundation
import IOKit
import IOKit.ps
import Synchronization

/// Memory pressure classification indicating whether the kernel is reclaiming or compressing memory.
public enum MemoryPressureLevel: String, Sendable, CaseIterable {
    /// Memory pressure is normal with sufficient available memory.
    case normal
    /// Memory pressure is elevated and caches are being trimmed.
    case warning
    /// Memory pressure is critical and paging or process suspension may occur.
    case critical
}

/// Hardware thermal status reflecting thermal headroom or throttling.
public enum ThermalState: String, Sendable, CaseIterable {
    /// Operating temperatures are within nominal limits.
    case nominal
    /// Temperatures are slightly elevated but within normal tolerances.
    case fair
    /// Thermal headroom is constrained; the system may throttle performance.
    case serious
    /// Critical thermal state; aggressive throttling or shutdown is imminent.
    case critical

    /// Maps Foundation's ProcessInfo thermal state so the UI layer is decoupled from AppKit/Foundation types.
    public init(processInfoState: ProcessInfo.ThermalState) {
        switch processInfoState {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

/// Battery health and capacity metrics, or nil on desktop Macs without batteries.
public struct BatteryHealth: Sendable, Equatable {
    /// Whether an internal battery is physically present.
    public let isPresent: Bool
    /// Current state of charge as a percentage from 0 to 100.
    public let chargePercent: Int
    /// Lifetime cycle count reported by the battery micro-controller.
    public let cycleCount: Int?
    /// Battery condition description reported by the power management subsystem.
    public let condition: String?
    /// Maximum capacity relative to original design capacity as a percentage.
    public let maxCapacityPercent: Int?

    /// Creates a battery health record with verified metrics.
    public init(
        isPresent: Bool,
        chargePercent: Int,
        cycleCount: Int? = nil,
        condition: String? = nil,
        maxCapacityPercent: Int? = nil
    ) {
        self.isPresent = isPresent
        self.chargePercent = chargePercent
        self.cycleCount = cycleCount
        self.condition = condition
        self.maxCapacityPercent = maxCapacityPercent
    }
}

/// Processor tick snapshot used to compute CPU usage across two sampling points.
public struct CPULoadSample: Sendable, Equatable {
    /// Ticks spent executing user-space code.
    public let userTicks: UInt64
    /// Ticks spent executing kernel system calls.
    public let systemTicks: UInt64
    /// Ticks spent idle.
    public let idleTicks: UInt64
    /// Ticks spent executing low-priority user tasks.
    public let niceTicks: UInt64

    /// Creates a tick sample for CPU arithmetic.
    public init(userTicks: UInt64, systemTicks: UInt64, idleTicks: UInt64, niceTicks: UInt64) {
        self.userTicks = userTicks
        self.systemTicks = systemTicks
        self.idleTicks = idleTicks
        self.niceTicks = niceTicks
    }

    /// Total ticks across all modes in this sample.
    public var totalTicks: UInt64 {
        userTicks + systemTicks + idleTicks + niceTicks
    }

    /// Ticks actively doing work in this sample.
    public var usedTicks: UInt64 {
        userTicks + systemTicks + niceTicks
    }
}

/// Unprocessed page counts from Darwin's virtual memory subsystem.
public struct RawVMMetrics: Sendable, Equatable {
    /// Number of anonymous internal memory pages.
    public let internalPageCount: UInt64
    /// Number of volatile purgeable pages.
    public let purgeablePageCount: UInt64
    /// Number of wired memory pages locked in physical RAM.
    public let wireCount: UInt64
    /// Number of pages occupied by the in-memory compressor.
    public let compressorPageCount: UInt64
    /// Page size in bytes for this architecture (16,384 bytes on Apple Silicon).
    public let pageSize: UInt64

    /// Creates a raw virtual memory metric record.
    public init(
        internalPageCount: UInt64,
        purgeablePageCount: UInt64,
        wireCount: UInt64,
        compressorPageCount: UInt64,
        pageSize: UInt64
    ) {
        self.internalPageCount = internalPageCount
        self.purgeablePageCount = purgeablePageCount
        self.wireCount = wireCount
        self.compressorPageCount = compressorPageCount
        self.pageSize = pageSize
    }
}

/// Breakdown of physical memory allocation in bytes.
public struct MemoryMetrics: Sendable, Equatable {
    /// Total installed physical RAM.
    public let totalPhysicalMemory: UInt64
    /// Memory consumed by running applications.
    public let appMemory: UInt64
    /// Memory locked by the kernel and core services that cannot be paged out.
    public let wiredMemory: UInt64
    /// Compressed memory held in RAM by the kernel compressor.
    public let compressedMemory: UInt64
    /// Total used memory (app + wired + compressed).
    public let usedMemory: UInt64
    /// Remaining memory available for applications or disk cache.
    public let availableMemory: UInt64

    /// Creates a memory metrics breakdown.
    public init(
        totalPhysicalMemory: UInt64,
        appMemory: UInt64,
        wiredMemory: UInt64,
        compressedMemory: UInt64,
        usedMemory: UInt64,
        availableMemory: UInt64
    ) {
        self.totalPhysicalMemory = totalPhysicalMemory
        self.appMemory = appMemory
        self.wiredMemory = wiredMemory
        self.compressedMemory = compressedMemory
        self.usedMemory = usedMemory
        self.availableMemory = availableMemory
    }
}

/// Complete system health snapshot including memory breakdown, CPU usage, swap, uptime, thermal, and battery.
public struct SystemHealth: Sendable, Equatable {
    /// Memory pressure status reported by the Darwin kernel.
    public let memoryPressure: MemoryPressureLevel
    /// Total installed physical RAM in bytes.
    public let totalPhysicalMemory: UInt64
    /// Total active used memory in bytes.
    public let usedMemory: UInt64
    /// Application memory in bytes.
    public let appMemory: UInt64
    /// Wired memory in bytes.
    public let wiredMemory: UInt64
    /// Compressed memory in bytes.
    public let compressedMemory: UInt64
    /// Available memory in bytes.
    public let availableMemory: UInt64
    /// Swap space currently allocated on disk in bytes.
    public let swapUsed: UInt64
    /// Overall CPU load percentage across all CPU cores (0–100%).
    public let cpuLoadPercent: Double
    /// Elapsed system uptime in seconds.
    public let uptime: TimeInterval
    /// Hardware thermal state.
    public let thermalState: ThermalState
    /// Battery health and charge status, or nil on desktops.
    public let battery: BatteryHealth?

    /// Creates a complete health snapshot.
    public init(
        memoryPressure: MemoryPressureLevel,
        totalPhysicalMemory: UInt64,
        usedMemory: UInt64,
        appMemory: UInt64,
        wiredMemory: UInt64,
        compressedMemory: UInt64,
        availableMemory: UInt64,
        swapUsed: UInt64,
        cpuLoadPercent: Double,
        uptime: TimeInterval,
        thermalState: ThermalState,
        battery: BatteryHealth?
    ) {
        self.memoryPressure = memoryPressure
        self.totalPhysicalMemory = totalPhysicalMemory
        self.usedMemory = usedMemory
        self.appMemory = appMemory
        self.wiredMemory = wiredMemory
        self.compressedMemory = compressedMemory
        self.availableMemory = availableMemory
        self.swapUsed = swapUsed
        self.cpuLoadPercent = cpuLoadPercent
        self.uptime = uptime
        self.thermalState = thermalState
        self.battery = battery
    }
}

/// Reads host metrics from Mach, sysctl, and IOKit without launching helper tools.
public final class HealthSampler: Sendable {
    private let previousCPUSample = Mutex<CPULoadSample?>(nil)

    /// Creates a health sampler with state for delta calculations.
    public init() {}

    /// Samples current host metrics.
    public func sample() throws -> SystemHealth {
        let pressure = Self.readMemoryPressure()
        let totalMem = ProcessInfo.processInfo.physicalMemory
        let vmMetrics = Self.calculateMemoryMetrics(
            raw: Self.readRawVMMetrics(),
            totalPhysical: totalMem
        )
        let swap = Self.readSwapUsed()

        let currentCPU = Self.readCPUTicks()
        let prevCPU = previousCPUSample.withLock { saved in
            let old = saved
            saved = currentCPU
            return old
        }
        let cpuLoad: Double
        if let prevCPU, let currentCPU {
            cpuLoad = Self.calculateCPULoad(previous: prevCPU, current: currentCPU)
        } else {
            cpuLoad = 0.0
        }

        let uptime = Self.readUptime()
        let thermal = ThermalState(processInfoState: ProcessInfo.processInfo.thermalState)
        let battery = Self.readBattery()

        return SystemHealth(
            memoryPressure: pressure,
            totalPhysicalMemory: vmMetrics.totalPhysicalMemory,
            usedMemory: vmMetrics.usedMemory,
            appMemory: vmMetrics.appMemory,
            wiredMemory: vmMetrics.wiredMemory,
            compressedMemory: vmMetrics.compressedMemory,
            availableMemory: vmMetrics.availableMemory,
            swapUsed: swap,
            cpuLoadPercent: cpuLoad,
            uptime: uptime,
            thermalState: thermal,
            battery: battery
        )
    }

    /// Pure translation of kernel memory pressure level into a classified enum.
    public static func memoryPressureLevel(forSysctlValue value: Int32) -> MemoryPressureLevel {
        switch value {
        case ..<2: .normal
        case 2: .warning
        default: .critical
        }
    }

    /// Pure calculation separating anonymous application memory, wired memory, and compressed memory.
    public static func calculateMemoryMetrics(raw: RawVMMetrics, totalPhysical: UInt64) -> MemoryMetrics {
        let appPages =
            raw.internalPageCount >= raw.purgeablePageCount
            ? raw.internalPageCount - raw.purgeablePageCount
            : raw.internalPageCount
        let app = appPages * raw.pageSize
        let wired = raw.wireCount * raw.pageSize
        let compressed = raw.compressorPageCount * raw.pageSize
        let used = app + wired + compressed
        let available = totalPhysical >= used ? totalPhysical - used : 0
        return MemoryMetrics(
            totalPhysicalMemory: totalPhysical,
            appMemory: app,
            wiredMemory: wired,
            compressedMemory: compressed,
            usedMemory: used,
            availableMemory: available
        )
    }

    /// Pure calculation of CPU load percentage based on tick deltas between two points in time.
    public static func calculateCPULoad(previous: CPULoadSample, current: CPULoadSample) -> Double {
        guard current.totalTicks > previous.totalTicks else { return 0.0 }
        let deltaTotal = current.totalTicks - previous.totalTicks
        let deltaUsed = current.usedTicks >= previous.usedTicks ? current.usedTicks - previous.usedTicks : 0
        let percentage = (Double(deltaUsed) / Double(deltaTotal)) * 100.0
        return min(max(percentage, 0.0), 100.0)
    }

    /// Pure calculation of uptime from boot timestamp and current timestamp.
    public static func calculateUptime(bootSeconds: Int64, currentSeconds: Int64) -> TimeInterval {
        guard currentSeconds >= bootSeconds else { return 0.0 }
        return TimeInterval(currentSeconds - bootSeconds)
    }

    /// Pure parser turning power source dictionary and registry metrics into structured battery health.
    public static func parseBatteryInfo(
        powerSource: [String: Any]?,
        cycleCount: Int?,
        maxCapacity: Int?
    ) -> BatteryHealth? {
        guard let powerSource else { return nil }
        guard let isPresent = powerSource["Is Present"] as? Bool, isPresent else { return nil }
        let currentCapacity = (powerSource["Current Capacity"] as? NSNumber)?.intValue ?? 0
        let condition = powerSource["BatteryHealthCondition"] as? String
        return BatteryHealth(
            isPresent: true,
            chargePercent: max(0, min(currentCapacity, 100)),
            cycleCount: cycleCount,
            condition: condition,
            maxCapacityPercent: maxCapacity
        )
    }

    // MARK: - Private Darwin / Mach / IOKit Readers

    private static func readMemoryPressure() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard result == 0 else { return .normal }
        return memoryPressureLevel(forSysctlValue: level)
    }

    private static func readRawVMMetrics() -> RawVMMetrics {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var vmStats = vm_statistics64()
        let kerr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        let pageSize = UInt64(getpagesize())
        guard kerr == KERN_SUCCESS else {
            return RawVMMetrics(
                internalPageCount: 0,
                purgeablePageCount: 0,
                wireCount: 0,
                compressorPageCount: 0,
                pageSize: pageSize
            )
        }
        return RawVMMetrics(
            internalPageCount: UInt64(vmStats.internal_page_count),
            purgeablePageCount: UInt64(vmStats.purgeable_count),
            wireCount: UInt64(vmStats.wire_count),
            compressorPageCount: UInt64(vmStats.compressor_page_count),
            pageSize: pageSize
        )
    }

    private static func readSwapUsed() -> UInt64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        guard result == 0 else { return 0 }
        return swap.xsu_used
    }

    private static func readCPUTicks() -> CPULoadSample? {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let kerr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )
        guard kerr == KERN_SUCCESS, let cpuInfo else { return nil }
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0
        cpuInfo.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: Int(numCPUs)) { ptr in
            for i in 0..<Int(numCPUs) {
                let info = ptr[i]
                user += UInt64(info.cpu_ticks.0)
                system += UInt64(info.cpu_ticks.1)
                idle += UInt64(info.cpu_ticks.2)
                nice += UInt64(info.cpu_ticks.3)
            }
        }
        let byteSize = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), byteSize)
        return CPULoadSample(userTicks: user, systemTicks: system, idleTicks: idle, niceTicks: nice)
    }

    private static func readUptime() -> TimeInterval {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        guard result == 0 else { return 0.0 }
        var now = timeval()
        gettimeofday(&now, nil)
        return calculateUptime(bootSeconds: Int64(bootTime.tv_sec), currentSeconds: Int64(now.tv_sec))
    }

    private static func readBattery() -> BatteryHealth? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
            let first = list.first
        else {
            return nil
        }
        guard let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else {
            return nil
        }

        var cycleCount: Int?
        var maxCapacity: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let cycleProp = IORegistryEntryCreateCFProperty(
                service,
                "CycleCount" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? NSNumber {
                cycleCount = cycleProp.intValue
            }
            if let maxCapProp = IORegistryEntryCreateCFProperty(
                service,
                "MaxCapacity" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? NSNumber {
                maxCapacity = maxCapProp.intValue
            }
        }

        return parseBatteryInfo(powerSource: desc, cycleCount: cycleCount, maxCapacity: maxCapacity)
    }
}
