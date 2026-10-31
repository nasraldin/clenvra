# Review Round 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner's review of 2026-10-31: complete Uninstall and flexible app backups (F); Startup items and Permissions you can act on, with the helper for Mac-wide items (G); Extensions with real icons, quit-before-remove and fast scrolling (H); Leftovers and Large & Old grouped (J); Similar Photos pre-selected with a clear keep/remove comparison (K).

**Architecture:** Logic and tests in ClenvraKit, views in the app, privileged work only through the existing XPC helper (`ClenvraHelper`, `HelperService`, `PrivilegedOperations`). Public Apple API only.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26, SDK 27), Swift Testing, XPC helper, `/usr/bin/ditto`, `brew`, `launchctl`, `tccutil`, `pkgutil`.

**Spec (owner, verbatim points):** Large & Old "more organised and grouped, with collapse/expand"; Similar Photos "after scan by default select all photos that need to be deleted … user can clear selection … I get lost which other one it compares with to keep"; Applications "select 2 apps and copy path copies only one"; "an option to take a backup of the app … whole app with everything to save its state (before an upgrade) … or just its config … restore one or multiple apps and choose what to restore"; "the 2 trash icons in the header are confusing … Uninstall should totally remove the app and clean up as if never installed … not to the Trash … handle how it was installed, e.g. brew"; Leftovers "organised so I can remove related things together, not a flat list"; Extensions "some do not have the correct icon … page gets slow when scrolling with Apple shown … option to quit/stop/kill the app so I can remove it"; Startup "quit, remove, disable … best case"; Permissions "option to revoke the permission for any app".
**Owner decisions:** Uninstall deletes permanently after a confirmation listing everything, with "Back up first" ON by default (Remove to Trash stays as the undoable action). Mac-wide startup items use the privileged helper, asking for the admin password each time; own items never need it.

## Global Constraints

As `2026-10-30-gap-features.md`: macOS 26 min, public API only, tests first (Swift Testing), `swift-format lint --strict` clean, no edits to `Localizable.xcstrings`, page pattern (stable toolbar structure, `pageState` overlays, `detailsPanel` + `InspectorToggle`, `.pageSearch` applied BEFORE the page's own `.toolbar` so search stays the last icon), no force unwraps, never silently elevate. Tests touch only temporary folders they create and fake runners (`FakeCommandRunner`); never real apps, real launch items, real TCC grants or real user data. Never run `brew`, `launchctl`, `tccutil`, `pkgutil` or the helper for real from tests or the shell.

## Review Focus

1. Uninstall of an app whose files are partly root-owned: the helper deletes those (irreversible mode) only after the same gate checks; nothing outside the reviewed list is touched; a Homebrew cask is uninstalled through `brew` as the user (never sudo).
2. Backup "Settings only" never includes the app bundle; "Whole app" includes bundle + every owned item; restoring "replace current version" moves the current copy to the Trash first (undoable), never deletes it.
3. Disabling a Mac-wide startup item asks for the admin password each time and is reversible (Enable); an item whose plist changed since review is refused.
4. Pre-selected similar photos never include a group's keeper; changing the keeper moves the selection with it.
5. Grouped lists (Leftovers, Large & Old): selecting a group selects only its visible, removable items; search/filter still apply inside groups.

---

### Task F: Applications — distinct actions, complete Uninstall, flexible backups, multi copy

**Files:** kit `Sessions/AppsSession.swift` (+ new `Sessions/AppsSession+Uninstall.swift`), `Apps/AppBackup.swift`, new `Apps/InstallSource.swift`; tests `AppUninstallTests.swift`, `AppBackupTests.swift`, `InstallSourceTests.swift`; app `Features/Applications/ApplicationsView.swift`, `ApplicationsSheets.swift`, `AppBackupsSheet.swift`, new `AppBackupOptionsSheet.swift`.

**Interfaces:**
- Toolbar (checked apps, else the selected app): **Move to Trash…** (`trash`, undoable, optional backup toggle as today), **Uninstall…** (`xmark.bin`, permanent), **Back Up…** (`externaldrive.badge.plus`), **Backups…** (`clock.arrow.circlepath`). Each has a distinct symbol and a help text saying exactly what it does.
- Context menu Copy Path / Show in Finder: when the clicked app is checked, act on all checked apps (`FileActionsMenu(paths:)` with every checked bundle path).
- `enum InstallSource { case homebrewCask(token), homebrewFormula(name), appStore, package(ids: [String]), direct }` detected read-only: Homebrew via existing `HomebrewCasks`/`homebrewToken`; App Store via `Contents/_MASReceipt/receipt`; package via `pkgutil --file-info <bundle>` (FakeCommandRunner in tests).
- `AppsSession.uninstall(_ apps: [InstalledApp], backup: AppBackup.Scope?, dryRun:) async -> BatchUninstallResult`: per app → optional backup (abort app on failure) → Homebrew: `brew uninstall --cask --zap <token>` (or formula) as the user, then re-check what is left → remaining bundle + all owned items (every confidence level the detail lists, minus protected) deleted with `DeletionMode.irreversible` through the gate; root-owned via `HelperRequest(mode: .irreversible)`; package receipts forgotten via helper (`pkgutil --forget <id>`, new allow-listed helper op if needed — coordinate: Task G owns helper files; if F needs a helper op, add it in F's own new file and list it in the report). Running/protected apps skipped as in `uninstallChecked`. Activity records `outcome: .deleted` (not restorable).
- `AppBackup.Scope { case wholeApp, settingsOnly }` stored in the manifest (`scope`, default `wholeApp` for old manifests). Settings = Preferences, Application Support, Containers, Group Containers, Saved Application State, Cookies/HTTPStorages of that app (from the owned items by kind); never the bundle, caches or logs.
- `AppBackup.restore(_ backup: URL, items: Set<String>? /*nil = all*/, replaceExisting: Bool)`: `replaceExisting` moves each existing original to the Trash (`DeletionMode.moveToTrash`, recorded in Activity) before extracting; otherwise unchanged (never overwrite).
- Backups sheet: grouped by app, newest first; multi-select backups; per-backup item checklist (all checked by default); "Replace the current version" toggle (off by default, explains it moves the current copy to the Trash); Restore N.

- [ ] Failing tests: `installSourceDetection` (cask, formula, App Store receipt, package, direct), `uninstallRunsBrewZapThenDeletesRest` (runner records `brew uninstall --cask --zap token`; no sudo), `uninstallIsIrreversibleAndRecorded`, `uninstallBacksUpFirstAndAbortsOnFailure`, `settingsOnlyBackupExcludesBundleAndCaches`, `restoreSelectedItemsOnly`, `restoreReplaceMovesCurrentToTrash`, `copyPathUsesAllChecked` (pure helper `paths(for:clicked:checked:)`).
- [ ] Implement; package passes; build; commit `feat(apps): complete Uninstall, flexible backups and restore, distinct actions`.

### Task G: Startup items and Permissions you can act on (+ helper ops)

**Files:** kit `Sessions/StartupSession.swift`, `Sessions/PermissionsSession.swift`, `Helper/HelperService.swift`, `Helper/PrivilegedOperations.swift`, `Helper/HelperConnection.swift`, `Helper/HelperIdentity.swift` (bump `protocolVersion`), `Helper/HelperAllowlist.swift`; `ClenvraHelper/main.swift`; tests in `StartupSessionTests`, `PermissionsSessionTests`, `HelperServiceTests`; app `Features/Startup/StartupView.swift`, `Features/System/PermissionsView.swift`.

**Interfaces:**
- Startup: toolbar + context menu + inspector actions on the selected items (multi-select): **Disable** / **Enable** (`launchctl bootout` + `launchctl disable` / `enable` + `bootstrap` in `gui/<uid>` for own agents; `system` domain via a new helper op `setLaunchItemEnabled(_ item: DeletionItem, enabled: Bool)` that re-validates the plist snapshot), **Stop** / **Start** (exists: `stop`, `start`), **Remove…** (exists). Login items registered through Background Task Management (SMAppService) cannot be changed by another app: show "Manage in Login Items Settings" opening `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`. A Disabled badge in the list (read with `launchctl print-disabled`).
- Permissions: a visible **Revoke…** toolbar button for the selected grants (multi-select table), plus the context menu. User-scope grants: `tccutil reset <Service> <bundleID>` as today. System-scope grants: new helper op `resetPermission(service:bundleID:)` running `/usr/bin/tccutil reset` as root (allow-listed service names only). Clients without a bundle ID (paths): no revoke; the button explains and offers Open Privacy Settings.
- Helper ops are allow-listed, take only validated input (bundle ID regex, known service names, launch plist paths under `/Library/LaunchAgents|LaunchDaemons`), require the existing authorization right (admin password each time: `HelperAuthorization` right with `timeout 0`).

- [ ] Failing tests: `disableOwnAgentRunsLaunchctl` (FakeCommandRunner: `bootout gui/501 <plist>` then `disable gui/501/<label>`), `enableReverses`, `systemItemGoesThroughHelper` (fake `PrivilegedOperations`), `changedPlistIsRefused`, `readsDisabledState` (parse `print-disabled` output), `revokeSystemGrantThroughHelper`, `revokeManyReportsEach`, `pathClientCannotBeRevoked`, helper `rejectsUnknownService`, `rejectsPlistOutsideLaunchFolders`.
- [ ] Implement; package passes; build (incl. ClenvraHelper target); commit `feat(startup,privacy): disable/enable startup items, revoke permissions, helper ops`.

### Task H: Extensions — icons, quit before remove, fast scrolling

**Files:** `Clenvra/Features/Applications/PluginsView.swift`, kit `Sessions/PluginsSession.swift` (or the session the page uses), new `Clenvra/Shared/IconCache.swift` (one cache used by any list: `@MainActor final class IconCache { static let shared; func icon(forFile path: String) -> NSImage }`, NSCache keyed by path, 32 pt), tests where logic is in the kit.

**Interfaces:** each extension row shows its own bundle icon (`NSWorkspace.icon(forFile: extensionPath)`), falling back to the containing app's icon, then the generic symbol; icons come from `IconCache` (never created in `body` per render). "Quit App" / "Force Quit" for the containing app when it is running (reuse the Processes quit confirmation pattern; `NSRunningApplication.terminate()` / `.forceTerminate()`), shown when removal is blocked because the app is open. Scrolling with Apple items shown must be smooth: no per-row synchronous file I/O or sorting in `body`; precompute rows when the session changes.

- [ ] Profile first: with Apple items shown, `xctrace record --template 'Time Profiler'` is NOT allowed in this sandbox; instead read the row code and remove per-render work (file reads, `NSWorkspace.icon`, `Bundle(url:)`, sorting/filtering in `body`). Report every heavy per-render call you find in OTHER pages (file:line) without changing them.
- [ ] Failing kit tests for any new logic (e.g. `containingAppIsRunning` with a fake); implement; build; commit `perf(extensions): real icons, quit the app before removing, smooth scrolling`.

### Task J: Leftovers and Large & Old grouped

**Files:** kit `Sessions/AppsSession.swift` only for a pure grouping function in a NEW file `Apps/LeftoverGroups.swift`, `Storage/LargeFileGroups.swift`; tests `LeftoverGroupsTests.swift`, `LargeFileGroupsTests.swift`; app `Features/Applications/LeftoversView.swift`, `Features/Storage/LargeFilesView.swift`. Do not touch `ApplicationsView.swift` or `AppsSession.swift` beyond reading.

**Interfaces:** Leftovers grouped by the app they belonged to (owner name from evidence/bundle ID; "Unknown app" last), largest group first, each group a disclosure row with a group checkbox (selects its removable visible items), size and count; Expand All/Collapse All in the toolbar; search filters inside groups. Large & Old: "Group by" Kind (Videos, Images, Archives, Disk Images, Apps, Documents, Other) / Folder (top folder under home) / Age, disclosure groups with group checkbox, Expand All/Collapse All, same filters as now. Use `ExpandedGroups` + `DisclosureTableRow` as `RuleReviewView` does.

- [ ] Failing tests: `leftoversGroupByOwner`, `unknownOwnerLast`, `largeFilesGroupByKind/Folder/Age`; implement; build; commit `feat(storage,apps): grouped Leftovers and Large & Old`.

### Task K: Similar Photos — pre-selected, clear keep/remove comparison

**Files:** kit `Sessions/SimilarPhotosSession.swift`, tests `SimilarPhotosSessionTests`; app `Features/Storage/SimilarPhotos/*`.

**Interfaces:** after a scan, every non-keeper in every group is selected (the keeper never is); "Clear Selection" and "Select Suggested" in the toolbar/More menu; changing a group's keeper re-selects that group's others. Each group shows the keeper first with a "Keep" badge and the others with "Remove"; clicking a photo opens the details panel as a side-by-side comparison: the clicked photo next to the group's keeper (thumbnail, size, dimensions, date, quality), with "Keep This Instead" and "Don't Remove". Low-quality section: also pre-selected (no keeper there).

- [ ] Failing tests: `scanPreselectsAllButKeepers`, `changingKeeperMovesSelection`, `clearAndSelectSuggested`; implement; build; commit `feat(photos): suggested photos pre-selected, side-by-side keep/remove comparison`.
