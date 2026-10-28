public import Foundation

/// A user-defined file cleanup location that can only produce review candidates.
public struct CustomCleanupRule: Codable, Equatable, Sendable, Identifiable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidFolder(PathRejection)
        case protected(ProtectionReason)
        case invalidMinimumAge
        case invalidNamePattern
    }

    public let id: UUID
    /// Canonical absolute path in memory; portable settings convert it to `~/…` when appropriate.
    public let folder: String
    public let minimumAge: Age
    /// A glob matched against each file name, never against a path outside the rule root.
    public let namePattern: String

    /// Validation at creation prevents unsafe roots from ever entering the cleanup workflow.
    public init(
        id: UUID = UUID(), folder: String, minimumAge: Age, namePattern: String, home: String,
        policy: ProtectionPolicy
    ) throws {
        let parts: [String]
        do {
            parts = try PathPolicy.components(of: folder)
        } catch {
            throw ValidationError.invalidFolder(error)
        }
        let normalized = Self.normalized(folder)
        guard minimumAge.seconds.isFinite, minimumAge.seconds >= 0 else {
            throw ValidationError.invalidMinimumAge
        }
        guard !namePattern.isEmpty, !namePattern.contains("/"),
            !namePattern.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw ValidationError.invalidNamePattern }
        if normalized == Self.normalized(home) { throw ValidationError.protected(.homeRoot) }
        // A volume's child folders are eligible, but a top-level system folder itself is never a rule root.
        guard parts.count > 1 else { throw ValidationError.protected(.system) }
        if let reason = policy.protection(for: normalized) { throw ValidationError.protected(reason) }

        self.id = id
        self.folder = normalized
        self.minimumAge = minimumAge
        self.namePattern = namePattern
    }

    /// Conversion fixes every safety-sensitive field so persistence cannot turn a custom rule into an auto-clean rule.
    public var cleanupRule: CleanupRule {
        CleanupRule(
            id: "custom.\(id.uuidString)", category: .custom, root: .absolute(folder),
            selection: .matchingFiles(pattern: namePattern, minimumAge: minimumAge, maximumDepth: 6), risk: .review,
            action: .moveToTrash, ownership: .none)
    }

    /// Re-validates decoded values at a persistence boundary; malformed or newly protected roots fail closed.
    func validated(home: String, policy: ProtectionPolicy) throws -> CustomCleanupRule {
        try CustomCleanupRule(
            id: id, folder: folder, minimumAge: minimumAge, namePattern: namePattern, home: home, policy: policy)
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
