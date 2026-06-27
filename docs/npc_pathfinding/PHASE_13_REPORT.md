# Phase 13 Report - Legacy Removal, Static Audit, Release Gate, And Acceptance Evidence

## 1. Phase Identification

- Phase: 13 - Legacy Removal, Static Audit, Release Gate, And Acceptance Report
- Branch: `npc-pathfinding/phase-13-finalize`
- Date: 2026-06-27
- Scope status: focused NPC suites, broad playtest, static audit, world signature, and branch all-runner pass on the phase branch; merged `master` all-runner evidence pending.
- Base commit before Phase 13 branch changes: `56119cef054cd444f6e9b87886b66054936785d0`
- Branch implementation/report commit: `4e1d893ec9fd2de7e6dd90461250c2fdd4ce9521`
- Merge commit: pending
- Post-merge `master` evidence commit: pending

## 2. Objective

Phase 13 removes migration debt, proves there is one authoritative NPC autonomy/navigation/movement/door stack, and records acceptance evidence for the replacement stack.

Required scope from the specification:

- remove runtime dual-stack selection and migration-era architecture switches;
- remove legacy `scripts/npc_nav` classes by moving the remaining authoritative implementations under `scripts/npc_ai/`;
- remove `NpcSystem` job movement, random day-target movement, snap fallback movement, door pending-close ownership, and direct route algorithms;
- remove blind door toggle usage and migrate player-facing door use to a desired-state request;
- migrate tests to the phase stack without deleting coverage;
- update architecture and agent documentation;
- run prohibited-shortcut static audits;
- run every focused NPC suite under the required time modes;
- run the branch all-runner, merge to `master`, and rerun the all-runner;
- verify startup, saves, story, visuals, deterministic world signature, and observation evidence.

## 3. Pre-Phase State And Risks

Phase 12 left the branch and `master` green with soak, failure recovery, LOD, save, and observation hardening in place. The remaining Phase 13 risk was not missing behavior, but migration residue:

- old class names could remain as active runtime references;
- `NpcSystem` could still contain direct job-route movement or route mutation fallback behavior;
- blind door toggles could remain reachable by NPCs or player input;
- transient route or traffic state could still leak into saves;
- event-driven topology could be stale in synthetic tests that drive NPC updates without normal physics frames;
- traffic updates could be advanced twice when a test called both the autonomy traffic clock and the public door-policy update;
- report evidence could overstate branch or master status before the required gates actually ran.

The dirty files listed by `git status --short` are the intentional Phase 13 implementation, documentation, and test updates.

## 4. Implementation Summary

Single authoritative stack:

- The remaining route, movement, navigation, and semantic planner implementations were moved out of `scripts/npc_nav/` and into their owned `scripts/npc_ai/` domains:
  - `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`
  - `scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd`
  - `scripts/npc_ai/movement/NpcRouteMovementController.gd`
  - `scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd`
- `NpcNavigationCoordinator.gd` now references the renamed phase stack classes and applies navigation events before route repair decisions.
- `scripts/npc_nav/` has no files and the empty local directory was removed.

`NpcSystem` reduction:

- `update_npc()` now delegates NPC behavior to the autonomy system instead of running direct fallback, wander, or job movement.
- Public NPC traffic, route, and door integration methods remain only as stable adapters to the composed services.
- Job phase execution moved to `NpcPlanExecutor.gd`.
- Door policy updates now advance traffic exactly once when tests call `advance_traffic()` directly before `update_door_policies()`.
- `process_navigation_changes()` is flushed from `update_door_policies()` so tight synthetic loops that do not wait for a physics tick still see event-driven topology changes.

Door and traffic hardening:

- Player door input is routed through `request_player_door_use`; no `toggle_door` or `request_door_toggle` callers remain in production scripts, scenes, tools, or `AGENTS.md`.
- Active door crossings are keyed by portal and actor so one actor cannot overwrite another actor's crossing state.
- Route-generation replacement no longer releases granted active portal crossings before the door release path clears them.
- Stale pending traffic groups are treated as `pending_replan` so a renewed request replans against current blockers.
- Door lookahead and portal crossing duration were tuned to keep door actions intact through approach, crossing, release, and safe close.

Navigation events and generated-world continuity:

- `GeneratedWorldNavigationAdapter.gd` uses event revisions instead of scene-tree hash scans to decide when topology snapshots need to rebuild.
- Dynamic props created through the relevant main/playtest factories now notify the NPC system after insertion.
- The adapter still scans prop/chunk roots when rebuilding the generated-world snapshot for blocker cells. That scan does not determine revision and is not the removed per-frame scene hash path.

Determinism and saves:

- NPC profile timing defaults derive from stable profile/body keys instead of raw runtime randomness.
- `canFight` remains a combat capability, not guard duty.
- Runtime route cells/actions remain transient compatibility diagnostics and are stripped by save snapshot filtering.
- Old-save defaults and new save round-trips remain covered by focused streaming/save tests.

Defects found and fixed during Phase 13:

- A typed GDScript inference issue in the traffic-clock guard failed parser startup. The guard now uses an explicit `bool`.
- Broad playtest exposed double traffic advancement when a manual traffic tick and door-policy tick both ran in the same synthetic loop. `NpcAutonomySystem` now tracks explicit external traffic advancement and `NpcSystem` consumes that marker.
- Broad playtest then exposed stale topology in direct synthetic town loops where new props were created and NPCs were advanced without a physics frame. Prop creation now emits navigation events, and `update_door_policies()` flushes pending navigation changes.
- Two-NPC door crossing diagnostics exposed active crossing overwrite risk. Door traversal active keys now include both portal and actor.
- Traffic diagnostics exposed stale pending group reuse after blocker release. Renewed pending requests now replan against current state.

## 5. Files Added, Changed, And Removed

Documentation:

- `AGENTS.md`
- `docs/npc_pathfinding/ARCHITECTURE.md`
- `docs/npc_pathfinding/PHASE_13_REPORT.md`
- `docs/npc_pathfinding/FINAL_ACCEPTANCE_REPORT.md`

Main integration and playtest harness:

- `scripts/MainInteractionFlow.gd`
- `scripts/MainInterface.gd`
- `scripts/MainPlaytestTools.gd`
- `scripts/MainRuntimeTools.gd`
- `scripts/NpcNavigationTestRunner.gd`
- `scripts/PlaytestRunner.gd`

Public NPC integration:

- `scripts/NpcSystem.gd`

NPC autonomy, behavior, movement, routing, navigation, doors, and traffic:

- `scripts/npc_ai/NpcAgentContext.gd`
- `scripts/npc_ai/NpcAutonomySystem.gd`
- `scripts/npc_ai/NpcConstants.gd`
- `scripts/npc_ai/behavior/GuardRosterService.gd`
- `scripts/npc_ai/behavior/NpcPlanExecutor.gd`
- `scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd`
- `scripts/npc_ai/contracts/TraversalProfile.gd`
- `scripts/npc_ai/interactions/DoorPortalService.gd`
- `scripts/npc_ai/interactions/DoorTraversalExecutor.gd`
- `scripts/npc_ai/interactions/SmartObjectService.gd`
- `scripts/npc_ai/movement/NpcRouteMovementController.gd`
- `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`
- `scripts/npc_ai/routing/HierarchicalRoutePlanner.gd`
- `scripts/npc_ai/routing/NpcNavigationCoordinator.gd`
- `scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd`
- `scripts/npc_ai/traffic/TrafficReservationService.gd`

Focused tests and runner registry:

- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `scripts/testing/npc/NpcBehaviorTestCases.gd`
- `scripts/testing/npc/NpcRouteTestCases.gd`
- `scripts/testing/npc/NpcTrafficTestCases.gd`
- `tools/test-runner-registry.json`

Removed/moved legacy path files:

- `scripts/npc_nav/NpcGoalPlanner.gd` moved to `scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd`
- `scripts/npc_nav/NpcLocomotionController.gd` moved to `scripts/npc_ai/movement/NpcRouteMovementController.gd`
- `scripts/npc_nav/NpcNavigationWorld.gd` moved to `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`
- `scripts/npc_nav/NpcRoutePlanner.gd` moved to `scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd`

## 6. Data/API Contracts Introduced Or Changed

- `NpcConstants.ARCHITECTURE_VERSION` is now `phase13_authoritative_stack`.
- `NpcConstants.NPC_MOVEMENT_STACK` is now `character_body_route_motor`.
- `NpcSystem.request_player_door_use()` is the player-facing desired-state door API.
- `NpcAutonomySystem.advance_traffic(delta, mark_external := true)` records explicit external traffic advancement.
- `NpcAutonomySystem.consume_external_traffic_advance()` lets public door-policy updates avoid double advancement.
- `NpcSystem.notify_navigation_prop_created(prop_id, body)` is called by dynamic prop factories after adding generated props to the scene tree.
- Route/action dictionaries remain runtime diagnostics for public compatibility and test introspection, but save filtering removes transient route, reservation, avoidance, queue, and planner state.

## 7. Migration/Compatibility Behavior

`NpcPathing.gd` remains only as a stable public facade for older callers. It delegates to `NpcNavigationCoordinator.gd` and does not own topology, route search, movement, goals, traffic, or doors.

NPC dictionaries still expose selected route fields because existing HUD/debug/tests inspect them, but they are runtime state. `NpcSystem.create_save_entry()` and `NpcSimulationLodService` filtering exclude transient route cells/actions, reservation IDs, avoidance IDs, planner queues, and debug traces from durable saves.

Old saves with missing fields still load through defaulted profile, home, schedule, and state fields. New saves round-trip durable state only.

## 8. Focused Test Evidence

Post-event focused NPC reports:

| Command | Report | Results | Failures | Duration |
| --- | --- | ---: | ---: | ---: |
| `.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-contract-both-post-event.json` | `artifacts/npc/reports/phase13-contract-both-post-event.json` | 40 | 0 | 0.097s |
| `.\tools\npc\run-npc-motor-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-motor-both-post-event.json` | `artifacts/npc/reports/phase13-motor-both-post-event.json` | 36 | 0 | 0.046s |
| `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-nav-world-both-post-event.json` | `artifacts/npc/reports/phase13-nav-world-both-post-event.json` | 38 | 0 | 0.058s |
| `.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-route-both-post-event.json` | `artifacts/npc/reports/phase13-route-both-post-event.json` | 38 | 0 | 0.565s |
| `.\tools\npc\run-npc-repair-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-repair-both-post-event.json` | `artifacts/npc/reports/phase13-repair-both-post-event.json` | 32 | 0 | 0.179s |
| `.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-door-both-post-event.json` | `artifacts/npc/reports/phase13-door-both-post-event.json` | 42 | 0 | 0.081s |
| `.\tools\npc\run-npc-avoidance-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-avoidance-both-post-event.json` | `artifacts/npc/reports/phase13-avoidance-both-post-event.json` | 30 | 0 | 0.072s |
| `.\tools\npc\run-npc-traffic-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-traffic-both-post-event.json` | `artifacts/npc/reports/phase13-traffic-both-post-event.json` | 38 | 0 | 0.109s |
| `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-behavior-both-post-event.json` | `artifacts/npc/reports/phase13-behavior-both-post-event.json` | 22 | 0 | 0.065s |
| `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Transition -ReportPath artifacts\npc\reports\phase13-behavior-transition-post-event.json` | `artifacts/npc/reports/phase13-behavior-transition-post-event.json` | 2 | 0 | 0.030s |
| `.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-interaction-both-post-event.json` | `artifacts/npc/reports/phase13-interaction-both-post-event.json` | 20 | 0 | 0.041s |
| `.\tools\npc\run-npc-streaming-save-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-streaming-save-both-post-event.json` | `artifacts/npc/reports/phase13-streaming-save-both-post-event.json` | 38 | 0 | 0.095s |
| `.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-soak-both-post-event.json` | `artifacts/npc/reports/phase13-soak-both-post-event.json` | 26 | 0 | 0.969s |
| `.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Transition -ReportPath artifacts\npc\reports\phase13-soak-transition-post-event.json` | `artifacts/npc/reports/phase13-soak-transition-post-event.json` | 2 | 0 | 0.201s |
| `.\tools\npc\run-npc-observation-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-observation-both-post-event.json` | `artifacts/npc/reports/phase13-observation-both-post-event.json` | 7 | 0 | 0.000s |
| `.\tools\run-npc-navigation-tests.ps1 -ReportPath artifacts\npc\reports\phase13-npc-navigation-post-event.json` | `artifacts/npc/reports/phase13-npc-navigation-post-event.json` | 11 | 0 | runner schema omits duration |

Broad playtest evidence:

- Command: `.\tools\run-playtest.ps1 -ReportPath artifacts\npc\reports\phase13-playtest-after-event-flush.json -Seed atlas-1492 -TimeoutSeconds 900 -StaleProgressSeconds 120`
- Report: `artifacts/npc/reports/phase13-playtest-after-event-flush.json`
- Result count: 181
- Failure count: 0
- Wall duration observed by wrapper: approximately 555 seconds
- Relevant rows: `generic_npc_job_outings`, `forager_goal_inventory_hunger`, and `right_mouse_interaction_input` pass after the traffic clock and event flush fixes.

## 9. Day/Night Evidence

Focused observation:

- Command: `.\tools\npc\run-npc-observation-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-observation-both-post-event.json`
- Report: `artifacts/npc/reports/phase13-observation-both-post-event.json`
- Result count: 7
- Failure count: 0
- Covered scenarios: noon work, dusk return-home, midnight guard/interior behavior, dawn transition, crowded door traffic, player/NPC door sharing, and dynamic block repair.

Behavior schedule evidence:

- Command: `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase13-behavior-both-post-event.json`
- Command: `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Transition -ReportPath artifacts\npc\reports\phase13-behavior-transition-post-event.json`
- Reports: `phase13-behavior-both-post-event.json` and `phase13-behavior-transition-post-event.json`
- Combined result count: 24
- Combined failure count: 0

Visible execution was not used in this pass. Headless observation artifacts and JSON traces were inspected through the focused observation report.

## 10. Full All-Runner Evidence On Phase Branch

Command:

```powershell
.\tools\run-all-test-runners.ps1 -ReportPath artifacts\test-runners\phase13-branch-all-test-runners-report.json -Seed atlas-1492
```

Report: `artifacts/test-runners/phase13-branch-all-test-runners-report.json`

Branch HEAD during run: `4e1d893ec9fd2de7e6dd90461250c2fdd4ce9521`

Aggregate result: 10 runner entries, 0 failures, 861.809 seconds, exit code 0.

| Runner | Exit | Passed | Duration |
| --- | ---: | --- | ---: |
| `npc_focused` | 0 | true | 26.413s |
| `npc_observation_dusk` | 0 | true | 0.668s |
| `npc_observation_midnight` | 0 | true | 0.659s |
| `npc_observation_phase12` | 0 | true | 1.281s |
| `world_signature` | 0 | true | 16.944s |
| `visual_manifest` | 0 | true | 0.090s |
| `npc_navigation_integration` | 0 | true | 122.272s |
| `story_playtest` | 0 | true | 77.031s |
| `visual_captures` | 0 | true | 71.934s |
| `playtest` | 0 | true | 544.380s |

## 11. Full All-Runner Evidence On Merged Master

Pending. Required after merge:

```powershell
.\tools\run-all-test-runners.ps1 -ReportPath artifacts\test-runners\phase13-master-all-test-runners-report.json -Seed atlas-1492
```

## 12. Performance And Boundedness Metrics

Focused performance and boundedness evidence:

- `phase13-soak-both-post-event.json`: 26 results, 0 failures, 0.969s.
- `phase13-soak-transition-post-event.json`: 2 results, 0 failures, 0.201s.
- `phase13-traffic-both-post-event.json`: 38 results, 0 failures, 0.109s.
- `phase13-avoidance-both-post-event.json`: 30 results, 0 failures, 0.072s.
- Observation suite includes 32-agent and 64-agent evidence inherited from Phase 12 cases and still passing under the Phase 13 stack.
- Bounded traces/queues remain covered by contract, traffic, soak, streaming/save, and lifecycle cleanup assertions.

## 13. Determinism And World-Signature Evidence

Command:

```powershell
.\tools\run-world-signature.ps1
```

Result:

- Output: `World signature matches baseline: artifacts\baselines\world-signature\atlas-1492.json`
- Tracked baseline hash: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`
- Generated latest hash: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`
- Generated latest path: `artifacts/world-signature/latest/atlas-1492.json`
- `git diff -- artifacts/baselines/world-signature/atlas-1492.json`: no diff

The tracked world-signature baseline remains tracked and unchanged.

## 14. Invariant Checklist

| Gate | Status | Evidence |
| --- | --- | --- |
| Exactly one authoritative NPC autonomy/navigation/movement/door stack remains | Pass | Legacy files moved into `scripts/npc_ai/`; production legacy reference search has zero matches. |
| No prohibited legacy behavior remains | Pass | Static audit section below; allowed matches are rationale-listed. |
| Every focused case passes in required modes/seeds | Pass | Focused test table in Section 8. |
| All-runner gate passes on branch | Pass | `phase13-branch-all-test-runners-report.json`, 10 runner entries, 0 failures, 861.809s. |
| All-runner gate passes on merged `master` | Pending | Section 11 command pending. |
| Observation evidence matches assertions | Pass for headless evidence | `phase13-observation-both-post-event.json`, 7 results, 0 failures. |
| Acceptance report has no failed mandatory row | Pending | Merged `master` all-runner row pending in `FINAL_ACCEPTANCE_REPORT.md`. |
| Repository starts with no missing script references | Pass on branch | Branch all-runner startup, focused parser startup, story script load, and broad playtest pass. |
| Save, story, visual, and deterministic world continuity green | Pass on branch, master pending | Save focused suite, story playtest, visual captures/manifest, broad playtest, and world signature pass on branch. |

## 15. Deviation Register

None approved or requested. Pending branch/master gates are not treated as debt; they remain required before merge acceptance.

## 16. Known Issues/Debt

No known issue is being carried as a Phase 13 gate exception. The only pending items are the required merged `master` all-runner gate and the report hash updates after that gate.

## 17. Static Audit Results

Production legacy/preload search:

```powershell
rg -n "legacy|scripts/npc_nav|NpcNavigationWorld|NpcRoutePlanner|NpcLocomotionController|NpcGoalPlanner|from_legacy_profile|update_legacy_npc|migrate_legacy_duty|LEGACY_LOCOMOTION_MODE|wanderTimer|update_wander_target|npc_navigation_legacy|MAX_ITERATIONS" scripts\NpcSystem.gd scripts\npc_ai scenes tools AGENTS.md
```

Result: exit 1, no production matches.

Door toggle search:

```powershell
rg -n "toggle_door|request_door_toggle" scripts scenes tools AGENTS.md docs/npc_pathfinding/ARCHITECTURE.md
```

Result: exit 1, no matches.

Old scene-scan/hash navigation revision search:

```powershell
rg -n "navigation.*hash|hash.*navigation|revision.*hash|hash.*revision|revision.*get_children|get_children.*revision|scan.*revision|revision.*scan|scene.*revision|revision.*scene" scripts\NpcSystem.gd scripts\npc_ai
```

Result: exit 1, no matches.

Unsafe timeout close search:

```powershell
rg -n "timeout|timer|force.*close|close.*force|occupancy.*timeout|expired" scripts\npc_ai\interactions scripts\NpcSystem.gd
```

Result: one unrelated `jobTimer` default in `NpcSystem.gd`; no door timeout safety bypass.

Legacy path directory check:

```powershell
Test-Path -LiteralPath scripts\npc_nav; rg --files scripts\npc_nav 2>$null
```

Result: `False`; no files.

Allowed transform/placement matches:

- `NpcSafePlacementService.gd` writes `global_position`/`position` only for spawn, promotion, and load-restore placement after capsule validation.
- `NpcRouteMovementController.gd` and `NpcSafePlacementService.gd` write `query.transform` for physics shape queries only.
- `CharacterMotor3D.gd` and route/interaction services read body positions for state, progress, and queries; they do not assign normal route transforms.

Allowed lifecycle collision-mask matches:

- `NpcSimulationLodService.gd` sets collision layer/mask to `0` only during abstract LOD demotion after `can_demote()` succeeds, then restores saved masks on safe promotion.

Allowed runtime route-state matches:

- `routeCells` and `routeActions` remain transient runtime diagnostics and route execution state.
- `NpcSystem.create_save_entry()` strips `routeCells`, `routeActions`, `pathWaypoints`, active door metadata, and `trafficWaitReason`.
- `NpcSimulationLodService` strips route cells/actions, reservations, avoidance IDs, planner queues, and debug traces from abstract/lifecycle save-facing data.

Allowed scene-tree scans:

- `NpcSystem` has bounded forage/job resource target scans for smart-object candidate discovery, not navigation revision.
- `GeneratedWorldNavigationAdapter.gd` scans prop/chunk roots while rebuilding a generated-world snapshot, not to infer revision each frame.

Allowed deterministic random matches:

- `NpcSemanticGoalPlanner.gd` uses per-NPC deterministic RNG streams for semantic fallback target candidates.
- `NpcSystem.deterministic_profile_float()` uses a stable hash for deterministic profile timers.

Allowed `canFight` matches:

- `canFight` is used as a combat/threat capability in context, perception, and goal selection.
- Guard duty is assigned separately by guard roster/schedule state and is not inferred from `canFight`.

## 18. Risk Assessment For Next Phase

There is no next NPC pathfinding phase in this plan. After the pending branch/master gates pass, future NPC movement features should extend typed traversal actions, smart objects, semantic goals, traffic reservations, and door portals rather than adding direct movement loops or new `Main*.gd` layers.

## 19. Verdict

Focused and branch all-runner Phase 13 evidence pass on the phase branch. Merge is allowed to proceed, but Phase 13 acceptance remains pending until merged `master` passes the required all-runner gate and the report is updated with that evidence.
