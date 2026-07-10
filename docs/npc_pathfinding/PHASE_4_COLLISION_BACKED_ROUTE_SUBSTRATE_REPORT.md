# Phase 4 Collision-Backed Route Substrate Report

## Scope

Phase 4 adds the passive collision-backed route substrate required by `CODEX_NPC_PATHFINDING_REPLACEMENT_PHASE_PLAN.md`.

This phase does not wire production NPC movement to the new authority yet. It creates a simple collision-grid substrate that can classify route outcomes before Phase 5 adds mandatory probe-before-commit behavior.

## Implementation

- Added `scripts/npc_ai/routing/CollisionBackedRouteSubstrate.gd`.
- Added generated-town-style route fixture coverage in `scripts/testing/npc/NpcRouteTestCases.gd`.
- The substrate builds from generated-world navigation snapshots and validates route cells/edges through adapter collision APIs:
  - `build_snapshot` / `cached_validation_snapshot`
  - `cell_is_standable_goal`
  - `static_blocker`
  - `static_collision_blocker`
  - `dynamic_blocker`
  - `door_at`
  - `cell_transition_pathable`
  - `approach_cells_for_target`
- Route results expose structured fields:
  - `ok`
  - `status`
  - `classification`
  - `reason`
  - `cells`
  - `waypoints`
  - `visited`
  - `proof`
- Classifications covered:
  - `reachable`
  - `unreachable_static`
  - `invalid_goal`
  - `pending_nav_data`
  - `pending_budget`
  - `blocked_dynamic`
- Semantic candidate pose generation is available for:
  - `home_interior`
  - `home_exterior`
  - `work_area`
  - `forage_target`
  - `guard_post`
  - `interaction_target`

## Evidence

Compile smoke:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Result: passed.

Route state writer audit:

```powershell
.\tools\npc\assert-npc-route-state-writers.ps1 -ReportPath artifacts\npc\reports\phase4-route-state-writer-audit.json -PassThruJson
```

Result: passed.

Focused route substrate cases:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -Case npc_route_substrate_reachable_generated_town_fixture -TimeMode Both -ReportPath artifacts\npc\reports\phase4-substrate-reachable.json
.\tools\npc\run-npc-route-tests.ps1 -Case npc_route_substrate_blocked_generated_town_fixture -TimeMode Both -ReportPath artifacts\npc\reports\phase4-substrate-blocked.json
.\tools\npc\run-npc-route-tests.ps1 -Case npc_route_substrate_invalid_goal_generated_town_fixture -TimeMode Both -ReportPath artifacts\npc\reports\phase4-substrate-invalid-goal.json
.\tools\npc\run-npc-route-tests.ps1 -Case npc_route_substrate_pending_generated_town_fixture -TimeMode Both -ReportPath artifacts\npc\reports\phase4-substrate-pending.json
```

Results:

- `npc_route_substrate_reachable_generated_town_fixture`: passed day and night.
- `npc_route_substrate_blocked_generated_town_fixture`: passed day and night.
- `npc_route_substrate_invalid_goal_generated_town_fixture`: passed day and night.
- `npc_route_substrate_pending_generated_town_fixture`: passed day and night.

## What This Proves

- A route can be found through collision-validated generated-town cells.
- Door cells remain visible route evidence instead of being hidden behind a composed route shortcut.
- A static collision wall prevents routing and does not return a partial endpoint route as success.
- A non-standable endpoint is classified as `invalid_goal` before search.
- Missing nav data and exhausted route budget are classified as pending states, not as permanent unreachable targets.
- The new substrate does not create another unauthorized route-state writer.

## What This Does Not Prove

- This is not live gameplay acceptance evidence.
- This does not prove NPCs move correctly in the booted game.
- This does not yet prove physical actor sweeps before route commitment.
- This does not yet replace production NPC routing.

Those belong to later phases, especially Phase 5 and the live acceptance phases.

## Next Phase

Phase 5 should make the route authority consume this substrate and run mandatory collision probes before committing a route lease to an NPC.
