# Minutes 1.6 verification

The macOS runner compiles release builds for arm64 and x86_64, runs Foundation core checks and XCTest, verifies the signature and packages the app. A synthetic note fixture is used to inspect the native one-page workspace.

Coverage includes PKCE's RFC test vector, read-only Google scopes, callback state validation and denial, Desktop-client import validation, refresh token retention, Google recurring occurrence identity across rescheduling, Notion title date mentions, local unsynced-edit persistence, repeated idle shutdown, pause/mute audio gating, stereo system PCM extraction and resampler tails. Existing storage, corruption, request and Unicode checks remain.

A successful synthetic idle shutdown test does not establish live capture shutdown timing. Real permission prompts, muted system output, active-recording quit, browser Google consent and Notion synchronization require actual account/hardware acceptance. No real secrets are supplied to CI. ScreenCaptureKit is retained at the user's request.
