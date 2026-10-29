# Minutes 2.5.2

Native macOS meeting and lecture notes with Apple transcription, optional Apple Intelligence or OpenRouter, Google Calendar and Notion. Runs on macOS 14+; modern Apple speech needs macOS 26 on eligible hardware. Experimental Apple Intelligence generation currently requires macOS 27 and a ready system model.

## Download and updates

Install `Minutes-App.zip` from GitHub Releases and move Minutes.app to a writable Applications folder. Starting with 2.5, Minutes checks this repository's latest public GitHub release on launch, at most once every six hours. Use **Minutes → Check for updates…** or **Settings → General → Updates** for a manual check. New versions appear above Connections. **Install & relaunch** downloads, verifies and installs the update; it waits until recording, generation, pending draft choices and Notion sync are idle.

The updater accepts only this repository's release asset URL, checks GitHub's SHA-256 digest and archive paths, and verifies the bundle identity, version and code signature before replacement. A separate helper waits for the app to quit and keeps a backup during replacement. Notes and recordings in Application Support are outside the app bundle and are not replaced. Distribution uses an ad-hoc signature, not Developer ID notarization. Update trust comes from this GitHub repository and HTTPS; the checksum is not a separate publisher signature.

Every successful main-branch build publishes a release when the app version is new. Existing release assets are never overwritten. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` before publishing an update. Fork pull requests do not publish releases.

## Recording and study notes

Choose a Google event or create a note, type your own notes, then record microphone or microphone plus computer audio. Approve macOS screen/system-audio capture for computer audio. No screen video is written. Use headphones to avoid capturing speakers twice through the microphone. The app remains usable while recording, and the draggable floating controls can collapse or dock at screen edges. Recordings and the transcript share an expandable source card.

Finish offers **Auto**, **Brief**, **Detailed**, or **Full detail**, plus **Outline**, **Cornell**, or **Q&A** formatting. Auto reads the source, consolidates its main concepts across the whole lecture, then writes concise, selective notes without a fixed word target. Brief is capped at 300 words for the whole lecture; Detailed at 900. Full detail retains broader explanations and examples. Outline follows personal college notes: short plain explanations mixed with lists, meaningful topic/subtopic headings, nested details, numbered examples and standalone formulas. It adapts to business definitions/comparisons, accounting scenarios/account effects, and math variables/units/worked steps. Auto preserves meaningful definitions and complete selected examples through the evidence passes, rather than reducing everything to keyword inventories. Apple inference is sequential to limit device pressure. Text streams as a live draft, with a smooth presentation respecting Reduce Motion. Cancelling a draft offers keep-partial or revert; previous saved notes stay intact until successful replacement or an explicit keep choice.

Apple's system model has a small context window, so long lectures require multiple requests. Generation can omit or misinterpret information, including numbers; the full transcript and audio remain available. No measured tokens-per-second rate is promised. Minutes never silently switches Apple generation to cloud AI. OpenRouter uses `openrouter/free` with its account/provider limits; only text is sent, not recordings.

## Google Calendar

Direct read-only Google Calendar access supplies Day, Week, Month and Agenda layouts. Clicking an event opens its meeting note. A Google Desktop OAuth client must be imported once: enable Calendar API, configure the consent screen/test user, create a Desktop client and import its JSON in Connections. PKCE and a local loopback callback are used. Credentials/tokens stay in macOS Keychain. There is no iCloud/EventKit integration or calendar-write scope.

## Notion

Connect a Notion personal token or internal connection in Connections, then choose a destination. Personal tokens/public user connections can create Private top-level pages; internal connections need a parent page shared with that connection. On finish choose local-only, a new page, the linked page or an existing page. Existing-page mode does not change the destination title. Meeting occurrences retain separate local notes and page IDs; normal retries reuse the saved page.

Sync writes native headings, nested bullets/numbered steps, formatted rich text and equations. Only recorded Minutes-owned block IDs are replaced. Before replacement, sync checks whether those blocks or their descendants were edited after the previous sync. A conflict preserves the Notion version and offers **Preserve edits & add copy**; that choice leaves the old section and appends a fresh local copy. Already-deleted owned blocks no longer trap cleanup in a retry loop. This is conflict protection, not bidirectional editing: Notion changes are not imported into the local summary. Concurrent edits during the upload and a lost create/append response can still leave duplicates/orphans; Notion supplies no idempotency key for these calls.

## Data, build and verification

Audio stays in `~/Library/Application Support/Minutes/Audio`; copy the entire Minutes support folder while closed for an audio-inclusive backup. JSON backups do not include audio. Quit saves text and closes capture without waiting for AI.

Build on a Mac with `bash build.command`. `MINUTES_RUN_TESTS=1` requires full Xcode. `MINUTES_UNIVERSAL=1` builds Apple Silicon and Intel, including the update helper. CI runs tests, verifies signatures/architectures, exercises the real helper against disposable app copies, and captures native UI previews. Live microphone/system-audio performance, Apple model quality/speed and account workflows still require real hardware/account testing.
