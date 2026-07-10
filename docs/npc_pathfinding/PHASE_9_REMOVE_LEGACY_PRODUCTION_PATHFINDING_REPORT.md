# Phase 9 - Remove Legacy Production Pathfinding Report

Date: 2026-07-10

Branch: `codex/npc-pathfinding-replacement`

Plan: `CODEX_NPC_PATHFINDING_REPLACEMENT_PHASE_PLAN.md`

## Scope

Phase 9 removes or quarantines production use of legacy NPC route sources after home, work, forage, guard, and roam migration. This is a route-authority cleanup gate, not a new live gameplay acceptance claim.

## Changes

- Disabled the generated-cell bridge fallback in production route planning.
- Disabled exact-home collision lattice routing as a production fallback.
- Rejected partial endpoint success in navmesh, hierarchical, runtime, and local A* route paths.
- Kept legacy helpers diagnostic-only by making production call sites bypass them and by making static audits fail if they are called from production code.
- Added `tools/npc/assert-npc-legacy-pathfinding-clean.ps1` to catch forbidden production generated-cell, exact-lattice, composed fallback, and partial-endpoint route sources.
- Kept `tools/npc/assert-npc-route-state-writers.ps1` as the route-state writer lockdown audit.
- Updated `AGENTS.md` to name `NpcRouteAuthorityV2`, `CollisionBackedRouteSubstrate`, and `NpcRouteLeaseExecutor` as the production migrated route path.

## Evidence

### Static Audits

Command:

```powershell
.\tools\npc\assert-npc-legacy-pathfinding-clean.ps1 -ReportPath artifacts\npc\reports\phase9-legacy-pathfinding-audit-after-source-clean.json -PassThruJson
```

Result: passed.

Report: `artifacts/npc/reports/phase9-legacy-pathfinding-audit-after-source-clean.json`

What it proves: production scripts no longer contain active generated-cell, exact-home collision lattice, composed fallback, or partial-endpoint fallback sources covered by the audit rules.

What it does not prove: live gameplay NPCs complete every schedule route. That remains a headed gameplay acceptance responsibility.

Command:

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase9-route-state-writer-audit-after-source-clean.json -PassThruJson
```

Result: passed.

Report: `artifacts/npc/reports/phase9-route-state-writer-audit-after-source-clean.json`

What it proves: raw NPC route-state writes are locked to approved route authority files.

### Compile Smoke

Command:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Result: passed.

What it proves: the main menu and main scene still compile/load after the legacy fallback quarantine.

### Focused Route Tests

Command:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase9-route-tests-after-legacy-quarantine.json
```

Result: passed. `failureCount=0`, `resultCount=92`, `assertions=206`.

Report: `artifacts/npc/reports/phase9-route-tests-after-legacy-quarantine.json`

### Focused Behavior Tests

Command:

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase9-behavior-tests-after-legacy-quarantine.json
```

Result: passed. `failureCount=0`, `resultCount=49`, `assertions=117`.

Report: `artifacts/npc/reports/phase9-behavior-tests-after-legacy-quarantine.json`

## Exit Gate

Phase 9 exit gate: static audits prove production NPC movement has one route authority and no generated-cell/composed-door fallback path remains active.

Status: passed for the covered production source rules.

Next phase allowed: yes.
