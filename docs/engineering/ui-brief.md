# Brief for agents building UI features

Read `docs/engineering/agent-brief.md` first; every rule there applies. This adds the UI conventions.

## Architecture (follow the existing Cleanup/Developer slice exactly)

- **Logic lives in ClenvraKit** as a `@MainActor @Observable public final class <Feature>Session` (see `Sessions/CleanupSession.swift`). It is fully unit-tested with Swift Testing, using `TemporaryDirectory`/`FixtureBuilder` and injected dependencies. No filesystem work runs on the main actor; use `FSExecutor` or existing scanners.
- **Views live in the app target** under `Clenvra/Features/<Feature>/`. They only read session state and call session methods. Model them on `Clenvra/Features/Review/RuleReviewView.swift` and `CleanupSheets.swift`.
- Reuse the shared components in `Clenvra/Shared/Presentation.swift` (`SizeText`, `PathText`, `StatusBadge`). Add new shared components there only if two features need them; otherwise keep them in your feature folder.
- Every deletion goes through `DeletionExecutor` (Trash first), with a confirmation sheet listing count and size, and a result sheet listing skipped items with `explanation`.

## Files you may touch

- New files under `Packages/ClenvraKit/Sources/ClenvraKit/<YourFolder>/`, `Packages/ClenvraKit/Tests/ClenvraKitTests/`, and `Clenvra/Features/<Feature>/`.
- **Do not edit** `Clenvra/App/*`, `Clenvra/Shared/*`, `Clenvra/Resources/Localizable.xcstrings` or other features' files. Instead, at the end, report:
  1. the view to show for your section and the initializer arguments it needs from `AppEnvironment` (e.g. `home`, `activityLog`, `policy`, `installedApps`);
  2. a JSON file `docs/engineering/translations/<task-id>.json` with every user-facing string you introduced:
     ```json
     { "Key exactly as written in code": { "ar": "Arabic" },
       "%lld files": { "en_plural": {"one": "%lld file", "other": "%lld files"},
                       "ar_plural": {"zero": "…", "one": "…", "two": "…", "few": "…", "many": "…", "other": "…"} } }
     ```
     Arabic must be natural, Apple-style terminology (e.g. سلة المهملات، التخزين، ذاكرة التخزين المؤقت، نقل إلى سلة المهملات، محمي، آمن، يحتاج إلى مراجعة). Every string with a count needs plural forms.

## UI rules

- Native controls only: `List`/`Table`, `Section`, `.toolbar`, `.searchable`, `.inspector`, sheets, `ContentUnavailableView`, `ProgressView`. No custom gradients, cards or animations.
- Use `.leading`/`.trailing` (never left/right). Paths, commands and identifiers go through `PathText` or `Text(verbatim:)` with left-to-right layout.
- Every icon-only control has a text label (use `Label`). Add `accessibilityIdentifier`s: `section.<name>` on the root view, `review.results` on the results container.
- Strings: `Text("…")`/`LocalizedStringResource` literals only (no string concatenation for UI text). Use `Text(bytes, format: .byteCount(style: .file))` and `.formatted()` for numbers and dates.
- Build the app (`xcodebuild -workspace Clenvra.xcworkspace -scheme Clenvra -destination 'platform=macOS,arch=arm64' -quiet build`) with zero warnings before reporting.
