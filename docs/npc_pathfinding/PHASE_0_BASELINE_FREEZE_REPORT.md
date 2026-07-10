# Phase 0 Baseline Freeze And Work Intake Report

## Phase

Phase 0 - Baseline Freeze And Work Intake

## Branch

`codex/npc-pathfinding-replacement`

## Linear

- Parent: `VOX-29` - Replace NPC pathfinding with one collision-backed route authority
- Active phase: `VOX-30` - Phase 0: Baseline freeze and work intake
- Queued phases: `VOX-31` through `VOX-41`

## Documents Re-Read

- `AGENTS.md`
- `manifesto.md`
- `CODEX_NPC_PATHFINDING_REPLACEMENT_PHASE_PLAN.md`
- `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`
- `CODEX_MATURE_NAV_PLAN.md`
- `NPC_PATHFINDING_REGRESSION_HANDOFF.md`

## Current Worktree

Current branch was created from commit:

```text
793e0de5f4b29a041f6ffc025f8e21c8dcefe9d1
```

Dirty worktree at intake:

```text
 M scripts/NpcSystem.gd
 M scripts/TitleMenu.gd
 M scripts/npc_ai/interactions/DoorTraversalExecutor.gd
 M scripts/npc_ai/movement/NpcRouteMovementController.gd
 M scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd
 M scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd
?? CODEX_NPC_PATHFINDING_REPLACEMENT_PHASE_PLAN.md
?? manifesto.md
?? scenes/testing/npc/NpcActualGameplayMiraPorchRegressionTest.tscn
?? scripts/testing/npc/NpcActualGameplayMiraPorchRegressionRunner.gd
?? scripts/testing/player/
?? tools/npc/run-actual-gameplay-mira-porch-regression.ps1
?? tools/npc/run-real-tutorial-playthrough-no-flags.ps1
```

No pathfinding repair work was performed during this phase intake.

## Save Preservation

Before running the strict real-boot baseline, existing Godot user saves were backed up under:

```text
artifacts/npc/save-backups/phase0-realboot
```

The baseline intentionally used the runner's `-RealBoot` mode, which removed `VOXEL_SAVE_PATH_OVERRIDE` to observe the normal boot path.

## Baseline Command

```powershell
.\tools\npc\run-actual-gameplay-mira-porch-regression.ps1 -RealBoot -ReportPath artifacts\npc\reports\phase0-actual-gameplay-mira-realboot-baseline.json -ProgressPath artifacts\npc\progress\phase0-actual-gameplay-mira-realboot-baseline.txt -ScreenshotDir artifacts\npc\screenshots\phase0-actual-gameplay-mira-realboot-baseline -TimeoutSeconds 300 -StaleProgressSeconds 90
```

## Baseline Artifacts

- Report: `artifacts/npc/reports/phase0-actual-gameplay-mira-realboot-baseline.json`
- Progress: `artifacts/npc/progress/phase0-actual-gameplay-mira-realboot-baseline.txt`
- Screenshots: `artifacts/npc/screenshots/phase0-actual-gameplay-mira-realboot-baseline`

Screenshots saved:

```text
gameplay_start_before_door_walk.png
menu_before_new_game.png
observer_mira_post_knock_final_state.png
player_pov_dialogue_acknowledged.png
player_pov_intro_dialogue_open.png
player_pov_intro_door_before_click.png
player_pov_mira_post_knock_final_state.png
```

## Baseline Result

```text
testId: npc_actual_gameplay_mira_porch_regression
passed: true
failureCount: 0
bootedSeed: atlas-27175369
actualGameplayDerived: true
realBootAttachedToMainMenu: true
launchPath: project main scene MainMenu.tscn New Game button input
usesVoxelPlaytest: false
VOXEL_PLAYTEST: blank
VOXEL_TEST_SEED: blank
VOXEL_SAVE_PATH_OVERRIDE: blank
wrapperRealBoot: true
wrapperRemovedSavePathOverride: true
miraLeftPlayerPorch: true
miraReachedStrictHome: true
miraTotalFlatDistance: 78.916
miraMaxPlayerPorchDistance: 52.256
processExitCode: 0
processStopReason: report_finished
```

## Observed NPC Matrix

Phase 0 has only a narrow Mira post-knock baseline, not the required full town autonomy matrix.

| Checkpoint | NPC | Visible/Reported State | Route/Behavior Evidence | Outcome |
| --- | --- | --- | --- | --- |
| Post-knock observation | Mira | Left player porch and reached strict home interior | `miraLeftPlayerPorch=true`, `miraReachedStrictHome=true`, `miraTotalFlatDistance=78.916` | Passed narrow gate |

## Limitations

This is not Phase 1 acceptance. It does not prove:

- next-morning NPC autonomy;
- Niko foraging;
- Rowan leaving home or working;
- guards guarding;
- non-guards returning indoors across a full schedule;
- a single route authority;
- collision-probe-before-commit behavior.

The next allowed implementation step is Phase 1 only: create the real-boot NPC autonomy matrix. Do not begin route-state lockdown or `NpcRouteAuthorityV2` implementation until Phase 1 fails honestly and is recorded in Linear.

## Next Phase Allowed

Yes, Phase 1 may begin after `VOX-30` is updated with this report and evidence.
