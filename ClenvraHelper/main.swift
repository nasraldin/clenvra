import ClenvraKit
import Darwin
import Foundation
import Synchronization

// Clenvra's optional privileged helper (`technical-architecture.md` §6a). launchd starts it on demand when the app
// connects; it exits after a minute without work. All decisions live in ClenvraKit's `HelperService`, which runs the
// allowlist, the managed-software check and the full deletion gate again for every item.

/// Root-owned folder for the helper's own activity log.
let logDirectory = "/Library/Application Support/Clenvra/Helper"
/// Root-only folder where Put Back checks an item before placing it; on the same volume as users' Trash folders.
let stagingDirectory = logDirectory + "/Staging"

/// The app bundle this helper ships in (…/Clenvra.app/Contents/MacOS/ClenvraHelper), protected from removal.
let appBundlePath: String? = {
    let executable = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return bundle.pathExtension == "app" ? bundle.path(percentEncoded: false) : nil
}()

let idleWatch = IdleWatch { exit(0) }

/// One connected app. Every payload is decoded and checked here; nothing from the app is trusted.
final class HelperEndpoint: NSObject, ClenvraHelperProtocol, Sendable {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func protocolVersion(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperIdentity.protocolVersion)
    }

    func perform(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let decoded = try? HelperRequest.decode(request) else {
            reply(nil)
            return
        }
        idleWatch.begin()
        let service = service
        Task {
            let response = await service.perform(decoded)
            reply(try? response.encoded())
            idleWatch.end()
        }
    }

    func restore(_ record: Data, reply: @escaping @Sendable (Data?) -> Void) {
        // Only which item to restore is taken from the app; the service uses its own log for everything else.
        guard let decoded = try? JSONDecoder().decode(ActivityRecord.self, from: record) else {
            reply(try? JSONEncoder().encode(RestoreError.notRestorable))
            return
        }
        idleWatch.begin()
        let service = service
        Task {
            let failure = await service.restore(decoded)
            reply(failure.flatMap { try? JSONEncoder().encode($0) })
            idleWatch.end()
        }
    }

    func removeOrphanedLaunchItem(_ item: Data, operationID: String, reply: @escaping @Sendable (Data?) -> Void) {
        guard let decoded = try? JSONDecoder().decode(DeletionItem.self, from: item),
            let operation = UUID(uuidString: operationID)
        else {
            reply(nil)
            return
        }
        idleWatch.begin()
        let service = service
        Task {
            let outcome = await service.removeOrphanedLaunchItem(decoded, operationID: operation)
            reply(try? JSONEncoder().encode(outcome))
            idleWatch.end()
        }
    }

    func deleteLocalSnapshot(_ date: String, reply: @escaping @Sendable (String?) -> Void) {
        idleWatch.begin()
        let service = service
        Task {
            reply(await service.deleteLocalSnapshot(date: date).rawValue)
            idleWatch.end()
        }
    }

    func setLaunchItemEnabled(
        _ item: Data, enabled: Bool, authorization: Data, reply: @escaping @Sendable (String?) -> Void
    ) {
        guard let decoded = try? JSONDecoder().decode(DeletionItem.self, from: item) else {
            reply(nil)
            return
        }
        idleWatch.begin()
        let service = service
        Task {
            let result = await service.setLaunchItemEnabled(decoded, enabled: enabled, authorization: authorization)
            reply(result.rawValue)
            idleWatch.end()
        }
    }

    func resetPermission(
        _ permission: String, bundleID: String, authorization: Data, reply: @escaping @Sendable (String?) -> Void
    ) {
        idleWatch.begin()
        let service = service
        Task {
            let result = await service.resetPermission(
                service: permission, bundleID: bundleID, authorization: authorization)
            reply(result.rawValue)
            idleWatch.end()
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Checked again on every message, not only when connecting (S25).
        connection.setCodeSigningRequirement(HelperIdentity.clientRequirement)
        // The user comes from the connection, never from the request; only administrators may use the helper.
        let uid = connection.effectiveUserIdentifier
        guard HelperAuthorization.isAdministrator(uid: uid), let home = Self.home(of: uid) else { return false }
        let service = HelperService(
            allowlist: HelperAllowlist(), clientHome: home, clientUID: uid,
            log: ActivityLog(directory: URL(filePath: logDirectory, directoryHint: .isDirectory)),
            staging: stagingDirectory,
            ownPaths: ["/Library/Application Support/Clenvra"] + (appBundlePath.map { [$0] } ?? []),
            // Mac-wide startup items and permissions: an administrator's password every time.
            authorize: HelperRight.authorize)
        connection.exportedInterface = NSXPCInterface(with: (any ClenvraHelperProtocol).self)
        connection.exportedObject = HelperEndpoint(service: service)
        connection.resume()
        idleWatch.begin()
        idleWatch.end()
        return true
    }

    /// Canonical home folder of a regular (non-system) user.
    static func home(of uid: uid_t) -> String? {
        guard uid >= 500, let entry = getpwuid(uid), let directory = entry.pointee.pw_dir,
            let resolved = realpath(directory, nil)
        else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// The log folder belongs to root and nobody else can write to it.
mkdir("/Library/Application Support/Clenvra", 0o755)
mkdir(logDirectory, 0o700)
mkdir(stagingDirectory, 0o700)
// The password rule for Mac-wide changes; never shared, never remembered.
HelperRight.install()

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.setConnectionCodeSigningRequirement(HelperIdentity.clientRequirement)
listener.delegate = delegate
listener.resume()
idleWatch.start()
dispatchMain()
