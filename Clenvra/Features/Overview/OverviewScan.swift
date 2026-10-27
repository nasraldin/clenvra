import ClenvraKit
import SwiftUI

/// The read-only areas "Scan Everything" runs. Their state is read from the long-lived sessions, so it survives
/// leaving the Overview and reflects scans the user started in the sections themselves.
enum OverviewArea: CaseIterable, Identifiable {
    case cleanup, developer, tools, startup, security

    var id: Self { self }

    enum State: Equatable {
        case notRun
        case running
        case done
        /// The developer-tool session appears once the login-shell PATH is known.
        case unavailable
    }

    var title: LocalizedStringResource {
        switch self {
        case .cleanup: "Cleanup"
        case .developer: "Developer build data"
        case .tools: "Developer tool storage"
        case .startup: "Startup"
        case .security: "Security"
        }
    }

    var symbol: String {
        switch self {
        case .cleanup: "sparkles"
        case .developer: "hammer"
        case .tools: "terminal"
        case .startup: "power"
        case .security: "lock.shield"
        }
    }

    var section: AppSection {
        switch self {
        case .cleanup: .cleanup
        case .developer, .tools: .developer
        case .startup: .startup
        case .security: .system
        }
    }

    @MainActor
    func state(in environment: AppEnvironment) -> State {
        switch self {
        case .cleanup: Self.state(of: environment.cleanupSession.phase)
        case .developer: Self.state(of: environment.developerSession.phase)
        case .tools:
            switch environment.toolSession?.phase {
            case nil: .unavailable
            case .idle: .notRun
            case .inspecting, .running: .running
            case .ready: .done
            }
        case .startup:
            if environment.startupSession.isLoading {
                .running
            } else {
                environment.startupSession.items.isEmpty ? .notRun : .done
            }
        case .security:
            if environment.systemSession.isCheckingSecurity {
                .running
            } else {
                environment.systemSession.securityChecks.isEmpty ? .notRun : .done
            }
        }
    }

    /// Starts this area's read-only scan and waits for it.
    @MainActor
    func run(in environment: AppEnvironment) async {
        switch self {
        case .cleanup: await environment.cleanupSession.scan()
        case .developer: await environment.developerSession.scan()
        case .tools: await environment.toolSession?.inspect()
        case .startup: await environment.startupSession.load(installedApps: environment.installedApps)
        case .security: await environment.systemSession.refreshSecurity()
        }
    }

    private static func state(of phase: CleanupSession.Phase) -> State {
        switch phase {
        case .idle: .notRun
        case .scanning, .cleaning: .running
        case .ready: .done
        }
    }
}

extension OverviewArea {
    /// Runs the given areas concurrently. Every area only reads; nothing is deleted from the Overview.
    @MainActor
    static func run(_ areas: [OverviewArea], in environment: AppEnvironment) async {
        // Each scan suspends while its work runs off the main actor, so these overlap.
        let tasks = areas.map { area in Task { await area.run(in: environment) } }
        for task in tasks { await task.value }
    }
}

/// One line per area: spinner while it runs, then a checkmark and what it found.
struct OverviewScanList: View {
    let environment: AppEnvironment
    let navigate: (AppSection) -> Void

    var body: some View {
        // A grid keeps the status column aligned whatever the title length in each language.
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            ForEach(OverviewArea.allCases) { area in
                row(area)
                if area != OverviewArea.allCases.last { Divider() }
            }
        }
    }

    private func row(_ area: OverviewArea) -> some View {
        GridRow {
            statusIcon(area.state(in: environment))
                .frame(width: 18)
            Label {
                Text(area.title)
            } icon: {
                Image(systemName: area.symbol)
            }
            headline(area)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if area.state(in: environment) == .done {
                    Button {
                        navigate(area.section)
                    } label: {
                        Label {
                            Text("Show \(Text(area.title))")
                        } icon: {
                            Image(systemName: "chevron.forward")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Show \(Text(area.title))"))
                    .accessibilityIdentifier("overview.area.\(area)")
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: OverviewArea.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Done"))
        case .notRun, .unavailable:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func headline(_ area: OverviewArea) -> some View {
        switch area.state(in: environment) {
        case .notRun:
            Text("Not scanned yet")
        case .unavailable:
            Text("Looking for developer tools…")
        case .running:
            Text("Scanning…")
        case .done:
            doneHeadline(area)
        }
    }

    @ViewBuilder
    private func doneHeadline(_ area: OverviewArea) -> some View {
        switch area {
        case .cleanup: sessionHeadline(environment.cleanupSession)
        case .developer: sessionHeadline(environment.developerSession)
        case .tools:
            let count = environment.toolSession?.rows.count { ($0.size ?? 0) > 0 } ?? 0
            if count > 0 {
                Text("\(count) tool stores found")
            } else {
                Text("No developer tool data found")
            }
        case .startup:
            let problems = environment.startupSession.problemCount
            if problems > 0 {
                Text("\(problems) items left behind by removed apps")
            } else {
                Text("\(environment.startupSession.items.count) startup items, none left behind")
            }
        case .security:
            let attention = environment.systemSession.securityChecks.count { $0.status == .attention }
            if attention > 0 {
                Text("\(attention) settings need attention")
            } else {
                Text("No issues found")
            }
        }
    }

    @ViewBuilder
    private func sessionHeadline(_ session: CleanupSession) -> some View {
        if session.selectedCount > 0 {
            Text(
                "\(session.selectedCount) safe items, \(Text(session.selectedBytes, format: .byteCount(style: .file)))"
            )
            .monospacedDigit()
        } else {
            Text("Nothing to clean")
        }
    }
}
