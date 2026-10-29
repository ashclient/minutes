# Minutes 2.7.2

Fixes local information loss in 2.7.0 and separates the writer/reviewer roles:

- Removed recursive whole-lecture compression into one 2,400-byte extract. Full evidence cards are retained in a ledger; a separate topic plan groups their IDs. Unknown, duplicate, omitted or malformed planner output cannot discard cards. Topic writers visit every retained evidence batch.
- Removed local word-count clipping. Length is requested through semantic selection and rewriting, rather than deleting whole lines from a response. Brief and Detailed are approximate targets; a complete topic is preferred to an artificially cut fragment.
- Incomplete topic output gets one bounded repair attempt. Dangling headings/labels/colon endings, unbalanced math/formatting and recognizable fabricated qualitative equations fail structural checks. These are safeguards, not a general fact checker.
- One main writer writes the notes. Extra workers perform brief sanity checks and return narrow issue reports, never rewritten sections. Only the main writer can apply a structurally valid patch to an exact quoted span. Invalid reports leave the draft intact; unresolved reported concerns are visibly marked for verification.
- Settings exposes 1–4 total local worker slots. Source reading can run in parallel; topic writing belongs to Agent 1, and extra agents perform optional quick checks. Stable section IDs and tracked edit presentation remain.
- Every topic is sanity-checked in small overlapping fragments, including topics too large for one model request. Reviewers do not treat fragment boundaries as errors; duplicate findings are handled once.
- Evidence for a topic is written in original source order, regardless of the planner’s ID order.
- Source excerpt retrieval computes relevance once per passage rather than repeatedly while sorting.

Regression coverage includes a long synthetic multi-topic source with markers from every passage, deliberately omitted planner IDs, malformed planner output, incomplete editor replies and complete evidence-batch retention. Live Apple quality on the reported 62-minute lecture has not been verified without its original transcript and an eligible Mac.
