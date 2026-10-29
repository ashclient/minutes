# Minutes 1.6

Native Mac meeting notes. macOS 14+; the direct long-form Apple speech engine needs macOS Tahoe 26 on supported hardware.

## Everyday use

1. Choose an upcoming Google Calendar event on the left, or click Blank note. A meeting opens with the event name and time. Clicking that event again reopens the same note; recurring occurrences have separate notes.
2. Type in Your notes, or choose Microphone / Mic + computer and click Record this meeting. Recording adds a take to the selected meeting rather than unexpectedly creating a different note. You can keep writing or browse another note.
3. Click Finish meeting. Apple finishes the transcript, then an OpenRouter free model writes the summary if AI is connected. Your writing, generated notes, expandable transcript and recording player are all on one page. To append another take, record in that same meeting again.
4. Open in Notion opens its linked Notion page. Connected meetings create one page with the event title plus a real date mention. Finished notes update the same page. Typed changes sync after a short delay when auto-sync is on. A saved pending sync is retried next time Minutes opens.

The recording controls are labeled Mute, Pause/Resume, and Finish meeting. Mute affects only the microphone. Pause omits incoming audio from both tracks and pauses the timer. Switching apps shows the draggable floating controls. Expand Recordings for playback, seeking and speed. The note menu offers export, re-transcription, Notion sync and recording management.

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

In Connections, create a Notion internal connection with read/insert/update content access. Share a parent page with it using that page's Connections menu. Paste the secret and parent page link into Minutes, then connect. New setups create ordinary child pages in that parent. An existing Notion database remains supported as an alternate destination, and old database-backed meeting links keep their parent type.

The page title contains the event name and a date mention (Notion chooses the relative date display, such as Today). The body shows your own notes and generated notes, and optionally the transcript. Minutes updates its own visible quote section; keep edits made directly in Notion outside that section. The page title and date are also updated on sync. Notion's exact native Calendar-to-AI-meeting-note attachment and tab controls are not exposed through the documented Calendar API; this app creates real Notion pages without claiming to control those native features.

Sync is one-way from Minutes. The page ID is saved before content upload so normal retries reuse the page. Like other APIs without an idempotency key, a lost create-page response can leave an orphan page. Errors are visible with retry. No credentials or real account connections are exercised by CI.

## Recording and AI

Computer audio still uses ScreenCaptureKit, as requested. Approve macOS Screen & System Audio Recording when using Mic + computer. No screen video is written. Separate meters and transcript labels identify Microphone and Computer. Use headphones when both sources are on to avoid speaker pickup through the mic. To test direct capture, mute the microphone in Minutes and play normal speech in another app. Repeated system permission prompts have not been reproduced or verified fixed on the user's Mac; updating the app may require granting its screen/audio permission again.

Audio files use lossless CAF and remain on the Mac. Apple's system language assets may install once. No third-party local LLM is installed. Configure an OpenRouter key under General for optional summaries, using the default automatic `openrouter/free` router. The transcript and typed notes are sent as text after finishing; audio is not sent to OpenRouter. Free limits and model availability apply. Notion receives the content selected in its sync settings.

## Data and build

Replacing Minutes.app preserves ~/Library/Application Support/Minutes. Copy that entire folder while the app is closed for an audio-inclusive backup. JSON backups omit audio. Transcript and audio tracks survive summary errors and cancellation. Removing a saved recording in Manage recordings keeps its text.

Build source using the macOS 26 SDK: bash build.command. Full Xcode is needed for MINUTES_RUN_TESTS=1. GitHub Actions builds Apple Silicon and Intel, runs core and XCTest checks, verifies the ad-hoc signature and captures the native workspace. The app is not Developer ID notarized.

Real Google/Notion sign-in, ScreenCaptureKit permissions and live audio still require testing with the user's accounts and hardware. Automated checks use synthetic audio, local storage and mocked network responses; they do not establish end-to-end account behavior.
