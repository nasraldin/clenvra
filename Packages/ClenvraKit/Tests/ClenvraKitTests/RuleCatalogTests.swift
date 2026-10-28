import Foundation
import Testing

@testable import ClenvraKit

@Suite("RuleCatalog")
struct RuleCatalogTests {
    private let catalog = RuleCatalog.standard
    private let home = "/Users/u"

    @Test("rule identifiers are unique")
    func uniqueIdentifiers() {
        #expect(Set(catalog.map(\.id)).count == catalog.count)
    }

    @Test("no rule offers a location the protection policy forbids")
    func noProtectedTargets() {
        let policy = ProtectionPolicy(home: home)
        for rule in catalog {
            let root = rule.root.path(home: home)
            let samples: [String] =
                switch rule.selection {
                case .children: [root + "/com.vendor.sample"]
                case .named(let names): names.map { root + "/" + $0 }
                case .files(let extensions, _, _): extensions.map { root + "/sample." + $0 }
                case .matchingFiles: [root + "/sample.log"]
                case .projectArtifacts(let kinds, _, _): kinds.map { root + "/project/" + $0.folder }
                case .emptyFolders: [root + "/sample"]
                }
            for sample in samples {
                #expect(policy.protection(for: sample) == nil, "\(rule.id) targets protected \(sample)")
            }
        }
    }

    @Test("two rules never offer the same item")
    func noOverlap() {
        let byRoot = Dictionary(grouping: catalog) { $0.root.path(home: home) }
        for (root, rules) in byRoot where rules.count > 1 {
            let claimed = rules.flatMap { rule -> [String] in
                if case .named(let names) = rule.selection { return Array(names) }
                return []
            }
            for rule in rules {
                if case .children(let excluded, _) = rule.selection {
                    #expect(Set(claimed).isSubset(of: excluded), "\(rule.id) at \(root) overlaps named rules")
                }
                if case .files = rule.selection {
                    #expect(
                        rules.allSatisfy {
                            switch $0.selection {
                            case .files, .emptyFolders: true
                            default: false
                            }
                        }, "\(rule.id) at \(root) overlaps other rules")
                }
                if case .emptyFolders = rule.selection {
                    #expect(
                        rules.allSatisfy {
                            switch $0.selection {
                            case .files, .emptyFolders: true
                            default: false
                            }
                        }, "\(rule.id) at \(root) overlaps other rules")
                }
            }
        }
    }

    @Test("rules that may hold user content are never pre-selected")
    func reviewRules() throws {
        let installers = try #require(catalog.first { $0.category == .installers })
        let archives = try #require(catalog.first { $0.id == "xcode.archives" })
        let mailAttachments = try #require(catalog.first { $0.category == .mailAttachments })
        let tempFiles = try #require(catalog.first { $0.category == .temporaryFiles })
        let emptyFolders = try #require(catalog.first { $0.category == .emptyFolders })
        #expect(installers.risk == .review)
        #expect(archives.risk == .review)
        #expect(mailAttachments.risk == .review)
        #expect(tempFiles.risk == .review)
        #expect(emptyFolders.risk == .review)
    }

    @Test("mail attachment rules are owned by Mail and never target the mailbox")
    func mailAttachmentRules() throws {
        let rules = catalog.filter { $0.category == .mailAttachments }
        #expect(rules.count == 2)
        for rule in rules {
            #expect(rule.ownership == .fixed("com.apple.mail"))
            #expect(rule.risk == .review)
            #expect(rule.action == .moveToTrash)
            let rootPath = rule.root.path(home: home)
            #expect(!rootPath.hasSuffix("/Library/Mail"), "must never target mailbox itself")
            #expect(rootPath.contains("Mail Downloads"))
        }
    }

    @Test("temporary files rule root is injectable and targets items older than 3 days")
    func temporaryFilesRule() throws {
        let injectedRoot = "/custom/tmp"
        let rule = RuleCatalog.temporaryFilesRule(root: injectedRoot)
        #expect(rule.category == .temporaryFiles)
        #expect(rule.risk == .review)
        #expect(rule.action == .moveToTrash)
        #expect(rule.root.path(home: home) == injectedRoot)
        guard case .children(_, let minimumAge) = rule.selection else {
            Issue.record("expected children selection")
            return
        }
        #expect(minimumAge == .days(3))
    }

    @Test("empty folders rules target Downloads, Desktop and Documents with review risk")
    func emptyFoldersRules() throws {
        let rules = catalog.filter { $0.category == .emptyFolders }
        let roots = Set(rules.map { $0.root.path(home: home) })
        #expect(roots == [home + "/Downloads", home + "/Desktop", home + "/Documents"])
        for rule in rules {
            #expect(rule.risk == .review)
            #expect(rule.action == .moveToTrash)
            if case .emptyFolders(let maxDepth) = rule.selection {
                #expect(maxDepth > 0)
            } else {
                Issue.record("expected emptyFolders selection")
            }
        }
    }

    @Test("editor cache rules are owned by their app, so they are skipped while the editor runs")
    func editorOwnership() throws {
        let code = try #require(catalog.first { $0.id == "ide.vscode" })
        #expect(code.ownership == .fixed("com.microsoft.VSCode"))
        guard case .named(let names) = code.selection else {
            Issue.record("expected named selection")
            return
        }
        #expect(names.contains("CachedData"))
        #expect(!names.contains("User"))
    }

    @Test("the standard catalog finds real items in a fixture home")
    func scansFixtureHome() async throws {
        let scratch = try TemporaryDirectory()
        let fixture = FixtureBuilder(root: scratch.url)
        try fixture.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 100)
        try fixture.file("Library/Caches/com.vendor.app/blob", bytes: 100)
        let home = String(scratch.url.path(percentEncoded: false).dropLast())
        let fixtureTmp = scratch.url.appending(component: "tmp").path(percentEncoded: false)

        var found: [String: [String]] = [:]
        for rule in RuleCatalog.standard(temporaryDirectory: fixtureTmp) {
            let result = await RuleScanner.scan(
                rule, home: home, policy: ProtectionPolicy(home: home), ownerState: { _ in .notRunning })
            if !result.candidates.isEmpty { found[rule.id] = result.candidates.map(\.name) }
        }

        #expect(found["xcode.derivedData"] == ["App-abc"])
        #expect(found["caches.user"] == ["com.vendor.app"])
    }
}
