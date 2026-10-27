# Installed Application Analysis

This analysis covers static, read-only inspection of apps the owner has installed. Raw evidence and Evidence IDs are in `rea-investigation.md`.

## 1. What is installed

| App | Version | Edition | Inspected |
|---|---|---|---|
| CleanMyMac | 5.7.2 | **Mac App Store (sandboxed)** `com.macpaw.CleanMyMac-mas` | Yes |
| CCleaner | 2.11 | Direct download | Yes |
| AppCleaner | 3.7.0 | Direct download (Sparkle) | Yes |
| Pearcleaner, OnyX, DaisyDisk, GrandPerspective, OmniDiskSweeper | none | — | Not installed, so not inspected |
| Related tools present | Stats, Power Monitor, ProcessSpy, Apparency, Suspicious Package, LuLu, BlockBlock | — | Not in scope |

## 2. Comparison of architectures

| Aspect | CleanMyMac (MAS) | CCleaner | AppCleaner |
|---|---|---|---|
| Sandbox | **Yes**: user-selected folders + bookmarks only | No | No |
| Privileged component | None (the MAS build can't install one) | 5 root/system launchd jobs, NSXPC root engine | Optional privileged helper (`appcleanerd`, strings) + Authorization Services prompt |
| Always-running pieces | 2 login items (menu, health monitor) | LaunchAgent with `KeepAlive` that **relaunches the full app**, crash reporter every 4 h, updater daily | SmartDelete login item (optional) |
| Traversal | `fts` | `fts` + `proc_*` process checks | `NSFileManager` + `getmntinfo` |
| Leftover ownership | Container metadata plist, `AssociatedBundleIdentifiers`, receipts, SMAppService login items, system extensions, curated knowledge base | Fixed Library roots list (strings) | Entitlement app-groups, receipts, about 60 Library roots, name matching |
| Deletion | not inspected deeply | Root engine with `moveToTrash:` flag + exclusions hook | Trash (inferred: Finder-style) |
| Bundle size | 216 MB | 122 MB | 7.5 MB |

## 3. Lessons for our design

1. **A sandboxed cleaner is a crippled cleaner.** CleanMyMac's MAS edition must ask you to grant your Home folder and still can't read `/Library/LaunchDaemons` ownership or delete other users' or root items. The non-sandboxed direct build exists for that reason. Our app is direct-distribution, non-sandboxed, with Hardened Runtime (see `technical-architecture.md` §6).
2. **Root daemons are a liability you can see.** CCleaner leaves 7 launchd jobs and runs constantly. The removed CleanMyMac 5 left a broken root daemon plist on this Mac. **We ship no daemon and no privileged helper in v1.**
3. **Precision comes from metadata.** CleanMyMac's uninstaller relies on system-maintained ownership markers rather than filename guesses. We adopt the same signal sources, all of which can be read with public APIs or file formats.
4. **AppCleaner shows a small app can do the core job** (7.5 MB, one window). That is the bar for speed and focus.
5. **Background "monitoring" is optional and costly.** Every inspected product adds login items. Ours has none by default.

## 4. Confidence and limits

- Facts about bundle layout, entitlements, signing, launchd plists and imports are **observed**.
- How strings are used (e.g. container metadata reading) is **inferred** from names. It is consistent with documented macOS behaviour but not traced through code.
- No runtime behaviour, network traffic or deletion behaviour was observed. Nothing was launched.
