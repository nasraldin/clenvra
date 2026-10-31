import Darwin
public import Foundation

// MARK: - Uninstall: remove an app completely, as if it had never been installed

extension AppsSession {
    /// Everything Uninstall would do to one app, for the confirmation that lists it before anything happens.
    public struct UninstallPlan: Sendable, Equatable, Identifiable {
        public var id: InstalledApp.ID { app.id }
        public let app: InstalledApp
        /// The bundle as reviewed; `nil` when it could not be read.
        public let bundle: BundleItem?
        /// Every owned item Uninstall deletes, at every confidence level the review lists.
        public let items: [OwnedItem]
        /// Owned items left in place: shared with another installed app, holding something protected, or needing
        /// administrator rights while the helper is not available.
        public let kept: [OwnedItem]
        /// How the app was installed; Homebrew apps are removed with `brew` first.
        public let source: InstallSource
        /// Why the app would be left installed; `nil` when it can be uninstalled.
        public let skip: SkipReason?

        /// Estimated bytes freed by the bundle and the items.
        public var bytes: Int64 { (bundle?.reclaimableSize ?? 0) + items.reduce(0) { $0 + $1.reclaimableSize } }
    }

    /// One backup's restore, for the result sheet.
    public struct RestoredBackup: Sendable, Identifiable {
        public var id: URL { backup }
        public let backup: URL
        public let name: String
        public let result: RestoreResult
    }

    /// What backing up apps did.
    public struct BackupRun: Sendable {
        /// Backup folders made.
        public var made: [URL] = []
        /// Apps not backed up, each with the reason.
        public var failed: [(name: String, reason: String)] = []

        public init() {}
    }

    /// The paths a row's Copy Path / Show in Finder act on: every checked app (and the clicked ones) when one of
    /// the clicked apps is checked, otherwise just the clicked apps; in list order.
    public static func paths(
        for apps: [InstalledApp], clicked: Set<InstalledApp.ID>, checked: Set<InstalledApp.ID>
    ) -> [String] {
        let chosen = clicked.isDisjoint(with: checked) ? clicked : clicked.union(checked)
        return apps.map(\.id).filter { chosen.contains($0) }
    }

    /// The plans for `apps`, in order: what each Uninstall would delete, or why it would skip the app.
    public func uninstallPlans(for apps: [InstalledApp]) async -> [UninstallPlan] {
        var plans: [UninstallPlan] = []
        for app in apps {
            if Task.isCancelled { break }
            plans.append(await uninstallPlan(for: app))
        }
        return plans
    }

    /// The inventory's own entry for an app, so a caller's copy can never claim an app is not protected.
    func inventoryEntry(for app: InstalledApp) -> InstalledApp? {
        apps.first { $0.id == app.id }
    }

    func uninstallPlan(for given: InstalledApp) async -> UninstallPlan {
        guard let app = inventoryEntry(for: given) else {
            return UninstallPlan(app: given, bundle: nil, items: [], kept: [], source: .direct, skip: .changed)
        }
        let built = await buildDetail(for: app)
        let skip: SkipReason? =
            switch built.availability {
            case .protected, .managed: .protected
            case .running: .running
            case .available: built.bundle == nil ? .changed : nil
            }
        let deletable = built.items.filter { $0.sharedWith.isEmpty && isSelectable($0) }
        let paths = Set(deletable.map(\.path))
        let source = await InstallSource.detect(
            app: app, homebrewToken: built.homebrewToken, runner: installSourceRunner)
        return UninstallPlan(
            app: app, bundle: built.bundle, items: deletable, kept: built.items.filter { !paths.contains($0.path) },
            source: source, skip: skip)
    }

    /// Removes each app completely and for good (not to the Trash), after the user confirmed the plan listing
    /// everything. Per app: an optional backup (the app is kept if it fails) → for Homebrew apps
    /// `brew uninstall --cask --zap` (or the formula), run as the user, never with sudo (the app is kept if it
    /// fails) → whatever is still there: the bundle first, then, only if it went, every planned item, each checked
    /// again by the deletion gate; files only an administrator can remove go through the helper. Running,
    /// protected or changed apps are skipped. One Activity operation per run. A dry run checks every item and
    /// runs nothing.
    /// - Parameter reviewed: the plans the user confirmed. When given, nothing outside them is touched: an item
    ///   found since is left alone, and each item keeps the snapshot it was reviewed with, so the deletion gate
    ///   refuses one that changed.
    public func uninstall(
        _ apps: [InstalledApp], backup: AppBackup.Scope?, backupFolder: URL? = nil,
        reviewed: [UninstallPlan]? = nil, dryRun: Bool = false
    ) async -> BatchUninstallResult {
        var result = BatchUninstallResult()
        guard !isWorking else { return result }
        isWorking = true
        let operation = UUID()
        let folder = backupFolder ?? AppBackup.defaultFolder(home: home)
        var removedIDs: Set<InstalledApp.ID> = []
        for given in apps {
            if Task.isCancelled { break }
            let current = await uninstallPlan(for: given)
            let app = current.app
            if let skip = current.skip {
                result.skipped.append((app.name, skip))
                continue
            }
            let plan: UninstallPlan
            if let reviewed {
                guard let confirmed = reviewed.first(where: { $0.app.id == app.id }) else { continue }
                plan = Self.restricted(current, to: confirmed)
            } else {
                plan = current
            }
            if let skip = plan.skip {
                result.skipped.append((app.name, skip))
                continue
            }
            guard let bundle = plan.bundle else {
                result.skipped.append((app.name, .changed))
                continue
            }
            if let backup, !dryRun {
                do {
                    let paths = AppBackup.paths(for: backup, bundle: app.id, owned: plan.items)
                    result.backups.append(try await AppBackup.create(app: app, items: paths, scope: backup, in: folder))
                } catch let error as AppBackupError {
                    result.skipped.append((app.name, .backupFailed(error.message)))
                    continue
                } catch {
                    result.skipped.append((app.name, .backupFailed(error.localizedDescription)))
                    continue
                }
            }
            if !dryRun, let command = homebrewUninstallCommand(for: plan.source) {
                if let failure = await runHomebrew(
                    command, app: app, bytes: bundle.reclaimableSize, operationID: operation)
                {
                    result.skipped.append((app.name, .homebrewFailed(failure)))
                    continue
                }
            }
            let (results, bundleDone) = await removePermanently(
                plan, bundle: bundle, dryRun: dryRun, operationID: operation)
            result.summary.add(results)
            if bundleDone {
                result.removed.append(app.name)
                removedIDs.insert(app.id)
            } else {
                result.skipped.append((app.name, .changed))
            }
        }
        isWorking = false
        if !dryRun, !removedIDs.isEmpty {
            checked.subtract(removedIDs)
            let shown = detail?.app.id
            await load()
            if let shown, removedIDs.contains(shown) { await select(nil) }
        }
        return result
    }

    /// The current plan cut down to what the user confirmed, with the snapshots they reviewed.
    static func restricted(_ current: UninstallPlan, to confirmed: UninstallPlan) -> UninstallPlan {
        let paths = Set(current.items.map(\.path))
        let items = confirmed.items.filter { paths.contains($0.path) }
        // An app shown as kept stays kept, even if it could go now: the user did not confirm removing it.
        let skip: SkipReason? =
            confirmed.skip ?? (confirmed.bundle == nil || current.source != confirmed.source ? .changed : nil)
        return UninstallPlan(
            app: current.app, bundle: confirmed.bundle, items: items, kept: current.kept, source: confirmed.source,
            skip: skip)
    }

    /// The `brew` command that removes a Homebrew app, run as the user; `nil` for other apps or without Homebrew.
    func homebrewUninstallCommand(for source: InstallSource) -> Command? {
        guard let homebrew else { return nil }
        let arguments: [String]
        switch source {
        case .homebrewCask(let token):
            guard !token.isEmpty, !token.hasPrefix("-") else { return nil }
            arguments = ["uninstall", "--cask", "--zap", token]
        case .homebrewFormula(let name):
            guard !name.isEmpty, !name.hasPrefix("-") else { return nil }
            arguments = ["uninstall", name]
        case .appStore, .package, .direct:
            return nil
        }
        return Command(executable: homebrew.brew, arguments: arguments, timeout: .seconds(600))
    }

    /// Runs `brew`, logged before and after; `nil` on success, otherwise its last error line.
    private func runHomebrew(_ command: Command, app: InstalledApp, bytes: Int64, operationID: UUID) async -> String? {
        guard let homebrew else { return String(cString: strerror(ENOENT)) }
        func record(_ outcome: ActivityRecord.Outcome) async -> Bool {
            let entry = ActivityRecord(
                operationID: operationID, date: now(), section: .applications, itemPath: app.id, bytes: bytes,
                outcome: outcome)
            return (try? await log.append(entry)) != nil
        }
        guard await record(.intent) else { return String(cString: strerror(EIO)) }  // never act without a log entry
        let result: CommandResult
        do {
            result = try await homebrew.runner.run(command)
        } catch {
            _ = await record(.failed(errno: EIO))
            return String(describing: error)
        }
        guard result.terminationReason == .exited, result.exitStatus == 0 else {
            _ = await record(.failed(errno: EIO))
            let lines = (result.standardError + "\n" + result.standardOutput).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.first { $0.hasPrefix("Error") } ?? lines.last ?? String(cString: strerror(EIO))
        }
        _ = await record(.removedPermanently)
        return nil
    }

    /// Deletes what is still there of a planned app, for good: the bundle first and, only if it went, the items.
    private func removePermanently(
        _ plan: UninstallPlan, bundle: BundleItem, dryRun: Bool, operationID: UUID
    ) async -> (results: [DeletionResult], bundleDone: Bool) {
        let app = plan.app
        var results: [DeletionResult] = []
        var bundleDone = true  // a bundle `brew` already removed is done
        if Self.exists(bundle.path) {
            let item = Self.deletionItem(for: app, bundle: bundle)
            results = await deleter.run([item], mode: .irreversible, dryRun: dryRun, operationID: operationID)
            // A bundle an installer placed as root: the helper may delete it, checking it again itself.
            if !dryRun, case .failed(let code)? = results.first?.outcome, code == EACCES || code == EPERM,
                helperAvailable,
                let system = systemAllowlist.helperItem(
                    path: app.id, expected: bundle.snapshot, owner: nil, freedBytes: bundle.reclaimableSize,
                    section: .applications)
            {
                results = await removeThroughHelper(
                    [system], mode: .irreversible, dryRun: false, operationID: operationID)
            }
            bundleDone = results.contains { result in
                switch result.outcome {
                case .removedPermanently, .wouldDelete: true
                default: false
                }
            }
        }
        let remaining = plan.items.filter { Self.exists($0.path) }
        let owned = remaining.filter { $0.handling == .removable }.map {
            $0.deletionItem(owner: app.bundleIdentifier, section: .applications)
        }
        // The bundle is gone first, so its launch daemons are orphans by the time the helper looks.
        let system = remaining.filter { $0.handling == .revealOnly }.compactMap { helperItem(for: $0, owner: nil) }
        if bundleDone {
            results += await deleter.run(owned, mode: .irreversible, dryRun: dryRun, operationID: operationID)
            results += await removeThroughHelper(system, mode: .irreversible, dryRun: dryRun, operationID: operationID)
        } else {
            // Data without its app is worse than an app without its data: keep everything if the bundle stays.
            results += (owned + system).map { DeletionResult(item: $0, outcome: .notAttempted) }
        }
        return (results, bundleDone)
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    // MARK: - Backing up and restoring

    /// Backs up each app into `folder`: the whole app (bundle and every owned item) or only its settings. Protected
    /// apps are not backed up. Never changes anything outside `folder`.
    public func backUp(_ apps: [InstalledApp], scope: AppBackup.Scope, in folder: URL) async -> BackupRun {
        var run = BackupRun()
        guard !isWorking else { return run }
        isWorking = true
        defer { isWorking = false }
        for given in apps {
            if Task.isCancelled { break }
            guard let app = inventoryEntry(for: given) else {
                run.failed.append((given.name, String(cString: strerror(ENOENT))))
                continue
            }
            let built = await buildDetail(for: app)
            switch built.availability {
            case .protected, .managed:
                run.failed.append((app.name, String(cString: strerror(EPERM))))
                continue
            case .available, .running:
                break
            }
            let paths = AppBackup.paths(for: scope, bundle: app.id, owned: built.items)
            do {
                run.made.append(try await AppBackup.create(app: app, items: paths, scope: scope, in: folder))
            } catch let error as AppBackupError {
                run.failed.append((app.name, error.message))
            } catch {
                run.failed.append((app.name, error.localizedDescription))
            }
        }
        return run
    }

    /// Restores the chosen items of each backup (`items[backup.url]`, `nil` = all). With `replaceExisting`, the
    /// current copy of an item is moved to the Trash first through the deletion gate (logged, so it can be put
    /// back) — never deleted; otherwise existing items are left alone. Refreshes the inventory afterwards.
    public func restore(
        _ backups: [AppBackupInfo], items: [URL: Set<String>] = [:], replaceExisting: Bool
    ) async -> [RestoredBackup] {
        guard !isWorking else { return [] }
        isWorking = true
        let operation = UUID()
        var restored: [RestoredBackup] = []
        for backup in backups {
            if Task.isCancelled { break }
            let result: RestoreResult
            do {
                result = try await AppBackup.restore(
                    backup.url, items: items[backup.url], replaceExisting: replaceExisting, trash: deleter,
                    operationID: operation)
            } catch {
                var failed = RestoreResult()
                let reason = (error as? AppBackupError)?.message ?? error.localizedDescription
                failed.failed = [.init(path: backup.url.path(percentEncoded: false), reason: reason)]
                result = failed
            }
            restored.append(RestoredBackup(backup: backup.url, name: backup.name, result: result))
        }
        isWorking = false
        if restored.contains(where: { !$0.result.restored.isEmpty }) { await load() }
        return restored
    }
}
