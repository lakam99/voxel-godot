# NPC Pathfinding Completion Plan

This plan continues the first-pass NPC navigation redesign without repeating the verification and debugging traps found during implementation.

## Current Evidence

- The composed navigation stack exists under `scripts/npc_nav/`.
- `scripts/NpcPathing.gd` remains the compatibility facade for existing `NpcSystem` calls.
- `scripts/NpcSystem.gd` carries runtime-only route diagnostics and no save-version migration.
- `scripts/PlaytestRunner.gd` currently covers the main route smoke cases.
- `scripts/NpcNavigationTestRunner.gd`, `scenes/NpcNavigationTest.tscn`, and `tools/run-npc-navigation-tests.ps1` provide the focused NPC navigation test loop.
- Latest focused NPC navigation report in this worktree: 11 results, 0 failures. The dedicated two-NPC narrow-door crossing case passes with reservation waits, no shared cell, and post-clearance door close. The dedicated home-return fallback case verifies no timer snap, route waypoint advance, porch advance, and `partial/home_porch_fallback`. The dedicated reachability-goal case verifies wood/stone worker resource anchors, guard hostile-intercept cells, and route-scored wander targets.
- Latest broad playtest command in this worktree: `tools/run-playtest.ps1` exits 0 with 180 results and 0 failures in `playtest-report.json`. Tutorial NPC home/guard behavior, generic NPC jobs, forager inventory/hunger, door open/close smoke, hostile smoke, held-light visual assertions, and `town_exit_slope_apron` all passed. The heavier wall/replan/unreachable NPC route case now runs only in the focused NPC navigation runner.
- `tools/run-world-signature.ps1` exits 0 after accepting the understood terrain-apron prop drift into the tracked baseline. Current and baseline hashes are both `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.
- Clean-HEAD comparison before the baseline update showed the current branch differed only in `props` versus clean HEAD: generated blocks, generated tier counts, loaded chunk keys, structure counts, terrain samples, and town home records matched. The prop delta was clustered around the town slope-apron edge, which is the intentional terrain-generation change.

## Progress Notes

- Phase 1 collision proof has been promoted from grid-only validation to grid footprint plus physics capsule validation for layer-1 static blockers. This intentionally leaves NPC-vs-NPC physical overlap hardening to Phase 3 reservation work.
- Phase 2 scaffolding is in place. The dedicated runner currently covers capsule/static blockers, generic town homes, worker outings, forager harvest/eating, NPC door open/close, wall avoidance, player block route invalidation, and unreachable diagnostics.
- Phase 3 multi-agent reservation hardening is in place. Door reservations persist across frames, active door claims cannot be preempted mid-crossing, lower-priority NPCs yield/back off deterministically, scripted targets use strict target-cell arrival, route-declared doors can be opened by the capsule gate when compressed waypoints would otherwise hit a closed door, and delayed door close now waits for all NPC/player clearance.
- Phase 4 reachability-aware goal selection is in place. Wander targets are route-scored town anchors including paths and utility approaches, workers prefer route-scored resource-appropriate outside prop approaches before generic work anchors, guards choose route-scored guard/intercept cells rather than hostile centers, and unreachable target diagnostics remain exposed through route status/reason.
- Town terrain grading is in place. `base_height_cell` now keeps the town interior flat while applying a cached, height-aware slope apron outside the town radius so cardinal exits grade back toward natural terrain. Broad playtest verifies the forced town exits stay below the NPC slope threshold (`max step 0.72`, limit `1.24` in the latest run).
- Verification cleanup is improved. `tools/run-playtest.ps1` deletes stale report/progress files before launch and exits from the fresh report result when Godot hangs after `get_tree().quit()`.
- The old direct-position fallback movement has been removed from normal NPC movement. `NpcSystem.move_npc(...)` now returns no movement when the composed pathing facade is unavailable, and worker stalls trigger route replanning instead of direct egress nudges.
- Broad NPC route coverage is reduced to smoke checks. The heavier wall/replan/unreachable route assertions remain implemented as a shared helper on `PlaytestRunner.gd`, but `run-playtest.ps1` no longer executes them; `tools/run-npc-navigation-tests.ps1` owns that focused route case.

## Known Lessons

- Do not chase world-signature drift blindly. The current baseline has been updated only after confirming the drift was confined to slope-apron-edge props and that generated blocks, terrain samples, structure counts, loaded chunk keys, and town home records stayed stable.
- Do not add more NPC route scenarios directly into the broad playtest. The broad runner is already a useful smoke gate but is too slow and too brittle for iteration.
- Do not rely on route success alone as collision proof. Movement now uses cell footprint validation plus the physics capsule query in `NpcLocomotionController.gd` before committing `body.global_position`.
- Keep NPC runtime randomness isolated from world generation. Any new NPC choice must use per-NPC deterministic RNG seeded from world seed, NPC id, phase/day context, and goal kind.
- Keep hostiles and wildlife out of the redesign scope until town/tutorial NPC routing has a focused test harness.

## Phase 1: Stabilize Collision Proof

Goal: make "NPCs do not enter blocked space" true beyond grid-cell approximation.

Work:
- Wire `NpcLocomotionController.capsule_hits_obstacle(...)` into `validate_candidate(...)` after footprint checks and before assigning `body.global_position`.
- Confirm the physics query ignores the moving NPC body, open doors, paths, torches, and nonblocking interaction areas.
- Add a narrow test with a wall, fence, window-equivalent block, prop, and door frame where movement is attempted at shallow angles.

Gate:
- NPC movement increments `validatedMoves` only after both footprint validation and physics capsule validation pass.
- No NPC test can place the body center or footprint into a blocked static cell.
- Broad playtest remains green.

Risk Control:
- If the physics query rejects legitimate porch/interior movement, first inspect collision layers/masks and existing overlap allowance. Do not reintroduce teleporting or raw position snapping.

## Phase 2: Create A Dedicated NPC Navigation Runner

Goal: make pathfinding iteration fast and less brittle than the full `PlaytestRunner.gd`.

Work:
- Add `scripts/NpcNavigationTestRunner.gd` and `scenes/NpcNavigationTest.tscn`.
- Add `tools/run-npc-navigation-tests.ps1` using the same bundled Godot executable convention as `tools/run-playtest.ps1`.
- Move the larger route scenarios out of `PlaytestRunner.gd` into the dedicated runner:
  - wall/fence/window/building avoidance;
  - closed door route;
  - two NPCs crossing a narrow doorway/path;
  - night return home/porch without wall snapping;
  - forager target selection, harvest, return, and eating;
  - scripted rescue target routing;
  - player-placed block route invalidation;
  - unreachable route diagnostics;
  - hostile/building/fence collision smoke.
- Keep only compact smoke assertions in `PlaytestRunner.gd`.

Gate:
- Dedicated runner reports each route case separately in JSON.
- `tools/run-npc-navigation-tests.ps1` completes much faster than the full playtest.
- `tools/run-playtest.ps1` still includes broad NPC smoke coverage and passes.

Risk Control:
- Avoid time-based "wait until maybe" loops where possible. Prefer deterministic setup, bounded simulation windows, and route/stat assertions.

## Phase 3: Harden Multi-Agent And Door Reservations

Goal: eliminate doorway/path deadlocks and accidental NPC overlap.

Work:
- Persist door reservations longer than a single frame when an NPC has been granted crossing intent.
- Add deterministic tie-breaking by NPC id, route priority, and wait time.
- Add a small backoff/yield behavior for lower-priority NPCs blocked at the same cell or door.
- Expose route reasons clearly: `door_reserved`, `cell_reserved`, `yielding`, `stuck_replan`, `blocked_dynamic`.

Gate:
- Two NPCs can swap sides of a one-cell doorway/path without overlap, permanent waiting, or clipping through closed doors.
- `reservationWaits` increases during contention, then movement resumes.
- Door closes only after NPC/player clearance.

Risk Control:
- Keep reservations runtime-only. Do not add save fields.

## Phase 4: Make Goal Selection Fully Reachability-Aware

Goal: make NPC purpose visible without raw random wandering.

Work:
- Expand town anchors from porch/guard/path candidates to include market/workstation/utility anchors where available.
- Make workers prefer reachable outside cells matching job type:
  - wood workers near tree/log props;
  - stone workers near rock/ore props;
  - foragers near berry approach cells.
- Make guards prefer reachable guard posts and reachable hostile intercept cells, not direct hostile centers.
- Add route-status fallback behavior for unreachable work/home goals: wait at best safe reachable fallback and expose reason.

Gate:
- Forager, wood, stone, guard, wander, home, and scripted intents all select route-scored targets or explicit fallback cells.
- No goal selection uses raw random world points without reachability scoring.

Risk Control:
- Keep candidate count capped and deterministic. Route-score only the nearest/safest subset to avoid playtest timeouts.

## Phase 5: Clean Up Verification And Baselines

Goal: separate pathfinding verification from unrelated deterministic baseline drift.

Work:
- Keep `WorldSignatureRunner.gd` save-isolated before instantiating `Main.tscn`.
- Only update the world-signature baseline when the current output is understood and intentionally accepted.
- During future pathfinding work, treat world-signature as a regression gate if generated blocks, loaded chunk keys, structure counts, terrain samples, or town home records differ unexpectedly.

Gate:
- `tools/run-npc-navigation-tests.ps1` passes.
- `tools/run-playtest.ps1` passes.
- `tools/run-world-signature.ps1` matches the accepted baseline.

## Efficient Work Order

1. Add the dedicated NPC navigation runner before adding more cases.
2. Promote physics capsule validation and prove it with the new runner.
3. Harden reservations/deadlock behavior using the focused runner.
4. Expand job/guard/wander reachability after collision and reservations are stable.
5. Run the broad playtest only at phase boundaries or after touching shared systems.
6. Compare world-signature output against clean `HEAD` before treating a mismatch as a pathfinding regression.

## Completion Definition

The redesign is complete when:

- Town/tutorial NPC movement always goes through intent, route, and validated locomotion.
- Closed doors are route actions with reservation, open, cross, and delayed-close behavior.
- NPCs do not overlap blocked buildings, fences, windows, props, closed doors, hostiles, player-placed blocks, or each other.
- Home return, work, guard, wander, forage, and scripted rescue targets are reachability-aware.
- Unreachable goals wait at deterministic safe fallback cells with route diagnostics instead of bumping, spinning, or snapping.
- Dedicated NPC navigation tests and the broad playtest pass.
- World-signature handling is either clean or explicitly separated as a pre-existing baseline issue with clean-HEAD comparison evidence.
