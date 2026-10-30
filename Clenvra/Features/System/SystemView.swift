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

    @State private var searchText = ""

    private var searchPrompt: LocalizedStringResource {
        switch page {
        case .health: "Search Health"
        case .processes: "Search Processes"
        case .security: "Search Security Checks"
        case .snapshots: "Search Snapshots"
        }
    }

    var body: some View {
        let query = AppSearch.normalized(searchText)
        VStack(spacing: 0) {
            Group {
                switch page {
                case .health:
                    SystemHealthView(session: session, query: query)
                case .processes:
                    SystemProcessesView(session: session, query: query)
                case .security:
                    SystemSecurityView(session: session, query: query)
                case .snapshots:
                    SnapshotsView(session: snapshots, query: query)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.results")
            .accessibilityLabel(Text(pageSection.title))
        }
        .pageSearch(text: $searchText, prompt: searchPrompt, section: pageSection)
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
    /// Shows only the rows whose title matches (already trimmed); a matching section title shows its whole section.
    let query: String

    private static let memoryLegend: [LocalizedStringResource] = [
        "App Memory", "Wired Memory", "Compressed Memory", "Available Memory",
    ]

    var body: some View {
        if let health = session.health {
            Form {
                if showsMemory { memorySection(health: health) }
                if showsPerformance { performanceSection(health: health) }
                if let battery = health.battery, showsBattery(battery) {
                    batterySection(battery: battery)
                }
            }
            .formStyle(.grouped)
            .pageState(isShown: !showsMemory && !showsPerformance && !(health.battery.map(showsBattery) ?? false)) {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var showsMemory: Bool {
        shows(section: "Memory", rows: ["Memory Pressure", "Total RAM", "Swap Used"] + Self.memoryLegend)
    }

    private var showsPerformance: Bool {
        shows(section: "System Performance", rows: ["CPU Usage", "Thermal State", "Uptime"])
    }

    private func showsBattery(_ battery: BatteryHealth) -> Bool {
        shows(section: "Battery", rows: batteryTitles(battery))
    }

    /// The battery rows this Mac reports.
    private func batteryTitles(_ battery: BatteryHealth) -> [LocalizedStringResource] {
        var titles: [LocalizedStringResource] = ["Charge"]
        if battery.maxCapacityPercent != nil { titles.append("Maximum Capacity") }
        if battery.cycleCount != nil { titles.append("Cycle Count") }
        if battery.condition != nil { titles.append("Condition") }
        return titles
    }

    private func matches(_ title: LocalizedStringResource) -> Bool {
        query.isEmpty || String(localized: title).localizedStandardContains(query)
    }

    /// A row is shown when the search is empty, its section's title matches, or its own title matches.
    private func shows(_ row: LocalizedStringResource, in section: LocalizedStringResource) -> Bool {
        matches(section) || matches(row)
    }

    private func shows(section: LocalizedStringResource, rows: [LocalizedStringResource]) -> Bool {
        matches(section) || rows.contains { matches($0) }
    }

    private func memorySection(health: SystemHealth) -> some View {
        Section {
            if shows("Memory Pressure", in: "Memory") {
                LabeledContent {
                    pressureBadge(level: health.memoryPressure)
                } label: {
                    Text("Memory Pressure")
                }
            }
            if matches("Memory") || Self.memoryLegend.contains(where: { matches($0) }) {
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
            }
            if shows("Total RAM", in: "Memory") {
                LabeledContent {
                    SizeText(bytes: Int64(health.totalPhysicalMemory))
                } label: {
                    Text("Total RAM")
                }
            }
            if shows("Swap Used", in: "Memory") {
                LabeledContent {
                    SizeText(bytes: Int64(health.swapUsed))
                } label: {
                    Text("Swap Used")
                }
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
            if shows("CPU Usage", in: "System Performance") {
                LabeledContent {
                    Text(health.cpuLoadPercent / 100, format: .percent.precision(.fractionLength(1)))
                        .monospacedDigit()
                } label: {
                    Text("CPU Usage")
                }
            }
            if shows("Thermal State", in: "System Performance") {
                LabeledContent {
                    thermalBadge(state: health.thermalState)
                } label: {
                    Text("Thermal State")
                }
            }
            if shows("Uptime", in: "System Performance") {
                LabeledContent {
                    Text(formatUptime(seconds: health.uptime))
                } label: {
                    Text("Uptime")
                }
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
            if shows("Charge", in: "Battery") {
                LabeledContent {
                    Text(Double(battery.chargePercent) / 100, format: .percent)
                        .monospacedDigit()
                } label: {
                    Text("Charge")
                }
            }
            if let maxCap = battery.maxCapacityPercent, shows("Maximum Capacity", in: "Battery") {
                LabeledContent {
                    Text(Double(maxCap) / 100, format: .percent)
                        .monospacedDigit()
                } label: {
                    Text("Maximum Capacity")
                }
            }
            if let cycles = battery.cycleCount, shows("Cycle Count", in: "Battery") {
                LabeledContent {
                    Text(cycles, format: .number)
                } label: {
                    Text("Cycle Count")
                }
            }
            if let condition = battery.condition, shows("Condition", in: "Battery") {
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
    /// Shows only the processes whose name matches (already trimmed); empty shows them all.
    let query: String

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

    private var sampled: [ProcessInfoItem] {
        switch sortOrder {
        case .cpu: return session.topByCPU
        case .memory: return session.topByMemory
        }
    }

    private var processes: [ProcessInfoItem] {
        query.isEmpty ? sampled : sampled.filter { $0.name.localizedStandardContains(query) }
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
            .pageState(isShown: processes.isEmpty) {
                if sampled.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No heavy processes detected")
                        } icon: {
                            Image(systemName: "cpu")
                        }
                    } description: {
                        Text("Sampling active host processes…")
                    }
                } else {
                    ContentUnavailableView.search(text: query)
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
    /// Shows only the checks whose title matches (already trimmed); empty shows them all.
    let query: String

    private var checks: [SecurityCheck] {
        guard !query.isEmpty else { return session.securityChecks }
        return session.securityChecks.filter {
            String(localized: SecurityCheckRow.title(for: $0.id)).localizedStandardContains(query)
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(checks) { check in
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
        .pageState(isShown: checks.isEmpty && !session.securityChecks.isEmpty) {
            ContentUnavailableView.search(text: query)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await session.refreshSecurity() }
                } label: {
                    ToolbarLabel(title: "Check Again", symbol: "arrow.clockwise")
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
                    Text(Self.title(for: check.id))
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
                    if check.id == "firewall" {
                        // macOS has no link to the Firewall page itself; it is a row in Network.
                        Link(destination: url) {
                            Text("Open Network Settings…")
                        }
                        .font(.callout)
                        .padding(.top, 2)
                        Text("Then choose Firewall.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Link("Open System Settings", destination: url)
                            .font(.callout)
                            .padding(.top, 2)
                    }
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

    static func title(for id: String) -> LocalizedStringResource {
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
    /// Shows only the snapshots whose name or date matches (already trimmed); empty shows them all.
    let query: String
    @State private var confirming: String?
    @State private var message: LocalizedStringResource?

    private var snapshots: [String] {
        guard !query.isEmpty else { return session.snapshots }
        return session.snapshots.filter { snapshot in
            snapshot.localizedStandardContains(query)
                || LocalSnapshots.date(of: snapshot).map {
                    $0.formatted(.dateTime.year().month().day().hour().minute()).localizedStandardContains(query)
                } == true
        }
    }

    var body: some View {
        Form {
            Section {
                if session.snapshots.isEmpty {
                    Text(session.isLoading ? "Looking for snapshots…" : "No local snapshots on this Mac.")
                        .foregroundStyle(.secondary)
                } else if snapshots.isEmpty {
                    Text("No snapshots match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshots, id: \.self) { snapshot in
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
                    ToolbarLabel(title: "Refresh", symbol: "arrow.clockwise")
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
