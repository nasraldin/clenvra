import ClenvraKit
import SwiftUI

/// The System pages: health, heavy processes, security checks and local snapshots. Each is its own sidebar page.
struct SystemView: View {
    let session: SystemSession
    let snapshots: SnapshotsSession
    let page: SystemTab

    enum SystemTab: String, CaseIterable, Identifiable {
        case health
        case processes
        case security
        case snapshots

        var id: String { rawValue }
    }

    private var pageSection: AppSection {
        switch page {
        case .health: .system
        case .processes: .processes
        case .security: .security
        case .snapshots: .snapshots
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .health:
                    SystemHealthView(session: session)
                case .processes:
                    SystemProcessesView(session: session)
                case .security:
                    SystemSecurityView(session: session)
                case .snapshots:
                    SnapshotsView(session: snapshots)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(pageSection.title))
        }
        .onAppear {
            session.start()
            if session.securityChecks.isEmpty {
                Task { await session.refreshSecurity() }
            }
        }
        .onDisappear {
            session.stop()
        }
    }
}

// MARK: - Health View

private struct SystemHealthView: View {
    let session: SystemSession

    var body: some View {
        if let health = session.health {
            Form {
                memorySection(health: health)
                performanceSection(health: health)
                if let battery = health.battery {
                    batterySection(battery: battery)
                }
            }
            .formStyle(.grouped)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func memorySection(health: SystemHealth) -> some View {
        Section {
            LabeledContent {
                pressureBadge(level: health.memoryPressure)
            } label: {
                Text("Memory Pressure")
            }
            VStack(alignment: .leading, spacing: 10) {
                MemoryDistributionBar(health: health)
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        legendItem(color: .blue, title: "App Memory", bytes: health.appMemory)
                        legendItem(color: .purple, title: "Wired Memory", bytes: health.wiredMemory)
                    }
                    GridRow {
                        legendItem(color: .orange, title: "Compressed Memory", bytes: health.compressedMemory)
                        legendItem(color: .green, title: "Available Memory", bytes: health.availableMemory)
                    }
                }
            }
            .padding(.vertical, 4)
            LabeledContent {
                SizeText(bytes: Int64(health.totalPhysicalMemory))
            } label: {
                Text("Total RAM")
            }
            LabeledContent {
                SizeText(bytes: Int64(health.swapUsed))
            } label: {
                Text("Swap Used")
            }
        } header: {
            Text("Memory")
        } footer: {
            Text(
                "macOS manages memory dynamically. High used memory is normal and keeps the system responsive; memory pressure is the true indicator of memory constraint."
            )
            .font(.callout)
        }
    }

    @ViewBuilder private func pressureBadge(level: MemoryPressureLevel) -> some View {
        switch level {
        case .normal: statusLabel("Normal", "checkmark.circle.fill", .green)
        case .warning: statusLabel("Warning", "exclamationmark.triangle.fill", .orange)
        case .critical: statusLabel("Critical", "exclamationmark.octagon.fill", .red)
        }
    }

    /// Only the symbol carries the status color: green or yellow text is unreadable on a light background.
    private func statusLabel(_ title: LocalizedStringResource, _ icon: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
    }

    private func legendItem(color: Color, title: LocalizedStringResource, bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
            SizeText(bytes: Int64(bytes))
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func performanceSection(health: SystemHealth) -> some View {
        Section {
            LabeledContent {
                Text(health.cpuLoadPercent / 100, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
            } label: {
                Text("CPU Usage")
            }
            LabeledContent {
                thermalBadge(state: health.thermalState)
            } label: {
                Text("Thermal State")
            }
            LabeledContent {
                Text(formatUptime(seconds: health.uptime))
            } label: {
                Text("Uptime")
            }
        } header: {
            Text("System Performance")
        }
    }

    @ViewBuilder private func thermalBadge(state: ThermalState) -> some View {
        switch state {
        case .nominal: statusLabel("Normal", "thermometer.low", .green)
        case .fair: statusLabel("Fair", "thermometer.medium", .yellow)
        case .serious: statusLabel("Serious", "thermometer.high", .orange)
        case .critical: statusLabel("Critical", "exclamationmark.triangle.fill", .red)
        }
    }

    private func batterySection(battery: BatteryHealth) -> some View {
        Section {
            LabeledContent {
                Text(Double(battery.chargePercent) / 100, format: .percent)
                    .monospacedDigit()
            } label: {
                Text("Charge")
            }
            if let maxCap = battery.maxCapacityPercent {
                LabeledContent {
                    Text(Double(maxCap) / 100, format: .percent)
                        .monospacedDigit()
                } label: {
                    Text("Maximum Capacity")
                }
            }
            if let cycles = battery.cycleCount {
                LabeledContent {
                    Text(cycles, format: .number)
                } label: {
                    Text("Cycle Count")
                }
            }
            if let condition = battery.condition {
                LabeledContent {
                    Text(verbatim: condition)
                } label: {
                    Text("Condition")
                }
            }
        } header: {
            Text("Battery")
        }
    }

    /// Localized by Foundation (e.g. "3 days, 4 hr" / Arabic equivalents), never hand-built English units.
    private func formatUptime(seconds: TimeInterval) -> String {
        Duration.seconds(max(60, seconds)).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// Proportional segmented bar visualizing App, Wired, Compressed, and Available memory.
private struct MemoryDistributionBar: View {
    let health: SystemHealth

    var body: some View {
        GeometryReader { geometry in
            let total = Double(max(1, health.totalPhysicalMemory))
            let appRatio = Double(health.appMemory) / total
            let wiredRatio = Double(health.wiredMemory) / total
            let compRatio = Double(health.compressedMemory) / total
            let availRatio = Double(health.availableMemory) / total

            HStack(spacing: 1) {
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: max(0, geometry.size.width * appRatio))
                Rectangle()
                    .fill(Color.purple)
                    .frame(width: max(0, geometry.size.width * wiredRatio))
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: max(0, geometry.size.width * compRatio))
                Rectangle()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: max(0, geometry.size.width * availRatio))
            }
        }
    }
}

// MARK: - Heavy Processes View

private struct SystemProcessesView: View {
    let session: SystemSession

    enum ProcessSortOrder: String, CaseIterable, Identifiable {
        case cpu
        case memory

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .cpu: "CPU"
            case .memory: "Memory"
            }
        }
    }

    @State private var sortOrder: ProcessSortOrder = .cpu
    @State private var targetProcessForQuit: ProcessInfoItem?
    @State private var isForceQuit = false
    @State private var selected: ProcessInfoItem.ID?

    private var selectedProcess: ProcessInfoItem? { processes.first { $0.id == selected } }

    /// Quit (or Force Quit after a polite quit failed) the given app, after confirmation.
    private func requestQuit(_ proc: ProcessInfoItem) {
        guard proc.isQuittableApp else { return }
        isForceQuit = session.failedPoliteQuits.contains(proc.id)
        targetProcessForQuit = proc
    }

    private var processes: [ProcessInfoItem] {
        switch sortOrder {
        case .cpu: return session.topByCPU
        case .memory: return session.topByMemory
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(selection: $sortOrder) {
                    ForEach(ProcessSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                } label: {
                    Text("Sort by")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
                .visibleLabel("Sort by")

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if processes.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No heavy processes detected")
                    } icon: {
                        Image(systemName: "cpu")
                    }
                } description: {
                    Text("Sampling active host processes…")
                }
                .frame(maxHeight: .infinity)
            } else {
                Table(processes, selection: $selected) {
                    TableColumn("Process") { proc in
                        HStack(spacing: 8) {
                            Image(systemName: proc.appBundlePath != nil ? "app.dashed" : "terminal")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proc.name)
                                    .fontWeight(.medium)
                                PathText(path: proc.executablePath)
                            }
                        }
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("CPU") { proc in
                        Text(proc.cpuPercent / 100, format: .percent.precision(.fractionLength(1)))
                            .monospacedDigit()
                    }
                    .width(ideal: 80)

                    TableColumn("Memory") { proc in
                        SizeText(bytes: Int64(proc.memoryBytes))
                    }
                    .width(ideal: 100)

                    TableColumn("Kind") { proc in
                        Text(proc.isQuittableApp ? "App" : "Not an App")
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 100)
                }
                .accessibilityLabel(Text("Processes"))
                .contextMenu(forSelectionType: ProcessInfoItem.ID.self) { ids in
                    if let id = ids.first, let proc = processes.first(where: { $0.id == id }), proc.isQuittableApp {
                        Button {
                            requestQuit(proc)
                        } label: {
                            Text(session.failedPoliteQuits.contains(proc.id) ? "Force Quit…" : "Quit…")
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    if let proc = selectedProcess { requestQuit(proc) }
                } label: {
                    Label {
                        Text(
                            selectedProcess.map { session.failedPoliteQuits.contains($0.id) } == true
                                ? "Force Quit…" : "Quit…")
                    } icon: {
                        Image(systemName: "xmark.octagon")
                    }
                }
                .help(Text("Quit the selected app (it is asked to save its work first)"))
                .disabled(selectedProcess?.isQuittableApp != true)
            }
        }
        .confirmationDialog(
            isForceQuit ? "Force Quit Application" : "Quit Application",
            isPresented: Binding(
                get: { targetProcessForQuit != nil },
                set: { if !$0 { targetProcessForQuit = nil } }
            ),
            presenting: targetProcessForQuit
        ) { proc in
            if isForceQuit {
                Button("Force Quit", role: .destructive) {
                    Task { await session.forceQuit(processID: proc.id) }
                }
            } else {
                Button("Quit", role: .destructive) {
                    Task { await session.quit(processID: proc.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                targetProcessForQuit = nil
            }
        } message: { proc in
            if isForceQuit {
                Text(
                    "Force quitting immediately terminates \(proc.name). Any unsaved data will be lost."
                )
            } else {
                Text(
                    "Are you sure you want to quit \(proc.name)? Unsaved changes may be lost."
                )
            }
        }
    }
}

// MARK: - Security View

private struct SystemSecurityView: View {
    let session: SystemSession

    var body: some View {
        Form {
            Section {
                ForEach(session.securityChecks) { check in
                    SecurityCheckRow(check: check)
                }
            } header: {
                Text("Security Protections")
            } footer: {
                Text("Clenvra only reads these settings. Change them in System Settings.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await session.refreshSecurity() }
                } label: {
                    Label {
                        Text("Check Again")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(Text("Read the security settings again (⌘R)"))
                .disabled(session.isCheckingSecurity)
            }
        }
    }
}

private struct SecurityCheckRow: View {
    let check: SecurityCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .accessibilityHidden(true)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(for: check.id))
                        .fontWeight(.medium)
                    Spacer()
                    statusLabel
                }

                Text(explanation(for: check.id))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(verbatim: check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)

                if let url = check.settingsURL {
                    Link("Open System Settings", destination: url)
                        .font(.callout)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch check.status {
        case .good:
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .imageScale(.large)
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .imageScale(.large)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch check.status {
        case .good:
            Text("Good")
        case .attention:
            Text("Attention")
        case .unknown:
            Text("Unknown")
        }
    }

    private func title(for id: String) -> LocalizedStringResource {
        switch id {
        case "sip": "System Integrity Protection"
        case "fileVault": "FileVault"
        case "gatekeeper": "Gatekeeper"
        case "firewall": "Firewall"
        case "xprotect": "XProtect"
        case "securityUpdates": "Security Updates"
        default: "Security Check"
        }
    }

    private func explanation(for id: String) -> LocalizedStringResource {
        switch id {
        case "sip": "Protects system-owned files and directories against unauthorized modification."
        case "fileVault": "Encrypts the system volume to prevent unauthorized access to your data."
        case "gatekeeper": "Enforces signature and notarization checks before opening downloaded apps."
        case "firewall": "Blocks unwanted incoming network connections and services."
        case "xprotect": "Apple built-in signature engine that detects and blocks known malware."
        case "securityUpdates": "Ensures critical security updates and system definitions install automatically."
        default: "Verifies macOS security configuration."
        }
    }
}

extension ProcessInfoItem {
    /// A regular app outside the system folders, and not Clenvra itself.
    fileprivate var isQuittableApp: Bool {
        guard let bundle = appBundlePath, !bundle.hasPrefix("/System/") else { return false }
        return bundle != Bundle.main.bundlePath
    }
}

// MARK: - Local Time Machine snapshots

/// Local snapshots Time Machine keeps on the startup disk. macOS deletes them by itself when space runs low; deleting
/// one by hand frees space now but loses that restore point.
private struct SnapshotsView: View {
    let session: SnapshotsSession
    @State private var confirming: String?
    @State private var message: LocalizedStringResource?

    var body: some View {
        Form {
            Section {
                if session.snapshots.isEmpty {
                    Text(session.isLoading ? "Looking for snapshots…" : "No local snapshots on this Mac.")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.snapshots, id: \.self) { snapshot in
                    LabeledContent {
                        if session.canDelete {
                            Button(role: .destructive) {
                                confirming = snapshot
                            } label: {
                                Text("Delete…")
                            }
                        }
                    } label: {
                        if let date = LocalSnapshots.date(of: snapshot) {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        } else {
                            Text(verbatim: snapshot)
                        }
                    }
                }
            } header: {
                Text("Local Time Machine Snapshots")
            } footer: {
                Text(
                    session.canDelete
                        ? "macOS removes these by itself when space runs low. Deleting one frees space now, but you can no longer restore from it. This cannot be undone."
                        : "macOS removes these by itself when space runs low. To delete one now, install the System Helper in Settings."
                )
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .task { await session.load() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await session.load() }
                } label: {
                    Label {
                        Text("Refresh")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(Text("List the snapshots again (⌘R)"))
                .disabled(session.isLoading)
            }
        }
        .confirmationDialog(
            Text("Delete this snapshot?"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            Button(role: .destructive) {
                guard let snapshot = confirming else { return }
                Task {
                    let outcome = await session.delete(snapshot)
                    message = outcome == .deleted ? nil : "The snapshot could not be deleted."
                }
            } label: {
                Text("Delete Snapshot")
            }
        } message: {
            Text("You can no longer restore your Mac to this point. This cannot be undone.")
        }
        .alert(
            Text("Snapshots"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
        } message: {
            if let message { Text(message) }
        }
    }
}
