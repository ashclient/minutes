# Minutes 2.6.0

- Added NVIDIA API as an optional notes provider. Default: Nemotron 3.5 Lightning, hosted by NVIDIA.
- NVIDIA keys are tested before saving and kept separately in Keychain. Transcript and typed notes are sent; audio stays local.
- Added Test connection for saved cloud keys. Provider selection keeps credentials separate and never silently falls back to another service.
- Cloud replies can now recover usable Markdown or JSON with missing optional arrays. Malformed output gets one bounded Markdown retry, instead of stopping immediately on a schema error.
- NVIDIA can read larger source chunks, with at most two concurrent requests. Cloud progress reserves the final portion for whole-lecture consolidation.
- Includes 2.5.3’s Keychain changes: metadata-only Google status checks, serialized in-memory credential caching, and suppression of duplicate reads after a denial.

Choose NVIDIA API in Settings → General, follow Get a NVIDIA key, paste the key, then Connect. NVIDIA account limits and availability apply. Current ad-hoc signatures can still require renewed Keychain trust after an update; choose Always Allow for each Minutes item when asked.
