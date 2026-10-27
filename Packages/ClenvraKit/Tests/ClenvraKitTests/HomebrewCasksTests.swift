import Foundation
import Testing

@testable import ClenvraKit

@Suite("HomebrewCasks")
struct HomebrewCasksTests {
    private let scratch: TemporaryDirectory
    private let fixture: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        fixture = FixtureBuilder(root: scratch.url)
    }

    private var caskroom: String { fixture.url("Caskroom").path(percentEncoded: false) }

    private func index(_ json: String, appdirs: [String: String] = [:]) -> HomebrewCaskIndex {
        HomebrewCasks.index(fromInfoJSON: Data(json.utf8), appdir: { appdirs[$0] })
    }

    private func writeConfig(token: String, _ json: String) throws {
        try fixture.directory("Caskroom/\(token)/.metadata")
        try Data(json.utf8).write(to: fixture.url("Caskroom/\(token)/.metadata/config.json"))
    }

    @Test("the resolved target Homebrew reports is matched by full path, so a custom --appdir is found")
    func resolvedTargets() {
        let index = index(
            """
            {"casks": [
              {"token": "firefox", "artifacts": [{"app": ["Firefox.app"], "target": "/Users/u/Applications/Firefox.app"}]},
              {"token": "renamed", "artifacts": [
                {"app": ["Src.app", {"target": "Other.app"}], "target": "/Applications/Other.app"}]}
            ]}
            """)

        #expect(index.token(forAppAt: "/Users/u/Applications/Firefox.app") == "firefox")
        #expect(index.token(forAppAt: "/users/u/applications/firefox.app/") == "firefox")
        #expect(index.token(forAppAt: "/Applications/Firefox.app") == nil)
        #expect(index.token(forAppAt: "/Applications/Other.app") == "renamed")
        #expect(index.token(forAppAt: "/Users/u/Applications/Other.app") == nil)
    }

    @Test("without a reported target, the cask's recorded appdir locates the app")
    func appdirFallback() {
        let index = index(
            """
            {"casks": [
              {"token": "a", "artifacts": [{"app": ["Sub/A.app"]}]},
              {"token": "b", "artifacts": [{"app": ["Src.app", {"target": "B.app"}]}]},
              {"token": "c", "artifacts": [{"app": ["Src.app", {"target": "/Opt/Apps/C.app"}]}]}
            ]}
            """,
            appdirs: ["a": "/Users/u/Applications", "b": "/Applications/", "c": "/Applications"])

        #expect(index.token(forAppAt: "/Users/u/Applications/A.app") == "a")
        #expect(index.token(forAppAt: "/Applications/A.app") == nil)
        #expect(index.token(forAppAt: "/Applications/B.app") == "b")
        #expect(index.token(forAppAt: "/Opt/Apps/C.app") == "c")
    }

    @Test("with no location at all, apps are matched by name as before, and shared names are dropped")
    func nameFallback() {
        let index = index(
            """
            {"casks": [
              {"token": "a", "artifacts": [{"app": ["A.app"]}, {"app": ["Shared.app"]}]},
              {"token": "b", "artifacts": [{"app": ["Shared.app"]}, {"app": ["Src.app", {"target": "Target.app"}]}]},
              {"token": "c", "artifacts": [{"uninstall": [{"quit": "x"}]}]},
              {"token": "d", "artifacts": [{"app": ["Shared.app"], "target": "/Users/u/Applications/Shared.app"}]}
            ]}
            """)

        #expect(index.token(forAppAt: "/Applications/A.app") == "a")
        #expect(index.token(forAppAt: "/Users/u/Applications/A.app") == "a")
        #expect(index.token(forAppAt: "/Applications/Target.app") == "b")
        #expect(index.token(forAppAt: "/Applications/Shared.app") == nil)
        #expect(index.token(forAppAt: "/Users/u/Applications/Shared.app") == "d")
    }

    @Test("a path claimed by two casks is ambiguous and dropped")
    func ambiguousPath() {
        let index = index(
            """
            {"casks": [
              {"token": "a", "artifacts": [{"app": ["X.app"], "target": "/Applications/X.app"}]},
              {"token": "b", "artifacts": [{"app": ["X.app"], "target": "/Applications/X.app"}]}
            ]}
            """)

        #expect(index.token(forAppAt: "/Applications/X.app") == nil)
    }

    @Test(
        "malformed output is ignored rather than guessed at",
        arguments: [
            "", "[]", "{\"casks\": 3}",
            "{\"casks\": [{\"artifacts\": [{\"app\": [\"A.app\"]}]}]}",
            "{\"casks\": [{\"token\": \"a\", \"artifacts\": [{\"app\": \"A.app\"}]}]}",
            "{\"casks\": [{\"token\": \"a\", \"artifacts\": [{\"app\": [7, {\"target\": 3}]}]}]}",
        ])
    func malformed(json: String) {
        #expect(index(json) == HomebrewCaskIndex())
    }

    @Test("a relative reported target is not trusted as a location")
    func relativeTargetIgnored() {
        let index = index(#"{"casks": [{"token": "a", "artifacts": [{"app": ["A.app"], "target": "A.app"}]}]}"#)

        #expect(index.token(forAppAt: "/Applications/A.app") == "a")
    }

    @Test("the recorded appdir prefers explicit options, then HOMEBREW_CASK_OPTS, then the default")
    func configPrecedence() {
        func appdir(_ json: String) -> String? { HomebrewCasks.appdir(fromConfigJSON: Data(json.utf8)) }

        #expect(
            appdir(
                #"{"default": {"appdir": "/Applications"}, "env": {"appdir": "/E"}, "explicit": {"appdir": "/X"}}"#)
                == "/X")
        #expect(appdir(#"{"default": {"appdir": "/Applications"}, "env": {"appdir": "/E"}, "explicit": {}}"#) == "/E")
        #expect(appdir(#"{"default": {"appdir": "/Applications"}, "env": {}, "explicit": {}}"#) == "/Applications")
        #expect(appdir(#"{"default": {"appdir": "~/Applications"}}"#) == nil)
        #expect(appdir(#"{"default": {"appdir": 3}}"#) == nil)
        #expect(appdir("not json") == nil)
    }

    @Test("installed casks are read from brew info, falling back to each cask's Caskroom config")
    func installedCasks() async throws {
        try writeConfig(token: "old", #"{"default": {"appdir": "/Applications"}, "explicit": {"appdir": "/Custom"}}"#)
        let brew = "/opt/homebrew/bin/brew"
        let runner = FakeCommandRunner()
        runner.stub(
            brew, ["info", "--json=v2", "--installed", "--cask"],
            stdout: """
                {"formulae": [], "casks": [
                  {"token": "old", "artifacts": [{"app": ["Old.app"]}]},
                  {"token": "../escape", "artifacts": [{"app": ["Esc.app"]}]}
                ]}
                """)

        let index = await HomebrewCasks.installedCasks(brew: brew, runner: runner, caskroom: caskroom)

        #expect(index.token(forAppAt: "/Custom/Old.app") == "old")
        #expect(index.token(forAppAt: "/Applications/Old.app") == nil)
        #expect(index.token(forAppAt: "/Applications/Esc.app") == "../escape")
    }

    @Test("a failing brew yields no casks")
    func brewFails() async {
        let runner = FakeCommandRunner()
        runner.stub("/b/brew", ["info", "--json=v2", "--installed", "--cask"], status: 1)

        #expect(
            await HomebrewCasks.installedCasks(brew: "/b/brew", runner: runner, caskroom: caskroom)
                == HomebrewCaskIndex())
    }

    @Test("the default Caskroom sits next to brew's bin folder")
    func defaultCaskroom() {
        #expect(HomebrewCasks.defaultCaskroom(brew: "/opt/homebrew/bin/brew") == "/opt/homebrew/Caskroom")
        #expect(HomebrewCasks.defaultCaskroom(brew: "/usr/local/bin/brew") == "/usr/local/Caskroom")
    }
}
