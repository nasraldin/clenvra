# Feature gaps against competitors (2026-10-30)

What other Mac cleaners offer that Clenvra does not, checked three ways, and what to do about each. Read with
[`verified-feature-matrix.md`](verified-feature-matrix.md) (our plan) and
[`../research/competitor-analysis.md`](../research/competitor-analysis.md) (first research, 2026-10-27).

## How this was checked

| Mark | Meaning |
|---|---|
| **Vendor** | The competitor's own page says it has the feature (read 2026-10-30) |
| **Inspected** | Seen in the competitor's installed app: strings and class names in its binaries, read only, nothing launched or changed |
| **Measured** | Measured on the work Mac (macOS 27, 926 GB disk, 96 % full, 37 GB free), read only |
| **Tested** | We ran the API or command ourselves and looked at the result |

Vendor pages: CleanMyMac 5.7.3 (MacPaw knowledge base: concepts, system junk list, maintenance tasks, the Menu, app
permissions), CCleaner for Mac (product page and edition table), App Cleaner & Uninstaller 10.0.1 (Nektony),
Pearcleaner 5.4.3 (README; development on hold), DaisyDisk 4.34.2. Installed and inspected: CleanMyMac 5 (App Store
edition), CCleaner, AppCleaner 3.7.

## Summary

1. **Our own plan is nearly complete**, with one gap that matters a lot: simulator runtimes are listed but cannot be
   removed. On the work Mac that is **24.8 GB** (`sizeBytes` reported by `simctl`; an earlier draft said 44.5 GB,
   which was the size of the mounted simulator volumes, not what deleting frees).
2. **Worth building next, by measured value:** remove simulator runtimes · app permissions review · blurry and dark
   photos · "System Data" explained · Trash on every drive · leftovers of apps already in the Trash.
3. **Downgraded after checking:** disk health (Apple's internal SSD only ever reports "Verified"), broken preference
   files (none of 597 on the work Mac; CleanMyMac needs an ignore list to avoid false alarms), Homebrew manager and
   installer packages (little to gain, and most packages here belong to company-managed tools).

## Status (2026-10-30)

Rows 1–6 shipped: see `docs/superpowers/plans/2026-10-30-gap-features.md` and `docs/STATUS.md`.

## Ranked list

Effort: S (a day or less), M (a few days), L (a week or more). Every item keeps our rules: review before delete,
Trash first, public APIs and Apple's own command-line tools only, no background process.

| # | Gap | Who has it (evidence) | Measured on the work Mac | How we would build it (evidence) | Risk | Effort | Decision |
|---|---|---|---|---|---|---|---|
| 1 | **Remove simulator runtimes** (our DEV-2 promised it; only listing ships) | Our own plan (DEV-2). CleanMyMac's "Xcode junk" covers build data and indexes only (Vendor); none of the checked apps says it removes runtimes | **3 runtimes, 24.8 GB** (iOS 18.6 8.8 GB, iOS 27.0 8.1 GB, iOS 27.1 7.9 GB, from `sizeBytes`) | `xcrun simctl runtime delete <id>`, shown before it runs, Review (needed to test on that iOS version; Xcode can download it again) (Tested: `simctl runtime list -j` already parsed) | M | S | **Build now** |
| 2 | **App permissions review** (camera, microphone, screen recording, Full Disk Access, accessibility…) with revoke | CleanMyMac, Nektony, Pearcleaner (Vendor); CleanMyMac reads `TCC.db` with `SELECT * FROM access` and revokes with `/usr/bin/tccutil` (**Inspected**) | 43 apps with Full Disk Access, 11 with Accessibility, 8 with Screen Recording; camera: Brave, Teams, Zoom, Remote Desktop and others | macOS 27: Apple's `tccutil list -s <service>` lists apps per permission (**Tested**); macOS 26 has only `tccutil reset` (**Tested** in the VM), so there we read `TCC.db` read-only like CleanMyMac (needs Full Disk Access; undocumented format, parsed defensively). Revoke: `tccutil reset <service> <bundle id>` | M | M | **Build** |
| 3 | **Blurry and dark photos** in Similar Photos | CCleaner Analyze Photos (Vendor); CCleaner computes its own `blurryScore` and `darkScore` with Core Image and exposure data (**Inspected**) | Not measured: personal photos were not read | Vision `VNCalculateImageAestheticsScoresRequest` (**Tested** on Apple wallpapers: originals +0.65 to +0.79; blurred copies −0.16 to −0.20; darkened copies −0.19 to −0.42). Review only, never preselected | M | M | **Build** |
| 4 | **"System Data" explained** | DaisyDisk (Vendor) | 6.1 GB swap in use; 24.8 GB of simulator runtimes; no local snapshots | Space Map entry summing swap (`vm.swapusage`), local snapshots (`tmutil`), simulator and other disk images, purgeable space, `~/Library` by kind (**Tested**: each command returns these figures) | L | M | **Build** |
| 5 | **Trash on every drive** (our CL-5 promised it) | CleanMyMac scans `.Trashes` (**Inspected**) | 0: no external drive connected | Each mounted volume's `.Trashes/<uid>` with the existing Trash rule | M (irreversible) | S | **Build** (cheap; matters on Macs with external drives) |
| 6 | **Leftovers of apps already in the Trash** | Pearcleaner Sentinel, AppCleaner SmartDelete (Vendor) | 0 apps in the Trash today | When Leftovers opens, read app bundles in the Trash and run the existing ownership evidence; no background monitor | H (as Leftovers) | S | **Build** (cheap; common way people delete apps) |
| 7 | **Trash-size reminder** | CleanMyMac Menu (Vendor) | Trash is empty today | Existing scheduled scan and notification, threshold in Settings | L | S | Later |
| 8 | **Install updates**, not only find them | CleanMyMac, Nektony (Vendor) | 0 outdated casks, 1 outdated formula (local Homebrew data, not refreshed) | Homebrew: `brew upgrade --cask <token>` shown first; App Store: open the app's page; others: open the app so its updater runs | M | M | Later |
| 9 | **Installer packages** (`.pkg` receipts) | Pearcleaner (Vendor); CleanMyMac reads receipts (**Inspected**) | 62 non-Apple receipts, mostly company-managed (Microsoft DLP, ManageEngine, Pulse Secure) and Adobe updaters | `pkgutil --pkgs/--files/--pkg-info` to show; removal through the System Helper only | H | L | Later, show-only first |
| 10 | **Deleted users' home folders** | CleanMyMac (Vendor, **Inspected**: "Deleted Users") | None on the work Mac | List `/Users/Deleted Users/*.dmg`; remove through the System Helper | M | S | Later |
| 11 | **Clear recent-items lists** (our CL-11) | CCleaner (Vendor) | 692 KB; privacy only | Open the right setting, or clear our own list; no private API | L | S | Later |
| 12 | **Homebrew manager** (`autoremove`, `cleanup`) | Pearcleaner (Vendor) | `brew autoremove --dry-run`: nothing; cache 43 MB | Homebrew CLI, command shown first | M | M | Later (little to gain) |
| 13 | **Broken preference files** | CleanMyMac (Vendor); it keeps a "BrokenPreferencesKnowledgeBase" ignore list (**Inspected**) | **0 of 597** fail `plutil -lint` | `PropertyListSerialization`; would need an ignore list too | M | S | Drop for now |
| 14 | **Disk health** | CleanMyMac Menu (Vendor; no SMART strings found, **Inspected**) | Internal Apple SSD: `SMARTStatus` is only "Verified"; no wear figure | `diskutil info -plist` (**Tested**). Wear and temperature need private interfaces | L | S | Drop (no useful signal on Apple Silicon) |

**Found while measuring, not in any competitor list:** eight disk images were left mounted (six copies of
"Clenvra 1.0.0", two of "Kiro CLI"). They use no extra disk space beyond their `.dmg` files, which Installers already
covers, so this is at most an "Eject" button. Not planned.

## Optional (only if asked for)

| Gap | Who has it | Note |
|---|---|---|
| Default apps for file types | Nektony (Vendor) | `NSWorkspace.setDefaultApplication(at:toOpen:)`. Useful, but not cleanup |
| "Uninstall with Clenvra" in Finder's menu | Pearcleaner (Vendor) | Finder Sync or a Services item; one more extension to maintain |
| URL scheme for automation | Pearcleaner (Vendor) | `clenvra://` to open a page; never to delete without review |

## Rejected

| Feature | Who has it | Why not |
|---|---|---|
| Malware scanning, real-time protection | CleanMyMac (Moonlock) | Needs a maintained engine; false assurance. Security checks cover what we can verify |
| Free up RAM | CleanMyMac | Misleading; macOS manages memory |
| Maintenance scripts: flush DNS, reindex Spotlight, repair permissions, periodic scripts, speed up Mail, free purgeable space | CleanMyMac | Little or no benefit on modern macOS; purgeable space is freed by macOS when needed |
| Remove language files, strip universal binaries | CleanMyMac (**Inspected**: `lipo`, `.lproj` code), Pearcleaner | Breaks code signatures and app updates |
| Document versions (`/.DocumentRevisions-V100`) | CleanMyMac (Vendor) | The history of documents you still use |
| Cloud drive cleanup, email cleanup | CleanMyMac | Third-party accounts; not on-device cleanup |
| Chrome tab manager extension | CleanMyMac | A browser extension, not a Mac app feature |
| Network traffic monitor and blocking | Nektony | Firewall apps do this properly |
| CPU, disk and battery temperatures | CleanMyMac | Only through private interfaces |
| Automatic browser wiping, automatic Trash emptying | CCleaner (Pro) | Deletes without review |
| Connected devices, Steam games | CleanMyMac, Pearcleaner | Not cleanup |

## What we have that they do not

1. Honest "frees about" sizes that account for clones and hard links (DaisyDisk also does this).
2. Evidence for every file and a safety status per item.
3. File identity re-checked at deletion; Trash first; Put Back from Activity.
4. Developer workstation focus, each tool cleaned with its own command.
5. Arabic and right-to-left layout.
6. No background process, no telemetry, no account; the System Helper is optional.

## Limits of this check

- Measured on one Mac (the work Mac). The home Mac may differ, for example external drives or more photos.
- Competitor implementations were inferred from strings and class names, not traced through code.
- Photo scoring was tested on Apple's wallpapers and degraded copies, not on real photo libraries.
