# Phase 07 Report - Predictive Local Avoidance and Stable Corridor Following

## 1. Phase Identification

- Phase: 07 - Predictive Local Avoidance and Stable Corridor Following
- Branch: `npc-pathfinding/phase-07-local-avoidance`
- Base commit before Phase 07 branch changes: `eddd86abceb1d63b5e2134e602986f56fba23a52`
- Branch code commit: pending branch commit
- Merge commit: pending merge to `master`
- Date: 2026-06-26
- Scope status: branch gates pass; merged `master` gate pending until the required non-fast-forward merge and rerun.

## 2. Objective

Phase 07 replaces hard-coded open-space sidestep steering with a corridor follower plus a predictive moving-agent avoidance adapter. Route corridor constraints, door/portal authority, and shared `CharacterBody3D` motor movement remain above any local avoidance suggestion.

## 3. Pre-Phase State

- `git status --short` before Phase 07 work showed one pre-existing modified tracked baseline: `artifacts/baselines/world-signature/atlas-1492.json`.
- That baseline artifact stayed outside the Phase 07 staging scope.
- `scripts/NpcNavigationTestRunner.gd` currently shows no content diff; Git reports it as touched by line-ending/stat tracking only.
- Phase 06 had moved door decisions to shared portal/controller services, but local open-space NPC steering still lived mainly in legacy locomotion helper logic.

## 4. Implementation Summary

`NpcCorridorFollower` now owns route-following velocity selection. It computes speed-aware lookahead, corner slowing, action stopping, terminal arrival, corridor clamp/projection, portal mode, no-progress classification, and oscillation counters before handing a movement candidate to the shared motor.

`ReciprocalAvoidanceAdapter` now owns active moving-agent avoidance. It configures Godot `NavigationAgent3D` helper nodes from named NPC constants, supplies current desired velocity and target metadata, tracks callback freshness, and returns a bounded safe-velocity candidate. In headless focused runs, Godot callback hits are not guaranteed; the adapter therefore uses deterministic predictive fallback when the callback is absent or stale, and tests assert invariant outcomes rather than bitwise-identical positions.

The locomotion controller now delegates steering to the corridor follower and treats the motor result as the source of route progress. Static collision, dynamic actor blocks, traffic/reservation waits, door state, stale corridors, and invalid goals are classified separately. Legacy fixed sidestep lists and fixed backoff attempts are no longer the primary open-space moving-agent strategy.

Portal mode reduces lateral avoidance to zero inside the threshold. Door traversal and reservation authority decide right of way; avoidance cannot steer an NPC around a closed door, into a frame, or outside the portal corridor. If physical movement is blocked at a portal, the locomotion controller attempts a validated recenter or axis retreat through the shared motor.

Scripted near-goal movement now uses a terminal direct corridor candidate to avoid late avoidance sidesteps around small scripted/door targets. Scripted route arrival radius was tightened in the goal planner, while door traffic release radius was widened so portal ownership lasts through exit-lane clearance.

NPC stats now expose avoidance counters for active frames, callback frames, fallback frames, and active registrations. `NpcStats.gd` reports adapter and corridor metrics for focused test evidence.

## 5. Files Added And Changed

Added:

- `scripts/npc_ai/movement/NpcCorridorFollower.gd`
- `scripts/npc_ai/movement/ReciprocalAvoidanceAdapter.gd`
- `scripts/testing/npc/NpcAvoidanceTestCases.gd`
- `tools/npc/run-npc-avoidance-tests.ps1`
- `docs/npc_pathfinding/PHASE_07_REPORT.md`

Changed:

- `scripts/NpcStats.gd`
- `scripts/NpcSystem.gd`
- `scripts/npc_ai/NpcConstants.gd`
- `scripts/npc_nav/NpcGoalPlanner.gd`
- `scripts/npc_nav/NpcLocomotionController.gd`
- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`

Not staged:

- `artifacts/baselines/world-signature/atlas-1492.json` - pre-existing tracked artifact change.
- `scripts/NpcNavigationTestRunner.gd` - no content diff; line-ending/stat noise only.

## 6. Focused Test Evidence

Command:

```powershell
.\tools\npc\run-npc-avoidance-tests.ps1 -TimeMode Both
```

Latest branch all-runner invocation also reran this suite with:

- Report: `artifacts/npc/reports/avoidance-both.json`
- Run token: `9cc54aab5ef049c1a7f7bddd5143614b`
- Started UTC: `2026-06-26T14:49:36`
- Finished UTC: `2026-06-26T14:49:36`
- Result count: 30
- Failure count: 0
- Time modes: day, night

Required IDs exercised in both time modes:

- `npc_avoidance_head_on_open_road`
- `npc_avoidance_crossing_paths`
- `npc_avoidance_overtake_slow_actor`
- `npc_avoidance_crowded_plaza_progress`
- `npc_avoidance_corridor_boundary_respected`
- `npc_avoidance_no_left_right_oscillation`
- `npc_avoidance_wall_not_treated_as_rvo_only`
- `npc_avoidance_closed_door_not_bypassed`
- `npc_avoidance_portal_mode_no_frame_sidestep`
- `npc_avoidance_inactive_agents_disabled`
- `npc_avoidance_stale_callback_safe_stop`
- `npc_follow_arrival_no_orbit`
- `npc_follow_progress_watchdog_classifies_blocker`
- `npc_follow_day_crowd_progress`
- `npc_follow_night_guard_passes_returning_civilian`

Representative assertions:

- Head-on open road: progress `1.89/1.89`, min separation `1.86`, active registration sum `108`.
- Crossing paths: progress `1.20/1.20`, min separation `1.31`.
- Crowded plaza: day progress `6.10`, night progress `6.06`; active registration sum `208`.
- Corridor boundary: lateral `0.283`, candidate kept inside corridor, stale callback fallback used.
- Wall block: classified as `static_collision`, reason `blocked_static`, with no relevant moving-agent avoidance active.
- Closed door: classified as `door_state`, reason `door_closed`, portal reservation authority disables avoidance.
- Portal mode: safe velocity `(0.0, 0.0, 2.0)`, lateral `0.000`.
- Inactive agents: active registration count `0`, inactive skip count `1`.
- Arrival: classification `arrival`, candidate zero, no orbit.
- Progress watchdog: classified `dynamic_actor` after 18 no-progress ticks.
- Oscillation: sign changes `0`, heading reversals `0`.

## 7. NPC Suite Evidence

Command:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both
```

Latest branch all-runner invocation produced:

- Report: `artifacts/npc/reports/all-npc-both.json`
- Result count: 7
- Failure count: 0
- Duration: `15.411` seconds

Suites:

- `contract`: pass, `1.714` seconds
- `motor`: pass, `1.454` seconds
- `nav_world`: pass, `1.607` seconds
- `route`: pass, `5.535` seconds
- `repair`: pass, `1.734` seconds
- `door`: pass, `1.815` seconds
- `avoidance`: pass, `1.536` seconds

Legacy NPC navigation wrapper:

- Command: `.\tools\run-npc-navigation-tests.ps1 -ReportPath artifacts\test-runners\npc-navigation-report.json`
- Report: `artifacts/test-runners/npc-navigation-report.json`
- Result count: 11
- Failure count: 0
- Duration inside all-runner: `261.388` seconds
- Door crossing evidence: crossed true, min separation `1.34`, door counts `1/0 -> 3/2`, routes `arrived/arrived`, closed true.
- Generic job evidence: outside worker seen true, job runs `0->1`, forager berries `2`, hunger `61.7`.

## 8. Branch All-Runner Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Report:

- `artifacts/test-runners/all-test-runners-report.json`
- Started UTC: `2026-06-26T14:49:21.7357966Z`
- Finished UTC: `2026-06-26T15:32:57.2970205Z`
- Duration: `2615.562` seconds
- Result count: 7
- Failure count: 0

Runner results:

- `npc_focused`: pass, `15.77` seconds, report fresh true
- `npc_navigation_legacy`: pass, `261.388` seconds, report fresh true
- `playtest`: pass, `2183.178` seconds, report fresh true
- `story_playtest`: pass, `70.337` seconds, report fresh true
- `world_signature`: pass, `15.475` seconds, report fresh true
- `visual_captures`: pass, `69.292` seconds, report fresh true
- `visual_manifest`: pass, `0.063` seconds, report fresh true

Additional broad playtest rerun before the all-runner:

- Command: `.\tools\run-playtest.ps1 -ReportPath .\artifacts\test-runners\playtest-report.json`
- First attempt failed only `held_torch_terrain_material_flickers`, matching a prior visual threshold flake.
- Immediate rerun passed: 181 results, 0 failures, terminal `finished` marker.
- The all-runner playtest also passed: 181 results, 0 failures.

## 9. Gate Audit

| Gate | Branch Evidence | Status |
| --- | --- | --- |
| Fixed sidestep lists are no longer primary avoidance. | `NpcLocomotionController` delegates steering to `NpcCorridorFollower`; moving-agent avoidance goes through `ReciprocalAvoidanceAdapter`. | Pass on branch |
| Open-space actors pass/cross without bump loops and make bounded progress. | Head-on, crossing, overtake, crowded plaza, day crowd, and night guard/civilian cases pass in day and night. | Pass on branch |
| Avoidance never steers outside capsule-safe corridor or through static geometry. | Corridor boundary, wall-not-RVO-only, stale callback safe stop, and closed door cases pass; candidate rejection and classification are asserted. | Pass on branch |
| Door/portal reservations remain authoritative. | Closed door and portal mode cases pass; legacy two-NPC door crossing passes with door closed after clearance. | Pass on branch |
| Arrival does not orbit or oscillate. | Arrival case reports zero candidate and `arrived`; oscillation case reports sign changes `0` and heading reversals `0`. | Pass on branch |
| Avoidance cost is measured and inactive agents are deregistered/disabled. | Inactive case reports active registration count `0`; NPC stats expose active/fallback/callback counters. | Pass on branch |
| Day/night crowd cases pass. | All 15 avoidance IDs pass in both day and night modes. | Pass on branch |
| Full all-runner gate passes on branch and `master`. | Branch all-runner pass recorded above; merged `master` rerun is pending until the required merge step. | Branch pass; master pending |

## 10. Review Questions

Is RVO used only for local moving-agent avoidance?

Yes for the Phase 07 scope. Route selection, wall/door checks, and portal decisions remain outside the adapter. The adapter is active only when a relevant nearby moving actor exists; otherwise it returns inactive/no-neighbor status and the corridor follower uses route/motor validation.

Can RVO defeat a route, wall, or door constraint?

No in the tested paths. The follower clamps/projects safe velocity to corridor or portal constraints, validates the candidate, and rejects static/door violations. Closed door and wall tests prove that avoidance does not bypass those constraints.

Are inactive agents truly disabled?

Yes in the focused case: active registration count is `0`, registered agents are `0`, and inactive skip count increments. Runtime stats expose active registration totals for broader measurement.

Is oscillation measured and bounded?

Yes. The follower tracks lateral sign changes, heading reversals, no-progress classifications, and progress. The oscillation focused case reports `0` sign changes and `0` heading reversals over the test window.

Does actual motor progress drive route advancement?

Yes. `NpcLocomotionController` records post-motor movement and feeds actual position/progress back into route state. Legacy navigation evidence includes route arrival through door crossing with physical separation and no transform advancement in normal route movement.

## 11. Tolerances And Notes

- Godot avoidance callbacks may be absent in headless focused runs. The adapter treats stale or absent callbacks as unsafe to reuse and uses deterministic prediction or validated direct corridor velocity instead.
- The tests assert invariant outcomes: progress, no penetration, corridor/portal limits, no orbit, no stale unsafe velocity reuse, and correct blocker classification.
- Portal recenter and axis retreat are deterministic physical recovery steps for blocked threshold movement. They are not the primary open-space avoidance path.
- The pre-existing world-signature baseline artifact remains a user/worktree change and is outside Phase 07 staging.
- The required `master` all-runner rerun has not happened yet because the branch has not yet been committed and merged.
