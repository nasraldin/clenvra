# Open-Source Repository Findings

This is the source-level analysis of the supplied repositories. It also serves as `repository-analysis.md`; the two were merged to avoid duplication.

Both repositories were treated as untrusted. No scripts, installers or tests from them were run.

| | MacSai | Mole |
|---|---|---|
| Path | `oss-app/MacSai` | `oss-app/Mole` |
| Purpose | GUI "CleanMyMac alternative": cleanup, uninstall, malware, optimisation, menu bar | CLI cleaner, uninstaller, disk analyser (TUI), status monitor |
| License | **BSD-3-Clause**. Reuse is allowed with attribution | **GPL-3.0**. **No code reuse** into a non-GPL app; ideas only |
| Stack | Swift 6 package (`Package.swift`, macOS 14), SwiftUI, GRDB | Bash (~55k lines in `bin/` and `lib/`) + Go (~29k lines, `cmd/analyze`, `cmd/status`) |
| Activity | v1.26.0, 248 commits, last 2026-10-21, 39 commits in the last 30 days | 3,849 commits, last 2026-10-27, 593 commits in the last 30 days |
| Tests | 1,133 `@Test`/`func test` declarations in `Tests/` (README claims 1,048) | 74 `.bats` suites + 33 Go `_test.go` files, incl. a delete fuzz test |

---

## 1. MacSai

### 1.1 Architecture

- `Sources/MacCleanKit`: pure, testable logic (safety, matching, duplicate decisions, categories as data).
- `Sources/MacClean`: the app (modules, views, scanner, cleaning engine).
- `Sources/MacCleanMenu`: a separate menu-bar executable.

The split between pure logic and a system-touching layer is a good pattern; we adopt the idea.

Modules implement `ScanModule.scan() async -> [ScanResult]` (`MacClean/Core/Scanner/ScanCoordinator.swift:4-10`). `ScanCoordinator` runs modules **sequentially** on the main actor and filters results through `CleanFilter.isActionable` (`ScanCoordinator.swift:85-125`).

### 1.2 Traced workflows

| Workflow | Code path | Observations |
|---|---|---|
| Deletion | `CleaningEngine.clean` → `processChunk` → `SafetyGuard.validatePath` → `FileManager.trashItem` / `removeItem` (`MacClean/Core/Cleaner/CleaningEngine.swift:93-284`) | Good: trash-first, dry-run mode, chunks of 5k, 500k total cap, per-item revalidation after a failed batch, benign ENOENT handling, operations log. **Gaps:** no file-identity check (inode/dev/mtime) between scan and delete; a directory's size is computed by a synchronous recursive walk *during* deletion (`:227-229`, `:289-307`); `ISO8601DateFormatter` is created per log line (`:350`). |
| Path safety | `MacCleanKit/SafetyGuard.swift:68-117` | Prefix blocklist (`/System`, `/usr`, `/bin`, `/sbin`, `/Library/Apple`, `/private/var/db`, from `Constants.swift:56-63`), firmlink canonicalisation, user exclusions. **Weakness:** the symlink check only rejects when the first 3 path components change (`:110-116`). A symlinked ancestor that redirects inside the same home folder (e.g. `~/Library/Caches/x → ~/Documents`) passes, so `~/Library/Caches/x/file` resolves into `~/Documents`. The paths are string-based, so case variants (`/SYSTEM`) are not compared by identity. |
| Cleanability filter | `MacCleanKit/CleanFilter.swift:27-54` | Uses `access(parent, W_OK)` to hide items the process can't delete (root-owned, `UF_DATAVAULT`). This is a useful idea that avoids noisy "N errors" screens. |
| Scanning | `MacClean/Core/Scanner/FileTreeScanner.swift` | `FileManager.enumerator` + `URLResourceValues`. **Bug:** `scan(root:)` runs the whole enumeration *inside the `AsyncStream` build closure* (`:18-40`). That closure runs synchronously, so nothing streams and the caller blocks until done. Sizes use `totalFileAllocatedSize` (`:88`), which double-counts hard links and over-reports APFS clones. `topLevelSizes` (`:121-183`) is the memory-bounded variant (issue #184). |
| App discovery | `AppDiscovery.discoverApps` (`MacClean/Modules/Uninstaller/UninstallerModule.swift:29-123`) | Scans `/Applications` and `~/Applications` (depth 4) and reads `Info.plist`. Misses `/System/Applications` (only relevant for protection), Setapp and Homebrew Caskroom. "Last opened" uses `contentAccessDate`, which is unreliable; Spotlight `kMDItemLastUsedDate` is the better signal. |
| Associated files | `MacCleanKit/AppMatching.swift:52-163` + `AppPathFinder.findAssociatedFiles` (`UninstallerModule.swift:138-175`) | Patterns at 7 levels (bundle ID, names, normalised, last two ID components…), whole-word matching against **top-level entries** of 17 `~/Library` subfolders and system Launch* plists. Company-name matching is disabled by default after a false positive (issue #98). **Gaps:** no container metadata check, no `AssociatedBundleIdentifiers`, no receipts, no "shared with another installed app" check, no Team-ID group containers. |
| Orphans | `MacCleanKit/OrphanedAppFiles.swift:40-95` | Conservative: bundle-ID-shaped names only, never `com.apple.`/Chromium/Electron/Qt, dotted-lineage check against installed IDs. A good model. |
| Duplicates | `MacCleanKit/DuplicateDetection.swift` + `MacClean/Modules/Duplicates/DuplicatesModule.swift` | Size → first-4 KB SHA-256 → full SHA-256 → hard-link dedupe by (dev, inode). Always keeps one copy (`extractDeletableDuplicates`). **Gaps:** one task per file in an unbounded `TaskGroup`, with blocking `FileHandle` I/O on the cooperative pool; files over 500 MB are skipped; no APFS-clone awareness (two clones show as "duplicates" that free nothing); no byte-for-byte confirmation. |
| Browser lock | `MacCleanKit/BrowserProfileLock.swift` | Chromium `SingletonLock` via `lstat`, Firefox `.parentlock` via `fcntl(F_GETLK)`. **Reusable idea (BSD)**, and simple. |
| Privileged actions | `MacClean/Modules/Maintenance/PrivilegedShellRunner.swift:33-59` | `NSAppleScript` "do shell script … with administrator privileges". It works, but every elevated action is a shell string. We avoid this. |
| Docker | `MaintenanceTask.swift:136,196-205` | Runs `docker system prune` (irreversible) and never touches `Docker.raw` or volumes. Using the tool's own command is the right approach. |
| Bundle thinning / languages | `Cleaner/ThinAppBundleOperation.swift`, `LanguageScanner.swift` | Removes architectures with `lipo` (verifies the signature and rolls back if it breaks) and removes `.lproj` folders. **Rejected for our app:** it modifies third-party signed bundles, interferes with delta updates, and saves little on Apple Silicon. |
| Localization | `MacCleanKit/Localization.swift` (2,755 lines) | Inline `L10n.tr(zh, en, ru)` tuples. **Anti-pattern:** no String Catalog, no plural rules, and adding Arabic would mean editing every call site. |

### 1.3 Reuse assessment (BSD-3)

We could reuse code with attribution. In practice we **re-implement independently**, because the important pieces (identity-checked deletion, bulk enumeration, ownership evidence) need a different design. Ideas worth keeping: pure-kit split, `CleanFilter` write probe, browser lock checks, "always keep one copy" rule for duplicates, conservative orphan rules.

---

## 2. Mole (GPL-3: ideas only)

### 2.1 Architecture

- `mole` / `bin/*.sh`: commands (clean, uninstall, optimize, purge, analyze, status).
- `lib/core/file_ops.sh`: the deletion gate.
- `lib/core/app_protection*.sh`: protection data, about 630 lines of rules.
- `lib/uninstall/*`: batch uninstall, Homebrew, receipts, config references.
- `cmd/analyze`: Go TUI disk analyser.

Most cleanup is **permanent** (`rm -rf`), not trash. Its own audit lists this as a known limit (`SECURITY_AUDIT.md`, "Known Limitations" M01/M04).

### 2.2 Ideas worth learning from (no code copied)

| Idea | Where | Takeaway for us |
|---|---|---|
| Ancestor-symlink guard | `lib/core/file_ops.sh:1160-1260` (`validate_path_for_deletion`) | Resolve **every ancestor**, not just the leaf. We go further: open each component with `O_NOFOLLOW` from a trusted root. |
| Identity-based protection on case-insensitive APFS | `file_ops.sh:1044-1132` (`_mole_is_critical_deletion_path`) | Compare **inode identity** with protected roots, not strings (`/SYSTEM` = `/System`). |
| "Owner is running" gate for caches | `SECURITY_AUDIT.md` §Destructive Operation Boundaries; `file_ops.sh:459-904` | Never delete a cache folder whose owning app/helper is running, and treat "can't tell" as "running". Handle SQLite `-wal`/`-shm` families together. |
| Exact-path leftover templates | `lib/core/app_protection.sh:1204-1340` (`find_app_files`) | Build candidate paths from bundle ID / name variants (`Caches/<id>`, `HTTPStorages/<id>.binarycookies`, `Saved Application State/<id>.savedState`…) instead of substring-matching directory listings. |
| Sibling / family guard on uninstall | `SECURITY_AUDIT.md` (shared-bundle-id sibling guard) | If another installed copy (Beta/Nightly, a second volume) shares the ID, keep shared data. **Absence must be proven** (tri-state: none / present / unknown). |
| launchd orphan detection | `SECURITY_AUDIT.md` (orphaned system services) | Flag a Launch* plist only when its `Program`/`ProgramArguments[0]` is absolute and missing, never `com.apple.*`. |
| BTM limitation | `lib/uninstall/batch.sh:3473-3475` | No public API deletes Background Task Management records. Detect and point the user to System Settings. |
| LaunchServices | `SECURITY_AUDIT.md` | Avoid domain-wide `lsregister` rebuilds; unregister only the removed bundle. |
| APFS clone sizing | `cmd/analyze/clone_darwin.go:36-55` | `getattrlist` + `ATTR_CMNEXT_CLONEID` + `EF_SHARES_ALL_BLOCKS` to avoid counting clones as reclaimable. We use the public `ATTR_CMNEXT_PRIVATESIZE` as well (confirmed in SDK `sys/attr.h:560`). |
| Bounded concurrency | `cmd/analyze/scanner.go:119-160` | Separate limits for directory entries vs heavy work, bounded by CPU count. |
| Large-file discovery via Spotlight | `scanner.go:806` | A fast optional path, with a full scan fallback when Spotlight is off or excludes a folder. |

### 2.3 Risks observed in Mole's approach

Shell `rm -rf` after validation still leaves a race window (acknowledged as M02). Permanent deletion by default. `sudo` flows. Breadth over depth: many app-specific rules need constant upkeep (593 commits/month).

---

## 3. Cross-cutting conclusions

1. **Ownership evidence beats name matching.** The best signals are container metadata, `AssociatedBundleIdentifiers`, receipts, the Team ID in app-group entitlements, and exact `<bundle-id>` paths. Name-only matches are shown as "possible" and are never pre-selected.
2. **Identity must be re-checked at delete time.** Neither project compares (device, inode, type, mtime) between scan and delete. We do.
3. **Reported "freed" space is usually wrong.** Both sum allocated sizes, ignoring hard links and clones. We report *private* size (what deletion actually frees) and label estimates.
4. **Use the tool's own commands for tool-managed storage** (Docker, Homebrew, simulators, pnpm). Both projects converge on this.
5. Neither project has a good localization story for RTL. We start with String Catalogs.
