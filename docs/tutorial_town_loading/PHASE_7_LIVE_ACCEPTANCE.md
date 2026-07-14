# Phase 7: Live Acceptance and Performance

## Objective

Complete Phase 7 of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`: prove that a production Main Menu -> New Game/Continue tutorial publishes the required town artifact before play, acknowledges the visible knock interaction promptly, retains an ordinary generic `go_home` order, and lets an ordinary production NPC leave the player porch, traverse a collision-backed generated-world route and door, reach a strict home interior, clear the threshold, and close the door. Also close the normal-runtime performance blockers that could amplify route latency.

## Branch and implementation commit

- Branch: `codex/vox-77-live-acceptance-performance`
- Implementation commit: `df9f700` (`Complete tutorial town live acceptance and runtime gates`)
- Linear phase issue: `VOX-77`
- Parent issue: `VOX-21`

## Changed files

The implementation commit contains 56 scoped files. The principal production changes are:

- `scripts/NpcSystem.gd`, `scripts/npc_ai/NpcAutonomySystem.gd`, `scripts/npc_ai/NpcBrainScheduler.gd`, `scripts/npc_ai/behavior/NpcPlanExecutor.gd`, and `scripts/npc_ai/routing/NpcRouteAuthorityV2.gd`: bounded, fair physics-owned route servicing and generic scripted-order timing/state telemetry.
- `scripts/npc_ai/routing/CollisionBackedRouteSubstrate.gd` and `CollisionProbeService.gd`: retained incremental search/probe progress and collision-backed repair for live dynamic actor blockers.
- `scripts/TutorialSystem.gd`, `TutorialSceneBuilder.gd`, `MainCore.gd`, `MainSetupScene.gd`, and `MainChunkTerrain.gd`: loading/readiness handoff, generated town/NPC publication, and staged startup/runtime work.
- `scripts/TerrainMeshingService.gd`, `TerrainVolumeService.gd`, `scripts/terrain/VoxelTerrainRuntime.gd`, `VoxelTerrainGenerator.gd`, `VoxelWorldGenerationContext.gd`, and `native/terrain_meshing/src/terrain_meshing_backend.{h,cpp}`: bounded terrain/fluid payload and worker work needed to pass the normal runtime gate.
- `scripts/HostileSystem.gd`, `MainPlaytestTools.gd`, `MainRuntimeTools.gd`, and `scripts/testing/NormalRuntimePerformancePassRunner.gd`: bounded hostile work and accountable normal-runtime instrumentation.
- `scripts/testing/npc/NpcActualGameplayMiraPorchRegressionRunner.gd`, `NpcRealTutorialPlaythroughRunner.gd`, `NpcTutorialSaveContinueRunner.gd`, `scripts/testing/player/*`, and `tools/npc/*`: guarded live MainMenu runners, visible-input navigation, two-process Continue coverage, dual-clock latency, loading/door screenshots, and prohibited-shortcut audits.
- Focused contract/test additions: `scripts/testing/TerrainBlockLightBatchContractRunner.gd`, `TerrainMeshingBoundsContractRunner.gd`, their PowerShell wrappers, updated NPC cases, and `tools/test-runner-registry.json`.
- `docs/tutorial_town_loading/PHASE_6_SAVE_CONTINUE_COMPATIBILITY.md`: documents that the headed Continue runner requires `-Visible`.

Generated `.import`/`.uid` files, the test-mutated `atlas-1492` world-signature baseline, line-ending-only files, and the obsolete interim latency note were deliberately excluded from the commit.

## Key decisions

1. Tutorial identity remains scenario/presentation data. The tutorial orchestration submits the same generic `wait` and `go_home` orders used by ordinary NPCs; route readiness, collision proof, motor execution, door ownership, arrival, and recovery remain generic authority.
2. Route work is physics-owned and globally bounded. Urgent work cannot consume the whole per-frame budget; ordinary requests retain deterministic service.
3. A live dynamic `CharacterBody3D` collision certificate may enter the existing bounded collision-backed repair path. It never becomes a ready route without a replacement route and a new clear physical probe.
4. Live acceptance uses uncapped production MainMenu processes, visible viewport input, random production seeds, real `CharacterBody3D` actors, real generated homes/doors, and real physics. No `VOXEL_PLAYTEST`, `VOXEL_TEST_SEED`, gameplay god mode, fixed post-load wait, teleport, direct tutorial progression, direct NPC movement, or metadata-only success is accepted.
5. Continue uses an isolated save path only to protect player data. The first process performs production New Game and `SaveSystem` persistence; a second production process selects visible Continue.
6. The Phase 7 loading screenshot is captured on the frame that actually renders `Gameplay prerequisites ready`, before the overlay disappears.

## Verification commands and results

### Focused support matrix

These are compile/contract/synthetic support and are not cited as live gameplay acceptance.

| Command | Report | Result |
| --- | --- | --- |
| `.\tools\run-project-compile-smoke.ps1` | console report | Passed |
| `.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both` | `artifacts/npc/reports/contract-both.json` | Passed: 82 runs, 240 assertions |
| `.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both` | `artifacts/npc/reports/route-both.json` | Passed: 126 runs, 316 assertions |
| `.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both` | `artifacts/npc/reports/door-both.json` | Passed: 48 runs, 88 assertions |
| `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both` | `artifacts/npc/reports/behavior-both.json` | Passed: 72 runs, 179 assertions |
| `.\tools\npc\run-npc-streaming-save-tests.ps1 -TimeMode Both` | `artifacts/npc/reports/streaming_save-both.json` | Passed: 40 runs, 92 assertions |

### Three fresh headed New Games

Each command used `run-actual-gameplay-mira-porch-regression.ps1 -RealBoot` with a unique report/progress/screenshot path and a 360-second watchdog. The wrapper ran `assert-npc-acceptance-runner-clean.ps1` before Godot.

| Report | Random seed | Command/route service | First displacement | Porch clear | Final state |
| --- | --- | ---: | ---: | ---: | --- |
| `artifacts/npc/reports/phase7-new-game-1.json` | `atlas-13818116` | 0.000s / 0.000s | 0.656s | 2.269s | strict interior; door closed |
| `artifacts/npc/reports/phase7-new-game-2.json` | `atlas-54871377` | 0.000s / 0.000s | 0.485s | 2.045s | strict interior; door closed |
| `artifacts/npc/reports/phase7-new-game-3.json` | `atlas-96836347` | 0.000s / 0.000s | 0.622s | 2.277s | strict interior; door closed |

All three reports are `actualGameplayDerived`, attach to the real MainMenu, dispatch visible New Game/door/dialogue input, retain the generic order, and show 76.471-79.167m of ordinary movement. The worst first route/displacement and porch-clearance values pass the plan's `<1s` and `<5s` gates. Final observer screenshots were inspected and show Mira inside the generated home. These compact runs prove prompt departure and strict arrival; the full run below supplies the complete visible home-door sequence.

The prior user-observed slow run did not preserve a seed, so there was no honest known seed to replay. No fixed seed was substituted and represented as known-seed evidence.

### Headed two-process Continue

Command:

```powershell
.\tools\npc\run-tutorial-save-continue-playtest.ps1 -Visible `
  -ReportPath artifacts\npc\reports\phase7-save-continue.json `
  -SavePathOverride artifacts\npc\saves\phase7-save-continue.json `
  -NoFlagsProofPath artifacts\npc\reports\phase7-save-continue-proof.json `
  -TimeoutSeconds 360
```

Result: passed on `atlas-45387755`. The first process selected visible New Game, performed the visible knock/dialogue flow, and persisted through the production save system. The second process visibly offered and selected Continue, restored generic order kind `go_home` with `usesRouteStack: true`, cleared the porch in 0.562s, reached strict interior, and ended with the generated home door closed. Report: `artifacts/npc/reports/phase7-save-continue.json`. Key screenshots: `menu_before_continue.png` and `observer_continue_mira_final_state.png` under `artifacts/npc/screenshots/tutorial-save-continue-stage-continue/`.

### Full unflagged tutorial

Command:

```powershell
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -Visible `
  -ReportPath artifacts\npc\reports\phase7-full-tutorial.json `
  -ProgressPath artifacts\npc\progress\phase7-full-tutorial.txt `
  -ScreenshotDir artifacts\npc\screenshots\phase7-full-tutorial `
  -NoFlagsProofPath artifacts\npc\reports\phase7-full-tutorial-proof.json `
  -TimeoutSeconds 720
```

Final result: passed on fresh random seed `atlas-57948400`, 0 failures, clean report-driven shutdown.

- Real production MainMenu and visible New Game input: yes.
- `VOXEL_PLAYTEST`, `VOXEL_TEST_SEED`, save override, and gameplay god mode: absent.
- Fixed post-load wait frames: 0. Forced post-menu chunk refresh: false.
- Generic order accepted promptly; first visible motion: 0.406s; player-porch clearance: 1.494s.
- Total flat movement: 79.820m; maximum observed walking speed: 2.530m/s.
- Collision-backed route and active generated-door portal observed.
- Final cell is within strict generated interior bounds, past the door plane, off porch/door cells, with threshold, sweep, and clearance volumes unoccupied.
- The home door is captured closed before approach, open before/crossing, and closed after clearance.
- Repair, blocked pre-repair sleep, morning transition, non-guard home behavior, and ordinary Niko forage behavior all passed in the same uninterrupted run.

Inspected screenshots in `artifacts/npc/screenshots/phase7-full-tutorial/`:

1. `phase7_menu_before_new_game.png` - production menu and visible New Game.
2. `phase7_loading_gameplay_prerequisites.png` - loading overlay visibly renders `Gameplay prerequisites ready`.
3. `player_pov_dialogue_acknowledged.png` - visible knock acknowledgement.
4. `mira_route_departure.png` - Mira leaving the player porch.
5. `mira_at_home_door.png` - generated home approach with door closed.
6. `mira_home_door_open.png` - door open before/during crossing.
7. `mira_inside_home_closed_door.png` - Mira past the door plane in strict interior after closure.
8. `player_pov_after_morning_forager_observation.png` - later tutorial/NPC behavior remains live.

The screenshots are backed by `miraRouteOrderTimeline`, door portal samples, collision-proof data, strict-interior bounds, and normal input timelines. The test does not directly call tutorial handlers, `interact_with`, `on_door_opened`, `sleep_at_bed`, `move_npc`, route/door service helpers, or metadata success markers.

### Normal runtime performance

Command:

```powershell
.\tools\run-normal-runtime-performance-pass.ps1 `
  -ReportPath artifacts\performance\vox66-release-acceptance.json
```

Result: passed on fresh seed `atlas-95247600` through production MainMenu -> visible New Game. The run covered 810.124m of sprint traversal, eight direction changes, and eleven observed jumps. Frame p50/p95/p99/max were 10.047/16.688/20.642/27.160ms; terrain queue and worker/payload maxima were 5.935/5.829ms; terrain collision holds were zero. The inspected night screenshot is visually coherent with terrain, water, props, lighting, and town structures. This is live normal-runtime performance evidence; the exact terrain/fluid reports remain contract evidence only.

## Artifacts

- Focused reports: `artifacts/npc/reports/{contract,route,door,behavior,streaming_save}-both.json`
- Fresh New Games: `artifacts/npc/reports/phase7-new-game-{1,2,3}.json`
- Continue: `artifacts/npc/reports/phase7-save-continue.json` and `phase7-save-continue-proof.json`
- Full live tutorial: `artifacts/npc/reports/phase7-full-tutorial.json` and `phase7-full-tutorial-proof.json`
- Full live screenshots: `artifacts/npc/screenshots/phase7-full-tutorial/`
- Performance: `artifacts/performance/vox66-release-acceptance.json`
- Supporting exact terrain/fluid contracts: `artifacts/terrain-volume/vox66-exact-generator-kernel-collision.json`, `vox66-exact-generator-save-parity.json`, and the exact fluid payload/mesh reports.

## Risks and limitations

- The known slow manual seed was not recorded. Phase 7 therefore provides three compact fresh New Games, a separate fresh full tutorial, and a fresh Continue seed rather than inventing a known-seed replay.
- The compact porch runner samples starter-door opening and final home state; only the full runner is cited for the complete generated-home door open/cross/close visual sequence.
- Contract/synthetic reports support invariants but are not gameplay acceptance evidence.
- `TerrainMeshingService` currently retains completed worker-bound payload state until lifecycle cleanup to avoid destroying a large Variant graph in a gameplay frame. The release performance run is green, but Phase 8 should either prove this collection is lifecycle-bounded in long sessions or replace it with bounded/incremental retirement.
- Passive bounded stall traces remain useful production diagnostics. Phase 8 must distinguish useful generic release telemetry from temporary acceptance probes before deleting anything.

## Linear status

- `VOX-66`, `VOX-92`, `VOX-104`, and `VOX-105` were closed with their blocker-specific evidence.
- `VOX-77` is Done with the implementation commit and live evidence attached in Linear.
- `VOX-21` remains In Progress until Phase 8 cleanup, release verification, and evidence attachment are complete.
- `VOX-78` is the next sequential issue.

## Next phase allowed

Phase 8 is allowed. Start from merged `master`, create the Phase 8 branch, remove obsolete tutorial-specific privilege/fallback and temporary diagnostics, add static reintroduction guards, rerun the release matrix, write `PHASE_8_RELEASE_REPORT.md`, then close `VOX-78` and `VOX-21` only if the final live evidence remains green.
