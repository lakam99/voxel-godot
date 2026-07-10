# Phase 5 Probe-Before-Commit Report

## Scope

Phase 5 makes probe proof mandatory before `NpcRouteAuthorityV2` can issue a route lease.

This phase still does not claim live gameplay acceptance. It hardens the passive V2 authority so later production integration cannot mark a route `ready` unless a collision probe has cleared the candidate route.

## Implementation

- Extended `scripts/npc_ai/routing/NpcRouteAuthorityV2.gd` with:
  - `setup(system, main, route_probe = null)`;
  - collision probe service initialization;
  - per-frame probe sample accounting;
  - probe cursor retention for budgeted probes;
  - `commit_route_after_probe`;
  - mandatory proof validation in `mark_ready`;
  - movement guard in `begin_moving`;
  - route proof export on all probe decisions;
  - structured door probe edge evidence.
- Updated `scripts/npc_ai/NpcAutonomySystem.gd` so every V2 authority creation path initializes the probe service.
- Added V2 probe contracts in `scripts/testing/npc/NpcAutonomyTestRunner.gd`.

## Behavior

- A direct `mark_ready` call without a successful authoritative probe certificate is rejected.
- A passed authoritative probe can issue a route lease.
- The route lease carries the probe certificate.
- Door edges are represented in probe proof as structured portal checks:
  - approach side;
  - door open state;
  - crossing clearance;
  - destination side;
  - threshold clearance.
- A blocked probe records blocker identity/class details and terminates the route before movement.
- `begin_moving` now rejects requests that are not `ready`.
- Probe budget exhaustion stays in `probing` and preserves the probe cursor. It is not classified as blocked or unreachable.

## Evidence

Compile smoke:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Result: passed.

Route state writer audit:

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase5-route-state-writer-audit.json -PassThruJson
```

Result: passed.

Focused V2 probe contracts:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_authority_v2_requires_probe_certificate -TimeMode Both -ReportPath artifacts\npc\reports\phase5-v2-requires-probe-certificate.json
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_authority_v2_probe_commit_ready -TimeMode Both -ReportPath artifacts\npc\reports\phase5-v2-probe-commit-ready.json
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_authority_v2_probe_blocked_before_movement -TimeMode Both -ReportPath artifacts\npc\reports\phase5-v2-probe-blocked-before-movement.json
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_authority_v2_probe_pending_budget -TimeMode Both -ReportPath artifacts\npc\reports\phase5-v2-probe-pending-budget.json
```

Results:

- `npc_contract_route_authority_v2_requires_probe_certificate`: passed day and night.
- `npc_contract_route_authority_v2_probe_commit_ready`: passed day and night.
- `npc_contract_route_authority_v2_probe_blocked_before_movement`: passed day and night.
- `npc_contract_route_authority_v2_probe_pending_budget`: passed day and night.

Regression checks:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_authority_v2_lifecycle -TimeMode Both -ReportPath artifacts\npc\reports\phase5-v2-lifecycle-regression.json
.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_route_authority_v2_cancellation -TimeMode Both -ReportPath artifacts\npc\reports\phase5-v2-cancellation-regression.json
```

Results:

- `npc_contract_route_authority_v2_lifecycle`: passed day and night.
- `npc_contract_route_authority_v2_cancellation`: passed day and night.

## What This Proves

- V2 route plans cannot become `ready` without successful authoritative probe proof.
- Collision-blocked routes fail before actor movement can begin.
- Probe failures include blocker identity/class details when provided by the probe.
- Probe budget deferral remains `probing`, not blocked or unreachable.
- Door route proof is structured as portal-edge checks, not hidden behind a composed route shortcut.
- The route-state writer lockdown still passes.

## What This Does Not Prove

- This is not live gameplay acceptance evidence.
- This does not yet migrate production NPC movement to V2.
- This does not yet prove headed NPCs leave porches, enter homes, forage, or resume schedules in the booted game.
- This does not yet prove full actor-footprint probe behavior against real generated-town doors in live gameplay.

Those belong to the production executor/integration and live acceptance phases.

## Next Phase

Phase 6 should integrate route execution/motor behavior around authority-issued V2 leases only.
