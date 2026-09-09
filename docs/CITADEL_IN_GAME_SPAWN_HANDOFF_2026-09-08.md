# Citadel In-Game Spawn Handoff — 2026-09-08

## Goal

**Continue until the citadel spawns correctly in the real game.** Preserve the approved citadel blueprint, Golden Alley/Solitude visual character, and recipe-driven furniture. Integrate through production world generation, terrain, streaming, and tree recipes. Do not revive citadel-specific NPC routing/navigation; the broken production NPC baseline is explicitly deferred.

Work is paused at the user's request. Do not resume tests or edits until this handoff is picked up.

## Frozen repository state

- Worktree: `C:\Users\arkam\Documents\Codex\2026-06-18\goal-develop-a-3d-voxel-seed\outputs\voxel-biome-world-godot-citadel-visuals`
- Branch: `codex/citadel-visuals-clean`
- HEAD: `e09cc95b6211ecfb7de1fcf9902406b0cb176a5d` (`Anchor failed market bunting to its generated facades`)
- Godot: 4.6.1
- Live Godot processes at pause: none
- Goal tracker objective: `continue until citadel spawns correctly`; execution is paused by the user (tracker presently reports `usageLimited`, not completion).

Before this handoff file was added, the only working-tree changes were:

```text
 M scripts/buildings/CivicHouseInfillRecipe.gd
?? scripts/testing/buildings/CitadelCivicClearanceDiagnostic.gd
```

This document itself is now a third untracked file. Do not reset, clean, or discard any of the three.

## Current approach

1. Citadels are rare deterministic landmarks in any non-ocean/non-cave biome; existing blocky towns remain unchanged for now.
2. Use the real game authorities: ordinary world candidate selection/admission, terrain reservation, streaming/publication, production procedural trees, collision, and structure recipes.
3. Keep all visual and furniture placement logic recipe-based—no authored seed repair, hand placement, PoC-only tree spawner, metadata success, or runtime prewarming.
4. Reach a remote candidate with the committed teleport playtest runner (`ea1757a`, updated by `20dffac`). Teleport is fixture setup only; it does not count as traversal/NPC acceptance.
5. Clear deterministic source/physical-integrity gates before launching the headed runner. A read-only critic must explicitly approve headed readiness first.
6. Every Godot launch must use the owned-process watchdog and prove zero remaining job members. Stop broken/timed-out runs immediately.

## How this point was reached

- The earlier attempt coupled the citadel PoC to separate NPC/navigation-publication work and became slow and fragile. The clean direction retained the citadel's visual blueprint and furniture while dropping citadel-specific NPC/pathfinding requirements.
- Visual verification and the ordinary tree baseline were accepted. Integration then moved to real world candidate spawning rather than a separate PoC scene.
- A candidate teleport runner was added so distance to a rare landmark would not dominate test time. It still exercises real generation/admission/streaming after setup.
- Full deterministic candidate construction exposed successive recipe gates. Recent focused fixes, each committed with contracts and reports, were:
  - `861ba73` fit civic houses inside retained walls and reconcile terrace footprints.
  - `ee51a8e` constrain urban streets to the retained keep/entrance boundary.
  - `d093c89` reuse party-wall proofs and reject impossible contacts early.
  - `d9f6570` validate residence candidates once per ordered obstacle batch.
  - `bc4cfaf` reserve real doorway clearance for façade supports.
  - `e09cc95` repair only the failed market-bunting assembly by anchoring it to generated opposing façades. It preserves 13 flags, styling, sag, dimensions, materials, and rotation; it adds no posts and changes no NPC/nav/tree/furniture/door behavior. Its focused suites passed (91/91, 33/33, 83/83, 83/83).
- Candidate Recipe 16 then passed the bunting/structural-completion stage and exposed the later `civic_house_infill` clearance gate. It failed `urban_civic_house_east` with `no_clear_fixed_x_placement` after three candidates. This was useful forward progress, not a bunting regression.
- The initial theory was that furniture access reservations blocked their own house. The pinned offline diagnostic disproved it: 154 furniture parts reproduced byte-for-byte, both civic envelopes matched, both houses passed in the earlier captured stage, and there were zero blockers there. Therefore the blocker is introduced later in composition.
- Failure-only instrumentation was added and validated locally, then the critic approved exactly one unchanged-budget terminal Recipe 17 diagnostic. The critic did **not** approve an ownership fix, commit, or headed test.

## Exact uncommitted changes

### `scripts/buildings/CivicHouseInfillRecipe.gd`

46 insertions/1 deletion, diagnostic only:

- Propagates cancellation returned by `Placement.fit` instead of reporting clearance failure.
- On an existing failed stored-pose clearance decision, records `blockingEvidence` across the same part/room/access/circulation/plan-access/furnishing obstacles.
- Records exact kind/ID/bounds, full count and counts by kind; stores at most 32 rows and marks truncation.
- Defers expensive part snapshots until a row is inside that 32-row cap.
- Does **not** alter obstacle membership, geometry, placement candidates, clearance thresholds, or acceptance.

### `scripts/testing/buildings/CitadelCivicClearanceDiagnostic.gd`

Offline diagnostic only. It pins:

- `facade-input-capture-03/input.bin` SHA-256 `1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c`
- Recipe 16 `failure.bin` SHA-256 `d29a3150a9d5f79b022b3ab00a5988d32952b9a1c9f2775cc2d3102d2580d792`

It proves the stage boundary, exact regenerated furniture/envelopes, absence of blockers in the pre-structural capture, cancellation, exact 1/33 synthetic blocker reporting, and the 32-snapshot cap. Latest focused evidence:

- `artifacts/citadel-runtime-integration/civic-clearance-diagnostic-03`: 20/20, natural exit 0, clean owned-process zero.
- `artifacts/citadel-runtime-integration/civic-house-infill-19`: 196/196, natural exit 0, clean owned-process zero (run before the final two tiny instrumentation refinements; those refinements received critic review for Recipe 17 diagnostic use).

## Exact stopping point and terminal evidence

Recipe 17 is complete; do **not** rerun it merely to rediscover the result.

- Artifact directory: `artifacts/citadel-runtime-integration/candidate-recipe-17`
- World seed: `atlas-30895044`
- Region: `(-1, 0)`
- Site: `citadel-site-v1:14:atlas-30895044:-1,0`
- Recipe seed: `541151883`; biome `forest`; scale `1.25`
- Result: `citadel_final_civic_clearance_failed`
- House: `urban_civic_house_east`
- Detail: `no_clear_fixed_x_placement`; 3 candidates
- Source preparation: 322.921 s; timeout budget 540 s
- Natural functional exit 1; no timeout, no forced cleanup, empty stderr, authoritative job-membership zero, no remaining PIDs
- Input SHA-256: `7223dfe9dade6f2ca3876a775ff12b8d7786871f577f40fbe4728bf8bd26147c`
- Failure SHA-256: `bec29f97da604a4a5efc4872179d01da84ea39aa2324a60b296b8e40044f5517`
- Evidence level is source-only replay plus physical-integrity validation: it proves neither site/runtime publication nor visuals/gameplay.

The failed east-house envelope overlaps exactly four `castle_courtyard_foundation` parts:

```text
castle_compound_foundation_segment_43
castle_compound_foundation_segment_45
castle_compound_foundation_segment_46
castle_compound_foundation_segment_47
```

All four are collision-enabled `foundation` parts at Y `0.0..0.62`, marked `navigationRole=structural_mass` and `egressCarved=true`. There are no furniture, room, access, circulation, or façade-bearing blockers in Recipe 17. Earlier speculation about `facade_bearing_*` ownership is therefore superseded.

## Next work, in order

1. Trace those four foundation segments to their producer and intended ownership/support relationship with `urban_civic_house_east`. Determine whether they are valid supporting underlay that the clearance gate fails to recognize, or genuinely conflicting retained-courtyard geometry. Inspect the exact XZ overlap against the east-house envelope before editing.
2. Fix the lowest recipe authority. If they are intended underlay, publish explicit producer-owned support/house provenance and consume it generically; preserve stable IDs and geometry if possible. If they are a real conflict, repair deterministic foundation segmentation/egress carving. Do not whitelist these IDs, infer ownership only by proximity, weaken clearance, move the house by authored offset, or delete visible architecture blindly.
3. Add focused contracts covering both the valid relationship and a foreign/mixed-house fail-closed case. Preserve cancellation, source immutability, deterministic signatures, geometry, furnishing, doors, and visual recipe output.
4. Submit the patch and evidence to a harsh read-only critic. Commit only after `PASS`.
5. Run one fresh full candidate-source diagnostic at unchanged budgets. It should either advance to the next honest gate or become recipe-ready. Never loop the multi-minute source run without a new falsifiable change.
6. When the source and integration gates are ready, obtain explicit critic `GO` for the headed candidate teleport playtest. Then inspect the screenshot and live terrain/collision/structure/tree/door/furniture publication. Headed testing remains prohibited before that approval.
7. Commit each accepted behavior-sized change. Final completion requires the citadel to appear correctly in `Main.tscn` through normal production integration; a green source replay or teleport setup alone is insufficient.

## Do not repeat these mistakes

- Do not optimize unrelated navigation scheduler machinery; it is outside this cleaned visual/spawn objective.
- Do not launch long/headed runs while a deterministic earlier gate is known red.
- Do not assume the newest visible blocker is furniture, façade ownership, or NPC routing—Recipe 17 has exact part IDs.
- Do not treat a synthetic/offline diagnostic as gameplay acceptance.
- Do not leave failed Godot children running. Require the watchdog's authoritative zero proof for every run.
- Do not modify or regress the approved blueprint, market treatment, roofline, trees, or furniture to make a validation boolean green.
