# Minutes 1.5 verification

CI runs Foundation core checks, XCTest, Apple Silicon and Intel release builds, signature verification, app packaging, and a native launch/screenshot.

New regression coverage checks pause omission, microphone mute silence, source ownership, stereo system sample-buffer extraction, resampler duration including its tail, recurring-calendar occurrence identity, reuse of existing notes, and Notion identifier/Unicode chunk limits. Existing persistence, corrupt-store protection, archive compatibility and text-only free-model request checks remain.

Real hardware checks remain necessary for ScreenCaptureKit with output muted, simultaneous Apple speech sessions, floating controls across Spaces/full-screen apps, calendar permissions/account syncing, and Notion access/sync with a real secret. Credentials are not embedded or supplied to CI. Passing CI is not a claim that those account/hardware tests passed.
