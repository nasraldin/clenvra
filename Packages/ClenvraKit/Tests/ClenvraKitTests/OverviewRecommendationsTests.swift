import Foundation
import Testing

@testable import ClenvraKit

@Suite("OverviewRecommendations")
struct OverviewRecommendationsTests {
    private typealias Input = OverviewRecommendations.Input
    private typealias Kind = OverviewRecommendations.Recommendation.Kind

    private func tool(_ id: String, bytes: Int64?, command: String? = "tool prune") -> Input.Tool {
        Input.Tool(id: id, name: "Tool", bytes: bytes, command: command)
    }

    @Test("nothing scanned and nothing wrong gives no recommendations")
    func empty() {
        #expect(OverviewRecommendations.make(Input()).isEmpty)
    }

    @Test("space items are ranked by reclaimable bytes, largest first")
    func ranking() {
        var input = Input()
        input.cleanup = Input.Totals(bytes: 2_000, count: 3)
        input.developer = Input.Totals(bytes: 9_000, count: 4)
        input.tools = [tool("pnpm.store", bytes: 5_000)]

        let result = OverviewRecommendations.make(input)

        #expect(result.map(\.bytes) == [9_000, 5_000, 2_000])
        #expect(
            result.map(\.kind) == [
                .developerItems(count: 4), .toolCommand(id: "pnpm.store", name: "Tool", command: "tool prune"),
                .cleanupItems(count: 3),
            ])
        #expect(result.map(\.destination) == [.developer, .developer, .cleanup])
    }

    @Test("zero-byte items, tools without a size or command, and empty sections are ignored")
    func zeroBytesIgnored() {
        var input = Input()
        input.cleanup = Input.Totals(bytes: 0, count: 2)
        input.developer = Input.Totals(bytes: 100, count: 0)
        input.tools = [tool("a", bytes: 0), tool("b", bytes: nil), tool("c", bytes: 500, command: nil)]
        input.largestReviewItem = Input.Item(name: "Backup", bytes: 0, destination: .cleanup)

        #expect(OverviewRecommendations.make(input).isEmpty)
    }

    @Test("never more than five tiles")
    func capsAtFive() {
        var input = Input()
        input.tools = (1...8).map { tool("t\($0)", bytes: Int64($0) * 1_000) }

        let result = OverviewRecommendations.make(input)

        #expect(result.count == OverviewRecommendations.maximumCount)
        #expect(result.first?.bytes == 8_000)
        #expect(result.last?.bytes == 4_000)
    }

    @Test("startup leftovers and security attention are always surfaced, even with many space items")
    func priorityTilesAlwaysPresent() {
        var input = Input()
        input.tools = (1...8).map { tool("t\($0)", bytes: Int64($0) * 1_000) }
        input.startupProblemCount = 2
        input.securityAttentionCount = 1

        let result = OverviewRecommendations.make(input)

        #expect(result.count == 5)
        #expect(result.contains { $0.kind == .startupLeftovers(count: 2) && $0.destination == .startup })
        #expect(result.contains { $0.kind == .securityAttention(count: 1) && $0.destination == .system })
        #expect(result.filter { $0.bytes != nil }.map(\.bytes) == [8_000, 7_000, 6_000])
    }

    @Test("no startup or security tile when there is nothing to report")
    func noPriorityTilesWhenClean() {
        var input = Input()
        input.startupProblemCount = 0
        input.securityAttentionCount = 0
        input.freeSpaceRatio = 0.5

        #expect(OverviewRecommendations.make(input).isEmpty)
    }

    @Test("low free space points to Storage")
    func lowDiskSpace() {
        var input = Input()
        input.freeSpaceRatio = 0.04
        input.cleanup = Input.Totals(bytes: 10, count: 1)

        let result = OverviewRecommendations.make(input)

        #expect(result.first?.kind == .lowDiskSpace(freeRatio: 0.04))
        #expect(result.first?.destination == .storage)
        #expect(result.first?.bytes == nil)
    }

    @Test("the largest item needing review is ranked with the other space items")
    func largestReviewItem() {
        var input = Input()
        input.cleanup = Input.Totals(bytes: 100, count: 1)
        input.largestReviewItem = Input.Item(name: "iPhone backup", bytes: 4_000, destination: .cleanup)

        let result = OverviewRecommendations.make(input)

        #expect(result.first?.kind == .reviewItem(name: "iPhone backup"))
        #expect(result.first?.bytes == 4_000)
    }

    @Test("sizes stay raw bytes: formatting belongs to the view")
    func bytesAreUnformatted() {
        var input = Input()
        input.cleanup = Input.Totals(bytes: 1_234_567, count: 1)

        let tile = OverviewRecommendations.make(input).first
        #expect(tile?.bytes == 1_234_567)
    }

    @Test("identifiers are unique so the view can list tiles")
    func uniqueIdentifiers() {
        var input = Input()
        input.cleanup = Input.Totals(bytes: 1, count: 1)
        input.developer = Input.Totals(bytes: 2, count: 1)
        input.tools = [tool("a", bytes: 3), tool("b", bytes: 4)]
        input.startupProblemCount = 1

        let ids = OverviewRecommendations.make(input).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
