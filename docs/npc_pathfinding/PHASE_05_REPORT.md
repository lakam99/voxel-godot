# Phase 05 Report - Incremental Route Repair and Dynamic World Response

## 1. Phase Identification

- Phase: 05 - Incremental Route Repair and Dynamic World Response
- Branch: `npc-pathfinding/phase-05-incremental-repair`
- Base commit before Phase 05 branch changes: `10b23f903df06ab0e90dbe1bd95bde1ac52474b2`
- Branch implementation commit: `bdaa9f80c4db005e9884e1fb874f85076a7eea5e`
- Merge commit: `5ebd7ef6b320afaaef26d1724be51a9d8334a147`
- Date: 2026-06-26
- Controlling specification: `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`
- Scope status: branch implementation gates passed; merged `master` gate passed after the required non-fast-forward merge.

## 2. Objective

Phase 05 makes active routes respond to world changes without blind fixed-interval replanning. The required behavior is dependency-scoped incremental repair, bounded repeated-failure handling, fresh A* oracle comparison in tests, physical stop before unsafe blockers, action-premise invalidation for removed resources or unavailable doors, and day/night dynamic coverage.

## 3. Pre-Phase State

- `git status --short` before Phase 05 work showed one pre-existing modified tracked baseline: `artifacts/baselines/world-signature/atlas-1492.json`.
- That baseline artifact remained outside the Phase 05 staged scope.
- Phase 04 had introduced typed route corridors, traversal actions, hierarchical route planning, and the legacy route adapter path.
- Production NPC route movement still consumed legacy route dictionaries, so Phase 05 integration needed to preserve that compatibility shape while attaching repair state to typed route results.

## 4. Implementation Summary

`IncrementalRouteRepair.gd` now owns active route repair state. It registers route graphs by route ID, maintains D* Lite/LPA*-style `g`, `rhs`, `km`, predecessor, edge override, and deterministic queue state, and computes bounded repairs under the caller's expansion budget.

Repair registration indexes active routes by tile, edge, portal, and object dependency. Change classification distinguishes irrelevant corridor changes, cost-only/local edge updates, abstract portal changes, action-premise invalidations, and unavailable streamed topology. Unrelated changes return `unchanged` without a full replan.

Repair responses include structured status, reason, route result, path, classification, and metrics. Metrics include changed vertices, expansion count, reused state, full replan count, `g`/`rhs` counts, `km`, failure count, pending state, and safe-stop requirement.

Route results from `HierarchicalRoutePlanner` now retain the repair graph, repair start key, repair goal keys, and repair request. The legacy `NpcRoutePlanner` compatibility adapter registers successful routes with the repair service and applies repair responses back onto `routeCells`, `pathWaypoints`, `routeActions`, `routeStatus`, and `routeReason`.

`NpcNavigationCoordinator`, `NpcPathing`, `NpcAutonomySystem`, and `NpcSystem` now forward navigation change events through the repair path. The legacy adapter can therefore stop or refresh current movement state from navigation events without waiting for a fixed retry interval.

Fixed route retry behavior was removed from `NpcLocomotionController`: the old retry counter is now set to `0` and empty blocked/waiting routes remain terminal until an explicit invalidation or caller replan. Cached nonempty routes recover from prior waiting/blocked statuses as routable when their route data remains valid.

Forager target loss now reaches the action boundary in the legacy job adapter. A blocked forager route marks the current target node unreachable for that NPC, clears the target, increments bounded route-failure telemetry, and selects a new resource or returns to idle after the failure limit. Harvest success clears the failure counter.

Door compatibility was tightened while preserving the Phase 06 ownership plan. Route door matching now normalizes collider nodes to their interaction block, active route door holds prevent premature close while an actor still needs the portal, and door close clearance uses a capsule/sweep-safe radius. This fixed the legacy two-NPC door crossing gate without introducing blind toggles or timeout-based unsafe closure.

## 5. Files Added, Changed, And Removed

Added repair service:

- `scripts/npc_ai/routing/IncrementalRouteRepair.gd`

Added repair tests and runner:

- `scripts/testing/npc/NpcRepairTestCases.gd`
- `tools/npc/run-npc-repair-tests.ps1`

Changed repair integration:

- `scripts/NpcPathing.gd`
- `scripts/NpcSystem.gd`
- `scripts/npc_ai/NpcAutonomySystem.gd`
- `scripts/npc_ai/contracts/RouteResult.gd`
- `scripts/npc_ai/routing/HierarchicalRoutePlanner.gd`
- `scripts/npc_ai/routing/NpcNavigationCoordinator.gd`
- `scripts/npc_nav/NpcLocomotionController.gd`
- `scripts/npc_nav/NpcRoutePlanner.gd`

Changed shared constants/enums:

- `scripts/npc_ai/NpcConstants.gd`
- `scripts/npc_ai/NpcEnums.gd`

Changed test integration:

- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`

Removed files: none.

## 6. Data And API Contracts

New repair constants:

- `ROUTE_REPAIR_FAILURE_LIMIT = 3`
- `ROUTE_REPAIR_FAILURE_HISTORY_CAPACITY = 256`

New route reasons:

- `target_gone`
- `topology_unavailable`
- `repair_loop_bound`
- `action_premise_invalid`

New repair statuses:

- `unchanged`
- `repaired`
- `waiting`
- `action_revision`
- `failed`

New repair classifications:

- `irrelevant_to_corridor`
- `cost_only_update`
- `local_edge_update`
- `abstract_portal_update`
- `action_premise_invalid`
- `topology_unavailable`

`RouteResult` now carries `repair_graph`, `repair_start_key`, `repair_goal_keys`, and `repair_request`. These fields are used by the repair service and are not save data.

## 7. Dynamic Event Behavior

Relevant local edge changes update affected vertices and repair the active route using retained `g`/`rhs` state. Safe-stop responses clear active waypoints so physical movement does not continue into the newly blocked segment.

Door lock events affect portal/edge feasibility. If an alternate route exists, the repair result returns a repaired corridor. If no route exists, the result becomes terminal with an explicit reason rather than entering a bump loop.

Door unlock and block removal events can restore feasibility and produce repaired paths without full blind replanning.

Resource or smart-object removal is classified as an action-premise invalidation. The route layer reports `target_gone` or `action_premise_invalid`; the legacy forager adapter clears that target and selects another valid resource or terminates the goal loop after the bounded failure policy.

Chunk unload events classify as unavailable topology. Active routes return a waiting/topology response instead of continuing through missing physical topology.

Unrelated world changes do not touch route generation or force a full replan.

## 8. Focused Test Evidence

Focused and compatibility gates run on branch `npc-pathfinding/phase-05-incremental-repair`:

| Command | Result | Evidence |
| --- | --- | --- |
| `.\tools\npc\run-npc-repair-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\repair-both.json`; 32 results, 0 failures, 74 assertions, 0.150s |
| `.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\all-npc-both.json`; 5 suites, 0 failures, 7.349s |
| `.\tools\run-npc-navigation-tests.ps1 -ReportPath artifacts\test-runners\npc-navigation-report.json` | Pass | `artifacts\test-runners\npc-navigation-report.json`; 11 results, 0 failures |
| `.\tools\run-playtest.ps1` through all-runner | Pass | `artifacts\test-runners\playtest-report.json`; fresh report, exit 0 |

Required Phase 05 repair IDs covered:

- `npc_repair_unrelated_change_no_replan`
- `npc_repair_block_added_on_corridor`
- `npc_repair_block_removed_shortens_route`
- `npc_repair_terrain_edit_on_corridor`
- `npc_repair_door_locked_alternate`
- `npc_repair_door_unlocked_resumes`
- `npc_repair_resource_removed_replan_action`
- `npc_repair_chunk_unload_suspends_or_alternates`
- `npc_repair_stale_generation_rejected`
- `npc_repair_matches_fresh_astar_cost`
- `npc_repair_reuses_search_state`
- `npc_repair_bounded_no_loop`
- `npc_repair_physical_stop_before_new_blocker`
- `npc_repair_day_worker_dynamic_block`
- `npc_repair_night_guard_dynamic_block`
- `npc_repair_night_civilian_home_dynamic_block`

Legacy NPC navigation cases passed:

- `npc_nav_capsule_collision_gate`
- `npc_nav_two_npc_door_crossing`
- `npc_nav_home_return_fallback_semantics`
- `npc_nav_reachability_goal_selection`
- `npc_nav_generic_town_npc_homes`
- `npc_nav_generic_job_outings`
- `npc_nav_forager_goal_inventory_hunger`
- `npc_nav_door_open_close_cycle`
- `npc_equipment_and_pathing`
- `npc_route_invalidates_player_block`
- `npc_unreachable_goal_diagnostics`

## 9. Day And Night Evidence

`repair-both.json` ran every required repair case once at canonical day and once at canonical night:

- Day snapshot: `time_of_day = 0.25`, display hour `12:00`.
- Night snapshot: `time_of_day = 0.75`, display hour `00:00`.
- Total repair matrix: 16 case IDs x 2 time modes = 32 results, 0 failures.

Representative repair evidence:

- Unrelated change: response classification `irrelevant_to_corridor`, status `unchanged`, `fullReplans = 0`.
- Corridor blocker: response classification `local_edge_update`, `safeStopRequired = true`, repaired path selected the alternate corridor.
- Block removal: repaired path shortened when the restored edge was beneficial.
- Terrain edit: edge updates changed local feasibility and repaired affected vertices.
- Door locked: alternate route selected with no collision bump loop.
- Door unlocked: waiting/blocked route could resume through the restored portal.
- Resource removed: result reason reached the action boundary as `target_gone`/action revision.
- Chunk unload: status became waiting/topology unavailable instead of continuing into absent topology.
- Stale generation: stale repair result was rejected.
- Fresh A* oracle: repaired cost/existence matched the oracle.
- Reuse test: metrics reported `reusedState = true`, retained `g`/`rhs` state, and `fullReplans = 0`.
- Bounded loop: repeated impossible repair terminated with `repair_loop_bound` after the configured failure limit.
- Day worker, night guard, and night civilian dynamic block cases all repaired while preserving the original arrival contract.

Broad playtest continuity evidence from `artifacts\test-runners\playtest-report.json`:

- `tutorial_elder_returns_home`: pass.
- `tutorial_npc_home_and_guard_behavior`: pass.
- `forager_goal_inventory_hunger`: pass; forager selected/gathered berries, then returned with a terminal blocked route reason rather than an unbounded retry.

## 10. Full All-Runner Evidence On Phase Branch

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Report: `artifacts\test-runners\all-test-runners-report.json`

Result: pass, 7 runners, 0 failures, 1636.904s, finished `2026-06-26T02:24:46.8190464Z`.

| Runner | Exit | Result | Duration | Fresh report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | Pass | 7.662s | yes |
| `npc_navigation_legacy` | 0 | Pass | 176.740s | yes |
| `playtest` | 0 | Pass | 1300.798s | yes |
| `story_playtest` | 0 | Pass | 69.367s | yes |
| `world_signature` | 0 | Pass | 15.352s | yes |
| `visual_captures` | 0 | Pass | 66.843s | yes |
| `visual_manifest` | 0 | Pass | 0.091s | yes |

Runner registry used: `tools\test-runner-registry.json`.

## 11. Merged Master Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Report: `artifacts\test-runners\all-test-runners-report.json`

Result: pass, 7 runners, 0 failures, 1514.475s, finished `2026-06-26T02:52:43.3766311Z` on merged `master` commit `5ebd7ef6b320afaaef26d1724be51a9d8334a147`.

| Runner | Exit | Result | Duration | Fresh report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | Pass | 7.662s | yes |
| `npc_navigation_legacy` | 0 | Pass | 263.706s | yes |
| `playtest` | 0 | Pass | 1091.130s | yes |
| `story_playtest` | 0 | Pass | 69.616s | yes |
| `world_signature` | 0 | Pass | 15.518s | yes |
| `visual_captures` | 0 | Pass | 66.702s | yes |
| `visual_manifest` | 0 | Pass | 0.092s | yes |

## 12. Static And Prohibited-Shortcut Audit

Commands run on the Phase 05 branch:

```powershell
git diff --check
rg -n "MAX_ITERATIONS|for iteration in range\(|routeRetry|fixed retry|retry interval|retry_ticks|RETRY" scripts\npc_nav scripts\npc_ai\routing scripts\NpcPathing.gd scripts\NpcSystem.gd
```

Results:

- `git diff --check`: no whitespace errors; line-ending warnings only, including the pre-existing unstaged world-signature baseline.
- Old fixed route iteration caps: no matches.
- Fixed retry behavior: only two intentional `entry["routeRetryTicks"] = 0` assignments remain in `NpcLocomotionController.gd`; no fixed retry interval remains.
- No generated world signature drift was accepted. `.\tools\run-world-signature.ps1` through all-runner matched the tracked baseline.
- The pre-existing modified `artifacts/baselines/world-signature/atlas-1492.json` remained unstaged.

## 13. Gate Matrix

| Phase 05 gate | Status | Evidence |
| --- | --- | --- |
| Unrelated world change does not rebuild or replan unaffected routes | Pass | `npc_repair_unrelated_change_no_replan`; classification `irrelevant_to_corridor`, `fullReplans = 0` |
| Relevant change stops unsafe movement before contact/penetration and produces bounded repair | Pass | `npc_repair_block_added_on_corridor`, `npc_repair_physical_stop_before_new_blocker`; `safeStopRequired = true` |
| Repaired route cost/existence matches fresh A* within deterministic tolerance | Pass | `npc_repair_matches_fresh_astar_cost` |
| Repair reuses state in required tests | Pass | `npc_repair_reuses_search_state`; metrics include `reusedState = true`, nonempty `g`/`rhs` state, `fullReplans = 0` |
| Repeated impossible repairs terminate with a reason | Pass | `npc_repair_bounded_no_loop`; reason `repair_loop_bound` after configured failure limit |
| Resource/door premise changes reach the action-planning boundary correctly | Pass | `npc_repair_resource_removed_replan_action`, `npc_repair_door_locked_alternate`, `npc_repair_door_unlocked_resumes` |
| Day/night dynamic cases pass | Pass | `npc_repair_day_worker_dynamic_block`, `npc_repair_night_guard_dynamic_block`, `npc_repair_night_civilian_home_dynamic_block` in both time modes |
| All prior focused suites pass on branch | Pass | `.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both`; 5 suites, 0 failures |
| Every repository runner passes on branch | Pass | `.\tools\run-all-test-runners.ps1`; 7 runners, 0 failures |
| Every repository runner passes on merged `master` | Pass | `.\tools\run-all-test-runners.ps1`; 7 runners, 0 failures, 1514.475s |

## 14. Review Questions

Is this actual incremental search state reuse?

Yes. The repair service registers each route with retained graph, predecessor, `g`, `rhs`, queue, `km`, and dependency indexes. Local edge and portal events update affected vertices and recompute from retained state. Tests assert `reusedState = true`, `fullReplans = 0`, and nonempty state counts for repair cases.

Are changes dependency-scoped?

Yes. Active routes are indexed by tile, edge, portal, and object. `routes_for_event()` returns only affected routes; unrelated block changes return no route hit and an unchanged response.

Does physical movement stop safely while repair is pending?

Yes. Repair responses that alter current/future safety set `safeStopRequired`. The compatibility adapter clears active waypoints for safe-stop responses, causing the locomotion path to wait instead of stepping into a new blocker.

Are action premise failures distinguished from route failures?

Yes. Removed resource/smart-object targets classify as `action_premise_invalid` and return route reasons such as `target_gone` rather than `no_route`. The legacy forager adapter then clears that action target and selects another valid target or terminates after the bounded failure limit.

Are repair loops bounded and visible in telemetry?

Yes. Failure keys include route ID, classification, tile, and revision. The failure history is capped by `ROUTE_REPAIR_FAILURE_HISTORY_CAPACITY`, repeated failures stop at `ROUTE_REPAIR_FAILURE_LIMIT`, and metrics include failure count, repair count, expansion count, changed vertices, and full replan count.

## 15. Known Migration Debt

- Door execution still uses the legacy adapter and `toggle_door()` compatibility path. Phase 06 is responsible for replacing this with authoritative smart doors and shared player/NPC interaction.
- `NpcSystem` still owns legacy job movement compatibility and pending door close bookkeeping. Later phases are expected to move those responsibilities into composed services.
- Legacy navigation-world revision still scans scene/block state. Phase 05 forwards change events to repair, but full event-driven topology ownership remains future work under the plan.
- The broad route dictionary shape remains as a compatibility adapter until later phases remove migration debt.

