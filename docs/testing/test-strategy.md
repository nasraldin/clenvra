# Test Strategy

## 1. Rules

- **Never against real user data.** All destructive tests run on fixtures under `FileManager.default.temporaryDirectory/ClenvraTests-<UUID>`, created and removed per test.
- The `DeletionExecutor` refuses to run in tests unless every plan item is under the fixture root. This is enforced in the test helper, not just by convention.
- Any **live** cleanup on any of the owner's Macs needs explicit approval from the owner each time.
- **OS matrix:** automated tests run on the current macOS. Before each release, a smoke pass runs on **macOS 26 and the latest macOS** in local Apple Silicon VMs (Virtualization framework, e.g. `tart`/UTM), on a standard (non-admin) user, and once with Full Disk Access denied.
- **Machine profiles:** at least one pass on a managed work Mac (MDM + security agent present) to confirm managed items stay protected, and one on a Mac without developer tools.
- Safety cases S1–S28 (`safety-model.md` §10) must pass before any destructive feature merges.

## 2. Layers

| Layer | Tool | Scope |
|---|---|---|
| Unit (pure) | Swift Testing in `ClenvraKit` | Rules, risk classification, path sanity, root containment, ownership evidence scoring, orphan rules, size aggregation (hard links), duplicate grouping decisions, plural/format helpers |
| Filesystem integration | Swift Testing + `FixtureBuilder` | Bulk enumerator vs `lstat` ground truth; symlinks, hard links (`link`), clones (`clonefile`), sparse files (`ftruncate`), flags (`chflags`), permission denied (`chmod 000`), mount boundary (attach a small RAM-disk/`hdiutil` image, opt-in tag `.requiresDiskImage`) |
| Safety (adversarial) | Swift Testing, fault-injecting `FileSystemOperations` | S1–S28, including race injection between gate and execute |
| Tool adapters | Fake `CommandRunner` with recorded outputs | Argument construction, output parsing (`simctl list -j`, `docker system df --format json`, `pnpm store path`), timeouts, cancellation |
| Concurrency | Swift Testing + `TaskGroup` stress | Cancellation leaves consistent state; no main-actor I/O (debug assertion `dispatchPrecondition(.notOnQueue(.main))` in FS calls) |
| Performance | XCTest `measure` + custom benchmark target | Enumerator throughput (1M-file synthetic tree), index memory, deletion rate, launch time. Results recorded in `benchmarks.md` |
| UI | XCTest UI | Smoke per section × {en, ar} × {light, dark}: launch, navigate, scan the fixture root, review sheet shows paths, cancel. Screenshots attached for RTL review |
| Localization | Unit + CI script | Every catalog key has `en` + `ar`; Arabic plural forms present for counted strings; no hard-coded strings (lint: `Text("` literal outside previews fails) |
| Accessibility | XCTest `performAccessibilityAudit()` | Per main screen |

## 3. Fixture builder (sketch)

```swift
let fx = try FixtureBuilder()
  .dir("Library/Caches/com.example.app") { $0.file("a.bin", size: .mb(5)) }
  .symlink("Library/Caches/evil", to: "Documents")      // S1/S2
  .hardLink("Downloads/a-link.bin", to: "Library/Caches/com.example.app/a.bin") // S8
  .clone("Movies/copy.mov", of: "Movies/orig.mov")      // S9
  .flags("Locked/keep.txt", [.userImmutable])           // S11
  .build()
```

## 4. End-to-end workflows (fixture-based)

1. Scan the fixture → select Safe → Preview (dry run) → no filesystem change, log written with `dryRun: true`.
2. Same → Move to Trash → items present in Trash with identities matching → Restore → originals back.
3. Uninstall a fixture app bundle (built in the test with an `Info.plist`, a fake container metadata plist, a LaunchAgent with `AssociatedBundleIdentifiers`) → Certain/Likely/Possible grouping correct → only Certain + Likely pre-selected.
4. Startup reader on a fixture LaunchAgents folder → "Target missing" detected; unparsable plist reported, not crashed.

## 5. CI gates

`swift test` (kit) on every change; `xcodebuild test` (app + UI) before merging UI work; benchmarks on demand. Warnings are errors in ClenvraKit, including strict concurrency.

GitHub Actions (`.github/workflows/ci.yml`) runs format lint, the ClenvraKit tests and an ad-hoc-signed Release build on every push and pull request. UI tests are local only (`scripts/check.sh --ui`): they need a GUI session and Accessibility permission for the test runner. UI tests force the appearance with the debug-only launch argument `-ClenvraUITestAppearance light|dark` (`-AppleInterfaceStyle` in the argument domain does not override the system appearance). The accessibility audit fails on any issue not covered by the documented exclusions in `AccessibilityAuditUITests.swift`.
