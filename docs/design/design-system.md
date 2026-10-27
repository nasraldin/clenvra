# Design System

The guiding rule is to look and behave like a first-party macOS utility (Disk Utility, System Settings › Storage), not a dashboard. Use standard controls; they pick up the current system look, including Liquid Glass on macOS 26+, for free.

## 1. Window and structure

- One `WindowGroup` with `NavigationSplitView` (sidebar + content) and `.inspector` for details (⌘I). Default size 1100×720; minimum 900×560. State restoration on.
- `Settings` scene (⌘,): General, Exclusions, Permissions, Developer roots, Advanced.
- Toolbar: section-specific primary action (Scan / Rescan), `.searchable` in the toolbar, filter segmented control (Safe · Review · All), Preview, and **Move to Trash** (destructive role, enabled only with a selection).
- Lists are `Table` with sortable columns (Name, Size, Frees ≈, Risk, Last used, Location). Grouping uses `DisclosureTableRow`. Context menu: Reveal in Finder, Quick Look (Space), Copy Path, Exclude…, Open With.
- Sheets for confirmation and results, not alerts, so they can show lists. `alert` is used only for single yes/no.

## 2. Visual language

| Element | Rule |
|---|---|
| Colour | Semantic colours only (`.primary`, `.secondary`, `Color.accentColor`, `.red/.orange/.green` from system palette). No hard-coded RGB except the app icon. |
| Materials | Sidebar and toolbar use system materials automatically. Content stays on the plain window background. No custom blur, no gradients. |
| Cards | Only on Overview (≤ 5 recommendation tiles) and the Developer section headers. Everywhere else: tables and grouped `Form`s. |
| Typography | System font; `.largeTitle` for the Overview free-space number only; `.headline` section headers; `.body` rows; `.callout`/`.secondary` for explanations; `.monospaced()` for paths and commands. Dynamic Type sizes respected. |
| SF Symbols | One per concept: Storage `internaldrive`, Developer `hammer`, Cleanup `sparkles`, Applications `app.badge`, Startup `power`, System `gauge.with.dots.needle.50percent`, Activity `clock.arrow.circlepath`, Safe `checkmark.shield`, Review `exclamationmark.triangle`, Protected `lock`, Irreversible `trash.slash`. Hierarchical rendering. |
| Risk | Always **icon + text + colour** (never colour alone). Safe = green, Review = orange, Protected = secondary grey, Irreversible = red. |
| Disk bar | A horizontal segmented bar (Apps, Developer, Documents, System, Other, Free), the same idiom as System Settings › Storage. Built with `Canvas`, with an accessible summary text. |
| Motion | System defaults only: list insert/remove, progress, a single number roll when the free space changes. Honours *Reduce Motion*. |
| Progress | Determinate when the total is known (cleanup); otherwise an indeterminate bar plus live "N items · X GB found" counters and the current folder (truncated in the middle). |

## 3. Content style

- Plain, specific language: "Moves 14 items (≈ 9.8 GB) to the Trash. You can put them back from Activity."
- Explanations say *what regenerates* and *what you lose*: "Xcode rebuilds this on the next build. Your first build will be slower."
- Errors say what happened and what to do: "Skipped: Slack is open. Quit Slack and scan again."
- Sizes: `ByteCountFormatStyle(style: .file)` (decimal, like Finder). Counts use plural-aware string catalog entries.

## 4. Light, dark and contrast

- Uses semantic colours and materials only, so no per-mode assets except the icon.
- Tested in Light, Dark and **Increase Contrast**. Risk colours were checked for ≥ 4.5:1 text contrast because the label text sits beside the icon, not on a coloured fill.

## 5. Localization and RTL (English + Arabic)

| Topic | Rule |
|---|---|
| Strings | `Localizable.xcstrings` (String Catalog), `InfoPlist.xcstrings`. All UI text uses `LocalizedStringKey` / `LocalizedStringResource`. A build setting turns missing translations into warnings; CI fails on stale entries. |
| Plurals | Catalog plural variants. Arabic needs **zero, one, two, few, many, other**, e.g. "%lld items". |
| Numbers / bytes / dates | `formatted()` APIs with the current locale; no manual digit handling. Arabic locale may show Arabic-Indic digits depending on the user's number setting. That is respected, not overridden. |
| Layout | SwiftUI mirrors automatically (`.leading/.trailing` only; never `.left/.right`). Directional symbols (`chevron.forward`, `arrow.uturn.backward`) flip automatically. Progress bars and the disk bar fill from the leading edge. |
| Mixed text | Paths, commands, bundle IDs and versions are always **LTR islands**: wrap in `Text(verbatim:)` with `.environment(\.layoutDirection, .leftToRight)` and the Unicode isolate `U+2066 … U+2069` when interpolated into Arabic sentences. Paths are truncated in the middle. |
| Terminology (ar) | Natural, Apple-consistent terms: سلة المهملات (Trash), ذاكرة التخزين المؤقت (cache), التخزين (Storage), التطبيقات (Applications), عناصر بدء التشغيل (Startup items), نقل إلى سلة المهملات (Move to Trash), وصول كامل إلى القرص (Full Disk Access), آمن (Safe), يحتاج إلى مراجعة (Review), محمي (Protected), لا يمكن التراجع عنه (Irreversible). A glossary lives in `docs/design/glossary-ar.md` (created with the first strings). |
| Testing | Scheme options: Application Language = Arabic, plus *Right-to-Left Pseudolanguage*. UI tests run each main screen in `ar` and take screenshots for review. |

## 6. Accessibility

- Every icon-only button has a label. Rows expose a combined accessibility label ("DerivedData, 4.2 gigabytes, Safe").
- Full keyboard use: sidebar ⌘1–⌘7, table navigation, Space = Quick Look, ⌘⌫ = Move to Trash (opens confirmation), ⌘R = rescan, Esc cancels a scan.
- VoiceOver announcements for scan completion and cleanup results.
- No information carried by colour alone (risk has icon + text).

## 7. Explicitly avoided

Gauges and "health scores", animated mascots, gradients and glow, full-window confetti, nag banners, fake urgency ("Your Mac is at risk").
