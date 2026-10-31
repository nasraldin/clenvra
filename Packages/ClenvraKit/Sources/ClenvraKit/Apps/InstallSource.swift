import Foundation

/// How an app was installed, which decides how Uninstall removes it: Homebrew apps through `brew` (so Homebrew's
/// own records go too), everything else by deleting the bundle and what it owns.
///
/// Detection only reads: the cask index, the bundle's location and App Store receipt, and `pkgutil --file-info`.
public enum InstallSource: Sendable, Hashable {
    /// Managed by a Homebrew cask.
    case homebrewCask(token: String)
    /// Built by a Homebrew formula; the bundle lives in Homebrew's Cellar.
    case homebrewFormula(name: String)
    /// Bought from the App Store; the bundle carries a receipt.
    case appStore
    /// Placed by installer packages, with their receipt identifiers.
    case package(ids: [String])
    /// Copied in by hand (a disk image, a zip…).
    case direct

    public static let pkgutilPath = "/usr/sbin/pkgutil"

    /// - Parameters:
    ///   - homebrewToken: the cask Homebrew reports for the bundle, when there is one.
    ///   - runner: runs `pkgutil --file-info`; `nil` skips the package check.
    @concurrent public static func detect(
        app: InstalledApp, homebrewToken: String?, runner: (any CommandRunning)?, pkgutil: String = pkgutilPath
    ) async -> InstallSource {
        if let homebrewToken { return .homebrewCask(token: homebrewToken) }
        if let name = formulaName(bundlePath: app.id) { return .homebrewFormula(name: name) }
        if FileManager.default.fileExists(atPath: app.id + "/Contents/_MASReceipt/receipt") { return .appStore }
        guard let runner else { return .direct }
        let command = Command(executable: pkgutil, arguments: ["--file-info", app.id], timeout: .seconds(30))
        guard let result = try? await runner.run(command), result.terminationReason == .exited,
            result.exitStatus == 0
        else { return .direct }
        let ids = packageIdentifiers(fromFileInfo: result.standardOutput)
        return ids.isEmpty ? .direct : .package(ids: ids)
    }

    /// The formula whose keg holds the bundle: `…/Cellar/<name>/<version>/…`.
    static func formulaName(bundlePath: String) -> String? {
        let parts = bundlePath.split(separator: "/").map(String.init)
        guard let cellar = parts.firstIndex(of: "Cellar"), cellar + 2 < parts.count else { return nil }
        let name = parts[cellar + 1]
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasPrefix("-") else { return nil }
        return name
    }

    /// The `pkgid:` values of `pkgutil --file-info`, once each, in order.
    static func packageIdentifiers(fromFileInfo output: String) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("pkgid:") else { continue }
            let id = line.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }
}
