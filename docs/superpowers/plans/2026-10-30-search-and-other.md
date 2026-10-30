# Search Everywhere and Clutter › Other Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (A) Clutter gets an "Other" tab for screenshots, screen recordings and anything outside the other categories; Downloads lists only `~/Downloads`. (B) Every page has search as an icon at the right of the toolbar that opens a field; Overview searches the whole app.

**Architecture:** (A) filters the existing clutter list by `ClutterSource`; a new sibling page in the Clutter group. (B) uses SwiftUI `.searchable` + `.searchToolbarBehavior(.minimize)` on every page; a small `AppSearch` index in ClenvraKit ranks pages and loaded items for Overview; a `SearchRouter` hands the query to the page a result opens.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26 SDK 27), Swift Testing.

**Spec:** owner's requests of 2026-10-30 (in conversation): "all pages … search icon at the right … in Overview the search can search anything in the app … each page searches its own content"; "new tab in Clutter for others … screenshots show in Downloads and this is wrong".

## Global Constraints

Same as `2026-10-30-gap-features.md` (macOS 26 minimum, public API only, tests first with Swift Testing, `swift-format lint --strict`, no edits to `Localizable.xcstrings`, page pattern rules, no force unwraps). Search is read-only: it never selects, scans or deletes anything.

## Review Focus

1. Search text with different case, Arabic text, or leading/trailing spaces matches the same items (`localizedStandardContains` after trimming).
2. A search on a page that has not scanned yet: the page shows its Scan prompt as before, not "no results".
3. Overview search with nothing scanned yet still finds pages and installed apps.
4. Opening a result whose page was already open applies the new query (not the old one) and the query is consumed once.
5. A screenshot saved into `~/Downloads` (screenshots location = Downloads) appears in Downloads only, never twice.

---

### Task A: Clutter › Other

**Files:** `Packages/ClenvraKit/Sources/ClenvraKit/Storage/StorageModels.swift` (`ClutterFilter.source`), `StorageSession.swift` if needed; `Clenvra/App/AppSection.swift` (new case `otherClutter`: title "Other", switcher title "Other", symbol `tray`, sibling of `.largeFiles` group after `.similarPhotos`), `Clenvra/App/MainWindow.swift` (route), `Clenvra/Features/Storage/StorageView.swift` (`StoragePage.otherClutter` using list `.clutter`), `Clenvra/Features/Storage/ClutterView.swift` (takes `source: ClutterSource`), `ClenvraUITests/UITestSupport.swift` (`allSections` + `switcherPages["otherClutter"] = ("largeFiles", 4)`). Tests: `StorageSessionTests` / a new `ClutterSourceTests`.

**Interfaces:** `ClutterFilter.source: ClutterSource?` (nil = both); `matches` also checks it. Downloads page passes `.downloads`, Other passes `.screenshots`. An item is `.downloads` when its path is inside `~/Downloads` even if it is a screenshot (Review Focus 5) — confirm in `loadClutter` and test it.

- [ ] Failing tests: `filterBySource` (two items, one per source; `.downloads` keeps one, `.screenshots` the other, `nil` both); `screenshotInDownloadsCountsOnce` (screenshots folder == Downloads: the file is listed once, source `.downloads`).
- [ ] Implement; run `swift test --package-path Packages/ClenvraKit --filter <suites>`; whole package passes.
- [ ] UI: Other tab with the same layout as Downloads (grouping, age/size filters, Select All Shown), Scan prompt text "Find screenshots, screen recordings and other files that do not belong to the other tabs.", Downloads prompt drops "and your screenshots". Build the app.
- [ ] Commit `feat(clutter): Other tab; Downloads lists the Downloads folder only`.

### Task B: Search everywhere

**Files:** create `Packages/ClenvraKit/Sources/ClenvraKit/Search/AppSearch.swift` + `AppSearchTests.swift`; create `Clenvra/Shared/SearchRouter.swift`; modify every page view listed below; `Clenvra/Features/Overview/OverviewView.swift` (results); `Clenvra/App/MainWindow.swift` (inject router). Do NOT modify `ClutterView.swift` (Task A owns it; the lead adds its search after merging).

**Interfaces:**
- `public struct SearchEntry: Sendable, Hashable { title: String; subtitle: String?; keywords: [String]; destination: String /* AppSection raw value */; query: String? /* text to pre-fill on that page */ }`
- `public enum AppSearch { static func results(for text: String, in entries: [SearchEntry], limit: Int = 50) -> [SearchEntry] }` — trims; empty → `[]`; matches `title`, `subtitle` or `keywords` with `localizedStandardContains`; ranks title prefix matches first, then title contains, then subtitle/keyword; stable within a rank.
- `@Observable @MainActor final class SearchRouter { func open(_ section: AppSection, query: String?); func take(for section: AppSection) -> String? }` — `take` returns the pending query once (then nil). Injected with `.environment(router)` in `MainWindow`; `open` sets `selection`.
- Overview entries: every `AppSection` (title + keywords such as "cache", "junk", "uninstall", "disk", "privacy", "camera"), installed apps (destination `applications`, query = app name), startup items (`startup`), permission grants if loaded (`permissions`), cleanup candidates if scanned (`cleanup`/`developer`), leftovers if scanned (`leftovers`), large files if scanned (`largeFiles`), mounted disks (`disks`).

**Every page with search** gets `.searchable(text:, placement: .toolbar, prompt:)` + `.searchToolbarBehavior(.minimize)` and, on appear, `if let q = router.take(for: <its section>) { query = q }`. Pages that already search keep their filtering; add search to: Overview (global), Space Map (current folder's children by name), Similar Photos (file name), Developer Tools (tool name), Health (row titles), Processes (name), Security (check title), Snapshots (name), Mounted Disks (name), Applications (already has search; ensure minimize + router).

- [ ] Failing tests for `AppSearch`: `emptyQueryGivesNothing`, `matchesTitleCaseInsensitively` ("SAFARI" finds "Safari"), `matchesArabic` ("الكاميرا" finds an entry with that title), `prefixRanksFirst` ("Dev" ranks "Developer Junk" before "Xcode Developer Tools"), `keywordMatch` ("cache" finds System Junk via keyword), `trimsSpaces`, `respectsLimit`.
- [ ] Failing test for `SearchRouter` (app target has no unit tests: put the router's logic in the kit as `SearchHandoff` (`struct` with `mutating func open(destination:query:)` and `mutating func take(for:) -> String?`) and test there: `takeReturnsOnce`, `takeForOtherPageIsNil`, `newOpenReplacesOld`).
- [ ] Implement; tests pass; whole package passes.
- [ ] UI per page as above; Overview: while the query is non-empty, the page shows results grouped by destination (section title as header, rows with title/subtitle and the page symbol); clicking a row calls `router.open`; no results → `ContentUnavailableView.search(text:)`.
- [ ] Build the app; commit `feat(search): search on every page; Overview searches the whole app`.
