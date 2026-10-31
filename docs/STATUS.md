# Project status and handoff

_Last updated: 2026-10-31 (release candidate on `main`, ready for team review)._

Read this first when you pick the project up on another Mac. It says where the work stands, how to get running, and what to do next.

## Where we are

**Version 1.0.0 is a release candidate on `main`, ready for team review.** Every milestone M0–M16 and every owner feedback round (2026-10-28 to 2026-10-31) is built end to end (engine, safety, UI, English and Arabic, tests), except CL-11 (see below). Verified on 2026-10-31:

- `scripts/check.sh`: format, 899 package tests, Release build (no warnings).
- `scripts/ui-tests-vm.sh`: every page in English and Arabic × light and dark, the accessibility audit in light and dark, search on every page, the sidebar and the permissions guide.
- `scripts/e2e-helper.sh`: the notarised app in a throwaway VM installs and approves the helper, disables a Mac-wide startup daemon, and uninstalls a `.pkg` app completely (root files and installer record), one administrator password per action.
- GitHub CI is green.

**Not yet released.** There is no `v1.0.0` tag or GitHub Release yet. Build the DMG with `scripts/release.sh` from the reviewed commit.

**CI** runs `scripts/check.sh` on GitHub's `xcode-27` runner (macOS 27, Xcode 27). UI tests run only locally: hosted runners have no GUI session with Accessibility permission.

| Area | Status |
|---|---|
| Overview, Storage (treemap, sunburst, large/old, Downloads by source, similar photos), Duplicates | ✅ |
| Cleanup (caches, logs, crash reports, installers, backups, Trash, browser caches, mail attachments, temp files, empty folders, your own rules), browser history/cookies/sessions (opt-in per type) | ✅ |
| Developer (Xcode, simulators, editors, build folders, package managers, containers, Android SDK, AI models) | ✅ |
| Applications (uninstall with evidence, reset, leftovers, extensions, Homebrew, opt-in update check) | ✅ |
| Startup, System (health, processes, security, Time Machine snapshots), Activity (Put Back, re-enable, CSV/Markdown) | ✅ |
| System Helper (M12–M13): system caches/logs, orphaned system launch items, snapshots, system leftovers, Put Back | ✅ Built, unit-tested and security-reviewed. **Run it once end to end** (see next steps) |
| Settings: exclusions, export/import, permissions guide, custom rules, scheduled scans, update opt-in, menu bar extra | ✅ |
| Safety cases S1–S28 | ✅ All tested |
| Signing, notarisation, release script | ✅ `scripts/release.sh` (Developer ID, team `CZU6ZC4LYQ`, notary profile `clenvra-notary`) |
| CL-11 recent-items lists | ✖ Not implemented on purpose: macOS has no supported way, and deleting `sharedfilelist` files does not reliably clear them (the daemon rewrites them) |

How the work was done: features were built test-first, partly by delegated agents (Claude subagents, Antigravity `agy`, opencode) in separate worktrees, then reviewed, merged and re-verified here. Automated security reviews of the helper led to six fixes (forged Put Back, Trash symlinks, irreversible mode, admin-only, staged Put Back, gate before `launchctl`).

### UI redesign (2026-10-28, work Mac)

Plan: [`superpowers/specs/2026-10-28-ui-redesign-design.md`](superpowers/specs/2026-10-28-ui-redesign-design.md). Owner's findings F1–F10: [`product/field-issues.md`](product/field-issues.md) (all fixed; two partial notes there).

- **Navigation:** 18 pages in a two-level sidebar (Overview · Clean Up · Storage · Applications · System · History); no segmented tabs. Window titles name the page; Go menu with ⌘1–⌘9; View has sidebar, toolbar and inspector commands.
- **Scan on request:** no page scans when opened (F3). Each shows a Scan button first, then "Scanned 5 minutes ago".
- **System Junk / Developer Junk:** a sortable `Table` with collapsible categories, a checkbox per item (highlight shows details, the checkbox decides what is cleaned), inspector (⌃⌘I), context menu (Show Details, Show in Finder, Copy Path, Include, Exclude from Scans), one prominent Move to Trash…, search. **Developer Tools** (npm, pnpm, Docker… cleaned by their own command) is its own page.
- **Startup Items:** readable names and icons, collapsible groups, inspector, Stop / Start for this login, Remove.
- **Downloads:** Age and Size filters, Select All Shown, collapsible groups; hidden files are never listed.
- **Space Map:** folders you created at the top of home can be selected and moved to the Trash (safety model updated); disks are re-read after every cleanup; the result explains that Trash space is freed once it is emptied.
- **Settings:** toolbar tabs with icons (General, Schedule, Menu Bar, Exclusions, Custom Rules, System Helper), two-column pages, Open at Login.
- **Every list page on one pattern (2026-10-29):** Leftovers, Extensions, Large & Old Files, Duplicates and Activity are sortable tables with an inspector, search, a context menu and one prominent action. The shared parts are in `Clenvra/Shared/PagePattern.swift` (`ExpandedGroups`, `PrimaryActionButton`, `InspectorToggle`, `SelectionStatusBar`, `ItemInspector`). Applications keeps list + detail (an uninstall review needs the width), with a sortable table of apps and **Uninstall…** as the prominent action. Duplicates' Search Options moved to a popover. Similar Photos keeps its thumbnail grid with collapsible groups. Health, Security and Snapshots are grouped forms with ⌘R in the toolbar. Overview already follows the spec's non-list layout.
- **Groups everywhere (F4):** every grouped page remembers which groups are closed across launches (`GroupExpansion` in the kit, tested), and Option-click opens or closes all of them, as in Finder. Activity's history starts closed.
- **Startup inspector shows who signed the program** (Apple, Mac App Store, identified developer, ad hoc, not signed, broken), read with the public Security framework (`CodeSignature`, tested).

### Owner feedback round (2026-10-30)

- **Sidebar:** Developer (Junk · Tools) and **Clutter** (Large & Old · Downloads · Duplicates · Similar Photos) are one row each, with a switcher in the toolbar centre; the row reopens the tab used last. The sidebar button shrinks the sidebar to an icon strip; View › Hide Sidebar still hides it.
- **Toolbar:** icon-only buttons everywhere (`ToolbarLabel`), with Settings › General › Toolbar › Show names with icons. Expand All / Collapse All on every grouped page; Scan and Stop are one button (`ScanButton`).
- **No toolbar reloads:** replacing a page's list (Scan prompt → progress → results) made SwiftUI rebuild the whole toolbar 2–3 times per scan. Every list page now keeps its list and draws those states over it (`pageState`). Similar Photos is the exception (see its comment).
- **Details panel:** drawn by the page (`detailsPanel`), not `.inspector`: on macOS 27 the system inspector inside the split view's detail column collapses the sidebar for a moment every time it opens (seen in screen recordings on the owner's Mac; the macOS 26 VM does not show it). ⌃⌘I toggles it.
- **Applications** is a full-width table; the app's review opens in the details panel when an app is chosen.
- **Disk bars** only on Space Map; Large & Old has a Scan Location menu in the toolbar.
- **Security links** use the current System Settings pane IDs (`SystemSettingsPane`, tested against the installed panes). macOS has no link to the Firewall page, so that button opens Network and says to choose Firewall.
- **Accessibility audit of some pages only:** `CLENVRA_AUDIT_SECTIONS=a,b`.

### Gap features (2026-10-30)

Six features from `docs/product/feature-gaps.md`, built by six OpenCode agents in parallel worktrees from
`docs/superpowers/plans/2026-10-30-gap-features.md`, reviewed and merged by the lead:

- **Remove simulator runtimes** (Developer Tools): `xcrun simctl runtime delete <uuid>`, only for runtimes `simctl`
  marks deletable and names by UUID; Review, irreversible, confirmed.
- **Permissions** (new System page): reads both privacy databases read-only (needs Full Disk Access; a failed read
  shows "Allow Full Disk Access", never an empty list); Revoke runs `tccutil reset <service> <bundle id>` and is
  reported as done only if the grant is really gone (system-wide grants and apps that are no longer installed
  fail and open System Settings instead; seen in the VM: `tccutil` exits 64 for an unknown app and 0 for a
  system-wide grant it may not have removed).
- **Blurry or dark photos** in Similar Photos: Vision aesthetics score below −0.1 (screenshots and documents
  excluded); never preselected; a photo in a similar group keeps the keep-one rule.
- **What's in System Data** (Space Map toolbar): swap, local snapshots, simulator runtimes, purgeable space.
- **Trash on every drive** (System Junk): each writable internal or external drive's `.Trashes/<uid>`, re-read at
  every scan; disk images and network drives excluded; permanent, never preselected.
- **Leftovers of apps already in the Trash**: data of an app found in `~/.Trash` is listed even if it changed in
  the last 30 days, with the evidence "“App” is in the Trash"; an installed app's data is never listed.
- **Testing rule (owner):** destructive paths are proven only on test data: package tests with temporary
  folders and fakes, and `scripts/e2e-gap-features.sh`, which seeds a throwaway clone of the UI-test VM
  (trashed app, second drive, generated photos) and checks the files on disk afterwards.

### Owner feedback rounds (2026-10-31)

- **Applications:** multi-select and batch Uninstall; Uninstall is permanent and complete (root files through the helper, Homebrew `--zap`, installer records forgotten), with an optional backup first; backups of the whole app or its settings only, restored per item.
- **Grouped lists:** Large & Old (by kind), Leftovers (by app), Developer Tools (by category), with collapse and expand.
- **Startup Items:** Disable and Enable (Mac-wide items through the helper), Remove for own agents and orphaned Mac-wide items; when the helper is missing or out of date the page asks to install or update it. Apple and managed items explain why they cannot be changed.
- **Extensions:** third-party app extensions can be turned off and on (`pluginkit -e`); the details panel explains how to turn off or remove each kind.
- **Permissions:** Revoke for any app; **Similar Photos:** pre-selected suggestions and a side-by-side comparison; **Processes:** icons and details; **search** on every page and app-wide on Overview.
- **Sidebar:** the sidebar button brings back a sidebar hidden with View › Hide Sidebar.

### Fixed on 2026-10-28 (work Mac verification)

- **Launch freeze (serious, also hit real users):** `MenuBarExtra(isInserted:)` was bound to `@AppStorage`. MenuBarExtra writes the binding back on every scene update, so the App body re-ran forever: main thread at 100%, memory over 1 GB, beach ball, UI tests failing with "has not loaded accessibility". It happened on most launches, not all. Fixed in `1024588`; found by bisecting to `55ec750`. **Rule: never bind `MenuBarExtra(isInserted:)` without dropping no-op writes, and never put `.task` or state writes in menu-style menu bar content.**
- **Network calls during scans:** `sdkmanager --list` now hands off to Google's Android CLI, which goes online (a firewall caught it). Android packages and AVDs are read from disk now (`4f43f18`). npm, pnpm, pip and Homebrew run with their update checks off (`ea17fb6`).
- **Light-mode contrast** of the small notes in Developer tool rows (`0b73013`).
- **Tests on any Mac:** helper tests no longer assume user ID 501 (`65ca4fd`); `check.sh` signs ad hoc without the team certificate; the UI-test window is placed on the main display when several monitors are connected (`c9a614f`).

## Setting up on a new Mac

1. Install Xcode 27.1 or later (macOS 26+, Apple Silicon).
2. `git clone` the repo, then `open Clenvra.xcworkspace`. Always open the workspace, not the project.
3. Run `scripts/check.sh`. It should pass without changes. It signs with team `CZU6ZC4LYQ` when this Mac has that team's signing certificate, and ad hoc otherwise, so it also works for contributors. Verified on a second Mac (user ID 502) on 2026-10-28.
4. **UI tests run in a VM, never on your screen:** install Tart from its official release (`https://github.com/openai/tart/releases`; the Homebrew tap is broken), then `tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:27.1 clenvra-ui` (about 80 GB). `scripts/ui-tests-vm.sh` runs every UI test in that macOS 26 VM and copies `Results.xcresult` back; `CLENVRA_SCREENSHOTS=1 scripts/ui-tests-vm.sh ClenvraUITests/ScreenshotUITests` captures every page. `scripts/check.sh --ui` still works on the Mac itself but takes over the screen for about 20 minutes.
5. **Signing:** the project signs with the owner's team `CZU6ZC4LYQ` (Automatic). To run the app, the helper or `scripts/release.sh`, sign in to that team in Xcode › Settings › Accounts and download its certificates. The bundle IDs are `com.nasraldin.clenvra` and `com.nasraldin.clenvra.helper`.
6. Give the app Full Disk Access for realistic manual testing.

> Session notes in `.remember/` are local to each Mac and are not in git. This file is the handoff.

## Next steps, in order

0. **Team review** of `main`, then `scripts/release.sh`. Confirm `xcrun stapler validate .build/release/Clenvra-1.0.0.dmg` and `spctl -a -t open --context context:primary-signature -v` on the DMG both pass.
1. **Owner test on a real Mac:** install the DMG, Overview › Update Helper (or Settings › System Helper › Install), then try Uninstall, Startup Items and Extensions on items the owner chooses.
2. **People, not code:** a VoiceOver pass and a native Arabic review of the strings.
3. **Other Macs:** a run on a managed (MDM) Mac, a Mac without developer tools, and macOS 26 in a VM; a Release-build benchmark (see `testing/benchmarks.md`).
4. **Publish:** tag `v1.0.0` on `main`, attach the notarised DMG to a GitHub Release (ask the owner first; it is public).
5. **After 1.0:** verify the vendor Team IDs below, and decide whether CL-11 gets a guided manual flow instead of automation.

## Known caveats

- **Vendor Team IDs in `Apps/ManagedAgents.swift`** (`X9E956P446`, `4AYE5J54KN`, `483DWKW443`, `PXPZ95SK77`) were written from memory and are not yet verified with `codesign -dv` against the real vendor apps. A wrong ID can only make Clenvra refuse to touch an agent, never remove one wrongly. Still, verify them.
- **Developer scans of very large source trees take time.** About 2M files take around 25 s, which is still about 3.6× faster than `du`. Results appear progressively, and selections are kept across rescans.
- **Unverified tool assumptions:** conda, Colima, Podman and OrbStack are not installed on this Mac. Their adapters parse output defensively, but the formats come from documentation, not a real run. OrbStack's size is read from its group container, which may trigger the macOS "access data from other apps" prompt without Full Disk Access.
- **Browser caches of uninstalled browsers** show as "in use", because Clenvra cannot tell whether an unknown app is running. The Leftovers tab is the place for those.
- **Also unverified on this Mac:** Android SDK, Ollama/LM Studio/Hugging Face, and the Sparkle/App Store/Homebrew update sources were built from documentation with canned test output.
- **UI tests trigger a folder prompt** on each fresh debug build ("access files in your Desktop folder"). Grant the debug build Desktop access once; the audit skips contrast checks while a prompt is showing.
- **The accessibility UI tests take about 12 minutes**, mostly waiting for real scans to finish. Don't use the Mac meanwhile: the tests drive the mouse.
- **Other apps' pop-ups break the audit.** A firewall alert (LuLu) or any window over Clenvra makes the contrast audit measure the overlay and fail. Dismiss such alerts before `check.sh --ui`.
- **Live cleanup on the owner's Macs is never automatic.** Testing deletion uses temporary fixture folders only.

## Working conventions

- **TDD:** write a failing test in `ClenvraKit` first.
- **Deletion goes through one place:** `AppEnvironment.makeDeleter`, which creates the deletion gate with live exclusions and the activity log. Never create a `DeletionGate` anywhere else.
- **Strings:** after any UI text change, run `scripts/sync-strings.sh`. Then add the Arabic in `docs/engineering/translations/<task>.json` and run `python3 -I scripts/apply-translations.py <file>`. The script never overwrites existing translations unless you pass `--overwrite`. Tests fail on missing Arabic and on stale keys.
- **Shell aliases:** `cp` and `rm` are interactive aliases on the owner's Macs. Scripts use `/bin/cp` and `/bin/rm`.
- **Background agents:** briefs for delegated work are in `docs/engineering/agent-brief.md` and `ui-brief.md`. Review their output before merging.
