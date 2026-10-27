import Foundation

/// Maps installed apps to the Homebrew casks that manage them, so they can be removed with `brew` (AP-4).
///
/// Modern casks copy the app into `/Applications`, so the bundle path alone does not reveal Homebrew; the cask's
/// `app` artifacts name the bundles it installed.
public enum HomebrewCasks {
    /// Lower-cased app file name (`firefox.app`) → cask token, from installed casks; ambiguous names are dropped.
    public static func installedAppTokens(brew: String, runner: any CommandRunning) async -> [String: String] {
        let command = Command(
            executable: brew, arguments: ["info", "--json=v2", "--installed", "--cask"], timeout: .seconds(60))
        guard let result = try? await runner.run(command), result.terminationReason == .exited,
            result.exitStatus == 0
        else { return [:] }
        return appTokens(fromInfoJSON: Data(result.standardOutput.utf8))
    }

    /// The command shown to the user and run as-is; `brew` removes the app permanently (no Trash).
    public static func uninstallCommand(brew: String, token: String) -> Command {
        Command(executable: brew, arguments: ["uninstall", "--cask", token], timeout: .seconds(600))
    }

    /// Parses `brew info --json=v2` output. An `app` artifact is a list of source names, optionally followed by
    /// `{"target": "…"}`, which renames the preceding source.
    static func appTokens(fromInfoJSON data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let casks = root["casks"] as? [[String: Any]]
        else { return [:] }
        var tokens: [String: String] = [:]
        var ambiguous: Set<String> = []
        for cask in casks {
            guard let token = cask["token"] as? String, let artifacts = cask["artifacts"] as? [Any] else { continue }
            for case let artifact as [String: Any] in artifacts {
                guard let parts = artifact["app"] as? [Any] else { continue }
                var names: [String] = []
                for part in parts {
                    if let source = part as? String {
                        names.append((source as NSString).lastPathComponent)
                    } else if let options = part as? [String: Any], let target = options["target"] as? String,
                        !names.isEmpty
                    {
                        names[names.count - 1] = (target as NSString).lastPathComponent
                    }
                }
                for name in names.map({ $0.lowercased() }) {
                    if let existing = tokens[name], existing != token { ambiguous.insert(name) }
                    tokens[name] = token
                }
            }
        }
        for name in ambiguous { tokens[name] = nil }
        return tokens
    }
}
