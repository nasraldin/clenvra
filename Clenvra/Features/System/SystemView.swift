import ClenvraKit
import SwiftUI

/// Displays system health diagnostics, heavy processes, and macOS security posture.
struct SystemView: View {
    let session: SystemSession
    let snapshots: SnapshotsSession

    enum SystemTab: String, CaseIterable, Identifiable {
        case health
        case processes
        case security
        case snapshots

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .health: "Health"
            case .processes: "Heavy Processes"
            case .security: "Security"
            case .snapshots: "Snapshots"
            }
        }

        var symbol: String {
            switch self {
            case .health: "heart.text.square"
            case .processes: "cpu"
            case .security: "shield"
            case .snapshots: "clock.arrow.circlepath"
            }
        }
    }

    @State private var selectedTab: SystemTab = .health

    var body: some View {
        VStack(spacing: 0) {
            tabSelector
            Divider()
            Group {
                switch selectedTab {
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
            .accessibilityIdentifier("review.results")
        }
        .navigationTitle(Text("System"))
        .onAppear {
            session.start()
            if session.securityChecks.isEmpty {
                Task { await session.refreshSecurity() }
            }
        }
        .onDisappear {
            session.stop()
        }
        .accessibilityIdentifier("section.system")
    }

    private var tabSelector: some View {
        Picker("System View", selection: $selectedTab) {
            ForEach(SystemTab.allCases) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.symbol)
                }
                .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Health View

private struct SystemHealthView: View {
    let session: SystemSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let health = session.health {
                    memoryPressureSection(health: health)
                    memoryBreakdownSection(health: health)
                    systemMetricsSection(health: health)
                    if let battery = health.battery {
                        batterySection(battery: battery)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func memoryPressureSection(health: SystemHealth) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory Pressure")
                        .font(.headline)
                    Spacer()
                    pressureBadge(level: health.memoryPressure)
                }
                Text(
                    "macOS manages memory dynamically. High used memory is normal and keeps the system responsive; memory pressure is the true indicator of memory constraint."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func pressureBadge(level: MemoryPressureLevel) -> some View {
        let (title, icon, color): (LocalizedStringResource, String, Color) = {
            switch level {
            case .normal:
                return ("Normal", "checkmark.circle.fill", .green)
            case .warning:
                return ("Warning", "exclamationmark.triangle.fill", .orange)
            case .critical:
                return ("Critical", "exclamationmark.octagon.fill", .red)
            }
        }()

        Label {
            Text(title)
                .fontWeight(.medium)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func memoryBreakdownSection(health: SystemHealth) -> some View {
        GroupBox(label: Text("Memory Usage").font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                MemoryDistributionBar(health: health)
                    .frame(height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

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

                Divider()

                HStack {
                    Text("Total RAM")
                        .foregroundStyle(.secondary)
                    SizeText(bytes: Int64(health.totalPhysicalMemory))
                        .fontWeight(.medium)

                    Spacer()

                    Text("Swap Used")
                        .foregroundStyle(.secondary)
                    SizeText(bytes: Int64(health.swapUsed))
                        .fontWeight(.medium)
                }
                .font(.callout)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func legendItem(color: Color, title: LocalizedStringResource, bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            SizeText(bytes: Int64(bytes))
                .fontWeight(.medium)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func systemMetricsSection(health: SystemHealth) -> some View {
        GroupBox(label: Text("System Performance").font(.headline)) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("CPU Usage")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(health.cpuLoadPercent, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                            .fontWeight(.medium)
                        Text(verbatim: "%")
                    }

                    Text("Uptime")
                        .foregroundStyle(.secondary)
                    Text(formatUptime(seconds: health.uptime))
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Thermal State")
                        .foregroundStyle(.secondary)
                    thermalBadge(state: health.thermalState)
                }
            }
            .font(.callout)
            .padding(4)
        }
    }

    @ViewBuilder
    private func thermalBadge(state: ThermalState) -> some View {
        let (title, icon, color): (LocalizedStringResource, String, Color) = {
            switch state {
            case .nominal: return ("Normal", "thermometer.low", .green)
            case .fair: return ("Fair", "thermometer.medium", .yellow)
            case .serious: return ("Serious", "thermometer.high", .orange)
            case .critical: return ("Critical", "exclamationmark.triangle.fill", .red)
            }
        }()

        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func batterySection(battery: BatteryHealth) -> some View {
        GroupBox(label: Text("Battery").font(.headline)) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("Charge")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Text(battery.chargePercent.formatted())
                            .monospacedDigit()
                            .fontWeight(.medium)
                        Text(verbatim: "%")
                    }

                    if let cycles = battery.cycleCount {
                        Text("Cycle Count")
                            .foregroundStyle(.secondary)
                        Text(cycles.formatted())
                            .fontWeight(.medium)
                    }
                }
                if let maxCap = battery.maxCapacityPercent {
                    GridRow {
                        Text("Maximum Capacity")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 2) {
                            Text(maxCap.formatted())
                                .monospacedDigit()
                                .fontWeight(.medium)
                            Text(verbatim: "%")
                        }

                        if let condition = battery.condition {
                            Text("Condition")
                                .foregroundStyle(.secondary)
                            Text(verbatim: condition)
                                .fontWeight(.medium)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(4)
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

    private var processes: [ProcessInfoItem] {
        switch sortOrder {
        case .cpu: return session.topByCPU
        case .memory: return session.topByMemory
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sort by")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Sort Order", selection: $sortOrder) {
                    ForEach(ProcessSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

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
                Table(processes) {
                    TableColumn("Process") { proc in
                        HStack(spacing: 8) {
                            Image(systemName: proc.appBundlePath != nil ? "app.dashed" : "terminal")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proc.name)
                                    .fontWeight(.medium)
                                PathText(path: proc.executablePath)
                            }
                        }
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("CPU") { proc in
                        HStack(spacing: 2) {
                            Text(proc.cpuPercent, format: .number.precision(.fractionLength(1)))
                                .monospacedDigit()
                            Text(verbatim: "%")
                        }
                    }
                    .width(ideal: 80)

                    TableColumn("Memory") { proc in
                        SizeText(bytes: Int64(proc.memoryBytes))
                    }
                    .width(ideal: 100)

                    TableColumn("Action") { proc in
                        let failedPolite = session.failedPoliteQuits.contains(proc.id)
                        // Only apps the user runs can be quit; macOS processes and command-line tools cannot.
                        if !proc.isQuittableApp {
                            EmptyView()
                        } else if failedPolite {
                            Button(role: .destructive) {
                                targetProcessForQuit = proc
                                isForceQuit = true
                            } label: {
                                Text("Force Quit")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else {
                            Button {
                                targetProcessForQuit = proc
                                isForceQuit = false
                            } label: {
                                Text("Quit")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .width(ideal: 100)
                }
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
        List {
            Section {
                ForEach(session.securityChecks) { check in
                    SecurityCheckRow(check: check)
                }
            } header: {
                HStack {
                    Text("Security Protections")
                    Spacer()
                    if session.isCheckingSecurity {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task { await session.refreshSecurity() }
                        } label: {
                            Label {
                                Text("Check Again")
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

private struct SecurityCheckRow: View {
    let check: SecurityCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                .font(.caption)
                .foregroundStyle(.green)
        case .attention:
            Text("Attention")
                .font(.caption)
                .foregroundStyle(.orange)
        case .unknown:
            Text("Unknown")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await session.load() }
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
