# Minutes 2.6.1

- OpenRouter now defaults to a pinned Qwen3.8 27B free model instead of random free routing. Edit the model ID in General settings or Reset to the default. Free endpoint quotas and capacity still apply; non-free IDs may incur OpenRouter charges.
- Both NVIDIA and OpenRouter now request real streaming Markdown and show live drafts in Minutes, including the source-check pass. Reasoning fields and JSON wrappers are kept out of the live draft.
- Cloud progress counts completed draft/check/consolidation passes rather than jumping to 85%. It measures work completed, not estimated time remaining.
- Most lectures fit one large source chunk; their checked notes no longer need an extra consolidation request. Longer sources retain every character and process in order, with one cloud request at a time to reduce rate-limit pressure.
- Connection tests now accept short successful replies such as OK, instead of rejecting them for not looking like study notes.
- Interrupted streams, truncation and provider errors preserve saved notes. Cancel still offers keep partial draft or revert.

Native tests use synthetic streamed responses; live provider capacity, speed and quality depend on your account and model. Current ad-hoc app signatures may still require renewed Keychain authorization after updates.
