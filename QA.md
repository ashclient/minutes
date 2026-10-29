# Minutes 1.7 verification

The macOS runner compiles release builds for arm64 and x86_64, runs Foundation core checks and XCTest, verifies the signature and packages the app. A synthetic note fixture is used to inspect the native one-page workspace.

Coverage includes PKCE's RFC test vector, read-only Google scopes, callback state validation and denial, Desktop-client import validation, refresh token retention, Google recurring occurrence identity across rescheduling, Notion title date mentions, local unsynced-edit persistence, repeated idle shutdown, pause/mute audio gating, stereo system PCM extraction and resampler tails. Existing storage, corruption, request and Unicode checks remain.

A successful synthetic idle shutdown test does not establish live capture shutdown timing. Real permission prompts, muted system output, active-recording quit, browser Google consent and Notion synchronization require actual account/hardware acceptance. No real secrets are supplied to CI. ScreenCaptureKit is retained at the user's request.

New checks cover the experimental Apple OS/hardware/enablement/readiness gate, exact Unicode preservation under UTF-8 input bounds, both Notion title formats and trash filtering, and an older-OS integration test verifying that Apple selection fails with its OS explanation instead of asking for an OpenRouter key. CI compiles the Foundation Models implementation but does not run real Apple model inference: the runner is macOS 26, and Apple summaries are intentionally gated to macOS 27+. Real summary quality and model availability require a supported user's Mac.

Native screenshot smoke opens Connections and General settings separately to verify the fixed Done button, short connection cards, and Apple experimental availability explanation. Google app registration, Notion token creation, page permission policies and real account sync remain external acceptance checks.
