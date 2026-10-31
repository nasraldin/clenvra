import Darwin
public import Foundation

/// What one backup holds; written as `manifest.json` inside the backup folder.
public struct AppBackupManifest: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// Absolute path the item was copied from, and where it is restored to.
        public let original: String
        /// File name of the item's zip inside the backup folder.
        public let archive: String
        /// Size of the item when it was backed up.
        public let bytes: Int64
    }

    public let bundleID: String?
    public let name: String
    public let version: String?
    public let created: Date
    public let items: [Item]
    /// What was backed up; manifests written before scopes existed are whole-app backups.
    public var scope: AppBackup.Scope = .wholeApp
}

extension AppBackupManifest {
    private enum CodingKeys: String, CodingKey {
        case bundleID, name, version, created, items, scope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        created = try container.decode(Date.self, forKey: .created)
        items = try container.decode([Item].self, forKey: .items)
        scope = try container.decodeIfPresent(AppBackup.Scope.self, forKey: .scope) ?? .wholeApp
    }
}

/// A backup found in the backups folder.
public struct AppBackupInfo: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    /// The `.clenvrabackup` folder.
    public let url: URL
    public let bundleID: String?
    public let name: String
    public let version: String?
    public let created: Date
    public let items: [AppBackupManifest.Item]
    /// Space the backup itself uses: the size of its zips.
    public let archiveBytes: Int64
    public var scope: AppBackup.Scope = .wholeApp

    /// Size of the backed-up items, as they were on disk.
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// What a restore did, item by item.
public struct RestoreResult: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// Paths put back.
    public var restored: [String] = []
    /// Paths left alone because something already exists there; restore never overwrites.
    public var skippedExisting: [String] = []
    /// Paths that could not be put back (for example, no permission), each with the reason.
    public var failed: [Failure] = []
    /// Current copies moved to the Trash (logged in Activity, so they can be put back) to make room for the backup's.
    public var movedToTrash: [String] = []
    /// Current copies the deletion gate refused to move (open, changed, protected), so the backup's copy was not
    /// restored over them.
    public var notReplaced: [CleanupSummary.Problem] = []

    public init() {}
}

/// Why a backup could not be made or read.
public enum AppBackupError: Error, Sendable, Equatable {
    /// A folder could not be created (`errno`).
    case folder(path: String, errno: Int32)
    /// An item to back up does not exist (any more).
    case missingItem(String)
    /// `ditto` failed or wrote no archive.
    case archive(path: String, message: String)
    /// The manifest could not be written or read.
    case manifest(String)
    /// There was nothing to back up (for example, a settings-only backup of an app without settings).
    case nothingToBackUp

    /// A short reason for the result sheet, in the system's words where there are some.
    public var message: String {
        switch self {
        case .nothingToBackUp: String(cString: strerror(ENOENT))
        case .folder(_, let code): String(cString: strerror(code))
        case .missingItem(let path): String(cString: strerror(ENOENT)) + ": " + path
        case .archive(_, let message): message
        case .manifest(let message): message
        }
    }
}

/// Copies an app and its files into a plain folder the user can see in Finder, and puts them back later.
///
/// A backup is `<App Name> <version> <yyyy-MM-dd HHmm>.clenvrabackup/` with `manifest.json` and one
/// `ditto` zip per item (keeping permissions, extended attributes and resource forks). Restoring never
/// overwrites anything and never asks for administrator rights.
public enum AppBackup {
    /// What a backup holds.
    public enum Scope: String, Codable, Sendable, Hashable, CaseIterable {
        /// The bundle and every file the app owns: its whole state, for example before an upgrade.
        case wholeApp
        /// Only the app's settings and data: preferences, Application Support, containers, saved state, cookies
        /// and web storage. Never the bundle, caches or logs.
        case settingsOnly
    }

    /// Kinds of owned items a settings-only backup keeps.
    static let settingsKinds: Set<OwnedItem.Kind> = [
        .preferences, .applicationSupport, .container, .groupContainer, .savedState, .cookies, .httpStorage,
    ]

    /// The paths a backup of `scope` takes: the bundle first (whole app only), then the owned items, in order.
    /// Items holding something protected (keys, keychains) are never copied.
    public static func paths(for scope: Scope, bundle: String, owned: [OwnedItem]) -> [String] {
        let items = owned.filter { !$0.containsProtectedItem }
        switch scope {
        case .wholeApp:
            return [bundle] + items.map(\.path).filter { $0 != bundle }
        case .settingsOnly:
            return items.filter { settingsKinds.contains($0.kind) }.map(\.path)
        }
    }

    public static let folderExtension = "clenvrabackup"
    public static let manifestName = "manifest.json"
    static let ditto = "/usr/bin/ditto"
    /// Large apps take a while to compress; a hung `ditto` still cannot block forever.
    static let timeout = Duration.seconds(3_600)

    /// `~/Documents/Clenvra Backups`; created on first use.
    public static func defaultFolder(home: String) -> URL {
        URL(filePath: home + "/Documents/Clenvra Backups", directoryHint: .isDirectory)
    }

    /// Backs up `items` (absolute paths, normally the bundle first) into a new folder inside `folder`. Every zip
    /// is checked to exist and be non-empty; on any failure the partial backup is removed and the error thrown.
    @concurrent public static func create(
        app: InstalledApp, items: [String], scope: Scope = .wholeApp, in folder: URL,
        runner: any CommandRunning = ProcessCommandRunner(), now: Date = Date()
    ) async throws -> URL {
        guard !items.isEmpty else { throw AppBackupError.nothingToBackUp }
        let root = folder.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw AppBackupError.folder(path: root, errno: posixCode(error) ?? EACCES)
        }
        let backup = try makeBackupFolder(in: root, baseName: baseName(of: app, now: now))
        do {
            var entries: [AppBackupManifest.Item] = []
            for (index, path) in items.enumerated() {
                var info = stat()
                guard lstat(path, &info) == 0 else { throw AppBackupError.missingItem(path) }
                let archive = "item-\(index + 1).zip"
                let destination = backup + "/" + archive
                let command = Command(
                    executable: ditto, arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", path, destination],
                    timeout: timeout)
                try await run(command, runner: runner, path: path)
                var written = stat()
                guard lstat(destination, &written) == 0, written.st_mode & S_IFMT == S_IFREG, written.st_size > 0
                else { throw AppBackupError.archive(path: path, message: String(cString: strerror(EIO))) }
                entries.append(.init(original: path, archive: archive, bytes: size(of: path)))
            }
            let manifest = AppBackupManifest(
                bundleID: app.bundleIdentifier, name: app.name, version: app.version, created: now, items: entries,
                scope: scope)
            do {
                try encoder.encode(manifest).write(
                    to: URL(filePath: backup + "/" + manifestName), options: .atomic)
            } catch {
                throw AppBackupError.manifest(error.localizedDescription)
            }
            return URL(filePath: backup, directoryHint: .isDirectory)
        } catch {
            // Only the folder this call created, so a half-written backup never looks like a good one.
            try? FileManager.default.removeItem(atPath: backup)
            throw error
        }
    }

    /// Backups in `folder`, newest first. Folders without a readable manifest are ignored.
    public static func list(in folder: URL) -> [AppBackupInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { ($0 as NSString).pathExtension == folderExtension }
            .compactMap { name -> AppBackupInfo? in
                let url = folder.appending(path: name, directoryHint: .isDirectory)
                guard let manifest = try? readManifest(url) else { return nil }
                let archives = manifest.items.reduce(Int64(0)) { total, item in
                    var info = stat()
                    let path = url.appending(path: item.archive).path(percentEncoded: false)
                    return total + (lstat(path, &info) == 0 ? Int64(info.st_size) : 0)
                }
                return AppBackupInfo(
                    url: url, bundleID: manifest.bundleID, name: manifest.name, version: manifest.version,
                    created: manifest.created, items: manifest.items, archiveBytes: archives, scope: manifest.scope)
            }
            .sorted { $0.created == $1.created ? $0.url.path < $1.url.path : $0.created > $1.created }
    }

    /// Puts items back where they were. Items are extracted next to their original place and moved in with an
    /// exclusive rename, so nothing is ever overwritten.
    /// - Parameters:
    ///   - items: original paths to restore; `nil` restores every item of the backup.
    ///   - replaceExisting: when something exists at an item's place, move it to the Trash first through `trash`
    ///     (the deletion gate, logged in Activity, so it can be put back). Without it, or without `trash`, existing
    ///     items are left alone and reported.
    ///   - trash: the deletion executor that moves current copies to the Trash; never deletes anything.
    @concurrent public static func restore(
        _ backup: URL, items chosen: Set<String>? = nil, replaceExisting: Bool = false,
        trash: DeletionExecutor? = nil, operationID: UUID = UUID(),
        runner: any CommandRunning = ProcessCommandRunner()
    ) async throws -> RestoreResult {
        let manifest: AppBackupManifest
        do {
            manifest = try readManifest(backup)
        } catch {
            throw AppBackupError.manifest(error.localizedDescription)
        }
        let folder = backup.path(percentEncoded: false)
        var result = RestoreResult()
        for item in manifest.items where chosen?.contains(item.original) ?? true {
            let original = item.original
            var info = stat()
            if lstat(original, &info) == 0 {
                guard replaceExisting, let trash else {
                    result.skippedExisting.append(original)
                    continue
                }
                // The current copy goes to the Trash first; the backup's copy only comes back if that worked.
                let current = DeletionItem(
                    path: original, ruleRoot: (original as NSString).deletingLastPathComponent,
                    expected: FileSnapshot(info), ownerBundleID: manifest.bundleID, freedBytes: 0,
                    section: .applications)
                let outcome = await trash.run([current], mode: .moveToTrash, operationID: operationID).first?.outcome
                guard let outcome, outcome.isMovedToTrash else {
                    result.notReplaced.append(.init(path: original, reason: outcome ?? .notAttempted))
                    continue
                }
                result.movedToTrash.append(original)
            }
            do {
                if try await restoreItem(item, from: folder, runner: runner) {
                    result.restored.append(original)
                } else {
                    result.skippedExisting.append(original)
                }
            } catch let error as AppBackupError {
                result.failed.append(.init(path: original, reason: error.message))
            } catch {
                result.failed.append(.init(path: original, reason: error.localizedDescription))
            }
        }
        return result
    }

    // MARK: - Private

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func readManifest(_ backup: URL) throws -> AppBackupManifest {
        let data = try Data(contentsOf: backup.appending(path: manifestName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AppBackupManifest.self, from: data)
        // A manifest edited by hand must not point restore at odd places or read files outside the backup.
        for item in manifest.items {
            let components = item.original.split(separator: "/", omittingEmptySubsequences: false)
            guard item.original.hasPrefix("/"), item.original.count > 1, !item.original.hasSuffix("/"),
                !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                !item.archive.isEmpty, !item.archive.contains("/"), item.archive != ".", item.archive != ".."
            else { throw AppBackupError.manifest(String(cString: strerror(EINVAL))) }
        }
        return manifest
    }

    /// Extracts one item into a fresh staging folder beside its original place, then moves it in without
    /// replacing anything. Returns `false` when something appeared at the original path meanwhile.
    private static func restoreItem(_ item: AppBackupManifest.Item, from folder: String, runner: any CommandRunning)
        async throws -> Bool
    {
        let original = item.original
        let parent = (original as NSString).deletingLastPathComponent
        let name = (original as NSString).lastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw AppBackupError.folder(path: parent, errno: posixCode(error) ?? EACCES)
        }
        let staging = parent + "/.clenvra-restore-" + UUID().uuidString
        guard mkdir(staging, 0o700) == 0 else { throw AppBackupError.folder(path: parent, errno: errno) }
        defer {
            // The staging folder is this call's own; it is empty unless the move below did not happen.
            if rmdir(staging) != 0 { try? FileManager.default.removeItem(atPath: staging) }
        }
        let command = Command(
            executable: ditto, arguments: ["-x", "-k", folder + "/" + item.archive, staging], timeout: timeout)
        try await run(command, runner: runner, path: original)
        let extracted = staging + "/" + name
        var info = stat()
        guard lstat(extracted, &info) == 0 else {
            throw AppBackupError.archive(path: original, message: String(cString: strerror(ENOENT)))
        }
        guard renamex_np(extracted, original, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return false }
            throw AppBackupError.folder(path: original, errno: errno)
        }
        return true
    }

    private static func run(_ command: Command, runner: any CommandRunning, path: String) async throws {
        let result: CommandResult
        do {
            result = try await runner.run(command)
        } catch {
            throw AppBackupError.archive(path: path, message: String(describing: error))
        }
        if result.terminationReason == .cancelled { throw CancellationError() }
        guard result.terminationReason == .exited, result.exitStatus == 0 else {
            let lines = result.standardError.split(whereSeparator: \.isNewline)
            let message = lines.last.map(String.init) ?? String(cString: strerror(EIO))
            throw AppBackupError.archive(path: path, message: message)
        }
    }

    private static func baseName(of app: InstalledApp, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let name = [app.name, app.version, formatter.string(from: now)].compactMap { $0 }.joined(separator: " ")
        let cleaned = name.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    /// A new folder that did not exist before; " 2", " 3"… when two backups share a minute.
    private static func makeBackupFolder(in root: String, baseName: String) throws -> String {
        for attempt in 1...100 {
            let suffix = attempt == 1 ? "" : " \(attempt)"
            let path = root + "/" + baseName + suffix + "." + folderExtension
            if mkdir(path, 0o755) == 0 { return path }
            guard errno == EEXIST else { throw AppBackupError.folder(path: path, errno: errno) }
        }
        throw AppBackupError.folder(path: root, errno: EEXIST)
    }

    /// Bytes of a file, or of every file inside a folder; symlinks are not followed.
    private static func size(of path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int64(info.st_size) }
        var total: Int64 = 0
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func posixCode(_ error: any Error) -> Int32? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return EACCES
            case NSFileWriteOutOfSpaceError: return ENOSPC
            case NSFileWriteVolumeReadOnlyError: return EROFS
            default: return nil
            }
        }
        return nil
    }
}
