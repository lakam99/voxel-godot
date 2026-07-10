# Phase 11 - Full Release Acceptance Report

Date: 2026-07-10

Branch: `codex/npc-pathfinding-authority-sequential`

Linear issue: `VOX-41`

Plan: `CODEX_NPC_PATHFINDING_REPLACEMENT_PHASE_PLAN.md`

## Scope

Phase 11 declares the NPC pathfinding replacement complete only after real gameplay proves it. This report records the current full-release evidence, including the Phase 11 regressions found and fixed while running the acceptance matrix.

## Code Changed In Phase 11

- `scripts/testing/player/LivePlaytestPlayerNavigator.gd`
  - Added route-planned player current-home exit handling and tutorial perimeter recovery so live tutorial playtests use real movement, doors, and route planning instead of hand-authored fence routes.
- `scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd`
  - Kept the runner as orchestration and routed Day One NPC interaction movement through the player navigator.
- `scripts/TutorialRescueSystem.gd`
  - Recognizes collision-backed route-authority arrival for the final rescue guard-return pose.
- `scripts/npc_ai/routing/NpcRouteAuthorityV2.gd`
  - Added bounded probe-failure repair: static probe blockers are fed back into the collision-backed substrate and re-probed before declaring static unreachable.
- `scripts/npc_ai/routing/CollisionBackedRouteSubstrate.gd`
  - Added repair `avoidCells` support.
  - Fixed `guard_post` goal candidates so they are anchored to the assigned guard post, not an arbitrary staged departure target.
- `scripts/npc_ai/routing/CollisionProbeService.gd`
  - Collapses duplicate start waypoints and treats single-point/no-op routes as authoritative passed probes.
- `scripts/npc_ai/behavior/NpcPlanExecutor.gd`
  - Passes route-repair context for home and routine routes.
  - Splits guard home-departure clearance from true guard-post routing, preventing porch/exit clearance from being certified as guard arrival.
- `scripts/testing/npc/NpcBehaviorTestCases.gd`
  - Added a regression case proving guard departure uses home-departure clearance first, then targets the assigned guard post through V2.
- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
  - Added a V2 contract case proving static probe blocks can repair and re-probe before lease readiness.

## Commands And Evidence

Compile smoke:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Result: passed.

Focused regression behavior case:

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Day -Case npc_behavior_guard_departure_does_not_arrive_at_exit_as_post
```

Report: `artifacts/npc/reports/behavior-day-npc_behavior_guard_departure_does_not_arrive_at_exit_as_post.json`

Result: passed. `failureCount=0`, `resultCount=1`.

Route suite:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both *> artifacts\npc\logs\route-both-after-guard-semantic-fix.console.txt
```

Report: `artifacts/npc/reports/route-both.json`

Result: passed.

Contract suite:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both *> artifacts\npc\logs\contract-both-after-guard-semantic-fix.console.txt
```

Report: `artifacts/npc/reports/contract-both.json`

Result: passed.

Static route writer audit:

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase11-route-state-writer-audit-after-guard-semantic-fix.json -PassThruJson
```

Result: passed. `failureCount=0`.

Legacy pathfinding audit:

```powershell
.\tools\npc\assert-npc-legacy-pathfinding-clean.ps1 -ReportPath artifacts\npc\reports\phase11-legacy-pathfinding-audit-after-guard-semantic-fix.json -PassThruJson
```

Result: passed. `failureCount=0`.

Focused home/door visual playtest:

```powershell
.\tools\npc\run-npc-go-home-visual-playtest.ps1 -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase11-go-home-visual-atlas-1492.json -ProgressPath artifacts\npc\progress\phase11-go-home-visual-atlas-1492.txt -ScreenshotDir artifacts\npc\screenshots\phase11-go-home-visual-atlas-1492 -WatchdogSeconds 220
```

Result: passed. Screenshots manually inspected:

- `artifacts/npc/screenshots/phase11-go-home-visual-atlas-1492/at_home_door.png`
- `artifacts/npc/screenshots/phase11-go-home-visual-atlas-1492/door_open.png`
- `artifacts/npc/screenshots/phase11-go-home-visual-atlas-1492/inside_closed_door.png`

Full real-boot no-flags tutorial playthrough:

```powershell
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -RealBoot -RunName phase11-realboot-full-no-flags-after-guard-semantic-fix -Visible -TimeoutSeconds 620 -StaleProgressSeconds 90
```

Report: `artifacts/npc/reports/phase11-realboot-full-no-flags-after-guard-semantic-fix.json`

No-flags proof: `artifacts/npc/progress/phase11-realboot-full-no-flags-after-guard-semantic-fix.no-flags-proof.json`

Screenshot directory: `artifacts/npc/screenshots/phase11-realboot-full-no-flags-after-guard-semantic-fix`

Result: passed. `failureCount=0`, `resultCount=8`, `realBootAttachedToMainMenu=true`, `launchPath=project main scene MainMenu.tscn New Game button input`, `playtestGodMode=false`.

Forbidden gameplay flags were absent: `VOXEL_PLAYTEST`, `VOXEL_TEST_SEED`, `VOXEL_SAVE_PATH_OVERRIDE`, `VOXEL_REAL_TUTORIAL_GOD_MODE`, and `VOXEL_GOD_MODE`.

Screenshots manually inspected:

- `player_pov_after_mira_home.png`
- `player_pov_after_morning_forager_observation.png`
- `player_pov_after_repair_flow.png`
- `player_pov_after_sleep_attempt.png`
- `player_pov_night_matrix_ready.png`

Known failing generated-town seed:

```powershell
.\tools\npc\run-npc-town-job-cycle-visual-playtest.ps1 -Seed town-cycle-20260710154736-ef37e8ac -ReportPath artifacts\npc\reports\phase11-town-job-cycle-random-01-after-guard-semantic-fix.json -ProgressPath artifacts\npc\progress\phase11-town-job-cycle-random-01-after-guard-semantic-fix.txt -ScreenshotDir artifacts\npc\screenshots\phase11-town-job-cycle-random-01-after-guard-semantic-fix -TimeoutSeconds 460 -StaleProgressSeconds 70
```

Report: `artifacts/npc/reports/phase11-town-job-cycle-random-01-after-guard-semantic-fix.json`

Screenshot directory: `artifacts/npc/screenshots/phase11-town-job-cycle-random-01-after-guard-semantic-fix`

Result: passed. `failureCount=0`, `resultCount=20`, seed `town-cycle-20260710154736-ef37e8ac`.

Screenshots manually inspected:

- `day_guard_guarding.png`
- `day_jobs_overview.png`
- `night_all_inside_homes.png`
- `morning_emerge_jobs.png`

Fresh generated-town seed:

```powershell
.\tools\npc\run-npc-town-job-cycle-visual-playtest.ps1 -ReportPath artifacts\npc\reports\phase11-town-job-cycle-random-02-after-guard-semantic-fix.json -ProgressPath artifacts\npc\progress\phase11-town-job-cycle-random-02-after-guard-semantic-fix.txt -ScreenshotDir artifacts\npc\screenshots\phase11-town-job-cycle-random-02-after-guard-semantic-fix -TimeoutSeconds 460 -StaleProgressSeconds 70
```

Report: `artifacts/npc/reports/phase11-town-job-cycle-random-02-after-guard-semantic-fix.json`

Screenshot directory: `artifacts/npc/screenshots/phase11-town-job-cycle-random-02-after-guard-semantic-fix`

Result: passed. `failureCount=0`, `resultCount=20`, seed `town-cycle-20260710165401-456322d9`.

Screenshots manually inspected:

- `day_guard_guarding.png`
- `day_jobs_overview.png`
- `night_all_inside_homes.png`
- `morning_emerge_jobs.png`

## Failures Reproduced And Fixed During Phase 11

1. Real-boot no-flags Day One initially failed because the automated player driver was outside the town fence after berry gathering and could not route to Niko. This was fixed in `LivePlaytestPlayerNavigator` by using real route-planned perimeter/gate recovery instead of hand-authored fence routes.
2. Generated-town seed `town-cycle-20260710154736-ef37e8ac` failed at night because a static rock collision blocked Mara's home route. This was fixed by adding bounded static probe repair in `NpcRouteAuthorityV2` and `CollisionBackedRouteSubstrate`.
3. The same seed then exposed a false guard-arrival bug: guards reached home-exit clearance cells and reported `arrived` while still 19-38 meters from guard posts. This was fixed by separating guard home-departure clearance from actual `guard_post` routing and by anchoring `guard_post` candidates to the assigned post.

## What This Proves

- The current route authority can produce collision-backed, probe-certified routes and repair static probe blockers before NPC movement is committed.
- Mira's post-knock home return in the real-boot no-flags tutorial uses authoritative V2 route evidence, including door probe edges and `home_interior_reached`.
- The full real-boot no-flags tutorial flow can launch from the main menu, click New Game, avoid forbidden gameplay flags, complete knock/repair/sleep, and observe next-morning forager behavior.
- The generated-town autonomy matrix passes on one known failing seed and one fresh random seed, including day guard/forage/work progression, night non-guard home return, and morning emergence.
- Focused home/door visual evidence still shows approach, door open, strict interior arrival, and closed-door final state.

## Residual Risk

- This is not a proof over every possible generated town. It covers the real-boot tutorial, one known failing generated-town seed, one fresh generated-town seed, and focused home/door visual acceptance.
- Some generated-town worker rows still report explicit route reasons such as `no_routeable_candidate_pose` while the broader town-work progression gate passes. These are explained route outcomes, not silent standing, but they remain useful future tuning signals.
- The broad behavior suite currently contains legacy synthetic expectations that count `move_npc` calls even though V2 route motion bypasses that helper. The focused new guard regression case passes; the full behavior suite should be cleaned separately before using it as a blanket V2 acceptance signal.

## Acceptance Result

Phase 11 status: complete.

Known failures: no current Phase 11 acceptance failure after the guard semantic fix.

Next phase allowed: no.

Reason: Phase 11 is the terminal release-acceptance phase. `VOX-41` and parent `VOX-29` were updated with final evidence and marked Done after the acceptance matrix passed.
