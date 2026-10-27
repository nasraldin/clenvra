# Project status and handoff

_Last updated: 2026-10-27 (evening)._

Read this first when you pick the project up on another Mac. It says where the work stands, how to get running, and what to do next.

## Where we are

All main sections are built end to end: engine, safety, UI, English and Arabic, and tests. `scripts/check.sh --ui` passes (format, 522 package tests, Release build, UI tests in en/ar). The app is signed with the personal team (`CZU6ZC4LYQ`, Apple Development) on this Mac.

| Area | Status |
|---|---|
| Filesystem core (bulk reader, executor, storage scanner) | ✅ Done |
| Safety core (path policy, safe walk, protection policy, deletion gate, executor, restore, live exclusions) | ✅ Done: safety cases S1–S28 all tested (S24/S25 in the helper) |
| Cleanup (app caches, logs, crash reports, installers, Trash, browser caches for 9 browsers, iPhone/iPad backups and firmware) | ✅ Done |
| Developer (Xcode, simulators, VS Code-family, JetBrains and Zed caches, project build folders, tool commands incl. Maven, NuGet, conda, SwiftPM, Docker, Podman, OrbStack, Colima, Lima) | ✅ Done |
| Storage (disks, browser, treemap, large and old files, Downloads by kind/age/source, screenshots; rescans only changed folders after a delete) | ✅ Done |
| Duplicates | ✅ Done |
| Applications (inventory, ownership evidence, uninstall, Homebrew incl. custom `--appdir`, leftovers, managed agents, extensions and plug-ins) | ✅ Done |
| Startup (launch items, orphans, safe removal, re-enable after Put Back) | ✅ Done |
| System (health, heavy apps, security checks) | ✅ Done |
| Activity (history, Put Back, CSV and Markdown export) | ✅ Done |
| Settings (exclusions, export/import, Full Disk Access status, permissions guide) | ✅ Done |
| First-launch guide to the macOS permission prompts | ✅ Done |
| Overview (disks, Scan Everything, recommendations, health line) | ✅ Done |
| Privileged helper (M12): target, allowlist, gate in the helper, pinned XPC, idle exit, install/remove in Settings | ✅ Built and unit-tested (S24, S25). End-to-end check after you approve it in System Settings is still to do |
| System-level cleanup through the helper (M13) | ⏳ Not started: route `/Library` caches/logs, system leftovers, system launch items and Put Back of helper-moved items through the helper |
| Developer ID signing and notarisation | ✅ `scripts/release.sh` builds a Developer ID signed DMG and submits it with the `clenvra-notary` keychain profile. The team's first submissions were still "In Progress" at Apple after more than an hour |
| More cleanup and tools (M14–M15), convenience (M16) | ⏳ Not started |

The milestone plan with acceptance criteria is in [`architecture/implementation-plan.md`](architecture/implementation-plan.md). Decisions D1–D12 there are final.

## Setting up on a new Mac

1. Install Xcode 27.1 or later (macOS 26+, Apple Silicon).
2. `git clone` the repo, then `open Clenvra.xcworkspace`. Always open the workspace, not the project.
3. Run `scripts/check.sh`. It should pass without changes.
4. **UI tests, one-time setup:** macOS asks for permission the first time UI tests drive the app. Run them once from Xcode (⌘U) and approve, or run `sudo DevToolsSecurity -enable`. After that, `scripts/check.sh --ui` works.
5. **Signing:** development builds use *Sign to Run Locally*. To work on the helper or on notarisation, sign in to the personal Apple Developer team in Xcode › Settings › Accounts. Then set the team on the `Clenvra` target. The bundle ID is `com.nasraldin.clenvra`, and the helper's will be `com.nasraldin.clenvra.helper`.
6. Give the app Full Disk Access for realistic manual testing.

> Session notes in `.remember/` are local to each Mac and are not in git. This file is the handoff.

## Next steps, in order

1. **M11 release hardening, what is left.** It needs people or other Macs, not code:
   - Accessibility audit (VoiceOver pass on every section) and a native Arabic speaker's review of the strings.
   - A run on a managed (MDM) Mac, and a Release-build benchmark (see [`testing/benchmarks.md`](testing/benchmarks.md); the debug build reads about 150k entries/s, the target is 250k).
2. **Release:** run `scripts/release.sh` once Apple's queue for the team clears; it notarises, staples and checks the DMG with Gatekeeper.
3. **Helper end to end:** install Clenvra from the DMG into /Applications, Settings › System Helper › Install, approve in System Settings › General › Login Items, then Check. Then **M13**: use the helper for system items (CL-8, SB-4, SY-4, system leftovers on uninstall) and for Put Back of what it moved.
4. **M14–M16:** browser history/cookies (opt-in), mail attachments, temp files, empty folders, similar photos (ST-5), app reset, Android SDK, AI model stores, custom rules, scheduled scans (SA-9), menu bar extra (SY-5), update check, sunburst view.

## Known caveats

- **Vendor Team IDs in `Apps/ManagedAgents.swift`** (`X9E956P446`, `4AYE5J54KN`, `483DWKW443`, `PXPZ95SK77`) were written from memory and are not yet verified with `codesign -dv` against the real vendor apps. A wrong ID can only make Clenvra refuse to touch an agent, never remove one wrongly. Still, verify them.
- **Developer scans of very large source trees take time.** About 2M files take around 25 s, which is still about 3.6× faster than `du`. Results appear progressively, and selections are kept across rescans.
- **Unverified tool assumptions:** conda, Colima, Podman and OrbStack are not installed on this Mac. Their adapters parse output defensively, but the formats come from documentation, not a real run. OrbStack's size is read from its group container, which may trigger the macOS "access data from other apps" prompt without Full Disk Access.
- **Browser caches of uninstalled browsers** show as "in use", because Clenvra cannot tell whether an unknown app is running. The Leftovers tab is the place for those.
- **Live cleanup on the owner's Macs is never automatic.** Testing deletion uses temporary fixture folders only.

## Working conventions

- **TDD:** write a failing test in `ClenvraKit` first.
- **Deletion goes through one place:** `AppEnvironment.makeDeleter`, which creates the deletion gate with live exclusions and the activity log. Never create a `DeletionGate` anywhere else.
- **Strings:** after any UI text change, run `scripts/sync-strings.sh`. Then add the Arabic in `docs/engineering/translations/<task>.json` and run `python3 -I scripts/apply-translations.py <file>`. The script never overwrites existing translations unless you pass `--overwrite`. Tests fail on missing Arabic and on stale keys.
- **Shell aliases:** `cp` and `rm` are interactive aliases on the owner's Macs. Scripts use `/bin/cp` and `/bin/rm`.
- **Background agents:** briefs for delegated work are in `docs/engineering/agent-brief.md` and `ui-brief.md`. Review their output before merging.
