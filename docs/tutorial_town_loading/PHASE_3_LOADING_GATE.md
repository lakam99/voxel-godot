# Phase 3 Startup Loading Gate

## Objective

Prevent normal New Game and Continue gameplay from enabling input or actor physics until the tutorial scenario, generated-town manifest, required doors, tutorial NPC registrations, VoxelTerrain collision, navigation changes, navigation tiles, navigation map, and initial navigation snapshot are ready.

This phase follows Phase 3 of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`. Tutorial actors still use the legacy profile/home assignment pass until Phase 4, and tutorial movement holds remain until Phase 5.

## Branch And Commit

- Branch: `codex/vox-73-startup-readiness-gate`
- Implementation commit: `2bf760c` (`Gate gameplay on tutorial town readiness`)
- Linear: `VOX-73`

## Production Contract

`TutorialSystem.start_new_world_staged()` and `complete_restore_world_staged()` now return structured `ready`, `pending`, or `failed` results. The shared staged preparation flow:

1. derives semantic tutorial requirements;
2. requests and polls the `StructureSystem` manifest under bounded operation and time budgets;
3. rejects missing or invalid home and door records;
4. builds tutorial scene elements only after manifest readiness;
5. registers tutorial NPCs and validates their required records;
6. returns a structured result to `MainCore`.

`MainCore._run_deferred_startup_boot()` then gates production gameplay on:

- tutorial-world readiness;
- required VoxelTerrain chunks;
- collision-backed publication for the player and required startup chunks;
- drained navigation-change events;
- required navigation tile publication;
- synchronized navigation map state;
- initial navigation snapshot readiness;
- a final physics gate proving the player and registered NPCs remained disabled during loading.

Failure records are retained in `startup_loading_failure_result`, emitted through `startup_loading_failed`, and shown by the existing title-menu loading UI. Failed startup does not emit `startup_loading_completed` and does not enable gameplay.

Diagnostic fast boot remains explicitly marked `excluded` from gameplay acceptance and keeps player/NPC physics disabled.

## Terrain Reset Repair

An in-session New Game previously deleted and recreated the VoxelTerrain runtime. That produced long frames, stale native tasks, RID errors, and nondeterministic collision publication.

The production reset now preserves both `VoxelTerrainRuntime` and the native `VoxelTerrain` node. It disables viewer requirements, invalidates old collision/navigation publications, assigns the new deterministic generator in place, resets bounded publication tracking, and then reenables loading.

The recurrent sequence `atlas-1492` to `atlas-89112822` exposed two additional collision-readiness defects:

- publication processed the same first dictionary entries every frame and starved later ready chunks;
- smooth VoxelTerrain colliders were rejected by a heightfield comparison even when every live collision probe hit the authoritative collider.

Publication now uses a fair FIFO queue. A required chunk becomes collision-ready only when the native mesh area exists and every probe hits the `VoxelTerrain` collider. Heightfield deltas remain diagnostic; they are not a competing terrain oracle.

Final reset evidence preserved both instance IDs, republished 9/9 required collision chunks, and reported:

```text
resetMode: in_place_generator_reload
resetMapUsec: 709
previousPublishedMeshBlocks: 431
invalidatedGameplayChunks: 10
terrainInstancePreserved: true
```

## Test Coverage

### Readiness Contracts

```powershell
.\tools\run-startup-loading-readiness-contract-tests.ps1 `
  -ReportPath artifacts\test-runners\startup-loading-readiness-contract.json
```

Result: 6 passed, 0 failed. This includes forced missing-manifest failure, missing NPC registration, Continue parity, and fail-closed gameplay physics.

```powershell
.\tools\run-structure-town-manifest-contract-tests.ps1 `
  -ReportPath artifacts\test-runners\structure-town-manifest-contract.json

.\tools\run-town-runtime-manifest-contract-tests.ps1 `
  -ReportPath artifacts\test-runners\town-runtime-manifest-contract.json
```

Results: 10/10 and 11/11 passed. Ready manifests report `pendingOpCount: 0`, one generation attempt, and all required semantic keys published.

### Production Scene Smokes

```powershell
.\tools\run-main-menu-startup-readiness-smoke.ps1 `
  -ReportPath artifacts\test-runners\main-menu-startup-readiness-smoke.json

.\tools\run-main-menu-continue-readiness-smoke.ps1 `
  -ReportPath artifacts\test-runners\main-menu-continue-startup-smoke.json

.\tools\run-main-menu-startup-readiness-smoke.ps1 `
  -RuntimeReset -Visible -TestSeed atlas-1492 `
  -ReportPath artifacts\test-runners\main-menu-runtime-reset-smoke.json
```

| Run | Result | Startup/act time | Longest loading step | Domains | NPCs | Collision |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| New Game | Passed | 61.96 s | 17.24 s | 19 | 6 | 9/9 |
| Continue | Passed | 86.16 s | 24.27 s | 19 | 6 | 9/9 |
| Known-seed runtime reset | Passed | 85.04 s reset act | 18.16 s initial startup | 15 reset domains | 6 | 9/9 |

The Phase 2 clean baseline longest startup step was 20.27 seconds. New Game and the known-seed reset remained below it. Continue observed 24.27 seconds in the existing synchronous tutorial-light construction step; duplicated light rigs and that variable stall are tracked separately by `VOX-80`.

The Forward+ runtime-reset report completes and passes before Godot later reports navigation RID leaks/access violation during engine shutdown. The wrapper accepts only a passing completed reset report plus the exact known `NavRegion3D` and `NavMap3D` leak signature, reports the engine exit code, and links it to `VOX-66`. Any other nonzero engine exit still fails.

### Collision And NPC Regressions

```powershell
.\tools\run-voxel-terrain-collision-publication.ps1 `
  -ReportPath artifacts\test-runners\voxel-terrain-collision-publication.json
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both `
  -ReportPath artifacts\test-runners\npc-contract-vox73.json
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both `
  -ReportPath artifacts\test-runners\npc-route-vox73.json
.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both `
  -ReportPath artifacts\test-runners\npc-door-vox73.json
```

Results:

- VoxelTerrain collision publication: 6/6 passed, including 5/5 live collider hits and navigation publication after collision.
- NPC contract: 74 runs, 214 assertions, 0 failures.
- NPC route: 110 runs, 258 assertions, 0 failures.
- NPC door: 48 runs, 88 assertions, 0 failures.
- Compile smoke: passed.
- Evidence-registry self-test: 3/3 passed.

## Broad Integration Result

`tools/run-playtest.ps1` did not complete within the external 15-minute limit. It wrote 125 results before the process remained alive in the Voxel Tools lifecycle path. One earlier assertion failed:

```text
settings_runtime_controls: fov 84.0, sens 0.0035, particles 0.25,
hud 1.4, render 2, chunks 0
```

The check still treats the retired legacy `chunks` dictionary as the render-distance oracle. Later terrain, generic NPC home/job, foraging, door, structural-integrity, and landmark checks passed. `VOX-81` tracks migration of that assertion to authoritative VoxelTerrain viewer/runtime coverage. `VOX-66` tracks the long-running task drain and shutdown lifecycle. Neither failure is hidden or claimed green here.

## Determinism

```powershell
.\tools\run-world-signature.ps1 `
  -OutputPath artifacts\world-signature\latest\atlas-1492-vox73-final.json
```

The standard command remains red against the already stale tracked baseline under `VOX-79`. The generated Phase 3 output is byte-identical to the established current Phase 1/2 output:

```text
SHA-256: CB567F741495CD62748CF1EC6B0B75A7795537CC22EE48B495593D7E7B7B8D5F
```

No baseline was weakened or updated.

## Residual Phase Scope

- Phase 4 owns manifest-derived tutorial profiles before spawn and removal of runtime home refresh/fallback assignment.
- Phase 5 owns removal of intro-specific holds and combined Mira release APIs in favor of generic orders.
- Phase 6 owns additive save/Continue compatibility for those ordinary profiles and orders.
- Phase 7 owns unflagged headed live acceptance; this phase makes no live Mira return-home claim.
- `VOX-66`, `VOX-79`, `VOX-80`, and `VOX-81` remain separately tracked and visible.

## Exit Decision

- Incomplete manifest can enable gameplay: no
- Forced missing manifest produces structured visible failure: yes
- Successful manifest has pending operations: no
- Player/NPC physics begins before readiness: no
- New Game startup introduced a longer single-frame step than Phase 2: no
- Continue variable tutorial-light stall tracked separately: yes, `VOX-80`
- Phase 3 startup-readiness gate: passed
- Next sequential phase: Phase 4, `VOX-74`
