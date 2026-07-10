# Phase 7 - Migrate Home Return Report

Date: 2026-07-10
Branch: `codex/npc-pathfinding-replacement`
Linear: `VOX-37`

## Scope

Phase 7 migrated home-return execution onto the collision-backed route authority path and tightened the home-arrival contract. The phase goal was not daytime work/forage autonomy; that remains Phase 8.

## Implementation

- `NpcRouteLeaseExecutor` now mirrors immutable lease data once per request instead of rehydrating mutable route actions every frame.
- Door route actions now fire only for the matching waypoint cell, not as a fallback for unrelated waypoints.
- Home V2 candidate cells reject poses whose arrival radius can still leave the NPC in door clearance, threshold, porch, sweep, or wall-edge ambiguity.
- Door traversal preserves explicit route-edge direction instead of overriding it with a derived goal direction.
- Strict inside-home arrival reports V2 `arrived`, clears route actions/cells/waypoints, and leaves route truth owned by the authority.
- Removed the production intro-release fallback that substituted `mira` when the requested actor was missing. Intro release now derives the actor from the live dialogue node or current dialogue payload and fails visibly if no actor can be resolved.

## Commands And Evidence

Compile smoke:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Result: passed.

Route-state writer audit after final cleanup:

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase7-route-state-writer-audit-after-named-fallback-removal.json
```

Result: passed.

Focused real-boot headed home-return gate after removing the named fallback:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -MiraHomeOnly -Visible -ReportPath artifacts\npc\reports\phase7-mira-home-visual-after-named-fallback-removal.json -ProgressPath artifacts\npc\progress\phase7-mira-home-visual-after-named-fallback-removal.txt -ScreenshotDir artifacts\npc\screenshots\phase7-mira-home-visual-after-named-fallback-removal -TimeoutSeconds 470 -StaleProgressSeconds 45
```

Result: passed. Seed `tutorial-20260710074456-2f8f1763`, `failureCount=0`, `evidenceLevel=acceptance_visual`.

Key proof:

- `miraFinalHomeInteriorStatus.strictInside=true`
- `clearOfDoor=true`
- `doorClearanceOccupied=false`
- `doorSweepOccupied=false`
- `doorThresholdOccupied=false`
- V2 state for Mira: `arrived`, reason `home_interior_reached`
- Visual captures saved:
  - `artifacts/npc/screenshots/phase7-mira-home-visual-after-named-fallback-removal/mira_home_door_open.png`
  - `artifacts/npc/screenshots/phase7-mira-home-visual-after-named-fallback-removal/mira_inside_home_closed_door.png`
  - `artifacts/npc/screenshots/phase7-mira-home-visual-after-named-fallback-removal/non_guard_home_rowan.png`
  - `artifacts/npc/screenshots/phase7-mira-home-visual-after-named-fallback-removal/non_guard_home_niko.png`

Generic visual home-door fixture:

```powershell
.\tools\npc\run-npc-go-home-visual-playtest.ps1 -ReportPath artifacts\npc\reports\phase7-go-home-visual-after-door-direction-fix.json -ProgressPath artifacts\npc\progress\phase7-go-home-visual-after-door-direction-fix.txt -ScreenshotDir artifacts\npc\screenshots\phase7-go-home-visual-after-door-direction-fix -WatchdogSeconds 190
```

Result: passed. Seed `atlas-1492`, `failureCount=0`, `evidenceLevel=acceptance_visual`.

Key proof:

- NPC walked to the home door.
- Door opened before crossing.
- NPC reached strict interior.
- Door closed after entry.
- Strict status: `strictInside=true`, `clearOfDoor=true`, door clearance/sweep/threshold all false.

Broader visible real tutorial run:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -Visible -ReportPath artifacts\npc\reports\phase7-full-real-tutorial-after-door-direction-fix.json -ProgressPath artifacts\npc\progress\phase7-full-real-tutorial-after-door-direction-fix.txt -ScreenshotDir artifacts\npc\screenshots\phase7-full-real-tutorial-after-door-direction-fix -TimeoutSeconds 620 -StaleProgressSeconds 70
```

Result: failed later at `workbench_not_reached_for_repair_crafting`.

Classification: not a Phase 7 NPC home-return failure. The run reached the post-knock/night matrix checkpoint first, with `night_guard_non_guard_matrix` passing and Mira strict-inside/clear of door. The failure is in the automated player driver route to the repair workbench and should remain tracked outside NPC home-return authority.

## Exit Gate

Phase 7 exit gate is satisfied for home-return scope:

- No named-NPC production pathing fallback remains in `scripts/NpcSystem.gd` or `scripts/npc_ai`.
- Door traversal is route-edge based.
- Focused real-boot evidence shows the outside-to-inside transition and strict interior arrival.
- Generic visual fixture proves the same door/open/cross/close contract without relying on Mira.
- The broader real tutorial run confirms the night matrix before a later player-driver failure.

Phase 8 may start next. It must address daytime work, forage, guard, and roam behavior through the same authority and must not treat this Phase 7 evidence as proof of next-morning autonomy.
