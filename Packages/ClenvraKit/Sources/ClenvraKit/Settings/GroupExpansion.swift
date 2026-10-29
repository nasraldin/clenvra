import Foundation

/// Which groups of a result list the person closed. Kept as text so a window can remember it across launches; every
/// group starts open.
public struct GroupExpansion: Sendable, Equatable {
    private var collapsed: Set<String>

    /// Restores from `stored`; unreadable text opens every group.
    public init(stored: String) {
        let ids = (try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? []
        collapsed = Set(ids)
    }

    /// The text to keep. JSON, so group names may hold any character.
    public var stored: String {
        let data = (try? JSONEncoder().encode(collapsed.sorted())) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public func isExpanded(_ id: String) -> Bool { !collapsed.contains(id) }

    /// Opens or closes the given groups: one for a click, all of them for Option-click (as in Finder).
    public mutating func set(_ ids: some Sequence<String>, expanded: Bool) {
        if expanded { collapsed.subtract(ids) } else { collapsed.formUnion(ids) }
    }
}
