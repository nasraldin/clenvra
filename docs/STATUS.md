# Project status and handoff

_Last updated: 2026-10-28 (1.0.0 on `main`, plus fixes found while verifying it on the work Mac)._

Read this first when you pick the project up on another Mac. It says where the work stands, how to get running, and what to do next.

## Where we are

**Version 1.0.0 is feature-complete and merged into `main`** (PR #1, branch `feat/gap-fixes-and-helper`). Every milestone M0–M16 is built end to end (engine, safety, UI, English and Arabic, tests), except CL-11 (see below). **`scripts/check.sh --ui` passes on the work Mac (2026-10-28):** format, 718 package tests, Release build, 7 UI tests (navigation in English and Arabic × light and dark, accessibility audit in light and dark). The earlier "UI tests passed" claim of 2026-10-27 was made before the menu bar extra landed, and the app froze at launch after that (see below).

**Not yet released.** There is no `v1.0.0` tag or GitHub Release yet. A signed but **not notarised** `.build/release/Clenvra-1.0.0.dmg` exists locally (local build output, not in git): notarisation failed because the keychain was locked at the time. The `clenvra-notary` profile works again, so re-running `scripts/release.sh` should produce the notarised, stapled DMG.

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
- **Not redesigned yet** (work as before, on the new navigation): Overview, Applications, Leftovers, Extensions, Duplicates, Similar Photos, Large & Old Files, Health, Processes, Security, Snapshots, Activity. They move to the same table + inspector pattern next.

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

0. **Unlocked Mac:** run `scripts/check.sh --ui`, then `scripts/release.sh`. Confirm `xcrun stapler validate .build/release/Clenvra-1.0.0.dmg` and `spctl -a -t open --context context:primary-signature -v` on the DMG both pass.
1. **Helper end to end on a real Mac:** install the DMG into /Applications, Settings › System Helper › Install, approve in System Settings › General › Login Items, press Check. Then try Cleanup › System Caches (one item), Put Back from Activity, and System › Snapshots.
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
