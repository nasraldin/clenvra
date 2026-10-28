# UI redesign: native macOS 27 design

_2026-10-28. Owner asked for a full redesign: "modern, user friendly, easy to use, aligned with Apple's latest macOS 27 design and best practices". The owner chose to skip questions; every decision below is the builder's call unless marked **Owner**._

## Why

The app works, but it feels dated and harder than it should be:

- Navigation is hidden. Storage, System and Applications put 3–4 pages each behind segmented controls, so the sidebar shows 9 items while the app has about 17 places.
- Rows show machine text: bundle IDs (`com.google.keystone.agent.plist`) and full paths as the main line.
- Toolbars use unlabelled icons with unclear meaning (a hand, an eye, a gear that opens Settings) and the main action has no consistent place.
- Every page invents its own layout: custom rows, cards of uneven width, forms, segmented bars.
- The menu bar has only a Go menu; no View, Item or Find commands; Duplicates and Activity have no shortcut; there is no window-wide search.
- Duplicates' window title is "Clenvra" (the app name, not the page).
- Two disks with the same name (for example two mounted copies of one disk image) look identical in Storage.

## Issues found in real use

The owner's findings while cleaning the work Mac are tracked in [`docs/product/field-issues.md`](../../product/field-issues.md) (F1–F10). They are part of this redesign: scans start only on request (F3), groups collapse (F4), every row has a context menu and details in the inspector (F5, F6, F8), Downloads filters by age and size (F7), Startup Items can be stopped and started (F9), Settings becomes toolbar tabs with two-column pages (F10), and the two Space Map bugs (F1, F2) are fixed with tests first.

## Goal

A calm, confident Mac app that looks and behaves like Apple's own (Finder, Mail, System Settings, Activity Monitor) on macOS 26 and 27: standard structures, Liquid Glass from system components, one consistent page pattern, every action reachable from the toolbar, the menu bar, the keyboard and the context menu.

**Feeling:** calm and confident. Nothing is ever deleted by surprise; the app explains, then acts.

## Non-goals

- No feature changes and no new cleanup logic. ClenvraKit stays as it is (sessions, safety, rules). The redesign is the app target only, plus fixes the redesign exposes.
- No custom design kit, custom window chrome or custom colours. The system accent (the person's choice) is the only accent.
- No onboarding tour or splash. The existing permissions guide stays a one-time sheet.

## Anti-goals (a failure even if it works)

- Any path that deletes without the existing review and confirmation.
- Losing English/Arabic parity or RTL mirroring.
- Glass on content (rows, cards), glass on glass, or decoration that does not help the content.
- Breaking macOS 26: macOS 27-only APIs (glass bounce, `visibilityPriority`, `ToolbarOverflowMenu`) only behind `if #available(macOS 27, *)`.

## Constraints

- macOS 26 minimum (**Owner**), built with Xcode 27 / Swift 6.4 and every Swift 7 upcoming feature.
- Every string in the String Catalog in English and Arabic; catalog tests stay green.
- UI tests (navigation en/ar × light/dark, accessibility audit) stay green; identifiers are updated with the views.
- Deletion only through `AppEnvironment.makeDeleter`.
- Source of the rules: Apple HIG (2026), WWDC25-219/323/356/359, WWDC26-250/269/289/292, and the BAMA `mac-design`, `ux-design` and `layout-grid` guides (MIT) that cite them.

## Information architecture

One window: `NavigationSplitView` with a two-level sidebar of labelled groups. Every former segmented tab becomes its own sidebar page.

| Group | Page | Was | Symbol |
|---|---|---|---|
| — | Overview | Overview | `gauge.with.dots.needle.67percent` |
| Clean Up | System Junk | Cleanup | `sparkles` |
| | Developer Junk | Developer | `hammer` |
| | Large & Old Files | Storage › Large & Old | `doc.badge.clock` |
| | Downloads | Storage › Downloads & Screenshots | `arrow.down.circle` |
| | Duplicates | Duplicates | `plus.square.on.square` |
| | Similar Photos | Storage › Similar Photos | `photo.on.rectangle.angled` |
| Storage | Space Map | Storage › Browser | `chart.pie` |
| Applications | Applications | Applications › Installed | `square.grid.2x2` |
| | Leftovers | Applications › Leftovers | `tray.full` |
| | Extensions | Applications › Extensions | `puzzlepiece.extension` |
| | Startup Items | Startup | `power` |
| System | Health | System › Health | `heart.text.square` |
| | Processes | System › Heavy Processes | `cpu` |
| | Security | System › Security | `lock.shield` |
| | Snapshots | System › Snapshots | `clock.badge.checkmark` |
| History | Activity | Activity | `clock.arrow.circlepath` |

Builder's call: the health group is titled **System** and its first page **Health**, so no title repeats its group. Internal page identifiers keep their old names (`cleanup` is System Junk, `storage` is Space Map, `system` is Health), so navigation code and UI tests stay stable.

Group headers are standard collapsible sidebar sections. Selection and the collapsed state are restored on relaunch (`@SceneStorage`).

## The page pattern

Every list page uses one pattern, so learning one page teaches all of them:

- **Toolbar** over the content column: title (the page name) and a subtitle (count, or total size: "26 items · 2.8 GB"). Trailing: Rescan (`arrow.clockwise`, ⌘R), and the page's one completing action as the single prominent button: **Move to Trash…** on cleanup pages, **Uninstall…** on Applications, **Remove…** on Startup Items. Every toolbar button has a title, `.help` with its shortcut, and a menu bar command.
- **Content:** a SwiftUI `Table` with sortable columns. The Name column shows the app icon or the file icon and a human name ("Homebrew", "Google Updater"); the path is never the main text. Status is one badge (icon + word: Safe, Review, In Use, Protected). Size is right-aligned.
- **Inspector** (trailing, ⌃⌘I): details of the selection. The full path (with Reveal in Finder), why the item is safe or needs review, the owning app, and the last-used date. Multi-selection shows the totals.
- **Search:** one window-wide field in the trailing toolbar (⌘F) that filters the current page; the subtitle shows the result count; no results show `ContentUnavailableView.search`.
- **States:** a page never scans on its own (F3). Before the first scan: `ContentUnavailableView` with one Scan button. After a scan: the results with "Scanned 5 min ago" in the subtitle. While scanning, results appear progressively with a determinate bar in the toolbar subtitle area and Stop. After a clean: the rows leave, and the toast says what moved to the Trash with **Undo** (Put Back). The same undo lives in Edit › Undo.
- **Context menu** on every row: Reveal in Finder, Quick Look (Space), Copy Path, Exclude Folder…, and Move to Trash….
- **Keyboard:** arrows move, Space previews, ⌘⌫ moves the selection to the Trash (after confirmation), ⌘A selects all.

Non-list pages (Overview, Memory & Battery, Security) use a grouped `Form` or a grid of equal-width cards with the same 20 pt margins.

## Overview

The landing page answers "how is my Mac and what should I do?":

- Startup disk: large free-space figure plus a capacity bar (used / purgeable / free) per disk, with disks that share a name told apart by their location.
- **Scan** (prominent): runs the read-only Scan Everything; results become up to five recommendation tiles of equal width, each with its size and a button that opens its page.
- A health strip: memory pressure, disk free, battery, security status; each opens its page.

## Menu bar and commands

- `SidebarCommands()`, `ToolbarCommands()`, `InspectorCommands()`.
- **Go:** every page, ⌘1 to ⌘9 for the most used ones (Overview, System Junk, Developer Junk, Large & Old Files, Duplicates, Space Map, Applications, Startup Items, Activity).
- **Item:** Move to Trash… (⌘⌫), Reveal in Finder (⇧⌘R), Quick Look (Space), Copy Path (⌥⌘C), Rescan (⌘R). Disabled when they do not apply.
- **Edit:** Undo names the action ("Undo Move to Trash"), Select All, Find (⌘F).
- Window title names the page.

## Settings

A `Settings` window (⌘,) with toolbar tabs that each have an icon and a title (the classic Mac preferences style, as in the owner's CleanMyMac and Outlook references): **General** (appearance stays System; Full Disk Access status; update checks), **Scanning** (what Scan Everything includes, large-file and age thresholds), **Notifications** (scheduled scans, low disk space warning), **Menu Bar** (show the menu bar extra, open at login), **Exclusions** (folders never touched, custom rules, import/export), **System Helper** (status, install, remove). Each tab is a two-column page: section titles on the leading side, controls on the trailing side, explanations under the controls in secondary text. It sizes to its content. The gear button leaves the toolbar.

## Visual rules

- System colours and text styles only (`.primary`/`.secondary`/`.tertiary`; macOS sizes, nothing under 10 pt). One accent: the system accent.
- Status = icon + word, never colour alone: Safe `checkmark.shield` (green), Review `exclamationmark.triangle` (orange), In Use `app.badge.clock` (secondary), Protected `lock` (secondary).
- 4 pt grid: 20 pt window margins, 8 pt between related controls, 20 pt between groups. Control sizes from `.controlSize`.
- Liquid Glass comes from system components only. No custom backgrounds behind bars, sheets or sidebars. Equal-width cards on content get no glass.
- Standard symbols for standard actions (Trash `trash`, Reveal `folder`, Share `square.and.arrow.up`, Filter `line.3.horizontal.decrease`).
- Arabic: every page mirrors; paths and numbers stay left-to-right.

## Delivery

One slice per commit, each green on `scripts/check.sh --ui` with English/Arabic, light/dark snapshots reviewed before the next:

1. Shell: sidebar groups and pages, Go/View/Item commands, window titles, search plumbing, same-name disks told apart. Existing views are placed under the new pages (former tabs split out).
2. Shared review page (Table + inspector + toolbar + states + context menu) adopted by System Junk and Developer Junk.
3. Large & Old Files, Downloads, Duplicates, Similar Photos, Space Map on the same pattern.
4. Applications, Leftovers, Extensions, Startup Items (names and icons instead of bundle IDs).
5. System pages (Health, Processes, Security, Snapshots) and Activity.
6. Overview.
7. Settings tabs.

## Left to the builder

Exact column sets per page, the toast's appearance, the inspector contents per page, and the wording (through the glossary and the catalog).
