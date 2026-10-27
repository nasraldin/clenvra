import Foundation
import Testing

@testable import ClenvraKit

@Suite("ScanSchedule")
struct ScanScheduleTests {
    private static func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    private static func date(_ text: String, _ calendar: Calendar) throws -> Date {
        let parts = text.split(whereSeparator: { "- :".contains($0) }).compactMap { Int($0) }
        try #require(parts.count == 5)
        let components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: 0)
        return try #require(calendar.date(from: components))
    }

    private static func daily(hour: Int, minute: Int = 0) -> ScanSchedule {
        var schedule = ScanSchedule()
        schedule.isEnabled = true
        schedule.frequency = .daily
        schedule.hour = hour
        schedule.minute = minute
        return schedule
    }

    @Test("the schedule is off by default, so nothing runs until the user turns it on")
    func offByDefault() throws {
        let calendar = try Self.calendar("UTC")
        let schedule = ScanSchedule()
        #expect(!schedule.isEnabled)
        #expect(schedule.nextRun(after: Date(), calendar: calendar) == nil)
        #expect(!schedule.isDue(now: Date(), lastRun: Date(timeIntervalSince1970: 0), calendar: calendar))
    }

    @Test("a daily schedule runs later today when the time has not passed, otherwise tomorrow")
    func dailyNextRun() throws {
        let calendar = try Self.calendar("Asia/Riyadh")
        let schedule = Self.daily(hour: 9, minute: 30)

        let morning = try Self.date("2026-10-27 08:00", calendar)
        #expect(schedule.nextRun(after: morning, calendar: calendar) == (try Self.date("2026-10-27 09:30", calendar)))

        let evening = try Self.date("2026-10-27 18:00", calendar)
        #expect(schedule.nextRun(after: evening, calendar: calendar) == (try Self.date("2026-10-28 09:30", calendar)))

        let exactly = try Self.date("2026-10-27 09:30", calendar)
        #expect(schedule.nextRun(after: exactly, calendar: calendar) == (try Self.date("2026-10-28 09:30", calendar)))
    }

    @Test("a weekly schedule runs on the chosen weekday")
    func weeklyNextRun() throws {
        let calendar = try Self.calendar("UTC")
        var schedule = Self.daily(hour: 10)
        schedule.frequency = .weekly
        schedule.weekday = 2  // Monday

        // 2026-10-27 is a Tuesday.
        let tuesday = try Self.date("2026-10-27 12:00", calendar)
        #expect(schedule.nextRun(after: tuesday, calendar: calendar) == (try Self.date("2026-11-02 10:00", calendar)))
    }

    @Test("the time of day follows the injected time zone")
    func timeZoneInjection() throws {
        let schedule = Self.daily(hour: 9)
        let instant = try Self.date("2026-10-27 12:00", try Self.calendar("UTC"))

        let inTokyo = try #require(schedule.nextRun(after: instant, calendar: try Self.calendar("Asia/Tokyo")))
        let inNewYork = try #require(schedule.nextRun(after: instant, calendar: try Self.calendar("America/New_York")))

        #expect(inTokyo == (try Self.date("2026-10-28 09:00", try Self.calendar("Asia/Tokyo"))))
        // 12:00 UTC is already evening in Tokyo but still morning in New York.
        #expect(inNewYork == (try Self.date("2026-10-27 09:00", try Self.calendar("America/New_York"))))
    }

    @Test("a time skipped by a daylight-saving change still produces a run instead of none")
    func daylightSavingGap() throws {
        let calendar = try Self.calendar("America/New_York")
        let schedule = Self.daily(hour: 2, minute: 30)
        // 2027-03-14 02:30 does not exist in New York (clocks jump from 02:00 to 03:00).
        let before = try Self.date("2027-03-13 23:00", calendar)

        let next = try #require(schedule.nextRun(after: before, calendar: calendar))

        #expect(next > before)
        #expect(next.timeIntervalSince(before) < 86_400)
    }

    @Test("a run is due once the scheduled time after the last run has passed, including runs missed while asleep")
    func dueness() throws {
        let calendar = try Self.calendar("UTC")
        let schedule = Self.daily(hour: 9)
        let lastRun = try Self.date("2026-10-26 09:00", calendar)

        #expect(!schedule.isDue(now: try Self.date("2026-10-27 08:59", calendar), lastRun: lastRun, calendar: calendar))
        #expect(schedule.isDue(now: try Self.date("2026-10-27 09:00", calendar), lastRun: lastRun, calendar: calendar))
        #expect(schedule.isDue(now: try Self.date("2026-10-30 15:00", calendar), lastRun: lastRun, calendar: calendar))
    }

    @Test("without a recorded last run nothing is due; the app records the moment the schedule was turned on")
    func noLastRun() throws {
        let calendar = try Self.calendar("UTC")
        #expect(!Self.daily(hour: 9).isDue(now: Date(), lastRun: nil, calendar: calendar))
    }

    @Test("out-of-range values from a damaged settings file are clamped instead of failing")
    func decodingClamps() throws {
        let json = #"{"isEnabled": true, "frequency": "hourly", "hour": 99, "minute": -4, "weekday": 12}"#
        let schedule = try JSONDecoder().decode(ScanSchedule.self, from: Data(json.utf8))

        #expect(schedule.isEnabled)
        #expect(schedule.frequency == .weekly)
        #expect(schedule.hour == 23)
        #expect(schedule.minute == 0)
        #expect(schedule.weekday == 7)
    }

    @Test("missing fields take the defaults")
    func decodingDefaults() throws {
        let schedule = try JSONDecoder().decode(ScanSchedule.self, from: Data("{}".utf8))
        #expect(schedule == ScanSchedule())
    }
}

@Suite("ScheduledScanReport")
struct ScheduledScanReportTests {
    private typealias Input = OverviewRecommendations.Input

    @Test("the report adds up what Cleanup and Developer would free by default")
    func canFree() {
        var input = Input()
        input.cleanup = .init(bytes: 4_000_000_000, count: 30)
        input.developer = .init(bytes: 2_200_000_000, count: 5)

        let report = ScheduledScanReport.make(input)

        #expect(report.reclaimableBytes == 6_200_000_000)
        #expect(report.itemCount == 35)
        #expect(report.headline == .canFree(bytes: 6_200_000_000))
        #expect(report.destination == .cleanup)
        #expect(report.shouldNotify)
    }

    @Test("tool commands are not counted: they are irreversible and never cleaned by default")
    func toolsExcluded() {
        var input = Input()
        input.tools = [.init(id: "npm", name: "npm", bytes: 9_000_000_000, command: "npm cache clean --force")]
        let report = ScheduledScanReport.make(input)
        #expect(report.reclaimableBytes == 0)
        #expect(!report.shouldNotify)
    }

    @Test("small amounts do not interrupt the user")
    func belowThreshold() {
        var input = Input()
        input.cleanup = .init(bytes: ScheduledScanReport.minimumReportedBytes - 1, count: 3)
        let report = ScheduledScanReport.make(input)
        #expect(report.headline == .nothingToReport)
        #expect(!report.shouldNotify)
    }

    @Test("low disk space is reported first and leads to Storage")
    func lowDiskFirst() {
        var input = Input()
        input.cleanup = .init(bytes: 6_000_000_000, count: 3)
        input.freeSpaceRatio = 0.04
        let report = ScheduledScanReport.make(input)
        #expect(report.headline == .lowDiskSpace(freeRatio: 0.04, reclaimableBytes: 6_000_000_000))
        #expect(report.destination == .storage)
    }

    @Test("the larger of Cleanup and Developer decides where the notification leads")
    func destinationFollowsBytes() {
        var input = Input()
        input.cleanup = .init(bytes: 1_000_000_000, count: 3)
        input.developer = .init(bytes: 5_000_000_000, count: 3)
        #expect(ScheduledScanReport.make(input).destination == .developer)
    }

    @Test("startup leftovers and security findings are reported when there is no space to free")
    func attention() {
        var input = Input()
        input.startupProblemCount = 2
        input.securityAttentionCount = 1
        let report = ScheduledScanReport.make(input)
        #expect(report.headline == .needsAttention(count: 3))
        #expect(report.destination == .startup)
    }

    @Test("the background totals count only safe, available items and never the same path twice")
    func totalsFromRules() async throws {
        let scratch = try TemporaryDirectory()
        let fixture = FixtureBuilder(root: scratch.url)
        try fixture.file("Library/Caches/com.vendor.app/blob", bytes: 50_000)
        try fixture.file("Library/Caches/com.vendor.busy/blob", bytes: 50_000)
        try fixture.file("Downloads/setup.dmg", bytes: 50_000)
        let home = String(scratch.url.path(percentEncoded: false).dropLast())
        let rules = RuleCatalog.standard.filter { [.appCaches, .installers].contains($0.category) }

        let totals = await ScheduledScanReport.totals(
            rules: rules + rules, home: home, policy: ProtectionPolicy(home: home),
            ownerState: { $0 == "com.vendor.busy" ? .running : .notRunning })

        #expect(totals.count == 1)
        #expect(totals.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: home + "/Library/Caches/com.vendor.app/blob"))
    }
}
