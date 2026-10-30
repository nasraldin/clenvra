import ClenvraKit
import SwiftUI

/// The Processes page: the heaviest processes by CPU or memory, each with its app's icon, and a details panel.
struct SystemProcessesView: View {
    let session: SystemSession
    /// Shows only the processes whose name matches (already trimmed); empty shows them all.
    let query: String
    /// The page's search text; the search icon is added here, before this page's own toolbar, so it comes last.
    let searchText: Binding<String>

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

    /// The app (or program) the Quit confirmation is about.
    struct QuitTarget: Identifiable {
        let id: pid_t
        let name: String
    }

    @State private var sortOrder: ProcessSortOrder = .cpu
    @State private var targetProcessForQuit: QuitTarget?
    @State private var isForceQuit = false
    @State private var selected: ProcessInfoItem.ID?
    @State private var showsInspector = false
    @State private var icons = ProcessIconCache()

    private var selectedProcess: ProcessInfoItem? { processes.first { $0.id == selected } }

    /// Quit (or Force Quit after a polite quit failed) the given app, after confirmation.
    private func requestQuit(pid: pid_t, name: String, appBundlePath: String?) {
        guard ProcessInfoItem.isQuittableApp(bundlePath: appBundlePath) else { return }
        isForceQuit = session.failedPoliteQuits.contains(pid)
        targetProcessForQuit = QuitTarget(id: pid, name: name)
    }

    private func requestQuit(_ proc: ProcessInfoItem) {
        requestQuit(pid: proc.id, name: proc.name, appBundlePath: proc.appBundlePath)
    }

    private var sampled: [ProcessInfoItem] {
        switch sortOrder {
        case .cpu: return session.topByCPU
        case .memory: return session.topByMemory
        }
    }

    private var processes: [ProcessInfoItem] {
        sampled.filter { AppSearch.matches(query, any: [$0.name, $0.executablePath, $0.appBundlePath, "\($0.pid)"]) }
    }

    /// The latest sample of a process from either list, for its live CPU and memory.
    private func liveSample(_ pid: pid_t) -> ProcessInfoItem? {
        session.topByCPU.first { $0.id == pid } ?? session.topByMemory.first { $0.id == pid }
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

            table
        }
        .detailsPanel(isPresented: $showsInspector, width: 300) {
            if let pid = selected {
                ProcessInspector(
                    pid: pid,
                    live: liveSample(pid),
                    icons: icons,
                    session: session,
                    requestQuit: requestQuit(pid:name:appBundlePath:)
                )
            } else {
                NoSelectionInspector(description: "Select a process to see its details.")
            }
        }
        .pageSearch(text: searchText, prompt: "Search Processes", section: .processes)
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
            ToolbarItem {
                InspectorToggle(isPresented: $showsInspector)
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

    private var table: some View {
        Table(processes, selection: $selected) {
            TableColumn("Process") { proc in
                HStack(spacing: 8) {
                    Image(nsImage: icons.icon(appBundlePath: proc.appBundlePath, executablePath: proc.executablePath))
                        .resizable()
                        .frame(width: 20, height: 20)
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
                Text(Self.kindTitle(ProcessSampler.kind(of: proc.executablePath)))
                    .foregroundStyle(.secondary)
            }
            .width(ideal: 100)
        }
        .accessibilityLabel(Text("Processes"))
        .contextMenu(forSelectionType: ProcessInfoItem.ID.self) { ids in
            if let id = ids.first, let proc = processes.first(where: { $0.id == id }) {
                FileActionsMenu(paths: proc.executablePath.isEmpty ? [] : [proc.appBundlePath ?? proc.executablePath]) {
                    selected = proc.id
                    showsInspector = true
                }
                if proc.isQuittableApp {
                    Divider()
                    Button {
                        requestQuit(proc)
                    } label: {
                        Text(session.failedPoliteQuits.contains(proc.id) ? "Force Quit…" : "Quit…")
                    }
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
}

/// Finder icons of processes, one lookup per path: the list refreshes every few seconds.
@MainActor
final class ProcessIconCache {
    private var cache: [String: NSImage] = [:]
    private lazy var programIcon: NSImage =
        NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()

    /// The app bundle's icon, else the executable's, else a generic program symbol.
    func icon(appBundlePath: String?, executablePath: String?) -> NSImage {
        guard let path = appBundlePath ?? executablePath.flatMap({ $0.isEmpty ? nil : $0 }) else {
            return programIcon
        }
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

/// Details of one process, read again every few seconds while shown.
extension SystemProcessesView {
    static func kindTitle(_ kind: ProcessSampler.Kind) -> LocalizedStringResource {
        switch kind {
        case .app: "App"
        case .system: "System"
        case .background: "Background"
        }
    }
}

private struct ProcessInspector: View {
    let pid: pid_t
    /// The latest sample from the CPU or Memory list, when the process is in one.
    let live: ProcessInfoItem?
    let icons: ProcessIconCache
    let session: SystemSession
    let requestQuit: (pid_t, String, String?) -> Void

    /// nil before the first read; `.some(nil)` once the process is gone.
    @State private var details: ProcessDetails??
    @State private var parentName: String?

    var body: some View {
        Group {
            content
        }
        .task(id: pid) { await refreshLoop() }
    }

    @ViewBuilder private var content: some View {
        switch details {
        case .none:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .some(.none):
            ContentUnavailableView {
                Label {
                    Text("No Longer Running")
                } icon: {
                    Image(systemName: "xmark.circle")
                }
            } description: {
                Text("This process has quit.")
            }
            .accessibilityIdentifier("page.inspector")
        case .some(.some(let info)):
            inspector(info)
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            let current = ProcessDetails.read(pid: pid)
            details = .some(current)
            parentName = current.flatMap { $0.parentPID > 0 ? ProcessDetails.read(pid: $0.parentPID)?.name : nil }
            guard current != nil else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    private func inspector(_ info: ProcessDetails) -> some View {
        let location = info.appBundlePath ?? info.executablePath
        let quittable = ProcessInfoItem.isQuittableApp(bundlePath: info.appBundlePath)
        return ItemInspector(
            name: info.name,
            path: location,
            icon: icons.icon(appBundlePath: info.appBundlePath, executablePath: info.executablePath)
        ) {
            Section {
                row("Process ID") { Text(verbatim: "\(info.pid)").monospacedDigit() }
                row("Parent Process") {
                    if let parentName {
                        Text(verbatim: "\(parentName) (\(info.parentPID))")
                    } else {
                        Text(verbatim: "\(info.parentPID)").monospacedDigit()
                    }
                }
                row("User") { Text(verbatim: info.user) }
                row("Started") {
                    if let start = info.startDate {
                        Text(start, format: .dateTime.year().month().day().hour().minute().second())
                    } else {
                        Text("Unknown")
                    }
                }
                row("Kind") { Text(SystemProcessesView.kindTitle(ProcessSampler.kind(of: info.executablePath ?? ""))) }
            }
            Section {
                if let live {
                    row("CPU") {
                        Text(live.cpuPercent / 100, format: .percent.precision(.fractionLength(1)))
                            .monospacedDigit()
                    }
                }
                row("Average CPU Since Launch") {
                    if let cpu = info.cpuPercent {
                        Text(cpu / 100, format: .percent.precision(.fractionLength(1)))
                            .monospacedDigit()
                    } else {
                        Text("Unknown")
                    }
                }
                row("Memory") {
                    if let bytes = live?.memoryBytes ?? info.memoryBytes {
                        SizeText(bytes: Int64(clamping: bytes))
                    } else {
                        Text("Unknown")
                    }
                }
                row("Threads") {
                    if let threads = info.threads {
                        Text(threads, format: .number)
                    } else {
                        Text("Unknown")
                    }
                }
            } header: {
                Text("Usage")
            }
            Section {
                if let arguments = info.arguments {
                    Text(verbatim: arguments.joined(separator: " "))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                } else {
                    Text("macOS does not show the arguments of another user’s process.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Arguments")
            }
            if quittable {
                Section {
                    Button {
                        requestQuit(info.pid, info.name, info.appBundlePath)
                    } label: {
                        Text(session.failedPoliteQuits.contains(info.pid) ? "Force Quit…" : "Quit…")
                    }
                }
            }
        }
    }

    private func row<Value: View>(_ title: LocalizedStringResource, @ViewBuilder value: () -> Value) -> some View {
        LabeledContent {
            value()
        } label: {
            Text(title)
        }
    }
}

extension ProcessInfoItem {
    /// A regular app outside the system folders, and not Clenvra itself.
    fileprivate var isQuittableApp: Bool { Self.isQuittableApp(bundlePath: appBundlePath) }

    fileprivate static func isQuittableApp(bundlePath: String?) -> Bool {
        guard let bundle = bundlePath, !bundle.hasPrefix("/System/") else { return false }
        return bundle != Bundle.main.bundlePath
    }
}
