# Citadel Normal-World Integration Handoff — 2026-08-24

## Branch And Objective

- Branch: `codex/citadel-texture-poc`
- Worktree used: `/Users/lakam99/Documents/voxel-godot-citadel-texture-poc`
- Base commit before this accumulated work: `c51d72e feat(visual): deepen citadel foliage variation`
- Objective: integrate the deterministic procedural citadel into the ordinary seeded survival-world pipeline without creating a parallel game, terrain authority, collision authority, navigation authority, NPC system, or authored citadel. Preserve the current citadel visuals and functionality while making normal-world terrain, structures, collision, doors, NPC lifecycle, navigation, saves, loading, and performance contracts authoritative.
- The work is not finished. This commit is a checkpoint requested by the user, not an acceptance commit.

## Read First

Read these before editing:

1. `AGENTS.md`
2. `manifesto.md`
3. `docs/CITADEL_NORMAL_WORLD_INTEGRATION_PLAN.md`
4. `CODEX_CITADEL_LIFE_VOX217_222_HANDOFF.md`
5. `NPC_PATHFINDING_REGRESSION_HANDOFF.md`

The relevant non-negotiable rules are:

- The citadel is a generated structure in the normal survival world, not an isolated or parallel game.
- Terrain volume remains the terrain, collision, digging, lighting, and publication authority.
- Generated building recipes/manifests remain the source of citadel geometry and topology. Do not author a fixed keep or city.
- NPC routing must use the protected mature pathfinding stack described in `manifesto.md`.
- Do not claim NPC/pathfinding acceptance from mocks, metadata, teleports, direct helper calls, or static audits.
- Live headed gameplay, screenshots, traces, and performance evidence can invalidate green synthetic tests.
- Keep unrelated user work. Do not reset, clean, or broadly rewrite this branch.

## Current Repository Scope

This checkpoint contains the accumulated branch work, not only the last navigation experiment. It includes changes across:

- normal-world citadel site selection, reservation, terrain operation policy, manifest caching, and procedural recipe context;
- citadel/keep/residence blueprint generation, interiors, roofs, furnishings, windows, materials, structural support, and physical-integrity contracts;
- normal game loading/publication integration through `StructureSystem`, `WorldGenerationSystem`, `Main*` runtime layers, and voxel terrain runtime;
- building collision/navigation manifests, support surfaces, vertical links, door portals, transition certification, and physical fall probes;
- NPC lifecycle, home/job scheduling, movement, crowd avoidance, traffic reservations, doors, motor state, animation presentation, and route leases;
- the shared generated-world NavMesh adapter, route coordinator, planner, collision-backed route substrate, and NavMesh service;
- citadel life headed playtest coverage and focused building/NPC contract runners;
- visual/material/tree/story-site support needed by the integrated citadel.

Do not assume every changed file was created by the final navigation pass. Much of this is accumulated, pre-existing work on this branch and must be preserved.

## Last Confirmed Headed Evidence

### Known Seed

Command:

```bash
node tools/run-citadel-life-playtest.mjs \
  --seed 208159 \
  --citadel-scale 1.25 \
  --surface-continuity-acceptance \
  --report-path artifacts/performance/citadel-life-continuity-known-208159-cached-transition.json \
  --progress-path artifacts/performance/citadel-life-continuity-known-208159-cached-transition-progress.txt \
  --screenshot-dir artifacts/performance/citadel-life-continuity-known-208159-cached-transition-screenshots \
  --watchdog-seconds 900
```

Report:

`artifacts/performance/citadel-life-continuity-known-208159-cached-transition.json`

Result:

- `passed=false`
- `failureReason=surface_continuity_live_actor_contract_failed`
- setup reached real live actor execution; the previous NavMesh publication starvation deadlock did not recur;
- both actors reached endpoints, but they did not prove the intended direct seam crossing;
- one actor had no matched crowd callback evidence;
- `midpointCaptureTaken=false` and `seamCrossings={}`;
- owner histories showed large detours through chapel floors, thresholds, ramps, and unrelated paving segments;
- maximum lane deviations exceeded 15 metres for an intended approximately four-metre crossing.

Performance maxima from this report:

- `navmesh_tile_snapshot_build = 3403.854 ms`
- `navmesh_tile_snapshot_base = 64.355 ms`
- `navmesh_tile_snapshot_terrain = 464.997 ms`
- `navmesh_tile_snapshot_support_samples = 2158.345 ms`
- `navmesh_tile_snapshot_support_surfaces = 38.962 ms`
- `navmesh_tile_snapshot_declared_links = 595.048 ms`
- `navmesh_tile_snapshot_derived_links = 1416.705 ms`
- `navmesh_tile_publish = 149.053 ms`
- `navigation_snapshot_rebuild = 79.382 ms`
- `update_npcs = 3448.071 ms`
- `navmesh_route_tiles_published = 1098`
- `navmesh_tile_publish_queue_deferred_frame_work = 67`

This proves that cache-only optimization reduced the earlier 6752.576 ms worst snapshot but did not make publication frame-safe.

### Earlier Publication Deadlock

Report:

`artifacts/performance/citadel-life-continuity-known-208159-fair-publication.json`

The old scheduler could permanently starve priority publication after three successful priority tiles:

1. the fairness scheduler selected a regular tile;
2. live frame pressure deferred the regular tile;
3. the priority burst remained saturated;
4. every following frame selected and deferred regular work again.

The coordinator now falls back to an eligible priority tile on a pressure-blocked regular slot, increments the burst only after successful priority progress, resets it only after successful regular progress, and ignores deferred priority retries when determining eligibility.

Focused evidence retained in `/tmp`:

- `/tmp/navmesh-cross-region-pressure-strict2-1787450200.json`
- `/tmp/navmesh-cross-region-publication-isolation-1787368488.json`
- `/tmp/navmesh-cross-region-multi-pending-rerun2-1787369347.json`

The queue-specific probes were green, but the whole cross-region runner was not top-level green because another direct NavigationServer fixture failed. Do not cite these as final acceptance.

## Completed Navigation Corrections

### Single Publisher And Queue Semantics

`scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd` is the runtime NavMesh publication scheduler. The completed work includes:

- one publication tick separated from full route/ticket/locomotion `begin_frame` work;
- exact tile/source readiness and topology/link cardinality checks;
- source-scoped queue attempts (`attemptCount`, `firstAttemptTick`, `lastAttemptTick`);
- retry/backoff for pending installation, invalid links, and required empty snapshots;
- untouched priority tiles before retries and oldest-attempt rotation;
- multi-pending fairness for pending-install, invalid-link, empty-required, and valid tiles;
- pressure fallback that prevents the three-priority-tile starvation lock;
- `pending_budget` snapshot construction is restored to the queue without incrementing installation retry/backoff.

### Diagnostic UI Freeze

`scripts/testing/npc/CitadelLifePlaytestRunner.gd::fail_fixture_loading` previously JSON-stringified a roughly 24 MB failure payload into a visible `Label`. macOS sampling showed the main thread spending all time in `Label::_shape`, so deferred shutdown never executed.

The UI now:

- preserves complete details in the report;
- chooses a concise structured failure reason for the screen;
- collapses newlines;
- caps the concise reason at 160 characters;
- hard-caps the final visible reason at 240 characters.

Do not remove these caps.

### Safe Local Build Reuse

`GeneratedWorldNavigationAdapter` now indexes building supports by ID and tile. A proposed cross-snapshot support-sample cache was tested and removed because it made a disabled door-adjacent route remain geometrically valid during topology proof. Reuse must remain revision-bound inside one immutable build job unless all mutable source facts participate in cancellation.

Duplicate support IDs now fail closed instead of silently overwriting the first support in the ID index. Verify this path with a focused negative test.

## Partial Incremental Snapshot Builder

This is the most important unfinished implementation.

File:

`scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`

Production entry point:

```gdscript
advance_navmesh_tile_snapshot_build(tile_key, budget_usec)
```

The old synchronous `build_navmesh_tile_snapshot(tile_key)` now drains the same state machine, which is the correct direction: diagnostics and production must not have separate topology implementations.

Current state-machine stages:

1. `base`
2. `terrain`
3. `support_samples`
4. `support_surfaces`
5. `declared_links`
6. `transition_samples`
7. `derived_links`
8. `finalize`

Implemented slicing:

- terrain is advanced one terrain cell per atomic unit;
- local support sampling is advanced one collision-screened sample cell per atomic unit;
- neighboring transition-support sampling is explicit and advances one sample cell at a time;
- a source key is captured when the job starts;
- a source-key change cancels the stale job instead of publishing stale geometry;
- finalization rechecks the source key before caching the result;
- metrics include slice count, maximum slice time, maximum atomic time, over-budget slices, atomic overruns, and cancellation counters;
- the coordinator returns/retains `snapshot_pending_budget` rather than treating a budget yield as installation failure.

Still monolithic and unacceptable:

- `base` can synchronously trigger the global static navigation snapshot rebuild and live-block/collision index construction;
- `support_surfaces` still aggregates all sampled support cells in one call;
- `declared_links` still resolves every vertical/seam/interior link in one call and may resample endpoint supports;
- `derived_links` still creates/certifies all candidate transitions in one call;
- creation of each neighboring live tile snapshot inside `transition_samples` is still atomic;
- final descriptor/mesh/link preparation and `NavigationServer3D` registration remain synchronous in `NavmeshWorldService`;
- final map synchronization remains separately capable of a visible stall.

The incremental builder has not reached acceptance and may currently reduce route throughput too much in broad normal NPC tests.

## Latest Focused/Broad Test Results

### Parse Check

Last successful parse command after the initial incremental builder and transition-sample stage were added:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

It exited `0`. Run it again immediately because the final small instrumentation edit occurred after the last recorded parse check.

### Broad Navigation Suite

Command:

```bash
node tools/run-npc-navigation-tests.mjs
```

Result: failed. This suite already contains unrelated/flaky failures, but it revealed important effects of the partial builder:

- routes now visibly report `pending_nav_data`/`snapshot_pending_budget` instead of blocking in one giant call;
- one observed job reported `maxAtomicUsec=5511` and `maxSliceUsec=5513` while still in `terrain`;
- queue fairness across many tiles plus one-cell slices caused insufficient topology throughput for several timed NPC scenarios;
- existing failures included door crossing, goal selection, job outings, foraging, route invalidation, unreachable diagnostics, screenshot output, RID/resource errors, and a freed-instance error in `_live_occupant_cells_for_frame`;
- do not “fix” these by weakening timeouts or tests. First separate pre-existing failures from incremental-publication regressions with focused runners.

### Direct Cross-Region Scene

Command:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --scene res://scenes/testing/npc/NavmeshCrossRegionLinkTest.tscn
```

Result: exited `1`. It emitted NavigationServer overlapping-edge warnings and `navigation_registration_retry_exhausted` from the intentionally invalid topology-classification site. No fresh top-level JSON report was captured from this direct invocation. Use the existing tool runner/report arguments rather than citing terminal output.

### Aborted Unsafe Cache Experiment

A headed known-seed rerun named `citadel-life-continuity-known-208159-support-cache` was stopped intentionally. It remained in `prebaking_navigation_topology` with `door_topology_proof_invalid`: disabled and enabled paths crossed identically and no exact portal action appeared. The cross-snapshot cache causing that regression was removed. The progress file may remain, but there is no passing report and it must not be cited.

## Harsh Critic Verdict

Critic agent: `Parfit` (`01a027e7-f5c6-7422-9fef-8654303f34b5`)

Current verdict: **REJECT**.

The critic requires all of the following before acceptance:

### Frame-Bound Architecture

- production snapshot construction must be a revision-bound resumable job owned by the existing generated-world adapter;
- terrain cells, support sample cells, support-surface aggregation, declared-link resolution, derived candidate generation, and certification need explicit cursors;
- stale jobs must be cancelled and coalesced to the newest source key;
- budget yielding must remain `pending_budget`, not installation failure or retry backoff;
- synchronous diagnostics must drain the same state machine;
- Node/physics/scene access must remain on the main thread;
- worker threads may only process immutable pure data;
- descriptor, mesh vertices/polygons, and links must be prepared incrementally;
- a replacement region must remain disabled/off-map until complete and be exposed transactionally;
- final `region_set_navigation_mesh`, link installation, and map synchronization must each be measured;
- if final server commit cannot remain below the hard frame ceiling, reduce publication-region granularity rather than hiding the cost;
- tile builds must not synchronously cause the global static snapshot rebuild;
- explain the 1098 tile publications with per-tile/per-revision counts to distinguish legitimate streaming from revision churn.

Required metrics/evidence:

- `maxSliceUsec`
- `maxAtomicUsec`
- `overBudgetSlices`
- cancellations
- cache hits
- builds keyed by `(tile, sourceKey)`
- separate snapshot, descriptor/mesh, registration, and map-sync timings
- declared slice budget at or below 4 ms
- zero atomic units above 8 ms
- top-level-green focused runner
- deterministic signature equality between synchronous drain and incremental completion
- stale-source cancellation test proving stale jobs never publish

### Actor/Seam Acceptance

The current headed actor fixture is invalid for acceptance even though both actors arrived:

- the detector requires an immediately previous signed distance below `-0.05` and current distance above `+0.05`; normal physics movement may never jump more than 0.1 m in one frame;
- use persistent hysteresis or segment-plane intersection;
- require a direct transition from expected source support to expected target support within the certified seam corridor;
- reject routes that detour through unrelated supports;
- persist committed route lease, waypoints, source revision, repair/replan events, waypoint index, requested/applied velocity, and support owner throughout the act;
- prove simultaneous crowd-neighbor eligibility under the real neighbor-distance rule before requiring callbacks;
- require fresh matched callbacks for both actors referencing each other when they are eligible;
- capture a visible midpoint screenshot from a geometry-derived, unobstructed observer position;
- do not patch ORCA until direct seam routing and encounter eligibility are proven.

Subagent `Zeno` only added these currently unused constants near the top of `CitadelLifePlaytestRunner.gd`:

```gdscript
SURFACE_CONTINUITY_SEAM_HALF_BAND
SURFACE_CONTINUITY_SEAM_LATERAL_LIMIT
SURFACE_CONTINUITY_SEAM_ARM_DISTANCE
SURFACE_CONTINUITY_TIMELINE_INTERVAL_FRAMES
```

No fixture implementation or validation was completed. Either use the constants in the corrected fixture or remove them in a focused edit.

## Recommended Continuation Order

Do not start another broad headed run immediately. Continue in this order:

1. Run the parse check and fix only errors introduced by the checkpoint.
2. Add a focused incremental snapshot-builder contract to `NavmeshCrossRegionLinkRunner.gd` or a dedicated existing navigation runner:
   - synchronous-drain signature equals incremental signature;
   - multiple small-budget advances complete deterministically;
   - source revision changes mid-job cancel the old job;
   - cancelled job never reaches `NavmeshWorldService`;
   - `pending_budget` does not increment installation retry count;
   - queue retains and fairly rotates other tiles.
3. Finish slicing `GeneratedWorldNavigationAdapter`:
   - incremental static/base snapshot readiness instead of global rebuild;
   - support-surface row/run aggregation cursors;
   - one declared link endpoint/certification work unit at a time, with sample work also resumable;
   - derived entries, candidate pairs, blocker checks, seam certification, candidate grouping, and final link construction with nested cursors;
   - avoid “one support” or “one link” as the unit when one item can exceed 8 ms.
4. Add bounded throughput policy:
   - preserve the 4 ms frame slice;
   - reduce work per atomic unit rather than raising the budget;
   - allow multiple cheap units in one slice;
   - keep priority/regular fairness and source coalescing;
   - record per-tile/source build and cancellation counts.
5. Make `NavmeshWorldService` resumable:
   - descriptor conversion;
   - sorted surface iteration;
   - polygon extraction;
   - vertex/index deduplication;
   - link preparation;
   - disabled/off-map replacement region;
   - measured transactional server commit;
   - measured map sync.
6. Get the focused cross-region runner top-level green. Do not excuse unrelated failures inside that runner.
7. Correct the surface-continuity headed fixture exactly as required by the critic.
8. Run the known seed `208159` and inspect report plus screenshots.
9. If known-seed topology/actor proof passes without navigation-owned frame stalls, derive a fresh random seed and run the same headed acceptance.
10. Send both reports, screenshots, traces, and timing maxima to Parfit. Continue until Parfit accepts.
11. Only then run broader normal-world NPC regression and performance suites.

## Important Failure Interpretations

- `pending_nav_data` is not unreachable.
- `pending_budget` is not installation failure.
- endpoint arrival is not proof of direct seam continuity.
- an aggregate ORCA callback count is not per-actor fresh callback proof.
- a screenshot without both actors and the seam is not visual acceptance evidence.
- a green static audit before Godot starts is not gameplay acceptance.
- a long watchdog is not a performance fix.
- a cache that ignores door/static/source revision facts is not valid reuse.
- a known-seed-only prewarm is not a procedural solution.

## Machine-Local Artifact

`addons/zylann.voxel/bin` is a worktree-local symlink to:

`/Users/lakam99/Documents/voxel-godot/addons/zylann.voxel/bin`

It is not project source and should not be committed. It was excluded locally for this checkpoint. Do not delete the target directory.

## Suggested First Commands

```bash
cd /Users/lakam99/Documents/voxel-godot-citadel-texture-poc
git status --short
git branch --show-current
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Then inspect:

```bash
sed -n '320,620p' scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd
sed -n '1380,1665p' scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd
sed -n '190,260p' scripts/npc_ai/navigation/NavmeshWorldService.gd
sed -n '1010,1085p' scripts/npc_ai/navigation/NavmeshWorldService.gd
sed -n '3230,3360p' scripts/testing/npc/CitadelLifePlaytestRunner.gd
```

Do not reset this branch to make the diff smaller. Continue from the checkpoint and make the next commit focused.
