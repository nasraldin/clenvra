# Gap Features 1–6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the six "Build" items of the feature-gap analysis: remove simulator runtimes, app permissions review, blurry and dark photos, "System Data" explained, Trash on every drive, and leftovers of apps already in the Trash.

**Architecture:** Each feature is a vertical slice: pure, tested logic in `ClenvraKit` (parsers, rules, sessions), then a thin SwiftUI surface on the existing page pattern (`Clenvra/Shared/PagePattern.swift`). Deletion goes only through `AppEnvironment.makeDeleter` (files) or `ToolCleanupRunner` (Apple tools). Tasks 1–6 are independent and run in parallel worktrees; Task 7 integrates, translates and verifies.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26 SDK 27), Swift Testing, SQLite3 (system library), Vision, Apple command-line tools (`xcrun simctl`, `tccutil`, `tmutil`).

**Spec:** [`docs/product/feature-gaps.md`](../../product/feature-gaps.md) (rows 1–6, "Build"), safety rules in [`docs/architecture/safety-model.md`](../../architecture/safety-model.md).

## Global Constraints

- macOS 26 minimum; anything macOS 27-only behind `if #available(macOS 27, *)` with a 26 path.
- Public APIs and Apple's own command-line tools only. No private frameworks, no `sudo`, no shell (`Command` takes an absolute executable and a fixed argv).
- Review before delete. Nothing in these features is selected by default (`risk: .review`, `isSelectedByDefault: false`).
- File deletions go through `DeletionExecutor` from `AppEnvironment.makeDeleter`; never call `FileManager.removeItem`/`trashItem` directly.
- Every user-visible string is a `LocalizedStringResource`/`Text` literal (the String Catalog extracts them). Do not edit `Localizable.xcstrings`; Task 7 syncs and translates.
- Tests first (Swift Testing, `@Test`, `#expect`), in `Packages/ClenvraKit/Tests/ClenvraKitTests/`. Run one suite with `swift test --package-path Packages/ClenvraKit --filter <SuiteType>`.
- Formatting: `xcrun swift-format lint --strict` must pass (120 columns). No force unwraps.
- Page pattern: toolbar items always present (disable, never add/remove), lists stay mounted with `pageState(isShown:)`, details in `detailsPanel(isPresented:width:)`, toolbar labels via `ToolbarLabel`.

## Review Focus

1. **A runtime that is in use or not deletable** (`"deletable": false`, or a simulator booted on it): the row must offer no action; `simctl` shuts booted simulators down itself, so the confirmation must say so. Test in Task 1.
2. **Permissions database unreadable** (no Full Disk Access, or the file is locked/absent): the page shows the Full Disk Access prompt, never an empty "no apps have permissions" list. Test in Task 2.
3. **Revoke fails** (`tccutil` exit ≠ 0, system-wide service, client is a path not a bundle ID): the app says so and offers the matching Privacy pane; it never claims success. Test in Task 2.
4. **External drive ejected between scan and clean**, or a read-only volume / disk image: no rule for read-only volumes; a vanished path fails safely as "not found". Test in Task 5.
5. **A Trash-ed app whose Info.plist is unreadable or has no bundle ID**, or two apps sharing an ID prefix with an installed app: skipped, and an installed app's data is never listed. Test in Task 6.

---

### Task 1: Remove simulator runtimes

**Files:**
- Modify: `Packages/ClenvraKit/Sources/ClenvraKit/Developer/ToolAdapters.swift` (`SimulatorAdapter.parseRuntimes`)
- Test: create `Packages/ClenvraKit/Tests/ClenvraKitTests/SimulatorRuntimeTests.swift` (no suite tests `parseRuntimes` today)

**Interfaces:**
- Consumes: `ToolStorage`, `ToolCleanupAction(command:risk:isIrreversible:summary:)`, `Command` (executable, arguments).
- Produces: runtime rows (`id: "simulators.runtime.<uuid>"`) whose `cleanup` is non-nil when deletable.

- [ ] **Step 1: Write the failing tests**, using this real `xcrun simctl runtime list -j` shape (keys are runtime UUIDs):
  ```json
  {"EC0470CE-EF90-4B78-955C-6E37ACB0E8A1": {"identifier": "EC0470CE-EF90-4B78-955C-6E37ACB0E8A1",
   "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "version": "18.6", "build": "22G86",
   "sizeBytes": 8838255185, "deletable": true, "kind": "Cryptex Disk Image", "state": "Ready",
   "path": "/Library/Developer/CoreSimulator/Cryptex/Images/bundle/x.dmg"},
   "AAAA0000-0000-0000-0000-000000000000": {"identifier": "AAAA0000-0000-0000-0000-000000000000",
   "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "version": "11.0",
   "sizeBytes": 100, "deletable": false, "state": "Ready"}}
  ```
  - `deletableRuntimeOffersDelete`: the iOS row's `cleanup?.command.arguments == ["simctl", "runtime", "delete", "EC0470CE-EF90-4B78-955C-6E37ACB0E8A1"]`, executable is the adapter's `xcrun`, `risk == .review`, `isIrreversible == true`, `summary == "xcrun simctl runtime delete EC0470CE-EF90-4B78-955C-6E37ACB0E8A1"`, `size == 8838255185`.
  - `undeletableRuntimeIsVisibilityOnly`: the watchOS row has `cleanup == nil`.
  - `runtimeWithoutIdentifierIsVisibilityOnly`: a row missing `identifier` has `cleanup == nil`.
- [ ] **Step 2: Run, expect FAIL** (`cleanup` is nil today): `swift test --package-path Packages/ClenvraKit --filter SimulatorRuntimeTests`.
- [ ] **Step 3: Implement** in `parseRuntimes`: `cleanup` only when `runtime["deletable"] as? Bool == true` and `identifier` is a non-empty string; pass the adapter's `xcrun` path into `parseRuntimes` (add a parameter `xcrun: String = "/usr/bin/xcrun"`). Note text: `"Needed only to run apps on \(name). Xcode can download it again. Simulators using it are shut down first."`; keep `"Remove unused runtimes in Xcode › Settings › Components."` for rows without an action.
- [ ] **Step 4: Run the suite, expect PASS**; then the whole `ToolAdapters`-related suites.
- [ ] **Step 5: Verify safely on this Mac:** `xcrun simctl runtime delete <one uuid> --dry-run` prints `Would delete …` (already checked once; do not run without `--dry-run`).
- [ ] **Step 6: Commit** `feat(developer): remove simulator runtimes with simctl`.

---

### Task 2: App permissions review and revoke

**Files:**
- Create: `Packages/ClenvraKit/Sources/ClenvraKit/Privacy/PermissionGrant.swift` (model + service catalog)
- Create: `Packages/ClenvraKit/Sources/ClenvraKit/Privacy/PermissionDatabase.swift` (read-only SQLite reader)
- Create: `Packages/ClenvraKit/Sources/ClenvraKit/Sessions/PermissionsSession.swift`
- Modify: `Packages/ClenvraKit/Sources/ClenvraKit/System/SystemSettingsPane.swift` (privacy anchors)
- Create: `Clenvra/Features/System/PermissionsView.swift`
- Modify: `Clenvra/App/AppSection.swift` (new page `.permissions`, group `.system`, title "Permissions", symbol `hand.raised`), `Clenvra/App/MainWindow.swift` (route), `Clenvra/App/AppEnvironment.swift` (session), `ClenvraUITests/UITestSupport.swift` (`allSections` gets `"permissions"` after `"security"`)
- Test: `PermissionDatabaseTests.swift`, `PermissionsSessionTests.swift`, extend `SystemSettingsPaneTests.swift`

**Interfaces:**
- Produces:
  - `public struct PermissionGrant: Sendable, Hashable, Identifiable { service: String /* "kTCCServiceCamera" */; client: String; clientIsBundleID: Bool; isAllowed: Bool; lastModified: Date?; scope: Scope (.user, .system); id: "\(scope):\(service):\(client)" }`
  - `public struct PermissionService { static func title(_ service: String) -> LocalizedStringResource; static func symbol(_:) -> String; static func shortName(_:) -> String /* drops "kTCCService" */ }` covering at least: Camera, Microphone, ScreenCapture, SystemPolicyAllFiles, Accessibility, ListenEvent (Input Monitoring), AddressBook, Calendar, Reminders, Photos, AppleEvents (Automation), SystemPolicyDesktopFolder/DocumentsFolder/DownloadsFolder, PostEvent; unknown services show their short name.
  - `public enum PermissionDatabase { static func read(at path: String, scope: PermissionGrant.Scope) throws(PermissionDatabase.Error) -> [PermissionGrant] }`, `Error: .unreadable` (open/prepare failed), via `sqlite3_open_v2(path, SQLITE_OPEN_READONLY)`, query `SELECT service, client, client_type, auth_value, last_modified FROM access`. `client_type 0` = bundle ID, `1` = path. `auth_value 2` (allowed) or `3` (limited) → `isAllowed true`; `0` → false. `last_modified` is seconds since 1970.
  - `@Observable public final class PermissionsSession { phase: .idle/.loading/.ready/.needsAccess; grants: [PermissionGrant] (allowed only, sorted by service then client); init(userDatabase: String, systemDatabase: String, runner: any CommandRunning, tccutil: String = "/usr/bin/tccutil"); func load() async; func revoke(_ grant: PermissionGrant) async -> RevokeResult (.revoked, .failed) }`. Database paths: `~/Library/Application Support/com.apple.TCC/TCC.db` (user) and `/Library/Application Support/com.apple.TCC/TCC.db` (system). `.needsAccess` when **both** reads throw.
  - `SystemSettingsPane.privacy(anchor: String)` → `com.apple.settings.PrivacySecurity.extension?<anchor>`; anchors: Camera `Privacy_Camera`, Microphone `Privacy_Microphone`, ScreenCapture `Privacy_ScreenCapture`, SystemPolicyAllFiles `Privacy_AllFiles`, Accessibility `Privacy_Accessibility`, ListenEvent `Privacy_ListenEvent`, AppleEvents `Privacy_Automation`, Photos `Privacy_Photos`, AddressBook `Privacy_Contacts`, Calendar `Privacy_Calendars`, Reminders `Privacy_Reminders`; others fall back to the pane without an anchor. (`SystemSettingsPane` is a `CaseIterable` enum today: add `privacy(anchor:)` as a static func returning `URL`, keep the enum's cases.)

- [ ] **Step 1: Failing tests — database.** `PermissionDatabaseTests`: create a temporary SQLite file with `CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, auth_reason INTEGER, last_modified INTEGER)` and rows: (`kTCCServiceCamera`, `us.zoom.xos`, 0, 2, …, 1_700_000_000), (`kTCCServiceMicrophone`, `/usr/local/bin/tool`, 1, 2), (`kTCCServiceCamera`, `com.denied`, 0, 0), (`kTCCServicePhotos`, `com.limited`, 0, 3). Expect 4 grants; zoom `isAllowed`, `clientIsBundleID`, `lastModified == Date(timeIntervalSince1970: 1_700_000_000)`; tool `clientIsBundleID == false`; denied `isAllowed == false`; limited `isAllowed == true`. `missingFileThrowsUnreadable`: a path that does not exist → throws `.unreadable`. `notADatabaseThrowsUnreadable`: a text file → throws.
- [ ] **Step 2: Failing tests — session.** `PermissionsSessionTests` with `FakeCommandRunner` (`Tests/ClenvraKitTests/Support/FakeCommandRunner.swift`): `loadKeepsAllowedOnly` (two databases → only allowed grants, sorted); `bothUnreadableNeedsAccess` (`phase == .needsAccess`, `grants.isEmpty`); `oneUnreadableStillReady` (user DB missing, system DB fine → `.ready`); `revokeRunsTccutilReset` (bundle-ID grant → runner received `/usr/bin/tccutil` `["reset", "Camera", "us.zoom.xos"]`, result `.revoked`, session reloaded); `revokeFailureReported` (runner exit 1 → `.failed`, grant still listed); `pathClientCannotBeRevoked` (path client → `.failed` without running anything).
- [ ] **Step 3: Failing test — panes.** In `SystemSettingsPaneTests`: `privacyAnchorsUsePrivacyPane`: `SystemSettingsPane.privacy(anchor: "Privacy_Camera").absoluteString == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"`.
- [ ] **Step 4: Run, expect FAIL** (types missing).
- [ ] **Step 5: Implement** `PermissionGrant.swift`, `PermissionDatabase.swift` (`import SQLite3`; always `sqlite3_close`; `sqlite3_open_v2` with `SQLITE_OPEN_READONLY`; read text columns defensively — a NULL becomes skip-row), `PermissionsSession.swift`, `SystemSettingsPane.privacy(anchor:)`. Reading runs off the main actor (`@concurrent`).
- [ ] **Step 6: Run the three suites, expect PASS.**
- [ ] **Step 7: UI.** `PermissionsView`: page pattern like `StartupView` — `Table` with `DisclosureTableRow` per service (group row: symbol, title, "N apps"), child rows: app icon + name (resolve with `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`, fall back to the bundle ID or the path's last component), "Since <date>" column, scope column ("This user" / "All users"). Toolbar: Refresh (⌘R), `ExpandAllButton` (`ExpandedGroups("permissions")`), `InspectorToggle`. Context menu and details panel: "Revoke…" (confirmation: "<App> will lose access to <Permission>. macOS asks again the next time it needs it."), "Open Privacy Settings" (the anchor URL), Show in Finder for the app. On `.failed`: alert "Could not revoke … Change it in System Settings." with a button to the pane. `.needsAccess` → `pageState` with the Full Disk Access prompt (`FullDiskAccess.settingsURL`). Page loads on first appear (read-only, like Startup).
- [ ] **Step 8: Build the app** (`xcodebuild … build`) and run `ClenvraUITests/NavigationUITests/testNavigationEnglishLight` in the VM (`scripts/ui-tests-vm.sh ClenvraUITests/NavigationUITests/testNavigationEnglishLight`): the new page opens.
- [ ] **Step 9: Commit** `feat(privacy): review app permissions and revoke with tccutil`.

---

### Task 3: Blurry and dark photos

**Files:**
- Modify: `Packages/ClenvraKit/Sources/ClenvraKit/SimilarPhotos/SimilarPhotoFinder.swift` (score during analysis), `SimilarPhotoModels.swift` (result field), `Packages/ClenvraKit/Sources/ClenvraKit/Sessions/SimilarPhotosSession.swift` (list + marking)
- Create: `Packages/ClenvraKit/Sources/ClenvraKit/SimilarPhotos/PhotoQuality.swift`
- Modify: `Clenvra/Features/Storage/SimilarPhotos/SimilarPhotoGroupsList.swift` (a "Blurry or Dark Photos" section above the groups)
- Test: `PhotoQualityTests.swift`, extend `SimilarPhotosSessionTests.swift`

**Interfaces:**
- Produces:
  - `public struct PhotoQuality: Sendable, Hashable { score: Float; isUtility: Bool; static let lowThreshold: Float = -0.1; var isLow: Bool { !isUtility && score < Self.lowThreshold } }`
  - `SimilarPhotoScanResult.lowQuality: [SimilarPhoto]` (sorted by score ascending), and `SimilarPhotosSession.lowQualityPhotos: [SimilarPhoto]`.
  - Marking: `canMark(path)` returns true for a low-quality photo that is in no group; a photo in a group keeps the group rule (one kept). `markedCount`/`markedBytes`/`moveMarkedToTrash` include marked low-quality photos.

- [ ] **Step 1: Failing tests.** `PhotoQualityTests`: `lowScoreIsLow` (`PhotoQuality(score: -0.3, isUtility: false).isLow`), `utilityIsNeverLow` (`score: -0.9, isUtility: true` → false), `goodScoreIsNotLow` (`0.7` → false), `thresholdIsExclusive` (`-0.1` → false). `scoresDegradedImages` (integration, Vision): render a 512×512 CGImage gradient with detail (checkerboard), score it, then a Gaussian-blurred copy (σ 12) and an exposure −4 copy; expect blurred.score < original.score and dark.score < original.score (measured on Apple wallpapers: originals +0.65…+0.79, degraded −0.16…−0.42; assert ordering only, not values). Session tests: `lowQualityPhotoCanBeMarkedAlone` (a low-quality photo not in any group: `canMark == true`, marking it increases `markedCount`); `groupRuleStillWins` (a photo in both a group and the low list: cannot mark the last kept photo of its group).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** In the finder's per-image analysis, run `VNCalculateImageAestheticsScoresRequest` on the same downscaled image as the feature print, store `PhotoQuality` (on failure: `nil`, the photo is simply not rated). Collect `lowQuality` from photos whose quality `isLow`. Session: store `lowQualityPhotos`; extend `canMark`/`setMarked`/`markedBytes` as specified; `markAllButSuggested` does **not** mark low-quality photos (never preselected).
- [ ] **Step 4: Run suites, expect PASS.**
- [ ] **Step 5: UI.** Section header "Blurry or Dark Photos" with count and size, same thumbnail cells and checkboxes as groups, collapsible via the existing `isExpanded` closure with id `"lowQuality"`; footer note "Rated by macOS image analysis. Check each photo before moving it to the Trash." Hidden when empty.
- [ ] **Step 6: Commit** `feat(photos): find blurry and dark photos`.

---

### Task 4: "System Data" explained

**Files:**
- Create: `Packages/ClenvraKit/Sources/ClenvraKit/Storage/SystemDataBreakdown.swift`
- Create: `Clenvra/Features/Storage/SystemDataView.swift`
- Modify: `Clenvra/Features/Storage/StorageView.swift` (Space Map toolbar button "What's in System Data", popover)
- Test: `SystemDataBreakdownTests.swift`

**Interfaces:**
- Consumes: `SimulatorAdapter.parseRuntimes` (sizes), `Volume.purgeableEstimate`, `CommandRunning`.
- Produces: `public struct SystemDataBreakdown: Sendable, Equatable { swapUsed: Int64?; localSnapshots: [String]; simulatorRuntimes: Int64?; purgeable: Int64? }` and `public enum SystemDataReader { static func read(runner: any CommandRunning, rootVolume: Volume?) async -> SystemDataBreakdown; static func parseSnapshots(_ tmutilOutput: String) -> [String]; static func swapUsed() -> Int64? }`.

- [ ] **Step 1: Failing tests.** `parseSnapshots` on `"Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-30-101500.local\ncom.apple.os.update-ABC\n"` → `["com.apple.TimeMachine.2026-10-30-101500.local", "com.apple.os.update-ABC"]`; on `"Snapshots for disk /:\n"` → `[]`. `readSumsRuntimes`: fake runner returns the Task 1 JSON for `xcrun simctl runtime list -j` and the snapshot text for `/usr/bin/tmutil listlocalsnapshots /` → `simulatorRuntimes == 8838255185 + 100`, `localSnapshots.count == 2`. `missingToolsGiveNil`: runner fails → `simulatorRuntimes == nil`, `localSnapshots == []`. `swapUsedIsReadable`: `swapUsed() != nil` on this Mac.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** `swapUsed()` via `sysctlbyname("vm.swapusage")` into `xsw_usage` (`xsu_used`). Runtimes: skip when `~/Library/Developer/CoreSimulator` is absent (same guard as `SimulatorAdapter`). Snapshots: `/usr/bin/tmutil listlocalsnapshots /`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: UI.** Popover from a Space Map toolbar button (symbol `questionmark.circle`, label "What's in System Data"): one row per part with size (or "None"), a one-line explanation and a link: swap ("Memory macOS moved to disk; it shrinks after a restart"), local snapshots (count; "Open Snapshots" → `.snapshots`), simulator runtimes ("Open Developer Tools" → `.developerTools`), purgeable ("Space macOS frees by itself when needed"). Navigation uses the existing `navigate`/selection mechanism (pass a closure from `MainWindow`).
- [ ] **Step 6: Commit** `feat(storage): explain what System Data holds`.

---

### Task 5: Trash on every drive

**Files:**
- Modify: `Packages/ClenvraKit/Sources/ClenvraKit/Rules/RuleCatalog.swift` (add `volumeTrash`), `Packages/ClenvraKit/Sources/ClenvraKit/Sessions/CleanupSession.swift` (rules re-read per scan), `Clenvra/App/AppEnvironment.swift` (provider)
- Test: `RuleCatalogTests.swift`, `CleanupSessionTests.swift`

**Interfaces:**
- Produces:
  - `public static func volumeTrash(volumeRoots: [String], uid: uid_t) -> [CleanupRule]` → for each root `R`: `CleanupRule(id: "trash.volume.<R>", category: .trash, root: .absolute("\(R)/.Trashes/\(uid)"), selection: .children(), risk: .review, action: .removePermanently, ownership: .none)`.
  - `CleanupSession.init(..., extraRules: @escaping @Sendable () -> [CleanupRule] = { [] })`; `scan()` uses `rules + extraRules()` and updates `actionsByRule`/`elevatedRules` for them (reuse `setRules` internals).
  - In `AppEnvironment` (cleanup section only): `extraRules: { RuleCatalog.volumeTrash(volumeRoots: VolumeInventory.mountedVolumes().filter { !$0.isRoot && !$0.isReadOnly && ($0.kind == .internal || $0.kind == .external) }.map(\.id.path), uid: getuid()) }` — read `Volume.Kind` to exclude disk images and network volumes.

- [ ] **Step 1: Failing tests.** `volumeTrashRules`: roots `["/Volumes/Backup"]`, uid 501 → one rule, root `/Volumes/Backup/.Trashes/501`, `action == .removePermanently`, `risk == .review`. `noVolumesNoRules`: `[]` → `[]`. `scanUsesExtraRules` (CleanupSession with a temp folder standing in for a volume Trash, `extraRules` pointing at it): the scan lists its children under category `.trash`; changing what `extraRules` returns changes the next scan's results. `vanishedVolumeIsHarmless`: extra rule root does not exist → scan finishes with no candidates for it and no error.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** as specified. Confirm `ProtectionPolicy` does not protect `/Volumes/<name>/.Trashes/<uid>/*` (only `/Volumes` itself is protected) with a test `volumeTrashIsNotProtected`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(cleanup): empty the Trash on every drive`.

---

### Task 6: Leftovers of apps already in the Trash

**Files:**
- Modify: `Packages/ClenvraKit/Sources/ClenvraKit/Apps/OwnershipResolver.swift` (`leftovers`), `Packages/ClenvraKit/Sources/ClenvraKit/Apps/OwnedItem.swift` (evidence case), `Packages/ClenvraKit/Sources/ClenvraKit/Apps/AppInventory.swift` (find apps in the Trash), `Packages/ClenvraKit/Sources/ClenvraKit/Sessions/AppsSession.swift` (pass them)
- Modify: `Clenvra/Features/Applications/AppDetailView.swift` (`EvidenceText`, new case)
- Test: `OwnershipResolverTests.swift`, `AppInventoryTests.swift`

**Interfaces:**
- Produces:
  - `public static func appsInTrash(trashRoots: [String]) -> [InstalledApp]` in `AppInventory`: `*.app` directories directly inside each root (depth 1), parsed with `AppInventory.app(at:)`; apps without a bundle identifier are skipped.
  - `OwnedItem.Evidence.appInTrash(String)` (the app's name).
  - `leftovers(installedApps:trashedApps: [InstalledApp] = [], inventoryIsComplete:now:)`: an orphan whose identifier `sharesLineage` with a trashed app's identifier gets evidence `.appInTrash(name)` added, confidence `.likely`, and is **exempt from the 30-day age cutoff**; still never preselected; an identifier that is also installed is never listed (installed wins).
  - `AppsSession.scanLeftovers()` passes `AppInventory.appsInTrash(trashRoots: [home + "/.Trash"])`.

- [ ] **Step 1: Failing tests.** In a temp home: `~/.Trash/Foo.app/Contents/Info.plist` with `CFBundleIdentifier com.example.foo`, `~/Library/Application Support/com.example.foo/` modified today. `trashedAppDataIsListedEvenIfNew`: listed, evidence contains `.appInTrash("Foo")`, confidence `.likely`, `isSelectedByDefault == false`. `withoutTrashedAppNewDataIsHidden`: same files without the Trash app → not listed (30-day rule). `installedWins`: `com.example.foo` also installed → not listed. `appWithoutBundleIDIsIgnored`: `appsInTrash` skips a bundle whose Info.plist lacks the key. `appsInTrashDepthOne`: `~/.Trash/folder/Bar.app` is not returned.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** as specified; evidence text in the app: "“Foo” is in the Trash".
- [ ] **Step 4: Run, expect PASS** (whole `OwnershipResolverTests` and `AppsSessionTests`).
- [ ] **Step 5: Commit** `feat(apps): find leftovers of apps already in the Trash`.

---

### Task 7: Integrate, translate, verify, document (lead, not delegated)

- [ ] **Step 1:** Merge Tasks 1–6 into `main` one by one; after each, `scripts/check.sh` (format, all package tests, Release build).
- [ ] **Step 2:** `scripts/sync-strings.sh`; Arabic for every new key in `docs/engineering/translations/R9-gap-features.json`; `python3 -I scripts/apply-translations.py …`; `0 keys still need Arabic`.
- [ ] **Step 3:** Full UI suite in the VM (`scripts/ui-tests-vm.sh`): navigation (en/ar × light/dark, including the new Permissions page) and the accessibility audit pass.
- [ ] **Step 4:** Owner's rule: **no real data is removed or changed on the owner's Mac.** Destructive paths are proven only with test data:
  - Package tests: temporary folders, temporary SQLite databases and `FakeCommandRunner` (no real `tccutil`, no real `simctl … delete`).
  - End to end in the disposable VM (`CLENVRA_VM_SETUP` seeds the data): a fake `Foo.app` in `~/.Trash` with `~/Library/Application Support/com.example.foo` (Leftovers lists and removes it), a writable disk image attached with files in its `.Trashes/<uid>` (Cleanup empties it), low-quality test photos generated into `~/Pictures` (listed and moved to the Trash). Permissions and runtime removal are checked in the VM with whatever the VM has; on the owner's Mac only `--dry-run`.
  - On the owner's Mac: nothing beyond building; the owner tests the final release build.
- [ ] **Step 5:** Docs: `docs/product/feature-gaps.md` (runtime size corrected to 24.8 GB = `sizeBytes`, rows 1–6 marked shipped), `verified-feature-matrix.md` (DEV-2 delete, CL-5 per-volume, new privacy row), `docs/STATUS.md`.
- [ ] **Step 6:** Commit, push, CI green.
