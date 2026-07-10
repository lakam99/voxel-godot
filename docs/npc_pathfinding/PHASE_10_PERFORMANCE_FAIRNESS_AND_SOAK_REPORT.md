# Phase 10 - Performance, Fairness, And Soak Report

Date: 2026-07-10

Branch: `codex/npc-pathfinding-replacement`

Linear issue: `VOX-40`

Plan: `CODEX_NPC_PATHFINDING_REPLACEMENT_PHASE_PLAN.md`

## Scope

Phase 10 makes the migrated NPC route authority stable under load. This phase adds bounded route-planning/probe admission, starvation telemetry, and load evidence. It is not the final live gameplay acceptance phase.

## Code Changed

- `scripts/npc_ai/routing/NpcRouteAuthorityV2.gd`
  - Added per-frame planning attempt budget.
  - Added starvation overrides for planning and probing so a request cannot remain deferred indefinitely.
  - Added wait/counter telemetry for queue wait, probe wait, dynamic blocks, static unreachable, route repairs, successful arrivals, and stuck recovery.
- `scripts/npc_ai/behavior/NpcPlanExecutor.gd`
  - Routes home/work/forage/guard planning admission through `NpcRouteAuthorityV2.claim_planning_budget()`.
  - Reports route-repair events when execution schedules a retry or cancels a stale routine route request.
- `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`
  - Caches dynamic occupant cells once per engine frame and removes the querying actor from the snapshot per caller.
  - This keeps dynamic collision information frame-fresh while avoiding repeated full NPC/hostile/player scans inside one frame.
- `scripts/testing/npc/NpcRouteTestCases.gd`
  - Added authority fairness and Phase 10 counter coverage.

## Performance Finding And Fix

The first focused DayWork performance run failed:

Command:

```powershell
.\tools\run-runtime-performance-observation.ps1 -Scenario DayWork -DurationSeconds 30 -WatchdogSeconds 180 -ReportPath artifacts\performance\phase10-runtime-observation-daywork.json -ProgressPath artifacts\performance\phase10-runtime-observation-daywork-progress.txt -LogPath artifacts\performance\phase10-runtime-observation-daywork-godot.log
```

Result: failed. `failureCount=1`, `frameP99Ms=42.19`, `frameMaxMs=55.809`, `maxNpcMs=54.783`.

Top spike: `update_npcs`, with `NpcAutonomySystem`, `npc_task_plan`, and `navigation_dynamic_update` in the stack.

Fix: cache dynamic occupant cells per engine frame in `GeneratedWorldNavigationAdapter`.

Re-run command:

```powershell
.\tools\run-runtime-performance-observation.ps1 -Scenario DayWork -DurationSeconds 30 -WatchdogSeconds 180 -ReportPath artifacts\performance\phase10-runtime-observation-daywork-after-cache.json -ProgressPath artifacts\performance\phase10-runtime-observation-daywork-after-cache-progress.txt -LogPath artifacts\performance\phase10-runtime-observation-daywork-after-cache-godot.log
```

Result: passed. `failureCount=0`, `frameP99Ms=21.846`, `frameMaxMs=32.325`, `maxNpcMs=23.159`, `maxRoutePlanMs=0.0`, `maxRouteSearchMs=0.0`.

Report: `artifacts/performance/phase10-runtime-observation-daywork-after-cache.json`

Traversal command:

```powershell
.\tools\run-runtime-performance-observation.ps1 -Scenario SprintTraversal -DurationSeconds 30 -WatchdogSeconds 180 -ReportPath artifacts\performance\phase10-runtime-observation-sprint-traversal.json -ProgressPath artifacts\performance\phase10-runtime-observation-sprint-traversal-progress.txt -LogPath artifacts\performance\phase10-runtime-observation-sprint-traversal-godot.log
```

Result: passed. `failureCount=0`, `frameP99Ms=7.312`, `frameMaxMs=17.742`, `maxNpcMs=0.706`, `playerTravelDistance=439.367`, `chunksCreated=84`.

Report: `artifacts/performance/phase10-runtime-observation-sprint-traversal.json`

Earlier attempted broad command:

```powershell
.\tools\run-runtime-performance-observation.ps1 -Scenario All -DurationSeconds 30 -ReportPath artifacts\performance\phase10-runtime-observation-all.json -ProgressPath artifacts\performance\phase10-runtime-observation-all-progress.txt -LogPath artifacts\performance\phase10-runtime-observation-all-godot.log
```

Result: watchdog timeout at 330 seconds before report write. Progress reached `scenario:AutosaveEnabled:measure_frame:1350:sample`. This is retained as failed evidence and not used for acceptance.

## Contract And Soak Evidence

Compile smoke:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Result: passed.

Legacy pathfinding audit:

```powershell
.\tools\npc\assert-npc-legacy-pathfinding-clean.ps1 -ReportPath artifacts\npc\reports\phase10-legacy-pathfinding-audit-final.json -PassThruJson
```

Result: passed. `failureCount=0`.

Route-state writer audit:

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase10-route-state-writer-audit-final.json -PassThruJson
```

Result: passed. `failureCount=0`.

Route suite:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase10-route-tests-final.json
```

Result: passed. `failureCount=0`, `resultCount=98`, `assertions=228`.

Behavior suite:

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase10-behavior-tests-final.json
```

Result: passed. `failureCount=0`, `resultCount=49`, `assertions=117`.

Soak suite:

```powershell
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase10-soak-tests-both.json -WatchdogSeconds 180
```

Result: passed. `failureCount=0`, `resultCount=26`, `assertions=78`, `dayMaxQueue=24`, `nightMaxQueue=24`.

Report: `artifacts/npc/reports/phase10-soak-tests-both.json`

## What This Proves

- Planning work is admitted through a bounded authority budget.
- Probe work remains bounded and can recover from starvation through a controlled per-frame override.
- Queue/probe wait, dynamic block, static unreachable, route repair, arrival, and stuck recovery counters are exported by the authority.
- DayWork and SprintTraversal performance reports pass after fixing the repeated dynamic-occupant scan.
- Synthetic soak coverage shows day/night queues drain and no persistent starvation is reported by the soak suite.

## What This Does Not Prove

- This does not prove final live gameplay acceptance.
- It does not replace Phase 11 real-boot autonomy, no-flags tutorial, focused home/door visual playtests, screenshot inspection, or multi-seed generated-town acceptance.

## Exit Gate

Phase 10 exit gate: performance reports show bounded planning/probe cost and soak evidence shows no persistent NPC starvation.

Status: passed for the Phase 10 load, synthetic, and static evidence listed above.

Next phase allowed: yes.
