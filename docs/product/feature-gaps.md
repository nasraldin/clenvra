# Feature gaps against competitors (2026-10-30)

What other Mac cleaners offer that Clenvra does not, and what to do about each. Read with
[`verified-feature-matrix.md`](verified-feature-matrix.md) (our plan) and
[`../research/competitor-analysis.md`](../research/competitor-analysis.md) (first research, 2026-10-27).

## Summary

- **Our own plan is complete.** Every feature in the verified matrix ships, except CL-11 (clear recent-items
  lists). The matrix also promised per-volume Trash (CL-5), but only the home Trash is cleaned today.
- **Competitors offer about 20 things we lack.** 11 fit our principles and are worth building; 3 are optional; the
  rest stay rejected (misleading, need a private API or network accounts, or delete without review).
- **Recommended for 1.1, in order:** Trash on every drive · leftovers of apps already in the Trash · broken
  preference files · disk health · Trash-size reminder · app permissions review · install updates · blurry and
  poorly lit photos · System Data explained · Homebrew and installer packages · deleted users' folders.

## Sources

Read 2026-10-30, all official pages:

| Product | Version | Source |
|---|---|---|
| CleanMyMac | 5.7.3 (29 Oct 2026) | cleanmymac.com; MacPaw knowledge base: concepts and usage, system junk list, maintenance tasks, the Menu, app permissions |
| CCleaner for Mac | 2.x | ccleaner.com/ccleaner-mac (feature and edition table) |
| App Cleaner & Uninstaller (Nektony) | 10.0.1 (20 Sep 2026) | nektony.com/mac-app-cleaner |
| Pearcleaner | 5.4.3, development on hold | github.com/alienator88/Pearcleaner README |
| DaisyDisk | 4.34.2 (10 Jul 2026) | daisydiskapp.com |

Features were not run; they are taken from the vendors' own descriptions (evidence level **P**).

## Gaps worth building

Effort: S (a day or less), M (a few days), L (a week or more). Every item keeps our rules: review before delete,
Trash first, nothing selected automatically unless it is regenerated data, public APIs only, no background process.

| # | Gap | Who has it | Why it matters | How (public API) | Risk | Effort | When |
|---|---|---|---|---|---|---|---|
| 1 | **Trash on every drive** (external and other volumes) | CleanMyMac, (our CL-5) | Deleted files on external drives keep using space; people do not know it is there | Each mounted volume's `.Trashes/<uid>`; same Trash rule per volume | M (irreversible) | S | 1.1 |
| 2 | **Leftovers of apps already in the Trash** | Pearcleaner (Sentinel), AppCleaner (SmartDelete) | Most people delete apps by dragging them to the Trash; their files stay | On opening Leftovers, read app bundles in the Trash and run the same ownership evidence; no background monitor | H (same as leftovers) | S | 1.1 |
| 3 | **Broken preference files** | CleanMyMac | A damaged `.plist` can stop an app from opening | `PropertyListSerialization` fails on files in `~/Library/Preferences`; Review, never preselected | M | S | 1.1 |
| 4 | **Disk health** (SMART status) on Health and Overview | CleanMyMac (Menu) | Early warning before a drive fails | `diskutil info -plist` (`SMARTStatus`); temperatures are left out (need the private SMC) | L | S | 1.1 |
| 5 | **Trash-size reminder** | CleanMyMac (Menu) | The Trash quietly grows to many GB | Existing scheduled scan and notification; threshold in Settings | L | S | 1.1 |
| 6 | **App permissions review** (camera, microphone, screen recording, files, Full Disk Access…) | CleanMyMac, Nektony, Pearcleaner | Privacy: see which apps can use what, revoke what is not needed | Read the TCC databases (needs Full Disk Access; the format is undocumented, so read-only and defensive); revoke with `tccutil reset <service> <bundle id>` (documented tool) or open the right Privacy pane | M | M | 1.1 |
| 7 | **Install updates**, not only find them | CleanMyMac, Nektony | Today we say an update exists and stop | Homebrew: `brew upgrade --cask <token>` shown before it runs; App Store: open the app's page; other apps: open the app so its own updater runs. Nothing is downloaded by us | M | M | 1.1 |
| 8 | **Blurry and poorly lit photos** in Similar Photos | CCleaner (Analyze Photos) | Bad shots are the easiest photos to let go | Vision `VNCalculateImageAestheticsScoresRequest` (macOS 15+: quality score and "utility" images such as screenshots of receipts); blur from image sharpness | M | M | 1.1 |
| 9 | **"System Data" explained** | DaisyDisk | The biggest question people have about storage | Space Map entry that sums snapshots, purgeable space, swap and VM files, and `~/Library` by kind; restricted folders sized through the System Helper | L | M | 1.1 |
| 10 | **Homebrew manager**: unused formulae, `brew autoremove`, `brew cleanup` | Pearcleaner | Big on developer Macs, invisible otherwise | Homebrew CLI with the command shown first, like Developer Tools | M | M | 1.2 |
| 11 | **Installer packages** (`.pkg` receipts): list, size, files; remove a package's files | Pearcleaner | Tools installed by `.pkg` leave no app to uninstall | `pkgutil --pkgs`, `--files`, `--pkg-info`; removal through the System Helper, Review only, protected-path checks | H | L | 1.2 |
| 12 | **Deleted users' home folders** (`/Users/Deleted Users/*.dmg`) | CleanMyMac | Can be many GB on shared or old Macs | List with size and date; remove through the System Helper; Review only | M | S | 1.2 |
| 13 | **Clear recent-items lists** (our CL-11) | CCleaner | Privacy, small | `NSDocumentController.clearRecentDocuments` for our app; for others only where a public setting exists. Decide whether a guided manual flow is better (open the right setting) | L | S | 1.2 |

## Optional (only if asked for)

| Gap | Who has it | Note |
|---|---|---|
| Default apps for file types | Nektony | `NSWorkspace.setDefaultApplication(at:toOpen:)` (public). Useful, but not cleanup |
| "Uninstall with Clenvra" in Finder's menu | Pearcleaner | Finder Sync or a Services menu item; adds an extension to maintain |
| URL scheme / command line for automation | Pearcleaner | `clenvra://` to open a page; never to delete without review |

## Rejected (unchanged or newly confirmed)

| Feature | Who has it | Why not |
|---|---|---|
| Malware scanning, real-time protection | CleanMyMac (Moonlock) | Needs a maintained engine; false assurance. Security checks cover what we can verify honestly |
| Free up RAM | CleanMyMac | Misleading; macOS manages memory. We show memory pressure and heavy apps instead |
| Maintenance scripts: flush DNS, reindex Spotlight, repair permissions, periodic scripts, speed up Mail, free purgeable space | CleanMyMac | Little or no benefit on modern macOS; some cause regressions; purgeable space is freed by macOS when needed |
| Remove language files, strip universal binaries | CleanMyMac, Pearcleaner | Breaks code signatures and app updates |
| Document versions (`/.DocumentRevisions-V100`) | CleanMyMac | System database of your document history; deleting it loses versions of files you still use |
| Cloud drive cleanup, email cleanup | CleanMyMac | Third-party accounts and OAuth; not on-device cleanup |
| Chrome tab manager extension | CleanMyMac | A browser extension, not a Mac app feature |
| Network traffic monitor and blocking | Nektony | Firewall apps (LuLu) do this properly; out of scope |
| CPU, disk and battery temperatures | CleanMyMac | Only through the private SMC interface |
| Automatic browser wiping and automatic Trash emptying on a schedule | CCleaner | Deletes without review. Scheduled scans only notify |
| Connected devices, Steam games | CleanMyMac, Pearcleaner | Not related to cleanup |

## What we have that they do not

Keep these visible in the product and the README:

1. Honest "frees about" sizes that account for clones and hard links (only DaisyDisk does this too).
2. Evidence for every file ("why we think this belongs to X") and a safety status per item.
3. File identity re-checked at the moment of deletion; Trash first; Put Back from Activity.
4. Developer workstation focus: Xcode, simulators, package managers, containers, AI models, each cleaned with the
   tool's own command.
5. Arabic and right-to-left layout.
6. No background process, no telemetry, no account; the System Helper is optional and removable.
