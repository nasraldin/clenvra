import Foundation
import Testing

@Suite("String catalogs")
struct StringCatalogTests {
    @Test("a key without an Arabic translation is reported")
    func reportsMissingArabic() throws {
        let catalog = Data(
            """
            {"sourceLanguage":"en","version":"1.0","strings":{
              "Done":{"localizations":{"ar":{"stringUnit":{"state":"translated","value":"تم"}}}},
              "Scan":{}
            }}
            """.utf8)

        let missing = try StringCatalogAudit.untranslatedKeys(in: catalog, languages: ["ar"])

        #expect(missing == ["Scan (ar)"])
    }

    @Test("a translation still marked as needing review is reported")
    func reportsNeedsReview() throws {
        let catalog = Data(
            """
            {"sourceLanguage":"en","version":"1.0","strings":{
              "Scan":{"localizations":{"ar":{"stringUnit":{"state":"needs_review","value":"فحص"}}}}
            }}
            """.utf8)

        #expect(try StringCatalogAudit.untranslatedKeys(in: catalog, languages: ["ar"]) == ["Scan (ar)"])
    }

    @Test("plural variants count as translated when every variant is translated")
    func pluralVariants() throws {
        let catalog = Data(
            """
            {"sourceLanguage":"en","version":"1.0","strings":{
              "%lld items":{"localizations":{"ar":{"variations":{"plural":{
                "zero":{"stringUnit":{"state":"translated","value":"لا عناصر"}},
                "one":{"stringUnit":{"state":"translated","value":"عنصر واحد"}},
                "other":{"stringUnit":{"state":"new","value":""}}
              }}}}}
            }}
            """.utf8)

        #expect(try StringCatalogAudit.untranslatedKeys(in: catalog, languages: ["ar"]) == ["%lld items (ar)"])
    }

    @Test("the audit scans only this repository, never sibling projects next to it")
    func scansOnlyThisRepository() throws {
        let root = try #require(StringCatalogAudit.repositoryRoot(from: #filePath))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Clenvra.xcworkspace").path))
        for url in StringCatalogAudit.catalogsInRepository() {
            #expect(url.path.hasPrefix(root.path + "/"))
        }
    }

    @Test("every string catalog in the repository is fully translated into Arabic")
    func repositoryCatalogsAreComplete() throws {
        let catalogs = StringCatalogAudit.catalogsInRepository()
        #expect(!catalogs.isEmpty)
        for url in catalogs {
            let missing = try StringCatalogAudit.untranslatedKeys(in: Data(contentsOf: url), languages: ["ar"])
            #expect(missing.isEmpty, "\(url.lastPathComponent): \(missing)")
        }
    }

    @Test("no catalog keeps stale keys: every translated string is still used by the code")
    func noStaleKeys() throws {
        for url in StringCatalogAudit.catalogsInRepository() {
            let stale = try StringCatalogAudit.staleKeys(in: Data(contentsOf: url))
            #expect(stale.isEmpty, "\(url.lastPathComponent) has stale keys (run scripts/sync-strings.sh): \(stale)")
        }
    }
}
