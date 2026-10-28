import Foundation

/// The built-in cleanup rules. Adding a category is adding a row here; the scanner, deletion gate and review UI
/// are shared. Rules whose root does not exist on a Mac (tool not installed) simply produce nothing.
public enum RuleCatalog {
    public static var defaultTemporaryDirectory: String {
        ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    }

    public static func standard(temporaryDirectory: String = defaultTemporaryDirectory) -> [CleanupRule] {
        system + trash + browsers + deviceBackups + mailAttachments + [temporaryFilesRule(root: temporaryDirectory)]
            + emptyFolders + xcode + editors + projects
    }

    public static var standard: [CleanupRule] {
        standard(temporaryDirectory: defaultTemporaryDirectory)
    }

    // MARK: - System and app junk

    /// Children of ~/Library/Caches owned by more specific rules: each browser's folder, and Google's (Chrome is
    /// a browser; the rest of Google's caches get their own rule).
    static let cachesOwnedElsewhere: Set<String> = Set(browserCaches.map { $0.folder.firstComponent })
        .union(["Google", "JetBrains", "Zed"])

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
        CleanupRule(
            id: "caches.google", category: .appCaches, root: .home("Library/Caches/Google"),
            selection: .children(excluding: ["Chrome"]), risk: .safe, action: .moveToTrash,
            ownership: .namePrefix([NamePrefixOwner("AndroidStudio", "com.google.android.studio")], fallback: nil)),
    ]

    // MARK: - System (through the privileged helper)

    /// System caches and logs (CL-8). Not part of `standard`: they live outside the home folder and are removed by
    /// the helper. Never pre-selected: anything needing administrator rights is the user's explicit choice.
    /// `root` is "/" in the app and a test folder in tests.
    public static func system(root: String) -> [CleanupRule] {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return [
            CleanupRule(
                id: "system.caches", category: .systemCaches, root: .absolute(base + "/Library/Caches"),
                selection: .children(), risk: .review, action: .moveToTrash, ownership: .bundleIdentifierFromName,
                elevation: .helper),
            CleanupRule(
                id: "system.logs", category: .systemLogs, root: .absolute(base + "/Library/Logs"),
                selection: .files(extensions: ["log", "gz"], minimumAge: .days(7), maximumDepth: 6), risk: .review,
                action: .moveToTrash, ownership: .none, elevation: .helper),
            // Rotated, compressed system logs; the helper deletes these for good (they are only ever archives).
            CleanupRule(
                id: "system.logArchives", category: .systemLogs, root: .absolute(base + "/private/var/log"),
                selection: .files(extensions: ["gz", "bz2", "xz"], minimumAge: .days(7), maximumDepth: 1),
                risk: .review, action: .removePermanently, ownership: .none, elevation: .helper),
        ]
    }

    // MARK: - Trash

    /// Moving Trash items to the Trash frees nothing, so this is the one rule that deletes for good. Never
    /// pre-selected; the confirmation says it cannot be undone.
    static let trash: [CleanupRule] = [
        CleanupRule(
            id: "trash.user", category: .trash, root: .home(".Trash"), selection: .children(), risk: .review,
            action: .removePermanently, ownership: .none)
    ]

    // MARK: - Browsers

    /// One browser's cache location under ~/Library/Caches. Only cache folders: profiles, history, cookies,
    /// passwords and extensions live in Application Support and are never offered.
    struct BrowserCache: Sendable {
        let id: String
        /// Relative to ~/Library/Caches; each child is one profile's (or one kind of) cache.
        let folder: String
        let bundleIdentifier: String
    }

    static let browserCaches: [BrowserCache] = [
        BrowserCache(id: "safari", folder: "com.apple.Safari", bundleIdentifier: "com.apple.Safari"),
        BrowserCache(id: "chrome", folder: "Google/Chrome", bundleIdentifier: "com.google.Chrome"),
        BrowserCache(id: "edge", folder: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac"),
        BrowserCache(id: "brave", folder: "BraveSoftware/Brave-Browser", bundleIdentifier: "com.brave.Browser"),
        BrowserCache(id: "arc", folder: "Arc/User Data", bundleIdentifier: "company.thebrowser.Browser"),
        BrowserCache(id: "vivaldi", folder: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi"),
        BrowserCache(id: "opera", folder: "com.operasoftware.Opera", bundleIdentifier: "com.operasoftware.Opera"),
        BrowserCache(id: "firefox", folder: "Firefox/Profiles", bundleIdentifier: "org.mozilla.firefox"),
        BrowserCache(id: "zen", folder: "zen/Profiles", bundleIdentifier: "app.zen-browser.zen"),
    ]

    /// Owned by the browser, so a running browser blocks its cache.
    static let browsers: [CleanupRule] = browserCaches.map { browser in
        CleanupRule(
            id: "browser.\(browser.id)", category: .browserCaches, root: .home("Library/Caches/\(browser.folder)"),
            selection: .children(), risk: .safe, action: .moveToTrash, ownership: .fixed(browser.bundleIdentifier))
    }

    // MARK: - iPhone and iPad

    static let deviceBackups: [CleanupRule] = [
        // A backup may be the only copy of a device's data: review only, named after the device.
        CleanupRule(
            id: "deviceBackups.mobileSync", category: .deviceBackups,
            root: .home("Library/Application Support/MobileSync/Backup"), selection: .children(), risk: .review,
            action: .moveToTrash, ownership: .none, label: .deviceBackup),
        // Software updates Finder downloaded to restore or update a device; downloaded again when needed.
        CleanupRule(
            id: "deviceBackups.firmware", category: .deviceBackups, root: .home("Library/iTunes"),
            selection: .files(extensions: ["ipsw"], minimumAge: nil, maximumDepth: 2), risk: .safe,
            action: .moveToTrash, ownership: .none),
    ]

    // MARK: - Mail attachments

    /// Downloaded copies of attachments Mail keeps locally. The mailbox itself (~/Library/Mail) is protected.
    public static let mailAttachments: [CleanupRule] = [
        CleanupRule(
            id: "mailAttachments.container", category: .mailAttachments,
            root: .home("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            selection: .children(), risk: .review, action: .moveToTrash,
            ownership: .fixed("com.apple.mail")),
        CleanupRule(
            id: "mailAttachments.legacy", category: .mailAttachments,
            root: .home("Library/Mail Downloads"),
            selection: .children(), risk: .review, action: .moveToTrash,
            ownership: .fixed("com.apple.mail")),
    ]

    // MARK: - Temporary files

    /// The user's temporary directory items older than 3 days. Injectable for testing.
    public static func temporaryFilesRule(root: String = defaultTemporaryDirectory) -> CleanupRule {
        CleanupRule(
            id: "temporaryFiles.user", category: .temporaryFiles,
            root: .absolute(root),
            selection: .children(minimumAge: .days(3)),
            risk: .review, action: .moveToTrash,
            ownership: .bundleIdentifierFromName)
    }

    // MARK: - Empty folders

    /// Folders with no files at any depth inside user standard folders; never pre-selected and never the roots.
    public static let emptyFolders: [CleanupRule] = [
        CleanupRule(
            id: "emptyFolders.downloads", category: .emptyFolders, root: .home("Downloads"),
            selection: .emptyFolders(), risk: .review, action: .moveToTrash, ownership: .none),
        CleanupRule(
            id: "emptyFolders.desktop", category: .emptyFolders, root: .home("Desktop"),
            selection: .emptyFolders(), risk: .review, action: .moveToTrash, ownership: .none),
        CleanupRule(
            id: "emptyFolders.documents", category: .emptyFolders, root: .home("Documents"),
            selection: .emptyFolders(), risk: .review, action: .moveToTrash, ownership: .none),
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

    /// JetBrains cache folders are named product + version (`PyCharmCE2026.2`).
    static let jetBrainsProducts: [NamePrefixOwner] = [
        NamePrefixOwner("IntelliJIdea", "com.jetbrains.intellij"),
        NamePrefixOwner("IdeaIC", "com.jetbrains.intellij.ce"),
        NamePrefixOwner("PyCharm", "com.jetbrains.pycharm"),
        NamePrefixOwner("PyCharmCE", "com.jetbrains.pycharm.ce"),
        NamePrefixOwner("WebStorm", "com.jetbrains.WebStorm"),
        NamePrefixOwner("GoLand", "com.jetbrains.goland"),
        NamePrefixOwner("CLion", "com.jetbrains.CLion"),
        NamePrefixOwner("PhpStorm", "com.jetbrains.PhpStorm"),
        NamePrefixOwner("RubyMine", "com.jetbrains.rubymine"),
        NamePrefixOwner("Rider", "com.jetbrains.rider"),
        NamePrefixOwner("DataGrip", "com.jetbrains.datagrip"),
        NamePrefixOwner("DataSpell", "com.jetbrains.dataspell"),
        NamePrefixOwner("RustRover", "com.jetbrains.rustrover"),
    ]

    /// Owner of JetBrains caches for products not listed above. No app has it, so the item counts as in use.
    public static let unknownJetBrainsIDE = "com.jetbrains.unknown-ide"

    static let editors: [CleanupRule] = [
        // Everything under ~/Library/Caches/JetBrains and ~/Library/Caches/Zed is cache; settings live elsewhere.
        CleanupRule(
            id: "ide.jetbrains", category: .ideCaches, root: .home("Library/Caches/JetBrains"), selection: .children(),
            risk: .safe, action: .moveToTrash,
            ownership: .namePrefix(jetBrainsProducts, fallback: unknownJetBrainsIDE)),
        CleanupRule(
            id: "ide.zed", category: .ideCaches, root: .home("Library/Caches/Zed"), selection: .children(),
            risk: .safe, action: .moveToTrash, ownership: .fixed("dev.zed.Zed")),
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

extension String {
    fileprivate var firstComponent: String {
        String(split(separator: "/", maxSplits: 1).first ?? Substring(self))
    }
}
