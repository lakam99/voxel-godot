# Citadel spawn performance handoff — 2026-09-11

## Start here

**The citadel spawns, but faster spawning and smooth traversal have not been achieved.** The latest worker experiment is unpromoted: it passes its diagnostic completion checks, takes slightly longer to release the player, and introduces more movement holds. Continue from the existing working tree; do not mistake a green report for performance acceptance.

The user’s priority is reducing citadel spawn time **without regressing FPS or physical behavior**. This document covers that work only. General project guidance is in [AGENTS.md](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/AGENTS.md); navigation-publication boundaries remain governed by [MANIFESTO.md](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/MANIFESTO.md). The wider architecture specification remains in [WORLD_STREAMING_ARCHITECTURE_PLAN.md](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/docs/WORLD_STREAMING_ARCHITECTURE_PLAN.md), but its historical notes are not a substitute for the current evidence below.

## Exact worktree and branch

Use this existing Godot project directory:

```text
C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals
```

- Branch: **codex/world-streaming-architecture**.
- Last implementation checkpoint: **f9ad747**, “Checkpoint regional loading before citadel performance cutover.”
- Earlier relevant milestone: **ea691ed**, “Prepare runtime navigation on workers and bound live prop collision.”
- The architecture branch descends from the user-approved **2c71199** starting point.
- The default sibling directory named `voxel-biome-world-godot` is a different worktree/branch. Do not run tests or apply these edits there.
- **Important:** the worker experiment and newest fixture changes are uncommitted. A fresh checkout of the branch will not contain them. Retain this directory and its ignored artifacts.
- Recheck `git status --short`, `git branch --show-current` and `git log -1 --oneline` on arrival. A documentation-only handoff commit may follow f9ad747; that does not promote the runtime changes.

Both assisting agents have stopped and been closed. The last owned Godot run completed naturally with authoritative zero remaining job members. No continued development or background test is intended after this handoff.

## What is implemented, and what is still incomplete

The committed implementation already prepares masonry/paving/roof rendering data on owned workers and publishes through the existing building preparation/publication owners. It also prepares source-owned navigation artifacts and retains regional demand. These are parts of the architecture, not a completed performance claim.

The current uncommitted experiment moves navigation surface filtering into the existing navigation worker. The adapter captures terrain/door/collision facts; one worker filters them and builds the descriptor; the publication service retains the exact accepted facts with the installation; regional readiness consumes those facts and actual acknowledgements. It does not replace NPC route search, movement, door execution or traffic.

The full physical citadel is still required by the current structure publication gate. Dependency-complete regional physical publication, allowing required nearby portions before the entire citadel completes, is **not finished**. A composed regional API alone does not establish that cutover.

Building distance tiers/occlusion, production tree batching evaluation, resumable large rendering uploads throughout, and any justified terrain/native calculation cutovers remain incomplete. An earlier smaller spatial-group experiment was not promoted because additional submissions did not consistently pay for themselves. Do not re-enable it without measured benefit.

The intended contract remains:

- A genuinely playable 64m horizontal region, expanded for real supports/crossings/dependencies.
- Initial rendering cells of 32 terrain cells, or 43.2m; explicit intersections with existing terrain/navigation grids.
- Preserve source ownership, near geometry/materials, door identities, stairs, collision and durable edits; save format stays v2.
- Keep the initial 4ms cooperative publication budget; split oversized operations rather than assuming the budget interrupts them.
- Near/middle/far appearance distances of 96/192/384m with hysteresis remain the planned starting values.
- Original load target: 90 seconds. The user questioned whether regenerated worlds make this realistic; **no replacement threshold was agreed**. Report cold generation and warm saved-world behavior separately rather than silently relaxing it.
- 1080p traversal target: sustained 60 FPS, p99 at most 33ms, no recurring streaming stalls above 33ms and no frame above 100ms. Current evidence fails this target.

## Working-tree changes to preserve

The original eight-file worker integration consists of:

| File | Change |
|---|---|
| [GeneratedWorldNavigationAdapter.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd) | Captures owned filter input; borrows current accepted facts; retires input caches through the publication owner. |
| [NavigationTileFilter.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/npc_ai/navigation/NavigationTileFilter.gd) | New, currently untracked pure worker filter. |
| [NavigationPublicationSource.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/npc_ai/navigation/NavigationPublicationSource.gd) | Validates/seals filter inputs and admitted building leaves. |
| [NavigationPublicationWorker.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/npc_ai/navigation/NavigationPublicationWorker.gd) | Filters, then prepares the descriptor from the same accepted source; transfers a one-shot payload. |
| [NavigationPublicationQueue.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/npc_ai/navigation/NavigationPublicationQueue.gd) | Carries accepted facts, diagnostics and profiles with descriptor/upload/retirement. |
| [NavmeshWorldService.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/npc_ai/navigation/NavmeshWorldService.gd) | Validates source/owner and binds accepted facts to descriptor and installation serial. |
| [RegionalNavigationPublication.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/world/RegionalNavigationPublication.gd) | Derives regional proof from accepted facts and current receipts. |
| [CitadelCandidateTeleportPlaytest.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd) | Waits for accepted publication before inspecting source arrays. |

Four fixture files were subsequently updated by the assisting agent:

- [StartupLoadingReadinessContractRunner.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/testing/StartupLoadingReadinessContractRunner.gd): synthetic accepted-source/weak-owner migration.
- [NpcRouteTestCases.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/testing/npc/NpcRouteTestCases.gd): await actual worker/service acceptance before surface assertions.
- [NpcAutonomyTestRunner.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/testing/npc/NpcAutonomyTestRunner.gd): separate captured/collision facts from accepted surfaces.
- [NavigationShutdownLifecycleContractRunner.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/testing/NavigationShutdownLifecycleContractRunner.gd): payload migration and filter identity, immutability, owner/source replacement, reuse, cancellation and empty-result cases.

**These four latest fixture edits have only standalone grammar and whitespace checks. They have not been compiled by Godot or executed.** Earlier passing suites do not validate them. There are no half-written files or pending agent edits. Review their diff and run one focused batch before treating them as usable evidence.

The architecture progress document also has uncommitted notes from the preceding work. Its statement that fixture migration is pending is superseded by the applied-but-unverified state above. The ignored [navigation-filter-worker-draft directory](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/navigation-filter-worker-draft) contains the original patch, proposed copies and partial fixture patch. These are historical working artifacts; **do not reapply them over the current files**.

## Latest headed citadel comparison

Both runs use world seed **atlas-3376622889**, candidate region **-2,-2**, recipe seed **1393179273**, and initial spawn cell **-3334,-2666**. The spawn is selected before scene attachment; there are zero setup teleports. Later diagnostic camera views are not ordinary interior traversal.

| Measurement | Headed11, before filter experiment | Headed12, filter experiment |
|---|---:|---:|
| Player startup release | 130.809s | 132.663s |
| Ordinary-input exterior approach | 11.993s | 32.391s |
| Held motion samples | 0 / 12 | 16 / 31 |
| Maximum sampled recovery count | 1 | 10 |
| Approach frame cadence p99 | 154.4ms | 154.4ms |
| Worst approach frame cadence | 208.482ms | 243.911ms |
| Diagnostic checks | 28 / 28 | 28 / 28 |

Evidence:
[headed11 report](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/candidate-teleport-regional-composed-11/report.json),
[headed12 report](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/candidate-teleport-navigation-filter-12/report.json),
[headed12 process/source verification](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/candidate-teleport-navigation-filter-12/verification.json).

Headed12 exits naturally with code 0, no engine errors/warnings, no changed frozen sources, cleanup passed and zero owned processes. Source signatures match headed11:
`b29eabb4fb8e28b3bb0ff53325e69ec2a72d05797280793b130bb49401427752`.
That supports unchanged generated citadel source, not complete navigation-buffer equivalence.

Inspected [initial spawn](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/candidate-teleport-navigation-filter-12/initial_spawn_ready.png) and [courtyard](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/candidate-teleport-navigation-filter-12/courtyard_overview.png) captures show continuous visible terrain, citadel walls/towers and courtyard buildings. The runner also records door, stair and furniture views. A clipped/occluded camera is not proof of a usable landing. There is no claim that every interior, gate, staircase or NPC route was physically traversed.

Headed12 timing:

- Landmark preparation: approximately 3.181–77.984s, about 75s.
- Terrain loading begins at 78.123s; collision is ready at 88.604s.
- Nearby readiness: 88.720–132.578s, about 44s.
- Entire runner: 185.611s, including approach, inspection/export and shutdown.

Some work overlaps these phases. These durations are not additive exclusive CPU costs. Neither headed run establishes controlled empty-generated-cache acceptance.

Approach rendering CPU/GPU maxima are 7.159/7.730ms. The largest measured navigation snapshot call is 154.009ms. Its separate capture maxima are terrain 150.150ms, live collision 48.602ms, sealing 12.313ms; these maxima occur in different calls. Worker filtering reaches 85.954ms off-thread. GPU rendering is not the dominant measured explanation for these stalls.

## New source profile: use this instead of older expensive profiles

The final source-only run completed during handoff:
[source profile32 report](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/report.json),
[timings](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/timings.json),
[execution](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/execution.json),
[owned-process watchdog](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/node-tools/process-runs/godot-A8UgGc/watchdog.json).

It used the existing `CitadelCandidateRecipeDiagnostic.gd` through `runGodotProcess`, with the exact seed/region/recipe above and `ExpectReady` behavior. This was a direct source profiling launch, not the top-level wrapper’s frozen-source audit. Source-generation files were not changed during the run; unrelated navigation fixture work proceeded separately.

Results: **70.139s recipe preparation**, 1.272s independent physical validation, 4584 building parts and 178 furnishing parts. All 4584 physical checks passed; context was unchanged. Furniture validation, full terrain-envelope survey, terrain rendering, live collision and gameplay are outside this source-only result. The source artifact hash is `42f3c7b2ff1dee451f98dbd286c1a2d346c9e0033326f578ec8a6fea75418067`; it is a different artifact/hash contract from the runtime manifest signature above.

Largest callback-family wall intervals:

| Callback family | Total interval | Calls |
|---|---:|---:|
| physical_resolve_support | 8.949s | 111587 |
| lower_facade_panel | 7.593s | 70 |
| opening_head_house | 6.361s | 16 |
| compound_placement_structure_proof | 4.308s | 485088 |
| bunting_clearance | 4.190s | 110224 |
| lower_facade_panel_completed | 3.429s | 64 |
| shop_recipe_prepare_started | 3.091s | 1 |
| physical_frame_part | 3.019s | 103694 |

Intervals belong to the preceding callback family; they are **not exclusive nested-function timings**. The runner made 1,671,708 callbacks, so instrumentation overhead also matters.

Older profile31 is stale for optimization selection: it had 4555 parts and 117.3s source preparation. Tree-candidate selection formerly cost about 9.8s; current profile32 is only 0.038s for 4753 calls. [CitadelTreeSiteIndex.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/buildings/CitadelTreeSiteIndex.gd) already addresses that scan. Native support acceleration and repeated-support memoization also already exist. Do not restart those completed optimizations from old timings.

## Concrete remaining bottlenecks and uncertainty

### Citadel source preparation

Start with [CitadelRecipePreparation.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/buildings/CitadelRecipePreparation.gd), [CitadelUrbanPocComposer.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/buildings/CitadelUrbanPocComposer.gd), [CitadelSitePreparation.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/world/CitadelSitePreparation.gd) and [CitadelSiteBuildQueue.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/world/CitadelSiteBuildQueue.gd). The worker still generates and validates the complete source before terrain admission; moving work off Main does not eliminate that load latency.

The current profile points into [LowerFacadeBearingRecipe.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/buildings/LowerFacadeBearingRecipe.gd), [OpeningHeadBandRecipe.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/buildings/OpeningHeadBandRecipe.gd), and [BuildingBlueprint.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/buildings/BuildingBlueprint.gd). Inspect repeated snapshot/copy/reconstruction and repeated source-support checks within a private transaction. Preserve final independent validation and exact ordered geometry; remove repeated work, not correctness requirements.

[BuildingNativeSupportQueries.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/buildings/BuildingNativeSupportQueries.gd) and [BuildingSupportResolutionMemo.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/buildings/BuildingSupportResolutionMemo.gd) already accelerate support queries. The latter reports real reuse in profile32. A possible lead is the lower-façade `AssemblyProof` subclass: base native eligibility requires an exact supported script, and this subclass currently does not opt in. Whether safely enabling the existing kernel helps has **not been tested or implemented**; do not generalize eligibility to arbitrary subclasses.

### Main-thread capture and regional publication latency

The worker cutover leaves 256 terrain-height queries per tile on Main through `height_for_cell` / `terrain_projection_for_cell`. That is the 150ms measured capture cost. A 4ms outer budget cannot preempt that loop. Any resumable capture must revalidate complete source identity across slices, retain pending demand and reject stale partial captures. Any worker calculation must consume owned authoritative inputs, not a mutable scene/world object.

During the failed smoothness comparison, tile **-209,-171** remains pending from approach sample 6.369s through 26.669s with the same source key `929:0:0` plus the citadel binding. Published-tile counters continue increasing from 216 to 277, so the evidence does not show a globally stalled worker.

No root cause or repair has yet been established. Two inspected code paths are leads:

- Regional publication only enqueues absent demand; urgent overlapping demand may leave an already queued background tile at its old priority.
- Publisher empty-tile shortcuts use source-key markers without checking accepted-source validity/dirtiness; the service rejects dirty accepted facts. The report does not establish that the held tile was empty.

Before changing either path, expose bounded rejection/queue details from the same acceptance predicate: reason, dirty state, owner/descriptor/installation identity, active slot stage, retained priority and request age. Current `navigation_accepted_source_pending` is too coarse to distinguish scheduling from invalidation. Keep [NpcRouteCoordinatorAdapter.gd](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd) changes limited to publication demand; preserve the routing stack above it.

## Next execution sequence

1. Inspect the current diff and compile the newly changed fixture files. Run the affected existing source/lifecycle/nav-world/route tests as one batch. Fix real contract errors; label obsolete fixture assumptions separately. Do not expand into another test framework.
2. Use profile32 to reduce repeated work in the citadel generator. In parallel, resolve the accepted-source delay and bound measured Main capture operations. Keep disjoint file ownership if delegating.
3. Compare complete typed source output and physical checks against the preserved source; check ordered navigation surfaces/crossings and owner lifecycle where changed. A source signature alone does not cover all those claims.
4. Freeze the candidate and run the production headed comparison early. Collect visible geometry, collision, door/stair/furniture behavior, movement holds and total cadence together. Batch independently detectable defects before paying for another full run.
5. Promote only after faster equivalent loading and improved traversal are measured. Then complete nearby physical publication and justified presentation/generation cutovers. Keep whole-citadel completion separately reported.
6. Final performance evidence still requires three controlled cold runs of the known seed and one each of two fresh seeds, plus five-minute 1080p sprint/forest/settlement observations, reversals/unloading, and relevant physical/edit/save/lifecycle checks. The current short exterior approach is supporting evidence only.

## Commands and verification details

Run commands from the exact worktree above. All outputs must use fresh directories; the candidate runner rejects `-OutputDirectory .`.

Production diagnostic comparison:

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -CaptureNavigationRejections -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-next
```

Add `-ManualInspection` for an interactive inspection. The flags provide controlled visibility and an explicit initial spawn; this command does not prove ordinary gameplay settings or five-minute traversal. Freeze production scripts during the run: its source watcher intentionally invalidates edited candidates.

Existing source/physical diagnostic, using the ordinary wrapper for the next run:

```text
node tools/run-citadel-candidate-recipe-diagnostic.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -ExpectedRecipeSeed 1393179273 -ExpectReady -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-next
```

Relevant existing regression commands:

```text
node tools/run-startup-loading-readiness-contract-tests.mjs
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both
node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both
node tools/npc/run-npc-route-tests.mjs -TimeMode Both
node tools/npc/run-npc-door-tests.mjs -TimeMode Both
node tools/run-playtest.mjs
```

The shutdown lifecycle fixture has no standalone named Node wrapper. Use the existing `runGodotProcess` helper with `--headless --path . --script res://scripts/testing/NavigationShutdownLifecycleContractRunner.gd` and an absolute `VOXEL_NAVIGATION_SHUTDOWN_REPORT` path. Use `findGodot()` from the shared Node runtime; do not create a new process runner.

Immediately before the last four fixture edits, filter-cutover contract results were 84/84, door 48/48, and nav-world 84/86. The two nav-world failures were the same synthetic immediate-snapshot test in day/night mode. Those results are in [navigation-filter-contract-01](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/navigation-filter-contract-01/report.json), [navigation-filter-door-01](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/navigation-filter-door-01/report.json) and [navigation-filter-nav-world-01](C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals/artifacts/citadel-runtime-integration/navigation-filter-nav-world-01/report.json). Re-run after the latest migration; do not claim they already pass.

The initial eight-file cutover compiled in Godot (`godot-STXMgh`). No full broad playtest has run against the complete current uncommitted batch. Future cutover verification must include the mandatory broad playtest and affected lifecycle/navigation suites, without treating source-only or synthetic success as smooth gameplay.

Retain ignored binary evidence locally when transferring work. Source snapshots use `FileAccess.store_var(..., false)` to preserve typed values; JSON is explanatory and can lose types/large integer precision. Parse large reports selectively instead of dumping entire per-frame motion/terrain proofs.
