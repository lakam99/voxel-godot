# VOX-42 Phase 4: Live Completion and Bounded Retarget

## Outcome

VOX-42 is resolved at the forage-task ownership boundary.

A forager can no longer own one bush indefinitely. A claimed forage task now has three valid outcomes:

1. reach the exact collision-proven slot and complete the harvest;
2. consume a terminal V2 route result, release the reservation, and try another slot or target;
3. hit the 45-second absolute smart-object deadline, release authoritatively, and place that object in a 90-second actor-local retry cooldown.

The player/Niko same-bush interaction probe was removed. It was outside the clarified scope and could obstruct the actor being observed.

## Root Cause

The failure was a lifecycle loop across two route stacks:

- the shared movement controller set `routeForceReplan = true` while a route was pending;
- the V2 routine executor treated that shared boolean as a level-trigger and cancelled its resumable collision search on the next tick;
- real `unreachable_static` probe results could also be cancelled before forage behavior consumed them;
- every replacement request rebound the same smart-object reservation to a newer generation;
- heartbeats had no absolute ownership deadline.

The live reproduction on `atlas-86013896` held one reservation for 3,290 frames and reached generation 137 with zero completed runs.

## Implementation

- Collision-backed A* search jobs resume across frame budgets instead of restarting.
- `routeForceReplan` is consumed once and coalesced while the same V2 request is queued, planning, or probing.
- V2 forage terminal states survive long enough for behavior to release, advance the slot, or retarget.
- Smart-object reservations store `maxAgeFrames` and `deadlinePhysicsFrame`.
- A heartbeat at or beyond the deadline releases the slot with `reservation_deadline`; heartbeat activity cannot extend absolute ownership.
- Deadline-retargeted objects enter a temporary per-forager cooldown and are not immediately reacquired.
- Reservation, route-generation, exact-slot, terminal-release, and bounded-retarget diagnostics are retained in live reports.

## Automated Verification

Passed:

- `tools/run-project-compile-smoke.ps1`
- route suite: 110/110, `artifacts/npc/reports/vox47-route-both-release.json`
- interaction suite: 39/39, `artifacts/npc/reports/vox47-interaction-both-release.json`
- focused stable request: `artifacts/npc/reports/vox47-force-replan-coalesced.json`
- focused terminal handoff: `artifacts/npc/reports/vox47-terminal-forage-handoff.json`
- focused authority deadline: `artifacts/npc/reports/vox47-authority-reservation-deadline.json`
- focused deadline cooldown: `artifacts/npc/reports/vox47-forage-deadline-cooldown.json`
- acceptance runner guard: `artifacts/npc/reports/vox47-acceptance-runner-clean-bounded-retarget.json`

Behavior suite: 59/63 passed in `artifacts/npc/reports/vox47-behavior-both-release.json`. The four failures are the pre-existing scripted/motor baseline:

- `npc_behavior_scripted_order_normal_profile_speed`
- `npc_behavior_scripted_order_sprint_profile_speed`
- `npc_motor_every_active_actor_motion_tick_32_npcs`
- `npc_behavior_scripted_order_moves_while_brain_skipped`

## Live Acceptance

Command shape for every acceptance run:

```powershell
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -RunName <name> -TimeoutSeconds 600 -StaleProgressSeconds 120 -RealBoot -Visible
```

The wrapper proved `VOXEL_PLAYTEST`, `VOXEL_TEST_SEED`, `VOXEL_SAVE_PATH_OVERRIDE`, `VOXEL_REAL_TUTORIAL_GOD_MODE`, and `VOXEL_GOD_MODE` were unset. Runs booted through the real main menu and selected New Game. NPC motion and interaction were actual gameplay-derived.

### Completed Harvest

`atlas-72726314`:

This completion was captured before the final terminal-handoff/cooldown hardening. Those later edits affect failed-route release only; the completed-harvest path remained green in the final interaction and behavior suites.

- report: `artifacts/npc/reports/vox47-live-seed-16-autonomy.json`
- result: `niko_real_forage_cycle_completed`
- exact slot: `slot:0`
- job runs: 0 to 1
- inventory: 3 berries
- release: `completed`, age 294 frames
- remaining reservations: 0
- screenshots: `artifacts/npc/screenshots/vox47-live-seed-16-autonomy`
- no-flags proof: `artifacts/npc/progress/vox47-live-seed-16-autonomy.no-flags-proof.json`

### Bounded Retargets

`atlas-46179968`:

- report: `artifacts/npc/reports/vox47-live-seed-20-autonomy.json`
- original request remained bounded at generation 5
- release: `reservation_deadline`, exactly 2,700 frames
- original reservations after release: 0
- next object differed from the released object
- screenshot: `artifacts/npc/screenshots/vox47-live-seed-20-autonomy/niko_forage_post_release.png`
- no-flags proof: `artifacts/npc/progress/vox47-live-seed-20-autonomy.no-flags-proof.json`

`atlas-41222791`:

- report: `artifacts/npc/reports/vox47-live-seed-22-autonomy.json`
- original request remained bounded at generation 6
- release: `reservation_deadline`, exactly 2,700 frames
- original reservations after release: 0
- actor returned to searching without reacquiring the released bush
- screenshots: `artifacts/npc/screenshots/vox47-live-seed-22-autonomy`
- no-flags proof: `artifacts/npc/progress/vox47-live-seed-22-autonomy.no-flags-proof.json`

### Fresh-Seed Non-Acceptance Findings

- `atlas-86013896` reproduced the original infinite lease before the authority deadline was added: 3,290-frame reservation, generation 137, zero runs.
- seed-15 reached a strict-inside Mira assertion mismatch during extended Day One flow before forage observation.
- seed-19, seed-23, and seed-24 found no eligible berry source during the strict window; no bush reservation was held.
- seed-21 stopped at `repair_placement_preview_miss`, an automated-player driver failure before morning.

These runs are retained as evidence and are not counted as successful forage acceptance.

## Screenshot Review

The final player POV shows the player remained inside the starter house during autonomous forage observation. The post-release observer capture shows Niko outside after the original reservation was released. Terrain was opaque in the inspected captures; the stale `[RMB] Sleep` HUD prompt remained visible in the observer capture and is not forage state.

## Performance Observation

`artifacts/performance/vox47-day-work-observation.json` completed and failed the existing DayWork threshold:

- frame p99: 101.77 ms
- frame max: 116.36 ms
- max `update_npcs`: 109.88 ms
- last spike reason: `update_npcs`
- dominant sections: `npc_execute_motion` and `npc_guard_move`

The spike is not attributed to forage reservation expiry; route-plan maxima were 0 ms in this scenario. It remains a release risk and should be tracked independently rather than hidden in VOX-42.

## Remaining Risk

- Random worlds can provide no eligible forage source within the observation window. That is target availability, not an indefinitely held task.
- The full behavior suite still has four pre-existing scripted/motor failures.
- DayWork NPC/guard motion performance is above the current threshold.
- The observer screenshot proves post-release actor state but not motion across frames; the live timeline and reservation records provide the temporal proof.
