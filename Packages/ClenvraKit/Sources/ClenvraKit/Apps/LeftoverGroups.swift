import Foundation

/// Leftovers of one removed app, so related files can be judged and removed together.
public struct LeftoverGroup: Sendable, Hashable, Identifiable {
    /// The app the files belonged to, as far as the evidence tells.
    public enum Owner: Sendable, Hashable {
        /// The shortest bundle identifier of the group; helpers and extensions (`<id>.helper`) join it.
        case app(identifier: String)
        /// No identifier in the evidence.
        case unknown
    }

    public var id: String {
        switch owner {
        case .app(let identifier): "app:" + identifier.lowercased()
        case .unknown: "unknown"
        }
    }

    public let owner: Owner
    /// The app's name when it is in the Trash, otherwise its bundle identifier; `nil` for an unknown app.
    public let name: String?
    /// Largest first.
    public let items: [OwnedItem]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.reclaimableSize } }

    public init(owner: Owner, name: String?, items: [OwnedItem]) {
        self.owner = owner
        self.name = name
        self.items = items
    }
}

/// Groups leftovers by the app they belonged to.
public enum LeftoverGroups {
    /// Largest group first, "Unknown app" last. Identifiers that share lineage (`com.a.App`, `com.a.App.helper`,
    /// any letter case) form one group.
    public static func groups(_ items: [OwnedItem]) -> [LeftoverGroup] {
        var roots: [String] = []  // Group identifiers, shortest first.
        var members: [String: [OwnedItem]] = [:]  // Keyed by the lowercased root.
        var unknown: [OwnedItem] = []
        let identified = items.map { (item: $0, identifier: identifier(of: $0)) }
        let ordered = identified.sorted { ($0.identifier?.count ?? 0) < ($1.identifier?.count ?? 0) }
        for (item, identifier) in ordered {
            guard let identifier else {
                unknown.append(item)
                continue
            }
            let lowered = identifier.lowercased()
            let root =
                roots.first { lowered == $0.lowercased() || lowered.hasPrefix($0.lowercased() + ".") } ?? identifier
            if !roots.contains(root) { roots.append(root) }
            members[root.lowercased(), default: []].append(item)
        }
        var groups = roots.map { root in
            let items = largestFirst(members[root.lowercased()] ?? [])
            return LeftoverGroup(owner: .app(identifier: root), name: trashedName(in: items) ?? root, items: items)
        }
        groups.sort { lhs, rhs in
            lhs.totalBytes != rhs.totalBytes ? lhs.totalBytes > rhs.totalBytes : lhs.id < rhs.id
        }
        if !unknown.isEmpty { groups.append(LeftoverGroup(owner: .unknown, name: nil, items: largestFirst(unknown))) }
        return groups
    }

    /// The bundle identifier the evidence names, if any.
    static func identifier(of item: OwnedItem) -> String? {
        for evidence in item.evidence {
            switch evidence {
            case .exactBundleIdentifierPath(let id), .containerMetadata(let id), .associatedBundleIdentifier(let id),
                .receipt(let id):
                return id
            case .programInsideBundle, .applicationGroup, .exactName, .nameMatch, .appInTrash:
                continue
            }
        }
        return nil
    }

    private static func trashedName(in items: [OwnedItem]) -> String? {
        for item in items {
            for case .appInTrash(let name) in item.evidence { return name }
        }
        return nil
    }

    private static func largestFirst(_ items: [OwnedItem]) -> [OwnedItem] {
        items.sorted { lhs, rhs in
            lhs.reclaimableSize != rhs.reclaimableSize ? lhs.reclaimableSize > rhs.reclaimableSize : lhs.path < rhs.path
        }
    }
}
