# NPC Pathfinding Regression Handoff

This document is for a fresh Codex instance taking over the NPC pathfinding regression. The core issue is not Niko, Mira, Rowan, or any single NPC. It is a systemic routing contract failure: NPC goals can be selected correctly, but the movement stack still lets real `CharacterBody3D` actors stall against doors, walls, fences, or route-readiness budgets.

## Required Context

- Read `AGENTS.md` first.
- For NPC/pathfinding work, also read `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`.
- Do not cite mocks, source scans, metadata checks, direct helper calls, teleporting, or synthetic tests as live gameplay acceptance.
- NPC/pathfinding acceptance must use real headed/live gameplay fixtures with real `CharacterBody3D` NPCs, real physics frames, real generated-world structures/doors, and real behavior scheduling.
- Door/home acceptance must visibly prove approach, door open, strict interior crossing, threshold clearance, and close-after-clearance.
- New headed NPC acceptance runners must call `tools/npc/assert-npc-acceptance-runner-clean.ps1` before launching Godot.
- Metadata goals are allowed. Authored/vector movement shortcuts are not. Routing must be collision-aware.

## Current Branch State

Branch at handoff: `master`.

The worktree is dirty. Relevant modified files at the time this document was created:

- `scripts/NpcPathing.gd`
- `scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd`
- `scripts/npc_ai/movement/NpcRouteMovementController.gd`
- `scripts/npc_ai/navigation/NavmeshWorldService.gd`
- `scripts/npc_ai/routing/IncrementalRouteRepair.gd`
- `scripts/npc_ai/routing/NavmeshRoutePlanner.gd`
- `scripts/npc_ai/routing/NpcNavigationCoordinator.gd`
- `scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd`
- `scripts/testing/npc/NpcRepairTestCases.gd`
- `scripts/testing/npc/NpcRouteTestCases.gd`
- `scripts/testing/npc/NpcTownJobCycleVisualPlaytestRunner.gd`

Important: `scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd` contains a partially applied, unverified route-readiness experiment. It sets `entry["navmeshRouteTilesStillLoading"]` and allows active job routes to proceed after queuing tiles, but it has not been tested after the interrupted turn. It also leaves a now-unreachable duplicate `if active_job_route: return false` branch immediately after the new active-job block. Treat this as unfinished work, not a proven fix.

## User-Observed Failures

- NPCs consistently stop outside or against their home doors/walls in real gameplay after clicking `New Game`.
- Mira can get stuck on the outside wall of her house post-knock dialogue.
- Niko, Mira, and Rowan have all been observed outside their doors instead of entering homes.
- A manual playtest found Niko stopping against a wooden wall, implying routing/execution is not truly collision-driven.
- The tutorial/live game behavior differs from prior tests: tests can pass while real gameplay launched from the main menu still fails.
- The user explicitly corrected the framing: this is an NPC pathfinding problem, not a Niko-specific problem.
- Foragers do not necessarily need a specific target. They need to leave town and roam safely until a forage target is in range.

## Evidence From Live Generated-Town Playtest

Known failing seed:

```text
town-nav-collision-20260708160218-1b2982bf
```

Known failing report:

```text
artifacts/npc/reports/town-job-cycle-visual-town-nav-collision-20260708160218-1b2982bf-query-path-20260708170929.json
```

Observed result:

- `failureCount`: 3
- `stoppedPhase`: `day`
- failed checks:
  - `day_forager_uses_builtin_forage`
  - `day_guard_uses_builtin_guard`
  - `day_non_guard_non_foragers_move_or_work_in_town`

The trace showed multiple NPCs stuck in route states such as:

- `pending/navmesh_tile_budget`
- `pending/route_budget`
- `frame_time_budget`
- `motion_budget`

Representative queued navmesh tile contexts from the failing run involved different actors and jobs:

- Mara, forager, tile `18,69`
- Pell, forager, tile `16,71`
- Brin, stone worker, tile `17,68`
- Brin, trader, tile `16,68`

This proves the failure is a shared route/navmesh readiness problem, not one NPC profile.

## Focused Tests That Were Passing

These are useful regression checks, but they are not sufficient acceptance evidence:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-repair-tests.ps1 -TimeMode Both
```

Recent focused reports had `failureCount: 0`:

- `artifacts/npc/reports/route-both.json`
- `artifacts/npc/reports/nav_world-both.json`
- `artifacts/npc/reports/behavior-both.json`
- `artifacts/npc/reports/repair-both.json`

Do not treat these as proof that live NPC pathfinding is fixed.

## Current Diagnosis

The present system is too fragmented:

- Behavior chooses semantic goals.
- `NpcSemanticGoalPlanner.gd` derives target/fallback cells.
- `NpcRouteCoordinatorAdapter.gd` gates route planning on navmesh tile publication and route budgets.
- `NavmeshRoutePlanner.gd` queries `NavmeshWorldService.gd`.
- `NpcRouteMovementController.gd` executes waypoints through `CharacterBody3D`.
- Door services and traffic reservations add additional constraints.

The systemic failure appears in the seams between these pieces:

- Endpoint/corridor navmesh tile readiness can block active job routes for the whole day window.
- Route cache keys include navmesh topology revision, while tile publication changes topology revision. Under load, route reuse can churn.
- Live NPCs can remain pending while multiple actors repeatedly queue endpoint/corridor tiles.
- Motion budgets can starve actors even after route work begins.
- Fallback/approach cells may be valid semantically but not actually reachable by the collision/navmesh backend.
- Some previous generated-cell bridge fallbacks produced routes that looked valid in XZ cells but could drive smoothed `CharacterBody3D` motion into walls. Those shortcuts must not return as production routes.

## Blockers To Resolve

1. Live route readiness does not reliably graduate from `pending` to a real collision-backed route under multi-NPC town load.
2. Endpoint and corridor tile publication are coupled to route planning in a way that can starve routine job movement.
3. Route cache invalidation is sensitive to navmesh topology churn from tile publishing.
4. Route failures are not clearly separated into:
   - still loading nav data;
   - route genuinely unreachable;
   - dynamic local blockage;
   - behavior target invalid.
5. Movement scheduling can skip too many actors (`motion_budget` / `frame_time_budget`) and make route success look like pathfinding failure.
6. Existing tests under-represent real main-menu `New Game` gameplay and generated-town multi-actor contention.

## Mature Pathfinding Approach

Implement a stricter navigation contract:

```text
semantic goal -> candidate goal cells -> collision-backed reachability -> route lease -> CharacterBody3D execution -> live collision validation/replan
```

The behavior layer may say “go home,” “guard,” “work,” or “forage.” It must not directly imply movement success. The routing layer owns reachability and must only return executable routes that are backed by collision/navigation data.

### Core Rules

- `NavmeshWorldService` / a new route service must be the production authority for NPC route reachability.
- Generated-cell bridges may remain only for diagnostics or tests explicitly labeled as synthetic. They must not produce accepted production NPC routes.
- A target is reachable only after the route service confirms it through collision-backed navigation.
- Missing navmesh tiles should produce `pending_nav_data`, not `unreachable`.
- A real unreachable result should only occur after required nav data is ready and the route query fails.
- NPC movement must consume route corridors/waypoints through `CharacterBody3D`, with local collision checks and replan triggers.
- Foragers should support collision-aware roaming outside town when no target is currently in range.
- Door traversal must remain portal-owned: open before crossing, keep active ownership until clearance/cancel, close after clearance.

## Proposed Implementation Phases

### Phase 0: Stabilize The Inherited Branch

- Inspect all dirty changes.
- Decide whether to complete or revert the partial `navmeshRouteTilesStillLoading` experiment.
- Keep the existing useful telemetry, but remove confusing dead branches.
- Run focused route/nav-world tests only to ensure the branch loads before live playtests.

### Phase 1: Formal Route Result Contract

Create or enforce route result states:

- `ready`: executable collision-backed route.
- `pending_nav_data`: required tiles/links are still publishing.
- `pending_budget`: route/nav computation deferred by budget.
- `blocked_dynamic`: temporary actor/door/traffic obstruction.
- `unreachable_static`: all required nav data is ready and no route exists.
- `invalid_goal`: semantic target is not a legal goal cell.

Every caller must handle these states differently. Do not let `pending_nav_data` poison smart-object targets as unreachable.

### Phase 2: Collision-Aware Goal Projection

For each semantic goal:

- Generate candidate cells from metadata, home interiors, work areas, guard posts, or roam envelopes.
- Filter by static collision, door legality, private interior rules, town limits, and terrain occupancy.
- Ask the route service which candidate is actually reachable.
- Commit the behavior target only after a route is ready or after the service explicitly says no candidate is statically reachable.

For foragers:

- If no forage object is route-ready, choose a collision-reachable roam point outside town.
- Continue roaming/searching until forage appears in range.
- Do not mark forage behavior failed just because a specific berry target is unavailable.

### Phase 3: Navmesh Tile Lifecycle

Replace ad hoc route-time tile publishing with a fair lifecycle:

- Endpoint tiles are highest priority.
- Door/gate/perimeter tiles get priority when involved in home/job routes.
- Corridor tiles are queued fairly by actor or route request, not by global FIFO alone.
- Publishing must be bounded per frame and measured.
- Published tile snapshots should be keyed by static/semantic revision, not dynamic actor movement.
- Route cache invalidation should ignore topology churn caused only by installing already-current tile snapshots.
- Missing required tiles should be observable as `pending_nav_data` with tile keys and actor context.

### Phase 4: Route Planning Service

Introduce a single route broker around current planner pieces:

- Accept `RouteRequest(actor, kind, start, candidate_goals, constraints)`.
- Ensure required nav data or return `pending_nav_data`.
- Query the navmesh backend.
- Validate path against static collision, doors, private interiors, and forbidden links.
- Return a route lease with snapshot revision and constraints.
- Revoke/repair leases on relevant navigation events.

The broker can wrap existing `NpcRouteCoordinatorAdapter`, `NavmeshRoutePlanner`, and `NavmeshWorldService` first. The important change is the contract, not file churn.

### Phase 5: Movement Execution

`NpcRouteMovementController.gd` should:

- Execute only `ready` route leases.
- Preserve active route while a replacement is `pending_nav_data`.
- Replan on repeated local collision, route lease invalidation, door cancellation, or actor displacement.
- Never continue a route whose validation says it crosses static collision.
- Record why an actor is stationary: no route, pending nav data, local collision, door wait, traffic wait, motion budget, or arrived.

### Phase 6: Live Acceptance Gates

Acceptance must include:

1. Rerun the known failing generated-town seed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\npc\run-npc-town-job-cycle-visual-playtest.ps1 -Seed town-nav-collision-20260708160218-1b2982bf -ReportPath artifacts\npc\reports\town-job-cycle-visual-town-nav-collision-20260708160218-1b2982bf-fixed.json -ProgressPath artifacts\npc\progress\town-job-cycle-visual-town-nav-collision-20260708160218-1b2982bf-fixed.txt -ScreenshotDir artifacts\npc\screenshots\town-job-cycle-visual-town-nav-collision-20260708160218-1b2982bf-fixed -TimeoutSeconds 620 -StaleProgressSeconds 120
```

2. Run multiple fresh random generated-town seeds.

3. Run the real tutorial playthrough from main-menu/New Game flow, not a hand-picked service fixture.

4. Inspect screenshots and traces for:

- NPCs not stuck on exterior walls.
- Foragers leaving town and roaming safely.
- Workers/guards moving to real reachable work/guard areas.
- NPCs returning indoors at night.
- Door open/cross/close sequence.
- No production route source using generated-cell bridge.

5. Run focused tests after the live issue is fixed:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-repair-tests.ps1 -TimeMode Both
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both
.\tools\run-all-test-runners.ps1
```

## Telemetry Needed Before Claiming Success

Add or preserve bounded report fields:

- actor id/name/job/goal;
- route state and reason;
- candidate goal cells and selected cell;
- endpoint tile keys;
- missing tile keys;
- route query API used;
- start/target walkable source;
- route source;
- `generatedCellBridgeUsed`;
- navmesh tile publish queue depth;
- queued tile contexts;
- route wait frames;
- motion skipped reason;
- door portal id/state;
- screenshot path for visual confirmation.

## Do Not Repeat These Mistakes

- Do not patch around Niko, Mira, or Rowan individually.
- Do not make tests pass by directly calling tutorial handlers, door helpers, metadata setters, or NPC movement helpers.
- Do not teleport actors or call `npc_system.move_npc` as acceptance evidence.
- Do not use authored vectors/coordinated door offsets as proof of pathfinding.
- Do not re-enable generated-cell bridge production routes for jobs/home.
- Do not mark a target unreachable while navmesh data is still pending.
- Do not cite focused unit/contract tests as proof that live gameplay pathfinding is fixed.

## Current Working Hypothesis

The immediate live blocker is the route-readiness/budget protocol. Multiple active NPCs request collision-backed navmesh tiles, but route planning stays pending while tile publication and topology revision churn continue. Because movement and route retries are budgeted, actors can spend the whole observation window outside homes or at walls. A mature fix must separate nav-data loading from true unreachable routes, make tile publication fair and endpoint-first, and route every committed movement through the collision-backed navmesh service.

