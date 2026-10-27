# REA Investigation Log

Date: 2026-10-27 · Host: macOS 27.2 (26B123), arm64 · Xcode 27.1 (27A9275), SDK 27.0, Swift 6.4

## 1. Setup and connectivity

| Check | Result | Evidence |
|---|---|---|
| REA skill installed in Claude Code | Yes, `~/.claude/skills/reverse-engineer-anything` | Skill loaded this session |
| REA MCP server registered | Yes, `mcp__rea__*` tools listed | Tool catalog |
| Connectivity | **Verified by live calls**: `open_binary`, `inspect_signature`, `inspect_macho`, `search_strings`, `inspect_analysis_view` and `close_binary` all returned Evidence records | Evidence IDs below |
| Deep provider | Hopper Disassembler (`/Users/…/Applications/Hopper Disassembler.app`), selected automatically | `provider.id = "hopper"` in search results |
| `rea doctor` | **Not run on purpose.** The REA skill says not to run diagnostics or setup when the tools are already working. No setup or configuration change was needed. | REA skill, "Connect only when needed" |

No restart and no install were required. Nothing was written to the REA or Claude Code configuration.

## 2. Scope and rules followed

- Static, read-only inspection of apps already installed by the owner. No target was launched, patched, or modified. No licensing or security controls were touched, and no secrets were extracted.
- REA string and import results show **what a binary contains**, not what it does at runtime. Where a conclusion depends on runtime behaviour, it is labelled *inferred*.
- Open-source repositories were analysed with ordinary source tools. The REA skill says to use normal repository tools for complete source trees. See `open-source-findings.md`.

## 3. Sessions and Evidence

### 3.1 AppCleaner 3.7.0 (`net.freemacsoft.AppCleaner`)

Target: `/Applications/AppCleaner.app/Contents/MacOS/AppCleaner`, sha256 `68e13754…058a`, arm64 slice.

| Finding | Confidence | Evidence ID |
|---|---|---|
| Developer ID, Team `X85ZX835W9`, Hardened Runtime. The only entitlement is `com.apple.security.automation.apple-events`. **Not sandboxed.** | observed | `ev_1201d2a0…3d85d` |
| Imports `AuthorizationCreate/CopyRights` (admin prompt), `SecStaticCodeCreateWithPath` + `kSecCodeInfoEntitlementsDict` (reads other apps' entitlements), `csr_get_active_config` (SIP state), `DADiskUnmount`, `LSSharedFileList*` login items (legacy API), `SMAppService`, `dispatch_source_type_vnode` (watching folders), `chflags`, `getxattr/removexattr`, `NSTask`, `QLPreviewPanel` | observed | `ev_a46668d0…576cb` (Mach-O), page `ev_ba0849c8…4a2` |
| Strings include `com.apple.security.application-groups` and `Group Containers`. This is consistent with resolving **Team-ID-prefixed group containers from the target app's own entitlements**. | observed (string) / inferred (use) | `ev_a7fffcaa…f565` |
| Searches about 60 `Library/<sub>` roots, both `~` and `/`. Reads `/private/var/db/receipts`. Mentions privileged helper `com.freemacsoft.appcleanerd` | observed | `ev_a7fffcaa…f565` |
| String `/Library/Application Support/com.apple.TCC/TCC.db`, typically used as a Full Disk Access probe | observed (string) / inferred (use) | `ev_a7fffcaa…f565` |
| SmartDelete login item (`AppCleaner SmartDelete.app`), likely a vnode watch on Applications folders that offers cleanup when an app is trashed | inferred | bundle layout + vnode import |

### 3.2 CleanMyMac 5.7.2, Mac App Store edition (`com.macpaw.CleanMyMac-mas`)

| Finding | Confidence | Evidence |
|---|---|---|
| **App Sandbox enabled.** File access is `files.user-selected.read-write` + `files.bookmarks.app-scope` only. So it must ask the user to grant folders (e.g. Home) and keeps security-scoped bookmarks. Also photos-library, network client/server, and app groups shared with `CleanMyMac5.CLI` | observed | `codesign -d --entitlements` (main + 2 login items) |
| 2 sandboxed login items: `HealthMonitor` (also has a location entitlement) and `Menu` | observed | bundle layout, entitlements |
| About 130 embedded frameworks, modular per feature: `SpaceLensScanning`, `UninstallerScanning`, `SystemJunkScanning`, `MalwareScanning` (Moonlock engine), `CloudStorageScanning`, `PrivacyScanning`, `UnusedDiskImagesScanning`, `AIToolScanning`, `LocalModelScanning`… | observed | `Contents/Frameworks` listing |
| Traversal uses BSD `fts_open/fts_read` (Uninstaller, SystemJunk, FileManagerService). SpaceLens uses `lstat`. Metadata comes from Spotlight `MDItemCreate/MDItemCopyAttribute` | observed | `nm -u` per framework (read-only) |
| `ApplicationsService` imports `LSCopyApplicationURLsForBundleIdentifier` and `SecStaticCodeCheckValidity(WithErrors)`, i.e. it finds apps by bundle ID and checks bundle integrity | observed | `nm -u` |
| **Leftover ownership is metadata-based, not name-based.** Strings: `.com.apple.containermanagerd.metadata.plist` (sandbox container owner), `AssociatedBundleIdentifiers` (launchd plist owner), `isPlistHasAssociatedBundleIdentifier:forBundleID:`, `_findReceiptResourcesForPackage:`, `isInSMLoginItems`, `systemExtensionWithBundleIdentifier:`, `leftoversKnowledgeBase`, `buildForLaunchAgentsWithKnowledgeBase:isFDAGranted:…`, `ApplicationContainerAccessProbe`, audio plug-in roots (incl. Avid), `_readSteamIdentifier` | observed (strings) / inferred (algorithm) | `ev_76d4159d…2689` (UninstallerScanning, sha256 `c6f26708…dec0`) |

### 3.3 CCleaner for Mac 2.11 (`com.piriform.ccleaner`)

| Finding | Confidence | Evidence |
|---|---|---|
| Not sandboxed (no entitlements). Developer ID Team `8M34BTQQ45`, Hardened Runtime | observed | `codesign` |
| Installs **5 system launchd jobs** in `/Library/LaunchDaemons` (`engine.xpc`, `services.xpc`, `services.submit` every 4 h, `uninstall`, `update.xpc` as root) and **2 LaunchAgents**. One of them keeps the full CCleaner app running in every login session (`KeepAlive: true`). Both CCleaner processes were running at inspection time | observed | plist dumps, `pgrep` |
| Root engine `com.piriform.ccleaner.engine.xpc` is an `NSXPCListener` with `listener:shouldAcceptNewConnection:` and a code-signing requirement string pinned to Developer ID + Team OU. API `deleteWithPath:moveToTrash:excludes:resultCallback:` uses `trashItemAtURL` / `removeItemAtURL` with a `fileManager:shouldRemoveItemAtPath:` exclusion hook | observed (strings); peer-check **enforcement not verified** | `ev_822d0aeb…41f` (sha256 `8b2bbd62…f111`) |
| CleaningEngine framework uses `fts_*`, `proc_pidinfo/proc_pidpath/proc_listchildpids/proc_pid_rusage` (process checks before cleaning) | observed | `nm -u` |
| Plug-in modules: AppUninstaller, BrowserCleaner, Dashboard, DiskAnalyzer, DuplicateFinder, Photos, QuickCleaner, StartupManager, SystemMonitor, MenuBar | observed | `Contents/PlugIns` |

### 3.4 Side finding on this Mac: orphaned launchd entries

| Item | State | Why it matters |
|---|---|---|
| `/Library/LaunchDaemons/com.macpaw.CleanMyMac5.Agent.plist` | Points to `/Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent`, **which no longer exists** | Leftover root daemon from the removed direct-download CleanMyMac 5 |
| `~/Library/LaunchAgents/com.macpaw.CleanMyMac5.Updater.plist` | `RunAtLoad`, runs every 6 h. Points to an updater in `~/Library/Application Support/CleanMyMac_5/` (still present) | Background updater for an app that is no longer installed |

This is concrete evidence that a **Startup & Background** view, with ownership and "target missing" detection, is useful on this machine.

## 4. Limitations

- Strings and imports show capability, not behaviour. No function-level decompilation was needed for the design decisions, so no pseudocode is cited.
- The CleanMyMac framework import survey used `nm -u` (read-only Xcode tool) for breadth. REA was used for the deep string evidence on `UninstallerScanning`.
- Pearcleaner, OnyX, DaisyDisk, GrandPerspective and OmniDiskSweeper are **not installed**, so they were not inspected with REA. See `competitor-analysis.md` for their evidence level.
- All REA sessions were closed (`close_binary`) after use.
