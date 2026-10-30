import ClenvraKit
import SwiftUI

/// Everything the Overview search can find: every page, the installed apps, startup items and mounted disks, and
/// whatever the other pages have already read or scanned. Building it reads only what is in memory; it never scans.
@MainActor
enum OverviewSearchIndex {
    static func entries(environment: AppEnvironment, volumes: [Volume]) -> [SearchEntry] {
        var entries = AppSection.allCases.filter { $0 != .overview }.map(pageEntry)

        let apps = environment.installedApps.isEmpty ? environment.appsSession.apps : environment.installedApps
        entries += apps.map {
            SearchEntry(
                title: $0.name, subtitle: $0.id, keywords: [$0.bundleIdentifier].compactMap { $0 },
                destination: AppSection.applications.rawValue, query: $0.name)
        }

        entries += environment.startupSession.items.map { item in
            let name = item.label ?? item.program.map { ($0 as NSString).lastPathComponent } ?? item.plistPath
            return SearchEntry(
                title: name, subtitle: item.program ?? item.plistPath, keywords: [],
                destination: AppSection.startup.rawValue, query: name)
        }

        entries += environment.permissionsSession.grants.map { grant in
            SearchEntry(
                title: grant.client, subtitle: String(localized: PermissionService.title(grant.service)), keywords: [],
                destination: AppSection.permissions.rawValue, query: grant.client)
        }

        for (session, section) in [
            (environment.cleanupSession, AppSection.cleanup), (environment.developerSession, .developer),
        ] {
            entries += session.groups.flatMap(\.candidates).map {
                SearchEntry(
                    title: $0.name, subtitle: $0.path, keywords: [], destination: section.rawValue, query: $0.name)
            }
        }

        if let tools = environment.toolSession {
            entries += tools.rows.map {
                let name = String(localized: $0.tool)
                return SearchEntry(
                    title: name, subtitle: $0.location, keywords: [],
                    destination: AppSection.developerTools.rawValue, query: name)
            }
        }

        if environment.appsSession.hasScannedLeftovers {
            entries += environment.appsSession.leftovers.map {
                SearchEntry(
                    title: $0.name, subtitle: $0.path, keywords: [], destination: AppSection.leftovers.rawValue,
                    query: $0.name)
            }
        }

        entries += environment.storageSession.largeFiles.map {
            SearchEntry(
                title: $0.name, subtitle: $0.path, keywords: [], destination: AppSection.largeFiles.rawValue,
                query: $0.name)
        }

        // The Mounted Disks page lists every disk except the startup disk.
        entries += volumes.filter { !$0.isRoot }.map {
            SearchEntry(
                title: $0.name, subtitle: $0.id.path(percentEncoded: false), keywords: [],
                destination: AppSection.disks.rawValue, query: $0.name)
        }
        return entries
    }

    /// A page: its name in the app's language, plus its English name and plain words people search for, so the
    /// page is found either way.
    private static func pageEntry(_ section: AppSection) -> SearchEntry {
        let title = String(localized: section.title)
        var keywords = keywords(for: section)
        keywords.append(String(localized: section.sidebarTitle))
        keywords.append(englishTitle(section))
        return SearchEntry(
            title: title, subtitle: nil, keywords: keywords, destination: section.rawValue, query: nil)
    }

    private static func englishTitle(_ section: AppSection) -> String {
        var english = section.title
        english.locale = Locale(identifier: "en")
        return String(localized: english)
    }

    private static func keywords(for section: AppSection) -> [String] {
        switch section {
        case .overview: []
        case .cleanup: ["cache", "caches", "junk", "logs", "crash reports", "installers", "browser", "cookies"]
        case .developer: ["xcode", "derived data", "simulator", "build", "node_modules", "package cache", "junk"]
        case .developerTools: ["npm", "pnpm", "yarn", "homebrew", "docker", "cargo", "pip", "tools"]
        case .largeFiles: ["large", "old", "big files", "clutter"]
        case .downloads: ["downloads", "screenshots", "clutter"]
        case .duplicates: ["duplicate", "copies", "same files"]
        case .similarPhotos: ["photos", "pictures", "images", "blurry"]
        case .storage: ["disk", "space", "storage", "folders", "system data"]
        case .disks: ["disk", "disk image", "dmg", "drive", "eject", "volume", "network share"]
        case .applications: ["apps", "uninstall", "remove app", "updates"]
        case .leftovers: ["leftovers", "uninstall", "remnants", "removed apps"]
        case .extensions: ["plug-ins", "plugins", "extensions", "widgets"]
        case .startup: ["login items", "launch agents", "launch daemons", "startup", "background"]
        case .system: ["memory", "ram", "cpu", "battery", "health", "thermal", "uptime"]
        case .processes: ["processes", "cpu", "memory", "quit", "activity monitor"]
        case .security: ["firewall", "filevault", "gatekeeper", "sip", "xprotect", "updates", "security"]
        case .permissions: ["privacy", "camera", "microphone", "screen recording", "full disk access", "tcc"]
        case .snapshots: ["time machine", "snapshots", "backup"]
        case .activity: ["history", "log", "trash", "put back", "undo"]
        }
    }
}

/// The Overview search results, grouped by the page each one opens.
struct OverviewSearchResults: View {
    let query: String
    let results: [SearchEntry]
    let open: (SearchEntry) -> Void

    private var groups: [(section: AppSection, entries: [SearchEntry])] {
        var order: [AppSection] = []
        var bySection: [AppSection: [SearchEntry]] = [:]
        for entry in results {
            guard let section = AppSection(rawValue: entry.destination) else { continue }
            if bySection[section] == nil { order.append(section) }
            bySection[section, default: []].append(entry)
        }
        return order.map { ($0, bySection[$0] ?? []) }
    }

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(groups, id: \.section) { group in
                    Section {
                        // By position: two results may be equal (the same name in two places).
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                            row(entry, section: group.section)
                        }
                    } header: {
                        Text(group.section.title)
                    }
                }
            }
            .accessibilityIdentifier("overview.searchResults")
        }
    }

    private func row(_ entry: SearchEntry, section: AppSection) -> some View {
        Button {
            open(entry)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.title)
                    if let subtitle = entry.subtitle {
                        Text(verbatim: subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } icon: {
                Image(systemName: section.symbol)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("overview.searchResult")
    }
}
