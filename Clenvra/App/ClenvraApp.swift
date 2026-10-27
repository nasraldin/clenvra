import SwiftUI

@main
struct ClenvraApp: App {
    @State private var selection: AppSection? = .overview
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            MainWindow(selection: $selection, environment: environment)
                .frame(minWidth: 900, minHeight: 560)
                .task { await environment.loadInstalledApps() }
                .task { await environment.prepareTools() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Go") {
                ForEach(AppSection.allCases) { section in
                    if let key = section.shortcut {
                        Button {
                            selection = section
                        } label: {
                            Text(section.title)
                        }
                        .keyboardShortcut(key, modifiers: .command)
                    }
                }
            }
        }

        Settings {
            SettingsView(environment: environment)
        }
    }
}
