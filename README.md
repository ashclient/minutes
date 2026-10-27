# Minutes 1.2

Native Mac meeting and lecture notes. macOS 14 or newer. Download the compiled app from the successful GitHub Actions build, unzip, and move Minutes.app to Applications.

## Use

- **New note** (Command-N): create a note without recording. Write in **My notes**; text is saved as you type.
- **Record**: if the current note has no recording or AI output, recording attaches to it. Otherwise a new meeting is created. You can keep typing in My notes while recording.
- **Transcript**: shows live on-device Apple recognition of your microphone. Initial recognition permission can take a moment. Live recognition uses overlapping context when requests rotate.
- **Stop & make notes**: waits for the microphone transcript to finish, then sends text and your typed notes to OpenRouter for a summary, detailed key points, decisions and next steps. If live recognition is unavailable or incomplete, the saved audio is transcribed first with overlapping windows. Computer audio, if enabled, is transcribed after stopping.
- **AI notes**: read, copy or edit generated notes. My notes remain separate and editable. To include later changes, use Generate again.
- **Details**: play recordings, review the transcript, paste transcript text or remove saved audio while retaining text.
- **Three-dot menu → Transcribe again**: refresh an existing recording's transcript and AI notes. Typed notes and audio are kept. Useful for recordings made with older versions.
- **History**: search or reopen notes. Trash supports restore and confirmed permanent deletion.

## One-time AI setup

Use Connect AI or the gear button to save an OpenRouter API key in macOS Keychain. Default model: `openrouter/free`, automatically routed to an available free model supporting JSON. No local language model is needed; free usage limits and availability apply. There is no paid fallback. No meeting text is sent to AI while recording: it is sent after stopping or when you explicitly make/regenerate notes. OpenRouter and its selected provider receive text, not audio. The old Groq key is not reused.

## Recording and speech

Enable Include computer audio in Settings for calls, and wear headphones to avoid duplicated speech. Participants should know you are recording. Speech permissions, supported on-device languages, and input quality affect recognition. You may need to enable Dictation/download a language in macOS Keyboard settings. Live microphone recognition and saved audio capture run separately. On-device speech failures retain audio for retry. Audio source labels are not speaker identification.

The live transcript is provisional and can change as Apple recognizes more context. It is not guaranteed verbatim. An interrupted live session falls back to saved audio after stopping. Separate audio takes are approximately aligned, not sample synchronized.

## Data and building

Notes/recordings remain in `~/Library/Application Support/Minutes`; replacing the app preserves them. Copy the whole folder while the app is closed for a full backup. JSON exports omit audio. Saved audio is not automatically deleted.

`bash build.command` runs standalone checks using Apple Command Line Tools, then builds the app. Full-Xcode users can additionally set `MINUTES_RUN_TESTS=1`. CI runs both core and XCTest checks, compiles arm64 and x86_64, verifies the ad-hoc signature and packages the app. A Developer ID/notarized public installer is not provided.

Native compilation, core checks and XCTest passed on the macOS runner for this update. Live microphone, speech quality and real API behavior still require testing on actual hardware. The tests include overlap-window boundary ownership, Unicode preservation, typed-note preservation and archive compatibility.
