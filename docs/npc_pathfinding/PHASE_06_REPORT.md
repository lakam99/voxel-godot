# Phase 06 Report - Authoritative Smart Doors and Shared Player/NPC Interaction

## 1. Phase Identification

- Phase: 06 - Authoritative Smart Doors and Shared Player/NPC Interaction
- Branch: `npc-pathfinding/phase-06-smart-doors`
- Base commit before Phase 06 branch changes: `17a7eafc4a1a5b952ccf27d75e6c91c15b56a864`
- Branch code commit: pending at branch-report authoring time
- Merge commit: pending at branch-report authoring time
- Date: 2026-06-26
- Controlling specification: `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`
- Scope status: branch gates passed; merged `master` gate pending until the required non-fast-forward merge and rerun.

## 2. Objective

Phase 06 replaces blind door toggles and timer-owned close behavior with a shared smart-object authority. Player and NPC door requests now resolve through logical portals, controller-owned collider state, explicit interaction requests, access policy, safe holds, queue inheritance, traversal execution, and save restoration for durable door facts.

## 3. Pre-Phase State

- `git status --short` before Phase 06 work showed one pre-existing modified tracked baseline: `artifacts/baselines/world-signature/atlas-1492.json`.
- That baseline artifact remained outside the Phase 06 staged scope.
- Phase 05 had tightened legacy door repair behavior, but door ownership still passed through compatibility helpers, pending close bookkeeping, and `toggle_door()` call paths.
- The branch started from green `master` commit `17a7eafc4a1a5b952ccf27d75e6c91c15b56a864`.

## 4. Implementation Summary

`SmartObjectService` now owns smart-object registrations and dispatches typed `InteractionRequest` contracts. Doors register through `SmartObjectRegistration`, which binds a stable object ID, interaction kind, node, controller, portal ID, group ID, and metadata.

`DoorPortalService` owns logical door portals. It resolves generated and player-placed door nodes into deterministic portal IDs, groups double leaves under one portal, registers controllers, records approach/threshold/sweep/clearance geometry, tracks state/access revisions, and provides desired-state requests for open, close, hold, release, lock, unlock, jam, destroy, repair, and cancel semantics.

`DoorController` is the only Phase 06 path that changes door collider disabled state. It applies idempotent state requests, coordinates leaf animation/collider state, blocks close while threshold/sweep/clearance volumes or active reservations/holds are occupied, reopens on closing obstruction, and records trace data for debug and tests.

`DoorAccessPolicy` centralizes access and hold policy. It covers public/private doors, night exterior behavior, explicit guard exit and resident traffic, follower inheritance windows, bulky holds, locked/unauthorized decisions, jammed/destroyed/missing outcomes, and no-timeout close safety.

`DoorTraversalExecutor` turns route traversal actions into an ordered execution path: reserve approach, request open, wait for traversable, reserve threshold, cross, verify capsule clearance, release/transfer hold, and request close by policy. NPC route dictionaries still exist for migration, but door traversal now calls the executor and controller path rather than a blind toggle.

`MainRuntimeTools.toggle_door()` remains only as a deprecated compatibility adapter for the player-facing interaction surface. It resolves the door controller/portal and requests the desired logical state. `NpcSystem` no longer has a production `toggle_door` call path, pending door-close timer ownership, or `open_door_for_npc()` ownership.

Door state/access revisions now flow into route feasibility and route repair. Locked, jammed, destroyed, missing, and unloaded states produce deterministic interaction or route outcomes instead of silent inversion or delayed timeout behavior.

Save restoration remains additive. Durable door open/locked/jammed/destroyed facts restore through the portal/controller service; transient holds, queues, reservations, and traversal executor state are not persisted.

## 5. Files Added, Changed, And Removed

Added interaction contracts and services:

- `scripts/npc_ai/contracts/InteractionRequest.gd`
- `scripts/npc_ai/interactions/SmartObjectRegistration.gd`
- `scripts/npc_ai/interactions/SmartObjectService.gd`
- `scripts/npc_ai/interactions/DoorPortal.gd`
- `scripts/npc_ai/interactions/DoorPortalService.gd`
- `scripts/npc_ai/interactions/DoorController.gd`
- `scripts/npc_ai/interactions/DoorAccessPolicy.gd`
- `scripts/npc_ai/interactions/DoorTraversalExecutor.gd`

Added door tests and runner:

- `scripts/testing/npc/NpcDoorTestCases.gd`
- `tools/npc/run-npc-door-tests.ps1`

Changed integration:

- `scripts/MainChunkTerrain.gd`
- `scripts/MainInterface.gd`
- `scripts/MainRuntimeTools.gd`
- `scripts/MainSaveState.gd`
- `scripts/NpcNavigationTestRunner.gd`
- `scripts/NpcSystem.gd`
- `scripts/StructureSystem.gd`
- `scripts/npc_ai/NpcAutonomySystem.gd`
- `scripts/npc_ai/routing/HierarchicalRoutePlanner.gd`
- `scripts/npc_nav/NpcLocomotionController.gd`

Changed shared constants/enums/contracts:

- `scripts/npc_ai/NpcConstants.gd`
- `scripts/npc_ai/NpcEnums.gd`
- `scripts/npc_ai/contracts/InteractionResult.gd`

Changed test registry:

- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`

Removed files: none.

## 6. Data And API Contracts

New interaction request types include desired door state, hold, release, cancel, lock, unlock, jam, destroy, repair, and smart-object dispatch fields.

New door states and outcomes distinguish closed, opening, open, closing, locked, jammed, destroyed, missing, blocked, denied, queued, traversable, and cancelled outcomes.

Door portal metadata includes stable portal/group IDs, leaf index, side/orientation, building/interior association, approach/staging points, threshold extents, sweep radius, clearance radius, policy kind, and revision counters.

Door debug traces include actor ID, request type, desired state, result, portal ID, controller path, active holders, queued actors, occupancy checks, and close-denial reasons.

## 7. Door Behavior

Single-leaf doors expose one logical portal and one controller. Double-leaf doors expose one logical portal with coordinated controllers, shared occupancy checks, and shared close policy.

Open and close requests are idempotent. A repeated open request does not invert the state, and a repeated close request does not reopen the door.

Close requests are rejected while any threshold, sweep, clearance, active holder, active threshold reservation, or queued inherited actor blocks closure. No elapsed-time path can override those checks.

NPC traversal uses explicit holds and releases. Plain player/NPC desired-state open requests no longer create persistent actor holds, which preserves compatibility with player toggle smoke coverage while keeping traversal holds explicit.

Access failures are structured. Locked unauthorized doors, jammed doors, destroyed doors, and missing/unloaded portals return deterministic outcomes that route/action layers can treat as alternate-route or terminal interaction facts.

## 8. Focused Test Evidence

Focused and compatibility gates run on branch `npc-pathfinding/phase-06-smart-doors`:

| Command | Result | Evidence |
| --- | --- | --- |
| `.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\contract-both.json`; 40 results, 0 failures, 110 assertions, 0.076s |
| `.\tools\npc\run-npc-motor-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\motor-both.json`; 36 results, 0 failures, 88 assertions, 0.042s |
| `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\nav_world-both.json`; 38 results, 0 failures, 70 assertions, 0.042s |
| `.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\route-both.json`; 38 results, 0 failures, 70 assertions, 0.563s |
| `.\tools\npc\run-npc-repair-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\repair-both.json`; 32 results, 0 failures, 74 assertions, 0.151s |
| `.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\door-both.json`; 42 results, 0 failures, 76 assertions, 0.073s |
| `.\tools\run-npc-navigation-tests.ps1` | Pass | `artifacts\test-runners\npc-navigation-report.json`; 11 results, 0 failures |

Required Phase 06 door IDs covered:

- `npc_door_idempotent_open`
- `npc_door_idempotent_close`
- `npc_door_single_open_cross_close`
- `npc_door_double_coordinated_portal`
- `npc_door_player_npc_shared_authority`
- `npc_door_threshold_occupied_no_close`
- `npc_door_sweep_occupied_no_close`
- `npc_door_clearance_volume_occupied_no_close`
- `npc_door_obstructed_closing_reopens`
- `npc_door_queue_inherits_opening`
- `npc_door_opposing_direction_ordered`
- `npc_door_locked_authorized`
- `npc_door_locked_unauthorized_alternate`
- `npc_door_jammed_failure_or_alternate`
- `npc_door_destroyed_topology_update`
- `npc_door_no_timeout_safety_override`
- `npc_door_cancelled_actor_releases_hold`
- `npc_door_night_civilian_enters_home`
- `npc_door_night_guard_exits_for_duty`
- `npc_door_night_player_blocks_threshold_no_close`
- `npc_door_day_worker_exit_and_return`

Legacy door continuity evidence:

- `npc_nav_two_npc_door_crossing`: pass; details include `crossed true`, `minSep 1.25`, `closed true`.
- `door_toggle_collision`: pass; details `opened true, closed proxy true, reopened proxy true, proxy true, body rotation fixed true`.

## 9. Day And Night Evidence

`door-both.json` ran every required door case once at canonical day and once at canonical night:

- Day snapshot: `time_of_day = 0.25`, display hour `12:00`.
- Night snapshot: `time_of_day = 0.75`, display hour `00:00`.
- Door matrix: 21 case IDs x 2 time modes = 42 results, 0 failures.

Night-specific door behavior passed for civilian home entry, guard duty exit, and player-blocked threshold close refusal.

Day-specific door behavior passed for worker exit and return, player/NPC shared authority, queue inheritance, and two-actor ordered crossing.

## 10. Full All-Runner Evidence On Phase Branch

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Report: `artifacts\test-runners\all-test-runners-report.json`

Result: pass, 7 runners, 0 failures, 1621.652s, finished `2026-06-26T08:12:45.5330923Z`.

| Runner | Exit | Result | Duration | Fresh report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | Pass | 8.773s | yes |
| `npc_navigation_legacy` | 0 | Pass | 399.338s | yes |
| `playtest` | 0 | Pass | 1045.696s | yes |
| `story_playtest` | 0 | Pass | 68.682s | yes |
| `world_signature` | 0 | Pass | 15.952s | yes |
| `visual_captures` | 0 | Pass | 83.075s | yes |
| `visual_manifest` | 0 | Pass | 0.090s | yes |

Runner registry used: `tools\test-runner-registry.json`.

## 11. Merged Master Evidence

Pending until the required non-fast-forward merge and `.\tools\run-all-test-runners.ps1` rerun on `master`.

## 12. Static And Prohibited-Shortcut Audit

Commands run on the Phase 06 branch:

```powershell
git diff --check -- . ':!artifacts/baselines/world-signature/atlas-1492.json'
rg -n "toggle_door" scripts\NpcSystem.gd scripts\npc_nav scripts\npc_ai
rg -n "pending_door|timed_out|DOOR_CLOSE_TIMEOUT|schedule_door_close|update_pending_door_closes|open_door_for_npc" scripts
rg -n "\.disabled\s*=|disabled\s*=" scripts\MainRuntimeTools.gd scripts\NpcSystem.gd scripts\npc_nav scripts\npc_ai\interactions
```

Results:

- `git diff --check`: no whitespace errors; line-ending warnings only.
- NPC production `toggle_door` calls: no matches.
- Legacy pending door-close arrays/timers and unsafe timeout close terms: no matches.
- Door collider mutation: only `scripts\npc_ai\interactions\DoorController.gd:183`.
- No generated world signature drift was accepted. `.\tools\run-world-signature.ps1` through all-runner matched the tracked baseline.
- The pre-existing modified `artifacts/baselines/world-signature/atlas-1492.json` remained unstaged.

## 13. Defect Found During Branch Gate

The first broad all-runner attempt failed only `door_toggle_collision`. Root cause: ordinary open requests with an actor ID created a persistent controller hold, so the player compatibility close request was denied by its own hold.

Fix: `DoorController.request_open()` now changes the desired state without creating an actor hold. Explicit traversal holds remain available through `request_hold()` and `hold_open()`, which the NPC door traversal path uses.

After the fix, the door focused suite, legacy door path, and full all-runner gate passed on the Phase 06 branch.

## 14. Gate Matrix

| Phase 06 gate | Status | Evidence |
| --- | --- | --- |
| Every generated/player-placed door has a logical portal/controller | Pass | Door-focused cases and legacy generated-door playtest exercise registered portals/controllers |
| Player and NPCs use the same authoritative door actions/state | Pass | `npc_door_player_npc_shared_authority`, `door_toggle_collision` |
| Single/double doors open, coordinate, cross, and close safely | Pass | `npc_door_single_open_cross_close`, `npc_door_double_coordinated_portal`, `npc_nav_two_npc_door_crossing` |
| Occupancy and active reservation defeat close regardless of elapsed time | Pass | threshold, sweep, clearance, queue, and no-timeout door cases |
| Door failures alter action/route feasibility correctly | Pass | locked, unauthorized alternate, jammed, destroyed, missing/unloaded door cases |
| Night inbound/outbound door scenarios pass | Pass | night civilian, night guard, and night player-blocking cases |
| Legacy door smoke tests remain green through the new controller | Pass | `npc_nav_door_open_close_cycle`, `door_toggle_collision` |
| All focused suites pass on branch | Pass | contract, motor, nav-world, route, repair, and door suites all green |
| Full repository gate passes on branch | Pass | `.\tools\run-all-test-runners.ps1`; 7 runners, 0 failures |
| Full repository gate passes on merged `master` | Pending | Merge and master rerun not yet executed at branch-report authoring time |

## 15. Review Questions

Is there exactly one logical authority per doorway?

Yes. Doors register through `DoorPortalService`, which resolves stable portal/group IDs and owns the logical state for single and double doors. Controllers are leaf-level physical executors under the portal authority.

Can a repeated request accidentally invert state?

No. Door requests are desired-state interactions. Repeated open/close requests return the current state or continue the same transition; they do not toggle.

Can any timer close on the player/NPC?

No. Pending timer ownership was removed from production NPC and runtime paths. Close requests consult threshold, sweep, clearance, active holds, reservations, and queue inheritance before collider/animation changes.

Are approach/threshold/sweep volumes real and tested?

Yes. Door portal metadata exposes approach/staging points, threshold extents, sweep radius, and clearance radius. Focused tests cover threshold, sweep, clearance, obstructed closing, and queue inheritance.

Do routes and actions observe access/state changes immediately?

Yes. Door state and access revisions feed route feasibility and repair responses. Locked, jammed, destroyed, missing, and unauthorized outcomes are surfaced to action/route callers as structured results.

## 16. Known Migration Debt

- Phase 07 still needs to replace hard-coded open-space sidestep behavior with predictive local avoidance while preserving the new portal authority.
- Later phases still need to move more high-level NPC purpose, schedules, traffic reservations, streaming, and save reconstruction out of legacy compatibility surfaces.
- `MainRuntimeTools.toggle_door()` remains as a deprecated player compatibility adapter. It delegates to the smart-object/door controller path and is not used by NPC production code.
