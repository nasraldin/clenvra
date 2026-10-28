import AppKit
import ClenvraKit
import SwiftUI

/// The optional menu bar extra (SY-5): free space, the next scheduled scan and its last result, and Scan Now.
/// Read-only, like a scheduled scan; cleaning always happens in the main window, after review.
struct MenuBarExtraView: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @State private var startup: Volume?

    var body: some View {
        if let startup {
            Text("\(startup.availableCapacity.formatted(.byteCount(style: .file))) free on \(startup.name)")
        }
        if let report = environment.scheduler.lastReport {
            Text(ScanScheduler.message(for: report))
        }
        if environment.settings.scanSchedule.isEnabled,
            let next = environment.settings.scanSchedule.nextRun(after: Date(), calendar: .current)
        {
            Text("Next scan \(next.formatted(.dateTime.weekday().hour().minute()))")
        }
        Divider()
        Button {
            Task { await environment.scheduler.scan(notify: false) }
        } label: {
            Text(environment.scheduler.isScanning ? "Scanning…" : "Scan Now")
        }
        .disabled(environment.scheduler.isScanning)
        Button {
            NSApp.activate()
            openWindow(id: "main")
        } label: {
            Text("Open Clenvra")
        }
        .task { startup = await Task.detached { VolumeInventory.mountedVolumes().first(where: \.isRoot) }.value }
    }
}

extension MenuBarExtraView {
    static let preferenceKey = "clenvra.showsMenuBarExtra"
}
