# Competitor Analysis

Evidence levels:
- **V** = verified this session (REA, bundle inspection, source code, or official page).
- **P** = official/public documentation, read but not inspected.
- **U** = general knowledge, not re-verified this session.

## 1. Products

| Product | Model | Evidence | Positioning |
|---|---|---|---|
| CleanMyMac 5.7.2 | Paid subscription; MAS + direct | V (bundle, REA) + P (cleanmymac.com, 15 Oct 2026 release; MacPaw press release) | All-in-one: Smart Care, Cleanup, Protection (Moonlock), Performance, Applications, My Clutter, Space Lens, Cloud cleanup |
| CCleaner for Mac 2.11 | Freemium | V (bundle, REA) + P (ccleaner.com/ccleaner-mac) | Cleaner, uninstaller, startup manager, duplicates (Pro), disk analyser, photo analyser, browser cleaner |
| AppCleaner 3.7.0 | Free, closed source | V (REA) | Drag-and-drop uninstaller + SmartDelete |
| Pearcleaner | Apache-2.0 **+ Commons Clause** (source-available, no monetisation) | P (GitHub README) | Uninstaller, orphan finder, Sentinel trash monitor, Homebrew adoption |
| MacSai | BSD-3 | V (source) | CleanMyMac-style GUI clone, 22 modules |
| Mole | GPL-3 | V (source) | CLI deep clean, uninstall, analyse, status |
| OnyX | Free, closed | U | Maintenance scripts, system tweaks |
| DaisyDisk | Paid | U | Sunburst storage visualiser, can show purgeable space |
| GrandPerspective / OmniDiskSweeper | Free | U | Treemap / sorted folder size browser |

## 2. Competitive feature matrix

Priority uses the four levels **Must**, **Should**, **Optional** and **Reject**. Risk and Complexity are rated L (low), M (medium) or H (high).

| Feature | Category | Products | Behaviour | User value | Implementation (macOS) | Permissions | Risk | Complexity | Priority | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Disk overview | Overview | All | Capacity, used, available, purgeable | High | `URLResourceValues.volumeAvailableCapacityForImportantUsage`, `statfs` | None | L | L | **Must** | V |
| Unified smart scan | Overview | CMM, CC, MacSai | One scan across categories → recommendations | High | Orchestrate category scanners | FDA improves coverage | M | M | **Must** (as "Scan everything" on Overview) | V/P |
| User caches cleanup | Cleanup | All | Delete `~/Library/Caches/*` | Low here (0.7 GB measured) | Allowlist + owner-running gate | None / FDA for some | M | M | **Must** (conservative) | V |
| Logs & diagnostic reports | Cleanup | CMM, MacSai, Mole | Old `.log`, `.ips`, `DiagnosticReports` | Low–Med | Age rules | Some need admin | L | L | **Must** (user scope) | V |
| Trash sizes / empty | Cleanup | CMM, MacSai | Show and empty Trash(es) | Med | `~/.Trash`, per-volume `.Trashes` | FDA for `.Trash` listing | M (irreversible) | L | **Should** | V |
| Installers & disk images | Cleanup | CMM (UnusedDiskImagesScanning), Mole | `.dmg/.pkg/.zip` installers in Downloads | Med | UTType + age + "app already installed" | None | L | L | **Must** | V |
| Developer caches | Developer | MacSai, Mole, CMM (AIToolScanning) | DerivedData, simulators, SPM, npm/pnpm/yarn, Gradle, Cargo | **Very high here** (npm 31 GB, pnpm 73 GB, CoreSimulator 17 GB) | Tool commands first (`xcrun simctl`, `pnpm store prune`, `npm cache clean`), path deletion only for disposable dirs | None | M | M | **Must** | V (measured) |
| Project artefacts | Developer | MacSai ProjectJunk, Mole purge | `node_modules`, `.build`, `target/`, `build/` in inactive projects | High (257 `node_modules` under ~/Sources) | Marker-file detection (package.json + node_modules), inactivity age | None | M | M | **Must** | V |
| Container/VM storage | Developer | MacSai DiskHogs | Docker prune, show VM disks | **Very high here** (Lima 122 GB, Arcbox 64 GB) | Show sizes; run supported prune only; never delete VM disks | None | H | M | **Should** (visibility + supported commands) | V |
| App inventory | Apps | All uninstallers | List apps, size, version, last used | High | `LSCopyApplicationURLsForBundleIdentifier`, Spotlight `kMDItemLastUsedDate`, Info.plist | None | L | L | **Must** | V |
| Uninstall with leftovers | Apps | AppCleaner, CMM, CC, Pearcleaner | Remove bundle + owned files | High | Ownership evidence (container metadata, receipts, associated IDs, exact paths) | FDA for containers | H | H | **Must** | V |
| Orphaned app data | Apps | CMM, Pearcleaner, MacSai | Data from apps no longer installed | Med | Conservative orphan rules | FDA | H | M | **Should** | V |
| App reset | Apps | CMM, MacSai | Delete prefs/caches, keep app | Low | Same as leftovers minus bundle | — | M | L | Optional | V |
| App updates | Apps | CMM, MacSai | Check Sparkle/MAS updates | Low | Appcast fetch | Network | L | M | **Reject** (out of scope, adds network) | V |
| Storage visualiser | Storage | CMM Space Lens, DaisyDisk, GrandPerspective | Interactive map / browser | High | Bulk enumeration + incremental tree | FDA for full coverage | L (read) | M | **Must** | V/U |
| Large & old files | Storage | CMM My Clutter, MacSai | Size/age filters | High | Same index | — | M | L | **Must** | V |
| Duplicates (exact) | Storage | CMM, CC (Pro), MacSai | Identical content | Med | Size → partial hash → full hash → byte compare; clone-aware | — | M | M | **Should** (v1.1) | V |
| Similar photos | Storage | CMM, CC Photos | Visual similarity | Low | Vision feature prints | Photos | M | H | Optional | P |
| Screenshots / Downloads review | Storage | CMM My Clutter | Grouped review | Med | Filters on index | — | L | L | **Should** | P |
| Startup items | Startup | CMM, CC, MacSai, Mole | Login items, Launch agents/daemons | High here (orphaned daemon found) | Parse launchd plists, `SMAppService.statusForLegacyPlist`, `openSystemSettingsLoginItems()` | Read: none; changes: admin for `/Library` | M | M | **Must** (read-only + reveal) | V |
| Browser privacy wipe | Privacy | CC, CMM, MacSai | History/cookies | Low–Med | Per-browser, profile lock checks | FDA (Safari) | H | M | Optional (v1.2, caches only first) | V |
| Malware scan | Protection | CMM (Moonlock), MacSai (XProtect sigs) | Signature scan | Low (no maintained engine) | — | — | H (false assurance) | H | **Reject** | V |
| RAM "free up" | Performance | CMM, CC | purge | Misleading | — | admin | M | L | **Reject** | P |
| Maintenance scripts (DNS flush, reindex) | Performance | CMM, OnyX, MacSai | Run system tasks | Low on modern macOS | `do shell script` admin | admin | M | L | **Reject** for v1 | V/U |
| Bundle thinning / languages | Cleanup | MacSai | Strip archs / `.lproj` | Low, breaks signatures | — | — | H | M | **Reject** | V |
| Shredder | Files | MacSai, CMM | "Secure delete" | Meaningless on APFS + SSD | — | — | M | L | **Reject** | V |
| Cloud storage cleanup | Cloud | CMM | Dropbox/Drive/OneDrive | Low | Third-party APIs | OAuth | M | H | **Reject** | V |
| Menu bar monitor | Insights | CMM, CC, MacSai | Live stats | Low (Stats app already installed) | — | — | L | M | **Reject** | V |
| Scan/cleanup history + restore | Safety | MacSai | Log + put back from Trash | High (trust) | JSON-lines log + `trashItem` resulting URL | — | L | L | **Must** | V |
| Exclusions | Safety | All | Never-touch folders | High | Persisted list checked at scan + delete | — | L | L | **Must** | V |
| Scheduled scans | Convenience | CMM, CC | Periodic scan | Low | `SMAppService` agent | — | L | M | Optional | V |

## 3. Shared, unique and missing

- **Shared by all:** cache cleanup, uninstaller, disk visualisation, startup items.
- **Unique and worth adopting:** CleanMyMac's metadata-based leftover ownership; AppCleaner's entitlement-driven group-container lookup; Mole's owner-running cache gate and sibling-install guard.
- **Missing everywhere (our differentiation):**
  1. honest *reclaimable* size (clone- and hard-link-aware);
  2. evidence shown per file ("why we think this belongs to X");
  3. file identity re-checked at delete time;
  4. a developer-workstation focus that calls the tools' own commands;
  5. RTL / Arabic support;
  6. no background processes.
