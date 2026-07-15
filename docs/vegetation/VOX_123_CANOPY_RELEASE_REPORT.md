# VOX-123 Canopy Release Report

## Outcome

VOX-123 is release-ready. The procedural canopy work is visually present in live generated worlds, deterministic, save-compatible, GPU-driven, and within the measured frame budget. The fixed-seed functional matrix and the complete protected NPC matrix are green.

This phase continued to treat `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md` as controlling for startup readiness and visible NPC evidence. No changes were made to `NpcPathing.gd` or `scripts/npc_ai/`.

Branch: `codex/vox-117-procedural-canopy`

Release commits through this report:

- `3d58f5e2` baseline and protected-system audit;
- `28561418` biome environment catalog;
- `eac862f3`, `95dcd746`, `8bbafdc2`, `52646889` mature generated canopy assets and current Godot pipeline;
- `4e6ee730` shared GPU environment wind;
- `0bd89de7`, `0e19a625` deterministic canopy integration and evidence;
- `54f4b1ee`, `6b89dfd2` live release runner, honest test cleanup, forest Continue readiness, and tightened visual acceptance.

## Release implementation completed in VOX-123

### Live canopy save/Continue runner

`tools/run-canopy-release-playtest.ps1` launches two headed processes through the production main menu.

The New Game process:

1. uses visible viewport input on the production New Game button with no `VOXEL_PLAYTEST` or test seed;
2. finds a real mature generated tree in a wooded biome;
3. performs fixture-only player placement and wooden-axe grant before the act phase;
4. targets the coherent production trunk and breaks it using real viewport mouse input;
5. observes the production falling-tree visual, log reward, and stable removed-prop state;
6. streams the chunk out and back and proves that the removed tree does not respawn;
7. saves the real forest state.

The Continue process uses visible input on the production Continue button, restores the saved forest position, waits for at least 12 mature trees around the observer, and proves that the harvested stable prop remains removed.

Fresh release seed `atlas-83978735` produced 55 mature trees within 72 m of the selected tree before harvest. The selected `mature_broadleaf_01` was 13.039 m tall with a 0.504 m trunk radius. Five live clicks granted three logs, created the falling visual, and completed the destruction path in 1.572 ms. Continue restored 12 nearby mature trees before capture and kept `atlas-83978735:313,-22:11` removed.

Reports and captures:

- `artifacts/vegetation/vox123-canopy-release-final/save-and-harvest.json`
- `artifacts/vegetation/vox123-canopy-release-final/continue-verify-dense.json`
- `artifacts/vegetation/vox123-canopy-release-final/screenshots/`

### Forest Continue collision readiness

The first forest Continue run exposed a genuine loading defect: 9 of 11 required initial voxel collision chunks published, while two tutorial-town-required chunks at the far edge of a player-connected component remained unpublished. The primary viewer did not cover the full component, but the startup code skipped an auxiliary viewer solely because the component contained the player chunk.

The generic fix now skips auxiliary publication only when the primary viewer actually covers every chunk in the component. The focused integration test constructs a player-connected region that extends beyond primary coverage and proves an auxiliary viewer covers its far edge.

This follows `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`: Continue does not emit playable readiness until all required collision facts publish. It does not guess collision readiness, reduce the required chunk set, special-case a tutorial NPC, or bypass collision-backed navigation.

Evidence:

- `tools/run-voxel-terrain-collision-publication.ps1 -Seed atlas-13279399 -ReportPath artifacts/vegetation/vox123-canopy-release/collision-publication-fix.json`
- 10/10 integration checks passed.
- The exact previously failing forest save then passed Main Menu -> Continue in 41.7 wall-clock seconds, and the final fresh Continue readiness domain completed in 32.412 seconds while the loading UI remained active.

## Visual acceptance

All nine procedural biome captures under `artifacts/vegetation/vox122-canopy-v5e/` were inspected at original resolution:

- forest midday, storm, night/torch, and traversal-line views show overlapping overhead crowns, walk-under trunks, and shade;
- taiga retains its taller conifer silhouette;
- swamp and savanna remain visually distinct;
- plains stays open;
- the town edge preserves roads, gate approaches, building clearance, and sightlines;
- no floating roots, buried pivots, trunk/visual mismatch, building penetration, or wind-displacement culling pop was observed.

The live harvest captures show individual leaf cards rather than one continuous crown mesh, a coherent thick trunk, the falling-tree state, and the harvested gap after chunk reload. The stricter Continue capture shows restored forest silhouettes around the saved position rather than accepting the first two streamed trees.

The headed production-shader wind fixture passed 8/8:

- 3.31% calm-to-storm canopy change;
- 3.67% asynchronous motion between storm instants;
- 3.15% moving daylight shadow-pattern change;
- 0.0592 night/torch average luminance;
- 72 draw calls, 25,050 primitives, and 72 rendered objects in every state.

Report: `artifacts/vegetation/vox123-environment-wind-visual.json`.

## Performance acceptance

### Unflagged normal runtime pass

`tools/run-normal-runtime-performance-pass.ps1` ran through production Main Menu -> New Game on fresh seed `atlas-30234053` for 1,945 measured frames and 673.94 m of sprint traversal.

- p50: 13.238 ms
- p95: 19.188 ms
- p99: 21.449 ms
- max: 28.377 ms
- max chunk work: 16.178 ms
- max chunk prop spawn: 16.022 ms
- max terrain meshing job: 4.809 ms
- max NPC update: 4.930 ms
- last spike reason: none

Report: `artifacts/performance/vox122-normal-sprint.json`.

### Focused sustained sprint observation

`tools/run-runtime-performance-observation.ps1 -Scenario SprintTraversal -Seed atlas-1492 -DurationSeconds 75` passed with 750 samples across 1,162.5 m.

- p50: 5.942 ms
- p95: 12.301 ms
- p99: 14.210 ms
- max: 18.513 ms
- 217 chunks created
- max chunk work: 3.238 ms
- max chunk prop spawn: 3.136 ms
- max tree creation section: 0.831 ms
- max NPC update: 2.788 ms
- last spike reason: none

The highest recorded section was sky at 14.222 ms, followed by sky/weather at 13.914 ms. Canopy prop work was not the worst-frame source.

Report: `artifacts/performance/vox123-sprint-observation.json`.

### Wind/material/resource bounds

The final environment-wind contract passed 11/11. Across 4,000 updates, CPU time averaged 3.475 microseconds; p50 was 3 us, p95/p99 were 4 us, and max was 8 us. Each update performs exactly five shader-global writes. The generated canopy registry used eight cached material roles and proved shared material reuse and per-instance phase without per-tree material duplication.

## Determinism and contracts

Two consecutive fixed-seed world signatures were byte-identical and matched the approved Phase 5 baseline:

- seed: `atlas-1492`
- SHA-256: `BEDD39F33317321C6294C5C980AE887340E62867FD28821284021F7E27F22BC6`
- 49 loaded chunks
- 896 props
- 338 trees

Reports:

- `artifacts/world-signature/vox123/run1.json`
- `artifacts/world-signature/vox123/run2.json`

Final focused contracts:

- biome environment catalog: 13/13;
- canopy asset import: 6/6, all 13 canopy GLBs imported;
- canopy runtime: 7/7;
- environment wind: 11/11;
- voxel terrain collision publication: 10/10;
- fresh-world movement: 13/13;
- fresh-world detail batching: 7/7.

## Functional and protected-system acceptance

The cleaned fixed-seed broad playtest passed 166/166:

`tools/run-playtest.ps1 -Seed atlas-1492 -ReportPath artifacts/vegetation/vox123-canopy-release/broad-playtest-fixed.json`

The protected contract suite passed 82/82 runs and 240 assertions at commit `6b89dfd2`.

The complete protected matrix passed 17/17 suites with zero failures in 842.416 seconds:

`tools/npc/run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts/npc/reports/vox123-all-npc-both.json`

Live headed evidence was inspected:

- real go-home: actor approaches, door opens before crossing, actor reaches strict interior, clears the threshold, and the door closes;
- real tutorial playthrough: Mira visibly departs after interaction and completes the same ordinary collision-backed home/door sequence;
- town job cycle: 20/20, including daytime activity, night door transitions, all non-guards strictly inside, and morning re-emergence;
- final rescue: site arrival, Sera/Niko combat choreography, completion, and return sequence passed. The camera-clipped Sera-attack screenshot is not cited as visual proof; the timeline and clearer return capture are used instead.

This is the acceptance boundary required by `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`. Contract booleans support the claim, but the visible headed sequences are the authority.

## Test cleanup

Every no-op `foliageSway` fixture key was removed. Production already uses the real shared environment-wind field; the obsolete key was not revived as misleading metadata.

The old aggregate ore/forage/tree checks were removed because they fabricated props and directly called destruction helpers. They are replaced by current dedicated evidence: real digging for terrain drops and the live viewport-input canopy runner for tree targeting, falling, drops, streaming, and saves.

The legacy `terrain_geometry` and `world_streaming` broad-section entry points were retired after fresh runs proved that they asserted removed `TerrainBody/TerrainCollision` ownership while production collision belongs to `VoxelTerrainRuntime`. No threshold was lowered. The current voxel publication and runtime performance runners replace those invalid assertions. Movement remains current and green. Detail batching remains current and green after removing its unnecessary legacy-streaming prerequisite.

## Explicit residuals

These are not hidden and were not repaired as canopy collateral work:

1. `tools/run-underground-visual-playtest.ps1` currently fails 6 of 27 checks: no underground mesh/collision publication for the selected visual fixture, four boundary/probe ray misses, and a ceiling sky-leak assertion. Report: `artifacts/underground/vox123-underground-current.json`. This is a current terrain issue, not a dated assertion, and remains outside VOX-123.
2. Fresh random broad seed `atlas-71512301` completed but reported four diagnostic failures: ranged collision, generic job outing, forager completion, and RMB door input. That broad runner is not an NPC/pathfinding acceptance runner under AGENTS.md. The fixed broad pass and the complete dedicated live NPC matrix are green; preserve the random seed for later focused reproduction rather than patching routing here.
3. Godot reports existing ObjectDB/resource/RID leak warnings while several headed test processes shut down. All reports completed and no runtime resource/material churn appeared in the measured gameplay window, but shutdown cleanup remains worth tracking independently.

## Exit decision

VOX-123 satisfies its exit gate. Visual canopy quality, GPU wind/shadows, deterministic generation, normal traversal performance, tree harvest/removal saves, New Game/Continue, and protected NPC/town behavior have current evidence. The residual underground and random-seed diagnostic concerns are explicit and do not justify changes to canopy or protected routing in this phase. VOX-117 can move to Done.
