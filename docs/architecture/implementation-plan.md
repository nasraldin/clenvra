# Architecture Review and Implementation Plan

**Revision 2.** Scope is all of the owner's Apple Silicon Macs, professional breadth.

## Part A: Architecture review (Phase 5)

| Perspective | Assessment | Decisions |
|---|---|---|
| Product value | The tool must earn its place on very different Macs: developer workstation, work Mac with MDM, home Mac. The first Mac's data shows developer storage dominates there. Other Macs will be dominated by photos, downloads, iOS backups and apps. | Seven intent-based sections; every integration detected at runtime; recommendations ranked per Mac. Professional breadth (duplicates, orphans, browser data, startup management, health and security) is in 1.0/1.1, not deferred indefinitely. |
| Native quality | Standard SwiftUI containers; AppKit only for Quick Look, Finder drag, `NSWorkspace`, DiskArbitration. | Unchanged |
| Performance | Main-actor I/O and cooperative-pool blocking are addressed by the FS executor. Memory is bounded per directory. Duplicates have their own I/O budget (≤ 4 readers). | Duplicates moved into 1.0 with that budget |
| Security & data safety | Identity-checked gate, fd-only irreversible removal, managed-software protection. The privileged helper is optional, pinned by Team ID and re-runs the gate with a narrower allowlist. | Helper deferred to 1.1 so the core gate is proven first |
| Maintainability | Two modules + an optional helper target, zero dependencies (Sparkle is the only candidate, decision D9). Rules as reviewed data. | Custom user rules are Review-only so they can't weaken safety |

**Contradictions resolved:**

- "All features" vs honesty: features that cannot be done honestly (antivirus, RAM cleaning, shredder) are replaced with truthful equivalents (Security checks, memory pressure, FileVault status).
- "Works on work Macs" vs cleanup power: managed items are always Protected, and the helper is never required.

**Top risks:**

| # | Risk | Mitigation |
|---|---|---|
| R1 | Ownership false positives in uninstall/orphans | Evidence tiers, shared guard, Possible never pre-selected, Trash + Restore |
| R2 | `getattrlistbulk` parsing bugs | Property tests against `lstat` ground truth |
| R3 | Tool CLI changes (pnpm, simctl, docker JSON) | Defensive parsing, show raw output, measure before/after |
| R4 | Behaviour differences across macOS 26 → future releases | VM smoke matrix per release; defensive parsing |
| R5 | Managed Macs block FDA or flag the helper | App fully useful without both; helper optional and documented |
| R6 | Breadth slows delivery | Strict release slicing (1.0 / 1.1 / 1.2); safety core first |
| R7 | Arabic quality | Glossary + native review before each release |

## Part B: Implementation plan (Phase 6)

"Done" for every task means: tests green, no warnings (strict concurrency), strings in en + ar, and VoiceOver labels present.

### Stage 1: Core engine and main sections (M0–M11)

| Milestone | Tasks | Depends on | Acceptance criteria |
|---|---|---|---|
| **M0 Skeleton** (0.5 d) | Xcode project (macOS 26, arm64, Swift 6, Hardened Runtime, no sandbox), `ClenvraKit` package, String Catalog en/ar, RTL scheme, string lint, OSLog, `ActivityLog` | — | Builds; seven sections navigable; Arabic mirrored |
| **M1 Filesystem core** (3 d) | `FSExecutor`, `BulkEnumerator`, `FixtureBuilder`, `StorageIndex` (aggregates, coalesced stream, cancel), volume list (OV-1) | M0 | Matches `lstat` ground truth; ≥ 250k entries/s warm; memory O(dirs); cancel < 200 ms |
| **M2 Safety core** (3.5 d) | Protected identities (incl. managed-software detector), path policy, exclusions, owner activity, `DeletionExecutor` (fd walk, identity, trash, post-check, fd-only irreversible), dry run, restore | M1 | **S1–S23, S26–S27 pass** |
| **M3 Shell UI** (3 d) | Review table, risk badge, size labels, LTR path label, confirm/result sheets, inspector, Quick Look, drag & drop, permission centre (SA-5), Activity (OV-5) | M2 | UI tests en/ar × light/dark; accessibility audit clean |
| **M4 Storage** (4 d) | Space map + list on any volume (ST-1), large & old (ST-2), downloads/screenshots (ST-4), duplicates (ST-3) | M1–M3 | Responsive during scan (no hang > 250 ms); duplicates confirmed byte-for-byte; clones excluded; one copy always kept |
| **M5 Cleanup** (3 d) | CL-1…CL-6 as `CategoryRule` data; browser cache adapters for 9 browsers with lock checks | M2, M3 | Unit tests per rule; running app/browser blocks its items with a reason |
| **M6 Developer** (4 d) | Tool locator + command runner; DEV-1…DEV-6, DEV-8; project artefacts with roots and inactivity | M2, M3 | Only detected tools shown; commands shown before running; before/after sizes logged; volumes/VM disks never offered |
| **M7 Applications** (5 d) | Inventory (AP-1, AP-10), ownership resolver, uninstall flow with quit, vendor uninstallers (AP-3), Homebrew casks (AP-4), orphans (AP-5), extensions & plug-ins (AP-6), protected apps (AP-8) | M2, M3 | ≥ 15 real-world-shaped fixture apps resolve correctly; S19, S20 pass; managed agents only via vendor uninstaller |
| **M8 Startup** (2.5 d) | Unified list, status, broken/orphan detection, managed marker, disable/remove user agents (SB-3), Reveal for system items, Login Items link | M7 (inventory) | Flags the orphaned CleanMyMac daemon on the first Mac; re-enable from Activity works on a fixture agent |
| **M9 System** (3 d) | Health (SY-1), heavy processes with confirmed Quit (SY-2), security checks (SY-3), Overview health summary (OV-4) | M3 | Values match Activity Monitor/System Settings; battery hidden on desktops |
| **M10 Overview & settings** (2 d) | Scan everything, recommendations (OV-2, OV-3), exclusions, developer roots, settings export/import (SA-7) | M4–M9 | Export on one Mac, import on another: same exclusions/roots; S28 passes |
| **M11 Release hardening** (3 d) | Benchmarks doc, accessibility, Arabic review, VM matrix (macOS 26 + latest), managed-Mac pass, notarised DMG | all | Test-strategy release checklist complete |

Stage 1 estimate: about 37 working days.

### Stage 2: Pro features (M12–M15, about 15 days)

| Milestone | Contents | Acceptance criteria |
|---|---|---|
| M12 Privileged helper | `SMAppService.daemon`, Team-ID-pinned XPC, gate inside helper, install/uninstall in Settings | S24, S25 pass; helper idle-exits; no KeepAlive |
| M13 System-level cleanup | System leftovers on uninstall, CL-8, SB-4, SY-4 snapshots via helper | Each falls back to Reveal without the helper |
| M14 More cleanup | Browser history/cookies (CL-7) opt-in per type, mail attachments (CL-9), temp files (CL-10), empty folders (ST-6) | Running browser blocks; sign-out warning shown |
| M15 More tools | Similar photos (ST-5), app reset (AP-7), Android SDK (DEV-7), AI model stores (DEV-9), custom rules (SA-8) | Custom rules Review-only |

### Stage 3: Convenience (M16, about 8 days)

**M16:** Scheduled scans + notifications (SA-9), menu bar extra (SY-5), app update check (AP-9, opt-in network), sunburst view (ST-7), recent items (CL-11), self-update decision (D9).

## Progress (2026-10-27)

| Area | Status |
|---|---|
| Filesystem core (bulk reader, executor, storage scanner ≈ 3.6× faster than `du`) | Done |
| Safety core (path policy, safe walk, protection policy, deletion gate, executor, restore, owner activity, live policy) | Done — safety cases S1–S8, S11–S23, S26, S28 covered by tests |
| Cleanup & Developer (rule engine, catalog, project build folders, tool adapters + commands) | Done |
| Storage (disks, browser, treemap, large & old, downloads & screenshots) | Done |
| Duplicates (staged hashing + byte compare, keep-one enforced in 4 layers) | Done |
| Applications (inventory, ownership evidence, uninstall, Homebrew, leftovers, managed agents) | Done |
| Startup (launch items, orphans, safe removal of user agents) | Done |
| System (health, heavy apps, security checks) | Done |
| Activity (history, Put Back persisted, CSV export) | Done |
| Settings (exclusions, export/import, Full Disk Access status) | Done |
| Overview (disks, read-only Scan Everything, recommendations, health line) | Done |
| Privileged helper (M12–M13), similar photos, scheduled scans, menu bar extra | Not started |
| Developer ID signing + notarisation | Waiting for the owner's personal team on this Mac |

## Part C: Decisions

| ID | Decision | Status |
|---|---|---|
| D1 | Minimum macOS | **Decided: macOS 26**, arm64 only. All of the owner's Macs run 26 or newer. No availability branches below 26. |
| D2 | Distribution | **Decided:** Developer ID signed and notarised, on the owner's **personal** paid team. During development: local signing (`Sign to Run Locally` / Apple Development). |
| D3 | Privileged helper | Optional, off by default. Its milestone runs once the personal team is signed in, because Team-ID-pinned XPC needs real signing to test end to end. |
| D4 | Browser history/cookies wiping | Opt-in per data type |
| D5 | Network features (update check) | Off by default |
| D6 | Default developer roots | `~/Sources`, `~/Developer`, `~/Projects`, `~/Code`, `~/src` (only those that exist) |
| D7 | Project inactivity threshold | 30 days (7–90 configurable) |
| D8 | Name / bundle ID | **Decided: `Clenvra` / `com.nasraldin.clenvra`** (helper `com.nasraldin.clenvra.helper`) |
| D9 | Self-update mechanism | Manual DMG first; Sparkle considered at the end |
| D10 | Apple Developer account | **Decided:** active personal account (signed in on another Mac) |
| D11 | Memory | **Decided:** honest memory view (pressure, swap, compressed, top apps, Quit). No `purge`. |
| D12 | Delivery | **Decided: full product, vertical slices.** All features of the former 1.0, 1.1 and 1.2 are built as one product. Each feature is finished end to end (engine → safety → UI → en/ar → tests) before the next starts. Milestone order is M0…M15 below; there is no separate release split. |

## Part D: Engineering practices (binding)

- **TDD:** each behaviour starts with a failing Swift Testing test in `ClenvraKit`. The UI is thin over tested models.
- **DRY by construction:** cleanup categories, browsers, developer tools and leftover locations are **data tables** consumed by one engine, one deletion gate, one review UI. New items are added as rows, not code paths.
- **Written from scratch:** no code copied from MacSai, Mole, Pearcleaner or any other app. Research is used for ideas only and cited in docs.
- **Ops-less:** zero third-party dependencies; strict concurrency; warnings as errors; defensive parsing of tool output with raw-output fallback; every failure becomes a user-readable reason, never a crash; an OSLog category per subsystem.
- **Formatting:** `swift-format` (bundled with Xcode) in lint mode in CI and a pre-commit check.
