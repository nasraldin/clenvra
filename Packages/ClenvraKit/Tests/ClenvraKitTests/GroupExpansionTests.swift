import Testing

@testable import ClenvraKit

/// Groups in result lists open and close, are remembered across launches, and Option-click applies to all (F4).
@Suite("Group expansion")
struct GroupExpansionTests {
    @Test("every group starts open")
    func startsOpen() {
        let expansion = GroupExpansion(stored: "")
        #expect(expansion.isExpanded("logs"))
    }

    @Test("closing one group leaves the others open")
    func closesOne() {
        var expansion = GroupExpansion(stored: "")
        expansion.set(["logs"], expanded: false)
        #expect(!expansion.isExpanded("logs"))
        #expect(expansion.isExpanded("caches"))
    }

    @Test("Option-click closes and opens every group at once")
    func appliesToAll() {
        var expansion = GroupExpansion(stored: "")
        expansion.set(["logs", "caches", "trash"], expanded: false)
        #expect(["logs", "caches", "trash"].allSatisfy { !expansion.isExpanded($0) })
        expansion.set(["logs", "caches", "trash"], expanded: true)
        #expect(["logs", "caches", "trash"].allSatisfy { expansion.isExpanded($0) })
    }

    @Test("the stored text restores the same groups, including names with line breaks")
    func roundTrips() {
        var expansion = GroupExpansion(stored: "")
        expansion.set(["/Users/me/odd\nname", "logs"], expanded: false)
        let restored = GroupExpansion(stored: expansion.stored)
        #expect(restored == expansion)
        #expect(!restored.isExpanded("/Users/me/odd\nname"))
    }

    @Test("unreadable stored text opens every group")
    func ignoresDamage() {
        #expect(GroupExpansion(stored: "not json").isExpanded("logs"))
    }
}
