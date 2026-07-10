# Phase 2 - Route State Writer Lockdown Report

Phase: 2 - Route State Writer Lockdown
Branch: `codex/npc-pathfinding-replacement`
Linear issue: `VOX-32`

## Commands Run

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase2-route-state-writer-audit.json -PassThruJson
```

```powershell
.\tools\run-project-compile-smoke.ps1
```

```powershell
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -RealBoot -Visible -RunName phase2-realboot-autonomy-matrix -ReportPath artifacts\npc\reports\phase2-realboot-autonomy-matrix.json -ProgressPath artifacts\npc\progress\phase2-realboot-autonomy-matrix.txt -ScreenshotDir artifacts\npc\screenshots\phase2-realboot-autonomy-matrix -NoFlagsProofPath artifacts\npc\progress\phase2-realboot-autonomy-matrix.no-flags-proof.json -TimeoutSeconds 520 -StaleProgressSeconds 90
```

## Reports

- Static writer audit: `artifacts/npc/reports/phase2-route-state-writer-audit.json`
- Compile smoke: `artifacts/project-compile-smoke-report.json`
- Real-boot matrix report: `artifacts/npc/reports/phase2-realboot-autonomy-matrix.json`
- Real-boot progress: `artifacts/npc/progress/phase2-realboot-autonomy-matrix.txt`
- No-flags proof: `artifacts/npc/progress/phase2-realboot-autonomy-matrix.no-flags-proof.json`
- Screenshots: `artifacts/npc/screenshots/phase2-realboot-autonomy-matrix/`

## Code Changed

- Added `scripts/npc_ai/routing/NpcRouteStateStore.gd`.
- Added `tools/npc/assert-npc-route-state-writers.ps1`.
- Routed production NPC entry/body route status, route reason, and route lease writes through `NpcRouteStateStore`.
- Left temporary route-result annotation in `NpcRouteAuthority` as an approved authority file.
- Converted route-state fixture writes in `scripts/PlaytestRunner.gd` and `scripts/NpcNavigationTestRunner.gd` to the same store API.

## Before Writers

Before Phase 2, route state was written directly by multiple systems:

- `NpcRouteMovementController`: status/reason helper, missing-lease cleanup, route lease install/clear.
- `NpcRouteAuthority`: route lease publication.
- `NpcPlanExecutor`: home arrival, job idle/waiting, forage retry/search, route action completion.
- `NpcRecoveryPolicy`: home blocked and unreachable goal terminal state.
- `NpcSemanticGoalPlanner`: no-reachable-goal fallback state.
- `NpcSimulationLodService`: topology hold and release state.
- `NpcSystem`: spawn-inside arrival, metadata publication, home blocked/partial fallback, home-terminal clear, route cleanup.
- Test/fixture runners: `PlaytestRunner` and `NpcNavigationTestRunner`.

## After Writers

The static audit now allows only:

- `scripts/npc_ai/routing/NpcRouteStateStore.gd`
- `scripts/npc_ai/routing/NpcRouteAuthority.gd`

`NpcRouteStateStore` owns NPC entry/body publication for:

- `routeStatus`
- `routeReason`
- `routeLease`
- `routeLeaseId`
- `routeLeaseGeneration`
- `npc_route_status`
- `npc_route_reason`

The audit also guards route authority/proof fields:

- `routeAuthorityState`
- `routeAuthorityReason`
- `probeCertificate`

Audit result:

```text
passed=true
matches=[]
ruleCount=12
details=route state writers are locked to approved authority files
```

## Real-Boot Matrix Result

The real-boot no-flags matrix still runs from the title menu and clicks New Game via viewport input.

- `actualGameplayDerived`: `true`
- `realBootAttachedToMainMenu`: `true`
- `launchPath`: `project main scene MainMenu.tscn New Game button input`
- `fullPlayerPov`: `true`
- `noGameplayFlagsProof.passed`: `true`
- `VOXEL_PLAYTEST`: unset
- `VOXEL_TEST_SEED`: unset
- `VOXEL_SAVE_PATH_OVERRIDE`: unset
- `VOXEL_REAL_TUTORIAL_GOD_MODE`: unset
- `VOXEL_GOD_MODE`: unset

Result:

```text
passed=false
failureCount=1
lastFailureCode=south_repair_bypass_not_reached
```

This Phase 2 run advanced past the post-knock Mira home check:

```text
miraStrictInside=true
miraStrictReason=interior_clear
```

It failed later in the automated player repair route:

```json
{
  "cell": [286, 0],
  "index": 1,
  "player": [384.895, 20.25, -18.896],
  "stopDistance": 1.688,
  "target": [386.1, 20.33, 0.0]
}
```

This is not an NPC pathfinding acceptance pass. It only proves the real-boot matrix remains runnable after the writer lockdown and remains red.

## Known Failures

- The full real-boot tutorial matrix still does not reach sleep/morning autonomy because the automated player driver fails at `south_repair_bypass_not_reached`.
- Phase 2 did not replace NPC pathfinding, remove legacy planners, or implement the new route authority lifecycle.
- The Phase 1 Mira threshold failure remains a valid known red gate from `artifacts/npc/reports/phase1-realboot-autonomy-matrix.json`, even though this Phase 2 random run advanced past Mira.

## Next Phase Allowed

Yes, for Phase 3 only.

Reason: the static route-state writer audit passes, compile smoke passes, the real-boot matrix still runs without gameplay flags, and the before/after writer list is documented. The next sequential work is the `NpcRouteAuthorityV2` skeleton; it must not migrate production NPC movement yet.
