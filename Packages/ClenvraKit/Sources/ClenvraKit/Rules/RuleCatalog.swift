/// The built-in cleanup rules. Adding a category is adding a row here; the scanner, deletion gate and review UI
/// are shared. Rules whose root does not exist on a Mac (tool not installed) simply produce nothing.
public enum RuleCatalog {
    public static let standard: [CleanupRule] = system + xcode + editors + projects

    // MARK: - System and app junk

    /// Children of ~/Library/Caches owned by more specific rules.
    static let cachesOwnedElsewhere: Set<String> = []

    static let system: [CleanupRule] = [
        CleanupRule(
            id: "caches.user", category: .appCaches, root: .home("Library/Caches"),
            selection: .children(excluding: cachesOwnedElsewhere), risk: .safe, action: .moveToTrash,
            ownership: .bundleIdentifierFromName),
        CleanupRule(
            id: "logs.user", category: .logs, root: .home("Library/Logs"),
            selection: .files(extensions: ["log", "gz"], minimumAge: .days(7), maximumDepth: 6),
            risk: .safe, action: .moveToTrash, ownership: .none),
        CleanupRule(
            id: "crashReports.user", category: .crashReports, root: .home("Library/Logs/DiagnosticReports"),
            selection: .files(
                extensions: ["ips", "crash", "diag", "spin", "hang", "panic"], minimumAge: .days(7), maximumDepth: 2),
            risk: .safe, action: .moveToTrash, ownership: .none),
        CleanupRule(
            id: "installers.downloads", category: .installers, root: .home("Downloads"),
            selection: .files(extensions: ["dmg", "pkg", "mpkg", "xip"], minimumAge: nil, maximumDepth: 2),
            risk: .review, action: .moveToTrash, ownership: .none),
    ]

    // MARK: - Xcode and simulators

    static let xcodeBundleIdentifier = "com.apple.dt.Xcode"

    static let xcode: [CleanupRule] =
        [
            CleanupRule(
                id: "xcode.derivedData", category: .xcode, root: .home("Library/Developer/Xcode/DerivedData"),
                selection: .children(), risk: .safe, action: .moveToTrash, ownership: .fixed(xcodeBundleIdentifier)),
            CleanupRule(
                id: "xcode.previews", category: .xcode, root: .home("Library/Developer/Xcode/UserData/Previews"),
                selection: .children(), risk: .safe, action: .moveToTrash, ownership: .fixed(xcodeBundleIdentifier)),
            CleanupRule(
                id: "xcode.archives", category: .xcode, root: .home("Library/Developer/Xcode/Archives"),
                selection: .children(), risk: .review, action: .moveToTrash, ownership: .none),
            CleanupRule(
                id: "simulators.caches", category: .simulators, root: .home("Library/Developer/CoreSimulator/Caches"),
                selection: .children(), risk: .safe, action: .moveToTrash, ownership: .none),
        ]
        + ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map { platform in
            CleanupRule(
                id: "xcode.deviceSupport.\(platform)", category: .xcode,
                root: .home("Library/Developer/Xcode/\(platform) DeviceSupport"), selection: .children(),
                risk: .review, action: .moveToTrash, ownership: .none)
        }

    // MARK: - Editors

    /// Electron/Chromium cache folders shared by VS Code-family editors. Settings, extensions, workspaces and
    /// storage (User, Local Storage, IndexedDB, …) are deliberately absent.
    static let electronCacheFolders: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "CachedData",
        "CachedExtensionVSIXs", "CachedProfilesData",
    ]

    static func electronEditor(id: String, supportFolder: String, bundleIdentifier: String) -> CleanupRule {
        CleanupRule(
            id: "ide.\(id)", category: .ideCaches, root: .home("Library/Application Support/\(supportFolder)"),
            selection: .named(electronCacheFolders), risk: .safe, action: .moveToTrash,
            ownership: .fixed(bundleIdentifier))
    }

    static let editors: [CleanupRule] = [
        electronEditor(id: "vscode", supportFolder: "Code", bundleIdentifier: "com.microsoft.VSCode"),
        electronEditor(id: "cursor", supportFolder: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        electronEditor(id: "kiro", supportFolder: "Kiro", bundleIdentifier: "dev.kiro.desktop"),
        electronEditor(id: "antigravity", supportFolder: "Antigravity", bundleIdentifier: "com.google.antigravity"),
    ]

    // MARK: - Project build output

    /// Regenerable build-output folders and the marker files that identify their project type.
    public static let projectArtifactKinds: [ArtifactKind] = [
        ArtifactKind(folder: "node_modules", markers: ["package.json"]),
        ArtifactKind(folder: ".next", markers: ["next.config.js", "next.config.mjs", "next.config.ts"]),
        ArtifactKind(folder: ".nuxt", markers: ["nuxt.config.js", "nuxt.config.ts"]),
        ArtifactKind(folder: ".svelte-kit", markers: ["svelte.config.js", "svelte.config.ts"]),
        ArtifactKind(folder: ".turbo", markers: ["turbo.json"]),
        ArtifactKind(folder: ".parcel-cache", markers: ["package.json"]),
        ArtifactKind(folder: ".build", markers: ["Package.swift"]),
        ArtifactKind(folder: "Pods", markers: ["Podfile"]),
        ArtifactKind(folder: "target", markers: ["Cargo.toml", "pom.xml"]),
        ArtifactKind(
            folder: ".gradle",
            markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
        ArtifactKind(
            folder: "build", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
        ArtifactKind(folder: ".venv", markers: ["pyproject.toml", "requirements.txt", "Pipfile"]),
        ArtifactKind(folder: "__pycache__", markers: ["pyproject.toml", "setup.py"]),
    ]

    /// Common places people keep code; folders that do not exist on a Mac produce nothing.
    static let projectRoots = ["Sources", "Developer", "Projects", "Code", "src", "dev", "repos", "GitHub"]

    static let projects: [CleanupRule] = projectRoots.map { folder in
        CleanupRule(
            id: "projects.\(folder)", category: .projectArtifacts, root: .home(folder),
            selection: .projectArtifacts(projectArtifactKinds, inactivity: .days(30), maximumDepth: 5),
            risk: .safe, action: .moveToTrash, ownership: .none)
    }
}
