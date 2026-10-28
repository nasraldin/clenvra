# Issues found in real use

Found by the owner while freeing ~75 GB on the work Mac with Clenvra 1.0.0 (2026-10-28). Each item says whether it is a bug or a design gap, and which redesign slice (`docs/superpowers/specs/2026-10-28-ui-redesign-design.md`) fixes it. Bugs get a failing test first.

| # | Where | What happens | What should happen | Kind | Slice |
|---|---|---|---|---|---|
| F1 | Space Map | A folder selected in the scan results cannot be removed: the remove button stays disabled | Any selectable item enables Move to Trash; if an item cannot be removed, the reason shows next to it | Bug | 3 |
| F2 | Space Map (storage bar) | After removing big files, the disk bar and free space still show the old numbers | Free space and the bar update right after a cleanup, on every page that shows them | Bug | 3 |
| F3 | All pages | Opening a page starts a scan or search automatically | Nothing scans until the person clicks Scan. Pages show what was found last time (with its date) or an empty state with a Scan button | Design | 2, 3, 4, 5 |
| F4 | All result pages | Groups (categories, kinds, sources) cannot be collapsed or expanded | Every group is a disclosure group, remembered across launches; Option-click opens or closes all | Design | 2, 3 |
| F5 | System Junk (and every list) | No right-click menu | Context menu on every row: Reveal in Finder, Quick Look, Show Details, Copy Path, Exclude Folder…, Move to Trash… | Design | 2 |
| F6 | System Junk (and every list) | No way to see an item's details | Inspector with full path, why it is safe or needs review, owning app, size, dates | Design | 2 |
| F7 | Downloads | Grouped by kind, age and source only | Filter by age (Last Week, Last Month, Last 3 Months, Older than a Year, Custom range) and by size (over 10 MB, 100 MB, 1 GB, custom) | Design | 3 |
| F8 | Startup Items | No details for an item | Inspector: name and app icon, what it runs, when it runs, who made it (signature), file location, whether it is loaded | Design | 4 |
| F9 | Startup Items | Only Remove; no way to stop or start an item | Stop / Start (unload / load for the current session) next to Remove, with clear words for each | Design | 4 |
| F10 | Settings | One long form; not modern or friendly | Toolbar tabs with icons (General, Scanning, Notifications, Menu Bar, Exclusions, System Helper), each a two-column page: section titles on the leading side, controls on the trailing side, explanations under the controls (reference screenshots from CleanMyMac and Outlook supplied by the owner) | Design | 7 |
