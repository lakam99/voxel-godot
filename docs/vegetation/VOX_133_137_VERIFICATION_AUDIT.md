# VOX-133 through VOX-137 Verification Audit

Date: 2026-07-18
Status: tree-specific implementation, headed visual/interaction acceptance,
normal-runtime performance, protected tutorial regression, and formal
determinism release gates are green.

## Canonical tree authority

`TreeSpawnService` is the only public tree spawn entry point. The isolated
mathematical PoCs and production world trees both call it and therefore share
the exact oak, conifer, and savanna grammars.

- Broadleaf resolves to `bushy_oak`.
- Conifer resolves to `norway_spruce`.
- Savanna resolves to `umbrella_thorn`.
- The retired `rounded_broadleaf` request name is normalized to `bushy_oak` at
  the public boundary, including old direct/saved requests. It is no longer a
  production or visual-fixture family.
- The old generic rounded-broadleaf PoC contract was removed. Its obsolete
  1,050-segment/branch-order assertions did not describe the approved
  multi-season oak grammar. The focused oak, conifer, and savanna contracts
  remain the authoritative synthetic recipe checks.

## Green evidence

| Scope | Command or runner | Result |
| --- | --- | --- |
| Oak math | `MathematicalTreePocBushyOakContractRunner.gd` | deterministic, connected, pipe-model-correct, girth-derived, bounded oak recipe passed |
| Conifer math | `MathematicalTreePocConiferContractRunner.gd` | passed |
| Savanna math | `MathematicalTreePocSavannaContractRunner.gd` | passed |
| Broadleaf variety | `ProceduralTreeRecipeContractRunner.gd` | one oak grammar, 12 unique deterministic signatures and structural fingerprints |
| Queue/cache/LOD | `tools/run-tree-publication-queue-contract.ps1` | passed; queued visual work p99 333-406 usec in the focused fixture |
| Recipe/publication benchmark | `tools/run-procedural-tree-performance-benchmark.ps1 -ReportPath artifacts/vegetation/vox133-137-canonical-recipe-publication.json` | staged publication p99 273 usec, worst frame 334 usec |
| Executable shadow policy | `tools/run-canopy-runtime-contract-tests.ps1 -ReportPath artifacts/vegetation/vox147-near-only-shadow-runtime.json` | passed 15/15, including `near_only_shadow_policy_keeps_close_tree_shade_without_mid_distance_shadow_fill` |
| Shadow-aware recipe/publication | `tools/run-procedural-tree-performance-benchmark.ps1 -ReportPath artifacts/vegetation/vox147-near-only-shadow-recipe-publication.json` | staged work p99 163 usec, full queue-frame p99 289 usec; a mixed near/mid/far/impostor fixture now reports 103,004 shadow triangles instead of the prior 153,748 (33% less) without reducing close-tree detail |
| Renderer decision | `tools/run-tree-chunk-batch-prototype.ps1 -ReportPath artifacts/vegetation/vox134-renderer-comparison-canonical.json` | passed; staged per-tree hybrid remains selected and documented in `VOX_134_PROCEDURAL_TREE_RENDERER_DECISION.md` |
| Wind | `tools/run-environment-wind-contract-tests.ps1` | 11/11 passed |
| Wind visual | `tools/run-environment-wind-visual-playtest.ps1` | 8/8 passed in headed Forward+ with all four fixture trees from recipe authority |
| Live harvest + save/Continue | `tools/run-canopy-release-playtest.ps1 -ArtifactDir artifacts/vegetation/vox136-canopy-release-readable-pov` | passed on fresh seed `atlas-60605296`; real input harvest/fall/drop/removal persistence and Continue passed |
| Near-only policy live acceptance | `tools/run-canopy-release-playtest.ps1 -ArtifactDir artifacts/vegetation/vox147-near-only-shadow-release` | passed on fresh seed `atlas-83750281`; the daytime close-trunk and canopy captures show intact near-tree shading, and real-input harvest/fall/chunk-reload/Continue persistence all passed |
| NPC contract firewall | `tools/npc/run-npc-contract-tests.ps1 -TimeMode Both` | 84 runs / 246 assertions passed; contract evidence only |
| Broad gameplay integration | `tools/run-playtest.ps1 -Seed atlas-1492 -ReportPath artifacts/diagnostics/vox133-137-full-after-guard-fixture.json` | passed; the real guard target fired an observed shot and use animation |
| Hostile pool state | `tools/run-playtest.ps1 -Only hostiles -Seed atlas-1492 -ReportPath artifacts/diagnostics/hostile-pool-reset.json` | passed; a reused body clears runtime hostile metadata before a fresh spawn |
| Real tutorial playthrough | `tools/npc/run-real-tutorial-playthrough.ps1 -TimeMode Both -Visible -Seed vox133-137-release-20260718 -ReportPath artifacts/npc/reports/vox133-137-real-tutorial.json` | passed 8/8 from Main Menu -> New Game with real player/NPC/door/bed/forager behavior; the runner enabled godmode for the night-safe run |
| Fixed-seed traversal observation | `tools/run-runtime-performance-observation.ps1 -Scenario SprintTraversal -Seed atlas-1492 -DurationSeconds 60 -WarmupFrames 120 -ReportPath artifacts/performance/vox133-137-final-fixed-observation/sprint.json` | passed; whole run p99 21.222ms, tree publication p99 0.314ms, full tree queue frame p99 0.453ms, max 0.955ms, no dropped work |
| Fresh tree publication benchmark | `tools/run-procedural-tree-performance-benchmark.ps1 -ReportPath artifacts/vegetation/vox133-137-final-tree-publication-benchmark.json` | passed; staged publication p99 0.171ms, max 0.258ms; full queue frame p99 0.251ms, max 0.282ms |
| Fresh post-worker-pool normal runtime | `tools/run-normal-runtime-performance-pass.ps1 -ReportPath artifacts/performance/vox133-137-final-normal-sprint-post-native-fix.json` | passed on fresh seed `atlas-65598237`: 2,449 measured headed frames, p50/p95/p99/max 9.327/15.207/17.050/26.542ms; tree stage p99 0.474ms, full tree-queue frame p99 0.750ms and max 1.332ms, with zero dropped tree requests |
| Fresh post-worker-pool tree benchmark | `tools/run-procedural-tree-performance-benchmark.ps1 -ReportPath artifacts/vegetation/vox133-137-post-native-tree-publication.json` | passed: staged publication p99 0.890ms and max 1.113ms; complete queue-frame p99 0.952ms and max 1.247ms |
| Fresh live harvest + save/Continue | `tools/run-canopy-release-playtest.ps1 -ArtifactDir artifacts/vegetation/vox136-post-native-canopy-release-retry` | passed on fresh seed `atlas-11057900`: a 62.03m mature oak rendered at near LOD, real targeting and five input swings produced a single non-colliding structural-wood fall, removal persisted through chunk reload and Continue, and Continue restored 12 rendered trees / 10 upper-age trees near the saved player position |
| Fresh protected tutorial acceptance | `tools/npc/run-real-tutorial-playthrough.ps1 -TimeMode Both -Visible -Seed vox133-137-post-native-20260718 -ReportPath artifacts/npc/reports/vox133-137-post-native-real-tutorial.json` | passed 8/8 from the real main menu flow: real door input, 36 repair placements, sleep progression, guard/non-guard matrix, and Niko's reserved-resource forage cycle; the runner's static shortcut audit passed first |
| Fresh broad integration | `tools/run-playtest.ps1 -Seed atlas-1492 -ReportPath artifacts/playtest/vox133-137-post-native-full.json` | passed all assertions on the fixed comparison seed |
| Fresh runtime/save authority | `tools/run-canopy-runtime-contract-tests.ps1 -ReportPath artifacts/vegetation/vox133-137-final-canopy-runtime-contract.json` | passed 16/16, including non-GLB runtime authority, continuous bole/collision bounds, exclusion/RNG parity, removed-tree persistence, and additive legacy-save restoration without serialized branch topology |
| Fresh wind contract | `tools/run-environment-wind-contract-tests.ps1 -ReportPath artifacts/vegetation/vox133-137-final-wind-contract.json` | passed 11/11, including shared cached procedural bark/foliage materials, per-tree phases, global wind bounds, and no static tree authority |
| Fresh headed wind visual | `tools/run-environment-wind-visual-playtest.ps1` | passed 8/8 in Forward+: four procedural canopies, storm strength/asynchronous motion, moving daylight shade, readable torch-lit night canopy, and recipe authority |
| Fresh canopy import authority | `tools/run-canopy-asset-import-contract-tests.ps1 -ReportPath artifacts/vegetation/vox133-137-final-canopy-asset-import.json` | passed 11/11; complete-tree GLBs remain importable reference assets but are excluded from runtime authority |

The direct `run-tree-spawn-performance.ps1` result is recorded as a diagnostic
only. It measures one-shot visual instantiation (p99 2.76ms), which is not the
bounded worker/queue publication path and must not be cited as traversal frame
evidence.

## Determinism

The old signature fixture recorded whichever streaming chunks happened to
remain loaded. Its replacement declares one fixed 7×7 chunk observation
window around the signature town, waits until that exact window is published,
and filters props to the same window. The runner and regenerated baseline were
committed together as `168f0684` so this is an explicit fixture-contract
migration, not an implicit world-content acceptance.

Two official runs both passed byte-for-byte against the committed baseline:

- `tools/run-world-signature.ps1 -OutputPath artifacts/world-signature/vox133-137-formal-baseline/atlas-1492.json`
- `tools/run-world-signature.ps1 -OutputPath artifacts/world-signature/vox133-137-formal-baseline-repeat/atlas-1492.json`

Both runs produced SHA-256
`589468D555206F3EAAABF2CE9058A75269A7EF446FC70793D9BC7546E94C12E6`,
completed 1,346 deterministic surface-prop attempts, and exited without the
previous retained-resource diagnostics.

## Release blockers and follow-up issues

1. **VOX-147 - normal runtime traversal is resolved by worker-pool meshing.**
   The fresh normal headed run above meets both the strict 22ms p99 and 33ms
   hard-stall gates, with no tree-attributed spike or dropped request. The
   prior `terrain_meshing_job_queue` worker-start stall is no longer a
   VOX-135/VOX-137 release blocker.
2. **VOX-144 - generated-world shutdown lifecycle:** resolved by a terminal
   teardown that releases the legacy navigation façade and autonomy graph
   instead of rebuilding world-reset services during application exit. The
   post-fix verbose graphical New Game run reports no ObjectDB or retained
   resource diagnostics; an isolated visible Continue run also passes.

VOX-148 and VOX-149 are Done. The current real tutorial run is green; VOX-98
remains a separate in-progress player-driver improvement, not a blocker for
the verified tree/NPC tutorial flow.

## Current re-verification (2026-07-18)

This additional pass was run after the worker-pool/tree-publication
optimisation and the native navigation-world reset fix. It does not replace the
evidence above; it confirms that the latest worktree still meets the active
tree contracts. The subsequent canonical-window fixture migration is recorded
in the determinism section above.

| Scope | Command or runner | Result |
| --- | --- | --- |
| Tree recipe/publication microbenchmark | `tools/run-procedural-tree-performance-benchmark.ps1 -ReportPath artifacts/vegetation/vox133-137-current-tree-publication-recheck.json` | passed; staged publication p99 146 usec, full queue-frame p99 178 usec, worst queue frame 278 usec; 700 branches and 1,033 foliage instances across near/mid/far/impostor with no dropped request |
| Renderer decision prototype | `tools/run-tree-chunk-batch-prototype.ps1 -Visible -ReportPath artifacts/vegetation/vox133-137-current-renderer-comparison.json` | passed 3/3 on Forward+; candidate A reduced its estimate to 27 submission roles versus 36 for the selected local hybrid, but still required 972 synchronous slot swaps / 3.868 ms to remove one tree, confirming that it remains an isolated non-production candidate |
| Normal headed sprint | `tools/run-normal-runtime-performance-pass.ps1 -DurationSeconds 60 -WarmupFrames 120 -Scenario NormalSprintTraversal -ReportPath artifacts/performance/vox133-137-current-normal-sprint.json` | passed on fresh seed `atlas-31332326`; 1,885 measured frames, p50/p95/p99/max 9.591/15.648/18.965/26.585 ms, staged tree self-time p99 0.417 ms and max 0.547 ms, full tree queue frame max 1.629 ms, zero dropped tree requests |
| Wind contracts | `tools/run-environment-wind-contract-tests.ps1 -ReportPath artifacts/vegetation/vox133-137-current-wind-contract.json` | passed 11/11 |
| Headed wind fixture | `tools/run-environment-wind-visual-playtest.ps1 -ReportPath artifacts/vegetation/vox133-137-current-wind-visual.json` | passed 8/8 in Forward+; four recipe-driven trees, visible storm/asynchronous motion, daylight shadow motion, and readable torch-lit night canopy |
| Canopy runtime/save authority | `tools/run-canopy-runtime-contract-tests.ps1 -ReportPath artifacts/vegetation/vox133-137-current-canopy-runtime-contract.json` | passed 16/16, including non-GLB authority, continuous bole/collision, save removal, Continue, and additive legacy-save fields |
| Live canopy interaction | `tools/run-canopy-release-playtest.ps1 -ArtifactDir artifacts/vegetation/vox145-current-live-canopy` | passed with real targeting, five input swings, fall/drop, chunk reload, and Continue |
| Protected NPC contracts | `tools/npc/run-npc-contract-tests.ps1 -TimeMode Both` | passed 84 runs / 246 assertions; contract evidence only |
| Real tutorial | `tools/npc/run-real-tutorial-playthrough.ps1 -TimeMode Both -Visible -Seed vox133-137-current-20260718 -ReportPath artifacts/npc/reports/vox133-137-current-real-tutorial.json` | passed 8/8 from main menu through real door input, 36 repair placements, sleep/morning, guard behavior, and Niko’s real reserved-resource gather; night player godmode was active only for test survivability |
| Generated-town job cycle | `tools/npc/run-npc-town-job-cycle-visual-playtest.ps1 -Seed vox133-137-current-town-jobs -ReportPath artifacts/npc/reports/vox133-137-current-town-job-cycle.json` | passed 25/25 headed natural-observation acceptance: day jobs, resource release, night returns/doors, and morning emergence |
| Broad game integration | `tools/run-playtest.ps1 -Seed atlas-1492 -ReportPath artifacts/playtest/vox133-137-current-full-after-isolation.json` | passed after keeping the long generated-town job cycle in its fresh-world dedicated acceptance rather than running it after unrelated in-session New Game mutations; the fresh `-Only structures` coverage also passed its real forager gather/release case |
| Deterministic repeat | direct `WorldSignature.tscn` runs writing `artifacts/world-signature/vox133-137-current-a.json` and `...-b.json` | identical SHA-256 `589468D555206F3EAAABF2CE9058A75269A7EF446FC70793D9BC7546E94C12E6` |
| Official deterministic baseline | `tools/run-world-signature.ps1` twice, writing `artifacts/world-signature/vox133-137-formal-baseline/atlas-1492.json` and `.../vox133-137-formal-baseline-repeat/atlas-1492.json` | both passed against the committed 7×7 canonical-window baseline and exited cleanly; each completed 1,346 deterministic prop attempts |
| Family-age ecology coverage | `tools/run-canopy-runtime-contract-tests.ps1 -ReportPath artifacts/vegetation/vox136-family-age-ecology-coverage.json` | passed 17/17; the shared production sampler produced mature/old counts of 310/188 (forest), 302/172 (taiga), and 315/184 (savanna) across 625 deterministic samples per biome |
| Headed family-age interaction matrix | `tools/run-procedural-tree-interaction-matrix.ps1 -ArtifactDir artifacts/vegetation/vox136-family-age-interaction-matrix-parity -WatchdogSeconds 420` | passed 6/6 independent Main Menu -> New Game runs: broadleaf/conifer/savanna at mature and old. Every selected natural tree was published from the recipe, hit with real viewport input, felled/dropped, kept removed through chunk reload, and preserved after save/Continue; break work ranged from 1.500ms to 2.576ms |
| Generated-world graceful exit | `tools/run-main-menu-startup-readiness-smoke.ps1 -RuntimeReset -Visible -TestSeed vox144-resource-after-teardown -ReportPath artifacts/playtest/vox144-exit-resource-after-teardown/main-menu-runtime-reset-wrapper.json` plus a verbose counterpart | passed with six tutorial NPCs and a 22,784ms in-session reset; the prior six retained resources/ObjectDB warning did not recur in the post-fix verbose graphical exit |
| Isolated Main Menu Continue | `tools/run-main-menu-continue-readiness-smoke.ps1 -Visible -ReportPath artifacts/playtest/vox144-continue-after-teardown/continue-readiness.json` | passed with six NPCs and no runner shutdown/error diagnostics; the runner created and removed its isolated fixture save |
| Full headed tutorial plus production exit | `tools/npc/run-real-tutorial-playthrough.ps1 -TimeMode Both -Visible -GodMode -Seed vox144-production-exit-20260718 -ReportPath artifacts/npc/vox144-production-exit-tutorial/real-tutorial.json` | passed 8/8 through real door input, repair placements, sleep/morning, guard behavior and Niko's forage cycle; its runner now requests `MainCore.request_graceful_quit`, and the raw engine logs contain no ObjectDB/resource, script, or native-access-violation diagnostics |

The current signatures match each other and the committed canonical-window
baseline. The official wrapper passed twice after the fixture migration.

The native Windows access violation no longer reproduced after explicit
navigation-map retirement during graceful exit. The final teardown additionally
removes the navigation-owned ObjectDB/resource leak: the post-fix verbose
graphical New Game exit reported zero retained resources, and the visible
isolated Continue flow, full headed tutorial, and standalone world-signature
fixture also exited cleanly. This is shutdown-lifecycle evidence, not a
tree-performance result.
