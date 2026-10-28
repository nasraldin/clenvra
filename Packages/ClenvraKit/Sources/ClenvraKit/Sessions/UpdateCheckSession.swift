public import Foundation
public import Observation

/// Whether one installed app has a newer version, and where that answer came from (AP-9).
public struct AppUpdate: Sendable, Equatable, Identifiable {
    /// Where the newest version was looked up; also tells the user how to update.
    public enum Source: Sendable, Equatable {
        case sparkle
        case homebrew(token: String)
        case appStore
    }

    public enum Status: Sendable, Equatable {
        case upToDate
        case available(version: String)
        case unknown(UnknownReason)
    }

    /// Why Clenvra could not tell; shown instead of guessing.
    public enum UnknownReason: Sendable, Equatable {
        /// No Sparkle feed, Homebrew cask or App Store receipt.
        case noUpdateSource
        /// The app's feed is plain HTTP, which Clenvra never contacts.
        case insecureFeed
        /// The network request or `brew` failed.
        case requestFailed
        /// The answer was not a feed or lookup Clenvra understands.
        case unreadableResponse
        /// The installed app's own version is missing or not a version.
        case unreadableVersion
    }

    /// The app's inventory id (canonical bundle path).
    public let id: String
    public let name: String
    public let installedVersion: String?
    public let source: Source?
    public let status: Status
}

/// Checks installed apps for updates. Network access is opt-in (D5): the check refuses to start, and stops
/// between requests, whenever `isEnabled` reports the setting off. It never downloads or installs anything.
@MainActor
@Observable
public final class UpdateCheckSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case checking(completed: Int, total: Int)
        case ready
        /// The user has not allowed update checks; nothing was contacted.
        case disabled
    }

    /// How many requests run at once; small, so a check never floods the network.
    static let concurrentRequests = 6

    public private(set) var phase = Phase.idle
    /// Results by app id; Apple apps and Clenvra itself are never listed.
    public private(set) var results: [String: AppUpdate] = [:]
    public private(set) var lastChecked: Date?

    private let isEnabled: @MainActor () -> Bool
    private let fetcher: any HTTPFetching
    private let homebrew: AppsSession.Homebrew?
    private let systemVersion: AppVersion

    /// - Parameters:
    ///   - isEnabled: reads the live "Check for app updates" setting; consulted before every network step.
    ///   - homebrew: enables `brew outdated`; `nil` when Homebrew is not installed.
    public init(
        isEnabled: @escaping @MainActor () -> Bool, fetcher: any HTTPFetching, homebrew: AppsSession.Homebrew?,
        systemVersion: AppVersion = .currentSystem
    ) {
        self.isEnabled = isEnabled
        self.fetcher = fetcher
        self.homebrew = homebrew
        self.systemVersion = systemVersion
    }

    /// Apps with a newer version, by name.
    public var availableUpdates: [AppUpdate] {
        results.values.filter { if case .available = $0.status { true } else { false } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Looks up every app's newest version. `homebrewToken` maps an app to its cask (see
    /// `AppsSession.homebrewToken(for:)`), because modern casks install into `/Applications`.
    public func check(_ apps: [InstalledApp], homebrewToken: (InstalledApp) -> String?) async {
        guard isEnabled() else {
            phase = .disabled
            results = [:]
            return
        }
        let candidates = apps.filter { !$0.isProtected }
        // Without Homebrew installed, cask apps fall back to their own feed.
        let tokens =
            homebrew == nil
            ? [:]
            : Dictionary(
                candidates.compactMap { app in Self.token(of: app, homebrewToken: homebrewToken).map { (app.id, $0) } },
                uniquingKeysWith: { first, _ in first })
        phase = .checking(completed: 0, total: candidates.count)
        var found: [String: AppUpdate] = [:]

        // App Store first (the store manages those), then Homebrew, then the app's own Sparkle feed.
        let feeds = await Self.feeds(of: candidates.filter { $0.source != .appStore && tokens[$0.id] == nil })
        var lookups: [Lookup] = []
        for app in candidates {
            if app.source == .appStore {
                if let identifier = app.bundleIdentifier,
                    let url = UpdateSources.appStoreLookupURL(bundleIdentifier: identifier)
                {
                    lookups.append(.appStore(app, url))
                } else {
                    found[app.id] = Self.result(app, source: .appStore, .unknown(.noUpdateSource))
                }
            } else if tokens[app.id] == nil {
                switch feeds[app.id] {
                case .https(let url): lookups.append(.sparkle(app, url))
                case .insecure: found[app.id] = Self.result(app, source: .sparkle, .unknown(.insecureFeed))
                case nil: found[app.id] = Self.result(app, source: nil, .unknown(.noUpdateSource))
                }
            }
        }

        let brewed = candidates.filter { tokens[$0.id] != nil }
        if let homebrew, !brewed.isEmpty {
            guard isEnabled() else { return stop(with: found) }
            let outdated = await Self.outdatedCasks(homebrew)
            for app in brewed {
                guard let token = tokens[app.id] else { continue }
                found[app.id] = Self.result(
                    app, source: .homebrew(token: token), Self.homebrewStatus(app, token: token, outdated: outdated))
            }
        }
        results = found
        phase = .checking(completed: found.count, total: candidates.count)

        var remaining = lookups[...]
        while !remaining.isEmpty {
            guard isEnabled() else { return stop(with: found) }
            let batch = remaining.prefix(Self.concurrentRequests)
            remaining = remaining.dropFirst(batch.count)
            let updates = await withTaskGroup(of: AppUpdate.self) { group in
                for lookup in batch {
                    group.addTask { @concurrent [fetcher, systemVersion] in
                        await Self.resolve(lookup, fetcher: fetcher, systemVersion: systemVersion)
                    }
                }
                var updates: [AppUpdate] = []
                for await update in group { updates.append(update) }
                return updates
            }
            for update in updates { found[update.id] = update }
            results = found
            phase = .checking(completed: found.count, total: candidates.count)
        }
        lastChecked = Date()
        phase = .ready
    }

    // MARK: - Private

    /// One network request still to make.
    private enum Lookup: Sendable {
        case sparkle(InstalledApp, URL)
        case appStore(InstalledApp, URL)
    }

    private func stop(with found: [String: AppUpdate]) {
        results = found
        phase = .disabled
    }

    private static func token(of app: InstalledApp, homebrewToken: (InstalledApp) -> String?) -> String? {
        if case .homebrew(let token) = app.source { return token }
        return homebrewToken(app)
    }

    private static func feeds(of apps: [InstalledApp]) async -> [String: UpdateSources.Feed] {
        let paths = apps.map(\.id)
        let read: @Sendable () -> [String: UpdateSources.Feed] = {
            Dictionary(
                paths.compactMap { path in UpdateSources.sparkleFeed(ofBundle: path).map { (path, $0) } },
                uniquingKeysWith: { first, _ in first })
        }
        return (try? await FSExecutor.shared.run(read)) ?? [:]
    }

    /// Outdated casks, or why brew could not tell.
    private static func outdatedCasks(_ homebrew: AppsSession.Homebrew) async -> Result<[String: String], Failure> {
        guard let result = try? await homebrew.runner.run(UpdateSources.outdatedCommand(brew: homebrew.brew)),
            result.terminationReason == .exited, result.exitStatus == 0
        else { return .failure(.requestFailed) }
        guard let casks = UpdateSources.outdatedCasks(fromJSON: Data(result.standardOutput.utf8)) else {
            return .failure(.unreadableResponse)
        }
        return .success(casks)
    }

    private struct Failure: Error {
        let reason: AppUpdate.UnknownReason
        static let requestFailed = Failure(reason: .requestFailed)
        static let unreadableResponse = Failure(reason: .unreadableResponse)
    }

    /// A cask missing from `brew outdated` is current. A listed cask is current too when the app updated itself
    /// past Homebrew's record; cask versions may carry a build after a comma (`131.0,6778.70`).
    private static func homebrewStatus(
        _ app: InstalledApp, token: String, outdated: Result<[String: String], Failure>
    ) -> AppUpdate.Status {
        switch outdated {
        case .failure(let failure):
            return .unknown(failure.reason)
        case .success(let casks):
            guard let latest = casks[token] else { return .upToDate }
            let display = String(latest.split(separator: ",").first ?? Substring(latest))
            if let installed = app.version.flatMap(AppVersion.init), let newest = AppVersion(display),
                newest <= installed
            {
                return .upToDate
            }
            return .available(version: display)
        }
    }

    @concurrent private nonisolated static func resolve(
        _ lookup: Lookup, fetcher: any HTTPFetching, systemVersion: AppVersion
    ) async -> AppUpdate {
        switch lookup {
        case .appStore(let app, let url):
            guard let data = try? await fetcher.data(from: url) else {
                return result(app, source: .appStore, .unknown(.requestFailed))
            }
            guard let identifier = app.bundleIdentifier,
                let latest = UpdateSources.appStoreVersion(fromJSON: data, bundleIdentifier: identifier)
            else { return result(app, source: .appStore, .unknown(.unreadableResponse)) }
            return result(app, source: .appStore, compare(installed: app.version, latest: latest))

        case .sparkle(let app, let url):
            guard let data = try? await fetcher.data(from: url) else {
                return result(app, source: .sparkle, .unknown(.requestFailed))
            }
            guard let release = UpdateSources.latestAppcastRelease(from: data, systemVersion: systemVersion) else {
                return result(app, source: .sparkle, .unknown(.unreadableResponse))
            }
            return result(app, source: .sparkle, sparkleStatus(app, release: release))
        }
    }

    /// Sparkle compares `sparkle:version` with `CFBundleVersion`; the short version is the fallback.
    private nonisolated static func sparkleStatus(
        _ app: InstalledApp, release: UpdateSources.AppcastRelease
    ) -> AppUpdate.Status {
        if let build = release.build, let latest = AppVersion(build),
            let installed = app.build.flatMap(AppVersion.init)
        {
            return installed < latest ? .available(version: release.shortVersion ?? build) : .upToDate
        }
        guard let short = release.shortVersion else { return .unknown(.unreadableResponse) }
        return compare(installed: app.version, latest: short)
    }

    private nonisolated static func compare(installed: String?, latest: String) -> AppUpdate.Status {
        guard let installed = installed.flatMap(AppVersion.init) else { return .unknown(.unreadableVersion) }
        guard let newest = AppVersion(latest) else { return .unknown(.unreadableResponse) }
        return installed < newest ? .available(version: latest) : .upToDate
    }

    private nonisolated static func result(
        _ app: InstalledApp, source: AppUpdate.Source?, _ status: AppUpdate.Status
    ) -> AppUpdate {
        AppUpdate(id: app.id, name: app.name, installedVersion: app.version, source: source, status: status)
    }
}
