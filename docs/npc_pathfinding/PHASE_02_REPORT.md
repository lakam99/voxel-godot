# Phase 02 Report - Shared Character Motor and CharacterBody3D NPC Migration

## 1. Phase Identification

- Phase: 02 - Shared Character Motor and `CharacterBody3D` NPC Migration
- Branch: `npc-pathfinding/phase-02-physics-motor`
- Base commit before Phase 02 branch changes: `cf32f83ca0d11ff5f8f0256ea3fb6da3d67a6938`
- Branch implementation commit: pending at report creation
- Merge commit: pending at report creation
- Date: 2026-06-25
- Controlling specification: `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`
- Scope status at report creation: branch implementation gates passed; post-merge `master` gate pending until after the branch commit and non-fast-forward merge.

## 2. Objective

Phase 02 ends transform-driven normal NPC route movement and establishes a shared physical motor used by the player and active NPCs. The legacy route planner remains as a one-way steering-intent producer during this phase, but physical displacement is now owned by a `CharacterBody3D` motor path.

## 3. Pre-Phase State

- `git status --short` before Phase 02 edits showed one pre-existing modified tracked baseline: `artifacts/baselines/world-signature/atlas-1492.json`.
- That baseline artifact remained outside the Phase 02 staged scope.
- The legacy route stack was still present from Phase 01 and was expected to remain as a compatibility adapter for this phase.

## 4. Implementation Summary

Phase 02 adds the shared character motor contracts and runtime motor:

- `scripts/npc_ai/contracts/CharacterMotorProfile.gd`
- `scripts/npc_ai/contracts/CharacterMotorCommand.gd`
- `scripts/npc_ai/contracts/CharacterMotorState.gd`
- `scripts/npc_ai/motor/CharacterMotor3D.gd`

`CharacterMotor3D` owns horizontal requested velocity, gravity, jump state, floor snap, terrain grounding assists, and post-physics state. Horizontal movement uses Godot collision movement through `move_and_slide()` and collision-safe correction through `move_and_collide()`.

`PlayerController.gd` now builds `CharacterMotorCommand` instances and applies the shared motor while keeping camera, automated input, survival, and visual responsibilities in the player controller.

NPC runtime bodies now use `CharacterBody3D`:

- `scenes/npc/NpcAgent.tscn`
- `scripts/npc_ai/NpcAgent.gd`
- `NpcSystem.create_npc_body()`
- town NPC spawning
- tutorial NPC spawning
- story/playtest NPC fixtures

`NpcMotionController.gd` is the Phase 02 compatibility adapter. It consumes the legacy route candidate, converts it to a requested velocity, invokes `CharacterMotor3D`, and reports actual post-physics displacement back to `NpcLocomotionController.gd`. `NpcLocomotionController.gd` no longer assigns route-progress transforms.

`NpcSafePlacementService.gd` is the only production NPC body placement API. It is used for spawn/load-style placement, validates the profile capsule through a shape query, and reports rejection instead of placing an NPC inside blocking geometry.

## 5. Collision Layer And Mask Notes

Phase 02 centralizes NPC collision constants in `scripts/npc_ai/NpcConstants.gd`:

- `COLLISION_WORLD_QUERY = 1`
- `COLLISION_TERRAIN_BODY = 2`
- `COLLISION_NPC_BODY = 4`
- `COLLISION_NONBLOCKING_PATH = 8`
- `COLLISION_NPC_BODY_MASK = 1 | 2 | 4`
- `COLLISION_NPC_SAFE_PLACEMENT_MASK = 1 | 2 | 4`

The broad playtest exposed a parity bug: tutorial Sera's escort route treated `cobblestonePath` and `torch` blocks as decorative/nonblocking, but the migrated `CharacterBody3D` NPC still physically collided with tutorial torches on the world/block layer. `MainChunkTerrain.create_block()` now assigns both `cobblestonePath` and `torch` to `COLLISION_NONBLOCKING_PATH`, which remains excluded from NPC body, static-query, and safe-placement masks. A focused regression, `npc_motor_decorative_path_torch_nonblocking_mask`, covers this.

## 6. Telemetry

The motor adapter writes the required per-body telemetry:

- `npc_requested_velocity`
- `npc_applied_velocity`
- `npc_blocked_contact`
- `npc_last_displacement`
- `npc_terrain_grounded`
- `npc_jump_snap_time`

`NpcAutonomySystem.record_motion()` records bounded motor telemetry and increments counters for frames and blocked contacts.

The broad playtest rescue assertion now also reports motor telemetry for Sera. The branch all-runner playtest evidence showed Sera moved `12.75` units, route status `moving/`, requested velocity `(15.04,0.00,-16.00)`, applied velocity `(15.04,0.00,-16.00)`, and no overlap.

## 7. Static Audit

### Normal NPC Movement Transform Writes

Command:

```powershell
rg -n 'body\.global_position\s*=|\.global_position\s*=.*target|move_npc\(|apply_npc_route_motion|move_and_slide|move_and_collide' scripts\NpcSystem.gd scripts\npc_nav\NpcLocomotionController.gd scripts\npc_ai\NpcMotionController.gd scripts\npc_ai\motor\CharacterMotor3D.gd scripts\npc_ai\NpcSafePlacementService.gd
```

Evidence:

- `scripts\npc_ai\NpcSafePlacementService.gd:25`: `body.global_position = position`
  - Classification: allowed spawn/load-style safe placement only.
  - Validation path: `place_spawn()` calls `validate_capsule()` before assignment; `validate_capsule()` uses `PhysicsShapeQueryParameters3D.intersect_shape()` with `COLLISION_NPC_SAFE_PLACEMENT_MASK`.
- `scripts\npc_ai\motor\CharacterMotor3D.gd:42`: `body.move_and_slide()`
  - Classification: required normal physical movement.
- `scripts\npc_ai\motor\CharacterMotor3D.gd:141`: vertical `move_and_collide()`
  - Classification: collision-safe vertical grounding correction.
- `scripts\npc_ai\motor\CharacterMotor3D.gd:147`: horizontal `move_and_collide()`
  - Classification: collision-safe rejection/correction for terrain assists; no direct transform write.
- `scripts\npc_nav\NpcLocomotionController.gd:137-138`: delegates candidate movement to `apply_npc_route_motion()`.
- `scripts\NpcSystem.gd:997-1000`: delegates route motion to `NpcMotionController`.

No production normal NPC route motion assignment to `position`, `global_position`, or `transform` remains in the route movement path.

### NPC StaticBody3D Audit

Command:

```powershell
rg -n 'StaticBody3D' scripts scenes -g 'Npc*.gd' -g 'Tutorial*.gd' -g 'npc_ai/**/*.gd' -g 'npc_nav/**/*.gd' -g 'PlaytestRunner.gd' -g 'testing/npc/**/*.gd' -g 'story/testing/**/*.gd' -g 'npc/**/*.tscn'
```

Classification:

- `scripts\TutorialRescueSystem.gd:177`: hostile rescue enemies from `HostileSystem.spawn_enemy()`, not NPC bodies.
- `scripts\NpcNavigationTestRunner.gd:673`: hostile test fixture, not an NPC body.
- `scripts\PlaytestRunner.gd`: blocks, doors, props, terrain, hostiles, and generated visual fixtures only.
- `scripts\story\testing\StoryPlaytestRunner.gd:643`: story shrine fixture, not an NPC body.
- `scenes\npc\NpcAgent.tscn`: `CharacterBody3D`.
- `scripts\NpcSystem.gd:279-283`: `create_npc_body()` instantiates `NpcAgent.tscn` or `NpcAgent.gd`, both `CharacterBody3D`.
- `scripts\TutorialSceneBuilder.gd:204-219`: tutorial NPCs are created through `NpcSystem.create_npc_body()` and placed through `safe_place_npc()`.

No production NPC body remains `StaticBody3D`.

### Spawn Path Audit

Command:

```powershell
rg -n 'CharacterBody3D|NpcAgent|create_npc_body|register_npc|safe_place_npc' scripts\NpcSystem.gd scripts\TutorialSceneBuilder.gd scripts\TutorialRescueSystem.gd scripts\PlaytestRunner.gd scripts\story\testing\StoryPlaytestRunner.gd scripts\testing\npc\NpcAutonomyTestRunner.gd scenes\npc -g '*.gd' -g '*.tscn'
```

Evidence:

- `scripts\NpcSystem.gd:279-292`: NPC body factory and safe placement wrapper.
- `scripts\NpcSystem.gd:343-359`: town NPC spawn path uses `create_npc_body()`, `safe_place_npc()`, then `register_npc()`.
- `scripts\TutorialSceneBuilder.gd:204-228`: tutorial NPC spawn path uses `create_npc_body()`, `safe_place_npc()`, then `register_npc()`.
- `scripts\PlaytestRunner.gd:4604-4612`: pathing playtest NPC uses `create_npc_body()`, `safe_place_npc()`, then `register_npc()`.
- `scenes\npc\NpcAgent.tscn:5`: node type is `CharacterBody3D`.

## 8. Branch Test Evidence

Focused and compatibility gates run on branch `npc-pathfinding/phase-02-physics-motor`:

| Command | Result | Evidence |
| --- | --- | --- |
| `.\tools\npc\run-npc-motor-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\motor-both.json`; 36 results, 0 failures, 88 assertions |
| `.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\contract-both.json`; 40 results, 0 failures, 110 assertions |
| `.\tools\run-npc-navigation-tests.ps1` | Pass | `npc-navigation-report.json`; 11 results, 0 failures |
| `.\tools\run-playtest.ps1` | Pass | `playtest-report.json`; 181 results, 0 failures |
| `.\tools\run-all-test-runners.ps1` | Pass | `artifacts\test-runners\all-test-runners-report.json`; 7 runners, 0 failures |

Repository-wide branch all-runner details:

| Runner | Result | Duration |
| --- | --- | ---: |
| `npc_focused` | Pass | 2.378s |
| `npc_navigation_legacy` | Pass | 89.087s |
| `playtest` | Pass | 209.037s |
| `story_playtest` | Pass | 59.394s |
| `world_signature` | Pass | 14.013s |
| `visual_captures` | Pass | 51.200s |
| `visual_manifest` | Pass | 0.092s |

## 9. Gate Matrix

| Phase 02 gate | Status | Evidence |
| --- | --- | --- |
| All active NPC bodies are `CharacterBody3D` | Pass | `NpcAgent.tscn`, `NpcSystem.create_npc_body()`, spawn path audit |
| Normal NPC route motion uses shared motor and collision movement | Pass | `NpcMotionController.apply_route_motion()` -> `CharacterMotor3D.apply()` -> `move_and_slide()` |
| No penetration through required blockers observed | Pass | motor day/night suite and legacy navigation runner |
| No stuck recovery teleports | Pass | `npc_motor_no_unstick_teleport`; static audit |
| Player characterization remains within tolerance | Pass | `npc_motor_player_characterization_*`; `npc_contract_player_motor_characterization_baseline`; broad player movement tests |
| Existing NPC focused tests remain green | Pass | contract, motor, and legacy navigation reports |
| Broad behavior tests remain green | Pass | `playtest-report.json`; 181/181 pass |
| Day/night motor matrix passes | Pass | `motor-both.json`; 36/36 pass |
| Full all-runner passes on branch | Pass | `all-test-runners-report.json`; 7/7 pass |
| Full all-runner passes on merged `master` | Pending | Must run after branch commit and non-fast-forward merge |

## 10. Review Questions

### Is physics now the final authority for NPC displacement?

Yes for active NPC route movement in Phase 02 scope. The legacy route follower supplies a candidate, but `NpcMotionController` converts that candidate into a requested velocity and uses `CharacterMotor3D`; arrival/progress consumes actual post-physics body position.

### Are all NPC spawn paths migrated, including tutorial and tests?

Yes for production town/tutorial/story/playtest NPC paths audited in this phase. Hostiles and props may still be `StaticBody3D`; they are not NPC bodies.

### Did player feel remain stable?

Player movement constants remain covered by focused characterization tests and broad movement cases. The broad playtest passed `player_movement`, terrain ascent/descent, steep ascent blocking, airborne obstacle blocking, jump, and interaction cases.

### Are collision masks centralized and explained?

Yes. NPC body, safe-placement, static-query, terrain, and decorative/nonblocking path layers are declared in `NpcConstants.gd`. The decorative path/torch fix is covered by `npc_motor_decorative_path_torch_nonblocking_mask` and by the passing broad rescue mission.

## 11. Follow-Up Required Before Phase 03

- Commit this branch implementation and report.
- Merge `npc-pathfinding/phase-02-physics-motor` into `master` with `--no-ff`.
- Rerun `.\tools\run-all-test-runners.ps1` on `master`.
- Record the post-merge gate result before starting Phase 03.
