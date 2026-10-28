public import Foundation

/// When Clenvra scans on its own (SA-9). A schedule only ever reads and reports; it never deletes anything.
public struct ScanSchedule: Codable, Equatable, Sendable {
    /// How often the scan repeats.
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily, weekly
    }

    /// Off by default: nothing runs in the background until the user asks for it.
    public var isEnabled = false
    public var frequency = Frequency.weekly
    /// Local time of day, 0…23.
    public var hour = 10
    /// 0…59.
    public var minute = 0
    /// For weekly schedules: `Calendar` weekday, 1 = Sunday … 7 = Saturday.
    public var weekday = 2

    public init() {}

    /// Values from a damaged or hand-edited file are clamped, and missing ones take the defaults, so a bad file
    /// can never stop settings from loading.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScanSchedule()
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? defaults.isEnabled
        let rawFrequency = try? container.decodeIfPresent(String.self, forKey: .frequency)
        frequency = rawFrequency.flatMap(Frequency.init(rawValue:)) ?? defaults.frequency
        hour = Self.clamped(try? container.decodeIfPresent(Int.self, forKey: .hour), 0...23, defaults.hour)
        minute = Self.clamped(try? container.decodeIfPresent(Int.self, forKey: .minute), 0...59, defaults.minute)
        weekday = Self.clamped(try? container.decodeIfPresent(Int.self, forKey: .weekday), 1...7, defaults.weekday)
    }

    /// The first scheduled moment strictly after `date`, or `nil` when the schedule is off.
    ///
    /// The calendar carries the time zone, so tests and travelling users get the time of day they chose. A time
    /// skipped by a daylight-saving change runs at the next valid moment instead of being dropped.
    public func nextRun(after date: Date, calendar: Calendar) -> Date? {
        guard isEnabled else { return nil }
        var components = DateComponents(hour: hour, minute: minute, second: 0)
        if frequency == .weekly { components.weekday = weekday }
        return calendar.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
            direction: .forward)
    }

    /// Whether a scan should run now. A run missed while the Mac was asleep or Clenvra was closed is due once,
    /// not once per missed slot. Without a recorded last run nothing is due: the app records the moment the
    /// schedule is turned on, so enabling it never triggers an immediate scan.
    public func isDue(now: Date, lastRun: Date?, calendar: Calendar) -> Bool {
        guard let lastRun, let next = nextRun(after: lastRun, calendar: calendar) else { return false }
        return next <= now
    }

    private static func clamped(_ value: Int?, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
        guard let value else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// What a scheduled scan tells the user (SA-9): a plain model the app turns into a notification.
///
/// It is built from the same totals as the Overview, so the notification and the Overview never disagree.
/// It carries numbers, not text, so the app words it in the user's language.
public struct ScheduledScanReport: Sendable, Equatable {
    /// Below this, a notification would interrupt for too little.
    public static let minimumReportedBytes: Int64 = 500_000_000

    /// The single message a notification shows, most urgent first.
    public enum Headline: Sendable, Equatable {
        /// The startup disk is nearly full; `reclaimableBytes` is what cleanup could free (may be 0).
        case lowDiskSpace(freeRatio: Double, reclaimableBytes: Int64)
        /// "Cleanup could free 6.2 GB".
        case canFree(bytes: Int64)
        /// Startup leftovers or security settings that need a look.
        case needsAttention(count: Int)
        /// Nothing worth a notification.
        case nothingToReport
    }

    /// What Cleanup and Developer would free with their default (safe) selection.
    public let reclaimableBytes: Int64
    public let itemCount: Int
    public let headline: Headline
    /// The section a click on the notification opens.
    public let destination: OverviewRecommendations.Destination

    /// The app posts a notification only when this is true.
    public var shouldNotify: Bool { headline != .nothingToReport }

    /// Builds the report from the Overview's inputs. Tool commands are left out: they bypass the Trash and are
    /// never part of a default cleanup.
    public static func make(_ input: OverviewRecommendations.Input) -> ScheduledScanReport {
        let cleanup = input.cleanup ?? .init(bytes: 0, count: 0)
        let developer = input.developer ?? .init(bytes: 0, count: 0)
        let bytes = cleanup.bytes + developer.bytes
        let count = cleanup.count + developer.count
        let spaceDestination: OverviewRecommendations.Destination =
            developer.bytes > cleanup.bytes ? .developer : .cleanup
        let attention = input.startupProblemCount + input.securityAttentionCount

        let headline: Headline
        let destination: OverviewRecommendations.Destination
        if let ratio = input.freeSpaceRatio, ratio < OverviewRecommendations.lowFreeSpaceRatio {
            headline = .lowDiskSpace(freeRatio: ratio, reclaimableBytes: bytes)
            destination = .storage
        } else if bytes >= minimumReportedBytes {
            headline = .canFree(bytes: bytes)
            destination = spaceDestination
        } else if attention > 0 {
            headline = .needsAttention(count: attention)
            destination = input.startupProblemCount > 0 ? .startup : .system
        } else {
            headline = .nothingToReport
            destination = spaceDestination
        }
        return ScheduledScanReport(
            reclaimableBytes: bytes, itemCount: count, headline: headline, destination: destination)
    }

    /// Read-only totals of what `rules` would clean by default, for a scan that runs without any section open.
    ///
    /// It has no deleter: a scheduled scan cannot remove anything by construction. Items found by two rules are
    /// counted once, like the Cleanup section does.
    @concurrent public static func totals(
        rules: [CleanupRule], home: String, policy: ProtectionPolicy,
        ownerState: @escaping @Sendable (String) -> OwnerState, executor: FSExecutor = .shared
    ) async -> OverviewRecommendations.Input.Totals {
        var sizes: [String: Int64] = [:]
        await withTaskGroup(of: RuleScanResult.self) { @concurrent group in
            for rule in rules {
                group.addTask { @concurrent in
                    await RuleScanner.scan(
                        rule, home: home, policy: policy, ownerState: ownerState, executor: executor)
                }
            }
            for await result in group {
                for candidate in result.candidates where candidate.isSelectedByDefault {
                    sizes[candidate.path] = candidate.reclaimableSize
                }
            }
        }
        return .init(bytes: sizes.values.reduce(0, +), count: sizes.count)
    }
}
