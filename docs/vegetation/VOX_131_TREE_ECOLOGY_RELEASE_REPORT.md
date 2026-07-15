# VOX-131 Tree Ecology Release Report

## Outcome

The player-facing ecology target is implemented: large trees are an ordinary age-distribution outcome in wooded biomes, older trees grow more branch generations and attached leaves, crowns create overhead shade, and bark retains readable scale. There is no canopy planner; existing valid tree placement plus biome age/phenotype rules produces the result.

`manifesto.md` and `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md` remain release gates. No protected pathfinding implementation changed and vegetation owns no town readiness or NPC command.

## Biome tuning and inspected visual evidence

The final nine headed captures are under `artifacts/visual/vox125-tree-ecology/` and were inspected at gameplay scale.

- Forest midday: eight old/ancient broadleaves within 48 m, 33.611-38.747 m high, 12.548-16.188 m crown radii, projected crown-area ratio 0.692.
- Forest traversal: 32 trees across the wider observation, overlapping crowns and a projected crown-area ratio of 2.76.
- Forest storm/night: the same canopy remains readable, sways asynchronously, casts moving shade, and is torch-readable at night.
- Taiga: tall old conifers provide a distinct vertical silhouette, roughly 37-42 m in the inspected stand.
- Savanna: mature broad crowns remain lower and flatter, roughly 22-24 m in the inspected stand.
- Plains: established/mature trees remain smaller, roughly 11.5-13.4 m, preserving open sightlines.
- Town edge: published building/road/gate exclusions remain clear.
- The selected swamp capture contains no requested-biome tree inside 48 m, so it is not cited as positive swamp-canopy proof; the profile/runtime contracts cover swamp configuration, and this limitation remains explicit.

Contact sheets prove monotonic architecture/leaf growth across all three species and five bands. Live forest captures prove the generated assets are actually selected in procedural gameplay.

## Performance

Unflagged Main Menu -> New Game random seed `atlas-69326680`:

- report: `artifacts/performance/vox131-ecology-sprint.json`;
- 1,872 measured frames, 615.12 m travel, 119 chunks created;
- p50 10.351 ms, p95 16.240 ms, p99 19.533 ms, max 27.059 ms;
- max chunk 13.953 ms; max chunk prop spawn 12.677 ms;
- max terrain meshing job 4.277 ms; max NPC 3.749 ms;
- no spike reason.

This is inside the completed VOX-123 envelope and shows no synchronous phenotype-generation or tree-publication hitch.

The normal world-edit latency runner recorded excellent direct operations:

- placement: wood 0.561 ms, torch 0.639 ms, lantern 0.807 ms;
- break: wood 0.346 ms, torch 0.154 ms, lantern 0.164 ms;
- follow-up queue peak 2.377 ms, below its 3 ms budget.

That runner's aggregate result is still red because an unrelated terrain meshing job reached 101.701 ms, navigation snapshot 15.483 ms, and autosave 3.398 ms. VOX-118 already recorded the same pre-canopy terrain hitch at 96.310/100.991 ms; the current direct edit numbers are below the pre-change audit and strict-audit edit values. This tree release does not patch terrain, navigation, or autosave collateral work.

## Determinism and signature publication

Two fresh `atlas-1492` signatures are byte-identical with SHA-256 `C6A282EC72EBEB76B3139CE2EE3CDF28CAF31CA95904DD8D32A879B36B053C88`.

The intended coherent trunk/collision change moved the observer across an exact streaming-window boundary, replacing one perimeter row of loaded chunks. Terrain samples, generated blocks, structure counts, tier counts, and town-home records are unchanged. All 628 overlapping stable prop IDs and records are byte-identical, proving no shared prop RNG reordering. The tracked signature baseline is updated honestly and must be republished through the official latest-artifact runner after its commit.

## Functional and protected evidence

- Blender re-import: 69/69.
- Visual manifest: 69/69.
- Canopy asset import: 9/9 across 43 tree GLBs.
- Biome catalog: 14/14.
- Canopy runtime: 9/9.
- Environment wind contract: 11/11.
- Headed environment wind visual: 8/8.
- Broad fixed-seed gameplay rerun: passed after updating two dated generated-asset smoke predicates to the ecological registry contract; production was not changed for the test.
- NPC contract: 82/82 runs, 240 assertions.

The first full protected aggregate passed 16/17 suites. Its only red suite was `streaming_save`: the newly updated working-tree baseline was compared with the still-old generated `latest` artifact. Blob inspection proves `latest` exactly matches the unchanged `HEAD` baseline (`2b4fec...`), while the new baseline exactly matches both new runs (`224f7d...`). This is an evidence-publication ordering failure, not a gameplay/pathfinding failure. No protected test or source was changed. The official signature and full protected aggregate will be rerun after the baseline commit; final results will be appended before Linear closure.

## Release boundary

The ecology implementation, visual acceptance, live harvesting/Continue, broad gameplay, direct edit latency, and normal traversal gates are green. Final release closure is conditional only on republishing the committed signature and obtaining a green protected aggregate with unchanged NPC/pathfinding code.

