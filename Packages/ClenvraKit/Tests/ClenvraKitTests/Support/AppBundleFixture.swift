import Foundation

/// Builds fake `.app` bundles on disk for tests. Only ever writes under the directory it is given.
struct AppBundleFixture {
    /// Bundle identifier written to Info.plist; `nil` omits the key.
    var identifier: String? = "com.example.app"
    var displayName: String?
    var bundleName: String?
    var version: String? = "1.0"
    var build: String? = "100"
    var masReceipt = false
    var plugIns: [String: String] = [:]  // file name (without .appex) → bundle id
    var loginItems: [String: String] = [:]  // file name (without .app) → bundle id
    var xpcServices: [String: String] = [:]  // file name (without .xpc) → bundle id
    var launchServicesHelpers: [String] = []  // plain helper executables named by their id
    var writeInfoPlist = true

    /// Creates the bundle at `path` (absolute; parents are created) and returns its URL.
    @discardableResult
    func create(at path: String) throws -> URL {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let contents = url.appending(path: "Contents")
        try makeDirectory(contents.appending(path: "MacOS"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appending(path: "MacOS/exe"))

        if writeInfoPlist {
            var plist: [String: String] = ["CFBundleExecutable": "exe", "CFBundlePackageType": "APPL"]
            plist["CFBundleIdentifier"] = identifier
            plist["CFBundleDisplayName"] = displayName
            plist["CFBundleName"] = bundleName
            plist["CFBundleShortVersionString"] = version
            plist["CFBundleVersion"] = build
            try Self.writePlist(plist, to: contents.appending(path: "Info.plist"))
        }
        if masReceipt {
            try makeDirectory(contents.appending(path: "_MASReceipt"))
            try Data([0x30, 0x80]).write(to: contents.appending(path: "_MASReceipt/receipt"))
        }
        for (name, id) in plugIns {
            try Self.makeNestedBundle(contents.appending(path: "PlugIns/\(name).appex"), identifier: id)
        }
        for (name, id) in loginItems {
            try Self.makeNestedBundle(contents.appending(path: "Library/LoginItems/\(name).app"), identifier: id)
        }
        for (name, id) in xpcServices {
            try Self.makeNestedBundle(contents.appending(path: "XPCServices/\(name).xpc"), identifier: id)
        }
        if !launchServicesHelpers.isEmpty {
            let folder = contents.appending(path: "Library/LaunchServices")
            try makeDirectory(folder)
            for helper in launchServicesHelpers {
                try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: folder.appending(path: helper))
            }
        }
        return url
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func makeNestedBundle(_ url: URL, identifier: String) throws {
        try FileManager.default.createDirectory(
            at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        try writePlist(["CFBundleIdentifier": identifier], to: url.appending(path: "Contents/Info.plist"))
    }

    private static func writePlist(_ plist: [String: String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }
}
