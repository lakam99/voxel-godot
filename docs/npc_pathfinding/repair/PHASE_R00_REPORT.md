# Phase R00 Report: Red Real Tutorial Playthrough Runner

## Scope

- Branch: `npc-pathfinding/repair-00-red-real-playthrough`
- Base commit: `13817a651860325f056f6bf3f7dab4810a36894f`
- Final commit: commit containing this report
- Merge commit: not applicable for R00 red characterization
- Test ID: `npc_tutorial_real_knock_to_morning_foragers`

R00 adds the real tutorial playthrough runner required by `CODEX_NPC_PATHFINDING_LIVE_REPAIR_PLAN.md`. The runner instantiates `res://scenes/Main.tscn`, uses deterministic seed `atlas-1492`, drives the player through the real input path, and records timelines instead of flipping tutorial state directly.

## Files Changed

- `tools/npc/run-real-tutorial-playthrough.ps1`
- `scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd`
- `scenes/testing/npc/NpcRealTutorialPlaythroughTest.tscn`
- `tools/test-runner-registry.json`
- `tools/npc/npc-suite-registry.json`
- `docs/npc_pathfinding/repair/PHASE_R00_REPORT.md`

## Implementation Summary

- Added a dedicated Godot runner scene for the real tutorial playthrough.
- Added a PowerShell wrapper with static forbidden-call scanning, detached Godot launch, progress polling, stale-progress cutoff, and stdout/stderr script-error scanning.
- Registered the runner in both aggregate runner registries.
- The runner performs deterministic tutorial reset before gameplay input begins, then uses player automation, camera aiming, mouse input, and Escape input to drive the real door/dialogue path.
- The runner records player timeline, door timeline, Mira movement timeline, route/order timeline, NPC schedule matrix, script-error scan, static forbidden-call scan, and Niko/forager route/smart-object state.

## Focused Evidence

Command:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -Seed atlas-1492 -TimeoutSeconds 120 -StaleProgressSeconds 30
```

Expected R00 result: fail red.

Report:

```text
artifacts/npc/reports/real-tutorial-playthrough.json
```

Observed result:

- `passed`: `false`
- `failureCount`: `1`
- failure: `mira_stalls_due_to_update_budget`
- detail: `Mira moved only 0.000 meters during observation`
- process stop reason: `completed`
- script-error scan: `passed`
- forbidden-call self-scan: `passed`

Real input proof:

- Door timeline shows the starter door changed from `open=false` to `open=true`.
- Tutorial state after door input has `doorOpened=true`.
- Tutorial state after Escape has `elderAcknowledged=true`.

Timeline evidence:

- Player timeline samples: `127`
- Door timeline samples: `3`
- Mira timeline samples: `120`
- Mira route/order samples: `120`
- Mira speed samples: `719`
- NPC schedule matrix rows: `6`
- Niko/forager state rows: `1`

The red failure is not a shortcut failure: the door opened through the real input event path, dialogue was acknowledged through Escape, and Mira then remained outside with `routeStatus=moving`, `lastMoveDistance=0.0`, and `strictInsideHome=false`.

## Script Error Scan

Wrapper scan result:

- stdout: `artifacts/npc/logs/real-tutorial-playthrough.out.log`
- stderr: `artifacts/npc/logs/real-tutorial-playthrough.err.log`
- match count: `0`
- status: `passed`

## Forbidden Shortcut Search

Command:

```powershell
rg -n "on_door_opened|interact_with\(|complete_step|on_block_placed|on_bed_used|intro_.*=|inventory_system\.add_item|player\.global_position\s*=|npc_system\.move_npc|safe_place_npc" scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd
```

Expected and observed result: zero matches.

## Existing Test Integrity

No existing gameplay test logic was weakened. R00 only adds a new red characterization runner and registers it. The aggregate gates are expected to fail on this branch because the required R00 runner is intentionally red.

## Gate And Merge Status

Branch full all-runner gate: intentionally not run after the focused R00 runner produced the required red failure. Running the aggregate registry on this branch would fail on the newly registered R00 runner by design.

Merged `master` all-runner gate: not applicable. This red characterization branch must not be merged into `master` until later repair phases make the registered real tutorial runner green.

## Verdict

R00 acceptance is satisfied: the runner exists, runs through real player-facing actions, fails honestly on current broken behavior, and emits the required evidence report. The branch is intentionally red and remains unmerged.
