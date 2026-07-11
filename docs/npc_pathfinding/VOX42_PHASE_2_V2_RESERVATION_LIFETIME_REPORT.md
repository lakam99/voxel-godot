# VOX-42 Phase 2: V2 Reservation Lifetime

## Scope

Branch: `codex/vox-42-forage-reservation-contract`

Linear issue: `VOX-45`

This phase binds forage reservation lifetime to the structured V2 route serving the current forage object. It does not claim live forage completion; exact reserved-slot routing remains Phase 3.

## Implementation

- Smart-object reservations now accept a heartbeat only for the exact object, reservation, owner, and slot.
- Route generation is monotonic. Older generations and conflicting request IDs at one generation are rejected.
- Reservation selection no longer inherits whichever route happened to be active. A reservation is bound only after a `forage_target` V2 request exists.
- `unreachable_static` and `invalid_goal` release once, mark the target unreachable for that forager, and reselect.
- `blocked_dynamic`, including executor `stuck`, receives one route repair without releasing capacity. A repeated dynamic failure releases once and reselects without permanently poisoning the target.
- Pending nav, budget, and probe states use the V2 request identity and authority wait counters. One fresh request window is allowed before bounded release.
- An arrived `home_departure_clearance` lease now releases cleared door/traffic ownership and forces the next job route, preventing the live route-key mismatch found in Phase 1.
- Release diagnostics preserve the actual structured release reason.

## Focused Verification

Compile smoke passed:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Terminal V2 release passed:

```text
artifacts/npc/reports/vox45-terminal-v2-final.json
```

Bounded dynamic repair/release passed:

```text
artifacts/npc/reports/vox45-dynamic-repair-final.json
```

Home-departure authority handoff passed:

```text
artifacts/npc/reports/vox45-home-departure-final.json
```

Forage route/reservation generation binding passed:

```text
artifacts/npc/reports/vox45-route-binding-final.json
```

Generic, non-Niko stale-reservation regression passed:

```text
artifacts/npc/reports/vox45-generic-stale-regression.json
```

Reservation heartbeat identity passed, and the full interaction suite passed 36/36:

```text
artifacts/npc/reports/vox45-heartbeat-green.json
artifacts/npc/reports/vox45-interaction-both.json
```

## Broader Suite

The full behavior suite passed 52/56 cases. Four existing scripted-motion cases still assert calls to the removed legacy `move_npc` path:

- `npc_behavior_scripted_order_normal_profile_speed`
- `npc_behavior_scripted_order_sprint_profile_speed`
- `npc_motor_every_active_actor_motion_tick_32_npcs`
- `npc_behavior_scripted_order_moves_while_brain_skipped`

They do not exercise foraging, reservations, or files changed by this phase. Report: `artifacts/npc/reports/vox45-behavior-both.json`.

## Remaining Contract

The binding test shows one reserved forage target still produces five V2 candidate cells. Phase 3 must make the reserved slot position/cell the immutable route goal and require the arrived lease to match it before gathering.

## Phase Gate

Phase goal achieved: terminal V2 outcomes and bounded no-progress release capacity exactly once, transient blockage receives one repair, and reservation ownership follows the active forage V2 generation.

Next phase allowed: yes.
