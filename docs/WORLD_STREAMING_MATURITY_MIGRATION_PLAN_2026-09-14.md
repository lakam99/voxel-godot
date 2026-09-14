# World streaming maturity migration — execution handoff

Date: 2026-09-14. Status: **GATE 1 LIFECYCLE COMPLETE; PERFORMANCE ACCEPTANCE PENDING; GATE 2 HAS NOT STARTED.**

## 0. Assignment, location, and authority

Deliver smooth, continuously streamed ordinary gameplay: menu → New Game/Continue → tutorial town → wilderness/sprinting → discover/approach/enter a procedural Citadel → streets/houses/interiors → leave/revisit → save/reload/exit. Preserve deterministic content, terrain solidity, interactions, NPC behavior, and the cozy voxel presentation. This is a world-streaming/runtime maturity migration, not a mandate to rewrite unrelated gameplay.

The user authorized this plan. Execute its gates only when instructed to implement. Gate 0 must preserve **all uncommitted work in the Citadel worktree, even incomplete work**, then create and switch to its descendant migration branch. Do not merge into master until the user separately authorizes merging.

```text
ACTIVE_WORKTREE = C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals
SOURCE_BRANCH   = codex/world-streaming-architecture
OBSERVED_HEAD   = d69323d5780d3baf3a0b9f6710a6b7478d0bafb8  (Furnish generated Citadel homes)
NEW_BRANCH      = codex/world-streaming-maturity-migration
PLAN            = docs/WORLD_STREAMING_MATURITY_MIGRATION_PLAN_2026-09-14.md
EVIDENCE_ROOT   = artifacts/world-streaming-maturity/<gate>/<unique-run-id>/
```

All relative paths below resolve from ACTIVE_WORKTREE. The app's cwd `.../voxel-biome-world-godot` is a DIFFERENT dirty checkout on `codex/citadel-texture-poc`; do not stage, switch, or edit that checkout for this task. Master is checked out elsewhere. Run `git worktree list --porcelain` and `git status --short --branch` before acting. If the environment permits writes only to the app cwd, request narrowly scoped tool escalation for ACTIVE_WORKTREE; do not relocate the work into the wrong checkout.

Read in order: `AGENTS.md`, `MANIFESTO.md`, this file, `docs/WORLD_STREAMING_ARCHITECTURE_PLAN.md`, `CODEX_PERFORMANCE_PLAN.md`, then `docs/CITADEL_SPAWN_PERFORMANCE_HANDOFF_2026-09-11.md` for history. This plan incorporates the later user decision that ordinary movement must not invoke a modal loading screen. Older documents requiring multidomain startup readiness still apply to New Game, Continue, and explicit world replacement; they do not justify gameplay overlay re-entry.

Navigation-service/publication changes were explicitly approved in this conversation. That permits the publication work described here, including its existing files under `scripts/npc_ai/navigation/`. It does not authorize replacing route planning/proof, NPC motors, door execution, traffic, or named-actor behavior. Preserve the manifesto's regression evidence requirements. Do not restart the rejected native Recast/chunk-baking replacement.

## 1. Product and engineering invariants

- **One world authority:** seed + durable edits → authoritative generated/edited terrain and procedural structure descriptions → derived visual/collision/navigation artifacts. No alternate readiness truth, authored Citadel substitute, fallback generator, or metadata-only physical success.
- **Movement:** bounded local terrain/collision publication evidence → ordinary `CharacterBody3D` physics. No structure closure, Citadel receipt scan, navigation query, or large diagnostic dictionary on ordinary player physics/dodge paths. Preserve real terrain-generation admission: Citadel grading/site profiles must be decided before the corresponding terrain publishes.
- **Presentation:** initial loading remains opaque until the initial playable world is ready. Ordinary traversal never displays `Preparing World` or enables loading cadence. Visible construction/pop-in is acceptable. If local terrain collision is genuinely missing, constrain unsafe motion locally while retaining demand; normal sustained traversal must prepare ahead enough to avoid repeated holds.
- **Demand:** camera/FoV, facing portals, predicted movement, occupancy, and distance affect priority/timing only. Retain a surrounding safety/reversal ring and hysteresis. Work behind the camera may still be required for collision, actors, shadows, or imminent turns. Offscreen does not mean disposable.
- **Determinism:** a fixed seed and durable edits yield the same complete typed geometry, stable IDs, dependencies, furniture, doors, and navigation meanings regardless of approach direction, worker completion order, cancellation/retry, or occupancy. No shared-RNG reordering or hand-placed seed-specific repairs.
- **Installation:** fresh authoritative source/support/shape/owner validation AND current dynamic-actor clearance at physical activation. Revision counters alone currently miss some shape/owner/transform mutations. Retained dependency descriptions may guide scheduling; they cannot replace fresh physical acceptance. If validation spans frames, establish explicit mutation ownership/invalidation first.
- **Publication bounds:** unit cap + elapsed-time cap + measured atomic-operation cap. Group count alone is insufficient; bound vertices/bytes, shape complexity, engine registrations, proof members, and cleanup work. A clock check cannot preempt a Godot call. Oversized controllable inputs must be subdivided; unsplittable overruns need attribution and a design correction.
- **Lifecycle:** keep ownership through preparation, upload, validation, activation, synchronization, and acknowledgement. Ready completions get bounded progress before new discovery; this does not authorize an unbounded drain. Pending work remains retryable, stale work cannot publish, and retirement cannot leak or stall a whole frame.
- **Language:** GDScript owns gameplay and orchestration. Pure, measured CPU kernels may move to the existing native extension after unnecessary work is removed. No required C++ rewrite merely to satisfy the word “migration.”

## 2. Snapshot and evidence — do not inherit earlier overclaims

Before this plan was added: 13 tracked files modified; 199 untracked files, including 198 `.gd.uid` files and `scripts/world/GeneratedContentViewPriority.gd`. Re-inventory at execution time. Existing tracked edits cover `MainCore`, `MainRuntimeTools`, `VoxelTerrainRuntime`, `WorldStreamingCoordinator`, `CitadelPublicationService`, `BuildingScenePublicationJob`, `CitadelUrbanPocComposer`, and their fixtures. Latest user instruction supersedes earlier advice to leave UID files uncommitted: include all Git-visible uncommitted files in Gate 0.

Implemented but not performance-accepted: nonmodal structure pending state; camera/prediction intent; portal/view ranking; 256-group rolling foreground windows; retained group receipts; procedural civic-paving clipping; focused no-overlay checks. Inspect and reuse these changes rather than reapplying old drafts.

Primary reproduction:

```text
seed = atlas-3376622889
candidate region = -2,-2
recipe seed = 1393179273
initial spawn cell = -3334,-2666
report = artifacts/citadel-runtime-integration/candidate-teleport-view-streaming-01/report.json
```

| Observation | Value / interpretation |
|---|---|
| Startup to release | 127.627 s; test portion 105.421 s; neither is exclusive generator CPU time |
| Ordinary approach presentation cadence | p50 358.3 ms; p95 508.1 ms; p99 550.6 ms; max 579.216 ms; 83/150 intervals >100 ms |
| Approach render timings | CPU p99 8.5 ms; GPU p99 14.9 ms; GPU data can be delayed and is not frame-aligned |
| Citadel service advance / scene-service unit | 527.301 / 526.733 ms; nested measurements, not additive |
| Actual job operation maxima | publication boundary 17.547 ms; group commit 13.067 ms; building begin 6.559 ms; building 4.545 ms; max job slice 17.552 ms |
| Streaming coordinator / demand | 168.346 / 168.427 ms; overlapping call-chain timing, not additive |
| Navigation terrain capture “128.922 ms” | **Accumulated capture CPU across resumable slices**, not established as a 129 ms atomic/frame stall |
| Recorded structural proof totals | source requirements: 1,390 calls / 20.402 ms total; single receipt: 3,966 calls / 2.233 s total / 4.875 ms max; commit: 412.476 ms total |
| Approach rendering/scale | up to 2,845 draw calls, 5,116 shadow calls, ~1.814 billion bytes static memory; scene census ~243k logical instances, 2,350 MultiMeshes, 3,400 collision shapes, 7k nodes; verify scope before comparing |
| Modal loading during two tested approach phases | Zero observed; does not prove all normal gameplay |
| Completion | Service labels a scene `scene_ready`, but `publicationReady=false`; scene audit has 4,094/4,098 physical groups complete, four deferred, `packet_wait`, `sceneReady=false`. Do not claim full source completion from the service label. |

The report explicitly disclaims continuous tutorial-to-Citadel travel, live gameplay/NPC acceptance, exhaustive collision correctness, and performance acceptance with captures/audits. Its ordinary-input cadence plus the user's visible stutter is sufficient to reject merging, but not to assign every stall to one function.

**Source audit corrections incorporated on 2026-09-14:**

1. `CitadelPublicationService._pump_scenes` times selection, demand refresh, transaction selection, readiness/eligibility, occupancy/source checks, dispatch, and `job.advance` together. The 526.733 ms value is not proof of a half-second engine-install API call. Instrument those internal boundaries.
2. `NavigationTileCapture.advance` already yields and retains its cursor; `profile.terrainUsec` accumulates across calls, then is recorded as a section at seal. Measure `maxStepUsec`, individual sample cost, entry validation, enumeration, seal, and engine acknowledgement separately. Do not rewrite an already-resumable capture to solve a misread total.
3. `set_request_view_intent` increments a global handoff revision but leaves request sequence/dependency identity intact. `_refresh_request` already has an unchanged-request early exit. Camera-driven closure recompilation is a hypothesis; unchanged terrain/source handoffs on camera-only updates are a verified audit target.
4. Motion proof also calls `collision_proof_for_world_position` for support-observation telemetry: five `surface_y_at` queries and full-height rays per swept sample despite `supportRequiredForMotion=false`. This unnecessary observation may cost more than the recorded receipt checks. Time the entire player physics path; do not blame validated geometry totals alone.

Other evidence:

- Exact production recipe `artifacts/citadel-runtime-integration/candidate-recipe-supported-paving-prod-01/report.json`: 56.376 s preparation; 4,570 building parts; physical checks passed. Separate generation/validation/copying/preparation in the corrected profile.
- `artifacts/citadel-runtime-integration/civic-generated-source-paving-audit-02/report.json`: supported civic paving now ends at X=62.09 instead of X=67; original fixed 48 m slab extended past curtain face ~62.86. Preserve the source-derived fix and inspect all external sides live.
- Prior focused passes: `world-streaming-consumer-view-priority-07` (102), `native-admission-nonmodal-01` (67), `publication-service-view-windows-03` (142), `streaming-packet-bridge-view-priority-02` (18 groups), under `artifacts/citadel-runtime-integration/`; startup contract report `artifacts/node-tools/run-startup-loading-readiness-contract-tests.json` (72). They are contract evidence, not FPS acceptance.
- Three civic recipe assertions failed identically at detached d69323d and candidate: `streetRecipeRecordsByteExact`, `independently_clear_street_layout_retains_full_legacy_parity`, `commons_recipe_tracks_generated_row_and_clears_two_seed_layouts`. Baseline evidence is in sibling `voxel-biome-world-godot-head-d693-civic-check/artifacts/citadel-runtime-integration/civic-head-d693-baseline-01/report.json`. Preserve/attribute; do not weaken assertions or silently count them as passing.
- Sibling `voxel-biome-world-godot-sep12-smooth-control` at `ede61d2127d4ca055cf6449694b232917633014d` is a potential comparison control, not independently accepted “smooth” evidence. Verify behavior/build/cache conditions before using it. Do not revert commits without a new user instruction.

## 3. Owner map

| Responsibility | Existing owner / entry points |
|---|---|
| Player movement | `scripts/PlayerController.gd` → `MainRuntimeTools.terrain_collision_motion_proof` → `terrain/VoxelTerrainRuntime.collision_proof_for_motion` |
| Terrain evidence and grading | `VoxelTerrainRuntime.region_publication_readiness`, native body-mesh evidence; `terrain/VoxelTerrainSiteGate.gd`, `world/CitadelTerrainAdmission.gd` |
| Retained spatial demand | `world/WorldStreamingCoordinator.gd`: `_region_readiness`, `_refresh_request`, `advance`, `set_request_view_intent`; `MainCore.apply_streaming_region_demand` |
| Gameplay budget | `MainRuntimeTools.update_voxel_authority_chunks` currently 6 ms aggregate; `VoxelTerrainRuntime._process/_physics_process` contain additional pumps. Citadel allowance is 4 ms. These are not equivalent or automatically shared. |
| View scheduling | `world/GeneratedContentViewPriority.gd`; `world/CitadelPublicationService.gd` demand-window and scene-pump methods |
| Source/worker/scene | `buildings/BuildingPublicationPreparation.gd`, `BuildingPublicationWorker.gd`, `BuildingScenePublicationJob.gd`, `BuildingPartPublisher.gd`, static batch/upload helpers |
| Physical proof | `buildings/BuildingSpatialDependencies.gd`, immutable description, actual per-group receipts and fresh commit proof |
| Occupancy | `world/GeneratedStructureRuntimeBindings.gd::construction_members_allowed`, bound by `StructureSystem.gd`; `GeneratedStructurePlayerClearance.gd` inspects already-published contacts and is not a general actor index |
| Schematic generation | `buildings/CitadelRecipePreparation.gd`, `CitadelUrbanPocComposer.gd`; `world/CitadelSitePreparation.gd`, `CitadelSiteBuildQueue.gd`; production blueprint/recipe composers |
| Navigation preparation/acceptance | `buildings/BuildingNavigationTileProducer.gd`; `npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`, `NavigationTileCapture.gd`, `NavigationPublicationWorker.gd`, `NavigationPublicationQueue.gd`, **`NavmeshWorldService.gd`**; `world/RegionalNavigationPublication.gd` |
| Measurement | `perf/RuntimePerformanceMonitor.gd` is Main-only; `perf/RuntimeRenderObservation.gd` measures presentation cadence; existing headed runners and owned-process watchdogs |
| Existing native code | `native/terrain_meshing/`, `addons/terrain_meshing_backend/`; registered `TerrainMeshingBackend`/`BuildingSupportKernel`; pinned godot-cpp/API/precision; do not create a competing extension pipeline |

## 4. Execution gates

Gate progression: `G0 → G1(A–E) → G2 → G3 → G4 → G5`. G1 is one coherent correctness cutover with reviewable sub-checkpoints; a fast movement microtest alone does not complete it. Commit each verified sub-checkpoint. No gate may be declared complete merely because its runner exited zero.

### G0 — Snapshot everything, branch from that snapshot

**Entry:** implementation authorized; correct worktree verified; other agents/owned runs quiescent. Do not launch tests or repair incomplete work before preserving it.

1. Record branch, full HEAD, status, diff stat, untracked list, known failures, and native dependency/binary hashes. Preserve ignored evidence and caches in place. The snapshot scope is every Git-visible tracked/untracked change in ACTIVE_WORKTREE, including this plan and `.gd.uid` files; no selective omission for quality/completeness. `git add -A` honors existing ignores; do not force-add caches, binary build directories, or unrelated worktrees.
2. Commit that exact incomplete snapshot on SOURCE_BRANCH. Inspect staged scope before committing. If an actual secret appears, preserve it securely and resolve that specific exception; do not publish secrets or silently discard work.
3. Create NEW_BRANCH from the snapshot commit and switch the same Citadel worktree to it. If it already exists, verify ancestry/status and resume the correct checkpoint; never reset an existing branch.
4. Record snapshot hash and new branch in the ledger below; verify clean status before subsequent work. Snapshotting is explicitly allowed to preserve failing tests and regressions. Do not label the WIP commit tested or release-ready.

```powershell
# Run only after verifying ACTIVE_WORKTREE and SOURCE_BRANCH.
git add -A
git diff --cached --stat
git commit -m "WIP: preserve all Citadel streaming work before maturity migration"
git switch -c codex/world-streaming-maturity-migration
git status --short --branch
git rev-parse HEAD
```

**Exit:** all Git-visible pre-migration work preserved in one identified commit; descendant branch selected; other worktrees unchanged. Commit ledger updates separately on the new branch. No push or merge.

### G1 — Repair bounded runtime work and complete the publication lifecycle

**Entry baseline:** use the preserved bad-run report first. Freeze the new branch's source while testing. Compile; run affected contracts and the applicable unchanged NPC regression baseline before generated-world changes, per MANIFESTO. Record real route behavior failures separately from obsolete fixture assumptions. Continue authorized root-cause work after failed runs; do not patch protected route behavior to make publication tests pass.

**G1A — Movement isolation and attribution.**

- Replace generic multidomain movement preflight with local authoritative terrain publication/body-mesh evidence. Reuse/refine the existing terrain owner; no global “ready” cache. Readiness entries bind runtime generation, owner, chunk/edit revision and collision publication receipt, and become invalid on edit/reset/retirement/replacement.
- Remove Citadel state scans and support-observation ray/height diagnostics from normal movement. Diagnostics may run explicitly outside the hot path with bounded frequency/storage. Preserve actual terrain mesh availability, swept-volume coverage, jump/fall/dodge and normal physics against already-published structures.
- Bound work by a local sweep, including chunk edges and vertical motion. Long/high-speed moves must split/progress or return pending rather than skip unsampled terrain. No dependence on total Citadel size or retained-world population.
- Instrument complete player physics and motion proof: entry count, samples/chunks, max/p95/p99, total per presented frame, physics ticks per presentation, and each expensive child. Fixed-capacity counters/histograms; no per-tick full-world copies/logging.
- **Pass:** structural dependency/publication and navigation test doubles receive zero calls during ordinary motion/dodge; unloaded mesh, pending edits, unload/reload, reset, owner replacement, falling and swept-edge cases remain safe. The bounded site-profile admission path is explicitly permitted; do not remove grading authority to satisfy the zero-call assertion. Repeat the exact headed approach early to quantify improvement without claiming G1 complete.

**G1B — Demand identity, locality, and priority propagation.**

- Distinguish world/source/edit identity, consumer spatial membership, camera priority, and publication/acknowledgement progress. Camera-only changes must reorder retained work without reacquiring terrain handles, replaying unchanged handoffs, recompiling closure, or discarding completed receipts.
- Retain immutable spatial membership under a complete source binding. Invalidate affected source/tiles and seam neighbors on actual changes. Bound dirty refresh, expiration, copying, sorting, and admission inside `WorldStreamingCoordinator.advance`, including work before its current deadline check.
- Preserve local safety demand; view-ranked visual windows do not grow into full-source fallback. Index queries depend on affected cells/overlaps rather than scanning every retained source. Inspect repeated copying before introducing a new cache.
- **Pass:** camera orbit/reversal changes selected priorities but leaves membership/source identity, handles and receipts stable; no unchanged terrain handoff; real edits invalidate affected dependencies and reject stale worker output. Thousands of groups cannot turn one refresh into a 168 ms synchronous call. Record worst refresh/selection/handoff times individually.

**G1C — Bounded installation, occupancy, and retained completion.**

- Time `_pump_scenes` internals before selecting the fix for its 526 ms service unit: demand refresh, selection, readiness/eligibility, receipt enumeration, guard, dispatch, job advance, callbacks, cleanup. Separate measured 17.547 ms job-boundary cost from outer service work.
- Existing limits differ: 256-group foreground window versus 64-group/256-member job transaction. Replace/augment count limits with measured byte/geometry/proof/registration cost. Split expensive selection/boundary/commit work as well as engine upload; do not simply lower a group constant and assume the issue is solved.
- Preserve a transaction record through every yield: source/owner binding, stable transaction ID, prepared artifact, immutable dependencies, accepted receipts, phase/cursor, pending acknowledgement, occupancy wait reason, retry age, cancellation epoch. Finish/acknowledge retained completed work before scanning new demand, within the shared budget.
- Shared members/engine objects have exactly one installation owner. Overlapping closures reuse receipts; cancelling one transaction must not retire dependencies still retained by another transaction or consumer.
- Fresh physical acceptance remains mandatory. Validate once per actual acceptance transaction where possible; do not repeatedly validate equivalent facts during scheduler polling. If the minimum dependency-complete transaction still exceeds the slice, restructure owned geometry/proofs or establish safe mutation invalidation before making validation resumable.
- Current occupancy only tests player XZ rectangles and a single pinned transaction. Extend the production guard through a bounded spatial physics/index query covering relevant players, NPCs, hostiles and wildlife with vertical separation. An index is a candidate accelerator, not cached clearance authority. Recheck immediately before collider activation, including after yields or acknowledgement delays, using a safe physics boundary so an actor cannot be trapped between check and activation.
- Retain occupied transactions and select independent groups within the SAME Citadel; a blocked doorway must not pin all other houses. Wait on true dependencies only. Partial staging must not expose misleading collision/visual states. No moving actors aside, disabling their collisions, or erasing generated geometry to pass clearance.
- **Pass:** one occupied room plus unoccupied independent rooms → latter publish, former later completes unchanged; stale/moved/replaced colliders rejected; reset/unload/cancel at each phase drains ownership; completion survives competing expensive requests; no duplicate install/ack; all demanded supported groups eventually complete. Full-source readiness must not be inferred from foreground `scene_ready`; report unsupported/pending groups explicitly.

**G1D — Navigation slices and acknowledgement.**

- Preserve existing resumable `NavigationTileCapture`, filter worker, tile artifacts and accepted-result ownership. Correct telemetry so lifetime capture totals cannot masquerade as frame sections. Measure actual step, sample, enumeration, seal, upload, synchronization and final validation latency.
- Split only measured oversized operations. Worker preparation consumes immutable authoritative terrain/structure facts; no mutable live node capture on a worker. Retain source identity across slices and reject stale partial/complete results.
- Keep exact physical validation at acceptance; current counters alone cannot prove arbitrary collider mutations absent. Cache reusable immutable source facts, not unchecked physical readiness. Preserve tile/vertical-span/seam compatibility, portal state behavior and route-stack outputs.
- **Pass:** tile publication eventually acknowledged under competing expensive dependency scans; demand retained; no repeat accepted work; stale source/owner replacement rejected at acceptance; cancellation/reset during capture/upload/sync clean. Real terrain/structure/door/stair/porch crossings preserved. `worker complete` never equals `navigation ready`.

**G1E — One gameplay frame budget and backpressure.**

- Inventory all `_process`, `_physics_process`, Main lanes, scene callbacks and timer pumps. Include terrain admission/generation handoff, chunk/collision publication, props/trees, structures, navigation, completion and retirement. Current independent Citadel pump and work before Main's lane checks must be charged.
- Start with the existing **6 ms aggregate gameplay publication allowance**, with Citadel at most **4 ms and never more than the shared remainder**. Charge actual elapsed work; subordinate services cannot each claim a fresh allowance per callback/physics tick. Record frame token/deadline, consumed work, maximum atom, overrun source, retained age/backlog and producer backpressure. Tighten if presentation targets require it; do not increase budgets to conceal overruns.
- Use unit ceilings and measured cost estimates before starting an atom. Godot/OS timing is not hard real-time: retain/attribute actual overruns and subdivide controllable work. Repeated budget breaches block this gate; do not promise impossible API preemption or chase sub-0.1 ms timing noise.
- Share worker capacity as well: background CPU, queue sizes, prepared-buffer memory and retirement need caps; avoid starving terrain or simulation under multiple worker jobs. Completion priority and aging provide progress without an unbounded completion drain.
- Initial/replacement loading has an explicit lifecycle owner and may use larger bounded slices while displaying responsive progress. A gameplay readiness result must never switch the scheduler into loading mode.
- **G1 exit:** focused contracts, cancellation/ownership tests and frozen exact-seed headed comparison pass with attributed before/after cadence; record ordinary wilderness sprint against §6. No modal re-entry, whole-source burst, per-motion structure/nav work, unbounded orchestration, or completion starvation remains. If final cadence still fails solely from an identified residual pure computation/rendering cost, record that owner and permit G2/G4 work while keeping performance acceptance PENDING; do not disguise unfinished lifecycle fixes as native candidates. Preserve captures but measure screenshot readback in a separate phase. Diagnose the full owner/call chain before another failed launch.

### G2 — Corrected profile and native decision record

**Entry:** G1 lifecycle corrections verified and before/after trace captured; any remaining performance failure has an attributed owner and remains a release blocker.

- Profile fresh/cached recipe creation, validation, spatial index build/query, copying/allocation, hashing, packed mesh/collider preparation, engine publication, acknowledgement, worker contention and retirement separately. Retain total source-to-visible and source-to-usable latency. Measure unique vs repeated semantic requests before proposing reuse.
- For every remaining material cost record: source/function, input scale, inclusive/exclusive scope, CPU vs wall time, thread, p50/p95/p99/max, frequency, bytes/allocations, end-to-end impact, chosen fix and rejected alternatives. Compare repeated controlled runs; avoid instrumenting millions of callbacks again.
- Establish the loading acceptance comparator now: a verified formerly smooth control under equivalent seed/build/cache conditions, or an explicitly justified absolute stage/load envelope if that control is unavailable. Record numeric targets/tolerances before final runs; never choose the already-regressed 127.627 s snapshot as the sole successful-loading standard.
- Classify: eliminate work → improve algorithm/retain state → batch/slice → native pure kernel → demonstrated engine/API limitation. A native candidate must remain expensive, deterministic, coarse-grained, CPU-bound, immutable-input/output, and independent of active scene mutation. “Already meets target; no native migration needed” is a valid measured decision.
- **Exit:** checked-in bottleneck/decision table with named candidates and measurable acceptance goals. C++ work cannot begin from the old 56 s aggregate alone. Do not make a custom engine fork/module a default deliverable.

### G3 — Ahead-of-player deterministic preparation and justified native kernels

- Establish a stable compact Citadel plan/spatial index or independently sealed partitions whose support/dependencies cannot change when hidden detail finishes. Preserve deterministic generator/RNG order while scheduling calculations; no early partition whose later geometry invalidates an installed support or aperture.
- Prepare at a distance informed by measured throughput, travel speed and reversal margin. Prioritize silhouette, gate/approach, space visible through the facing gate, connected streets/façades, accessible interiors, then hidden detail. For rear/air approaches honor actual view and portal exposure; the list is scheduling policy, not authored city versions. Cap wasted precomputation and retain completed work across turns.
- Track time to first silhouette, usable gate path, visible courtyard, accessible home, and complete demanded/full source separately. Queue throughput must keep up with representative sprint discovery. Pop-in is allowed; repeated modal pauses and persistent holes/missing demanded interiors are not.
- Implement G2-selected native kernels in `native/terrain_meshing/` with the pinned Godot 4.6 godot-cpp and precision configuration. Inputs/outputs: immutable source binding, recipe/schema version, packed data, cancellation epoch, output signature, bounded lifetime; no live nodes. Batch boundary crossings rather than thousands of tiny calls. Cancellation must not access released inputs.
- Validate ordered/typed output, physical semantics, durable-edit behavior and stable IDs against the original implementation for known and fresh seeds; explicit float/precision rules, including negative coordinates and serialization. A signature alone is insufficient. Keep a reference implementation in differential tests if useful; remove superseded production authority/fallback after cutover.
- Build debug and release; verify installed library hashes match sources. GDExtension comes first. A module or engine fork requires a reproducible public-API blocker and concrete evidence; raise that scope decision only if needed.
- **Exit:** early useful publication and sustained preparation keep ahead of representative travel; demand eventually drains; deterministic approach-order/worker-order/edit/cancel parity passes; each selected kernel improves measured cost/latency without regressing frame cadence. If no kernel is justified, document the measured decision and still complete progressive preparation.

### G4 — Scale, visual quality, and retirement

- Profile and reduce unnecessary nodes, static instances, MultiMeshes, shadow casters, collider registrations and retained buffers. Batch by spatial region/material/geometry while preserving culling, ownership, edits, interactions, holes/apertures and collision boundaries. Avoid a single city-sized batch that destroys view culling or makes uploads indivisible.
- Keep full required near geometry; use source-derived silhouettes/detail tiers, conservative opaque occlusion, distance-aware shadows and existing tree grammar/batching. Visibility controls rendering; it cannot remove collision under actors or a demanded route. Retire unnecessary detail gradually with hysteresis and shared budgets.
- Detail replacement preserves common source/group identity and required old collision until replacement activation/acknowledgement. Reuse or transfer ownership without duplicate colliders, doors or interaction registrations; cancel stale replacement work without destroying the accepted tier.
- Preserve the civic-paving source fix. Inspect outside curtain walls, gate, overhead layout, streets, actual furnished interiors, stairs and roof/door/window transitions in day and night. An outside plant or clipped camera is not furniture/interior evidence.
- **Exit:** resource census and memory measured at equivalent camera/state; repeated leave/revisit cycles settle to the same retained working set without monotonic growth, stale handles or stranded jobs. Record peak and settled memory, cache caps and process baseline. At least 30 minutes and three retirement/revisit cycles, with autosave enabled; no post-warmup growth >5% between comparable settled checkpoints without an accounted retained asset. This is an initial engineering criterion, not a universal 1.8 GB memory ceiling.

### G5 — Maturity acceptance and merge-ready handoff

- Execute the matrix in §6 with frozen source/binary hashes and preserved input saves. Full gameplay acceptance starts at the actual menu and uses normal runtime settings, collision and input. Extend existing headed fixtures where necessary; no teleport/helper-driven act phase, forced safe movement, bypassed interactions, or metadata-only success.
- Validate New Game and Continue initial readiness, tutorial town/actors, wilderness sprint, Citadel approach from gate and side, rapid turns/reversals, interior furnishings, gate/door/stair passage, nearby NPC behavior, edit/dig/build/harvest, combat/survival, autosave/manual save, reload during pending work, exit/cancel during preparation/installation/sync, and later revisit. Use established broad/NPC/terrain/save fixtures; inspect their reports and actual visuals.
- Resolve failures within authorized ownership. A green boolean cannot waive an engine error, unsafe collision, missing required crossing, source mismatch, missing demanded content or visible stutter. Baseline defects remain listed and separately attributed; a defect blocking this plan's ordinary flow must be resolved before acceptance, even if inherited. Request additional scope only for a needed protected route/motor/door-behavior change.
- Record exact commits, diff summary, benchmark comparisons, load distributions/cache state, commands, reports, inspected screenshots, evidence limits, native build reproduction, remaining unrelated defects, and merge conflict assessment against current master. Do not touch master's checkout or merge as part of preparation.
- **Exit:** all release criteria below satisfied; all migration changes checkpointed; worktree clean; final handoff declares ready for the user's merge decision. Actual merge remains explicitly withheld.

## 5. Focused verification and known commands

Use existing Node wrappers/owned watchdogs and fresh output paths. Verify each wrapper's supported flags before extending it. Defaults may overwrite evidence. Tests below are a map, not a command to run every suite after every tiny edit.

| Changed boundary | Existing runners / fixtures |
|---|---|
| Compile, movement, startup, domain identity | `run-project-compile-smoke.mjs`, `run-citadel-native-admission-contract.mjs`, `run-startup-loading-readiness-contract-tests.mjs`, `run-world-streaming-consumer-contract.mjs` |
| Scene packets/acceptance/ownership | `run-citadel-publication-service-contract.mjs`, `run-citadel-streaming-packet-bridge-contract.mjs`, `run-building-scene-publication-job-contract.mjs`, `run-building-scene-publication-contract.mjs`, `run-building-publication-ownership-contract.mjs`, `run-building-publication-preparation-contract.mjs`, `run-building-publication-worker-contract.mjs`, `run-building-publication-source-contract.mjs` |
| Occupancy | Existing `GeneratedStructureConstructionMembersContract.gd`, `GeneratedStructureRuntimeBindingsContract.gd`, `GeneratedStructurePlayerClearanceContract.gd`; verify harness inclusion, then add same-source independence and multi-actor/height cases |
| Navigation mapping/ack/cancel | `run-regional-navigation-sparse-contract.mjs`, `run-navigation-shutdown-lifecycle-contract.mjs`, `run-citadel-actual-packet-tile-navigation-acknowledgement-contract.mjs`, `run-citadel-actual-packet-nonempty-navigation-acknowledgement-contract.mjs`, `run-voxel-terrain-navigation-publication-mapping-contract.mjs` |
| NPC preservation | `tools/npc/run-npc-contract-tests.mjs -TimeMode Both`, `tools/npc/run-all-npc-tests.mjs -TimeMode Both`; affected route/door/nav-world/streaming-save suites; real tutorial/home/job-cycle headed fixtures |
| Whole gameplay | `tools/run-playtest.mjs`, `tools/run-normal-runtime-performance-pass.mjs`; affected terrain digging/lighting/ground/save visual fixtures and `tools/run-world-signature.mjs` |

Runner names in the first four rows are under `tools/`. Mocks/contracts remain explicitly labeled. New headed NPC runners must pass `tools/npc/assert-npc-acceptance-runner-clean.mjs` before launch. Normal runtime performance chooses its seed through New Game: do not pass `-Seed`. `run-runtime-performance-observation.mjs` uses `--fixed-fps 60` in the current wrapper and is supporting diagnosis, not a substitute for real-time cadence acceptance.

```powershell
# Fixed failing seed: diagnostic initial-location approach and visual comparison.
node tools/run-citadel-candidate-teleport-playtest.mjs -OutputDirectory artifacts/world-streaming-maturity/g1/citadel-approach-01 -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600

# Normal real-time menu/New Game sprint; no fixed seed, five-minute measurement.
node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 300 -TimeoutSeconds 600 -ReportPath artifacts/world-streaming-maturity/g1/normal-sprint-01/report.json -ProgressPath artifacts/world-streaming-maturity/g1/normal-sprint-01/progress.txt

# Source-only diagnostic; not scene, collision, or live gameplay acceptance.
# Current ownership validation requires a fresh candidate-recipe-* directory
# directly below artifacts/citadel-runtime-integration.
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-g2-01 -Seed atlas-3376622889 -CandidateRegion "-2,-2" -ExpectedRecipeSeed 1393179273 -ExpectReady

# Only for selected native work. Reuse pinned bindings; fetch if actually absent.
node tools/build-native-terrain-meshing.mjs --target template_debug --api-version 4.6
node tools/build-native-terrain-meshing.mjs --target template_release --api-version 4.6
```

The normal performance runner is useful coverage but does not by itself prove the entire tutorial-to-Citadel journey. Audit its setup, phases, survival policy and report limitations; add continuous ordinary-input journey coverage using the established fixture conventions.

## 6. Release measurements and acceptance matrix

Run one measured Godot workload at a time; no parallel benchmarks, builds or source edits during a frozen run. Record hardware/driver/engine version, renderer, resolution, source/build hashes, seed, cache state and active flags. Report presentation cadence separately from Main sections, physics ticks, worker CPU, engine submission and synchronization. Do not sum nested maxima or label accumulated job totals as frame costs.

| Scenario | Required evidence / criterion |
|---|---|
| 1080p wilderness sprint and Citadel traversal | 60 FPS target on documented RTX 5060 Ti host; ≥5 min each, p99 presentation ≤33 ms, no recurring streaming stalls >33 ms, no frame >100 ms. These are the later approved spatial-streaming criteria; do not reduce to Main-only timings. |
| 32-NPC normal town workload | Preserve older performance-plan scenario: p99 target ≤16.7 ms / ≤22 ms tolerated; max ≤33 ms; no repeating 2–7 s spikes; autosave main-thread section ≤2 ms. Measure it if claiming broad runtime maturity, not by extrapolating the Citadel camera. |
| Per-call work | Full movement path bounded by local sweep; publish actual timing distribution. Budget envelope 6 ms aggregate / Citadel ≤4 ms subordinate; no repeated controllable atom/slice overrun. Report violations without relabeling budgets after the run. |
| Continuous journey | Ordinary menu → tutorial departure → wilderness → discovered Citadel → gate → streets → home → leave/revisit with no modal loading, no recurrent collision hold, no helper movement; trajectory/input and loading-state trace |
| Visual/physical | Overhead and external sides; gate-facing progress; clear streets; actual interior beds/tables/storage as generated; no wall platform; real gate/door opening and crossing, stairs, terrain solidity, collision and readable day/night presentation |
| NPC/publication | Existing live behavior and strict-home interior/door-clearance-close sequence; no altered route stack; revision-matched physical/navigation acknowledgement and cancellation proof |
| Deterministic output | Known seed plus ≥2 fresh seeds; approach/order/cancellation permutations and durable edits; typed ordered geometry/IDs/ownership/required navigation parity, not hashes alone |
| Loading | Three controlled cold known-seed samples plus one each of two fresh seeds; paired warm Continue observations. Fresh process + isolated empty generated-artifact cache defines cold. Do not delete user saves or unrelated caches. Meet the numeric comparator/envelope recorded in G2; no regression hidden by early release or comparison only to the bad snapshot. The old 90 s target was provisional and is not an accepted hard threshold. |
| Long-session retirement | G4 soak criterion, bounded queue/cache census, revisits, autosave and clean shutdown; no alive worker/native job/owned process after exit |
| Broad gameplay | Gather/craft/build/dig/harvest, combat/survival, save v2/Continue/reload, startup/exit/cancel while work pending; existing broad fixtures plus relevant headed captures |

Separate initial playable readiness, first useful Citadel content and complete demanded/full-site completion. Snapshot/capture readback stays visible in overall timing and gets its own phase; never remove real gameplay stalls from acceptance by renaming their phase. Timed acceptance intervals should contain no scripted capture/audit work; obtain checkpoint screenshots in a separate visual pass or clearly delimited pauses.

On timeout/failure, inspect progress, report, stdout/stderr and owned-process receipt before changing code. User closing the game is interruption, not acceptance or automatically a product crash. Preserve failing input/seed/source hashes, identify the root owner, batch related corrections and rerun the smallest meaningful coverage before a costly full launch. Do not repeat the same failed launch without new evidence or a relevant change.

## 7. Checkpoint ledger — update after each executed checkpoint

Each completion entry must record commit, source/binary hashes, exact commands, evidence paths, before/after measurements, inspected captures, evidence limitations, failures with attribution, and the next action. Artifact folders are ignored by Git: preserve them locally and check in the compact evidence summary so a new agent can understand results if artifacts are unavailable. Reproduce missing decisive evidence; do not substitute recollection.

| Gate | Status | Commit / evidence / next action |
|---|---|---|
| G0 snapshot + branch | COMPLETE | Snapshot `94d823cdbad8425553c0a76b3f4e4fc5f2d662a3`; switched the same Citadel worktree to descendant branch `codex/world-streaming-maturity-migration`; full inventory, native hashes, known failures, commands and evidence limits in `docs/WORLD_STREAMING_MATURITY_G0_SNAPSHOT_2026-09-14.md`; no tests run; next action is the frozen G1 baseline when implementation continues |
| G1A movement | COMPLETE | Commit `26383424`; local revision-bound terrain receipts only, zero structure/nav calls in motion; 66-check native admission and real collision publication pass |
| G1B identity/demand | LIFECYCLE COMPLETE; PERF PENDING | Commit `26383424`; membership/view revisions separated and handles stable; 72-check retention plus 102-check consumer contracts pass; costly all-group refresh is the first G2 profile target |
| G1C transactions | COMPLETE | Commit `26383424`; exact 3D actor guard, independent occupied transactions, no whole-source fallback, semantic first-useful closure; 149 service, 545 job and 109 construction checks pass |
| G1D navigation | COMPLETE | Commit `8306d3b`; per-slice capture/upload/install/ack telemetry; 262-result shutdown, mapping and real nonempty packet acknowledgement pass |
| G1E shared budget + headed checkpoint | LIFECYCLE COMPLETE; PERF PENDING | Commit `26383424`; one 6 ms gameplay envelope/4 ms Citadel claim; exact headed lifecycle PASS and five-minute sprint recorded. Citadel demand refresh, orchestration and autosave snapshot remain release blockers. Full evidence: `docs/WORLD_STREAMING_MATURITY_G1_RUNTIME_LIFECYCLE_2026-09-14.md` |
| G2 profile/decisions | COMPLETE | Corrected three-run source profile, moving-player headed stage profile, autosave ownership, loading comparator and native decision recorded in `docs/WORLD_STREAMING_MATURITY_G2_PROFILE_AND_NATIVE_DECISION_2026-09-14.md`; no native kernel selected; performance remains pending |
| G3 progressive preparation/native | NEXT; NOT STARTED | Build timing-free stable plan/spatial/dependency index and sealed early immutable partitions; re-profile before admitting any native kernel; parity and throughput |
| G4 scale/retirement | NOT STARTED | Spatial batching/detail/cleanup; exterior/interior visuals and soak |
| G5 acceptance/handoff | NOT STARTED | Full matrix, final commits, clean status, ready-for-merge report; DO NOT MERGE |

## 8. Engine references — implementation constraints, not rewrite mandates

- Active scene-tree mutation is not thread-safe. Some server APIs support threads, subject to API/settings/resource ownership; NavigationServer itself is thread-safe. Keep this project's publication ownership explicit rather than claiming every server call must run on Main. A deferred call is not a frame budget, and thread safety does not imply cheap synchronization. [Godot 4.6 thread-safe APIs](https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html).
- MultiMesh batching trades draw/instance overhead against all-or-none instance visibility within a batch; use spatial batches and measure upload/culling tradeoffs. The tutorial carries a 4.6 freshness notice, so verify concrete API behavior on the bundled engine. [Godot MultiMesh optimization](https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html).
- GDExtension loads native shared libraries without compiling them into the engine. Reuse the project's pinned extension/build route before proposing a module or fork. [Godot GDExtension](https://docs.godotengine.org/en/4.6/tutorials/scripting/gdextension/what_is_gdextension.html).
