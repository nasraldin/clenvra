import Foundation
import Synchronization
import Testing

@testable import ClenvraKit

@Suite("HealthSampler")
struct HealthSamplerTests {
    @Test("memory pressure level maps sysctl values to normal, warning, and critical")
    func memoryPressureLevels() {
        #expect(HealthSampler.memoryPressureLevel(forSysctlValue: 0) == .normal)
        #expect(HealthSampler.memoryPressureLevel(forSysctlValue: 1) == .normal)
        #expect(HealthSampler.memoryPressureLevel(forSysctlValue: 2) == .warning)
        #expect(HealthSampler.memoryPressureLevel(forSysctlValue: 4) == .critical)
        #expect(HealthSampler.memoryPressureLevel(forSysctlValue: 5) == .critical)
    }

    @Test("memory metrics arithmetic separates app, wired, and compressed memory")
    func memoryMetricsArithmetic() {
        let pageSize: UInt64 = 16384
        let raw = RawVMMetrics(
            internalPageCount: 100_000,
            purgeablePageCount: 10_000,
            wireCount: 50_000,
            compressorPageCount: 20_000,
            pageSize: pageSize
        )
        let totalRAM: UInt64 = 32 * 1024 * 1024 * 1024  // 32 GiB

        let metrics = HealthSampler.calculateMemoryMetrics(raw: raw, totalPhysical: totalRAM)

        let expectedApp: UInt64 = (100_000 - 10_000) * pageSize
        let expectedWired: UInt64 = 50_000 * pageSize
        let expectedCompressed: UInt64 = 20_000 * pageSize
        let expectedUsed = expectedApp + expectedWired + expectedCompressed

        #expect(metrics.appMemory == expectedApp)
        #expect(metrics.wiredMemory == expectedWired)
        #expect(metrics.compressedMemory == expectedCompressed)
        #expect(metrics.usedMemory == expectedUsed)
        #expect(metrics.totalPhysicalMemory == totalRAM)
        #expect(metrics.availableMemory == totalRAM - expectedUsed)
    }

    @Test("CPU load arithmetic calculates delta percentage clamped to 0...100")
    func cpuLoadArithmetic() {
        let prev = CPULoadSample(userTicks: 1000, systemTicks: 500, idleTicks: 3500, niceTicks: 0)
        let current = CPULoadSample(userTicks: 1300, systemTicks: 600, idleTicks: 3600, niceTicks: 0)
        // delta: user 300, system 100, idle 100, nice 0.
        // total delta = 500. used delta = 400.
        // 400 / 500 = 80.0%
        let load = HealthSampler.calculateCPULoad(previous: prev, current: current)
        #expect(abs(load - 80.0) < 0.001)

        // Stale or inverted ticks return 0
        let zero = HealthSampler.calculateCPULoad(previous: current, current: prev)
        #expect(zero == 0.0)
    }

    @Test("uptime calculation subtracts boot timestamp from current time")
    func uptimeCalculation() {
        let uptime = HealthSampler.calculateUptime(bootSeconds: 1_700_000_000, currentSeconds: 1_700_086_400)
        #expect(uptime == 86400.0)  // 1 day
    }

    @Test("battery parsing handles missing battery on desktops and present battery on laptops")
    func batteryParsing() {
        #expect(HealthSampler.parseBatteryInfo(powerSource: nil, cycleCount: nil, maxCapacity: nil) == nil)

        let notPresent: [String: Any] = ["Is Present": false, "Current Capacity": 0]
        #expect(HealthSampler.parseBatteryInfo(powerSource: notPresent, cycleCount: nil, maxCapacity: nil) == nil)

        let laptopSource: [String: Any] = [
            "Is Present": true,
            "Current Capacity": 85,
            "BatteryHealthCondition": "Normal",
        ]
        let battery = HealthSampler.parseBatteryInfo(
            powerSource: laptopSource,
            cycleCount: 142,
            maxCapacity: 98
        )
        #expect(battery != nil)
        #expect(battery?.isPresent == true)
        #expect(battery?.chargePercent == 85)
        #expect(battery?.cycleCount == 142)
        #expect(battery?.maxCapacityPercent == 98)
        #expect(battery?.condition == "Normal")
    }

    @Test("live health sampler returns plausible system metrics")
    func liveHealthSampling() throws {
        let sampler = HealthSampler()
        let health = try sampler.sample()

        #expect(health.totalPhysicalMemory > 0)
        #expect(health.usedMemory > 0)
        #expect(health.usedMemory <= health.totalPhysicalMemory)
        #expect(health.uptime > 0)
        #expect(health.cpuLoadPercent >= 0.0 && health.cpuLoadPercent <= 100.0)
    }
}

@Suite("ProcessSampler")
struct ProcessSamplerTests {
    @Test("owning app bundle path extracts the outermost .app bundle")
    func appBundlePathExtraction() {
        #expect(
            ProcessSampler.findAppBundlePath(in: "/Applications/Safari.app/Contents/MacOS/Safari")
                == "/Applications/Safari.app"
        )
        #expect(
            ProcessSampler.findAppBundlePath(in: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
                == "/System/Applications/Utilities/Terminal.app"
        )
        #expect(
            ProcessSampler.findAppBundlePath(
                in:
                    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
            ) == "/Applications/Xcode.app"
        )
        #expect(ProcessSampler.findAppBundlePath(in: "/usr/bin/git") == nil)
        #expect(ProcessSampler.findAppBundlePath(in: "/bin/zsh") == nil)
    }

    @Test("process metrics arithmetic ranks top processes by CPU and by memory")
    func processMetricsArithmetic() {
        let t1: UInt64 = 1_000_000_000  // 1s in ns
        let t2: UInt64 = 2_000_000_000  // 2s in ns (wall delta = 1,000,000,000 ns)

        let prev: [pid_t: RawProcessSample] = [
            101: RawProcessSample(
                pid: 101,
                name: "HeavyCPU",
                executablePath: "/Applications/HeavyCPU.app/Contents/MacOS/HeavyCPU",
                cpuTimeNanoseconds: 200_000_000,
                physicalFootprint: 100 * 1024 * 1024,
                timestampNanoseconds: t1
            ),
            102: RawProcessSample(
                pid: 102,
                name: "HeavyMem",
                executablePath: "/Applications/HeavyMem.app/Contents/MacOS/HeavyMem",
                cpuTimeNanoseconds: 100_000_000,
                physicalFootprint: 4 * 1024 * 1024 * 1024,
                timestampNanoseconds: t1
            ),
            103: RawProcessSample(
                pid: 103,
                name: "IdleTool",
                executablePath: "/usr/bin/idle",
                cpuTimeNanoseconds: 50_000_000,
                physicalFootprint: 20 * 1024 * 1024,
                timestampNanoseconds: t1
            ),
        ]

        let curr = [
            RawProcessSample(
                pid: 101,
                name: "HeavyCPU",
                executablePath: "/Applications/HeavyCPU.app/Contents/MacOS/HeavyCPU",
                cpuTimeNanoseconds: 1_000_000_000,  // delta = 800,000,000 ns -> 80% CPU
                physicalFootprint: 100 * 1024 * 1024,
                timestampNanoseconds: t2
            ),
            RawProcessSample(
                pid: 102,
                name: "HeavyMem",
                executablePath: "/Applications/HeavyMem.app/Contents/MacOS/HeavyMem",
                cpuTimeNanoseconds: 200_000_000,  // delta = 100,000,000 ns -> 10% CPU
                physicalFootprint: 4 * 1024 * 1024 * 1024,
                timestampNanoseconds: t2
            ),
            RawProcessSample(
                pid: 103,
                name: "IdleTool",
                executablePath: "/usr/bin/idle",
                cpuTimeNanoseconds: 50_000_000,  // delta = 0 -> 0% CPU
                physicalFootprint: 20 * 1024 * 1024,
                timestampNanoseconds: t2
            ),
        ]

        let result = ProcessSampler.computeMetrics(previous: prev, current: curr, limit: 10)

        #expect(result.topByCPU.map(\.pid) == [101, 102, 103])
        #expect(abs(result.topByCPU[0].cpuPercent - 80.0) < 0.1)
        #expect(abs(result.topByCPU[1].cpuPercent - 10.0) < 0.1)
        #expect(result.topByCPU[0].appBundlePath == "/Applications/HeavyCPU.app")

        #expect(result.topByMemory.map(\.pid) == [102, 101, 103])
        #expect(result.topByMemory[0].memoryBytes == 4 * 1024 * 1024 * 1024)
        #expect(result.topByMemory[2].appBundlePath == nil)
    }

    @Test("injected process sampler returns ranked processes")
    func injectedProcessSampler() async throws {
        let fakeSamples: [RawProcessSample] = [
            RawProcessSample(
                pid: 200,
                name: "MockApp",
                executablePath: "/Applications/Mock.app/Contents/MacOS/MockApp",
                cpuTimeNanoseconds: 500_000_000,
                physicalFootprint: 512 * 1024 * 1024,
                timestampNanoseconds: 1_000_000_000
            )
        ]

        let sampler = ProcessSampler(sampleSource: { fakeSamples })
        let result = try await sampler.sample(limit: 5)

        #expect(result.topByMemory.count == 1)
        #expect(result.topByMemory.first?.pid == 200)
        #expect(result.topByMemory.first?.name == "MockApp")
    }

    @Test("live process sampler returns running host processes")
    func liveProcessSampler() async throws {
        let sampler = ProcessSampler()
        let result = try await sampler.sample(limit: 10)

        #expect(!result.topByMemory.isEmpty)
        #expect(result.topByMemory.first?.memoryBytes ?? 0 > 0)
        #expect(result.topByMemory.first?.pid ?? 0 > 0)
    }
}

@Suite("SecurityChecks")
struct SecurityChecksTests {
    @Test("SIP parser parses enabled, disabled, and unknown outputs")
    func sipParsing() {
        let good = SecurityChecker.parseSIP(
            output: "System Integrity Protection status: enabled.\n",
            exitStatus: 0
        )
        #expect(good.id == "sip")
        #expect(good.status == .good)
        #expect(good.detail == "System Integrity Protection status: enabled.")

        let attention = SecurityChecker.parseSIP(
            output: "System Integrity Protection status: disabled.\n",
            exitStatus: 0
        )
        #expect(attention.status == .attention)

        let unknown = SecurityChecker.parseSIP(output: "failed to communicate", exitStatus: 1)
        #expect(unknown.status == .unknown)
    }

    @Test("FileVault parser parses on, off, and error outputs")
    func fileVaultParsing() {
        let good = SecurityChecker.parseFileVault(output: "FileVault is On.\n", exitStatus: 0)
        #expect(good.id == "fileVault")
        #expect(good.status == .good)
        #expect(good.detail == "FileVault is On.")

        let attention = SecurityChecker.parseFileVault(output: "FileVault is Off.\n", exitStatus: 0)
        #expect(attention.status == .attention)

        let unknown = SecurityChecker.parseFileVault(output: "", exitStatus: 1)
        #expect(unknown.status == .unknown)
    }

    @Test("Gatekeeper parser parses enabled and disabled states")
    func gatekeeperParsing() {
        let good = SecurityChecker.parseGatekeeper(output: "assessments enabled\n", exitStatus: 0)
        #expect(good.id == "gatekeeper")
        #expect(good.status == .good)
        #expect(good.detail == "assessments enabled")

        let attention = SecurityChecker.parseGatekeeper(output: "assessments disabled\n", exitStatus: 0)
        #expect(attention.status == .attention)

        let unknown = SecurityChecker.parseGatekeeper(output: "unexpected", exitStatus: 1)
        #expect(unknown.status == .unknown)
    }

    @Test("Firewall parser parses enabled and disabled states")
    func firewallParsing() {
        let good = SecurityChecker.parseFirewall(
            output: "Firewall is enabled. (State = 1)\n",
            exitStatus: 0
        )
        #expect(good.id == "firewall")
        #expect(good.status == .good)
        #expect(good.detail == "Firewall is enabled. (State = 1)")

        let attention = SecurityChecker.parseFirewall(
            output: "Firewall is disabled. (State = 0)\n",
            exitStatus: 0
        )
        #expect(attention.status == .attention)

        let unknown = SecurityChecker.parseFirewall(output: "error", exitStatus: 1)
        #expect(unknown.status == .unknown)
    }

    @Test("XProtect parser extracts version and formats modification date")
    func xprotectParsing() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let check = SecurityChecker.parseXProtect(version: "5368", modificationDate: date)
        #expect(check.id == "xprotect")
        #expect(check.status == .good)
        #expect(check.detail.contains("5368"))

        let missing = SecurityChecker.parseXProtect(version: nil, modificationDate: nil)
        #expect(missing.status == .unknown)
    }

    @Test("Security updates parser inspects critical and config flags")
    func securityUpdatesParsing() {
        let good = SecurityChecker.parseSecurityUpdates(critical: true, config: true)
        #expect(good.id == "securityUpdates")
        #expect(good.status == .good)

        let attention = SecurityChecker.parseSecurityUpdates(critical: false, config: true)
        #expect(attention.status == .attention)

        let unknown = SecurityChecker.parseSecurityUpdates(critical: nil, config: nil)
        #expect(unknown.status == .unknown)
    }

    @Test("injected security checker executes commands and aggregates all six checks")
    func injectedSecurityChecker() async {
        let fake = FakeCommandRunner()
        fake.stub("/usr/bin/csrutil", ["status"], stdout: "System Integrity Protection status: enabled.\n")
        fake.stub("/usr/bin/fdesetup", ["status"], stdout: "FileVault is On.\n")
        fake.stub("/usr/sbin/spctl", ["--status"], stdout: "assessments enabled\n")
        fake.stub(
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            ["--getglobalstate"],
            stdout: "Firewall is enabled. (State = 1)\n"
        )

        let checker = SecurityChecker(
            runner: fake,
            xprotectReader: { ("5368", Date(timeIntervalSince1970: 1_700_000_000)) },
            softwareUpdateReader: { (true, true) }
        )

        let checks = await checker.checkAll()
        #expect(checks.count == 6)
        #expect(checks.allSatisfy { $0.status == .good })
        #expect(checks.map(\.id) == ["sip", "fileVault", "gatekeeper", "firewall", "xprotect", "securityUpdates"])
    }

    @Test("live security checker returns checks without crashing")
    func liveSecurityChecker() async {
        let checker = SecurityChecker()
        let checks = await checker.checkAll()
        #expect(checks.count == 6)
        #expect(!checks.contains { $0.id.isEmpty })
    }
}

@Suite("SystemSession")
struct SystemSessionTests {
    @MainActor
    private func makeSession(
        politeResult: Bool = true,
        forceResult: Bool = true,
        healthSampler: HealthSampler? = nil,
        processSampler: ProcessSampler? = nil,
        securityChecker: SecurityChecker? = nil
    ) -> (SystemSession, FakeTerminators) {
        let terminators = FakeTerminators(politeResult: politeResult, forceResult: forceResult)
        let session = SystemSession(
            healthSampler: healthSampler ?? HealthSampler(),
            processSampler: processSampler
                ?? ProcessSampler(sampleSource: {
                    [
                        RawProcessSample(
                            pid: 42,
                            name: "TestApp",
                            executablePath: "/Applications/Test.app/Contents/MacOS/TestApp",
                            cpuTimeNanoseconds: 100_000_000,
                            physicalFootprint: 50 * 1024 * 1024,
                            timestampNanoseconds: 1_000_000_000
                        )
                    ]
                }),
            securityChecker: securityChecker
                ?? SecurityChecker(
                    runner: FakeCommandRunner(),
                    xprotectReader: { ("1.0", Date()) },
                    softwareUpdateReader: { (true, true) }
                ),
            politeTerminator: { terminators.polite($0) },
            forceTerminator: { terminators.force($0) }
        )
        return (session, terminators)
    }

    @Test("session starts with empty state and refreshes health, processes and security")
    @MainActor
    func initialAndRefresh() async {
        let (session, _) = makeSession()
        #expect(session.health == nil)
        #expect(session.topByCPU.isEmpty)
        #expect(session.topByMemory.isEmpty)
        #expect(session.securityChecks.isEmpty)

        await session.refreshHealth()
        #expect(session.health != nil)

        await session.refreshProcesses()
        #expect(!session.topByMemory.isEmpty)
        #expect(session.topByMemory.first?.pid == 42)

        await session.refreshSecurity()
        #expect(!session.securityChecks.isEmpty)
    }

    @Test("polite quit records failure and enables force quit")
    @MainActor
    func politeQuitAndForceQuit() async {
        let (session, terminators) = makeSession(politeResult: false, forceResult: true)

        // Force quit before polite quit failure is refused
        let prematureForce = await session.forceQuit(processID: 42)
        #expect(prematureForce == false)
        #expect(terminators.forceCalls.isEmpty)

        // Polite quit fails
        let politeSuccess = await session.quit(processID: 42)
        #expect(politeSuccess == false)
        #expect(terminators.politeCalls == [42])
        #expect(session.failedPoliteQuits.contains(42))

        // Now force quit is permitted
        let forceSuccess = await session.forceQuit(processID: 42)
        #expect(forceSuccess == true)
        #expect(terminators.forceCalls == [42])
        #expect(!session.failedPoliteQuits.contains(42))
    }

    @Test("start and stop manage monitoring status")
    @MainActor
    func startAndStopMonitoring() async {
        let (session, _) = makeSession()
        #expect(!session.isMonitoring)

        session.start()
        #expect(session.isMonitoring)

        session.stop()
        #expect(!session.isMonitoring)
    }
}

final class FakeTerminators: Sendable {
    private let politeResult: Bool
    private let forceResult: Bool
    private let politeRecords = Mutex<[pid_t]>([])
    private let forceRecords = Mutex<[pid_t]>([])

    init(politeResult: Bool, forceResult: Bool) {
        self.politeResult = politeResult
        self.forceResult = forceResult
    }

    func polite(_ pid: pid_t) -> Bool {
        politeRecords.withLock { $0.append(pid) }
        return politeResult
    }

    func force(_ pid: pid_t) -> Bool {
        forceRecords.withLock { $0.append(pid) }
        return forceResult
    }

    var politeCalls: [pid_t] { politeRecords.withLock { $0 } }
    var forceCalls: [pid_t] { forceRecords.withLock { $0 } }
}
