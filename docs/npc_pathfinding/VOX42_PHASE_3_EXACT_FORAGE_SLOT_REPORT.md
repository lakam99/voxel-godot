# VOX-42 Phase 3: Exact Forage Slot

## Scope

Branch: `codex/vox-42-forage-reservation-contract`

Linear issue: `VOX-46`

This phase makes forage target selection, capacity, collision proof, route execution, arrival, and gathering refer to one exact approach slot.

## Implementation

- SmartObjectService accepts an explicit `preferredSlotId`; it never falls back to another slot when a preferred slot is supplied.
- Re-registering a smart object preserves the position and occupants of every live reserved slot, preventing moved or orphaned reservations.
- NpcSystem records deterministic forage slot candidates and reserves one preferred slot at a time.
- `forage_target` collision candidates contain only the reserved slot cell. Broad neighboring approach cells are no longer accepted for that semantic.
- V2 route intents and leases carry an interaction claim with object id, reservation id, slot id, slot position, slot cell, and route generation.
- A static/invalid slot releases and advances to the next explicit candidate. A repeated dynamic failure does the same after its one repair attempt.
- Gathering requires the current V2 request and generation to be `arrived`, the lease target to equal the reserved slot cell, the interaction claim to match the reservation, and the actor to be physically at that slot.

## Verification

Compile smoke passed:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Preferred-slot capacity contract passed:

```text
artifacts/npc/reports/vox46-preferred-slot-green.json
```

Live reservation geometry reconciliation passed:

```text
artifacts/npc/reports/vox46-reregistration-green.json
```

Exact candidate plus intent/lease claim passed:

```text
artifacts/npc/reports/vox46-exact-route-claim-rerun.json
```

Strict arrived-claim gate passed:

```text
artifacts/npc/reports/vox46-arrival-green.json
```

Blocked-side to clear-side slot retry passed:

```text
artifacts/npc/reports/vox46-blocked-clear-slot-final.json
```

Phase 2 terminal and dynamic behavior remained green:

```text
artifacts/npc/reports/vox46-terminal-regression.json
artifacts/npc/reports/vox46-dynamic-regression.json
```

Full shared suites:

- Interaction: 38/38 passed, `artifacts/npc/reports/vox46-interaction-both.json`.
- Route: 108/108 passed, `artifacts/npc/reports/vox46-route-both.json`.
- Behavior: 54/58 passed, `artifacts/npc/reports/vox46-behavior-both.json`.

The four behavior failures are the same unrelated legacy scripted-motion assertions documented in Phase 2; no forage or exact-slot case failed.

## Evidence Boundary

The blocked/clear fixture is synthetic and uses the production behavior, V2 authority, collision substrate, route lease, and exact claim contracts with controlled test world/probe inputs. It is not live gameplay acceptance.

## Phase Gate

Phase goal achieved: a blocked exact slot is released, the next clear exact slot is collision-proven and claimed, and proximity alone cannot start gathering.

Next phase allowed: yes.
