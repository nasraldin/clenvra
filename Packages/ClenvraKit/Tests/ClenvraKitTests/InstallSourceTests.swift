import Foundation
import Testing

@testable import ClenvraKit

@Suite("InstallSource")
struct InstallSourceTests {
    private let fixture: AppsFixture
    private let pkgutil = "/usr/sbin/pkgutil"

    init() throws {
        fixture = try AppsFixture()
    }

    @Test("detects a Homebrew cask, a formula, an App Store receipt, an installer package and a direct copy")
    func installSourceDetection() async throws {
        let runner = FakeCommandRunner()

        // A cask: the token Homebrew reports wins, and pkgutil is not even asked.
        let cask = try fixture.app("org.mozilla.firefox", name: "Firefox")
        let caskSource = await InstallSource.detect(app: cask, homebrewToken: "firefox", runner: runner)
        #expect(caskSource == .homebrewCask(token: "firefox"))

        // A formula: the bundle lives in Homebrew's Cellar.
        let formula = try fixture.app(
            "org.gnu.emacs", name: "Emacs", folder: "homebrew/Cellar/emacs-plus@30/30.1")
        let formulaSource = await InstallSource.detect(app: formula, homebrewToken: nil, runner: runner)
        #expect(formulaSource == .homebrewFormula(name: "emacs-plus@30"))

        // The App Store: the bundle carries a receipt.
        let store = try fixture.app("com.example.store", name: "Store App")
        try AppBundleFixture(identifier: "com.example.store", displayName: "Store App", masReceipt: true)
            .create(at: store.id)
        let storeSource = await InstallSource.detect(app: store, homebrewToken: nil, runner: runner)
        #expect(storeSource == .appStore)

        // An installer package: pkgutil names the receipts that placed the bundle.
        let packaged = try fixture.app("com.example.office", name: "Office")
        runner.stub(
            pkgutil, ["--file-info", packaged.id],
            stdout: """
                volume: /
                path: \(packaged.id)

                pkgid: com.example.office.app
                pkg-version: 16.0
                install-time: 1700000000
                uid: 0

                pkgid: com.example.office.licensing
                pkg-version: 1.0
                """)
        let packageSource = await InstallSource.detect(app: packaged, homebrewToken: nil, runner: runner)
        #expect(packageSource == .package(ids: ["com.example.office.app", "com.example.office.licensing"]))

        // A direct copy: pkgutil knows nothing about it (and a failing pkgutil means the same).
        let direct = try fixture.app("com.example.writer", name: "Writer")
        runner.stub(pkgutil, ["--file-info", direct.id], stdout: "volume: /\npath: \(direct.id)\n")
        let directSource = await InstallSource.detect(app: direct, homebrewToken: nil, runner: runner)
        #expect(directSource == .direct)
        let unknown = try fixture.app("com.example.viewer", name: "Viewer")
        let unknownSource = await InstallSource.detect(app: unknown, homebrewToken: nil, runner: runner)
        #expect(unknownSource == .direct)
        let withoutRunner = await InstallSource.detect(app: packaged, homebrewToken: nil, runner: nil)
        #expect(withoutRunner == .direct)

        // Detection is read-only: only pkgutil --file-info was ever run.
        #expect(runner.commands.allSatisfy { $0.executable == pkgutil && $0.arguments.first == "--file-info" })
    }

    @Test("parses pkgutil --file-info output, ignoring blank lines and other keys")
    func parsesFileInfo() {
        let ids = InstallSource.packageIdentifiers(
            fromFileInfo: "volume: /\npath: /Applications/A.app\n\npkgid: a.b\npkgid: a.b\npkgid:   \npkgid: c.d\n")
        #expect(ids == ["a.b", "c.d"])
    }
}
