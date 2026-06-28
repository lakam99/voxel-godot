# Phase R03 Report - Scripted Orders Through Normal NPC Routing

Branch: `npc-pathfinding/repair-03-scripted-orders`

Base commit: `3de2710fe2b1c096829bfb421752cb01763c03e1` (`master`, after R02 merge)

Branch final commit: to be recorded after the branch commit is fixed and before/after merge.

Merge commit: pending.

Status: PASS for R03 branch gates. Merge to `master` is allowed after commit.

## Implementation Summary

- Added an explicit scripted order API to `NpcSystem`:
  - `order_wait(actor_id, reason)`
  - `order_go_to(actor_id, target, reason, arrival_radius := -1.0)`
  - `order_go_home(actor_id, reason)`
  - `order_face_player(actor_id, reason)`
  - `order_resume_schedule(actor_id)`
  - `cancel_order(actor_id, reason)`
- Added order result state tracking with `PENDING`, `ACTIVE`, `ARRIVED`, `CANCELLED`, `FAILED_TARGET_GONE`, and `FAILED_BLOCKED` paths used by the current implementation.
- Kept legacy `set_scripted_target` compatibility, but made it create a `go_to` scripted order instead of a bare target-only meta state.
- Routed `go_to` through the existing scripted movement lane, which calls `move_npc()` and therefore the normal route/motor stack.
- Routed `go_home` through the existing home executor and home route stack rather than creating a special target mover.
- Added selector/perception support for `scriptedHomeOrder`, so a scripted home order chooses the home goal instead of a generic scripted target goal.
- Wired real intro elder dialogue acknowledgement to `NpcSystem.order_go_home(..., "intro_acknowledged_return_home")`.
- Preserved `holdIntroDoor` only as a hold/dialogue state. It does not alter movement speed.

## Files Changed

- `scripts/NpcSystem.gd`
- `scripts/TutorialSystem.gd`
- `scripts/npc_ai/behavior/NpcGoalSelector.gd`
- `scripts/npc_ai/behavior/NpcPerceptionService.gd`
- `scripts/npc_ai/behavior/NpcPlanExecutor.gd`
- `scripts/testing/npc/NpcBehaviorTestCases.gd`

## Failures Found and Fixed

- Initial behavior-suite run selected zero cases because new script changes caused GDScript parse warnings treated as errors.
- Fixed typed Variant inference warnings in:
  - `NpcPlanExecutor.gd`: `face_target` now has explicit `Vector3` type.
  - `NpcBehaviorTestCases.gd`: fake scripted-order result dictionary now has explicit `Dictionary` type.
- Re-ran the focused single R03 case and then the full behavior suite successfully.

## Focused R03 Coverage

Command:

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\behavior-r03-scripted-orders-2.json
```

Result:

- `resultCount=34`
- `failureCount=0`
- wrapper exit code `0`

R03 behavior cases:

| Case | Result | Evidence |
| --- | --- | --- |
| `npc_behavior_scripted_order_go_home_uses_route_stack` | pass | `moveCalls=8`, `homeCalls=8`, no `npc_scripted_target` meta |
| `npc_behavior_scripted_order_normal_profile_speed` | pass | max requested step `0.0508`, no speed hack |
| `npc_behavior_scripted_order_no_transform_write` | pass | scripted update uses `move_npc`, no transform assignment |
| `npc_behavior_mira_dialogue_ack_releases_go_home_order` | pass | ack hook and order API present |
| `npc_behavior_mira_home_arrival_requires_interior` | pass | interior semantics and porch-blocked check present |
| `npc_behavior_hold_intro_door_not_speed_override` | pass | no forbidden hold/speed shortcut |

Existing R02 behavior cases also remained green, including:

- `npc_behavior_scripted_order_moves_while_brain_skipped`
- `npc_behavior_mira_no_inching_after_dialogue`
- `npc_behavior_morning_departures_not_brain_starved`
- `npc_traffic_door_crossing_continues_while_brain_skipped`

## Real Tutorial Regression Check

Command:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\real-tutorial-r03-scripted-orders.json -ProgressPath artifacts\npc\progress\real-tutorial-r03-scripted-orders.txt -TimeoutSeconds 90 -StaleProgressSeconds 20
```

Result:

- wrapper exit code `0`
- `passed=true`
- `failureCount=0`
- `processExitCode=0`
- `processStopReason=completed`
- `scriptErrorScan.status=passed`
- `scriptErrorScan.matchCount=0`

Real runner assertions:

- `real_door_input_opened_tutorial_dialogue`: pass
- `mira_timeline_speed_within_profile`: pass, max flat speed `6.401 <= 7.360`

Scope note: this runner remains the R00 partial real playthrough gate. It does not yet prove repair/sleep/morning foraging; Phase R04 owns that full sequence.

## Full NPC Gate on Branch

Command:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\all-npc-r03-scripted-orders.json -ProgressPath artifacts\npc\progress\all-npc-r03-scripted-orders.txt
```

Result:

- wrapper exit code `0`
- `resultCount=13`
- `failureCount=0`
- failed suites: none

All registered NPC suites passed:

`contract`, `motor`, `nav_world`, `route`, `repair`, `door`, `avoidance`, `traffic`, `behavior`, `interaction`, `streaming_save`, `soak`, `real_tutorial_playthrough`.

## Repository All-Runner Gate on Branch

Command:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\all-test-runners-r03-scripted-orders.json
```

Registry:

- `tools/test-runner-registry.json`

Result:

- wrapper exit code `0`
- `resultCount=11`
- `failureCount=0`
- `stoppedEarly=false`

Runner evidence:

| Runner | Exit | Passed | Duration |
| --- | ---: | --- | ---: |
| `npc_focused` | 0 | true | 54.948s |
| `npc_observation_dusk` | 0 | true | 0.654s |
| `npc_observation_midnight` | 0 | true | 0.640s |
| `npc_observation_phase12` | 0 | true | 0.947s |
| `world_signature` | 0 | true | 12.455s |
| `visual_manifest` | 0 | true | 0.091s |
| `npc_navigation_integration` | 0 | true | 25.734s |
| `npc_real_tutorial_playthrough` | 0 | true | 27.692s |
| `story_playtest` | 0 | true | 60.102s |
| `visual_captures` | 0 | true | 47.403s |
| `playtest` | 0 | true | 140.166s |

## Static Searches

Forbidden real-runner shortcut search:

```powershell
rg -n "on_door_opened|interact_with\(|complete_step|on_block_placed|on_bed_used|intro_.*=|inventory_system\.add_item|player\.global_position\s*=|npc_system\.move_npc|safe_place_npc" scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd
```

Result: no matches.

Tutorial speed-hack search:

```powershell
rg -n "speed\s*=\s*20\.0|holdIntroDoor.*speed|speed.*holdIntroDoor" scripts\NpcSystem.gd scripts\npc_ai scripts\TutorialSystem.gd scripts\TutorialDialogueSystem.gd
```

Result: no matches.

Order API search:

```powershell
rg -n "func order_wait|func order_go_to|func order_go_home|func order_face_player|func order_resume_schedule|func cancel_order|intro_acknowledged_return_home" scripts\NpcSystem.gd scripts\TutorialSystem.gd
```

Result: all required API functions found; `TutorialSystem.gd` calls `order_go_home(..., "intro_acknowledged_return_home")`.

Whitespace/static check:

```powershell
git diff --check
```

Result: no whitespace errors; Git reported LF-to-CRLF warnings for touched files only.

## Acceptance Mapping

- Tutorial/story NPC movement is expressible as explicit orders: `NpcSystem` exposes the required R03 order API.
- Orders use normal routing/motor paths: `go_to` calls `move_npc`; `go_home` routes through the home executor; behavior tests prove route-stack calls.
- Mira no longer has a special speed path: speed-hack search has no matches and focused behavior speed assertions pass.
- Dialogue acknowledgement releases Mira with `order_go_home("intro_acknowledged_return_home")`.
- Home arrival still requires interior semantics; porch fallback remains blocked as not-inside.
- Existing story/tutorial and broad gates remain green through the branch all-runner.

## Merged Master Verification

Pending until branch merge. After merge, rerun:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492
```

and record the result in this report or the final handoff.

## Verdict

R03 branch gates pass. Merge is allowed.
