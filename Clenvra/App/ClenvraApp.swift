import SwiftUI

@main
struct ClenvraApp: App {
    @State private var selection: AppSection? = .overview
    @State private var environment = AppEnvironment()
    @AppStorage(PermissionsGuideView.seenKey) private var hasSeenPermissionsGuide = false
    /// Also tracked per launch: a launch argument can override the stored value.
    @State private var dismissedPermissionsGuide = false

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow(selection: $selection, environment: environment)
                .frame(minWidth: 900, minHeight: 560)
                .task { await environment.loadInstalledApps() }
                .task { await environment.prepareTools() }
                .task { await environment.refreshHelper() }
                .task { environment.scheduler.start() }
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
                .preferredColorScheme(Self.forcedColorScheme)
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

        MenuBarExtra(
            isInserted: Binding(
                get: { environment.showsMenuBarExtra },
                // MenuBarExtra writes this back on every scene update, usually unchanged. Each write would count as an
                // observable change, re-run this body and trigger another write: an endless loop. Only real changes pass.
                set: { if environment.showsMenuBarExtra != $0 { environment.showsMenuBarExtra = $0 } })
        ) {
            MenuBarExtraView(environment: environment)
        } label: {
            Image(systemName: "sparkles")
                .accessibilityLabel(Text("Clenvra"))
        }

        Settings {
            SettingsView(environment: environment)
        }
    }

    /// UI tests pass `-ClenvraUITestAppearance light|dark` to run in either appearance whatever the Mac uses.
    /// Debug builds only; release builds always follow the system.
    private static var forcedColorScheme: ColorScheme? {
        #if DEBUG
            switch UserDefaults.standard.string(forKey: "ClenvraUITestAppearance") {
            case "light": .light
            case "dark": .dark
            default: nil
            }
        #else
            nil
        #endif
    }
}
