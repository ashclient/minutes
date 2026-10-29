# Minutes 1.9

Native Mac meeting notes. macOS 14+; the direct long-form Apple speech engine needs macOS Tahoe 26 on supported hardware.

## Everyday use

1. Choose an upcoming Google Calendar event on the left, or click Blank note. A meeting opens with the event name and time. Clicking that event again reopens the same note; recurring occurrences have separate notes.
2. Type in Your notes, or choose Microphone / Mic + computer and click Record this meeting. Recording adds a take to the selected meeting rather than unexpectedly creating a different note. You can keep writing or browse another note.
3. Click Finish meeting. After the recording is saved, choose Brief, Detailed, or Full detail (the default), then Next. Choose local-only, a new Notion page, the linked page, or an existing page; then Make notes. Transcript only skips AI but still lets you choose a destination; Decide later keeps the recording for later. Apple finishes the transcript and your selected AI provider writes notes if connected. Your writing, generated notes, expandable transcript and recording player are all on one page. To append another take, record in that same meeting again.
4. Open in Notion opens its linked Notion page. The finish screen asks whether to sync each meeting and where. Calendar clicks open a local note without creating a Notion page prematurely. New Notion pages use the event title plus a real date mention; append mode leaves the destination title and existing blocks intact. Finished notes update the same page. Typed changes sync after a short delay when auto-sync is on. A saved pending sync is retried next time Minutes opens.

The recording controls are labeled Mute, Pause/Resume, and Finish meeting. Mute affects only the microphone. Pause omits incoming audio from both tracks and pauses the timer. Switching apps shows smaller floating controls with an audio-responsive waveform. Drag the dotted handle to move them; use the chevron to collapse or expand. Drop the panel beyond an outer screen edge to dock it as a tiny arrow, then click the arrow to restore it. Shared display boundaries do not trigger docking. Pause freezes the waveform and silence makes it flat. Expand Recordings for playback, seeking and speed. The note menu offers export, re-transcription, Notion sync and recording management.

## Calendar and detail levels

Click Calendar in the sidebar for a month grid, calendar filter and daily agenda. Browse previous/future months and select an event to open its meeting note. Calendar browsing and note navigation remain available while recording. Selected Google calendars control which events are fetched.

Full detail preserves substantive explanations, examples, calculations, questions, corrections and qualifications without a word-count target. Brief intentionally prioritizes takeaways. Each long-source section is written independently; finished sections are joined without recursively condensing them. Model output can still omit or misinterpret details, so the transcript and original recording remain available. Regenerate opens the detail chooser again.

## Quit when you want

Command-Q saves text immediately, cancels processing, and closes audio capture without waiting for speech or AI. Interrupted work is saved for Finish notes on reopening. Quit has a four-second ceiling if an OS capture service is stalled; in that exceptional case the last in-flight audio buffers may not finish closing. A normal finish still waits for Apple to finalize the transcript. Closing just the main window leaves recording running with floating controls.

## Connect Google Calendar

Minutes 1.6 reads Google Calendar directly. It no longer reads macOS Calendar or iCloud, and does not request EventKit access. Existing notes are preserved.

This private app does not contain an invented or shared OAuth client. A one-time Google Desktop OAuth client setup is required before browser sign-in works:

1. Open a Google Cloud project and enable Google Calendar API.
2. Configure the OAuth consent screen. For a project in Testing, add your Google account as a test user. Add the Calendar events read-only and Calendar list read-only scopes.
3. Create a Desktop app OAuth client and download its JSON file.
4. In Minutes → Connections → Google app setup, import that JSON, then click Connect Google and approve access in your browser. Choose which Google calendars appear.

The local callback listener binds only to 127.0.0.1 on an ephemeral port. Sign-in uses PKCE S256, random state checking, a three-minute timeout and a Cancel button. Client configuration and access/refresh tokens are kept in macOS Keychain. OAuth testing-mode token expiry and Google verification policies still apply. There is no calendar-write scope. For a public distribution, the developer must register and configure the distribution's Google OAuth client; that external setup has not been completed by this build.

## Connect Notion

Click Connect Notion to open a two-step guide:

1. Open Notion's personal-token page, create a token for your workspace with Notion API capability, and paste it in Minutes. Personal tokens act as you, so pages do not need to be shared with a bot. Workspace policy may limit who can create tokens. This private app supports your personal workflow; a public distribution would need its own Notion OAuth connection.
2. Choose Private · top level to create each meeting directly under Private, or Inside a page to choose a parent folder. Top-level pages require a personal access token/public user connection; internal bot connections need a parent. The setting applies to new meeting notes. Existing pages keep their saved IDs and location; you can move them manually in Notion without changing the link.

An existing internal connection token still works. If using one, add the connection to the destination page through Notion's page Connections menu first. Previously connected databases continue to work; choosing a new destination through the guide creates ordinary child pages in the selected parent page. Credentials stay in macOS Keychain.

Meeting titles contain the event name and a real date mention. Minutes writes native headings, rich text, bullets, numbered lists, checkboxes and code blocks directly on each page. It tracks and replaces only blocks it created; keep manual Notion edits outside those managed blocks. The old quote wrapper is replaced on the next sync. Long notes are sent in batches without flattening or truncating content. The native Notion Calendar-to-AI-meeting-note attachment is not exposed through its documented Calendar API. Normal retries reuse the saved page ID. A lost create-page response can still leave an orphan page because that API does not provide an idempotency key.

## Experimental Apple Intelligence summaries

In General, choose Apple Intelligence. This opt-in feature uses Apple's Foundation Models framework, not Siri automation. This release requires macOS 27 or newer, eligible Apple Intelligence hardware/region, Apple Intelligence enabled in System Settings, and a ready model. The control is disabled with a reason on unsupported Macs. Availability is checked again before generation, so changing preferences cannot bypass the gate.

Summaries use Apple's system model on the Mac with no API key and no bundled third-party model. Apple manages any required system-model download. Long transcripts are processed in fresh bounded sessions. Completed sections are joined without a second summarization pass, preserving the selected detail level; no raw source text is truncated. Experimental summaries can be less detailed than OpenRouter, and guardrails/context limits may reject a request. Errors retain the recording, transcript and existing notes. The app never silently switches an Apple summary to a cloud provider. Select OpenRouter explicitly if you want to use it instead.

The Google Connect button is now always actionable: it opens the setup guide when app registration is missing. This UI change does not provision a Google OAuth client; that one-time developer registration remains required. The guide walks through registration, file import and browser sign-in one step at a time.

## Recording and AI

Computer audio still uses ScreenCaptureKit, as requested. Approve macOS Screen & System Audio Recording when using Mic + computer. No screen video is written. Separate meters and transcript labels identify Microphone and Computer. Use headphones when both sources are on to avoid speaker pickup through the mic. To test direct capture, mute the microphone in Minutes and play normal speech in another app. Repeated system permission prompts have not been reproduced or verified fixed on the user's Mac; updating the app may require granting its screen/audio permission again.

Audio files use lossless CAF and remain on the Mac. Apple's system language assets may install once. No third-party local LLM is installed. Configure an OpenRouter key under General for optional summaries, using the default automatic `openrouter/free` router. The transcript and typed notes are sent as text after finishing; audio is not sent to OpenRouter. Free limits and model availability apply. Notion receives the content selected in its sync settings.

## Data and build

Replacing Minutes.app preserves ~/Library/Application Support/Minutes. Copy that entire folder while the app is closed for an audio-inclusive backup. JSON backups omit audio. Transcript and audio tracks survive summary errors and cancellation. Removing a saved recording in Manage recordings keeps its text.

Build source using the macOS 26 SDK: bash build.command. Full Xcode is needed for MINUTES_RUN_TESTS=1. GitHub Actions builds Apple Silicon and Intel, runs core and XCTest checks, verifies the ad-hoc signature and captures the native workspace. The app is not Developer ID notarized.

Real Google/Notion sign-in, ScreenCaptureKit permissions and live audio still require testing with the user's accounts and hardware. Automated checks use synthetic audio, local storage and mocked network responses; they do not establish end-to-end account behavior.

## Long-recording performance

Audio levels and the clock publish into a separate small observable model, so they do not invalidate the document eight times per second. Transcript updates coalesce over 350 ms and flush before stop/quit; final and provisional rows retain stable identities. Ordered track merging replaces repeated full sorting. The expanded transcript initially renders the latest 200 segments, with earlier segments accessible in batches; the complete text remains saved and is used for AI/export. Long generated notes render lazily. Autosave runs at most once per second while changes continue, with JSON encoding and atomic disk/backup work on a serial utility queue. Explicit Save/Quit flushes stay ordered with pending background writes.

A local-only selection disables automatic sync for that meeting. Choosing an existing page adds only this meeting's owned blocks and never renames that page. Retries update the same owned section. Changing the destination starts fresh block ownership and leaves the old destination untouched.
