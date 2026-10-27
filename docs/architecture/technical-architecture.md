# Technical Architecture

## 1. Platform decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language / UI | Swift 6 (language mode 6, strict concurrency), SwiftUI, AppKit only where needed (Quick Look, drag from Finder, `NSWorkspace`) | Native; installed toolchain is Swift 6.4 / Xcode 27.1 |
| Deployment target | **macOS 26**, **arm64 only** (decided, D1) | The app runs on all the owner's Macs, all Apple Silicon. All the owner's Macs run 26+. This gives the newest SwiftUI and Liquid Glass with no availability branches. `SMAppService` daemons and XPC code-signing requirements (macOS 13+) are included. |
| Architectures | `ARCHS = arm64` | No Intel Macs; one slice to build and test |
| Distribution | **Direct, non-sandboxed, Hardened Runtime, Developer ID signed and notarised** | Needed to install on several Macs, including managed work Macs, without Gatekeeper prompts. A sandbox would limit access to user-chosen folders and block `/Library/Launch*`, receipts, other apps' containers and tool commands (evidence: CleanMyMac MAS entitlements, `installed-app-analysis.md` §3). |
| Privileged helper | **Optional, from 1.1**: `SMAppService.daemon`, off by default, installed from Settings | Required for system-level work: system leftovers on uninstall, `/Library` caches/logs, system launch items, local snapshots. Without it, these items fall back to Reveal in Finder. Design in §6a. |
| Updates of Clenvra itself | Manual DMG in 1.0; Sparkle (the only candidate dependency) considered for 1.2 | Several Macs need a simple update path; the decision is deferred (D9) |
| Dependencies | **None** | Everything needed is in Foundation, Darwin, CryptoKit, ServiceManagement, UniformTypeIdentifiers, CoreServices (Spotlight), QuickLookUI. JSON-lines log instead of SQLite/GRDB. |
| Persistence | `~/Library/Application Support/Clenvra/` : `settings.json`, `activity/YYYY-MM.jsonl`; scan cache optional (1.1) | Human-readable, auditable, no schema migrations |
| Logging | `OSLog` `Logger(subsystem: "app.clenvra", category: …)`; paths logged with `privacy: .private` | Diagnostics without leaking paths to sysdiagnose |
| Network | **No network entitlement use, no telemetry** | Offline-first |

## 2. Project structure

```
Clenvra.xcodeproj
├─ Clenvra/                         App target (UI only, @MainActor)
│  ├─ App/                          ClenvraApp, AppModel, Commands (menus/shortcuts)
│  ├─ Features/
│  │  ├─ Overview/  Storage/  Developer/  Cleanup/  Applications/  Startup/  Activity/  Settings/
│  ├─ Shared/                       RiskBadge, SizeLabel, PathLabel, ReviewTable, ConfirmSheet, ResultSheet
│  └─ Resources/                    Localizable.xcstrings, InfoPlist.xcstrings, Assets.xcassets
├─ Packages/ClenvraKit/             Local Swift package, no UI, fast `swift test`
│  ├─ Sources/ClenvraKit/
│  │  ├─ FileSystem/   BulkEnumerator (getattrlistbulk), FileIdentity, SizeInfo, Volume, FSExecutor
│  │  ├─ Index/        StorageIndex (actor), DirectorySummary
│  │  ├─ Rules/        Category definitions (data), Risk, Evidence, Exclusions
│  │  ├─ Safety/       PathPolicy, ProtectedRoots, OwnerActivity, DeletionPlan, DeletionExecutor
│  │  ├─ Apps/         AppInventory, OwnershipResolver, ReceiptReader, EntitlementReader
│  │  ├─ Developer/    ToolLocator, ToolCommand, adapters (Xcode, simctl, npm, pnpm, yarn, brew, docker)
│  │  ├─ Startup/      LaunchItemReader, ManagedItemDetector
│  │  ├─ System/       HealthSampler, ProcessSampler, SecurityChecks
│  │  ├─ Duplicates/   DuplicateFinder (staged hashing, byte compare)
│  │  ├─ Settings/     SettingsStore, Export/Import
│  │  └─ Activity/     ActivityLog, RestoreService
│  └─ Tests/ClenvraKitTests/        Swift Testing + FixtureBuilder
├─ ClenvraHelper/                   (1.1) privileged XPC daemon, links ClenvraKit Safety only
└─ ClenvraUITests/                  XCTest UI (en/ar × light/dark smoke)
```

There are two modules (app + kit) in 1.0, plus a helper target in 1.1. That is the minimum split that gives fast, UI-free tests of every safety rule. There are no protocols "for later". A protocol exists only where tests need a seam: `FileSystemOperations` for fault injection in the executor, and `CommandRunner` for tool commands.

## 3. Core components

### 3.1 FileSystem

- **`BulkEnumerator`**: reads directories with `getattrlistbulk(2)` on an `open(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` fd. A single syscall returns, per entry: name, `objtype`, `fileid`, `devid`, `linkcount`, `flags` (`UF_DATAVAULT`, `SF_RESTRICTED`…), modification/access dates, allocated size, and with `FSOPT_ATTR_CMN_EXTENDED` **`ATTR_CMNEXT_PRIVATESIZE`** and `ATTR_CMNEXT_CLONEID`/`EXT_FLAGS`. It never follows symlinks and never crosses a mount (`devid` change = stop and record a boundary). Children are opened with `openat(parentFD, name, O_NOFOLLOW)`, so a path swap during the walk can't redirect it.
  - Why not `FileManager.enumerator`: it costs one `URLResourceValues` call (several syscalls) per item, and MacSai's measured design suffers from it. `fts` is fine but path-based. A bulk read plus `openat` is both faster and safer.
- **`FileIdentity`** = (`devid`, `fileid`, `objtype`, `mtime`, `size`). It is captured at scan time and compared at delete time.
- **`SizeInfo`** = `logical`, `allocated`, `private`. "Frees ≈" always uses **private** size: per `getattrlist(2)`, these are the bytes "not trapped inside a clone or snapshot, which would be freed immediately if the file were deleted". Hard links (`linkcount > 1`) are counted once per (`devid`, `fileid`) in totals and shown as *shared*. If the volume doesn't report private size (non-APFS), allocated size is used and the label shows "estimate".
- **`FSExecutor`**: a custom Swift `TaskExecutor` backed by a small thread pool (width `min(activeProcessorCount, 8)`, QoS `.utility`). Blocking syscalls run there via `withTaskExecutorPreference`, so they never occupy the cooperative pool. (MacSai's duplicate finder blocks it with one task per file.)

### 3.2 StorageIndex (actor)

- Breadth-first, **bounded-parallel** walk: a work queue of directory fds, at most *N* in flight.
- Keeps **aggregates per directory**, not a node per file: the total, child directory summaries, the top 50 largest files per subtree in a bounded heap, and counts. Memory is O(directories), not O(files).
- Emits `AsyncStream<IndexEvent>`, coalesced to at most one UI update per 150 ms.
- Cancellation is checked between directory batches; a cancelled scan keeps partial results, marked "incomplete".
- Re-scans are scoped: refresh a subtree, never the whole disk, after a cleanup.
- Optional (1.1): FSEvents `kFSEventStreamCreateFlagFileEvents` with `sinceWhen` stored, to invalidate only changed subtrees on the next launch.

### 3.3 Rules (categories as data)

Each cleanup category is a value:

```swift
struct CategoryRule: Sendable {
  let id: CategoryID
  let roots: [RootSpec]          // e.g. .home("Library/Caches"), with per-root depth
  let match: MatchSpec           // children-of-root / extensions / marker files / age
  let risk: Risk                 // .safe / .review / .protected
  let ownerCheck: OwnerCheck     // none / bundleIDFromName / processName
  let action: ActionSpec         // .trash / .toolCommand(ToolCommand) / .revealOnly
  let explanation: LocalizedStringResource
}
```

The rules live in code, not downloaded, so they are reviewable in diffs and unit-testable.

### 3.4 Apps

- **`AppInventory`** scans `/Applications`, `~/Applications`, `/Applications/Setapp` and Homebrew `Caskroom` symlink targets (depth ≤ 3, skipping package descendants). For each app it reads `Info.plist` (`CFBundleIdentifier`, version, executable). Icons are loaded lazily via `NSWorkspace.icon(forFile:)`. "Last used" comes from `MDItemCopyAttribute(kMDItemLastUsedDate)`. The source is detected from the `_MASReceipt` folder or a Caskroom link. Sizes are computed lazily with the bulk enumerator.
- **`OwnershipResolver`** produces `[OwnedItem(path, evidence: [Evidence], confidence)]`:
  1. **Certain:**
     - exact `<bundleID>` children of known roots (`Caches`, `Application Support`, `HTTPStorages`, `WebKit`, `Saved Application State/<id>.savedState`, `Preferences/<id>.plist`, `Cookies/<id>.binarycookies`, `Application Scripts/<id>`, `LaunchAgents`);
     - `~/Library/Containers/*` whose `.com.apple.containermanagerd.metadata.plist` `MCMMetadataIdentifier` equals the ID or a bundled extension's ID (enumerate `Contents/PlugIns/*.appex` and `Contents/Library/LoginItems/*.app` IDs);
     - launchd plists whose `AssociatedBundleIdentifiers` or `Program` points into the bundle;
     - receipt files from `pkgutil --pkgs` / `--files` when an installer package matches.
  2. **Likely:** `~/Library/Group Containers/<group>` where `<group>` is in the app's `com.apple.security.application-groups` entitlement (`SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation`); exact display-name folders in `Application Support`/`Caches`/`Logs`.
  3. **Possible (never pre-selected):** whole-word name matches. They are shown only if no other installed app also matches.
  - **Shared guard:** an item stays unselected if any *other* installed app (by ID lineage or group membership) also claims it. Discovery returns `none / present / unknown`; `unknown` keeps the guard on.

### 3.5 Developer adapters

`ToolLocator` resolves the user's login-shell `PATH` once (`/bin/zsh -lc 'command -v npm pnpm yarn brew docker xcrun'`, 3 s timeout) and then runs tools with **absolute paths and fixed argv**. No string-built shell commands are used.

Adapters report two things:

- `sizeProbe()`: the read-only command or path size, e.g. `pnpm store path`, `npm config get cache`, `xcrun simctl list -j`, `docker system df --format json`;
- `cleanup()`: a `ToolCommand`, e.g. `pnpm store prune`, `npm cache clean --force`, `xcrun simctl delete unavailable`, `brew cleanup -s`.

Output streams to the UI. Exit status and a stderr summary are logged. Before/after sizes are measured, not assumed.

### 3.6 Startup

`LaunchItemReader` parses plists in the three Launch* folders (`PropertyListDecoder`, size-capped at 1 MB). It extracts the label, program, schedule, `KeepAlive`/`RunAtLoad` and `AssociatedBundleIdentifiers`, and adds status from `SMAppService.statusForLegacyPlist(at:)`. Owner: associated ID → installed app, or a program path inside an app bundle. **Target missing** = absolute program path that fails `lstat`.

### 3.7 Activity

`ActivityLog` appends JSON lines. Each record holds: operation ID, time, section, item path, identity, sizes, action, outcome, resulting Trash URL, error. `RestoreService` moves a trashed item back with `FileManager.moveItem` only when the original path is free and the Trash item's identity still matches.

## 4. Concurrency model

```
@MainActor  SectionModel (@Observable) ──start──▶ Task { await kit.scan(...) }   // cancellable handle kept by model
                                       ◀─events── AsyncStream (coalesced 150 ms)
ClenvraKit  actor StorageIndex / scanners ──blocking I/O──▶ FSExecutor (bounded pool)
            actor DeletionExecutor (one at a time; serial by design)
            ToolCommand runs via Process + async pipes; cancellable (SIGTERM, then SIGKILL after 5 s)
```

- The main actor does no filesystem I/O. Models hold only display-ready slices: tables are fed with at most a few thousand rows; deeper levels load on expand.
- Sendable value types cross actors. There are no `@unchecked Sendable` classes.
- One destructive operation at a time, app-wide (`DeletionExecutor` is a serial actor). Scans can continue in parallel but are invalidated for affected subtrees.

## 5. Performance targets and measurement

| Metric | Target | How measured |
|---|---|---|
| Cold launch to interactive window | < 400 ms (M-series) | `os_signpost` launch interval; Instruments App Launch |
| Idle CPU / memory after a scan | 0% CPU; < 120 MB resident | Activity Monitor / `footprint` |
| Enumeration throughput, warm cache | ≥ 250k entries/s | Benchmark test over a synthetic 1M-file fixture (`FixtureBuilder`) and on `~` (read-only) |
| Full home scan (reference: first Mac, ~800 GB used) | Measured and recorded per Mac, not promised; UI stays at 60 fps | Signposts + Instruments Hangs |
| Memory during full scan | O(directories); < 400 MB for 5M files | `footprint`, XCTest `XCTMemoryMetric` |
| Duplicate hashing (1.1) | I/O-bound; ≤ 4 concurrent readers; 1 MB read buffers reused | Benchmark fixture |
| Deletion | ≥ 2,000 items/s to Trash for small files | Fixture benchmark |

Results go into `docs/testing/benchmarks.md` (created when the first benchmark runs).

## 6. Permissions and distribution

| Capability | Without FDA | With FDA | Notes |
|---|---|---|---|
| Home folders, most of `~/Library` | ✓ | ✓ | |
| `~/Library/Containers/*`, `Mail`, `Safari`, `~/.Trash` listing | partial / ✗ | ✓ | TCC-protected; the app degrades gracefully and shows "skipped (needs Full Disk Access)" |
| `/Library/Launch*` read | ✓ | ✓ | Writes need admin, so reveal-only |
| Other users' data, SIP paths | ✗ | ✗ | Never attempted |

**Managed (company) Macs:**
- Never act on items owned by MDM or security software: configuration profiles, `com.microsoft.wdav*`, Ivanti/Pulse, Jamf, Kandji, Intune, CrowdStrike, SentinelOne, and other agents. They are detected by Team ID of the program and by known labels, and shown as "Managed by your organisation".
- If Full Disk Access is blocked by a PPPC profile, the app explains that and keeps working.
- The helper is never required.

**Multiple volumes:** the Storage index runs per volume. External drives are scanned on request. Network volumes are read-only by default. Trash on another volume uses that volume's `.Trashes` (handled by `trashItem`). Removable volumes can be ejected via DiskArbitration.

**Settings across Macs:** `Settings → Export` writes `clenvra-settings.json` with exclusions, developer roots, rule toggles and thresholds. Home-relative paths are stored as `~/…` so they apply on any Mac. Import validates and previews the changes.

### 6a. Optional privileged helper (1.1)

- Packaged as `Contents/Library/LaunchDaemons/app.clenvra.helper.plist`, registered with `SMAppService.daemon(plistName:)`. The user approves it in System Settings. It can be uninstalled from Settings, and is unregistered automatically when the app is removed with Clenvra itself.
- Uses `NSXPCConnection` both ways, with `setCodeSigningRequirement("anchor apple generic and identifier \"app.clenvra.Clenvra\" and certificate leaf[subject.OU] = \"<TEAMID>\"")`. This pins the Team ID so a forged ad-hoc client can't connect. MacSai documents the same need: `Constants.swift:9-24`.
- **Small fixed protocol, no paths as free-form commands:**
  - `trash(items: [PlanItem])`
  - `removeIrreversible(items: [PlanItem])`
  - `bootout(label:domain:)`
  - `deleteLocalSnapshot(date:)`
  - `version()`
- The helper **re-runs the full deletion gate** (`safety-model.md` §4) itself, with a *narrower* root allowlist: `/Library/{Caches,Logs,LaunchAgents,LaunchDaemons,PrivilegedHelperTools,Application Support/<owner>}`, `/private/var/log` (archives only), and `/Applications/<bundle>.app`. It refuses anything else even if the app asks.
- It runs only on demand (XPC launch-on-demand) and exits when idle. There is no `KeepAlive`.

**FDA detection:** attempt a read-only `open` of a TCC-protected file that always exists (e.g. `~/Library/Containers/com.apple.Safari`). AppCleaner uses a similar probe (`TCC.db` string). The app deep-links to the Full Disk Access pane in System Settings.

**Sandboxed vs direct (summary):**

| | Sandboxed (MAS) | Direct (chosen) |
|---|---|---|
| Access | User-picked folders only, via security-scoped bookmarks | Everything the user can access, plus TCC areas once FDA is granted |
| Launch* / receipts / other apps' containers | No | Yes (read) |
| Running `xcrun`, `pnpm`, `brew` | No (child processes inherit the sandbox) | Yes |
| Review | App Store | Notarisation (optional for personal use) |

## 7. Explicit "won't do" engineering rules

No private APIs. No `AuthorizationExecuteWithPrivileges`. No `do shell script … with administrator privileges`. No `rm -rf` via shell. No `lsregister` domain rebuilds. No modification of other apps' bundles. No resident processes unless the user enables scheduling or the menu bar extra (1.2). No machine-specific paths: every location is resolved at runtime (home, tool caches via the tool's own `config get`/`store path`).
