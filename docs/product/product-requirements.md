# Product Requirements and Information Architecture

This file merges `product-requirements.md` and `information-architecture.md`.

**Revision 2 (2026-10-27).** The app targets **all of the owner's Macs** (work, home, others), not one machine. Scope is broadened to a professional, full-featured utility comparable to the products studied. The safety model is unchanged.

## 1. Product statement

**Clenvra** is a fast, native, full-featured macOS utility for cleaning, storage management, app management and system hygiene. It runs on any of the owner's Apple Silicon Macs, personal or company-managed, with internal or external disks. Every deletion is explained, reviewable and, where possible, recoverable.

### Design assumptions for "any Mac"

| Assumption | Consequence |
|---|---|
| Different macOS versions | **macOS 26 minimum** (decided, D1). Newer looks (Liquid Glass on 26+) come automatically from standard controls. |
| Different hardware | **Apple Silicon only (arm64)**, as all the owner's Macs are Apple Silicon. Laptops vs desktops differ only in battery features, which hide on desktops. |
| Different toolsets | Every developer/tool integration is **detected**, never assumed. Sections show only what exists on that Mac. |
| Company-managed Macs (MDM, Defender, VPN agents) | Never touch MDM profiles, security agents or their launchd jobs. Work fully as a standard user; admin-only features are optional and clearly marked. Full Disk Access may be blocked by policy, so the app degrades gracefully. |
| Multiple disks | Storage analysis on any mounted volume (internal, external, network shares read-only by default). |
| Multiple user accounts | Only the current user's data plus explicitly elevated system areas. Never other users' homes. |
| Same preferences everywhere | **Export/Import settings** (exclusions, project folders, rule choices) as a JSON file. No account, no cloud. |

### Goals

1. Find the biggest reclaimable space on any Mac in under a minute of user time.
2. Professional breadth: everything a user needs from CleanMyMac, CCleaner, AppCleaner, DaisyDisk and Pearcleaner, organised in fewer, clearer places.
3. Never delete anything the user did not see and confirm. Trash first. Explain ownership and risk.
4. No resident processes by default. No network unless a network feature is switched on. No telemetry.
5. First-class English and Arabic (RTL), light/dark, accessibility.

### Non-goals (kept, with reasons)

| Not built | Why | What we offer instead |
|---|---|---|
| Antivirus / malware removal engine | Needs a maintained detection engine and threat feed. Anything else gives false assurance. | **Security checks** (System › Security): SIP, FileVault, Gatekeeper, firewall, XProtect/MRT data version and last update, unsigned or un-notarised apps, launch items pointing to unsigned binaries. |
| "Free up RAM" | macOS manages memory; purging hurts performance. | Memory pressure, swap and top memory users with a Quit button. |
| Shredder / secure erase | Not meaningful on APFS + SSD (copy-on-write, snapshots, TRIM). | Explanation + FileVault status. |
| Bundle thinning / language removal | Modifies signed third-party apps; breaks updates. | — |

## 2. Navigation

There are seven sidebar sections, plus Activity and Settings.

```
Overview        ⌘1   disk bars (all volumes) · Scan everything · recommendations · health summary
─────────
Storage         ⌘2   disks · folder browser + treemap · large & old files · downloads & screenshots
  Duplicates         exact duplicates (own sidebar entry: its own toolbar and keep-one workflow)
Cleanup         ⌘3   system & app junk · logs/crash reports · installers · iOS backups & firmware · mail attachments · browser data · Trash
Developer       ⌘4   Xcode · simulators · package caches · project artefacts · containers & VMs · Android SDK
Applications    ⌘5   all apps · uninstall · leftovers of removed apps · reset · extensions & plug-ins · updates
Startup         ⌘6   login items · launch agents & daemons · broken/orphaned items
System          ⌘7   health (disk, memory, battery, uptime) · heavy processes · security checks · maintenance (local snapshots)
─────────
Activity             history · restore from Trash · reports
Settings        ⌘,   general · exclusions · permissions & helper · developer folders · schedule & notifications · import/export
```

### Why seven sections

- They map to **user questions**:
  - Where did my space go? (Storage)
  - What junk can go? (Cleanup)
  - What did my tools leave behind? (Developer)
  - How do I remove an app completely? (Applications)
  - What runs without me? (Startup)
  - Is my Mac healthy and secure? (System)
- Privacy (browser data) is a **Cleanup category**, not its own section.
- Performance and Protection merge into **System** because both are about state, not cleanup.
- Sections and categories with nothing to show on a given Mac collapse ("No Xcode on this Mac").

### Common interaction pattern

```
[Toolbar: Scan ▸ | Search | Filter: Safe · Review · All | Preview | Move to Trash]
┌ Grouped table (category ▸ items) ───────────────┬ Inspector (⌘I) ───────────────┐
│ ☑ Xcode DerivedData       4.2 GB   Safe          │ paths · owner · evidence ·    │
│ ☐ iOS 17 runtime          8.1 GB   Review        │ last used · frees ≈ vs total ·│
│ ⊘ Mail data               —        Protected 🔒   │ why safe/risky · Reveal ·     │
│                                                  │ Quick Look · Exclude          │
├──────────────────────────────────────────────────┴───────────────────────────────┤
│ 12 selected · frees ≈ 9.8 GB · 3 skipped (in use) ▸                              │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Pre-selection covers only **Safe** items. **Review** items are opt-in. **Protected** items are shown greyed with the reason. The confirmation sheet lists counts, sizes, irreversible actions and admin-required actions separately.

## 3. User workflows

| ID | Workflow | Summary |
|---|---|---|
| W1 | First run | Welcome → permission centre (Full Disk Access; optional helper, explained; notifications only if scheduling is enabled) → Overview → Scan everything (read-only) |
| W2 | Free space fast | Overview recommendations → jump to item → review → Move to Trash / run tool command → result with actual free-space change |
| W3 | Explore a disk | Storage → pick volume (incl. external) → space map + list → drill down → act on files/folders |
| W4 | Developer cleanup | Detected tools only; commands shown before running; project artefacts by inactivity |
| W5 | Uninstall | Drag app or select many → owned files by confidence → quit running app → Homebrew/MAS/pkg-aware removal → leftovers in system areas via helper (optional) |
| W6 | Leftovers of removed apps | Conservative orphan list, never pre-selected |
| W7 | Startup hygiene | Disable/remove user agents; system items via helper or Reveal; broken items flagged; Login Items via System Settings |
| W8 | Health & security | Read-only dashboard + one-click fixes only where Apple provides them (e.g. open FileVault settings) |
| W9 | Restore | Activity → Put Back |
| W10 | Same settings on another Mac | Settings → Export → Import on the other Mac |
| W11 | Scheduled scan (opt-in) | Weekly scan via a login agent → notification "≈ 14 GB can be cleaned" → nothing deleted automatically |

## 4. Release scope

| Release | Contents |
|---|---|
| **1.0 Core** | Overview (all volumes, Scan everything, recommendations), Storage (space map, large & old, **duplicates**, downloads/screenshots), Cleanup (app & system caches, logs/crash reports, installers, iOS backups/firmware, Trash, **browser caches**), Developer (all detected tools; containers/VMs read-only + safe prune), Applications (inventory, **uninstall with evidence**, **orphans**, extensions & plug-ins), Startup (list, broken detection, **disable/remove user agents**, system items reveal), System (health, heavy processes, security checks), Activity & restore, Settings incl. import/export. en + ar. |
| **1.1 Pro** | Optional privileged helper: system leftovers on uninstall, `/Library` caches/logs, system launch daemons, local Time Machine snapshots. Browser history/cookies (explicit opt-in per item). Similar photos. App reset. Mail attachments. Empty folders. Android SDK management. |
| **1.2 Convenience** | Scheduled scans + notifications. Menu bar extra (free space, quick scan). App updates check (opt-in network: Sparkle feeds, App Store, `brew outdated`). Treemap/sunburst alternative visualisation. |

## 5. Acceptance criteria (product level)

- Works on macOS 26 → current, on Apple Silicon, as a standard (non-admin) user, with and without Full Disk Access.
- No machine-specific paths. Every integration is detected at runtime.
- No file leaves its location without passing the deletion gate (`safety-model.md`) and explicit confirmation.
- Every item shows path, total and "frees ≈" size, owner/evidence and risk.
- Every string exists in English and Arabic. The Arabic UI mirrors correctly.
- Idle: no Clenvra process running unless the user enabled scheduling or the menu bar extra.
