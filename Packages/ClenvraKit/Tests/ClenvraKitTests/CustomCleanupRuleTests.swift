import Foundation
import Testing

@testable import ClenvraKit

@Suite("CustomCleanupRule")
struct CustomCleanupRuleTests {
    private let home = "/Users/a"
    private var policy: ProtectionPolicy { ProtectionPolicy(home: home) }

    @Test("a custom rule becomes a stable, review-only Trash rule")
    func cleanupRule() throws {
        let id = UUID()
        let custom = try CustomCleanupRule(
            id: id, folder: "/Users/a/Work/Logs/", minimumAge: .days(7), namePattern: "*.log", home: home,
            policy: policy)

        #expect(custom.folder == "/Users/a/Work/Logs")
        #expect(custom.cleanupRule.id == "custom.\(id.uuidString)")
        #expect(custom.cleanupRule.category == .custom)
        #expect(custom.cleanupRule.root == .absolute("/Users/a/Work/Logs"))
        #expect(
            custom.cleanupRule.selection
                == .matchingFiles(pattern: "*.log", minimumAge: .days(7), maximumDepth: 6))
        #expect(custom.cleanupRule.risk == .review)
        #expect(custom.cleanupRule.action == .moveToTrash)
        #expect(custom.cleanupRule.ownership == .none)
    }

    @Test(
        "protected folders, home roots and top-level system folders are rejected with their reason",
        arguments: [
            ("/Users/a", ProtectionReason.homeRoot),
            ("/Users/a/Documents", .homeRoot),
            ("/Users/a/Library", .homeRoot),
            ("/Users/a/.ssh", .secret),
            ("/System", .system),
            ("/Library", .system),
            ("/var", .system),
        ])
    func protectedFolder(_ folder: String, _ reason: ProtectionReason) {
        #expect(throws: CustomCleanupRule.ValidationError.protected(reason)) {
            try CustomCleanupRule(
                folder: folder, minimumAge: .days(1), namePattern: "*.log", home: home, policy: policy)
        }
    }

    @Test("an excluded folder is rejected when the rule is created")
    func excludedFolder() {
        let policy = ProtectionPolicy(home: home, exclusions: ["/Users/a/Work/keep"])
        #expect(throws: CustomCleanupRule.ValidationError.protected(.excluded)) {
            try CustomCleanupRule(
                folder: "/Users/a/Work/keep/logs", minimumAge: .days(1), namePattern: "*.log", home: home,
                policy: policy)
        }
    }

    @Test("invalid paths, ages and name patterns are refused")
    func invalidInput() {
        #expect(throws: CustomCleanupRule.ValidationError.invalidFolder(.notAbsolute)) {
            try CustomCleanupRule(
                folder: "Logs", minimumAge: .days(1), namePattern: "*.log", home: home, policy: policy)
        }
        #expect(throws: CustomCleanupRule.ValidationError.invalidMinimumAge) {
            try CustomCleanupRule(
                folder: "/Users/a/Work/Logs", minimumAge: Age(seconds: -1), namePattern: "*.log", home: home,
                policy: policy)
        }
        #expect(throws: CustomCleanupRule.ValidationError.invalidNamePattern) {
            try CustomCleanupRule(
                folder: "/Users/a/Work/Logs", minimumAge: .days(1), namePattern: "Logs/*.log", home: home,
                policy: policy)
        }
    }

    @Test("nested folders below a system root or on another volume remain eligible")
    func eligibleFolders() throws {
        for folder in ["/Library/Logs/Example", "/Volumes/Work/Logs"] {
            let rule = try CustomCleanupRule(
                folder: folder, minimumAge: .days(0), namePattern: "*", home: home, policy: policy)
            #expect(rule.folder == folder)
        }
    }
}
