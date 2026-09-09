# Lower facade assembly proof reuse, 2026-09-09

On codex/citadel-visuals-clean after fa5927b, LowerFacadeBearingRecipe reuses unchanged masonry footprint support records in its private assembly proof only when all new members are cardinal and every cached sample is outside their bounds expanded by 0.5. New members and affected originals resolve normally. Complete physical dependency, rootedness and explicit finite-joint checks still run. Object-keyed records are isolated copies and cleared after one validation, including cancellation. No NPC/navigation changes.

Evidence under artifacts/citadel-runtime-integration:
- lower-support-reuse-01: 159 producer checks pass.
- lower-support-differential-02: 21 checks pass; three captured assemblies over 666 roots retain exact full reports/snapshots. About493 records reused, ~187ms baseline versus43ms candidate per assembly. Controls verify near-member exclusion, rotated fallback and map cleanup on success/cancellation; they do not establish full differential results for those negative cases.
- candidate-recipe-28: 149.096s total, all4555 physical checks pass, zero violations, clean owned-zero. Prior candidate27 took162.696s. Full28 preceded the final conservative rotated fallback and one-shot cleanup; focused controls cover those changes.
- source-diff-27-28: recursive Variant comparison found only civicClearance/elapsedUsec different. No generated blueprint/furniture value differences.
- Temporary cardinal vertical rejection was measured separately in support-query-02 but removed: it did not demonstrate a material gain beyond the committed arithmetic path.

All verification is headless source/contract evidence, not live player traversal or 90-second arrival acceptance. The90-second goal remains active. Next: remove repeated immutable input preparation and redundant boundary proofs, then measure the next complete candidate before headed publication.

