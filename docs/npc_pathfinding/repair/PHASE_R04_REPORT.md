# Phase R04 Report - Real Tutorial Full Playthrough Acceptance Gate

Branch: `npc-pathfinding/repair-04-real-tutorial-playthrough`

Base commit: `c70131beb3026c498678c124dfa24e0b319bc848` (`master`, after R03 merge)

Branch final commit: `c8e381f975a95a3848eb1c5f7eeb43605dab5cfa`

Merge commit: fast-forward to `c8e381f975a95a3848eb1c5f7eeb43605dab5cfa`; `master` and `npc-pathfinding/repair-04-real-tutorial-playthrough` point to the same commit.

Status: PASS for the real tutorial runner and merged-`master` aggregate gate.

## Implementation Summary

- Extended `scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd` from the initial knock/Mira proof into the full required sequence: real door interaction, real HUD dialogue acknowledgement, Mira home return, night schedule matrix, real repair chest/material flow, real placement repair, sleep gate, morning departure observation, and Niko/forager proof.
- Registered the real tutorial runner in both `tools/npc/npc-suite-registry.json` and `tools/test-runner-registry.json`.
- Kept the runner source free of direct tutorial-state shortcuts and direct NPC movement.
- Hardened navigation and route diagnostics enough for the live sequence to complete without wall penetration, Mira speed spikes, or stale smart-object crashes.

## Files Changed

- `scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd`
- `tools/npc/run-real-tutorial-playthrough.ps1`
- `tools/npc/npc-suite-registry.json`
- `tools/test-runner-registry.json`
- NPC navigation/movement support files included in commit `c8e381f`.

## Focused Real Runner Evidence

Command:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\npc-real-tutorial-playthrough.json
```

Report:

```text
artifacts\test-runners\npc-real-tutorial-playthrough.json
```

Result:

- `testId=npc_tutorial_real_knock_repair_sleep_morning_foragers`
- `failureCount=0`
- `resultCount=7`
- `processExitCode=0`
- `scriptErrorScan.status=passed`
- `forbiddenCallSelfScan.status=passed`

Live proof extracted from the report:

- Door opened through the real interaction path.
- HUD dialogue opened and was acknowledged through HUD input.
- Mira max flat speed was `6.401`, below profile limit `7.360`.
- Mira total flat movement was `101.236`.
- Mira final strict home interior status was `true`.
- Night guard/non-guard matrix was recorded.
- Repair target placement proof and sleep transition proof were recorded.
- Morning departure matrix recorded six NPC entries.
- Niko selected live object `prop:atlas-1492:273,39:3`.
- Niko reservation `prop:atlas-1492:273,39:3:slot:0:niko:2185` was recorded.
- Niko reached forage cycle state `returning` with personal inventory `{ "berries": 2 }`.

## Repository All-Runner Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\all-test-runners-003.json -StopOnFailure
```

Result:

- `resultCount=11`
- `failureCount=0`
- `stoppedEarly=false`
- duration `616.826s`

Runner coverage included:

- `npc_focused`
- `world_signature`
- `npc_navigation_integration`
- `npc_real_tutorial_playthrough`
- `story_playtest`
- `visual_captures`
- `playtest`

## Static Searches

Forbidden real-runner shortcut search:

```powershell
rg -n "on_door_opened|interact_with\(|complete_step|on_block_placed|on_bed_used|intro_.*=|inventory_system\.add_item|player\.global_position\s*=|npc_system\.move_npc|safe_place_npc" scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd
```

Result: no matches.

Tutorial speed-hack search:

```powershell
rg -n "speed\s*=\s*20\.0|holdIntroDoor.*speed|speed.*holdIntroDoor" scripts/NpcSystem.gd scripts/npc_ai scripts -g "Tutorial*.gd"
```

Result: no matches.

## Verdict

R04 real tutorial playthrough acceptance passed. The live runner proves the knock-to-morning tutorial story through real gameplay-facing paths, not direct tutorial flag flips.
