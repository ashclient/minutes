# Minutes 2.6.2

- Removed the “streaming…” suffix from cloud generation status messages.
- Apple Intelligence now displays its actual working draft while selecting concepts for Auto, Brief and Detailed, instead of hiding all intermediate text until the final writing pass. Full detail continues to stream as before.
- Apple draft updates are delivered more frequently through the existing smooth reveal. Brief and Detailed preview budgets remain enforced; final consolidation may revise provisional text.
- Apple still processes small source chunks sequentially because of its local context limit. This improves time to visible output, not the model's inference speed or total number of necessary passes.
- Fixed the unavailable OpenRouter default: Nemotron 3.5 Lightning’s free endpoint replaces the old Qwen ID. The old default migrates automatically; custom choices stay unchanged.
- General settings now fetches a live list of free text models with sufficient context, with Refresh and a custom ID field. Selection stays pinned; model availability is not guaranteed by catalog listing.
- Updated the built-in guide to describe OpenRouter’s pinned default.

Includes 2.6.1's cloud streaming and improved connection checks. Actual Apple inference requires an eligible Mac with macOS 27 and Apple Intelligence enabled; CI verifies draft handling without running the local model.
