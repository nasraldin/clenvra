import SwiftUI

struct MainWindow: View {
    @Binding var selection: AppSection?
    let environment: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AppSection.Group.allCases, id: \.self) { group in
                    Section {
                        ForEach(AppSection.allCases.filter { $0.group == group }) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                Image(systemName: section.symbol)
                            }
                            .tag(section)
                            .accessibilityIdentifier("sidebar.\(section.rawValue)")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch selection {
            case .cleanup:
                RuleReviewView(section: .cleanup, session: environment.cleanupSession)
            case .developer:
                RuleReviewView(section: .developer, session: environment.developerSession) {
                    if let tools = environment.toolSession { ToolStorageSection(session: tools) }
                }
            case .overview:
                OverviewView(environment: environment, navigate: { selection = $0 })
            case .storage:
                StorageView(session: environment.storageSession)
            case .duplicates:
                DuplicatesView(session: environment.duplicatesSession)
            case .applications:
                ApplicationsView(session: environment.appsSession)
            case .activity:
                ActivityView(session: environment.activitySession)
            case .system:
                SystemView(session: environment.systemSession)
            case .startup:
                StartupView(session: environment.startupSession, installedApps: environment.installedApps)
            case let section?:
                SectionPlaceholder(section: section)
            case nil:
                EmptyView()
            }
        }
    }
}

/// Shown until a section's real screen is built; replaced milestone by milestone.
private struct SectionPlaceholder: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(section.title)
            } icon: {
                Image(systemName: section.symbol)
            }
        } description: {
            Text("Not available yet.")
        }
        .navigationTitle(Text(section.title))
        .accessibilityIdentifier("section.\(section.rawValue)")
    }
}
