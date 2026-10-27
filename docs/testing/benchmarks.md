# Benchmarks

Read-only timings on a real Mac. Nothing is deleted: the benchmarks only call the scanners. They are opt-in tests, so a normal `swift test` skips them.

```sh
cd Packages/ClenvraKit
CLENVRA_BENCH_HOME=$HOME swift test --filter RuleBenchmarkTests          # every cleanup rule against a real home
CLENVRA_BENCH_ROOT=$HOME/Sources swift test --filter StorageBenchmarkTests # one storage scan of a real folder
/usr/bin/time -p du -sk $HOME/Sources                                     # baseline
```

`swift test` builds in debug, so these numbers are an upper bound; the Release app is faster.

## 2026-10-27: MacBook Pro, Apple M1 Max, 64 GB, macOS 27.2

Warm file cache, Full Disk Access not granted to the test runner.

### Storage scan (`StorageScanner`, `getattrlistbulk` on the FS executor)

| Folder | Files | Folders | Clenvra | `du -sk` | Speed-up |
|---|---|---|---|---|---|
| `~/Sources` | 1,232,552 | 159,127 | 9.2 s (12.9 s second run) | 34.8 s | 2.7–3.8× |

### Cleanup rules (`RuleScanner`, whole catalog)

| Rule | Time | Items | Size |
|---|---|---|---|
| `projects.Sources` (build folders in 28 inactive projects) | 11.0 s | 28 | 18.15 GB |
| `caches.user` | 1.85 s | 102 | 6.18 GB |
| `installers.downloads` | 0.76 s | 0 | — |
| `deviceBackups.mobileSync` | 0.73 s | 2 | 56.48 GB |
| `ide.cursor` | 0.51 s | 7 | 1.49 GB |
| `ide.vscode` | 0.24 s | 8 | 1.24 GB |
| `xcode.derivedData` | 0.20 s | 7 | 1.57 GB |
| `xcode.deviceSupport.iOS` | 0.20 s | 1 | 6.96 GB |
| all other rules | < 0.1 s each | | |
| **Total** | **15.5 s** | | |

Project build folders dominate, because finding them means walking every project tree. Results appear rule by rule as each finishes, so the rest of the list is usable within about 2 seconds.

## Targets (from the implementation plan)

- Filesystem core: ≥ 250k entries/s warm. **Not confirmed yet:** the debug build reads about 150k entries/s (1.39M entries in 9.2 s). Measure a Release build before calling this met.
- No main-thread hang over 250 ms during a scan. Check with Instruments › Hangs in the release pass.
- Cancel within 200 ms. Covered by `FSExecutorTests`.

## Still to measure

- A managed (MDM) Mac, where Full Disk Access may be blocked by policy.
- A Mac with mostly media and documents rather than code, for the Storage and Duplicates sections.
