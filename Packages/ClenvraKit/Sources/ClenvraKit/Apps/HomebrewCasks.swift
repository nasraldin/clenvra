import Foundation

/// Which installed cask manages an app bundle, located where Homebrew actually put it, so a cask installed with a
/// custom `--appdir` (for example `~/Applications`) is found and a same-named copy elsewhere is not claimed (AP-4).
public struct HomebrewCaskIndex: Sendable, Equatable {
    /// Lower-cased install path → token, for casks whose install location is known.
    var tokensByPath: [String: String] = [:]
    /// Lower-cased app file name → token, only for casks whose location is unknown (older Homebrew, no config).
    var tokensByName: [String: String] = [:]

    public init() {}

    /// The cask token for the bundle at `path`; matched by exact location when known, otherwise by file name.
    public func token(forAppAt path: String) -> String? {
        let key = Self.key(path)
        if let token = tokensByPath[key] { return token }
        return tokensByName[(key as NSString).lastPathComponent]
    }

    static func key(_ path: String) -> String {
        var result = path.lowercased()
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// Maps installed apps to the Homebrew casks that manage them, so they can be removed with `brew` (AP-4).
///
/// Modern casks copy the app into the cask's `appdir`, so the bundle path alone does not reveal Homebrew. The
/// install location comes from, in order: the resolved `target` that current `brew info --json=v2` reports per
/// artifact; the `appdir` recorded in the cask's `Caskroom/<token>/.metadata/config.json`; or, when neither is
/// available, the app file name alone.
public enum HomebrewCasks {
    /// The installed casks; an empty index when `brew` fails.
    /// - Parameter caskroom: Homebrew's Caskroom; defaults to the one next to `brew`'s `bin` folder.
    @concurrent public static func installedCasks(
        brew: String, runner: any CommandRunning, caskroom: String? = nil
    ) async -> HomebrewCaskIndex {
        let command = Command(
            executable: brew, arguments: ["info", "--json=v2", "--installed", "--cask"], timeout: .seconds(60))
        guard let result = try? await runner.run(command), result.terminationReason == .exited,
            result.exitStatus == 0
        else { return HomebrewCaskIndex() }
        let caskroom = caskroom ?? defaultCaskroom(brew: brew)
        return index(fromInfoJSON: Data(result.standardOutput.utf8)) { token in
            recordedAppdir(token: token, caskroom: caskroom)
        }
    }

    /// The command shown to the user and run as-is; `brew` removes the app permanently (no Trash).
    public static func uninstallCommand(brew: String, token: String) -> Command {
        Command(executable: brew, arguments: ["uninstall", "--cask", token], timeout: .seconds(600))
    }

    /// `<prefix>/Caskroom` for `<prefix>/bin/brew`, Homebrew's standard layout.
    static func defaultCaskroom(brew: String) -> String {
        let prefix = ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return (prefix as NSString).appendingPathComponent("Caskroom")
    }

    /// Parses `brew info --json=v2` output. An `app` artifact is a source name, optionally followed by
    /// `{"target": "…"}` which renames it (relative to the appdir, or absolute); current Homebrew also adds the
    /// resolved absolute install path as the artifact's own `"target"`. Paths or names claimed by two casks are
    /// dropped, since removing the wrong app is worse than not offering `brew`.
    /// - Parameter appdir: the cask's recorded appdir, consulted only when no resolved target is reported.
    static func index(fromInfoJSON data: Data, appdir: (String) -> String?) -> HomebrewCaskIndex {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let casks = root["casks"] as? [[String: Any]]
        else { return HomebrewCaskIndex() }
        var byPath = Claims()
        var byName = Claims()
        var allNames = Claims()
        for cask in casks {
            guard let token = cask["token"] as? String, let artifacts = cask["artifacts"] as? [Any] else { continue }
            var recorded: String??
            for case let artifact as [String: Any] in artifacts {
                guard let parts = artifact["app"] as? [Any], let installed = installedName(parts) else { continue }
                let name = HomebrewCaskIndex.key((installed as NSString).lastPathComponent)
                allNames.claim(name, by: token)
                if let target = artifact["target"] as? String, target.hasPrefix("/") {
                    byPath.claim(HomebrewCaskIndex.key(target), by: token)
                } else if installed.hasPrefix("/") {
                    byPath.claim(HomebrewCaskIndex.key(installed), by: token)
                } else {
                    if recorded == nil { recorded = appdir(token) }
                    if case let directory?? = recorded, directory.hasPrefix("/") {
                        byPath.claim(
                            HomebrewCaskIndex.key((directory as NSString).appendingPathComponent(installed)), by: token)
                    } else {
                        byName.claim(name, by: token)
                    }
                }
            }
        }
        var index = HomebrewCaskIndex()
        index.tokensByPath = byPath.unambiguous
        index.tokensByName = byName.unambiguous.filter { !allNames.ambiguous.contains($0.key) }
        return index
    }

    /// The effective `appdir` in a cask's `config.json`: explicit options win over `HOMEBREW_CASK_OPTS` (`env`),
    /// which win over the default. Only absolute paths are accepted.
    static func appdir(fromConfigJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for scope in ["explicit", "env", "default"] {
            guard let options = root[scope] as? [String: Any], let value = options["appdir"] else { continue }
            guard let directory = value as? String, directory.hasPrefix("/") else { return nil }
            return directory
        }
        return nil
    }

    /// The installed name of an `app` artifact: its single source, renamed by an inline `target` when present.
    private static func installedName(_ parts: [Any]) -> String? {
        guard parts.count == 1 || parts.count == 2, let source = parts[0] as? String, !source.isEmpty else {
            return nil
        }
        if parts.count == 2, let options = parts[1] as? [String: Any], let target = options["target"] as? String,
            !target.isEmpty
        {
            return target
        }
        return (source as NSString).lastPathComponent
    }

    /// Reads the cask's recorded appdir; tokens that could escape the Caskroom are never used as paths.
    private static func recordedAppdir(token: String, caskroom: String) -> String? {
        guard !token.isEmpty, !token.contains("/"), !token.hasPrefix(".") else { return nil }
        let path = (caskroom as NSString).appendingPathComponent(token + "/.metadata/config.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return appdir(fromConfigJSON: data)
    }

    /// Keys claimed by tokens; a key claimed by two different tokens is ambiguous.
    private struct Claims {
        private(set) var tokens: [String: String] = [:]
        private(set) var ambiguous: Set<String> = []

        mutating func claim(_ key: String, by token: String) {
            if let existing = tokens[key], existing != token { ambiguous.insert(key) }
            tokens[key] = token
        }

        var unambiguous: [String: String] { tokens.filter { !ambiguous.contains($0.key) } }
    }
}
