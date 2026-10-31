// Prints how many entries each Apple menu Recent Items list has ("applications 3") and how many Finder windows are
// open, for the recent-items end-to-end check in the VM. Reads only.
import CoreGraphics
import CoreServices
import Foundation

let lists = [
    ("applications", "com.apple.LSSharedFileList.RecentApplications"),
    ("documents", "com.apple.LSSharedFileList.RecentDocuments"),
    ("servers", "com.apple.LSSharedFileList.RecentServers"),
]
for (name, type) in lists {
    guard let list = LSSharedFileListCreate(nil, type as CFString, nil)?.takeRetainedValue() else { continue }
    var seed: UInt32 = 0
    let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
    print(name, items.count)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print("finderWindows", windows.filter {
    $0[kCGWindowOwnerName as String] as? String == "Finder" && $0[kCGWindowLayer as String] as? Int == 0
}.count)
