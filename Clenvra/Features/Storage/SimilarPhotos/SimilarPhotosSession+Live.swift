import ClenvraKit

extension SimilarPhotosSession {
    /// The session wired to the real Trash, the activity log and the app's live protection rules.
    @MainActor
    static func live(environment: AppEnvironment) -> SimilarPhotosSession {
        // Photos are user files, never owned by a running app; "unknown" is the safe answer if ever asked.
        SimilarPhotosSession(
            home: environment.home, policy: environment.policy,
            deleter: environment.makeDeleter { _ in .unknown })
    }
}
