<div align="center">

# Clenvra

**A native macOS app for storage, cleanup, app management and system health, built so that it never deletes something you didn't review.**

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black?logo=apple)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![Languages](https://img.shields.io/badge/languages-English%20%7C%20العربية-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

---

Clenvra finds what fills your Mac: caches, logs, developer build data, duplicates, leftovers from removed apps, forgotten startup items. You choose what to remove. Everything goes to the Trash first, every action is recorded, and anything moved can be put back.

> **Status:** 1.0. Signed and notarised builds are on the Releases page; you can also build from source. See [`docs/STATUS.md`](docs/STATUS.md).

## Features

| Section | What it does |
|---|---|
| **Overview** | Free space on every disk, one read-only *Scan Everything*, the five most useful recommendations, and a health line |
| **Storage** | Folder browser with treemap or sunburst for any disk, large and old files, Downloads (by kind, age or website) and screenshots, and **similar photos** found with Vision |
| **Duplicates** | Finds identical files (size, then partial hash, full hash, then byte-by-byte compare). One copy is always kept |
| **Cleanup** | App caches, logs, crash reports, installers and disk images, iPhone/iPad backups, browser caches, mail attachment copies, temporary files, empty folders, Trash, your own review-only rules; browser history, cookies and sessions (opt-in per type); system caches and logs through the optional System Helper |
| **Developer** | Xcode data, simulators, package caches, editor caches (VS Code family, JetBrains, Zed), build folders in your projects (`node_modules`, `target`, `.build`…), Android SDK and emulators, AI models (Ollama, LM Studio, Hugging Face), plus the tools' own clean commands (npm, pnpm, Yarn, Bun, Homebrew, pip, Go, NuGet, conda, SwiftPM, Docker, Podman and more) |
| **Applications** | Every installed app with size and last use; complete uninstall including leftovers, with evidence for why each file belongs to the app; **reset** an app; Homebrew casks; orphaned files from apps already removed; extensions and plug-ins; opt-in update check |
| **Startup** | Launch agents, daemons and login items in one list; flags items whose app is gone and removes them safely (system items through the System Helper) |
| **System** | Memory pressure, swap, CPU, battery, apps using the most resources (with Quit), security checks (FileVault, firewall, Gatekeeper, SIP), and local Time Machine snapshots |
| **Activity** | A record of everything Clenvra did, with **Put Back** for items moved to the Trash, re-enabling of startup items, and CSV or Markdown export |

Also:

- **Excluded folders** that Clenvra never lists or touches. You can export them to a file and import them on your other Macs.
- **Optional System Helper** for system-wide caches, logs, startup items and snapshots. It runs only while working, acts only on a short list of system folders, checks every item again itself, and accepts only Clenvra signed by the developer.
- **Scheduled scans** that only report, and an optional **menu bar** extra.
- **Full English and Arabic** with a mirrored right-to-left layout.
- **Light and dark mode**, VoiceOver labels, and keyboard shortcuts.

## Safety model

Cleanup apps can do real damage. Clenvra treats deletion as the most dangerous thing it does, and every removal passes through one **deletion gate** (12 checks):

- **Trash first.** Items are moved to the Trash, never deleted outright. The only exceptions are emptying items already in the Trash, which is never pre-selected and says it cannot be undone, and the tools' own commands (for example `npm cache clean`), which show the exact command before it runs.
- **Identity checked again.** An item must be the same file (device, inode, type) at deletion time as it was at scan time. Otherwise it is skipped.
- **No following links.** Symbolic links are never followed, and directories are walked by file descriptor with `O_NOFOLLOW`. Hard links and APFS clones are counted honestly, so the space shown is space actually freed.
- **Protected by default.** Credentials, SSH and GPG keys, keychains, browser profiles, databases, documents, system paths and your excluded folders are refused, whatever a rule says.
- **In use means hands off.** Files of running apps are not offered.
- **Everything recorded.** The intent is logged before each action and the outcome after it.
- **No silent privilege escalation, no private APIs, no telemetry.**

Each rule has a test. The full rules are in [`docs/architecture/safety-model.md`](docs/architecture/safety-model.md).

## Requirements

- macOS 26 or later on Apple Silicon
- Xcode 27.1 or later (to build)

## Build and run

```sh
git clone https://github.com/nasraldin/clenvra.git
cd clenvra
open Clenvra.xcworkspace        # then ⌘R
```

From the command line:

```sh
scripts/check.sh          # format lint + package tests + Release build
scripts/check.sh --ui     # … plus UI tests (English/Arabic × light/dark) and the accessibility audit
```

For complete scans, give Clenvra **Full Disk Access** in System Settings › Privacy & Security. Without it, macOS hides some folders (Safari, Mail and others), and Clenvra skips them.

## Architecture

```
Clenvra.xcworkspace
├── Clenvra/                 SwiftUI app: thin views, no logic
├── Packages/ClenvraKit/     all logic, no UI, fully unit-tested
│   ├── FileSystem/          getattrlistbulk reader, fd-based walking, custom executor
│   ├── Safety/              path policy, protection policy, deletion gate, executor, restore
│   ├── Rules/               data-driven cleanup rules and the rule scanner
│   ├── Developer/           tool detection and the tools' own clean commands
│   ├── Apps/ Startup/ Duplicates/ Storage/ System/ Settings/ Activity/
│   └── Sessions/            one @Observable workflow per section
├── ClenvraUITests/          UI tests in English and Arabic
└── docs/                    research, product, architecture, design, testing
```

- **Swift 6** with strict concurrency, and warnings treated as errors.
- **No third-party dependencies.**
- **Fast scanning:** filesystem scans use `getattrlistbulk` on a dedicated thread pool, about 3.6× faster than `du` on a large real source tree.
- **Data over code:** cleanup categories, browsers, developer tools and leftover locations are rows in tables, not separate code paths.
- **Sessions in the kit, views in the app:** each section's workflow lives in ClenvraKit and is tested there; SwiftUI views only display it.

Benchmarks: [`docs/testing/benchmarks.md`](docs/testing/benchmarks.md). More: [`docs/architecture/technical-architecture.md`](docs/architecture/technical-architecture.md).

## Testing

- About **520 unit tests** (Swift Testing) cover the filesystem core, every safety rule, every cleanup rule and every section's workflow. They run against temporary fixture trees, never your real files.
- **UI tests** go through every section in English and Arabic.
- **String catalog tests** fail the build if an Arabic translation is missing or a string is no longer used.
- **Opt-in benchmarks:**

  ```sh
  cd Packages/ClenvraKit
  CLENVRA_BENCH_HOME=$HOME swift test --filter RuleBenchmark   # read-only timing of every cleanup rule
  ```

Strategy: [`docs/testing/test-strategy.md`](docs/testing/test-strategy.md).

## Contributing

Contributions are welcome. A few rules keep the project safe and easy to maintain:

1. **Write the test first.** Every behaviour starts as a failing test in `ClenvraKit`.
2. **Never weaken the safety model.** Changes to deletion code must keep every safety test passing and add new tests for new cases.
3. **Translate every string.** Add each user-facing string to the String Catalog with English and Arabic (`scripts/sync-strings.sh`, then `scripts/apply-translations.py`).
4. **No new dependencies** without a discussion first.
5. **Run `scripts/check.sh`** before opening a pull request.

Start with [`docs/README.md`](docs/README.md) for the reading order of the design documents.

## Privacy

Clenvra has no analytics and no telemetry. It makes no network calls unless you turn on **Check for app updates** in Settings; then, only when you press Check for Updates, it asks the apps' own update feeds, Apple's App Store and Homebrew for version numbers. Everything it scans stays on your Mac. The activity log is a local file in `~/Library/Application Support/Clenvra`.

## Acknowledgements

The open-source projects [Mole](https://github.com/tw93/Mole) and MacSai, and the publicly documented behaviour of commercial Mac cleaners, informed the feature research (see [`docs/research`](docs/research)). Clenvra's code is written from scratch, and nothing was copied from other projects.

## License

[MIT](LICENSE) © 2026 Nasr Aldin
