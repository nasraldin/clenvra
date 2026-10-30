import Foundation
public import Observation

/// Which apps may use the camera, microphone, screen, files and other protected services, and revoking one grant
/// with Apple's `tccutil`. Reading is read-only; nothing is changed until the person confirms a revoke.
@MainActor
@Observable
public final class PermissionsSession {
    public enum Phase: Sendable, Equatable {
        case idle, loading, ready
        /// Neither privacy database could be read: Clenvra needs Full Disk Access to show permissions.
        case needsAccess
    }

    public enum RevokeResult: Sendable, Equatable {
        /// `tccutil` succeeded and the grant is gone from the database.
        case revoked
        /// The grant could not be revoked here (path client, `tccutil` failed, or the grant is still there); the
        /// person changes it in System Settings.
        case failed
    }

    /// The person's own privacy database.
    public static let userDatabasePath =
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    /// The Mac's privacy database, for every user.
    public static let systemDatabasePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    public private(set) var phase: Phase = .idle
    /// Allowed grants only, sorted by service, then app.
    public private(set) var grants: [PermissionGrant] = []
    /// Databases that could not be read in the last load; their grants are not listed.
    public private(set) var unreadableScopes: Set<PermissionGrant.Scope> = []

    private let userDatabase: String
    private let systemDatabase: String
    private let runner: any CommandRunning
    private let tccutil: String

    public init(
        userDatabase: String = PermissionsSession.userDatabasePath,
        systemDatabase: String = PermissionsSession.systemDatabasePath, runner: any CommandRunning,
        tccutil: String = "/usr/bin/tccutil"
    ) {
        self.userDatabase = userDatabase
        self.systemDatabase = systemDatabase
        self.runner = runner
        self.tccutil = tccutil
    }

    public func load() async {
        phase = .loading
        let read = await Self.read(user: userDatabase, system: systemDatabase)
        unreadableScopes = read.unreadable
        if read.unreadable.count == 2 {
            grants = []
            phase = .needsAccess
            return
        }
        grants = read.grants.filter { $0.isAllowed && PermissionService.isKnown($0.service) }.sorted {
            ($0.service, $0.client, $0.scope.rawValue) < ($1.service, $1.client, $1.scope.rawValue)
        }
        phase = .ready
    }

    /// `tccutil` resets by bundle ID only; programs listed by path are changed in System Settings.
    public func canRevoke(_ grant: PermissionGrant) -> Bool {
        grant.clientIsBundleID && !grant.client.isEmpty
    }

    /// Runs `tccutil reset <service> <bundle ID>`, reloads, and reports success only when the grant is really gone.
    public func revoke(_ grant: PermissionGrant) async -> RevokeResult {
        guard canRevoke(grant) else { return .failed }
        let command = Command(
            executable: tccutil, arguments: ["reset", PermissionService.shortName(grant.service), grant.client],
            timeout: .seconds(15))
        let result = try? await runner.run(command)
        guard let result, result.terminationReason == .exited, result.exitStatus == 0 else { return .failed }
        await load()
        // A system-wide grant survives a reset run as the user, and tccutil may still exit 0: never claim success.
        guard phase == .ready, !unreadableScopes.contains(grant.scope),
            !grants.contains(where: { $0.id == grant.id })
        else { return .failed }
        return .revoked
    }

    @concurrent private static func read(user: String, system: String) async -> (
        grants: [PermissionGrant], unreadable: Set<PermissionGrant.Scope>
    ) {
        var grants: [PermissionGrant] = []
        var unreadable: Set<PermissionGrant.Scope> = []
        for (path, scope) in [(user, PermissionGrant.Scope.user), (system, .system)] {
            do {
                grants += try PermissionDatabase.read(at: path, scope: scope)
            } catch {
                unreadable.insert(scope)
            }
        }
        return (grants, unreadable)
    }
}
