# Phase 11 Report - Streaming, Save/Load, And Simulation LOD

## 1. Phase Identification

- Phase: 11 - Streaming, Save/Load, And Simulation LOD
- Branch: `npc-pathfinding/phase-11-streaming-save`
- Date: 2026-06-27
- Scope status: branch gates pass; merged `master` gates are pending until merge.
- Base commit before Phase 11 branch changes: `2521122806da5d5b6583802a83fd83161a0c1875`
- Branch implementation/report commit: pending before branch commit
- Merge commit: pending
- Post-merge `master` evidence commit: pending

## 2. Objective

Phase 11 adds bounded NPC simulation LOD, abstract semantic transit, chunk-streaming safety, lifecycle cleanup, and additive durable save/load facts without changing terrain generation, town generation, or prior NPC door/traffic/job authority.

## 3. Pre-Phase State And Risks

Before this phase, Phase 10 had real shared object authority for jobs, guards, and player/NPC resource interactions. NPCs still lived mostly as active actors, so long-distance streaming, actor deletion, and save/load paths could leave route, traffic, door, avoidance, or smart-object ownership behind.

Relevant risks at phase start:

- Active NPC route, traffic, door, avoidance, or smart-object ownership could survive demotion, unregister, deletion, or load repair.
- Distance-based abstraction could bypass walls, doors, locked portals, combat, scripted sequences, or visible door crossings.
- Abstract travel could imply movement through unknown, infeasible, locked, or unloaded topology.
- Promotion could place a body into unsafe collision or inside a door threshold.
- Save snapshots could accidentally persist transient route/planner/reservation/debug state.
- Old saves needed additive defaults and safe placement repair rather than save-format breakage.
- Chunk unloads needed to hold movement and request topology rather than teleporting or pushing through missing route data.

## 4. Implementation Summary

Added composed lifecycle services under `scripts/npc_ai/lifecycle/`:

- `AbstractNpcTransit` represents semantic abstract travel through known feasible region/portal edges, with locked/denied/infeasible/unknown/unloaded-topology rejection and durable save summaries.
- `NpcSimulationLodService` owns active, nearby, and abstract simulation states; deterministic distance thresholds and hysteresis; nearby brain cadence; abstract advancement; demotion and promotion gates; prefetch near tile boundaries; tile-unload hold/replan state; lifecycle cleanup; leak counters; and durable save/load snapshot handling.

Integrated lifecycle authority into the existing NPC stack:

- `NpcAutonomySystem` creates and exposes the simulation LOD service, registers legacy NPCs with it, gates legacy brain updates by LOD cadence, skips abstract bodies, advances abstract transit, and forwards snapshot/apply/prefetch/cleanup calls.
- `NpcSystem` adds lifecycle fields to NPC entries, snapshots additive durable lifecycle facts, applies saved lifecycle facts through the autonomy system, restores job metadata from saves, skips abstract actor updates, and cleans route and avoidance state for lifecycle cleanup.
- `NpcPathing`, `NpcNavigationCoordinator`, and `NpcLocomotionController` expose actor cleanup so demotion, deletion, and unregister paths can release route and avoidance state.
- `SmartObjectService` exposes owner-wide release and owner reservation counts for lifecycle cleanup and leak audits.
- `NpcSafePlacementService` safely places detached bodies by local `position` and in-tree bodies by `global_position`, preserving promotion/load placement validation.

Branch validation found and fixed two issues before the green branch gate:

- Distance-only demotion was initially too broad and suppressed legacy job navigation. `validate_abstract_demotion_plan()` now rejects distance demotion unless there is an explicit traversable transit edge, existing non-blocked transit, or allowed stationary semantic region.
- Direct public `update_npc()` calls from existing playtest coverage could be starved by stale LOD brain cadence. `update_npcs()` now marks when the LOD gate already ran, while direct `update_npc()` calls force `npc_lod_brain_due = true`.

## 5. Files Added And Changed

Added lifecycle runtime files:

- `scripts/npc_ai/lifecycle/AbstractNpcTransit.gd`
- `scripts/npc_ai/lifecycle/NpcSimulationLodService.gd`

Added focused Phase 11 test/tool files:

- `scripts/testing/npc/NpcStreamingSaveTestCases.gd`
- `tools/npc/run-npc-streaming-save-tests.ps1`

Changed NPC runtime and lifecycle integration:

- `scripts/NpcSystem.gd`
- `scripts/npc_ai/NpcAutonomySystem.gd`
- `scripts/npc_ai/NpcConstants.gd`
- `scripts/NpcPathing.gd`
- `scripts/npc_ai/NpcSafePlacementService.gd`
- `scripts/npc_ai/routing/NpcNavigationCoordinator.gd`
- `scripts/npc_nav/NpcLocomotionController.gd`
- `scripts/npc_ai/interactions/SmartObjectService.gd`

Changed test registration:

- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`

No tracked world-signature baseline file changed in this phase.

## 6. Data And API Contracts

Lifecycle state added to NPC entries:

- `simulationLod`
- `abstractSimulated`
- `abstractRegionId`
- `abstractTransit`
- `interiorRegionId`
- `restoredScheduleIntent`
- `npc_lod_brain_due`
- `movementHeldForTopology`
- `requestedTopologyTile`

LOD constants added to `NpcConstants`:

- `LOD_ACTIVE_ENTER_DISTANCE = 42.0`
- `LOD_ACTIVE_EXIT_DISTANCE = 52.0`
- `LOD_NEARBY_ENTER_DISTANCE = 96.0`
- `LOD_NEARBY_EXIT_DISTANCE = 112.0`
- `LOD_NEARBY_BRAIN_INTERVAL_SECONDS = 0.45`
- `LOD_ABSTRACT_EVENT_INTERVAL_SECONDS = 2.0`
- `LOD_PREFETCH_BOUNDARY_MARGIN_CELLS = 3`
- `LOD_SCHEMA_VERSION = 2`

Durable lifecycle facts saved additively through existing NPC job facts include:

- stable identity, role, town key, home/porch/guard/interior cells, interior region, level, and position;
- durable job, job resource, personal inventory, hunger/max hunger, equipment, guard duty, job runs, and durable goal;
- `simulationLod`, `abstractRegionId`, durable `abstractTransit`, and durable door state.

Transient state is intentionally omitted from lifecycle saves, including:

- route cells/actions/snapshots/goal/wait/yield/priority;
- path waypoints and path refresh timers;
- traffic groups, door crossing metadata, job reservation and approach slot IDs;
- requested/applied velocities, avoidance IDs, planner open/closed sets, debug trace, and wait-for graph state.

## 7. Migration And Compatibility

Save changes are additive through `LOD_SCHEMA_VERSION = 2`. Old snapshots without lifecycle fields load with generated/default job and LOD values. Missing or invalid saved positions go through `safe_place_npc(..., "load_restore")`; invalid saved positions are migrated to safe home placement and recorded in the entry migration log.

Night schedule intent reconstructs from saved guard duty and current time. Guard duty, job runs, personal inventory, hunger, carried resources, and durable abstract transit survive round trips. Transient route, planner, avoidance, reservation, queue, and trace state is intentionally absent from snapshots and reconstructed through normal runtime systems.

World generation and existing save compatibility are preserved. No terrain/town/prop RNG stream was changed, and the atlas world signature still matches the tracked baseline.

## 8. Focused Test Evidence

Command:

```powershell
.\tools\npc\run-npc-streaming-save-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase11-streaming-save-after-direct-update-guard.json
```

Report:

- Path: `artifacts/npc/reports/phase11-streaming-save-after-direct-update-guard.json`
- Suite: `streaming_save`
- Time mode: both
- Result count: 38
- Failure count: 0
- Duration: 0.102 seconds

Minimum IDs covered in day and night modes:

- `npc_stream_active_to_abstract_safe`
- `npc_stream_abstract_to_active_safe_span`
- `npc_stream_no_promote_in_door_threshold`
- `npc_stream_no_demote_during_crossing`
- `npc_stream_route_across_chunk_boundary`
- `npc_stream_prefetch_before_boundary`
- `npc_stream_unloaded_goal_pending_not_teleport`
- `npc_stream_abstract_respects_locked_portal`
- `npc_stream_lod_hysteresis_no_thrashing`
- `npc_stream_actor_removal_releases_all_ownership`
- `npc_save_old_snapshot_defaults`
- `npc_save_round_trip_durable_state`
- `npc_save_no_transient_route_or_reservation`
- `npc_save_invalid_position_safe_migration`
- `npc_save_night_schedule_reconstructs`
- `npc_save_guard_duty_reconstructs`
- `npc_save_door_durable_state_reconstructs`
- `npc_save_deterministic_round_trip`
- `npc_save_world_signature_unchanged`

## 9. Contract Harness Evidence

Command:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase11-contract-both.json
```

Report:

- Path: `artifacts/npc/reports/phase11-contract-both.json`
- Suite: `contract`
- Time mode: both
- Result count: 40
- Failure count: 0
- Assertion count: 110
- Duration: 0.092 seconds

## 10. Day/Night Evidence

The focused streaming/save suite ran every Phase 11 case in both day and night modes.

Day/night-specific coverage includes:

- no demotion while crossing doors;
- no promotion in door thresholds;
- locked portal rejection for abstract travel;
- night schedule reconstruction;
- guard duty reconstruction;
- durable door state reconstruction;
- deterministic save round trip.

The branch all-runner also reran observation scenarios:

- `npc_observation_dusk`: pass, exit 0, 0.664 seconds
- `npc_observation_midnight`: pass, exit 0, 0.640 seconds

## 11. NPC Suite Evidence

Command:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both
```

Report:

- Path: `artifacts/npc/reports/all-npc-both.json`
- Time mode: Both
- Result count: 11
- Failure count: 0
- Duration: 22.571 seconds

Suites:

- `contract`: pass, exit 0, 2.020 seconds
- `motor`: pass, exit 0, 1.417 seconds
- `nav_world`: pass, exit 0, 1.626 seconds
- `route`: pass, exit 0, 5.314 seconds
- `repair`: pass, exit 0, 1.958 seconds
- `door`: pass, exit 0, 1.708 seconds
- `avoidance`: pass, exit 0, 1.438 seconds
- `traffic`: pass, exit 0, 2.117 seconds
- `behavior`: pass, exit 0, 1.739 seconds
- `interaction`: pass, exit 0, 1.337 seconds
- `streaming_save`: pass, exit 0, 1.880 seconds

## 12. Legacy Navigation And Broad Playtest Evidence

Legacy navigation command through all-runner:

```powershell
.\tools\run-npc-navigation-tests.ps1 -ReportPath artifacts\test-runners\npc-navigation-report.json -Seed atlas-1492
```

Report:

- Path: `artifacts/test-runners/npc-navigation-report.json`
- Result count: 11
- Failure count: 0
- Seed: `atlas-1492`

Broad playtest command through all-runner:

```powershell
.\tools\run-playtest.ps1 -ReportPath artifacts\test-runners\playtest-report.json -Seed atlas-1492
```

Report:

- Path: `artifacts/test-runners/playtest-report.json`
- Result count: 181
- Failure count: 0
- Seed: `atlas-1492`

Earlier branch failures, fixed before the green rerun:

- Initial all-runner legacy navigation failure: distance LOD demotion suppressed legacy job/forager navigation; fixed by requiring a valid abstract demotion plan.
- Follow-up all-runner playtest failure: direct public `update_npc()` calls were starved by stale LOD cadence; fixed by forcing brain due for direct update calls.

## 13. Branch All-Runner Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1 -ReportPath artifacts\test-runners\phase11-branch-all-test-runners-report.json -Seed atlas-1492
```

Report:

- Path: `artifacts/test-runners/phase11-branch-all-test-runners-report.json`
- Seed: `atlas-1492`
- Result count: 9
- Failure count: 0
- Duration: 928.282 seconds
- Stopped early: false
- Stop on failure: false

Runner results:

- `npc_focused`: pass, exit 0, 22.934 seconds
- `npc_observation_dusk`: pass, exit 0, 0.664 seconds
- `npc_observation_midnight`: pass, exit 0, 0.640 seconds
- `world_signature`: pass, exit 0, 16.923 seconds
- `visual_manifest`: pass, exit 0, 0.090 seconds
- `npc_navigation_legacy`: pass, exit 0, 119.785 seconds
- `story_playtest`: pass, exit 0, 76.528 seconds
- `visual_captures`: pass, exit 0, 91.687 seconds
- `playtest`: pass, exit 0, 598.968 seconds

## 14. Merged Master Evidence

Pending until Phase 11 is committed, no-ff merged to `master`, and the required `master` all-runner pass is recorded.

## 15. Performance And Boundedness Metrics

Measured runner durations:

- Focused streaming/save suite: 0.102 seconds
- Contract harness: 0.092 seconds
- All NPC suites: 22.571 seconds
- Branch all-runner: 928.282 seconds
- Branch all-runner playtest: 598.968 seconds
- Branch all-runner visual captures: 91.687 seconds

Boundedness controls present:

- LOD uses deterministic enter/exit thresholds with hysteresis.
- Nearby actors throttle brain updates to a bounded cadence while active actors stay per-update.
- Abstract actors advance by a bounded elapsed/expected-duration transit model.
- Demotion is rejected in door thresholds, door sweeps, active traffic/door reservations, combat, physical blocking/penetration, noninterruptible interactions, and visible scripted sequences.
- Abstract demotion requires a traversable transit edge, existing non-blocked transit, or explicit stationary semantic region.
- Promotion uses `NpcSafePlacementService` and rejects unloaded topology, blocked transit, missing bodies, and missing positions.
- Chunk unloads mark movement held for topology, set route status to `PENDING`, and request the missing tile instead of moving through absent topology.
- Actor cleanup releases traffic, door holds, smart-object ownership, route state, and avoidance registrations.
- Save/load omits transient route/planner/reservation/debug state.

## 16. Determinism And World Signature

Command through all-runner:

```powershell
.\tools\run-world-signature.ps1 -OutputPath artifacts\test-runners\world-signature-atlas-1492.json -Seed atlas-1492
```

Evidence:

- Baseline: `artifacts/baselines/world-signature/atlas-1492.json`
- Fresh output: `artifacts/test-runners/world-signature-atlas-1492.json`
- Baseline SHA-256: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`
- Fresh output SHA-256: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`
- Runner result: pass

No tracked world-signature baseline change is present in this phase. The generated fresh signature matches the tracked baseline byte-for-byte.

## 17. Invariant Checklist

- Active NPCs remain real bodies using existing route, door, traffic, avoidance, job, and combat systems: yes.
- Nearby NPCs use bounded brain cadence without changing deterministic route authority: yes.
- Abstract NPCs do not keep physical collision active: yes, only after demotion gates pass.
- NPCs are not abstracted in door thresholds, door sweeps, active bottleneck reservations, combat, physical blocking, noninterruptible interactions, or visible scripted sequences: yes.
- Abstract transit rejects locked, denied, unauthorized, infeasible, unknown, and unloaded topology edges: yes.
- Promotion uses safe placement and does not place through door thresholds or unloaded topology: yes.
- Chunk unload does not teleport NPCs through missing route data: yes.
- Actor removal releases traffic, door, smart-object, route, and avoidance ownership: yes.
- Save/load is additive and old snapshots get defaults: yes.
- Transient route/planner/avoidance/reservation/debug state is absent from lifecycle snapshots: yes.
- World signature is unchanged: yes.
- Branch focused and repository gates pass: yes.
- Merged `master` gates pass: pending.

## 18. Deviation Register

- Branch all-runner was run without `-StopOnFailure` so all runner outcomes were captured in one aggregate report. It reported zero failures and did not stop early.
- Merged `master` evidence is pending in this branch report and must be added after merge and rerun.

## 19. Known Issues And Debt

- Some legacy route/job pacing fields remain in active NPC entries for compatibility. The lifecycle snapshot filter keeps them out of durable saves.
- Abstract semantic transit currently validates provided edge facts; broader runtime generation of long-distance semantic edges remains later-phase scope.
- Broad playtest is long; this phase used background execution, progress polling, and report freshness checks to avoid silent waits.

## 20. Static Audit Results

Search run:

```powershell
rg -n "routeCells|routeActions|avoidanceRid|avoidance_rid|reservation|plannerOpenSet|plannerClosedSet|debugTrace|debug_trace|routePlan|trafficReservation|doorHold|smartObject" scripts/NpcSystem.gd scripts/npc_ai/lifecycle scripts/npc_ai/NpcAutonomySystem.gd
```

Classified results:

- `routeCells` and `routeActions` remain active runtime route fields in `NpcSystem`; `NpcSimulationLodService.TRANSIENT_SAVE_KEYS` and `snapshot_has_transient_state()` explicitly filter them from durable lifecycle saves.
- Reservation matches are active Phase 10 traffic/smart-object ownership, plus owner release and leak-count APIs used by lifecycle cleanup.
- `plannerOpenSet`, `plannerClosedSet`, `debugTrace`, and `avoidanceRid` appear only in transient-key filtering and audit checks for lifecycle snapshots.
- `doorHolds`, `trafficReservations`, `smartObjectSlots`, route requests, avoidance registrations, and contexts are lifecycle leak counters.

Search run:

```powershell
rg -n "global_position\s*=|position\s*=|collision_layer\s*=\s*0|collision_mask\s*=\s*0|toggle_door\(|find_children|get_tree\(" scripts/NpcSystem.gd scripts/npc_ai scripts/npc_nav scripts/NpcPathing.gd
```

Classified results:

- No `toggle_door()` behavior was introduced.
- `collision_layer = 0` and `collision_mask = 0` occur only in lifecycle demotion after safety gates pass; prior layers/masks are restored on promotion.
- `global_position =` and `position =` actor writes are confined to safe placement service for validated spawn/promotion/load placement. Other matches are reads, local variables, or existing motor/contract data assignment.

Additional validation:

```powershell
git diff --check
```

Result: no whitespace errors; only existing Git line-ending normalization warnings.

## 21. Risk Assessment For Phase 12

Phase 12 should harden phase interactions under longer soak and regression conditions:

- verify LOD cleanup remains leak-free over longer actor add/remove and chunk unload/reload loops;
- stress save/load around abstract transit and door/job ownership transitions;
- watch for broad playtest time drift caused by LOD cadence changes;
- keep world signature and deterministic NPC ID ordering fixed while adding any hardening probes.

## 22. Verdict

Phase 11 branch evidence passes. Do not begin Phase 12 until Phase 11 is committed, no-ff merged to `master`, the required `master` gates pass, and this report is updated with merged `master` evidence.
