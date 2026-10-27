import ClenvraKit

extension DuplicatesSession {
    /// The session wired to the real Trash, the activity log and the app's live protection rules.
    @MainActor
    static func live(environment: AppEnvironment) -> DuplicatesSession {
        // Duplicates are user files, never owned by a running app; "unknown" is the safe answer if ever asked.
        DuplicatesSession(
            home: environment.home, policy: environment.policy,
            deleter: environment.makeDeleter { _ in .unknown })
    }
}
