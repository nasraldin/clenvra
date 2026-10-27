# Project status and handoff

_Last updated: 2026-10-27 (1.0.0)._

Read this first when you pick the project up on another Mac. It says where the work stands, how to get running, and what to do next.

## Where we are

**Version 1.0.0 is feature-complete.** Every milestone M0–M16 is built end to end (engine, safety, UI, English and Arabic, tests), except CL-11 (see below). `scripts/check.sh --ui` passes: format, 720+ package tests, Release build, UI tests in English and Arabic, light and dark, and an accessibility audit of every section. GitHub Actions runs lint, package tests and a Release build on every push.

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

## Setting up on a new Mac

1. Install Xcode 27.1 or later (macOS 26+, Apple Silicon).
2. `git clone` the repo, then `open Clenvra.xcworkspace`. Always open the workspace, not the project.
3. Run `scripts/check.sh`. It should pass without changes.
4. **UI tests, one-time setup:** macOS asks for permission the first time UI tests drive the app. Run them once from Xcode (⌘U) and approve, or run `sudo DevToolsSecurity -enable`. After that, `scripts/check.sh --ui` works.
5. **Signing:** development builds use *Sign to Run Locally*. To work on the helper or on notarisation, sign in to the personal Apple Developer team in Xcode › Settings › Accounts. Then set the team on the `Clenvra` target. The bundle ID is `com.nasraldin.clenvra`, and the helper's will be `com.nasraldin.clenvra.helper`.
6. Give the app Full Disk Access for realistic manual testing.

> Session notes in `.remember/` are local to each Mac and are not in git. This file is the handoff.

## Next steps, in order

1. **Helper end to end on a real Mac:** install the DMG into /Applications, Settings › System Helper › Install, approve in System Settings › General › Login Items, press Check. Then try Cleanup › System Caches (one item), Put Back from Activity, and System › Snapshots.
2. **People, not code:** a VoiceOver pass and a native Arabic review of the strings.
3. **Other Macs:** a run on a managed (MDM) Mac, a Mac without developer tools, and macOS 26 in a VM; a Release-build benchmark (see `testing/benchmarks.md`).
4. **Publish:** merge `feat/gap-fixes-and-helper` into `main`, tag `v1.0.0`, run `scripts/release.sh`, attach the DMG to a GitHub Release.

## Known caveats

- **Vendor Team IDs in `Apps/ManagedAgents.swift`** (`X9E956P446`, `4AYE5J54KN`, `483DWKW443`, `PXPZ95SK77`) were written from memory and are not yet verified with `codesign -dv` against the real vendor apps. A wrong ID can only make Clenvra refuse to touch an agent, never remove one wrongly. Still, verify them.
- **Developer scans of very large source trees take time.** About 2M files take around 25 s, which is still about 3.6× faster than `du`. Results appear progressively, and selections are kept across rescans.
- **Unverified tool assumptions:** conda, Colima, Podman and OrbStack are not installed on this Mac. Their adapters parse output defensively, but the formats come from documentation, not a real run. OrbStack's size is read from its group container, which may trigger the macOS "access data from other apps" prompt without Full Disk Access.
- **Browser caches of uninstalled browsers** show as "in use", because Clenvra cannot tell whether an unknown app is running. The Leftovers tab is the place for those.
- **Also unverified on this Mac:** Android SDK, Ollama/LM Studio/Hugging Face, and the Sparkle/App Store/Homebrew update sources were built from documentation with canned test output.
- **UI tests trigger a folder prompt** on each fresh debug build ("access files in your Desktop folder"). Grant the debug build Desktop access once; the audit skips contrast checks while a prompt is showing.
- **The accessibility UI tests take about 12 minutes**, mostly waiting for real scans to finish.
- **Live cleanup on the owner's Macs is never automatic.** Testing deletion uses temporary fixture folders only.

## Working conventions

- **TDD:** write a failing test in `ClenvraKit` first.
- **Deletion goes through one place:** `AppEnvironment.makeDeleter`, which creates the deletion gate with live exclusions and the activity log. Never create a `DeletionGate` anywhere else.
- **Strings:** after any UI text change, run `scripts/sync-strings.sh`. Then add the Arabic in `docs/engineering/translations/<task>.json` and run `python3 -I scripts/apply-translations.py <file>`. The script never overwrites existing translations unless you pass `--overwrite`. Tests fail on missing Arabic and on stale keys.
- **Shell aliases:** `cp` and `rm` are interactive aliases on the owner's Macs. Scripts use `/bin/cp` and `/bin/rm`.
- **Background agents:** briefs for delegated work are in `docs/engineering/agent-brief.md` and `ui-brief.md`. Review their output before merging.
