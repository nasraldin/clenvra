# Brief for coding agents working on Clenvra

You are implementing one small, well-defined unit of Clenvra, a native macOS 26+ (Apple Silicon) utility. Read `README.md` and `docs/architecture/safety-model.md` §1 before starting.

## Non-negotiable rules

1. **TDD.** Write a failing Swift Testing test first, run it and see it fail for the right reason, then write the minimum code to pass. Repeat. Every behaviour has a test.
2. **Only touch the files listed in your task.** Do not edit any other file. If you believe another file must change, stop and say so in your final report.
3. **Swift 6, strict concurrency, no warnings** (warnings are errors). No `@unchecked Sendable`, `nonisolated(unsafe)`, force unwraps (`!`), `try!` or implicitly unwrapped optionals in production code.
4. **No third-party dependencies.** Use Foundation, Darwin, Dispatch and Apple frameworks only.
5. **No code copied** from other projects or the internet. Write it yourself from Apple documentation and SDK headers (`xcrun --show-sdk-path`).
6. `ClenvraKit` uses `InternalImportsByDefault`: write `public import Foundation` only when a public API exposes Foundation types; otherwise `import Foundation`.
7. Tests touch the filesystem **only** inside `TemporaryDirectory` (see `Tests/ClenvraKitTests/Support/TemporaryDirectory.swift`). Never read or write real user folders, never delete anything outside the test directory.
8. Public API gets a one-line doc comment explaining *why*, not *what*. No commented-out code, no TODOs.
9. Before reporting done, both must pass with zero warnings:
   ```sh
   cd Packages/ClenvraKit && swift test --scratch-path .build/agent
   cd ../.. && xcrun swift-format lint --recursive --strict Packages/ClenvraKit/Sources Packages/ClenvraKit/Tests
   ```
   (Use `xcrun swift-format format --in-place …` to fix formatting.)

## Final report (print at the end)

- Files created/changed.
- Public API added (signatures).
- Tests added (names) and the final `swift test` summary line.
- Any assumption, limitation or open question.
