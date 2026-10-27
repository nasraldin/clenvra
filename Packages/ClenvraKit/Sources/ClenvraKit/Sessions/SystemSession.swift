public import Darwin
public import Foundation

/// Manages live system telemetry, heavy process monitoring, process termination, and security status.
@MainActor
@Observable
public final class SystemSession {
    /// Closure invoked to politely ask an application to terminate.
    public typealias ProcessTerminator = @Sendable (pid_t) -> Bool

    /// Latest snapshot of system memory, CPU load, swap, thermal state, and battery.
    public private(set) var health: SystemHealth?

    /// Active heavy processes ranked by CPU percentage descending.
    public private(set) var topByCPU: [ProcessInfoItem] = []

    /// Active heavy processes ranked by memory footprint descending.
    public private(set) var topByMemory: [ProcessInfoItem] = []

    /// Current evaluation of macOS security protections.
    public private(set) var securityChecks: [SecurityCheck] = []

    /// Whether recurring monitoring tasks are actively polling.
    public private(set) var isMonitoring: Bool = false

    /// Whether an on-demand security check is currently executing.
    public private(set) var isCheckingSecurity: Bool = false

    /// Process IDs for which a polite termination request was attempted and did not succeed.
    public private(set) var failedPoliteQuits: Set<pid_t> = []

    private let healthSampler: HealthSampler
    private let processSampler: ProcessSampler
    private let securityChecker: SecurityChecker
    private let politeTerminator: ProcessTerminator
    private let forceTerminator: ProcessTerminator
    private let healthInterval: Duration
    private let processInterval: Duration

    private var healthTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?

    /// Creates a system session with injected samplers and terminators.
    public init(
        healthSampler: HealthSampler = HealthSampler(),
        processSampler: ProcessSampler = ProcessSampler(),
        securityChecker: SecurityChecker = SecurityChecker(),
        politeTerminator: @escaping ProcessTerminator = { _ in true },
        forceTerminator: @escaping ProcessTerminator = { _ in true },
        healthInterval: Duration = .seconds(2),
        processInterval: Duration = .seconds(3)
    ) {
        self.healthSampler = healthSampler
        self.processSampler = processSampler
        self.securityChecker = securityChecker
        self.politeTerminator = politeTerminator
        self.forceTerminator = forceTerminator
        self.healthInterval = healthInterval
        self.processInterval = processInterval
    }

    /// Begins periodic background sampling while the system view is visible.
    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        healthTask = Task { [weak self, healthInterval] in
            while !Task.isCancelled {
                await self?.refreshHealth()
                do {
                    try await Task.sleep(for: healthInterval)
                } catch {
                    break
                }
            }
        }

        processTask = Task { [weak self, processInterval] in
            while !Task.isCancelled {
                await self?.refreshProcesses()
                do {
                    try await Task.sleep(for: processInterval)
                } catch {
                    break
                }
            }
        }
    }

    /// Stops recurring background sampling tasks when the system view is hidden.
    public func stop() {
        isMonitoring = false
        healthTask?.cancel()
        healthTask = nil
        processTask?.cancel()
        processTask = nil
    }

    /// Samples live health telemetry immediately.
    public func refreshHealth() async {
        do {
            let sample = try healthSampler.sample()
            self.health = sample
        } catch {
            // Keep previous sample on transient sampling failure
        }
    }

    /// Samples running processes and updates CPU and memory rankings.
    public func refreshProcesses() async {
        do {
            let result = try await processSampler.sample()
            self.topByCPU = result.topByCPU
            self.topByMemory = result.topByMemory
        } catch {
            // Keep previous lists on transient sampling failure
        }
    }

    /// Performs an on-demand audit of macOS system security controls.
    public func refreshSecurity() async {
        guard !isCheckingSecurity else { return }
        isCheckingSecurity = true
        defer { isCheckingSecurity = false }

        let checks = await securityChecker.checkAll()
        self.securityChecks = checks
    }

    /// Politely requests that an application quit via NSRunningApplication.
    @discardableResult
    public func quit(processID: pid_t) async -> Bool {
        let success = politeTerminator(processID)
        if !success {
            failedPoliteQuits.insert(processID)
        }
        await refreshProcesses()
        return success
    }

    /// Forcefully terminates a process only after a polite quit attempt has failed.
    @discardableResult
    public func forceQuit(processID: pid_t) async -> Bool {
        guard failedPoliteQuits.contains(processID) else {
            return false
        }
        let success = forceTerminator(processID)
        failedPoliteQuits.remove(processID)
        await refreshProcesses()
        return success
    }
}
