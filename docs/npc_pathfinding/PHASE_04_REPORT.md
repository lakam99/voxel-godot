# Phase 04 Report - Hierarchical Route Planner, Semantic Costs, and Corridor Generation

## 1. Phase Identification

- Phase: 04 - Hierarchical Route Planner, Semantic Costs, and Corridor Generation
- Branch: `npc-pathfinding/phase-04-hierarchical-routing`
- Base commit before Phase 04 branch changes: `0e4ea8ebef14e9395b3ee61956835b6caecbcf95`
- Branch implementation commit: `142c6c797c3364adc0b162a4f4ae53c7572aa501`
- Merge commit: `2dd99e1383402cdce80f337860e28ea5ac8a64c0`
- Date: 2026-06-25
- Controlling specification: `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`
- Scope status: branch implementation gates passed; merged `master` gate passed after the non-fast-forward merge.

## 2. Objective

Phase 04 replaces the bounded flat-grid route search with deterministic hierarchical, profile-aware route planning and explicit traversal corridors. The new planner must expose abstract/local route structure, semantic costs, capsule-safe corridors, action-preserving smoothing, route terminal reasons, and a compatibility path for legacy high-level goals.

## 3. Pre-Phase State

- `git status --short` before Phase 04 work showed one pre-existing modified tracked baseline: `artifacts/baselines/world-signature/atlas-1492.json`.
- That baseline artifact remained outside the Phase 04 staged scope.
- Phase 03 had introduced `NavigationWorldService`, multi-surface spans, semantic regions, dirty tile invalidation, and new nav-world focused tests.
- The production route path still used `scripts/npc_nav/NpcRoutePlanner.gd` as a bounded compatibility A* adapter.
- Legacy door execution and legacy scene-scan revision code were still present as documented migration debt.

## 4. Implementation Summary

Phase 04 adds a composed route layer under `scripts/npc_ai/routing/` and keeps `NpcPathing.gd` as a compatibility facade.

`HierarchicalRoutePlanner` now owns route formation. It resolves start and goal spans, builds deterministic tile hierarchy data from graph spans and cross-tile/portal edges, caches local entrance costs by tile/profile key, and uses a budget-sliced local A* job for refinement. Long compatibility routes no longer use the old small iteration cutoff.

`LocalAStarPlanner` stores open/closed/came-from state on resumable jobs. A budget slice returns `pending_budget`; exhausted open sets return an explicit unreachable result or an explicit partial result only when the request allows partial routes.

`RouteCostModel` centralizes route cost. Each traversed edge records base, hazard, semantic, door, and bottleneck components. Route results carry cost breakdowns and tile/edge/portal/semantic dependencies.

`RouteCorridorBuilder` converts span paths into `RouteCorridor`, `RouteStep`, and `TraversalAction` contracts. It preserves required actions, marks bottleneck/reservation metadata, and applies deterministic smoothing only when mandatory action points remain intact.

`TraversalCapabilityService` applies profile ability checks for walk, step, drop, door, and special traversal kinds. Large/narrow profile tests now prove feasibility differs by capability and clearance.

`RouteRequestQueue` is deterministic and bounded. It orders by priority then sequence, exposes capacity metrics, and evicts lowest-priority newest pending requests if the queue exceeds its named limit. The planner also caps active jobs and local-cost cache entries through named Phase 04 constants.

`NpcRoutePlanner.gd` remains as a compatibility adapter, but delegates route planning and route-cost scoring to `HierarchicalRoutePlanner`. `NpcPathing.gd` constructs a `NpcNavigationCoordinator` and delegates movement, route, locomotion, and goal compatibility services; it no longer owns movement or topology algorithms.

Production movement still consumes the legacy route dictionary shape, but that dictionary now comes from the new corridor path. The Phase 02 motor remains the physical movement authority.

Door traversal is represented as placeholder traversal actions in route corridors. Detailed door execution remains in the legacy door adapter until Phase 06, as allowed by the Phase 04 specification.

## 5. Files Added, Changed, And Removed

Added route contracts:

- `scripts/npc_ai/contracts/TraversalAction.gd`
- `scripts/npc_ai/contracts/RouteStep.gd`
- `scripts/npc_ai/contracts/RouteCorridor.gd`

Added route services:

- `scripts/npc_ai/routing/TraversalCapabilityService.gd`
- `scripts/npc_ai/routing/RouteCostModel.gd`
- `scripts/npc_ai/routing/RouteRequestQueue.gd`
- `scripts/npc_ai/routing/LocalAStarPlanner.gd`
- `scripts/npc_ai/routing/RouteCorridorBuilder.gd`
- `scripts/npc_ai/routing/HierarchicalRoutePlanner.gd`
- `scripts/npc_ai/routing/NpcNavigationCoordinator.gd`

Changed route integration:

- `scripts/NpcPathing.gd`
- `scripts/NpcSystem.gd`
- `scripts/npc_nav/NpcRoutePlanner.gd`
- `scripts/npc_nav/NpcGoalPlanner.gd`
- `scripts/npc_nav/NpcLocomotionController.gd`
- `scripts/NpcNavigationTestRunner.gd`

Changed shared route constants/enums:

- `scripts/npc_ai/NpcConstants.gd`
- `scripts/npc_ai/NpcEnums.gd`
- `scripts/npc_ai/navigation/NavigationTileBuilder.gd`

Added route tests and runner:

- `scripts/testing/npc/NpcRouteTestCases.gd`
- `tools/npc/run-npc-route-tests.ps1`

Changed test integration:

- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`

Removed files: none.

## 6. Data And API Contracts

`TraversalAction` stores mandatory action metadata: action ID, kind, portal ID, source/target spans, cost, required capabilities, reservation requirement, and action-specific metadata.

`RouteStep` stores one corridor step: source/target spans, cell, world position, traversal kind, cost breakdown, semantic regions, portal/action IDs, bottleneck flag, and reservation requirement.

`RouteCorridor` stores ordered steps/actions, waypoints, dependencies, total cost, smoothing state, and arrival contract.

`RouteRequestQueue` stores pending requests keyed by request ID. New bounds are:

- `ROUTE_REQUEST_QUEUE_CAPACITY = 256`
- `ROUTE_COMPLETED_RESULT_CAPACITY = 512`
- `ROUTE_ACTIVE_JOB_CAPACITY = 256`
- `ROUTE_LOCAL_COST_CACHE_CAPACITY = 2048`

`HierarchicalRoutePlanner.plan_route()` returns typed route results from the new contracts. `plan_legacy_route()` and `route_cost_for_legacy()` are temporary adapters for existing goal selection and diagnostics.

New route reasons include `pending_budget`, `no_start_span`, `no_goal_span`, `locked_or_unauthorized`, and `queue_capacity`.

## 7. Migration And Compatibility Behavior

Existing high-level goal selection remains legacy during Phase 04, but active route generation now flows through the new planner/coordinator path.

The compatibility route dictionary still exposes legacy fields such as `cells`, `status`, `reason`, `index`, and route metadata so existing diagnostics and tests can continue to run. The typed route result is also recorded on NPC blackboard/metadata for inspection.

`NpcPathing.gd` remains the stable public facade for callers. Ownership of route planning, route cost, locomotion adapter construction, and goal adapter construction moved into `NpcNavigationCoordinator`.

Door execution remains in legacy adapter code. Closed-but-openable doors are represented as route-feasible placeholder actions; locked or unauthorized doors are route-infeasible unless an alternate is available.

## 8. Focused Test Evidence

Focused and compatibility gates run on branch `npc-pathfinding/phase-04-hierarchical-routing`:

| Command | Result | Evidence |
| --- | --- | --- |
| `.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\route-both.json`; 38 results, 0 failures, 70 assertions, 0.598s |
| `.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\all-npc-both.json`; 4 suites, 0 failures, 6.427s |
| `.\tools\run-npc-navigation-tests.ps1` | Pass | `artifacts\test-runners\npc-navigation-report.json`; 11 results, 0 failures |
| `.\tools\run-playtest.ps1` through all-runner | Pass | `artifacts\test-runners\playtest-report.json`; 181 results, 0 failures |

Required Phase 04 route IDs covered:

- `npc_route_same_tile_optimal_oracle`
- `npc_route_multi_tile_hierarchy`
- `npc_route_cross_loaded_chunks`
- `npc_route_road_preferred_equal_time`
- `npc_route_hazard_avoided_by_civilian`
- `npc_route_guard_semantic_preference`
- `npc_route_profile_large_rejects_narrow_small_accepts`
- `npc_route_closed_openable_door_action`
- `npc_route_locked_unauthorized_alternate`
- `npc_route_start_snap_no_wall_cross`
- `npc_route_goal_snap_correct_vertical_layer`
- `npc_route_corner_smoothing_capsule_safe`
- `npc_route_mandatory_action_not_smoothed_out`
- `npc_route_no_iteration_cap_false_failure`
- `npc_route_pending_budget_resumes`
- `npc_route_partial_explicit_only`
- `npc_route_unreachable_terminal_reason`
- `npc_route_deterministic_replay`
- `npc_route_legacy_goal_adapter_uses_new_corridor`

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

`route-both.json` ran every required route case once at canonical day and once at canonical night:

- Day snapshot: `time_of_day = 0.25`, display hour `12:00`.
- Night snapshot: `time_of_day = 0.75`, display hour `00:00`.
- Total route matrix: 19 case IDs x 2 time modes = 38 results, 0 failures.

Representative route evidence:

- Multi-tile hierarchy: hierarchy had two cross-tile entrances, two tile edges, and path dependencies across `0,0` and `1,0`.
- Cross-loaded chunks: route dependencies spanned three tiles.
- Road preference: equal-time alternatives preferred road semantics through deterministic semantic cost.
- Civilian hazard avoidance: civilian profile selected a safer route because hazard cost was nonnegative and explainable.
- Guard semantic preference: guard profile preferred guard semantics where cost profiles made that route appropriate.
- Narrow profile test: large profile rejected the narrow route while small profile accepted it.
- Door action test: openable closed door route retained a mandatory door action and reservation metadata.
- Locked unauthorized door test: planner selected alternate route or terminal reason rather than treating the door as open.
- Snap tests: start and goal resolution did not cross walls or vertical layers.
- Smoothing tests: capsule-safe smoothing preserved mandatory action edges.
- Budget test: route search resumed from `pending_budget` instead of reporting unreachable.
- Determinism test: repeated route requests produced identical path/cost output.

Broad playtest continuity evidence from `artifacts\test-runners\playtest-report.json`:

- `tutorial_elder_returns_home`: pass; Mira reached an inside-accepted home state through the compatibility route fallback.
- `tutorial_final_rescue_mission`: pass; guard movement, rescue state, and rescue objective flow remained valid.
- `tutorial_npc_home_and_guard_behavior`: pass; 6 NPCs homed, 3 sheltered, 3 fighters armed, guard shots advanced, and no blocked moves were reported.

## 10. Full All-Runner Evidence On Phase Branch

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Report: `artifacts\test-runners\all-test-runners-report.json`

Result: pass, 7 runners, 0 failures, 932.081s, finished `2026-06-25T22:28:35.6815840Z`.

| Runner | Exit | Result | Duration | Fresh report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | Pass | 6.762s | yes |
| `npc_navigation_legacy` | 0 | Pass | 107.372s | yes |
| `playtest` | 0 | Pass | 661.107s | yes |
| `story_playtest` | 0 | Pass | 70.344s | yes |
| `world_signature` | 0 | Pass | 16.143s | yes |
| `visual_captures` | 0 | Pass | 70.200s | yes |
| `visual_manifest` | 0 | Pass | 0.105s | yes |

Runner registry used: `tools\test-runner-registry.json`.

## 11. Full All-Runner Evidence On Merged Master

Merge commit: `2dd99e1383402cdce80f337860e28ea5ac8a64c0`

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Report: `artifacts\test-runners\all-test-runners-report.json`

Result: pass, 7 runners, 0 failures, 1087.229s, finished `2026-06-25T22:49:16.6092219Z`.

| Runner | Exit | Result | Duration | Fresh report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | Pass | 6.458s | yes |
| `npc_navigation_legacy` | 0 | Pass | 106.353s | yes |
| `playtest` | 0 | Pass | 791.699s | yes |
| `story_playtest` | 0 | Pass | 92.596s | yes |
| `world_signature` | 0 | Pass | 20.056s | yes |
| `visual_captures` | 0 | Pass | 69.912s | yes |
| `visual_manifest` | 0 | Pass | 0.101s | yes |

## 12. Performance And Boundedness Metrics

Focused route suite: 38 route runs, 70 assertions, 0.598s.

NPC aggregate suite: 4 suites, 0 failures, 6.427s.

Repository all-runner branch gate: 7 runners, 0 failures, 932.081s.

Named route bounds:

- Per-tick route search budget: `ROUTE_SEARCH_MAX_EXPANSIONS_PER_TICK = 128`.
- Compatibility route expansion allowance: `ROUTE_SEARCH_COMPATIBILITY_EXPANSIONS = 200000`, replacing the old small false-failure cap.
- Route request queue capacity: `ROUTE_REQUEST_QUEUE_CAPACITY = 256`.
- Completed/cancelled route history capacity: `ROUTE_COMPLETED_RESULT_CAPACITY = 512`.
- Active route job capacity: `ROUTE_ACTIVE_JOB_CAPACITY = 256`.
- Local route cost cache capacity: `ROUTE_LOCAL_COST_CACHE_CAPACITY = 2048`.

## 13. Determinism And World Signature Evidence

- Route determinism is covered by `npc_route_deterministic_replay` in day and night.
- All route cases use deterministic tie-breaking and sorted tile/goal dependency lists.
- `.\tools\run-world-signature.ps1` through the all-runner passed and matched `artifacts\baselines\world-signature\atlas-1492.json`.
- The pre-existing dirty baseline file `artifacts/baselines/world-signature/atlas-1492.json` was not changed by this phase branch scope.

## 14. Invariant Checklist

| Phase 04 gate | Status | Evidence |
| --- | --- | --- |
| All production NPC routes use the new hierarchical planner/corridor path while high-level goals remain legacy | Pass | `NpcPathing.gd` delegates through `NpcNavigationCoordinator`; `NpcRoutePlanner.gd` delegates to `HierarchicalRoutePlanner`; `npc_route_legacy_goal_adapter_uses_new_corridor` passed day/night |
| Long solvable routes no longer fail from a small iteration cap | Pass | `MAX_ITERATIONS` static search had zero matches; `npc_route_no_iteration_cap_false_failure` passed day/night |
| Profile capability and vertical surface identity affect route feasibility | Pass | `npc_route_profile_large_rejects_narrow_small_accepts` and `npc_route_goal_snap_correct_vertical_layer` passed day/night |
| Route smoothing is capsule-valid and preserves actions | Pass | `npc_route_corner_smoothing_capsule_safe` and `npc_route_mandatory_action_not_smoothed_out` passed day/night |
| Semantic cost choices are deterministic and explainable | Pass | `RouteCostModel` cost breakdowns plus road/hazard/guard tests passed day/night |
| Route statuses and terminal reasons satisfy the contract | Pass | `npc_contract_route_status_terminal`, `npc_route_pending_budget_resumes`, `npc_route_partial_explicit_only`, and `npc_route_unreachable_terminal_reason` passed |
| Existing focused NPC scenarios and broad playtest remain green | Pass | `run-all-npc-tests`, `run-npc-navigation-tests`, and all-runner `playtest` passed |
| Full all-runner gate passes on branch and `master` | Pass | Branch all-runner passed 7/7; merged `master` all-runner passed 7/7 at merge commit `2dd99e1383402cdce80f337860e28ea5ac8a64c0` |

## 15. Deviation Register

No unapproved Phase 04 implementation deviation is recorded.

## 16. Known Issues And Debt

- Legacy door execution remains in `NpcSystem.gd` and `MainRuntimeTools.gd` until Phase 06. Static audit still finds `toggle_door`, `pending_door_closes`, and `timed_out`; this is allowed Phase 04 compatibility debt, not new route ownership.
- Legacy `NpcNavigationWorld.gd` still computes a scene/block hash revision. Phase 04 does not add new scene scanning; removal is Phase 13 debt.
- Legacy forager runner passes, but its diagnostic still shows `route blocked/no_goal_span` during return behavior. Behavior/home semantics are Phase 08/09 work.
- Tutorial home behavior still accepts `partial/home_porch_fallback` in compatibility paths. The plan's stricter interior-only night-home contract belongs to later behavior/legacy-removal phases.
- A bare headless startup check prints an existing ObjectDB leak warning at exit. No parser error remains after the boundedness patch.

## 17. Static Audit Results

Commands run from the project root:

```powershell
rg -n "MAX_ITERATIONS|for iteration in range\(" scripts\npc_nav scripts\npc_ai\routing scripts\NpcPathing.gd scripts\NpcSystem.gd
```

Result: zero matches.

```powershell
rg -n "ROUTE_REQUEST_QUEUE_CAPACITY|ROUTE_COMPLETED_RESULT_CAPACITY|ROUTE_ACTIVE_JOB_CAPACITY|ROUTE_LOCAL_COST_CACHE_CAPACITY|pendingCapacity|completedCapacity" scripts\npc_ai
```

Result: named route bounds found in `NpcConstants.gd`, `RouteRequestQueue.gd`, and `HierarchicalRoutePlanner.gd`.

```powershell
rg -n "global_position\s*=|position\s*=|transform\s*=|global_transform\s*=" scripts\npc_nav scripts\npc_ai scripts\NpcPathing.gd scripts\NpcSystem.gd
```

Result: no normal route movement transform write found. Matches are state reads/data assignment or physics query transforms, except `NpcSafePlacementService.gd:25`, which is the named safe-placement API for spawn/load/promotion placement.

```powershell
rg -n "toggle_door|pending_door_closes|timed_out" scripts\NpcSystem.gd scripts\MainRuntimeTools.gd scripts\npc_ai scripts\npc_nav
```

Result: expected legacy door adapter matches in `NpcSystem.gd` and `MainRuntimeTools.gd`; execution replacement is Phase 06.

## 18. Risk Assessment For Next Phase

Phase 05 incremental route repair should build on the route dependency data already recorded in corridors. Primary risks:

- Legacy route adapter paths still produce coarse generated-world graphs for active NPCs.
- Door and bottleneck actions are placeholders until Phase 06 and Phase 08.
- Dynamic block changes currently invalidate through compatibility behavior; Phase 05 must prove targeted segment repair against a fresh-route oracle.
- Home/forager compatibility fallbacks may hide behavior problems that later phases must make explicit.

## 19. Verdict

Branch and merged-`master` gates passed. Phase 05 may start only from the updated green `master`.
