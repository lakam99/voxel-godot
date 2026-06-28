# Mature Nav Phase 00/01 Foundation Report

Date: 2026-06-28

Branch: `codex/mature-navmesh-phase0-foundation`

Controlling specification: `CODEX_MATURE_NAV_PLAN.md`

## Scope

This foundation pass starts the full navmesh migration without changing live NPC movement behavior. The current green custom route stack remains the default backend while the navmesh backend becomes explicit, testable, and auditable.

Implemented:

- Added `NavigationBackendConfig` with `custom` and `navmesh` backend values.
- Kept `custom` as the default backend for live NPCs.
- Added `NavigationBakeDescriptor` for deterministic CPU-side navigation descriptors.
- Added `NavmeshWorldService` as the future NavigationServer-backed service shell with one owned NPC navigation map, descriptor registration, cleanup, closest-walkable queries, debug snapshots, and stats.
- Added `audit-npc-navmesh-backend.ps1` to detect remaining runtime legacy route-search dependencies before later cutover.
- Added nav-world tests for backend defaulting, explicit navmesh selection, deterministic descriptors, region cleanup, closest-walkable lookup, no scene visual-mesh scanning, and legacy-stack audit coverage.

Not changed:

- Live NPC route search still uses the existing custom stack.
- Door, smart-object, behavior, save, traffic, and CharacterBody motor ownership remains project-owned.
- No generated terrain, town RNG, save data, or broad behavior semantics were changed.

## Evidence

Static audit:

```powershell
.\tools\npc\audit-npc-navmesh-backend.ps1
```

Result: pass in detect mode. Runtime legacy pattern baseline: 10 hits in routing/navigation runtime files.

Nav-world focused suite:

```powershell
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\nav_world-mature-foundation.json
```

Result: pass, 52 results, 0 failures.

Contract suite:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\contract-mature-foundation.json
```

Result: pass, 40 results, 0 failures.

## Acceptance Notes

This phase intentionally does not enable navmesh as the live route authority. Its acceptance target is a controlled migration footing: a selectable backend, deterministic descriptor data shape, service lifecycle cleanup, focused tests, and a static audit that can later flip from detect mode to fail-on-legacy mode.

Next phase should feed real generated chunk/town/building descriptor facts into `NavmeshWorldService`, then add parity route-query tests before any live movement cutover.
