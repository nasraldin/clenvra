import AppKit
import ClenvraKit
import CoreServices

/// The Apple menu's Recent Items (Apple's shared file lists) and Finder's Go › Recent Folders (Finder's settings),
/// through public interfaces only.
struct LiveRecentListStore: RecentListStore {
    func names(in list: RecentList) async -> [String] {
        if let type = Self.sharedListType(list) { return (SharedFileLists() as any SharedFileListAccess).names(type) }
        return Self.finderFolders()
    }

    func clear(_ list: RecentList) async -> Bool {
        if let type = Self.sharedListType(list) {
            let lists: any SharedFileListAccess = SharedFileLists()
            lists.removeAll(type)
            return lists.names(type).isEmpty
        }
        return await Self.clearFinderFolders()
    }

    private static func sharedListType(_ list: RecentList) -> String? {
        switch list {
        case .applications: "com.apple.LSSharedFileList.RecentApplications"
        case .documents: "com.apple.LSSharedFileList.RecentDocuments"
        case .servers: "com.apple.LSSharedFileList.RecentServers"
        case .finderFolders: nil
        }
    }

    // MARK: - Finder's Recent Folders

    private static let finder = "com.apple.finder"
    private static let recentFolders = "FXRecentFolders"

    private static func finderFolders() -> [String] {
        CFPreferencesAppSynchronize(finder as CFString)
        let folders = CFPreferencesCopyAppValue(recentFolders as CFString, finder as CFString) as? [[String: Any]] ?? []
        return folders.compactMap { $0["name"] as? String }
    }

    /// Finder keeps the list in memory and writes it back, so it is cleared while Finder is closed: the setting is
    /// removed, Finder is asked to quit, the setting is removed again, and macOS starts Finder again (within
    /// milliseconds). A Finder that started before the second removal may hold the old list, so the round is repeated.
    /// `true` when the Finder now running started after the list was gone. Finder then reopens the windows it had;
    /// their folders count as opened, so they are listed again (Apple's own Clear Menu does not restart Finder).
    @MainActor
    private static func clearFinderFolders() async -> Bool {
        for _ in 0..<3 {
            removeRecentFolders()
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: finder)
            for app in running { kill(app.processIdentifier, SIGTERM) }
            _ = await waitUntil { running.allSatisfy(\.isTerminated) }
            removeRecentFolders()
            let removed = Date.now
            // macOS starts Finder again by itself; start it if it has not.
            if await !waitUntil({ !runningFinders().isEmpty }) {
                let url = URL(filePath: "/System/Library/CoreServices/Finder.app")
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                _ = await waitUntil { !runningFinders().isEmpty }
            }
            if runningFinders().allSatisfy({ (startTime(of: $0.processIdentifier) ?? .distantPast) > removed }) {
                // Let Finder reopen its windows, so the list read next is the one Finder keeps.
                try? await Task.sleep(for: .seconds(3))
                return true
            }
        }
        return false
    }

    private static func removeRecentFolders() {
        CFPreferencesSetAppValue(recentFolders as CFString, nil, finder as CFString)
        CFPreferencesAppSynchronize(finder as CFString)
    }

    /// When the process started, from the kernel (`launchDate` is empty for Finder, which launchd starts).
    private static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    /// Finder windows on screen (counted without reading their contents, so no permission is needed).
    static func openFinderWindows() -> Int {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter {
            $0[kCGWindowOwnerName as String] as? String == "Finder" && $0[kCGWindowLayer as String] as? Int == 0
        }.count
    }

    private static func runningFinders() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: finder).filter { !$0.isTerminated }
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}

/// Apple's shared file lists: the lists the Apple menu's Recent Items shows and its Clear Menu empties. The
/// interface is deprecated but public and still the one the menu uses (checked on macOS 26 and 27); it is reached
/// through a protocol so its deprecation is stated once, here.
nonisolated private protocol SharedFileListAccess {
    func names(_ type: String) -> [String]
    func removeAll(_ type: String)
}

nonisolated private struct SharedFileLists: SharedFileListAccess {
    @available(macOS, deprecated: 10.11)
    func names(_ type: String) -> [String] {
        guard let list = LSSharedFileListCreate(nil, type as CFString, nil)?.takeRetainedValue() else { return [] }
        var seed: UInt32 = 0
        let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        return items.map { LSSharedFileListItemCopyDisplayName($0).takeRetainedValue() as String }
    }

    @available(macOS, deprecated: 10.11)
    func removeAll(_ type: String) {
        guard let list = LSSharedFileListCreate(nil, type as CFString, nil)?.takeRetainedValue() else { return }
        LSSharedFileListRemoveAllItems(list)
    }
}
