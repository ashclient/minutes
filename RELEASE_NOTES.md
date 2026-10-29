# Minutes 2.7.1

Fixes two destructive local-generation behaviors in 2.7.0:

- Removed recursive whole-lecture compression into one 2,400-byte extract. Full evidence cards are retained in a ledger; a separate topic plan groups their IDs. Unknown, duplicate, omitted or malformed planner output cannot discard cards. Topic writers visit every retained evidence batch.
- Removed local word-count clipping. Length is requested through semantic selection and rewriting, rather than deleting whole lines from a response. Brief and Detailed are approximate targets; a complete topic is preferred to an artificially cut fragment.
- Incomplete topic output gets one bounded repair attempt. Dangling headings/labels/colon endings, unbalanced math/formatting and recognizable fabricated qualitative equations fail structural checks. These are safeguards, not a general fact checker.
- Editors that return incomplete or severely reduced content are rejected; the last complete topic remains intact. Source-backed corrections still require inference and can be imperfect.
- Topic writing now uses the existing 1–4 local worker slots, stable section IDs and tracked edit presentation. An optional verification pass checks complete topics using source excerpts.
- Source excerpt retrieval computes relevance once per passage rather than repeatedly while sorting.

Regression coverage includes a long synthetic multi-topic source with markers from every passage, deliberately omitted planner IDs, malformed planner output, incomplete editor replies and complete evidence-batch retention. Live Apple quality on the reported 62-minute lecture has not been verified without its original transcript and an eligible Mac.
