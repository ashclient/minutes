# Verification of the simplified version

## Completed here
- Swift grammar parse across production, XCTest, and standalone check sources.
- Shell syntax and Info.plist structure.
- Simulated launcher paths: default no-XCTest build, core-check failure stops build, explicit XCTest failure stops build.
- Review of automatic record/save/transcribe/generate order, cancellation, incomplete/transcribed track handling, migration of old JSON fields, consent/key separation from Groq, and free-model request configuration.
- Package integrity.

## Automatically run by build.command on your Mac
The Checks/CoreChecks.swift executable uses only Foundation and runs before the app build. It checks free-model request configuration, text-only payload, missing keys, rejected/rate-limited/error responses, truncated completions, lossless Unicode chunking, deduplicated actions, preservation of manually edited titles, and decoding an older archive without the new fields. No credentials, network, or XCTest are needed.

## Native acceptance checks still pending
- Release compilation and standalone core checks on macOS 14+.
- Compact UI at minimum/default window sizes and in light/dark appearance.
- Record → Stop → Apple speech → OpenRouter → finished notes with real hardware and a key.
- Speech permission denied / language unavailable / silence.
- Computer audio capture, permission refusal, and empty or interrupted computer track.
- Cancel during transcription and AI generation; retry without redoing completed tracks.
- Quit/relaunch recovery and loading a user's existing data folder.
- OpenRouter authentication failure, free-provider unavailable, daily limit reached, and actual summary quality.
- Removing recording files while retaining transcripts; trash and restore.

The Linux checks do not establish macOS SDK type correctness or runtime behavior. The macOS build and live API checks have not been run here.
