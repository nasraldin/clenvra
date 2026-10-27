import SwiftUI

@main
struct ClenvraApp: App {
    @State private var selection: AppSection? = .overview
    @State private var environment = AppEnvironment()
    @AppStorage(PermissionsGuideView.seenKey) private var hasSeenPermissionsGuide = false
    /// Also tracked per launch: a launch argument can override the stored value.
    @State private var dismissedPermissionsGuide = false

    var body: some Scene {
        WindowGroup {
            MainWindow(selection: $selection, environment: environment)
                .frame(minWidth: 900, minHeight: 560)
                .task { await environment.loadInstalledApps() }
                .task { await environment.prepareTools() }
                .sheet(
                    isPresented: Binding(
                        get: { !hasSeenPermissionsGuide && !dismissedPermissionsGuide },
                        set: { isShown in
                            if !isShown {
                                dismissedPermissionsGuide = true
                                hasSeenPermissionsGuide = true
                            }
                        })
                ) {
                    PermissionsGuideView(home: environment.home)
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // Its own key: "Go" alone is also the Go language in Developer, which must not be translated.
            CommandMenu(Text("menu.go", comment: "Menu that switches between sections")) {
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
