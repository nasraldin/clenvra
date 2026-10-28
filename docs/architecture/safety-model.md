# Safety Model

This document takes priority over every other doc. If a feature conflicts with it, the feature changes.

## 1. Principles

1. **Scan → classify → review → confirm → act → log.** No step is skipped. There is no "auto clean".
2. **Only scanned items can be deleted.** The executor accepts `DeletionPlan` entries that carry the scan-time `FileIdentity` and the rule that produced them. Arbitrary paths (drag-and-drop, typed paths) go through a scan first.
3. **Trash first.** Every file deletion moves to the Trash, except for these three:
   - emptying the Trash (CL-4);
   - tool commands that manage their own storage (DEV-2/4/6);
   - nothing else.

   These are labelled *irreversible* and get a separate confirmation.
4. **Fail closed.** "Unknown" (can't read, can't tell if running, can't resolve owner) means **skip**, with a reason shown.
5. **A safe partial result beats an unsafe complete one.** One failure never aborts unrelated items. An identity anomaly *does* stop the batch.
6. **No silent elevation.** Root-owned items are revealed in Finder unless the user has installed the optional helper (1.1). Even then, every elevated action is listed as "needs administrator" in the confirmation sheet, and the helper re-runs this whole gate with a narrower allowlist (`technical-architecture.md` §6a).
7. **Never fight the organisation.** Items belonging to MDM, configuration profiles or security/VPN agents are Protected ("Managed by your organisation") on every Mac.

## 2. Risk classes

| Class | Meaning | Default selection | Examples |
|---|---|---|---|
| **Safe** | Regenerated automatically; no user content; owner not running | Selected | DerivedData, unavailable simulators, app caches of non-running apps, logs > 7 days |
| **Review** | Recoverable but costs something (re-download, re-login, slower build) or user content possible | Not selected | Simulator runtimes, Xcode Archives, installers in Downloads, large/old files, project artefacts of active projects, possible app leftovers |
| **Protected** | Never deleted by this app; shown greyed with reason | Not selectable | See §3 |
| **Irreversible** (modifier) | Action bypasses Trash | Never pre-selected | Empty Trash, `pnpm store prune`, `npm cache clean`, `simctl runtime delete`, Docker prune |

## 3. Protected (never delete)

All checks compare **file identity (dev, inode)** where a path is given, so case variants and firmlinks (`/var` ↔ `/private/var`) cannot slip through.

- **System:** `/`, `/System`, `/usr`, `/bin`, `/sbin`, `/private` (except user `$TMPDIR` items in a later release), `/Library/Apple`, `/Library/Keychains`, `/Library/Extensions`, `/Applications` itself, `/System/Applications/**`, `/Users`, `/Volumes`.
- **Home roots:** `~` itself, the folders macOS and the shell put in every home (`Applications`, `Desktop`, `Documents`, `Downloads`, `Library`, `Movies`, `Music`, `Pictures`, `Public`, `Sites`, `.Trash`, `.config`, `.local`, `.cache`), and every top-level folder of `~/Library`. Their *contents* can be candidates; the folders themselves never are. Folders the person created at the top of their home (`~/flutter`, `~/Sources`) are not structural: they can be selected on purpose in Space Map, reviewed, confirmed and moved to the Trash (field issue F1, 2026-10-28). Secrets inside any folder stay protected by the name rules below.
- **Secrets and identity:**
  - folders: `~/Library/Keychains`, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker` (config), `~/.config` *root*, `~/.local` *root*, `~/.cache` *root*;
  - files: `*.keychain-db`, `id_*`, `*.pem`, `*.p12`, `.netrc`, `.npmrc`, `.pypirc`, `credentials*`.
- **User data stores:**
  - browser profile folders (only their `Cache`/`Code Cache`/`GPUCache` children are eligible, in 1.1);
  - `~/Library/Mail`, `Messages`, `Photos Library.photoslibrary`, `Mobile Documents` (iCloud Drive), `CloudStorage/*`;
  - any `*.sqlite`/`*.db` outside cache roots.
- **Developer state:** Docker/Lima/Colima/OrbStack/Arcbox disk images and volumes, `.git` folders, simulator *data* of booted devices, `~/.android/avd/*.avd` (later: via `sdkmanager`/`avdmanager` only), Xcode Archives (Review, never Safe).
- **Files with protective flags:** `UF_DATAVAULT`, `SF_RESTRICTED`, `UF_IMMUTABLE`/`SF_IMMUTABLE`, `SF_NOUNLINK`. Also anything whose parent is not writable by the process (MacSai `CleanFilter` idea), shown as "System-managed".
- This app's own bundle and data; Apple apps (`com.apple.*` bundle IDs).
- **Managed and security software:** configuration profiles (`/Library/Managed Preferences`, `/var/db/ConfigurationProfiles`), MDM agents, endpoint security / antivirus, VPN and network extensions, and their launch items and support folders. Detected by program Team ID, system-extension list and known labels. Uninstall is offered only through the vendor's own uninstaller.
- **Other users' home folders** and Time Machine backup volumes.
- **User exclusions** (Settings), applied at scan time *and* delete time.

## 4. Deletion gate (per item, run at execution time)

```
input: PlanItem { path, identity(dev, ino, type, mtime, size), ruleRoot, rule, ownerCheck }
1. Path sanity     absolute; no NUL/control chars; no "." or ".." components; ≤ PATH_MAX
2. Root containment  path is strictly below ruleRoot (component-wise), never equal to it
3. Safe walk       open("/", O_DIRECTORY|O_NOFOLLOW) then openat(each component, O_DIRECTORY|O_NOFOLLOW)
                   → any symlinked ancestor fails ELOOP/ENOTDIR → SKIP("path changed")
4. Same volume     fstat(parentFD).st_dev == identity.dev == ruleRoot.dev   (no mount crossing)
5. Identity        fstatat(parentFD, leaf, AT_SYMLINK_NOFOLLOW) equals scan identity
                   (dev, ino, type; mtime/size for regular files) → else SKIP("changed since scan")
                   leaf symlink → only the link itself is eligible
6. Protection      leaf identity ∉ protected identities; for directories, no protected identity
                   is a descendant (checked via the precomputed protected set's paths + identity)
7. Flags           none of the protective flags in §3
8. Exclusions      not inside a user exclusion — read from the app's live PolicyProvider on every check,
                   so exclusions added after a scan (or after a section opened) still apply
9. Owner activity  if rule.ownerCheck: owner app not running (NSRunningApplication by bundle ID)
                   and no process image path inside the owner bundle (proc_listallpids + proc_pidpath);
                   cannot determine → SKIP("may be in use")
10. Execute        trash: FileManager.trashItem(at:resultingItemURL:)
                   irreversible: fd-based recursive unlinkat() from parentFD (never re-resolves the path)
11. Post-check     trash: lstat(resultingURL) dev/ino == identity → else ANOMALY: stop batch, log, alert
12. Log            append ActivityLog record (outcome, sizes, resulting URL, reason)
```

**Residual race (documented):** `trashItem` is path-based. Between step 5 and step 10 a same-user process could swap the path. Two things bound this:

1. the gate runs immediately before each move;
2. the post-check (step 11) detects a swap. The swapped object is then in the Trash, so it is recoverable and nothing was destroyed.

Irreversible removal uses only fds (step 10), so it has no such window.

## 5. Ownership and shared files

- Uninstall candidates carry `Evidence` (see `technical-architecture.md` §3.4). **Certain** items are pre-selected; **Likely** items are pre-selected only when no other installed app is related; **Possible** items are never pre-selected.
- **Shared guard:** keep an item if another installed app shares the bundle-ID lineage (`a == b`, `a` a dotted prefix of `b` or the reverse) or the app group. Keep the item if the inventory is incomplete (unreadable volume, timeout), because "no other owner" must be proven.
- Never-flag owner prefixes for orphans (1.1): `com.apple.`, `org.chromium.`, `com.google.keystone`, `com.github.electron`, `com.electron.`, `org.qt-project.`, `io.qt.`, `com.microsoft.autoupdate`, `org.sparkle-project`. This list comes from MacSai `OrphanedAppFiles.swift:28-36`, as an idea.
- An orphan must also look like a reverse-DNS ID (≥ 3 components) and be untouched for ≥ 30 days.

## 6. Cache-specific rules

- A cache folder is skipped while its owner runs. For SQLite families (`x.db`, `x.db-wal`, `x.db-shm`), all members are treated together.
- Browser caches (1.1): the browser is not running **and** the profile lock is free (`SingletonLock` absent via `lstat` for Chromium; `fcntl(F_GETLK)` on `.parentlock` for Firefox).
- Never treat a whole `~/Library/Caches` root as one item. Items are its children.

## 7. Tool-managed storage

- Prefer the tool's command over deleting its internal files.
- Commands run with fixed argv and the absolute tool path, with no shell. The UI shows the command before it runs.
- Destructive commands that touch **user data** are never offered: `docker volume prune`, `docker system prune --volumes`, `limactl delete`, `simctl erase`.

## 8. Confirmation and disclosure

- The confirmation sheet shows: number of items, total *private* size ("frees ≈"), the list of irreversible actions, and "Show all paths". The default button is the non-destructive choice when anything irreversible is included.
- If the selection exceeds 20 GB or 10,000 items, an extra line asks the user to confirm the amount.
- Results show the actual change in volume free space, which can differ because of snapshots and purgeable space, with an explanation.

## 9. Audit

Every operation is written to `activity/*.jsonl` before (intent) and after (outcome) each item. Logs are append-only from the app's point of view and readable in Activity. Paths are stored in full (local only).

## 10. Required test cases before any destructive code merges

Each case is a Swift Testing test on a temp fixture (`FixtureBuilder`).

| # | Case | Expected |
|---|---|---|
| S1 | Leaf is a symlink to `~/Documents/x` | Only the link is trashed; the target is untouched |
| S2 | Ancestor replaced by a symlink after scan | SKIP "path changed"; nothing moved |
| S3 | File replaced (new inode) after scan | SKIP "changed since scan" |
| S4 | File modified after scan | SKIP |
| S5 | Directory is a mount point / different `st_dev` | SKIP |
| S6 | Path equals rule root | Rejected at plan build |
| S7 | `/SYSTEM`, `/private/var/db` case and firmlink variants | Protected |
| S8 | Hard link: one of two links deleted | Item moved; "frees ≈ 0" shown at review |
| S9 | APFS clone (`clonefile`) of a big file | Private size ≈ 0; not counted as reclaimable |
| S10 | Permission denied (chmod 000 parent) | Filtered at scan as "System-managed"; if reached, error recorded, batch continues |
| S11 | `UF_IMMUTABLE` file | Protected |
| S12 | Owner app running (test double runner) | SKIP "in use" |
| S13 | Owner check fails to enumerate processes | SKIP |
| S14 | Cancellation mid-batch | Completed items logged; remaining untouched; no partial directory removal |
| S15 | Trash unavailable (simulated `trashItem` error) | Error; **no fallback to permanent** |
| S16 | Post-check identity mismatch (injected) | Batch stops; anomaly logged |
| S17 | Irreversible recursive removal with a symlink inside the tree | Symlink unlinked, not followed |
| S18 | Exclusion added between scan and delete | SKIP |
| S19 | Shared group container claimed by two apps | Not pre-selected for either |
| S20 | Name-only match ("Possible") | Never pre-selected |
| S21 | Protected secret file inside a selected cache dir (e.g. `id_rsa`) | Whole dir becomes Review + warning (deny on contained secrets) |
| S22 | Restore when the original path is occupied | Refused with reason |
| S23 | Item owned by a managed/security agent (fixture Team ID) | Protected, not selectable |
| S24 | Helper receives a path outside its allowlist | Refused by the helper even though the app sent it |
| S25 | Helper XPC client with the wrong signature (test build signed ad hoc) | Connection rejected |
| S26 | Duplicate group where every copy is selected | At least one copy is always kept |
| S27 | Item on an external volume, then the volume is ejected before deletion | SKIP "volume unavailable" |
| S28 | Imported settings containing a protected path as a "custom rule" root | Import rejects that rule |
