# Minutes 2.7.0

- Cloud generation now shows a moving activity bar during requests, instead of sitting at 0%. Unknown output length is not presented as a percentage or time estimate.
- Apple collects compact evidence internally, combines related concepts, then writes one whole-lecture draft for every length. It no longer fills the document with a separate set of notes for every source chunk.
- Added optional collaborative topic editing with 1–4 independent local model sessions (default: 2). Settings → General → Apple Intelligence controls the worker count and editing pass. Active workers and topic markers show where real requests are running.
- Editors own distinct topic sections, keep source excerpts beside the draft, remove repetition, and clarify supported details. Auto/Brief/Detailed sections cannot grow beyond their initial draft budget. A topic too large for safe local editing is preserved unchanged.
- Mid-document additions, replacements and deletions now animate at the changed location while retaining untouched text. Removed text appears briefly with strikethrough. Reduce Motion applies edits immediately.
- Cancellation keeps the previous saved notes and still offers keep partial / revert. Worker labels clear when work stops; editor metadata is never exported to Notion.

Apple's small local context still requires chunking internally. More sessions share the same hardware and may be queued by macOS; four workers are not a promise of faster generation. Native CI exercises the full orchestration with synthetic inference; real Apple inference needs an eligible macOS 27 Mac.
