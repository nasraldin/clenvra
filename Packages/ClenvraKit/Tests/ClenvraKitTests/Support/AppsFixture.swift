import Darwin
import Foundation

@testable import ClenvraKit

/// A fake home folder with app bundles and Library data, for ownership and uninstall tests.
/// Everything lives inside one `TemporaryDirectory`.
struct AppsFixture {
    let scratch: TemporaryDirectory
    let builder: FixtureBuilder

    init() throws {
        scratch = try TemporaryDirectory()
        builder = FixtureBuilder(root: scratch.url)
        try builder.directory(".Trash")
        try builder.directory("Library")
    }

    /// Canonical scratch root without a trailing slash; used as the fake home folder.
    var home: String { String(scratch.url.path(percentEncoded: false).dropLast()) }

    func path(_ relative: String) -> String { home + "/" + relative }

    func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path(relative), &info) == 0
    }

    /// Creates `Applications/<file>.app` and returns it as an inventory entry.
    func app(
        _ identifier: String?, name: String, file: String? = nil, folder: String = "Applications",
        plugIns: [String: String] = [:], groups: [String]? = [], source: InstalledApp.Source = .other,
        isProtected: Bool = false
    ) throws -> InstalledApp {
        let bundle = path("\(folder)/\(file ?? name).app")
        try AppBundleFixture(identifier: identifier, displayName: name, plugIns: plugIns).create(at: bundle)
        try builder.file("\(folder)/\(file ?? name).app/Contents/MacOS/payload", bytes: 40_000)
        return InstalledApp(
            id: bundle, url: URL(filePath: bundle, directoryHint: .isDirectory), bundleIdentifier: identifier,
            name: name, version: "1.0", build: "1", source: source, isProtected: isProtected,
            embeddedBundleIdentifiers: plugIns.values.sorted(), applicationGroups: groups)
    }

    /// An inventory entry without a bundle on disk (another installed app that only matters for sharing checks).
    func otherApp(_ identifier: String?, name: String, embedded: [String] = [], groups: [String]? = [])
        -> InstalledApp
    {
        let bundle = path("Elsewhere/\(name).app")
        return InstalledApp(
            id: bundle, url: URL(filePath: bundle, directoryHint: .isDirectory), bundleIdentifier: identifier,
            name: name, version: nil, build: nil, source: .other, isProtected: false,
            embeddedBundleIdentifiers: embedded, applicationGroups: groups)
    }

    func file(_ relative: String, bytes: Int = 2_000) throws {
        try builder.file(relative, bytes: bytes)
    }

    func plist(_ relative: String, _ contents: [String: Any]) throws {
        let url = builder.url(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: url)
    }

    /// A sandbox container whose folder name is `folder` and whose metadata names `identifier`.
    func container(_ folder: String, identifier: String) throws {
        try file("Library/Containers/\(folder)/Data/Library/Caches/blob")
        try plist(
            "Library/Containers/\(folder)/.com.apple.containermanagerd.metadata.plist",
            ["MCMMetadataIdentifier": identifier])
    }

    func age(_ relative: String, days: Double, now: Date) throws {
        let date = now.addingTimeInterval(-days * 86_400)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path(relative), isDirectory: &isDirectory)
        if isDirectory.boolValue, let enumerator = FileManager.default.enumerator(atPath: path(relative)) {
            for case let child as String in enumerator {
                try builder.setModificationDate(relative + "/" + child, date)
            }
        }
        try builder.setModificationDate(relative, date)
    }

    /// Launch items from the fixture's own folders only (never the real `/Library`).
    var launchItems: @Sendable ([InstalledApp]) -> [LaunchItem] {
        let home = home
        return { apps in
            LaunchItemReader(
                userAgents: home + "/Library/LaunchAgents", systemAgents: home + "/System/LaunchAgents",
                systemDaemons: home + "/System/LaunchDaemons", status: { _ in .unknown }
            ).read(installedApps: apps)
        }
    }

    func resolver(
        policy: ProtectionPolicy? = nil, receipts: OwnershipResolver.ReceiptLookup? = nil
    ) -> OwnershipResolver {
        OwnershipResolver(
            home: home, policy: policy ?? ProtectionPolicy(home: home), launchItems: launchItems,
            receipts: receipts)
    }
}
