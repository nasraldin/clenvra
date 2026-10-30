# Multi-select, App Backup and Processes Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (C) Check several apps and remove them at once, with an optional backup that can be restored later. (D) Checkboxes for multi-select on Space Map and Developer Tools. (E) Processes show real app icons and a details panel.

**Architecture:** Logic and tests in ClenvraKit; views in the app. Removal keeps the existing deletion gate (trash-first, snapshot revalidation). Backups are plain folders the user can see in Finder.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26, SDK 27), Swift Testing, `/usr/bin/ditto`, libproc (public).

**Spec:** owner's request of 2026-10-30: "applications … multi select checkbox … remove them at once like professional apps … option to backup these apps somewhere before remove them and restore, this is important"; "space map add checkboxes for multi select, keep current selection behavior"; "developer tools need same"; "processes … show the real icon in cpu and memory … details for any item".

## Global Constraints

Same as `2026-10-30-gap-features.md`: macOS 26 minimum, public API only, tests first (Swift Testing), `swift-format lint --strict` clean, no edits to `Localizable.xcstrings`, page pattern rules (stable toolbar; `pageState` overlays; `detailsPanel` + `InspectorToggle` for details), no force unwraps, never silently elevate privileges. Tests only touch temporary folders they create; never real apps or real user data.

## Review Focus

1. Batch removal where one app is running, protected (Apple/system) or changed since review: that app is skipped and reported; the others still go; nothing is removed without the confirmation sheet listing every app.
2. Backup fails (disk full, permission denied) for one app: that app is NOT removed; the result says why.
3. Restore when the app (or any of its files) already exists at the original place: never overwrite; skip that path and report it.
4. Checked items hidden by search or filter are still listed in the confirmation sheet (the sheet lists exactly what will be removed).
5. A process that quits while its details are open: the panel says it is no longer running, no crash.

---

### Task C: Applications — check, remove several, back up and restore

**Files:** kit `Sessions/AppsSession.swift` (or a new `Sessions/AppsSession+Batch.swift`), new `Apps/AppBackup.swift`; tests `AppsBatchUninstallTests.swift`, `AppBackupTests.swift`; app `Features/Applications/ApplicationsView.swift`, `ApplicationsSheets.swift`, new `Features/Applications/AppBackupsSheet.swift`, `App/SettingsView.swift` (backup folder).

**Interfaces:**
- `AppsSession.checked: Set<InstalledApp.ID>`; `toggleChecked(_:)`, `setChecked(_:)`, `clearChecked()`. Checking never changes the table's row selection (the detail on the right) and vice versa.
- `AppsSession.uninstallChecked(backup: URL?, dryRun: Bool = false) async -> BatchUninstallResult` with `struct BatchUninstallResult { removed: [String] /*app names*/; skipped: [(name: String, reason: SkipReason)]; summary: CleanupSummary; backups: [URL] }`, `enum SkipReason { running, protected, changed, backupFailed(String) }`. For each app: build its detail as `select(_:)` does, keep the default selection (bundle + items selected by default), back up when `backup != nil` (abort that app on failure), then remove through the same path as `uninstall`. One Activity record per run.
- `enum AppBackup { static func create(app: InstalledApp, items: [String] /*absolute paths*/, in folder: URL) async throws -> URL; static func list(in folder: URL) -> [AppBackupInfo]; static func restore(_ backup: URL) async throws -> RestoreResult }`. A backup is a folder `<App Name> <version> <yyyy-MM-dd HHmm>.clenvrabackup/` holding `manifest.json` (`bundleID, name, version, created, items: [{original: String, archive: String, bytes: Int64}]`) and one `ditto -c -k --sequesterRsrc --keepParent` zip per item. `create` verifies each zip exists and is non-empty before returning; on any failure it removes its partial backup folder and throws. `restore` extracts each item with `ditto -x -k` into the original parent folder only when the original path does not exist; existing paths go to `RestoreResult.skippedExisting`. No elevation: a permission error is reported per item.
- Default folder `~/Documents/Clenvra Backups` (created on first use); Settings › Applications lets the user pick another folder (NSOpenPanel, security-scoped bookmark not needed: the app is not sandboxed — confirm in the entitlements).

- [ ] Failing tests (fixtures in temp folders with fake `.app` bundles, `AppsFixture`): `checkingDoesNotChangeSelection`, `batchRemovesEveryCheckedApp`, `batchSkipsRunningApp`, `batchSkipsWhenBackupFails` (backup folder read-only → app kept, reason `.backupFailed`), `backupRoundTrip` (create → delete originals in the temp folder → restore → identical files, incl. an executable bit and an xattr), `restoreNeverOverwrites`, `listReadsManifests` (a folder with a broken manifest is ignored).
- [ ] Implement; package passes.
- [ ] UI: a checkbox column first in the apps table (header checkbox = check all shown); toolbar "Remove N Apps…" (enabled when N > 0) and "Backups…"; the confirm sheet lists every checked app with size and a "Back up before removing" toggle (on by default) showing the folder; result sheet lists removed/skipped with reasons and a "Show Backups" button. Backups sheet: list (name, version, date, size), Restore, Show in Finder, Move Backup to Trash; restore result lists skipped paths.
- [ ] Build; commit `feat(apps): check several apps, remove them together, back up and restore`.

### Task D: Space Map and Developer Tools checkboxes

**Files:** `Clenvra/Features/Storage/StorageBrowserView.swift`, `Clenvra/Features/Review/ToolStorageSection.swift`, kit sessions they use (`StorageSession` browser selection; `ToolCleanupSession` or equivalent); tests in the matching kit test files.

**Interfaces:** Space Map: a checkbox column first, bound to the existing selection set the Move to Trash button already uses; table row selection keeps its current behaviour (details panel / navigation) and does not change the checks. Developer Tools: a checkbox per tool that has a cleanup action (others show no checkbox), header checkbox for all shown, toolbar "Clean N Tools…" running each checked tool's existing cleanup in order behind ONE confirmation that lists every tool and command; results listed per tool.

- [ ] Failing kit tests: `browserChecksAreIndependentOfRowSelection` (if the selection model lives in the kit), `toolsCleanCheckedInOrder` (FakeCommandRunner records the commands; a tool without an action cannot be checked), `toolFailureDoesNotStopOthers`.
- [ ] Implement; package passes; build; commit `feat(storage): checkboxes on Space Map and Developer Tools`.

### Task E: Processes — icons and details

**Files:** kit `System/ProcessSampler.swift` (+ new `System/ProcessDetails.swift`), tests `ProcessDetailsTests.swift`; app `Features/System/SystemView.swift` (processes part; move it to `ProcessesView.swift` if it grows).

**Interfaces:** `ProcessDetails.read(pid: pid_t) -> ProcessDetails?` (nil when the process is gone) with `pid, parentPID, name, executablePath, appBundlePath, user (uid → name), startDate, threads, cpuPercent, memoryBytes, arguments: [String]?` via `proc_pidinfo` / `proc_pidpath` / `sysctl KERN_PROCARGS2` (arguments nil when not permitted). App: icon column in both CPU and Memory lists (`NSWorkspace.icon(forFile:)` of the app bundle, else of the executable, cached per path); row selection + `InspectorToggle` opens a details panel (`ItemInspector` style) with the fields above, Show in Finder, Quit/Force Quit as the page already offers; "No longer running" when `read` returns nil.

- [ ] Failing tests: `readsOwnProcess` (`getpid()` → name, path, start date in the past, parent = `getppid()`), `goneProcessIsNil` (a pid from a child that has exited).
- [ ] Implement; package passes; build; commit `feat(processes): app icons and a details panel`.
