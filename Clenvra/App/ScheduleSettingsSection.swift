import ClenvraKit
import SwiftUI

/// Scheduled scans (SA-9): off by default; they only report, never delete.
struct ScheduleSettingsSection: View {
    let environment: AppEnvironment

    var body: some View {
        Section {
            Toggle(isOn: binding(\.isEnabled)) {
                Text("Scan on a schedule")
            }
            .accessibilityIdentifier("settings.schedule.enabled")
            if environment.settings.scanSchedule.isEnabled {
                Picker(selection: binding(\.frequency)) {
                    Text("Every day").tag(ScanSchedule.Frequency.daily)
                    Text("Every week").tag(ScanSchedule.Frequency.weekly)
                } label: {
                    Text("How often")
                }
                if environment.settings.scanSchedule.frequency == .weekly {
                    Picker(selection: binding(\.weekday)) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    } label: {
                        Text("Day")
                    }
                }
                DatePicker(selection: time, displayedComponents: .hourAndMinute) {
                    Text("Time")
                }
                if let next = environment.settings.scanSchedule.nextRun(after: Date(), calendar: .current) {
                    LabeledContent {
                        Text(next, format: .dateTime.weekday().day().month().hour().minute())
                    } label: {
                        Text("Next scan")
                    }
                }
            }
        } header: {
            Text("Scheduled Scans")
        } footer: {
            Text(
                "While Clenvra is open, it looks for what could be cleaned and tells you in a notification. It never removes anything by itself."
            )
            .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ScanSchedule, Value>) -> Binding<Value> {
        Binding(
            get: { environment.settings.scanSchedule[keyPath: keyPath] },
            set: { value in
                var settings = environment.settings
                let wasEnabled = settings.scanSchedule.isEnabled
                settings.scanSchedule[keyPath: keyPath] = value
                // Count from now, so turning it on does not fire at once; ask for notifications only now.
                if !wasEnabled, settings.scanSchedule.isEnabled {
                    settings.lastScheduledScan = Date()
                    Task { await ScanScheduler.requestNotificationPermission() }
                }
                try? environment.apply(settings)
            })
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                let schedule = environment.settings.scanSchedule
                return Calendar.current.date(
                    bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                var settings = environment.settings
                settings.scanSchedule.hour = parts.hour ?? 10
                settings.scanSchedule.minute = parts.minute ?? 0
                try? environment.apply(settings)
            })
    }
}
