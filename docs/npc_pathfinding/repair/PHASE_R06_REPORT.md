# Phase R06 Report - Final Cleanup And Gate

Branch: `npc-pathfinding/repair-06-final-cleanup-gate`

Base commit: `c8e381f975a95a3848eb1c5f7eeb43605dab5cfa`

Branch final commit: `5ffebd2` (`Complete NPC repair final gate coverage`).

Merge commit: `84cbfaf` (`Merge NPC repair final gate coverage`).

Status: complete. Branch and merged-`master` aggregate gates passed.

## Implementation Summary

- Reclassified old broad playtest tutorial shortcut assertions as contract tests by renaming their result IDs with `tutorial_contract_*`.
- Added exact R05 focused forager/resource test IDs.
- Added explicit R06 top-level test-runner registry entries for the focused NPC suites named in the live repair plan.
- Preserved the mandatory real tutorial playthrough gate in `tools/test-runner-registry.json`.

## Files Changed

- `scripts/PlaytestRunner.gd`
- `scripts/testing/npc/NpcInteractionTestCases.gd`
- `tools/test-runner-registry.json`
- `docs/npc_pathfinding/repair/PHASE_R04_REPORT.md`
- `docs/npc_pathfinding/repair/PHASE_R05_REPORT.md`
- `docs/npc_pathfinding/repair/PHASE_R06_REPORT.md`
- `docs/npc_pathfinding/repair/FINAL_LIVE_REPAIR_ACCEPTANCE_REPORT.md`

## Old Shortcut Reclassification

The old broad playtest result labels now use contract naming:

- `tutorial_contract_intro_knock_elder`
- `tutorial_contract_followups_locked_until_sleep`
- `tutorial_contract_repair_and_sleep_gate`
- `tutorial_contract_npc_interaction`
- `tutorial_contract_niko_food_errand`
- `tutorial_contract_rowan_errand_chain`
- `tutorial_contract_weapon_preps_final_night`
- `tutorial_contract_final_rescue_mission`

Search:

```powershell
rg -n "tutorial_intro_knock_elder|tutorial_followups_locked_until_sleep|tutorial_repair_and_sleep_gate|tutorial_npc_interaction|tutorial_niko_food_errand|tutorial_rowan_errand_chain|tutorial_weapon_preps_final_night|tutorial_final_rescue_mission" scripts\PlaytestRunner.gd
```

Result: no matches.

## Focused Test Evidence

Interaction suite:

```powershell
.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\interaction-r06-focused.json
```

Result: `resultCount=33`, `failureCount=0`, `assertions=60`.

Behavior transition suite:

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Transition -ReportPath artifacts\npc\reports\behavior-r06-transition.json
```

Result: `resultCount=2`, `failureCount=0`.

Soak suite:

```powershell
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\soak-r06-both.json
```

Result: `failureCount=0`.

## Required Static Searches

Forbidden shortcut scan in the real playthrough runner:

```powershell
rg -n "on_door_opened|interact_with\(|complete_step|on_block_placed|on_bed_used|intro_.*=|inventory_system\.add_item|player\.global_position\s*=|npc_system\.move_npc|safe_place_npc" scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd
```

Result: no matches.

Mira speed-hack scan:

```powershell
rg -n "speed\s*=\s*20\.0|holdIntroDoor.*speed|speed.*holdIntroDoor" scripts/NpcSystem.gd scripts/npc_ai scripts -g "Tutorial*.gd"
```

Result: no matches.

SmartObjectService node-use scan:

```powershell
rg -n "node is Node3D|as Node3D|get_meta|global_position|position" scripts/npc_ai/interactions/SmartObjectService.gd
```

Result: nonzero by design. Inspection notes:

- `live_registration_node_3d()` stores `registration.node`, checks null, checks `is_instance_valid(node)`, and only then checks/casts `Node3D`.
- `object_position_from_node_or_metadata()` returns metadata position first, then checks null and `is_instance_valid(node)` before `node is Node3D`, cast, `global_position`, or `position`.
- `registration_matches_query()` and `query_resource_nodes()` obtain live nodes through `live_registration_node_3d()` before using metadata/candidate filters that require a node.
- Actor/block node accesses are separately guarded with null and `is_instance_valid()` checks.

NPC budget scan:

```powershell
rg -n "budget = 4|budget = 6|npc_update_cursor" scripts/NpcSystem.gd scripts/npc_ai
```

Result: nonzero by design in `scripts/NpcSystem.gd`.

Inspection notes:

- Lines around `budget = 4`, `budget = 6`, and `npc_update_cursor` throttle only the brain/update cursor.
- After the budgeted `update_npc()` loop, `NpcSystem.update_npcs()` iterates every active entry and calls `autonomy_system.advance_npc_motion(entry, delta, night_factor)`.
- `NpcAutonomySystem.advance_npc_motion()` records `npc_motion_updates`, `npc_last_motion_tick`, `npc_active_route_motion_ticks`, `npc_scripted_order_motion_ticks`, and `npc_door_action_motion_ticks`.

## Branch All-Runner Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\all-test-runners-r06-branch.json -StopOnFailure
```

Result: `resultCount=23`, `failureCount=0`, `stoppedEarly=false`, `durationSeconds=681.162`, exit code `0`.

Required runner IDs passed:

- `npc_focused`
- `npc_contract_tests`
- `npc_motor_tests`
- `npc_route_tests`
- `npc_repair_tests`
- `npc_door_tests`
- `npc_avoidance_tests`
- `npc_traffic_tests`
- `npc_behavior_tests`
- `npc_behavior_transition_tests`
- `npc_interaction_tests`
- `npc_streaming_save_tests`
- `npc_soak_tests`
- `npc_observation_dusk`
- `npc_observation_midnight`
- `npc_observation_phase12`
- `world_signature`
- `visual_manifest`
- `npc_navigation_integration`
- `npc_real_tutorial_playthrough`
- `story_playtest`
- `visual_captures`
- `playtest`

## Merged Master Evidence

Command after merge:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\all-test-runners-r06-master.json -StopOnFailure
```

Result: `resultCount=23`, `failureCount=0`, `stoppedEarly=false`, `durationSeconds=697.697`, exit code `0`.

## Verdict

R06 code/report cleanup passed both the branch and merged-`master` aggregate gates.
