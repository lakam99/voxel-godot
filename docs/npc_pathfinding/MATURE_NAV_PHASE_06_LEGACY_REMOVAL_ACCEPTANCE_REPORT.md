# Mature Nav Phase 6 Legacy Removal Acceptance Report

Date: 2026-06-29

## Scope

Phase 6 removes legacy live-route dependencies from NPC navigation acceptance and hardens the navmesh path against tutorial, door, streaming, save, and aggregate-run regressions.

Key outcomes:

- live NPC route planning remains on the navmesh backend;
- legacy route-pattern audit reports zero live matches;
- tutorial NPCs return home without teleport or speed hacks;
- transient navmesh endpoint failures preserve active routes or skip only optional home threshold waypoints;
- topology holds release when requested tiles become traversable;
- forage smart-object completion now waits for the reserved approach slot rather than loose node proximity.

## Regression Fixed During Gate

The first full aggregate rerun failed in `tutorial_elder_returns_home` only inside `run-all-test-runners.ps1`. The isolated playtest immediately passed, so this was a route stability flake rather than a persistent behavior failure.

Failure evidence:

- Mira reached the safe porch edge.
- The active home target was the porch-adjacent threshold cell.
- The route failed with `endpoint_not_server_walkable`.
- The route had no fallback cell, so `npc_inside_home` stayed false.

Fix:

- `NpcRouteMovementController` now skips only optional moving-home threshold waypoints when the nav server cannot snap that endpoint and the NPC is already at the porch.
- Porch, home, and non-adjacent route goals are not skipped.
- Added `npc_motor_skips_optional_home_threshold_on_endpoint_snap_failure`.

## Branch Verification

Commands run after final changes:

```powershell
.\tools\npc\run-npc-motor-tests.ps1 -Case npc_motor_skips_optional_home_threshold_on_endpoint_snap_failure -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\motor-home-threshold-endpoint-skip.json
.\tools\run-playtest.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\playtest-after-home-endpoint-skip.json
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\all-npc-both-after-home-endpoint-skip.json
.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\real-tutorial-both-after-home-endpoint-skip.json -ProgressPath artifacts\npc\progress\real-tutorial-after-home-endpoint-skip.txt
.\tools\run-npc-navigation-tests.ps1 -Seed atlas-1492 -ReportPath artifacts\npc\reports\nav-full-after-home-endpoint-skip.json
.\tools\run-world-signature.ps1 -Seed atlas-1492 -OutputPath artifacts\world-signature\latest\atlas-1492-phase6-after-home-endpoint-skip.json
.\tools\npc\audit-npc-navmesh-backend.ps1 -FailOnLegacy
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -StopOnFailure -ReportPath artifacts\test-runners\all-test-runners-after-home-endpoint-skip.json
```

Results:

- focused motor regression: `failureCount=0`, `resultCount=2`;
- broad playtest: `failed=false`, `results=181`;
- full NPC suite: `failureCount=0`, `resultCount=13`;
- real tutorial wrapper: `failureCount=0`, `resultCount=7`, `scriptScan=passed`;
- NPC navigation integration: `passed=true`, `resultCount=11`;
- world signature: matched `artifacts\baselines\world-signature\atlas-1492.json`;
- static audit: `legacyPatternCount=0`;
- full aggregate: `failureCount=0`, `resultCount=23`, `stoppedEarly=false`.

## Merge Requirement

Phase 6 is ready to merge to `master` after commit. Per plan, merged `master` still requires post-merge verification.
