import AppKit
import ClenvraKit
import SwiftUI

/// The landing screen: disks, a read-only "Scan Everything", up to five recommendations and a health line.
/// It never deletes anything; every tile and row leads to the section where the user reviews and acts.
struct OverviewView: View {
    let environment: AppEnvironment
    let navigate: (AppSection) -> Void

    @State private var volumes: [Volume] = []
    @State private var fullDiskAccess = FullDiskAccess.Status.unknown
    @State private var helperUpdateFailed = false
    @State private var searchText = ""
    @Environment(SearchRouter.self) private var router: SearchRouter?

    var body: some View {
        let query = AppSearch.normalized(searchText)
        // The results cover the dashboard rather than replace it, so its toolbar and work stay in place.
        dashboard
            .pageState(isShown: !query.isEmpty) {
                OverviewSearchResults(
                    query: query,
                    results: AppSearch.results(
                        for: query, in: OverviewSearchIndex.entries(environment: environment, volumes: volumes)),
                    open: open)
            }
    }

    /// Opens the page a search result belongs to, with the result's text in that page's search field.
    private func open(_ entry: SearchEntry) {
        guard let section = AppSection(rawValue: entry.destination) else { return }
        if let router {
            router.open(section, query: entry.query)
        } else {
            navigate(section)
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                disks
                if fullDiskAccess == .notGranted { fullDiskAccessNote }
                if environment.helperNeedsUpdate { helperUpdateNote }
                scanSection
                if hasScanned { recommendationsSection }
                OverviewHealthLine(
                    health: environment.systemSession.health, startupVolume: startupVolume, navigate: navigate)
            }
            .padding(20)
            // Fills the page at any width (with or without the sidebar); the tile grid adds columns as it grows.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageSearch(text: $searchText, prompt: "Search Clenvra", section: .overview)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startScan(rescan: true)
                } label: {
                    ToolbarLabel(title: "Rescan", symbol: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(isScanning || !hasScanned)
                .accessibilityIdentifier("overview.rescan")
            }
        }
        .task {
            await environment.systemSession.refreshHealth()
            await refreshVolumes()
            fullDiskAccess = await FullDiskAccess.currentStatus(home: environment.home)
        }
    }

    // MARK: - Disks

    private var disks: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(volumes.filter(\.isRealDisk)) { volume in
                OverviewVolumeRow(volume: volume)
            }
            if volumes.isEmpty {
                ProgressView().controlSize(.small)
            }
            // Disk images (installers and the like) are not disks you own; they are listed on their own page.
            let images = volumes.filter { $0.kind == .diskImage }.count
            if images > 0 {
                Button {
                    navigate(.disks)
                } label: {
                    Label {
                        Text("\(images) disk images are mounted")
                    } icon: {
                        Image(systemName: "externaldrive.badge.plus")
                    }
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("overview.diskImages")
            }
        }
    }

    private var startupVolume: Volume? { volumes.first(where: \.isRoot) }

    private func refreshVolumes() async {
        volumes = await Task.detached { VolumeInventory.mountedVolumes() }.value
    }

    // MARK: - Scan Everything

    private var areaStates: [OverviewArea.State] { OverviewArea.allCases.map { $0.state(in: environment) } }
    private var isScanning: Bool { areaStates.contains(.running) }
    private var hasScanned: Bool { areaStates.contains(.done) }
    private var hasUnscannedAreas: Bool { areaStates.contains(.notRun) }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scan Everything").font(.headline)
                Spacer()
                if hasUnscannedAreas {
                    Button {
                        startScan(rescan: false)
                    } label: {
                        Text("Scan Everything")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanning)
                    .accessibilityIdentifier("overview.scanEverything")
                }
            }
            if !hasScanned {
                Text(
                    "Looks through caches, developer data, startup items and security settings. It only reads: nothing is deleted until you review it in its section."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            OverviewScanList(environment: environment, navigate: navigate)
        }
    }

    /// Runs the areas that have not run yet, or every idle area on Rescan, all at once.
    private func startScan(rescan: Bool) {
        let areas = OverviewArea.allCases.filter { area in
            let state = area.state(in: environment)
            return rescan ? state == .done || state == .notRun : state == .notRun
        }
        guard !areas.isEmpty else { return }
        Task {
            await OverviewArea.run(areas, in: environment)
            await refreshVolumes()
        }
    }

    // MARK: - Recommendations

    private var recommendations: [OverviewRecommendations.Recommendation] {
        OverviewRecommendations.make(OverviewInputs.make(environment: environment, startupVolume: startupVolume))
    }

    @ViewBuilder
    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommendations").font(.headline)
            let tiles = recommendations
            if tiles.isEmpty {
                Label {
                    Text("Nothing needs your attention right now.")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(tiles) { tile in
                        OverviewRecommendationTile(recommendation: tile, navigate: navigate)
                    }
                }
                .accessibilityIdentifier("overview.recommendations")
            }
        }
    }

    // MARK: - Full Disk Access

    /// After an app update the installed helper speaks an older protocol, so every helper action is off until it is
    /// reinstalled; this says so where it is seen first.
    private var helperUpdateNote: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("The system helper needs an update").font(.headline)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(
                    "It is from another version of Clenvra or is not answering, so system cleanup, Uninstall’s system files and changes for all users are off until it is updated. macOS may ask you to approve it again."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { helperUpdateFailed = !(await environment.updateHelper()) }
                } label: {
                    Text("Update Helper")
                }
                .accessibilityIdentifier("overview.updateHelper")
                if helperUpdateFailed {
                    Text("macOS did not update the helper. Make sure Clenvra is in the Applications folder.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var fullDiskAccessNote: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Full Disk Access is off").font(.headline)
                } icon: {
                    Image(systemName: "lock.shield")
                }
                Text(
                    "Without it, scans skip some protected folders, such as Safari and Mail data. Clenvra only reads them, and nothing is deleted without your review."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let url = FullDiskAccess.settingsURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("Open Privacy & Security Settings…")
                    }
                    .accessibilityIdentifier("overview.fullDiskAccess")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// Collects the plain totals the recommendation model ranks.
@MainActor
enum OverviewInputs {
    static func make(environment: AppEnvironment, startupVolume: Volume?) -> OverviewRecommendations.Input {
        var input = OverviewRecommendations.Input()
        var reviewCandidates: [(CleanupCandidate, OverviewRecommendations.Destination)] = []
        for (session, destination) in [
            (environment.cleanupSession, OverviewRecommendations.Destination.cleanup),
            (environment.developerSession, .developer),
        ] where session.phase == .ready {
            let totals = OverviewRecommendations.Input.Totals(
                bytes: session.selectedBytes, count: session.selectedCount)
            if destination == .cleanup { input.cleanup = totals } else { input.developer = totals }
            for candidate in session.groups.flatMap(\.candidates)
            where candidate.status == .available && !candidate.isSelectedByDefault {
                reviewCandidates.append((candidate, destination))
            }
        }
        if let largest = reviewCandidates.max(by: { $0.0.reclaimableSize < $1.0.reclaimableSize }) {
            input.largestReviewItem = .init(
                name: largest.0.name, bytes: largest.0.reclaimableSize, destination: largest.1)
        }
        if let tools = environment.toolSession, tools.phase == .ready {
            input.tools = tools.rows.map {
                .init(id: $0.id, name: $0.tool, bytes: $0.size, command: $0.cleanup?.summary)
            }
        }
        input.startupProblemCount = environment.startupSession.problemCount
        input.securityAttentionCount = environment.systemSession.securityChecks.count { $0.status == .attention }
        if let volume = startupVolume {
            input.freeSpaceRatio = volume.freeRatio
        }
        return input
    }
}

extension OverviewRecommendations.Destination {
    var section: AppSection {
        switch self {
        case .storage: .storage
        case .cleanup: .cleanup
        case .developer: .developer
        case .startup: .startup
        case .system: .security
        }
    }
}
