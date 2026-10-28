import AppKit
import ClenvraKit
import Foundation
import UserNotifications

/// Runs the scheduled scan (SA-9) while Clenvra is open: read-only totals, then one notification. It has no deleter,
/// so a scheduled scan can never remove anything.
@MainActor
@Observable
final class ScanScheduler {
    /// The most recent scheduled (or "Scan Now") result, shown in the menu bar extra.
    private(set) var lastReport: ScheduledScanReport?
    private(set) var isScanning = false

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Checks every few minutes and on wake; a run missed while the Mac slept happens once.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runIfDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.runIfDue() }
        }
        Task { await runIfDue() }
    }

    func runIfDue() async {
        guard let environment else { return }
        let settings = environment.settings
        guard settings.scanSchedule.isDue(now: Date(), lastRun: settings.lastScheduledScan, calendar: .current)
        else { return }
        await scan(notify: true)
    }

    /// Scans now. Notifies only for scheduled runs, and only when there is something worth saying.
    func scan(notify: Bool) async {
        guard let environment, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let home = environment.home
        let policy = environment.policy
        let ownership = environment.ownership
        let ownerState: @Sendable (String) -> OwnerState = { ownership.state(of: $0) }
        let rules = RuleCatalog.standard
        var input = OverviewRecommendations.Input()
        input.cleanup = await ScheduledScanReport.totals(
            rules: rules.filter { $0.category.section == .cleanup }, home: home, policy: policy,
            ownerState: ownerState)
        input.developer = await ScheduledScanReport.totals(
            rules: rules.filter { $0.category.section == .developer }, home: home, policy: policy,
            ownerState: ownerState)
        let startup = await Task.detached { VolumeInventory.mountedVolumes().first(where: \.isRoot) }.value
        input.freeSpaceRatio = startup?.freeRatio

        let report = ScheduledScanReport.make(input)
        lastReport = report
        var settings = environment.settings
        settings.lastScheduledScan = Date()
        try? environment.apply(settings)
        if notify, report.shouldNotify { await post(report) }
    }

    /// Asked when the user turns the schedule on, never at launch.
    static func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func post(_ report: ScheduledScanReport) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Clenvra scan finished")
        content.body = Self.message(for: report)
        let request = UNNotificationRequest(identifier: "clenvra.scheduledScan", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func message(for report: ScheduledScanReport) -> String {
        switch report.headline {
        case .lowDiskSpace(_, let bytes) where bytes > 0:
            let size = bytes.formatted(.byteCount(style: .file))
            return String(localized: "Your startup disk is almost full. Cleanup could free \(size).")
        case .lowDiskSpace:
            return String(localized: "Your startup disk is almost full.")
        case .canFree(let bytes):
            return String(localized: "Cleanup could free \(bytes.formatted(.byteCount(style: .file))).")
        case .needsAttention(let count):
            return String(localized: "\(count) items need your attention.")
        case .nothingToReport:
            return String(localized: "Nothing needs your attention.")
        }
    }
}
