# Minutes 1.8 verification

Universal native macOS build, XCTest, standalone core checks, codesign and binary architecture verification run in GitHub Actions. Synthetic UI captures cover connections, settings, Notion setup, Google setup, month calendar and the finish/detail chooser.

New regression coverage checks Markdown to native Notion headings, rich emphasis, bullets, numbered lists, checkboxes and code; long notes exceeding 100 blocks retain all items; private pages use workspace parent; section combination retains every detail; calendar grids and all-day exclusive end across DST; transcript-only completion persists detail preference without calling AI.

The floating recorder is smaller, collapsible, explicitly draggable using an AppKit handle and animated from real mic/system levels. Hardware capture, panel drag across displays and real model output quality require user acceptance. Apple Intelligence remains experimental and macOS 27+; CI compiles it on macOS 26 but cannot exercise inference. Cloud free model availability and response quality depend on OpenRouter.

Notion private-page creation requires a personal access token/public user connection; internal bot connections must use a parent page. Existing linked pages keep their IDs and location; new destination settings apply to new notes. Native content blocks replace the legacy quote wrapper on the next sync, keeping blocks outside the Minutes-managed set. Partial uploads retain returned block IDs for retry cleanup. Real API account acceptance remains necessary.

Full detail is the default. Each bounded source section is turned into detailed notes, then concatenated without a second condensation pass; the source transcript remains available. There is no guarantee that a probabilistic model preserves every fact. A truncated provider response fails rather than replacing notes with incomplete output.
