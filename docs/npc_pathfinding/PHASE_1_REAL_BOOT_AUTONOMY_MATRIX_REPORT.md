# Phase 1 - Real-Boot NPC Autonomy Matrix Report

Phase: 1 - Real-Boot NPC Autonomy Matrix
Branch: `codex/npc-pathfinding-replacement`
Linear issue: `VOX-31`

## Commands Run

```powershell
.\tools\npc\assert-npc-acceptance-runner-clean.ps1 -RunnerPath scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd -ReportPath artifacts\npc\reports\phase1-runner-clean-guard.json -TestId npc_tutorial_real_knock_repair_sleep_morning_foragers -AllowedShortcutPattern final_rescue_fixture_setup_allowance
```

```powershell
.\tools\run-project-compile-smoke.ps1
```

```powershell
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -RealBoot -Visible -RunName phase1-realboot-autonomy-matrix -ReportPath artifacts\npc\reports\phase1-realboot-autonomy-matrix.json -ProgressPath artifacts\npc\progress\phase1-realboot-autonomy-matrix.txt -ScreenshotDir artifacts\npc\screenshots\phase1-realboot-autonomy-matrix -NoFlagsProofPath artifacts\npc\progress\phase1-realboot-autonomy-matrix.no-flags-proof.json -TimeoutSeconds 520 -StaleProgressSeconds 90
```

## Reports

- Runner clean guard: `artifacts/npc/reports/phase1-runner-clean-guard.json`
- Real-boot matrix report: `artifacts/npc/reports/phase1-realboot-autonomy-matrix.json`
- Progress log: `artifacts/npc/progress/phase1-realboot-autonomy-matrix.txt`
- No-flags proof: `artifacts/npc/progress/phase1-realboot-autonomy-matrix.no-flags-proof.json`
- Screenshots: `artifacts/npc/screenshots/phase1-realboot-autonomy-matrix/`

## Real-Boot And No-Flags Proof

The runner attached to the actual title menu and clicked New Game through viewport input.

- `actualGameplayDerived`: `true`
- `realBootAttachedToMainMenu`: `true`
- `launchPath`: `project main scene MainMenu.tscn New Game button input`
- `fullPlayerPov`: `true`
- `VOXEL_PLAYTEST`: unset
- `VOXEL_TEST_SEED`: unset
- `VOXEL_SAVE_PATH_OVERRIDE`: unset
- `VOXEL_REAL_TUTORIAL_GOD_MODE`: unset
- `VOXEL_GOD_MODE`: unset

The only runner environment variables were report/progress/screenshot paths, visual requirement, and `VOXEL_REAL_TUTORIAL_REAL_BOOT=1` so the runner could attach from the real main menu.

## Code Changed

- `scripts/TitleMenu.gd`: added a real-boot runner attachment hook gated by `VOXEL_REAL_TUTORIAL_REAL_BOOT`.
- `scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd`: changed menu launch to real New Game button input and added report fields for real-boot/no-flags proof.
- `tools/npc/run-real-tutorial-playthrough-no-flags.ps1`: added `-RealBoot`, no-flags proof output, and real-main-scene launch mode.

No production NPC pathfinding repair was made in this phase.

## Acceptance Result

Result: failed honestly, as expected for Phase 1.

The run reached the post-knock Mira return-home observation and failed before the sleep/morning autonomy checkpoints:

```text
passed=false
failureCount=1
lastFailureCode=mira_did_not_reach_strict_home_interior
elapsed=51.517
```

Strict home status from the report:

```json
{
  "cell": [292, 15],
  "doorCell": [292, 15],
  "homeCell": [294, 12],
  "interiorMinCell": [290, 10],
  "interiorMaxCell": [296, 14],
  "clearOfDoor": false,
  "doorClearanceOccupied": true,
  "doorSweepOccupied": true,
  "doorThresholdOccupied": true,
  "insideBounds": false,
  "insideWorldBounds": false,
  "pastDoorPlane": false,
  "strictInside": false,
  "reason": "not_inside_interior_bounds"
}
```

NPC matrix snapshot at failure:

| NPC | Job | Strict Inside Home | Route Status | Route Reason | Movement Delta | Notable State |
| --- | --- | --- | --- | --- | --- | --- |
| Mira |  | false | pending | queued | 0.0 | stopped on door cell, not strict interior |
| Rowan | wood | true | arrived |  | 0.0 | no daytime proof reached |
| Niko | forage | true | arrived |  | 0.0 | no daytime proof reached |
| Sera | guard | false | arrived |  | 0.0 | active door portal retained |
| Toma | guard | false | arrived |  | 0.0 | no movement proof reached |
| Lyra | guard | false | arrived |  | 0.0 | `frame_time_budget` skip reason |

## Screenshot And Trace Evidence

Captured files:

- `player_pov_start.png`
- `player_pov_intro_door_before_click.png`
- `player_pov_intro_dialogue_open.png`
- `player_pov_dialogue_acknowledged.png`
- `player_pov_after_mira_home.png`

The final visual capture is player POV while the trace reports Mira's strict-home failure. The failure evidence is therefore a combination of headed player-derived capture plus the live NPC state snapshot from the same run. Phase 2+ should improve the acceptance runner so future matrix checkpoints include clearer direct NPC-facing visual captures for each claimed NPC state.

## Known Failures

- Mira does not reach strict interior after the knock in this real-boot matrix run.
- The old route stack reports a queued/pending home route while the actor is on the door cell with occupied door threshold/sweep.
- The morning job/forage matrix is not reached, so this run does not prove or disprove Niko, Rowan, or guard behavior after sleep.

## Next Phase Allowed

Yes, for Phase 2 only.

Reason: Phase 1's exit gate requires an honest real-boot autonomy matrix failure tracked in Linear. This run gives that red gate without pathfinding repair, named-NPC special casing, direct tutorial progression calls, gameplay flags, or metadata-only success. The next work must lock down route-state writers before building or migrating a replacement authority.
