# Project status and handoff

_Last updated: 2026-10-27._

Read this first when you pick the project up on another Mac. It says where the work stands, how to get running, and what to do next.

## Where we are

All main sections are built end to end: engine, safety, UI, English and Arabic, and tests. `scripts/check.sh --ui` passes (format, about 445 package tests, Release build, UI tests in en/ar).

| Area | Status |
|---|---|
| Filesystem core (bulk reader, executor, storage scanner) | ✅ Done |
| Safety core (path policy, safe walk, protection policy, deletion gate, executor, restore, live exclusions) | ✅ Done: safety cases S1–S8, S11–S23, S26, S28 tested |
| Cleanup and Developer (rule engine, catalog, project build folders, tool commands) | ✅ Done |
| Storage (disks, browser, treemap, large and old files, Downloads and screenshots) | ✅ Done |
| Duplicates | ✅ Done |
| Applications (inventory, ownership evidence, uninstall, Homebrew, leftovers, managed agents) | ✅ Done |
| Startup (launch items, orphans, safe removal) | ✅ Done |
| System (health, heavy apps, security checks) | ✅ Done |
| Activity (history, Put Back, CSV export) | ✅ Done |
| Settings (exclusions, export/import, Full Disk Access status) | ✅ Done |
| Overview (disks, Scan Everything, recommendations, health line) | ✅ Done |
| Privileged helper, system-level cleanup (M12–M13) | ⏳ Not started: needs the personal team signed in |
| Developer ID signing and notarisation | ⏳ Waiting for the personal team on the build Mac |
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

1. **M11 release hardening.** This needs no signing:
   - Accessibility audit (VoiceOver pass on every section) and a native Arabic speaker's review of the strings.
   - The Overview scan list was just changed to a `Grid` so its columns line up. Check it in the next screenshot pass:
     `TEST_RUNNER_CLENVRA_SCREENSHOTS=1 xcodebuild test -workspace Clenvra.xcworkspace -scheme Clenvra -only-testing:ClenvraUITests/ScreenshotUITests -resultBundlePath /tmp/shots.xcresult`
     Then export the images with `xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path /tmp/shots`.
   - Rescan only the affected folder after deleting in Storage. Today it rescans the whole tree.
   - Better Homebrew detection: casks installed with a custom `--appdir`.
   - Onboarding that explains the macOS permission prompts (Full Disk Access, Automation) before they appear.
   - Benchmarks doc and a run on a managed (MDM) Mac.
2. **M15 / M16 items that need no signing:** similar photos (ST-5), scheduled scans with notifications (SA-9), menu bar extra (SY-5).
3. **Once the personal team is signed in on this Mac:** M12 privileged helper (`SMAppService.daemon`, XPC pinned to the Team ID, the deletion gate also inside the helper), then M13 system-level cleanup, then a Developer ID signed and notarised DMG.

## Known caveats

- **Vendor Team IDs in `Apps/ManagedAgents.swift`** (`X9E956P446`, `4AYE5J54KN`, `483DWKW443`, `PXPZ95SK77`) were written from memory and are not yet verified with `codesign -dv` against the real vendor apps. A wrong ID can only make Clenvra refuse to touch an agent, never remove one wrongly. Still, verify them.
- **Developer scans of very large source trees take time.** About 2M files take around 25 s, which is still about 3.6× faster than `du`. Results appear progressively, and selections are kept across rescans.
- **Live cleanup on the owner's Macs is never automatic.** Testing deletion uses temporary fixture folders only.

## Working conventions

- **TDD:** write a failing test in `ClenvraKit` first.
- **Deletion goes through one place:** `AppEnvironment.makeDeleter`, which creates the deletion gate with live exclusions and the activity log. Never create a `DeletionGate` anywhere else.
- **Strings:** after any UI text change, run `scripts/sync-strings.sh`. Then add the Arabic in `docs/engineering/translations/<task>.json` and run `python3 -I scripts/apply-translations.py <file>`. The script never overwrites existing translations unless you pass `--overwrite`. Tests fail on missing Arabic and on stale keys.
- **Shell aliases:** `cp` and `rm` are interactive aliases on the owner's Macs. Scripts use `/bin/cp` and `/bin/rm`.
- **Background agents:** briefs for delegated work are in `docs/engineering/agent-brief.md` and `ui-brief.md`. Review their output before merging.
