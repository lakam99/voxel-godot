# Phase 6 Route Executor And Motor Integration Report

## Scope

Phase 6 adds a V2 route lease executor that consumes only authority-issued leases and moves a controlled NPC body through the shared `CharacterMotor3D` motor.

This phase does not migrate production NPC behavior yet. It proves the executor contract needed before home-return production migration.

## Implementation

- Added `scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd`.
- Extended `scripts/npc_ai/routing/NpcRouteAuthorityV2.gd` with authority-visible execution events:
  - `report_segment_started`
  - `report_segment_completed`
  - `report_stuck`
  - `report_unexpected_collision`
  - `report_door_wait`
  - `report_execution_event`
- V2 summaries now include recent events and the current route lease payload for auditability.
- Added Phase 6 contracts in `scripts/testing/npc/NpcAutonomyTestRunner.gd`.

## Behavior

- The executor rejects:
  - missing request IDs;
  - missing bodies;
  - missing leases;
  - non-ready leases;
  - leases without successful authoritative probe certificates;
  - invalid waypoint geometry;
  - authority requests that are not ready.
- The executor does not invent fallback routes.
- The executor does not write route truth fields directly.
- The executor starts movement through `NpcRouteAuthorityV2.begin_moving`.
- The executor reports segment start/completion to V2.
- Arrival is reported through `NpcRouteAuthorityV2.report_arrived`.
- Unexpected collision, stuck, and door wait reporting APIs exist on V2 for the executor path.

## Evidence

Compile smoke:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Result: passed.

Route state writer audit:

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase6-route-state-writer-audit.json -PassThruJson
```

Result: passed.

Focused executor contracts:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_lease_executor_follows_v2_lease -TimeMode Both -ReportPath artifacts\npc\reports\phase6-v2-lease-executor-follows-lease.json
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_lease_executor_rejects_unready_lease -TimeMode Both -ReportPath artifacts\npc\reports\phase6-v2-lease-executor-rejects-unready.json
```

Results:

- `npc_contract_route_lease_executor_follows_v2_lease`: passed day and night.
- `npc_contract_route_lease_executor_rejects_unready_lease`: passed day and night.

## What This Proves

- A controlled `CharacterBody3D` can follow a V2 ready lease through `CharacterMotor3D`.
- The lease must contain a successful authoritative probe certificate.
- V2 receives execution events for movement start, segment completion, and arrival.
- A forged or unprobed lease is rejected.
- The executor does not mutate route truth directly; the static writer audit remains green.

## What This Does Not Prove

- This is not live gameplay acceptance evidence.
- This does not yet migrate home return, work, forage, guard, or roam behavior to V2.
- This does not yet prove generated-town doors in production home return.
- This does not yet prove Mira, Niko, Rowan, or any other named NPC moves correctly in the booted game.

Those belong to Phase 7 and later.

## Next Phase

Phase 7 should migrate home return to V2 for the first real production behavior and prove it through the real-boot runner with screenshots/trace evidence.
