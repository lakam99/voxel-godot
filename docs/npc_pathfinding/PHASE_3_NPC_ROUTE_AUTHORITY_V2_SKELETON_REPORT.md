# Phase 3 - NpcRouteAuthorityV2 Skeleton Report

Phase: 3 - NpcRouteAuthorityV2 Skeleton
Branch: `codex/npc-pathfinding-replacement`
Linear issue: `VOX-33`

## Commands Run

```powershell
.\tools\run-project-compile-smoke.ps1
```

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase3-route-state-writer-audit.json -PassThruJson
```

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_authority_v2_lifecycle -TimeMode Both -ReportPath artifacts\npc\reports\phase3-v2-lifecycle-contract.json
```

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_authority_v2_cancellation -TimeMode Both -ReportPath artifacts\npc\reports\phase3-v2-cancellation-contract.json
```

```powershell
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -RealBoot -Visible -RunName phase3-realboot-autonomy-matrix -ReportPath artifacts\npc\reports\phase3-realboot-autonomy-matrix.json -ProgressPath artifacts\npc\progress\phase3-realboot-autonomy-matrix.txt -ScreenshotDir artifacts\npc\screenshots\phase3-realboot-autonomy-matrix -NoFlagsProofPath artifacts\npc\progress\phase3-realboot-autonomy-matrix.no-flags-proof.json -TimeoutSeconds 520 -StaleProgressSeconds 90
```

## Reports

- Compile smoke: `artifacts/project-compile-smoke-report.json`
- Static writer audit: `artifacts/npc/reports/phase3-route-state-writer-audit.json`
- V2 lifecycle contract: `artifacts/npc/reports/phase3-v2-lifecycle-contract.json`
- V2 cancellation contract: `artifacts/npc/reports/phase3-v2-cancellation-contract.json`
- Real-boot matrix: `artifacts/npc/reports/phase3-realboot-autonomy-matrix.json`
- No-flags proof: `artifacts/npc/progress/phase3-realboot-autonomy-matrix.no-flags-proof.json`
- Screenshots: `artifacts/npc/screenshots/phase3-realboot-autonomy-matrix/`

## Code Changed

- Added `scripts/npc_ai/routing/NpcRouteAuthorityV2.gd`.
- Added passive V2 diagnostics to `scripts/npc_ai/NpcAutonomySystem.gd`.
- Added `routeAuthorityV2` to `NpcRealTutorialPlaythroughRunner.gd` NPC summaries.
- Added V2 contract cases to `scripts/testing/npc/NpcAutonomyTestRunner.gd`.
- Updated the route-state writer audit allowlist to include `NpcRouteAuthorityV2.gd`.

## V2 Skeleton Capabilities

`NpcRouteAuthorityV2` now supports:

- actor registration;
- route request ids;
- per-actor active request tracking;
- lifecycle transitions:
  - `queued`
  - `pending_budget`
  - `pending_nav_data`
  - `probing`
  - `ready`
  - `moving`
  - `arrived`
  - `blocked_dynamic`
  - `unreachable_static`
  - `invalid_goal`
  - `cancelled`
- route lease creation for ready routes;
- route proof storage;
- cancellation;
- starvation accounting:
  - queued frames;
  - pending budget frames;
  - pending nav data frames;
  - pending probe frames;
  - last serviced frame;
- debug export per actor and global stats.

## Contract Results

Lifecycle contract:

```text
passed=true
resultCount=2
failureCount=0
assertions=10
```

Cancellation contract:

```text
passed=true
resultCount=2
failureCount=0
assertions=6
```

The lifecycle test proves queued -> pending budget -> pending nav data -> probing -> ready -> moving -> arrived, with a route lease and starvation counters. The cancellation test proves a request can be cancelled without a lease while preserving pending-budget accounting and last-serviced frame.

## Real-Boot Matrix Result

The real-boot matrix still launches the actual title menu, clicks New Game, and runs without gameplay-affecting flags.

- `actualGameplayDerived`: `true`
- `realBootAttachedToMainMenu`: `true`
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
lastFailureCode=intro_route_waypoint_not_reached
```

The report includes `routeAuthorityV2` debug for all 6 NPC matrix rows:

```json
{
  "actorId": "mira",
  "hasRequest": false,
  "state": "none",
  "reason": "no_active_request",
  "queuedFrames": 0,
  "pendingBudgetFrames": 0,
  "pendingNavDataFrames": 0,
  "pendingProbeFrames": 0,
  "lastServicedFrame": -1
}
```

This proves V2 is observable in the real-boot matrix without controlling production movement yet.

## Known Failures

- The real-boot tutorial matrix remains red at the automated player route: `intro_route_waypoint_not_reached` for `bed_after_repair_route`.
- V2 does not yet build collision-backed route substrates, probe production routes, migrate home return, or execute NPC movement.
- Production NPCs still move through the old route stack in this phase by design.

## Next Phase Allowed

Yes, for Phase 4 only.

Reason: V2 lifecycle and cancellation contracts pass, compile smoke passes, the route-state writer audit remains clean, and the real-boot matrix includes V2 debug fields without changing production movement ownership. The next sequential work is the collision-backed route substrate.
