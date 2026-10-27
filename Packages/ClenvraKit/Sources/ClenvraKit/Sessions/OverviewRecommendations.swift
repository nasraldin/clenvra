public import Foundation

/// Picks the few findings worth showing first on the Overview, from plain totals other sections already computed.
///
/// Pure and deterministic, so ranking is unit-tested; the view formats sizes and words each tile.
public enum OverviewRecommendations {
    /// The Overview is a summary, not a list: it never shows more tiles than this.
    public static let maximumCount = 5

    /// Below this share of free space on the startup disk, macOS starts to struggle.
    public static let lowFreeSpaceRatio = 0.10

    /// Where a tile leads; the app maps it to a sidebar section.
    public enum Destination: Sendable, Hashable {
        case storage, cleanup, developer, startup, system
    }

    /// Snapshot of what the other sections found; `nil` totals mean "not scanned yet".
    public struct Input: Sendable, Equatable {
        /// Items a section would clean by default (safe ones) and the space they free.
        public struct Totals: Sendable, Equatable {
            public var bytes: Int64
            public var count: Int

            public init(bytes: Int64, count: Int) {
                self.bytes = bytes
                self.count = count
            }
        }

        /// A developer tool's store that the tool's own command can shrink.
        public struct Tool: Sendable, Equatable {
            public var id: String
            public var name: LocalizedStringResource
            public var bytes: Int64?
            /// The command shown before it runs; `nil` when the tool offers none.
            public var command: String?

            public init(id: String, name: LocalizedStringResource, bytes: Int64?, command: String?) {
                self.id = id
                self.name = name
                self.bytes = bytes
                self.command = command
            }
        }

        /// One large item that is not cleaned by default because it needs the user's review.
        public struct Item: Sendable, Equatable {
            public var name: String
            public var bytes: Int64
            public var destination: Destination

            public init(name: String, bytes: Int64, destination: Destination) {
                self.name = name
                self.bytes = bytes
                self.destination = destination
            }
        }

        public var cleanup: Totals?
        public var developer: Totals?
        public var tools: [Tool] = []
        public var largestReviewItem: Item?
        public var startupProblemCount = 0
        public var securityAttentionCount = 0
        /// Free share (0…1) of the startup volume.
        public var freeSpaceRatio: Double?

        public init() {}
    }

    /// One tile: what was found, how much it frees (raw bytes), and which section handles it.
    public struct Recommendation: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case lowDiskSpace(freeRatio: Double)
            case cleanupItems(count: Int)
            case developerItems(count: Int)
            case toolCommand(id: String, name: LocalizedStringResource, command: String)
            case reviewItem(name: String)
            case startupLeftovers(count: Int)
            case securityAttention(count: Int)
        }

        public let kind: Kind
        /// `nil` for tiles that are not about space.
        public let bytes: Int64?
        public let destination: Destination

        public var id: String {
            switch kind {
            case .lowDiskSpace: "lowDiskSpace"
            case .cleanupItems: "cleanup"
            case .developerItems: "developer"
            case .toolCommand(let id, _, _): "tool." + id
            case .reviewItem(let name): "review." + name
            case .startupLeftovers: "startup"
            case .securityAttention: "security"
            }
        }
    }

    /// Alerts first (low space), then space items by bytes freed, then startup and security, capped at five.
    /// Startup leftovers and security attention always keep their place; space items fill the remaining slots.
    public static func make(_ input: Input) -> [Recommendation] {
        var leading: [Recommendation] = []
        if let ratio = input.freeSpaceRatio, ratio < lowFreeSpaceRatio {
            leading.append(Recommendation(kind: .lowDiskSpace(freeRatio: ratio), bytes: nil, destination: .storage))
        }

        var trailing: [Recommendation] = []
        if input.startupProblemCount > 0 {
            trailing.append(
                Recommendation(
                    kind: .startupLeftovers(count: input.startupProblemCount), bytes: nil, destination: .startup))
        }
        if input.securityAttentionCount > 0 {
            trailing.append(
                Recommendation(
                    kind: .securityAttention(count: input.securityAttentionCount), bytes: nil, destination: .system))
        }

        let space = spaceItems(input).filter { ($0.bytes ?? 0) > 0 }
            .enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.bytes ?? 0, rhs.element.bytes ?? 0)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)

        let slots = max(0, maximumCount - leading.count - trailing.count)
        return Array((leading + space.prefix(slots) + trailing).prefix(maximumCount))
    }

    private static func spaceItems(_ input: Input) -> [Recommendation] {
        var items: [Recommendation] = []
        if let cleanup = input.cleanup, cleanup.count > 0 {
            items.append(
                Recommendation(kind: .cleanupItems(count: cleanup.count), bytes: cleanup.bytes, destination: .cleanup))
        }
        if let developer = input.developer, developer.count > 0 {
            items.append(
                Recommendation(
                    kind: .developerItems(count: developer.count), bytes: developer.bytes, destination: .developer))
        }
        for tool in input.tools {
            guard let command = tool.command, let bytes = tool.bytes else { continue }
            items.append(
                Recommendation(
                    kind: .toolCommand(id: tool.id, name: tool.name, command: command), bytes: bytes,
                    destination: .developer))
        }
        if let item = input.largestReviewItem {
            items.append(
                Recommendation(kind: .reviewItem(name: item.name), bytes: item.bytes, destination: item.destination))
        }
        return items
    }
}
