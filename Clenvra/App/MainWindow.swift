import ClenvraKit
import SwiftUI

struct MainWindow: View {
    @Binding var selection: AppSection?
    let environment: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AppSection.Group.allCases, id: \.self) { group in
                    if let title = group.title {
                        Section {
                            rows(in: group)
                        } header: {
                            Text(title)
                        }
                    } else {
                        rows(in: group)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if let selection {
                // The page title and the test identifier are set here, once for every page.
                VStack(spacing: 0) {
                    page(selection)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(selection.title))
                .accessibilityIdentifier("section.\(selection.rawValue)")
                .navigationTitle(Text(selection.title))
            }
        }
    }

    private func rows(in group: AppSection.Group) -> some View {
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

    @ViewBuilder private func page(_ section: AppSection) -> some View {
        switch section {
        case .overview:
            OverviewView(environment: environment, navigate: { selection = $0 })
        case .cleanup:
            CleanupView(environment: environment)
        case .developer:
            RuleReviewView(section: .developer, session: environment.developerSession) {
                if let tools = environment.toolSession { ToolStorageSection(session: tools) }
            }
        case .storage:
            storage(.browser)
        case .largeFiles:
            storage(.largeFiles)
        case .downloads:
            storage(.clutter)
        case .similarPhotos:
            storage(.similarPhotos)
        case .duplicates:
            DuplicatesView(session: environment.duplicatesSession)
        case .applications:
            applications(.installed)
        case .leftovers:
            applications(.leftovers)
        case .extensions:
            applications(.extensions)
        case .startup:
            StartupView(session: environment.startupSession, installedApps: environment.installedApps)
        case .system:
            system(.health)
        case .processes:
            system(.processes)
        case .security:
            system(.security)
        case .snapshots:
            system(.snapshots)
        case .activity:
            ActivityView(session: environment.activitySession)
        }
    }

    private func storage(_ page: StoragePage) -> some View {
        StorageView(session: environment.storageSession, similarPhotos: environment.similarPhotosSession, page: page)
            .id(page)
    }

    private func applications(_ page: ApplicationsPage) -> some View {
        ApplicationsView(
            session: environment.appsSession, plugins: environment.pluginsSession, updates: environment.updateSession,
            checksForUpdates: environment.settings.checksForAppUpdates, page: page
        )
        .id(page)
    }

    private func system(_ page: SystemView.SystemTab) -> some View {
        SystemView(session: environment.systemSession, snapshots: environment.snapshotsSession, page: page)
            .id(page)
    }
}
