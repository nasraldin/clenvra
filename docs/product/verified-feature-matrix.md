# Verified Feature Matrix (Consolidated Feature Inventory)

**Revision 2.** Scope is for all of the owner's Apple Silicon Macs, at a professional level.

This file is both `verified-feature-matrix.md` and `feature-inventory.md`. Overlapping features were merged into one definition each. IDs are referenced across the plan.

**Evidence:**
- **V** = verified in source or binary (`docs/research/*`).
- **M** = measured on the first Mac.
- **P** = public documentation.
- **U** = general knowledge.

**Release:** `1.0`, `1.1`, `1.2`, `No`. **Helper** = needs the optional privileged helper (otherwise "Reveal in Finder" fallback).

## Overview

| ID | Feature | Sources | Behaviour | Technique / API | Permissions | Risk | Release |
|---|---|---|---|---|---|---|---|
| OV-1 | Disk summary, all volumes | All (V) | Per volume: capacity, used, free, purgeable estimate, by-category bar | `volumeAvailableCapacityForImportantUsage`, `statfs`, `DiskArbitration` for names/eject | None | L | 1.0 |
| OV-2 | Scan everything | CMM, CC, MacSai (V) | All read-only scanners, then per-section totals; lists what was skipped and why | Orchestrator | FDA optional | L | 1.0 |
| OV-3 | Recommendations | CMM (P) | Top findings ranked by "frees ≈" and safety | — | — | L | 1.0 |
| OV-4 | Health summary | CMM, CC (V) | Disk free trend, memory pressure, battery, security status at a glance | from System section | — | L | 1.0 |
| OV-5 | Activity, restore, reports | MacSai (V) | History, Put Back, export report (Markdown/CSV) | JSON-lines log | — | L | 1.0 |

## Storage

| ID | Feature | Sources | Behaviour | Technique / API | Permissions | Risk | Release |
|---|---|---|---|---|---|---|---|
| ST-1 | Space map + folder list | CMM Space Lens, DaisyDisk, GrandPerspective (V/U) | Any volume; drill down; sizes as total and "frees ≈" | `getattrlistbulk` index; SwiftUI `Canvas` treemap | FDA for full coverage | L | 1.0 |
| ST-2 | Large & old files | CMM, MacSai (V) | Size/age filters, by kind | Index + Spotlight `kMDItemLastUsedDate` | — | M | 1.0 |
| ST-3 | Exact duplicates | CMM, CC, MacSai (V) | Groups, smart "keep" choice, keep ≥ 1 always | size → head/tail hash → SHA-256 → byte compare; clone-aware | — | M | 1.0 |
| ST-4 | Downloads & screenshots review | CMM My Clutter (P) | Grouped by kind/age/source | Index + `kMDItemWhereFroms`, screenshot metadata | — | L | 1.0 |
| ST-5 | Similar photos | CMM, CC (P) | Near-duplicate images in folders (not inside Photos library) | Vision `VNGenerateImageFeaturePrintRequest` | — | M | 1.1 |
| ST-6 | Empty folders | Mole (V) | Never pre-selected | Index | — | L | 1.1 |
| ST-7 | Sunburst view | DaisyDisk (U) | Alternative visualisation | `Canvas` | — | L | 1.2 |

## Cleanup

| ID | Feature | Sources | Behaviour | Technique / API | Permissions | Risk | Release |
|---|---|---|---|---|---|---|---|
| CL-1 | User app caches | All (V) | Per-app cache folders, owner-running gate | Allowlisted roots | None / FDA | M | 1.0 |
| CL-2 | User logs & crash reports | MacSai, Mole (V) | `~/Library/Logs`, `DiagnosticReports` > 7 days | Age + type | — | L | 1.0 |
| CL-3 | Installers & disk images | CMM (V) | `.dmg/.pkg/.xip/.zip` installers; flags "app already installed" | UTType + Info inspection | — | L | 1.0 |
| CL-4 | iOS/iPadOS backups & firmware | CMM (P), Mole (V) | `MobileSync/Backup` (Review, shows device name/date), `.ipsw` in iTunes/Configurator folders (Safe) | `Info.plist` in backup | FDA | M | 1.0 |
| CL-5 | Trash | CMM, MacSai (V) | User + per-volume Trash sizes; empty (per-volume shipped 2026-10-30) | fd-based removal | FDA | M (irreversible) | 1.0 |
| CL-6 | Browser caches | CC, MacSai (V) | Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox, Zen: cache folders only | Profile-lock + running checks | FDA (Safari) | M | 1.0 |
| CL-7 | Browser history, cookies, sessions | CC, CMM (V) | Per browser, per data type, explicit opt-in; warns about sign-outs | Per-browser files, never while running | FDA | H | 1.1 |
| CL-8 | System caches & logs | MacSai, Mole (V) | `/Library/Caches`, `/Library/Logs`, old `/private/var/log` archives (allowlist) | Helper | admin | M | 1.1 (Helper) |
| CL-9 | Mail attachments (downloaded copies) | CMM, MacSai (V) | `Mail Downloads` copies only; never the mailbox | Paths | FDA | M | 1.1 |
| CL-10 | Temporary files | Mole (V) | Own `$TMPDIR` items > 3 days | Age | — | M | 1.1 |
| CL-11 | Recent items lists | CC (P) | Clear Finder/app recent lists | `NSDocumentController.clearRecentDocuments`, shared file lists where public | — | L | 1.2 |

## Developer (detected per Mac)

| ID | Feature | Sources | Behaviour | Technique / API | Risk | Release |
|---|---|---|---|---|---|---|
| DEV-1 | Xcode DerivedData, previews, module caches | MacSai, Mole (V) | Skip while building | Paths | L | 1.0 |
| DEV-2 | Simulators & runtimes | MacSai (V) | Unavailable devices; runtimes by size, removable with `simctl runtime delete` (shipped 2026-10-30) | `xcrun simctl delete unavailable`, `simctl runtime delete` | M | 1.0 |
| DEV-3 | Device support, Archives | MacSai (V) | Old DeviceSupport (Safe); Archives (Review, dSYMs) | Paths | M | 1.0 |
| DEV-4 | Package caches | MacSai, Mole (V) | npm, pnpm, Yarn, Bun, Homebrew, CocoaPods, SwiftPM, Gradle, Maven, Cargo, Go, pip/uv/conda, NuGet | Tool command first, path only where none | M | 1.0 |
| DEV-5 | Project artefacts | MacSai, Mole (V) | `node_modules`, `.build`, `target`, `build`, `dist`, `.gradle`, `Pods`, `.venv` in inactive projects | Marker files; user roots | M | 1.0 |
| DEV-6 | Containers & VMs | MacSai (V) | Docker Desktop, OrbStack, Colima, Lima, Podman, Arcbox: sizes; safe prune (build cache, dangling images) | Tool CLI only; never volumes/disks | H | 1.0 (view + safe prune) |
| DEV-7 | Android SDK & AVDs | Mole (V) | System images, build-tools, emulators | `sdkmanager`/`avdmanager` | M | 1.1 |
| DEV-8 | IDE caches | MacSai (V) | VS Code, Cursor, JetBrains, Zed caches (not settings/extensions) | Allowlisted subfolders | L | 1.0 |
| DEV-9 | AI model stores | CMM AIToolScanning/LocalModelScanning (V) | LM Studio, Ollama, Hugging Face caches: show sizes per model; delete via tool where possible | Paths + `ollama rm` | M | 1.1 |

## Applications

| ID | Feature | Sources | Behaviour | Technique / API | Permissions | Risk | Release |
|---|---|---|---|---|---|---|---|
| AP-1 | Inventory | All (V) | Icon, name, version, ID, size, last used, source (App Store / Homebrew / Setapp / direct), architecture, signature status | Info.plist, Spotlight, receipts, `SecStaticCode` | — | L | 1.0 |
| AP-2 | Uninstall with evidence | AppCleaner, CMM, CC (V) | Bundle + owned files (Certain/Likely/Possible); multi-select; drag-and-drop; running-app quit | Container metadata, associated IDs, app groups, receipts, exact paths | FDA; Helper for system files | H | 1.0 (system files 1.1) |
| AP-3 | Vendor uninstallers | Mole (V) | Detect and offer the app's own uninstaller (e.g. Adobe, Microsoft, security agents) instead of our removal | Known uninstaller paths in bundle | — | M | 1.0 |
| AP-4 | Homebrew casks | Mole (V) | `brew uninstall --cask [--zap]` | Tool CLI | — | M | 1.0 |
| AP-5 | Leftovers of removed apps | CMM, Pearcleaner, MacSai (V) | Conservative orphans, never pre-selected | Orphan rules | FDA | H | 1.0 |
| AP-6 | Extensions & plug-ins | CMM, MacSai (V) | Preference panes, QuickLook, Spotlight importers, audio plug-ins, Safari/Finder extensions (view), system extensions (view) | Paths, `pluginkit -m` (read), `systemextensionsctl list` (read) | — | M | 1.0 |
| AP-7 | Reset app | CMM, MacSai (V) | Remove prefs/caches, keep app | Subset of AP-2 | — | M | 1.1 |
| AP-8 | Protected apps | MacSai, Mole (V) | Apple apps, MDM/security agents, this app | ID + location + known agent list | — | L | 1.0 |
| AP-9 | Update check | CMM, MacSai (V) | Sparkle feeds, App Store, `brew outdated` | Network (opt-in) | Network | L | 1.2 |
| AP-10 | Unused apps | CMM, MacSai (V) | Not opened in N months | Spotlight last-used | — | L | 1.0 |

## Startup & Background

| ID | Feature | Sources | Behaviour | Technique / API | Permissions | Risk | Release |
|---|---|---|---|---|---|---|---|
| SB-1 | Unified list | CMM, CC, Mole (V) | User/system agents, daemons, privileged helpers; owner, program, schedule, status | Plist parse + `SMAppService.statusForLegacyPlist` | — | L | 1.0 |
| SB-2 | Broken / orphaned detection | Mole (V); found on first Mac (M) | Missing program; owner app not installed | `lstat`, inventory | — | L | 1.0 |
| SB-3 | Disable / remove user agents | CC, CMM (V) | `launchctl bootout gui/<uid>/<label>` + trash plist; re-enable from Activity | `Process` fixed argv | — | M | 1.0 |
| SB-4 | System daemons/agents/helpers | CC (V) | Bootout + remove orphaned ones | Helper (else Reveal) | admin | H | 1.1 (Helper) |
| SB-5 | Login items | CMM (V) | Open System Settings › Login Items; show legacy login items | `SMAppService.openSystemSettingsLoginItems()` | — | L | 1.0 |
| SB-6 | Managed items marker | — (new) | Items from MDM/security agents shown as "Managed by your organisation", not actionable | Known labels, profile-installed paths, team IDs | — | L | 1.0 |

## System

| ID | Feature | Sources | Behaviour | Technique / API | Risk | Release |
|---|---|---|---|---|---|---|
| SY-1 | Health | CMM, CC, Mole status (V) | Memory pressure, swap, CPU load, disk free, battery cycle/condition, uptime, thermal state | `host_statistics64`, `sysctl`, IOKit `AppleSmartBattery`, `ProcessInfo.thermalState` | L | 1.0 |
| SY-2 | Heavy processes | CMM, MacSai (V) | Top CPU/memory users; Quit/Force Quit (confirmed) | `proc_pid_rusage`, `NSRunningApplication` | M | 1.0 |
| SY-3 | Security checks | — (honest replacement for antivirus) | SIP, FileVault, Gatekeeper, firewall, XProtect version/date, unsigned/un-notarised apps and launch items | `csr_get_active_config`, `fdesetup status`, `spctl --status`, `SecStaticCode` | L | 1.0 |
| SY-4 | Local Time Machine snapshots | MacSai (V) | List; delete (explain impact) | `tmutil listlocalsnapshots` / `deletelocalsnapshots` | M | 1.1 (Helper) |
| SY-6 | App permissions | CMM, Nektony, Pearcleaner (V) | Review TCC grants; revoke with `tccutil reset` | SQLite read-only + `tccutil` | M | 1.1 (shipped 2026-10-30) |
| SY-5 | Menu bar extra | CMM, CC, MacSai (V) | Free space, memory, quick scan | `MenuBarExtra` (opt-in) | L | 1.2 |

## Settings, safety, convenience

| ID | Feature | Release |
|---|---|---|
| SA-1 | Review before delete, evidence and risk per item | 1.0 |
| SA-2 | Trash-first; irreversible actions labelled | 1.0 |
| SA-3 | Preview (dry run) | 1.0 |
| SA-4 | Exclusions | 1.0 |
| SA-5 | Permission centre (FDA, helper, notifications) | 1.0 |
| SA-6 | Keyboard shortcuts, Quick Look, drag & drop | 1.0 |
| SA-7 | Settings export/import (JSON) for multiple Macs | 1.0 |
| SA-8 | Custom cleanup rules (user-defined folder + age + pattern, Review only) | 1.1 |
| SA-9 | Scheduled scans + notifications (never auto-delete) | 1.2 |
| SA-10 | Optional privileged helper (install/uninstall in Settings) | 1.1 |

## Rejected

| Feature | Reason | Replacement |
|---|---|---|
| Malware/antivirus engine | Needs a maintained engine; false assurance | SY-3 Security checks |
| RAM cleaner | Misleading | SY-1 memory pressure + SY-2 |
| Maintenance scripts (DNS flush, Spotlight/LaunchServices rebuild, periodic) | Little benefit on modern macOS; LaunchServices rebuild regressions (Mole audit) | Targeted actions only |
| Bundle thinning / language removal | Breaks signed apps and updates | — |
| Shredder | Meaningless on APFS/SSD | FileVault status |
| Cloud storage cleanup | Third-party OAuth, accounts | Storage works on synced local folders |
