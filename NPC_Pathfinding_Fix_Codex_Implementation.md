# NPC Pathfinding Fix Implementation Guide for Codex

This is the exact implementation playbook for stabilizing the NPC pathfinding stack in this Godot project.

Use this as an execution script. Start at Phase 0. Do not reorder phases. Do not skip verification. The first phases fix correctness and consistency bugs; the later phases make the system mature and consistently functional under load.

---

## Objective

Make NPC pathfinding reliable by ensuring that:

1. Movement substeps use the correct physics delta.
2. NPC component initialization cannot permanently fail after one partial attempt.
3. Navmesh tile snapshots, collision snapshots, door snapshots, and route probes all read the same world state.
4. Route reuse does not keep stale routes alive after actor displacement or world revision changes.
5. Essential navmesh tiles are primed before active gameplay instead of being lazily generated during the first NPC movement request.
6. Route/tile/probe budgets drain predictably and do not starve active NPCs.
7. Every route failure or delay has a visible diagnostic reason.
8. Generated-cell fallback is reintroduced only where safe and only behind the authoritative collision probe.
9. Movement no longer synchronously waits on navmesh/tile/probe work; it uses route tickets for multi-frame route preparation.
10. The fix is protected by tests and acceptance criteria.

---

## Hard rules

Codex must follow these rules while editing:

1. **Do not bypass `NpcRouteAuthority`.** Every route that movement follows must still receive an authority lease.
2. **Do not disable collision probing to “make NPCs move.”** That hides the bug and reintroduces wall clipping.
3. **Do not globally re-enable generated-cell routes.** Generated-cell routes may only be used for safe open-terrain fallback, and they must still be passed through `NpcRouteAuthority`.
4. **Do not use a per-frame current-cell route key for active routes.** That causes constant replanning as the NPC walks. Start cell belongs to new route requests and stale-route invalidation, not to every active-route comparison.
5. **Do not raise budgets without diagnostics.** Higher budgets are allowed, but the system must also report why routes are pending or blocked.
6. **Preserve the existing GDScript indentation style in each file.** Use tabs in files that use tabs, spaces in files that use spaces.
7. **Make small commits or small patch groups.** After each phase, run the listed tests before continuing.

---

## Repository paths touched

Primary files:

```text
scripts/npc_ai/routing/NpcNavigationCoordinator.gd
scripts/NpcSystem.gd
scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd
scripts/npc_ai/movement/NpcRouteMovementController.gd
scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd
scripts/MainCore.gd
scripts/NpcStats.gd
scripts/npc_ai/debug/NpcDebugStateExporter.gd
scripts/npc_ai/NpcConstants.gd
```

New files added in the route-ticket phase:

```text
scripts/npc_ai/contracts/RouteTicket.gd
scripts/npc_ai/routing/NpcRouteTicketBroker.gd
```

Test files:

```text
scripts/testing/npc/NpcAutonomyTestRunner.gd
scripts/NpcNavigationTestRunner.gd
```

---

## Phase 0 — Establish a clean baseline

### 0.1 Create a branch

```powershell
git checkout -b fix/npc-pathfinding-authoritative-stabilization
```

### 0.2 Run compile smoke before edits

```powershell
.\tools\run-project-compile-smoke.ps1
```

### 0.3 Run the relevant existing NPC suites before edits

Run these even if some fail. Save the reports so the final result can be compared to the baseline.

```powershell
.\tools\npc\run-npc-suite.ps1 -Suite contract -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite nav_world -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite motor -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite route -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite door -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite behavior -TimeMode Both -WatchdogSeconds 60
```

Also run the visual/navigation playtest if the machine can run Godot scenes:

```powershell
.\tools\run-npc-navigation-tests.ps1
```

Do not try to fix failures in this phase. Record what fails.

---

## Phase 1 — Add safety feature flags

Edit:

```text
scripts/npc_ai/NpcConstants.gd
```

Add these constants near the top, after `NPC_MOVEMENT_STACK`:

```gdscript
const NPC_NAV_ENABLE_STARTUP_TILE_PRIMING := true
const NPC_NAV_ENABLE_ADAPTIVE_ROUTE_BUDGET := true
const NPC_NAV_ENABLE_SAFE_GENERATED_OPEN_TERRAIN_FALLBACK := true
const NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE := false
const NPC_NAV_DEBUG_ROUTE_REASONS := true
```

Leave `NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE` as `false` until Phase 8. The earlier phases must pass before enabling it.

### Verification

```powershell
.\tools\run-project-compile-smoke.ps1
```

Expected result: compile succeeds.

---

## Phase 2 — Apply immediate correctness fixes

### 2.1 Fix substep delta handling

Edit:

```text
scripts/npc_ai/routing/NpcNavigationCoordinator.gd
```

Find this line in `move_npc()`:

```gdscript
var moved := _move_npc_step(entry, target, step_distance, moving_home, allow_outside, physics_delta)
```

Replace it with:

```gdscript
var moved := _move_npc_step(entry, target, step_distance, moving_home, allow_outside, step_delta)
```

Reason: the code already calculates `step_delta`, but each substep currently receives the original full-frame `physics_delta`. That makes avoidance, corridor timing, traffic reservation timing, and movement intent timing inconsistent.

### 2.2 Make component setup retryable

Edit:

```text
scripts/NpcSystem.gd
```

Near the existing component flags:

```gdscript
var components_initialized := false
var component_init_attempted := false
```

Add:

```gdscript
var component_init_in_progress := false
```

Replace the whole `ensure_components()` function with this retry-safe version:

```gdscript
func ensure_components() -> void:
    if components_initialized or component_init_in_progress:
        return

    component_init_in_progress = true
    component_init_attempted = true

    if visual_factory == null:
        visual_factory = NpcVisualFactoryScript.new()
        visual_factory.setup(main)

    if pathing == null:
        pathing = NpcPathingScript.new()
        pathing.setup(self, main)

    if combat == null and visual_factory != null:
        combat = NpcCombatScript.new()
        combat.setup(self, hostile_system, visual_factory.arrow_material)

    if motion_controller == null:
        motion_controller = NpcMotionControllerScript.new()
        motion_controller.setup(self, main)

    if safe_placement_service == null:
        safe_placement_service = NpcSafePlacementServiceScript.new()
        safe_placement_service.setup(self, main)

    components_initialized = visual_factory != null \
        and pathing != null \
        and combat != null \
        and motion_controller != null \
        and safe_placement_service != null

    component_init_in_progress = false
```

Important: after this change, `component_init_attempted` is diagnostic only. It must not block a future retry.

### 2.3 Run verification

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite motor -TimeMode Both -WatchdogSeconds 60
```

Expected result:

```text
compile passes
motor suite passes or has fewer movement timing failures than baseline
```

Do not proceed until compile passes.

---

## Phase 3 — Make navmesh tile snapshots collision-consistent

This phase fixes the planner/probe/motor disagreement.

### 3.1 Use the stronger live tile snapshot helper

Edit:

```text
scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd
```

In `build_navmesh_tile_snapshot(tile_key: String)`, find:

```gdscript
var snapshot: Dictionary = _snapshot_with_live_tile_blocks_for_navmesh_tile(cached_static_tile_snapshot(true, true), tile_key)
```

Replace it with:

```gdscript
var snapshot: Dictionary = _snapshot_with_live_tile_blocks(cached_static_tile_snapshot(true, true), tile_key)
```

Reason: `_snapshot_with_live_tile_blocks_for_navmesh_tile()` updates only `blocked`, `doors`, and `paths`. `_snapshot_with_live_tile_blocks()` also rebuilds `staticCollision`, `staticCollisionByCell`, `doorCollision`, and `doorCollisionByCell`. The navmesh planner, collision probe, and CharacterBody motor need the same collision snapshot.

### 3.2 Include door state in navmesh tile source keys

In the same file, replace:

```gdscript
func navmesh_tile_source_key() -> String:
    return "%d:%d" % [static_snapshot_revision, semantic_revision]
```

with:

```gdscript
func navmesh_tile_source_key() -> String:
    return "%d:%d:%d" % [static_snapshot_revision, semantic_revision, door_state_revision]
```

Then replace the return at the end of `navmesh_tile_source_key_for_tile(tile_key: String)`.

Current:

```gdscript
return "%d:%d" % [tile_revision, tile_semantic_revision]
```

Replace with:

```gdscript
return "%d:%d:%d" % [tile_revision, tile_semantic_revision, door_state_revision]
```

Reason: door state changes alter usable portals/links. A tile cache key that ignores door state can reuse stale door-link snapshots.

### 3.3 Add a comment to prevent regression

Immediately above `build_navmesh_tile_snapshot()`, add:

```gdscript
# IMPORTANT: navmesh tile snapshots must be built from the same live collision
# snapshot used by collision probing. Do not switch this back to the lighter
# helper that only updates blocked/doors/paths; that reintroduces planner/probe
# disagreement and makes NPCs accept routes into walls or reject valid routes.
```

### 3.4 Run verification

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite nav_world -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite door -TimeMode Both -WatchdogSeconds 60
```

Expected result:

```text
compile passes
nav_world passes or improves from baseline
door suite passes or improves from baseline
```

If a navmesh descriptor determinism test changes because the source key now includes door revision, update the expected assertion to include the new door-revision component. Do not remove the door revision from the key.

---

## Phase 4 — Make route reuse safe without causing replan churn

The goal is to prevent stale route reuse while avoiding constant replans as an NPC walks.

### 4.1 Prefer the full world revision for route reuse

Edit:

```text
scripts/npc_ai/movement/NpcRouteMovementController.gd
```

Replace `route_reuse_revision(world)` with:

```gdscript
func route_reuse_revision(world) -> String:
    if world != null and world.has_method("revision"):
        return String(world.revision())
    if world != null and world.has_method("navmesh_tile_source_key"):
        return String(world.navmesh_tile_source_key())
    return ""
```

Reason: route reuse should be conservative. It must notice static, semantic, dynamic, and door-state changes. Tile build keys can remain more selective, but movement route reuse should not preserve a potentially stale route across world-revision changes.

### 4.2 Split goal identity from request start identity

Still in `NpcRouteMovementController.gd`, edit `ensure_route(entry, intent, planner, world)`.

Near the top of the function, after `target_cell` is calculated, add start-position and current-waypoint calculation before the route key is built.

Replace this block:

```gdscript
var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", Vector3.ZERO)))
var route_key: String = "%s:%d,%d:%s:%s:%s:%s:%.3f" % [
    String(intent.get("kind", "move")),
    target_cell.x,
    target_cell.y,
    str(bool(intent.get("allowOutside", false))),
    str(bool(intent.get("movingHome", false))),
    String(intent.get("action", "")),
    str(bool(intent.get("strictArrival", false))),
    float(intent.get("arrivalRadius", CELL * 0.75))
]
```

with this block:

```gdscript
var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", Vector3.ZERO)))
var body := entry.get("body") as Node3D
var start_position: Vector3 = body.global_position if body != null and is_instance_valid(body) else entry.get("position", entry.get("porchPosition", intent.get("target", Vector3.ZERO)))
var start_cell: Vector2i = world.world_cell(start_position)
var current_waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
var has_active_route := not current_waypoints.is_empty()
var route_key_start_cell: Vector2i = entry.get("routeStartCell", start_cell) if has_active_route and entry.get("routeStartCell", null) is Vector2i else start_cell

var goal_key: String = "%s:%d,%d:%s:%s:%s:%s:%.3f" % [
    String(intent.get("kind", "move")),
    target_cell.x,
    target_cell.y,
    str(bool(intent.get("allowOutside", false))),
    str(bool(intent.get("movingHome", false))),
    String(intent.get("action", "")),
    str(bool(intent.get("strictArrival", false))),
    float(intent.get("arrivalRadius", CELL * 0.75))
]

var route_key: String = "%d,%d->%s" % [
    route_key_start_cell.x,
    route_key_start_cell.y,
    goal_key
]
```

Then delete or avoid the later duplicate declaration:

```gdscript
var current_waypoints: Array = entry.get("pathWaypoints", [])
```

There must be exactly one `current_waypoints` variable in this function.

### 4.3 Add active-route drift detection

Add this helper function near `route_reuse_revision(world)`:

```gdscript
func active_route_drifted_from_position(entry: Dictionary, current_waypoints: Array, start_position: Vector3, world) -> bool:
    if current_waypoints.is_empty():
        return false
    if world == null or not world.has_method("world_cell"):
        return false

    var current_cell: Vector2i = world.world_cell(start_position)
    var stored_current_cell: Vector2i = entry.get("routeLastKnownCell", current_cell)
    entry["routeLastKnownCell"] = current_cell

    # Normal movement changes cells. That is not drift by itself.
    # Drift means the actor is no longer near the next remaining waypoint.
    var first_waypoint_value = current_waypoints[0]
    if not (first_waypoint_value is Vector3):
        return true

    var first_waypoint: Vector3 = first_waypoint_value
    var distance_to_first := start_position.distance_to(first_waypoint)
    if distance_to_first > CELL * 4.0:
        var last_cell_distance := absi(current_cell.x - stored_current_cell.x) + absi(current_cell.y - stored_current_cell.y)
        if last_cell_distance > 2:
            return true

    return false
```

This deliberately uses a forgiving threshold. It should catch teleports, unstuck displacement, and route corruption without forcing a replan every time the NPC advances normally.

### 4.4 Use goal-key comparison and drift in `ensure_route()`

Find the existing comparison section:

```gdscript
var stored_route_key := String(entry.get("routeKey", ""))
var pending_route_key := String(entry.get("routePendingKey", ""))
var comparison_route_key := stored_route_key if stored_route_key != "" else pending_route_key
var comparison_snapshot_revision := String(entry.get("routeSnapshotRevision", ""))
if comparison_snapshot_revision == "" and pending_route_key != "":
    comparison_snapshot_revision = String(entry.get("routePendingSnapshotRevision", ""))
var route_known := comparison_route_key != ""
var current_waypoints: Array = entry.get("pathWaypoints", [])
```

After Phase 4.2, `current_waypoints` already exists. Replace the comparison block with:

```gdscript
var stored_route_key := String(entry.get("routeKey", ""))
var pending_route_key := String(entry.get("routePendingKey", ""))
var stored_goal_key := String(entry.get("routeGoalKey", ""))
var pending_goal_key := String(entry.get("routePendingGoalKey", ""))
var comparison_route_key := stored_route_key if stored_route_key != "" else pending_route_key
var comparison_goal_key := stored_goal_key if stored_goal_key != "" else pending_goal_key
var comparison_snapshot_revision := String(entry.get("routeSnapshotRevision", ""))
if comparison_snapshot_revision == "" and pending_route_key != "":
    comparison_snapshot_revision = String(entry.get("routePendingSnapshotRevision", ""))
var route_known := comparison_route_key != ""
```

Then replace:

```gdscript
var route_key_changed := comparison_route_key != route_key
```

with:

```gdscript
var goal_key_changed := comparison_goal_key != goal_key
var active_route_drifted := active_route_drifted_from_position(entry, current_waypoints, start_position, world)
var route_key_changed := goal_key_changed or active_route_drifted or (current_waypoints.is_empty() and comparison_route_key != route_key)
```

Reason: while an NPC is actively following waypoints, the route key must not change merely because the NPC has moved to the next cell. But if the goal changes, the route is empty, or the actor has drifted far away from the route, replanning is required.

### 4.5 Store route start and goal keys when pending or successful

In the pending-route block, after:

```gdscript
entry["routePendingKey"] = route_key
entry["routePendingSnapshotRevision"] = snapshot_revision
```

add:

```gdscript
entry["routePendingGoalKey"] = goal_key
entry["routePendingStartCell"] = start_cell
```

In the successful-route install block, after:

```gdscript
entry["routeKey"] = route_key
entry["routeGoalCell"] = target_cell
```

add:

```gdscript
entry["routeGoalKey"] = goal_key
entry["routeStartCell"] = start_cell
entry["routeLastKnownCell"] = start_cell
```

Also, when clearing pending route metadata, after:

```gdscript
entry.erase("routePendingSnapshotRevision")
```

add:

```gdscript
entry.erase("routePendingGoalKey")
entry.erase("routePendingStartCell")
```

### 4.6 Run verification

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite motor -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite route -TimeMode Both -WatchdogSeconds 60
```

Expected result:

```text
compile passes
route tests do not show continuous replanning
motor tests do not show stale-route preservation after displacement
```

If route replans spike badly, check that `route_key_changed` is not true merely because `start_cell` changes during normal movement.

---

## Phase 5 — Prime essential navmesh tiles at startup

The game currently builds the static navigation snapshot, but returns immediately from both startup tile-priming functions. That makes first NPC movement pay the tile-generation cost. Fix that.

### 5.1 Add a helper to get the active route delegate

Edit:

```text
scripts/MainCore.gd
```

Add this helper above `prime_initial_navigation_tiles_staged()`:

```gdscript
func initial_navigation_route_delegate():
    if npc_system == null:
        return null
    var pathing = npc_system.get("pathing")
    if pathing == null:
        return null
    var coordinator = pathing.get("coordinator")
    if coordinator == null:
        return null
    return coordinator.get("route_delegate")
```

### 5.2 Add a helper to publish one startup tile immediately

Add this helper below `initial_navigation_route_delegate()`:

```gdscript
func publish_startup_navmesh_tile(navigation_world, route_delegate, tile_key: String) -> bool:
    if navigation_world == null or route_delegate == null or tile_key == "":
        return false
    if not navigation_world.has_method("build_navmesh_tile_snapshot"):
        return false
    var navmesh_world = route_delegate.get("navmesh_world")
    if navmesh_world == null or not navmesh_world.has_method("register_tile_snapshot"):
        return false
    var snapshot: Dictionary = navigation_world.call("build_navmesh_tile_snapshot", tile_key)
    if snapshot.is_empty():
        return false
    var result: Dictionary = navmesh_world.call("register_tile_snapshot", snapshot)
    if navmesh_world.has_method("sync_navigation_map_if_dirty"):
        navmesh_world.call("sync_navigation_map_if_dirty")
    var status := String(result.get("status", ""))
    return bool(result.get("installed", false)) or status in ["installed", "updated", "registered"]
```

### 5.3 Implement the staged startup priming function

Replace the body of `prime_initial_navigation_tiles_staged(navigation_world, entries: Array)` with:

```gdscript
func prime_initial_navigation_tiles_staged(navigation_world, entries: Array) -> void:
    if not NpcConstantsScript.NPC_NAV_ENABLE_STARTUP_TILE_PRIMING:
        return
    if navigation_world == null:
        return

    var route_delegate = initial_navigation_route_delegate()
    if route_delegate == null:
        return

    var tile_keys := {}
    for entry_value in entries:
        if tile_keys.size() >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        if entry_value is Dictionary:
            prime_navigation_tiles_for_entry(navigation_world, entry_value, tile_keys)

    var total := mini(tile_keys.size(), INITIAL_NAVMESH_PRIME_TILE_LIMIT)
    var published := 0
    for tile_key_value in tile_keys.keys():
        if published >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        var tile_key := String(tile_key_value)
        await startup_loading_yield("Preparing NPC route tiles %d/%d" % [published, total])
        if publish_startup_navmesh_tile(navigation_world, route_delegate, tile_key):
            published += 1
```

### 5.4 Implement the synchronous startup priming function

Replace the body of `prime_initial_navigation_tiles(navigation_world, entries: Array)` with:

```gdscript
func prime_initial_navigation_tiles(navigation_world, entries: Array) -> void:
    if not NpcConstantsScript.NPC_NAV_ENABLE_STARTUP_TILE_PRIMING:
        return
    if navigation_world == null:
        return

    var route_delegate = initial_navigation_route_delegate()
    if route_delegate == null:
        return

    var tile_keys := {}
    for entry_value in entries:
        if tile_keys.size() >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        if entry_value is Dictionary:
            prime_navigation_tiles_for_entry(navigation_world, entry_value, tile_keys)

    var published := 0
    for tile_key_value in tile_keys.keys():
        if published >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        if publish_startup_navmesh_tile(navigation_world, route_delegate, String(tile_key_value)):
            published += 1
```

### 5.5 Ensure `NpcConstantsScript` is available in `MainCore.gd`

At the top of `MainCore.gd`, add a preload if it is not already present:

```gdscript
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
```

Place it near the other constants/preloads.

### 5.6 Run verification

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite nav_world -TimeMode Both -WatchdogSeconds 60
.\tools\run-npc-navigation-tests.ps1
```

Expected result:

```text
compile passes
startup does not hang
first NPC route requests show fewer navmesh_tile_budget/navmesh_tile_loading waits
```

If startup becomes too slow, lower `INITIAL_NAVMESH_PRIME_TILE_LIMIT` from `32` to `24`, but do not return to zero tile priming.

---

## Phase 6 — Make route and tile budgets adaptive

The current fixed budgets are too low for active towns. This phase keeps hard limits but allows the queue to drain under load.

### 6.1 Increase the base constants safely

Edit:

```text
scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd
```

At the top, change these constants:

```gdscript
const LIVE_ROUTE_JOBS_PER_FRAME := 2
const NAVMESH_TILE_PUBLISHES_PER_FRAME := 1
const BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME := 1
const PRIORITY_NAVMESH_TILE_PUBLISHES_PER_FRAME := 4
```

to:

```gdscript
const LIVE_ROUTE_JOBS_PER_FRAME := 6
const LIVE_ROUTE_JOBS_MAX_PER_FRAME := 24
const NAVMESH_TILE_PUBLISHES_PER_FRAME := 4
const NAVMESH_TILE_PUBLISHES_MAX_PER_FRAME := 32
const BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME := 2
const PRIORITY_NAVMESH_TILE_PUBLISHES_PER_FRAME := 8
```

### 6.2 Add adaptive budget helpers

Add these helper functions near `_claim_route_budget()` and `_claim_navmesh_tile_publish_budget()`:

```gdscript
func _active_route_pressure() -> int:
    if system == null:
        return 0
    var entries_value = system.get("npcs")
    if not (entries_value is Array):
        return 0
    var pressure := 0
    for entry_value in entries_value:
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        var status := String(entry.get("routeStatus", ""))
        if status in ["moving", "pending", "waiting"]:
            pressure += 1
        elif int(entry.get("routeBudgetWaitFrames", 0)) > 0 or int(entry.get("navmeshTileBudgetWaitFrames", 0)) > 0:
            pressure += 1
    return pressure

func _live_route_job_limit() -> int:
    if not NpcConstantsScript.NPC_NAV_ENABLE_ADAPTIVE_ROUTE_BUDGET:
        return LIVE_ROUTE_JOBS_PER_FRAME
    var pressure := _active_route_pressure()
    var adaptive := ceili(float(pressure) / 4.0)
    return clampi(maxi(LIVE_ROUTE_JOBS_PER_FRAME, adaptive), LIVE_ROUTE_JOBS_PER_FRAME, LIVE_ROUTE_JOBS_MAX_PER_FRAME)

func _navmesh_tile_publish_limit(extra_budget := 0) -> int:
    var base_limit := NAVMESH_TILE_PUBLISHES_PER_FRAME + maxi(0, int(extra_budget))
    if not NpcConstantsScript.NPC_NAV_ENABLE_ADAPTIVE_ROUTE_BUDGET:
        return base_limit
    var queued_pressure := ceili(float(queued_navmesh_tile_keys.size()) / 8.0)
    return clampi(base_limit + queued_pressure, NAVMESH_TILE_PUBLISHES_PER_FRAME, NAVMESH_TILE_PUBLISHES_MAX_PER_FRAME)
```

If `NpcConstantsScript` is not preloaded in this file, add this near the other preloads:

```gdscript
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
```

### 6.3 Use the adaptive route limit

In `_claim_route_budget()`, find:

```gdscript
if route_jobs_this_frame >= LIVE_ROUTE_JOBS_PER_FRAME:
```

Replace with:

```gdscript
if route_jobs_this_frame >= _live_route_job_limit():
```

### 6.4 Use the adaptive tile publish limit

In `_claim_navmesh_tile_publish_budget(extra_budget := 0)`, replace:

```gdscript
var publish_limit := NAVMESH_TILE_PUBLISHES_PER_FRAME + maxi(0, int(extra_budget))
```

with:

```gdscript
var publish_limit := _navmesh_tile_publish_limit(extra_budget)
```

### 6.5 Record budget pressure in stats

Find `stats()` in `NpcRouteCoordinatorAdapter.gd`. If it already exists, extend it. If not, add one.

It must include at least:

```gdscript
"activeRoutePressure": _active_route_pressure(),
"liveRouteJobLimit": _live_route_job_limit(),
"navmeshTilePublishLimit": _navmesh_tile_publish_limit(0),
"queuedNavmeshTiles": queued_navmesh_tile_keys.size(),
"priorityQueuedNavmeshTiles": queued_navmesh_tile_priority_keys.size(),
"routeJobsThisFrame": route_jobs_this_frame,
"navmeshTilePublishesThisFrame": navmesh_tile_publishes_this_frame
```

Do not remove existing stats fields.

### 6.6 Run verification

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite route -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite nav_world -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite behavior -TimeMode Both -WatchdogSeconds 60
```

Expected result:

```text
route_budget and navmesh_tile_budget waits decrease
no large frame stalls in normal tests
no pathfinding tests regress because of missing authority leases
```

---

## Phase 7 — Add route diagnostics that show why movement is blocked

This phase makes failure visible and prevents future guessing.

### 7.1 Extend NPC stats with route reasons and authority states

Edit:

```text
scripts/NpcStats.gd
```

In `build(system)`, near the existing route counters:

```gdscript
var routed := 0
var waiting_routes := 0
var blocked_routes := 0
var partial_routes := 0
```

Add:

```gdscript
var route_reasons := {}
var route_authority_states := {}
var route_authority_reasons := {}
var max_route_budget_wait := 0
var max_navmesh_tile_budget_wait := 0
var pending_routes := 0
```

Inside the NPC loop, after `route_status` is calculated, add:

```gdscript
if route_status == "pending":
    pending_routes += 1

var route_reason := String(entry.get("routeReason", "none"))
if route_reason == "":
    route_reason = "none"
route_reasons[route_reason] = int(route_reasons.get(route_reason, 0)) + 1

var authority: Dictionary = entry.get("lastRouteAuthority", {}) if entry.get("lastRouteAuthority", {}) is Dictionary else {}
var authority_state := String(authority.get("state", "none"))
if authority_state == "":
    authority_state = "none"
route_authority_states[authority_state] = int(route_authority_states.get(authority_state, 0)) + 1

var authority_reason := String(authority.get("reason", "none"))
if authority_reason == "":
    authority_reason = "none"
route_authority_reasons[authority_reason] = int(route_authority_reasons.get(authority_reason, 0)) + 1

max_route_budget_wait = maxi(max_route_budget_wait, int(entry.get("routeBudgetWaitFrames", 0)))
max_navmesh_tile_budget_wait = maxi(max_navmesh_tile_budget_wait, int(entry.get("navmeshTileBudgetWaitFrames", 0)))
```

In the returned dictionary, extend `routeStatus`:

```gdscript
"routeStatus": {
    "routed": routed,
    "waiting": waiting_routes,
    "pending": pending_routes,
    "blocked": blocked_routes,
    "partial": partial_routes
},
"routeReasons": route_reasons,
"routeAuthorityStates": route_authority_states,
"routeAuthorityReasons": route_authority_reasons,
"routeWaitFrames": {
    "maxRouteBudget": max_route_budget_wait,
    "maxNavmeshTileBudget": max_navmesh_tile_budget_wait
},
```

Do not remove existing returned fields.

### 7.2 Extend runtime debug export per NPC

Edit:

```text
scripts/npc_ai/debug/NpcDebugStateExporter.gd
```

In `_runtime_route_state()`, inside each route dictionary, extend the record.

Current record contains fields like:

```gdscript
"status": String(entry.get("routeStatus", "idle")),
"reason": String(entry.get("routeReason", "")),
"targetCell": str(entry.get("routeGoalCell", "")),
"pathAge": float(entry.get("pathRefreshTimer", 0.0)),
"waypoints": path_waypoints.size(),
"cells": route_cells.size(),
"actions": route_actions.size(),
"nextDoor": String(entry.get("activeDoorPortalId", ""))
```

Add these fields:

```gdscript
"routeKey": String(entry.get("routeKey", "")),
"pendingKey": String(entry.get("routePendingKey", "")),
"snapshotRevision": String(entry.get("routeSnapshotRevision", "")),
"pendingSnapshotRevision": String(entry.get("routePendingSnapshotRevision", "")),
"routeBudgetWaitFrames": int(entry.get("routeBudgetWaitFrames", 0)),
"navmeshTileBudgetWaitFrames": int(entry.get("navmeshTileBudgetWaitFrames", 0)),
"lastRoutePlanDebug": entry.get("lastRoutePlanDebug", {}),
"lastRouteAuthority": entry.get("lastRouteAuthority", {}),
"lastRouteCollisionProbe": entry.get("lastRouteCollisionProbe", {}),
"lastNavmeshTilePublishDebug": entry.get("lastNavmeshTilePublishDebug", []),
```

### 7.3 Add aggregate overlay lines

In `overlay_lines(export: Dictionary)`, after the existing route/task lines, add concise aggregate text from `routeState`:

```gdscript
var route_state: Dictionary = export.get("routeState", {}) if export.get("routeState", {}) is Dictionary else {}
var route_reasons: Dictionary = route_state.get("routeReasons", {}) if route_state.get("routeReasons", {}) is Dictionary else {}
var route_waits: Dictionary = route_state.get("routeWaitFrames", {}) if route_state.get("routeWaitFrames", {}) is Dictionary else {}
```

Then include a line like:

```gdscript
"Route waits route=%d tile=%d reasons=%s" % [int(route_waits.get("maxRouteBudget", 0)), int(route_waits.get("maxNavmeshTileBudget", 0)), JSON.stringify(route_reasons)]
```

If `overlay_lines()` currently returns a literal array, convert it to build an array variable first, append this line, then return the array.

### 7.4 Run verification

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite contract -TimeMode Both -WatchdogSeconds 60
```

Expected result:

```text
compile passes
runtime debug state contains routeReasons, routeAuthorityStates, and routeWaitFrames
```

---

## Phase 8 — Add the route-ticket pipeline behind a feature flag

This phase makes routing mature. Movement should not synchronously try to build navmesh data, query routes, and wait for collision probes in one call. It should submit a route ticket, wait for it to become ready, then follow the leased route.

The existing movement controller can keep calling `planner.plan_route(entry, intent)`. The trick is to insert a broker object that implements the same `plan_route()` method but returns `pending` while the route is being prepared across frames.

### 8.1 Add `RouteTicket.gd`

Create:

```text
scripts/npc_ai/contracts/RouteTicket.gd
```

File contents:

```gdscript
extends RefCounted
class_name RouteTicket

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

enum State {
    QUEUED,
    WAITING_NAV_DATA,
    PLANNING,
    PROBING,
    READY,
    FOLLOWING,
    ARRIVED,
    FAILED_INVALID_GOAL,
    FAILED_UNREACHABLE,
    CANCELLED,
    INVALIDATED,
    FAILED_INTERNAL
}

var ticket_id := ""
var actor_id := ""
var key := ""
var goal_key := ""
var start_cell := Vector2i(999999, 999999)
var target_cell := Vector2i(999999, 999999)
var intent := {}
var state := State.QUEUED
var reason := "queued"
var route := {}
var created_frame := 0
var updated_frame := 0
var retry_frame := 0
var attempts := 0
var generation := 0

func configure(ticket_id_value: String, actor_id_value: String, key_value: String, goal_key_value: String, start_cell_value: Vector2i, target_cell_value: Vector2i, intent_value: Dictionary, generation_value: int) -> void:
    ticket_id = ticket_id_value
    actor_id = actor_id_value
    key = key_value
    goal_key = goal_key_value
    start_cell = start_cell_value
    target_cell = target_cell_value
    intent = intent_value.duplicate(true)
    generation = generation_value
    created_frame = Engine.get_physics_frames()
    updated_frame = created_frame
    retry_frame = created_frame
    attempts = 0
    state = State.QUEUED
    reason = "queued"
    route = {}

func is_pending() -> bool:
    return state in [State.QUEUED, State.WAITING_NAV_DATA, State.PLANNING, State.PROBING]

func is_ready() -> bool:
    return state == State.READY or state == State.FOLLOWING

func is_terminal_failure() -> bool:
    return state in [State.FAILED_INVALID_GOAL, State.FAILED_UNREACHABLE, State.CANCELLED, State.INVALIDATED, State.FAILED_INTERNAL]

func to_pending_route() -> Dictionary:
    return {
        "ok": false,
        "status": "pending",
        "reason": reason,
        "ticketId": ticket_id,
        "routeTicketState": state_name(),
        "routeAuthorityState": "pending_budget" if state == State.QUEUED or state == State.PLANNING else "pending_nav_data",
        "routeAuthorityReady": false,
        "targetCell": target_cell,
        "fallbackCell": target_cell,
        "cells": [],
        "waypoints": [],
        "actions": {}
    }

func state_name() -> String:
    match state:
        State.QUEUED:
            return "queued"
        State.WAITING_NAV_DATA:
            return "waiting_nav_data"
        State.PLANNING:
            return "planning"
        State.PROBING:
            return "probing"
        State.READY:
            return "ready"
        State.FOLLOWING:
            return "following"
        State.ARRIVED:
            return "arrived"
        State.FAILED_INVALID_GOAL:
            return "failed_invalid_goal"
        State.FAILED_UNREACHABLE:
            return "failed_unreachable"
        State.CANCELLED:
            return "cancelled"
        State.INVALIDATED:
            return "invalidated"
        State.FAILED_INTERNAL:
            return "failed_internal"
    return "unknown"
```

### 8.2 Add `NpcRouteTicketBroker.gd`

Create:

```text
scripts/npc_ai/routing/NpcRouteTicketBroker.gd
```

File contents:

```gdscript
extends RefCounted
class_name NpcRouteTicketBroker

const RouteTicketScript := preload("res://scripts/npc_ai/contracts/RouteTicket.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := 1.35
const MAX_TICKET_JOBS_PER_FRAME := 12
const MAX_TICKET_ATTEMPTS_BEFORE_FAILURE := 240

var system = null
var main = null
var world = null
var authority_planner = null
var tickets_by_actor := {}
var ticket_order: Array[String] = []
var sequence := 0
var generation_by_actor := {}

func setup(system_node, main_node, navigation_world, planner) -> void:
    system = system_node
    main = main_node
    world = navigation_world
    authority_planner = planner

func begin_frame() -> void:
    if not NpcConstantsScript.NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE:
        return
    _process_tickets(MAX_TICKET_JOBS_PER_FRAME)

func invalidate() -> void:
    for ticket_value in tickets_by_actor.values():
        var ticket = ticket_value
        if ticket != null:
            ticket.state = RouteTicketScript.State.INVALIDATED
            ticket.reason = "navigation_invalidated"
            ticket.updated_frame = Engine.get_physics_frames()
    tickets_by_actor.clear()
    ticket_order.clear()

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
    if not NpcConstantsScript.NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE:
        return authority_planner.plan_route(entry, intent) if authority_planner != null and authority_planner.has_method("plan_route") else _failure("blocked", "missing_authority_planner", intent)

    var actor_id := String(entry.get("id", "npc"))
    var key_info := _ticket_key(entry, intent)
    var key := String(key_info.get("key", ""))
    var ticket = tickets_by_actor.get(actor_id, null)

    if ticket == null or ticket.key != key or ticket.is_terminal_failure():
        ticket = _submit_ticket(actor_id, key_info, intent)
        tickets_by_actor[actor_id] = ticket
        ticket_order.erase(actor_id)
        ticket_order.append(actor_id)
        entry["routeTicketId"] = ticket.ticket_id
        entry["routeTicketState"] = ticket.state_name()
        entry["routeTicketReason"] = ticket.reason
        return ticket.to_pending_route()

    entry["routeTicketId"] = ticket.ticket_id
    entry["routeTicketState"] = ticket.state_name()
    entry["routeTicketReason"] = ticket.reason

    if ticket.is_ready():
        var ready_route: Dictionary = ticket.route.duplicate(true)
        ready_route["ticketId"] = ticket.ticket_id
        ready_route["routeTicketState"] = ticket.state_name()
        ticket.state = RouteTicketScript.State.FOLLOWING
        ticket.updated_frame = Engine.get_physics_frames()
        return ready_route

    if ticket.is_terminal_failure():
        var failed_route: Dictionary = ticket.route.duplicate(true) if ticket.route is Dictionary else {}
        if failed_route.is_empty():
            failed_route = _failure("blocked", ticket.reason, intent)
        failed_route["ticketId"] = ticket.ticket_id
        failed_route["routeTicketState"] = ticket.state_name()
        return failed_route

    return ticket.to_pending_route()

func stats() -> Dictionary:
    var states := {}
    for ticket_value in tickets_by_actor.values():
        var ticket = ticket_value
        if ticket == null:
            continue
        var state_name := ticket.state_name()
        states[state_name] = int(states.get(state_name, 0)) + 1
    var planner_stats := authority_planner.stats() if authority_planner != null and authority_planner.has_method("stats") else {}
    return {
        "tickets": tickets_by_actor.size(),
        "ticketStates": states,
        "ticketOrder": ticket_order.duplicate(),
        "delegate": planner_stats
    }

func _process_tickets(max_jobs: int) -> void:
    if authority_planner == null or not authority_planner.has_method("plan_route"):
        return
    var now := Engine.get_physics_frames()
    var jobs := 0
    var actors := ticket_order.duplicate()
    for actor_id_value in actors:
        if jobs >= max_jobs:
            break
        var actor_id := String(actor_id_value)
        var ticket = tickets_by_actor.get(actor_id, null)
        if ticket == null:
            ticket_order.erase(actor_id)
            continue
        if not ticket.is_pending():
            continue
        if ticket.retry_frame > now:
            continue
        jobs += 1
        _process_one_ticket(ticket)

func _process_one_ticket(ticket) -> void:
    ticket.attempts += 1
    ticket.updated_frame = Engine.get_physics_frames()
    ticket.state = RouteTicketScript.State.PLANNING
    ticket.reason = "planning"

    var route: Dictionary = authority_planner.plan_route(_entry_for_actor(ticket.actor_id), ticket.intent)
    var status := String(route.get("status", ""))
    var reason := String(route.get("reason", ""))
    var authority_state := String(route.get("routeAuthorityState", ""))

    if status == "pending" or bool(route.get("routeAuthorityPending", false)):
        ticket.route = route.duplicate(true)
        ticket.reason = reason if reason != "" else "route_pending"
        if authority_state == "pending_nav_data":
            ticket.state = RouteTicketScript.State.WAITING_NAV_DATA
        elif authority_state == "pending_probe":
            ticket.state = RouteTicketScript.State.PROBING
        else:
            ticket.state = RouteTicketScript.State.QUEUED
        ticket.retry_frame = Engine.get_physics_frames() + _retry_frames_for_reason(ticket.reason)
        if ticket.attempts >= MAX_TICKET_ATTEMPTS_BEFORE_FAILURE:
            ticket.state = RouteTicketScript.State.FAILED_INTERNAL
            ticket.reason = "ticket_attempt_limit"
        return

    if bool(route.get("ok", false)) and bool(route.get("routeAuthorityReady", false)) and not (route.get("waypoints", []) as Array).is_empty():
        ticket.route = route.duplicate(true)
        ticket.state = RouteTicketScript.State.READY
        ticket.reason = "ready"
        ticket.retry_frame = Engine.get_physics_frames()
        return

    ticket.route = route.duplicate(true)
    if status in ["blocked", "unreachable", "partial"]:
        ticket.state = RouteTicketScript.State.FAILED_UNREACHABLE
        ticket.reason = reason if reason != "" else status
    elif status in ["cancelled"]:
        ticket.state = RouteTicketScript.State.CANCELLED
        ticket.reason = reason if reason != "" else "cancelled"
    else:
        ticket.state = RouteTicketScript.State.FAILED_INTERNAL
        ticket.reason = reason if reason != "" else "route_failed"

func _submit_ticket(actor_id: String, key_info: Dictionary, intent: Dictionary):
    sequence += 1
    var generation := int(generation_by_actor.get(actor_id, 0)) + 1
    generation_by_actor[actor_id] = generation
    var ticket = RouteTicketScript.new()
    ticket.configure(
        "ticket:%s:%06d" % [actor_id, sequence],
        actor_id,
        String(key_info.get("key", "")),
        String(key_info.get("goalKey", "")),
        key_info.get("startCell", Vector2i(999999, 999999)),
        key_info.get("targetCell", Vector2i(999999, 999999)),
        intent,
        generation
    )
    return ticket

func _ticket_key(entry: Dictionary, intent: Dictionary) -> Dictionary:
    var target: Vector3 = intent.get("target", Vector3.ZERO)
    var target_cell: Vector2i = intent.get("targetCell", world.world_cell(target) if world != null and world.has_method("world_cell") else Vector2i(roundi(target.x / CELL), roundi(target.z / CELL)))
    var body := entry.get("body") as Node3D
    var start_position: Vector3 = body.global_position if body != null and is_instance_valid(body) else entry.get("porchPosition", target)
    var start_cell: Vector2i = world.world_cell(start_position) if world != null and world.has_method("world_cell") else Vector2i(roundi(start_position.x / CELL), roundi(start_position.z / CELL))
    var revision := String(world.revision()) if world != null and world.has_method("revision") else ""
    var goal_key := "%s:%d,%d:%s:%s:%s:%s:%.3f" % [
        String(intent.get("kind", "move")),
        target_cell.x,
        target_cell.y,
        str(bool(intent.get("allowOutside", false))),
        str(bool(intent.get("movingHome", false))),
        String(intent.get("action", "")),
        str(bool(intent.get("strictArrival", false))),
        float(intent.get("arrivalRadius", CELL * 0.75))
    ]
    var key := "%d,%d->%s:%s" % [start_cell.x, start_cell.y, goal_key, revision]
    return {
        "key": key,
        "goalKey": goal_key,
        "startCell": start_cell,
        "targetCell": target_cell
    }

func _entry_for_actor(actor_id: String) -> Dictionary:
    if system == null:
        return { "id": actor_id }
    var by_id = system.get("npc_by_id")
    if by_id is Dictionary and (by_id as Dictionary).has(actor_id):
        var entry = (by_id as Dictionary).get(actor_id)
        if entry is Dictionary:
            return entry
    var entries = system.get("npcs")
    if entries is Array:
        for entry_value in entries:
            if entry_value is Dictionary and String((entry_value as Dictionary).get("id", "")) == actor_id:
                return entry_value
    return { "id": actor_id }

func _retry_frames_for_reason(reason: String) -> int:
    if reason in ["route_budget", "navmesh_tile_budget", "collision_probe_budget"]:
        return 1
    if reason.find("navmesh") >= 0 or reason.find("tile") >= 0:
        return 2
    return 1

func _failure(status: String, reason: String, intent: Dictionary) -> Dictionary:
    var target_cell: Vector2i = intent.get("targetCell", Vector2i(999999, 999999))
    return {
        "ok": false,
        "status": status,
        "reason": reason,
        "targetCell": target_cell,
        "fallbackCell": target_cell,
        "cells": [],
        "waypoints": [],
        "actions": {},
        "routeAuthorityReady": false,
        "routeAuthorityState": "failed_internal"
    }
```

### 8.3 Wire the broker into the coordinator

Edit:

```text
scripts/npc_ai/routing/NpcNavigationCoordinator.gd
```

Add preloads:

```gdscript
const NpcRouteTicketBrokerScript := preload("res://scripts/npc_ai/routing/NpcRouteTicketBroker.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
```

Add a member:

```gdscript
var route_ticket_broker
```

In `ensure_ready()`, after `route_planner` is initialized, add:

```gdscript
if route_ticket_broker == null:
    route_ticket_broker = NpcRouteTicketBrokerScript.new()
    route_ticket_broker.setup(system, main, navigation_world, route_planner)
```

In `rebuild()`, after `route_planner.setup(...)`, add:

```gdscript
route_ticket_broker = NpcRouteTicketBrokerScript.new()
route_ticket_broker.setup(system, main, navigation_world, route_planner)
```

In `begin_frame()`, after `route_planner.begin_frame()`, add:

```gdscript
if route_ticket_broker != null and route_ticket_broker.has_method("begin_frame"):
    route_ticket_broker.begin_frame()
```

In `invalidate()`, after route planner invalidation, add:

```gdscript
if route_ticket_broker != null and route_ticket_broker.has_method("invalidate"):
    route_ticket_broker.invalidate()
```

In `_move_npc_step()`, replace:

```gdscript
var result: Dictionary = locomotion.move(entry, intent, max_distance, route_planner, navigation_world)
```

with:

```gdscript
var planner_for_movement = route_ticket_broker if NpcConstantsScript.NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE and route_ticket_broker != null else route_planner
var result: Dictionary = locomotion.move(entry, intent, max_distance, planner_for_movement, navigation_world)
```

In `stats()`, include broker stats:

```gdscript
if route_ticket_broker != null and route_ticket_broker.has_method("stats"):
    var ticket_stats = route_ticket_broker.stats()
    result["routeTickets"] = ticket_stats if ticket_stats is Dictionary else {}
```

### 8.4 Enable the route-ticket pipeline

After compile and basic tests pass with the broker wired but disabled, edit:

```text
scripts/npc_ai/NpcConstants.gd
```

Change:

```gdscript
const NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE := false
```

to:

```gdscript
const NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE := true
```

### 8.5 Run verification

First with the flag still `false`:

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite route -TimeMode Both -WatchdogSeconds 60
```

Then enable the flag and run:

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite route -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite motor -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite behavior -TimeMode Both -WatchdogSeconds 60
.\tools\run-npc-navigation-tests.ps1
```

Expected result:

```text
movement returns pending while route tickets are queued/waiting/planning/probing
NPCs do not treat route-ticket pending as permanent blocked state
ready tickets produce authority leases
movement follows only leased routes
```

If NPCs never leave pending, inspect `routeTickets.ticketStates`, `routeReasons`, and `routeAuthorityStates` from stats. The likely causes are navmesh tiles still not publishing, collision probe budget, or route budget.

---

## Phase 9 — Reintroduce safe generated-cell fallback only for open terrain

This is a recovery path, not the primary path. It is useful for foragers, guards, and short open-terrain movement when the navmesh tile queue is briefly behind.

### 9.1 Add a shared fallback safety helper

Edit:

```text
scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd
```

Add this helper near the existing `_should_try_generated_cell_*` functions:

```gdscript
func _safe_open_terrain_generated_fallback_allowed(entry: Dictionary, intent: Dictionary) -> bool:
    if not NpcConstantsScript.NPC_NAV_ENABLE_SAFE_GENERATED_OPEN_TERRAIN_FALLBACK:
        return false
    if world == null or navmesh_planner == null:
        return false
    if bool(entry.get("insideHome", false)):
        return false
    if String(entry.get("activeDoorPortalId", "")) != "":
        return false
    if String(intent.get("action", "")) != "":
        return false
    if bool(intent.get("movingHome", false)):
        return false

    var route_kind := String(intent.get("kind", "move"))
    if route_kind not in ["forage", "guard", "work", "job", "move", "idle", "wander"]:
        return false

    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false

    var start_cell: Vector2i = world.world_cell(body.global_position)
    var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", body.global_position)))
    var door_cell: Vector2i = entry.get("doorCell", Vector2i(999999, 999999))
    var porch_cell: Vector2i = entry.get("porchCell", Vector2i(999999, 999999))
    var home_cell: Vector2i = entry.get("homeCell", Vector2i(999999, 999999))

    # Keep generated fallback away from house/door/private-interior transitions.
    for sensitive_cell in [door_cell, porch_cell, home_cell]:
        if sensitive_cell is Vector2i:
            if absi(start_cell.x - sensitive_cell.x) + absi(start_cell.y - sensitive_cell.y) <= 2:
                return false
            if absi(target_cell.x - sensitive_cell.x) + absi(target_cell.y - sensitive_cell.y) <= 2:
                return false

    # Do not use this for long routes. Long routes must wait for navmesh tiles.
    var manhattan := absi(start_cell.x - target_cell.x) + absi(start_cell.y - target_cell.y)
    if manhattan > 24:
        return false

    return true
```

### 9.2 Re-enable job/open fallback through the safety helper

Replace `_should_try_generated_cell_job_route()` with:

```gdscript
func _should_try_generated_cell_job_route(entry: Dictionary, intent: Dictionary) -> bool:
    return _safe_open_terrain_generated_fallback_allowed(entry, intent)
```

Keep `_should_try_generated_cell_home_route()` returning `false`. Home/door/interior routes must use collision-backed navmesh tiles.

Replace `_should_try_prebudget_forage_departure_route()` with:

```gdscript
func _should_try_prebudget_forage_departure_route(entry: Dictionary, intent: Dictionary) -> bool:
    if String(intent.get("kind", "move")) != "forage":
        return false
    return _safe_open_terrain_generated_fallback_allowed(entry, intent)
```

### 9.3 Add a hard assertion in route result annotation

Generated fallback routes must still go through `NpcRouteAuthority`. The existing call path does this because `NpcRouteCoordinatorAdapter.plan_route()` is wrapped by `NpcRouteAuthority.plan_route()`. Add route metadata so diagnostics prove it.

When a generated-cell route is returned successfully, ensure these fields are set before `_store_route_cache(...)` and `return generated_route`:

```gdscript
generated_route["generatedCellBridge"] = true
generated_route["requiresAuthorityProbe"] = true
```

### 9.4 Run verification

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-suite.ps1 -Suite route -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite behavior -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite door -TimeMode Both -WatchdogSeconds 60
```

Expected result:

```text
generated fallback may appear for open-terrain forager/guard/work routes
generated fallback must not appear for home/interior/door portal routes
all generated fallback routes still have routeAuthorityReady true before movement follows them
```

If any door test regresses, disable generated fallback for the failing route kind and tighten the sensitive-cell distance from `2` to `4`.

---

## Phase 10 — Add targeted tests

Add tests before declaring the fix complete. The tests below are small and targeted at the actual bugs.

### 10.1 Add a substep delta test

Edit:

```text
scripts/testing/npc/NpcAutonomyTestRunner.gd
```

Add this preload if missing:

```gdscript
const NpcNavigationCoordinatorScript := preload("res://scripts/npc_ai/routing/NpcNavigationCoordinator.gd")
```

Add fake helper classes near the other fake classes:

```gdscript
class FakeCoordinatorWorld:
    func world_cell(position: Vector3) -> Vector2i:
        return Vector2i(roundi(position.x), roundi(position.z))

    func revision() -> String:
        return "fake-rev"

class FakeCoordinatorGoalPlanner:
    func make_intent(_entry: Dictionary, target: Vector3, _max_distance: float, moving_home := false, allow_outside := false) -> Dictionary:
        return {
            "kind": "move",
            "target": target,
            "targetCell": Vector2i(roundi(target.x), roundi(target.z)),
            "movingHome": moving_home,
            "allowOutside": allow_outside
        }

class FakeCoordinatorLocomotion:
    var deltas: Array = []

    func begin_frame() -> void:
        pass

    func move(_entry: Dictionary, intent: Dictionary, max_distance: float, _planner, _world) -> Dictionary:
        deltas.append(float(intent.get("physicsDelta", -1.0)))
        return { "moved": max_distance, "status": "moving", "reason": "" }

class FakeCoordinatorPlanner:
    func begin_frame() -> void:
        pass

    func stats() -> Dictionary:
        return {}
```

Add this test function:

```gdscript
func test_npc_motor_substep_uses_step_delta(_mode: String) -> Dictionary:
    var coordinator = NpcNavigationCoordinatorScript.new()
    var fake_locomotion = FakeCoordinatorLocomotion.new()
    coordinator.set("system", self)
    coordinator.set("main", self)
    coordinator.set("navigation_world", FakeCoordinatorWorld.new())
    coordinator.set("route_planner", FakeCoordinatorPlanner.new())
    coordinator.set("locomotion", fake_locomotion)
    coordinator.set("goal_planner", FakeCoordinatorGoalPlanner.new())

    var body := CharacterBody3D.new()
    add_child(body)
    body.global_position = Vector3.ZERO
    var entry := { "id": "npc:test:substep", "body": body }

    var moved := coordinator.move_npc(entry, Vector3(10.0, 0.0, 0.0), 4.0, false, false, 0.24)
    body.queue_free()

    var deltas: Array = fake_locomotion.deltas
    var passed := moved > 0.0 and deltas.size() > 1
    for delta_value in deltas:
        var delta := float(delta_value)
        if delta <= 0.0 or delta >= 0.24:
            passed = false

    return outcome(
        passed,
        "moved=%.3f deltas=%s" % [moved, JSON.stringify(deltas)],
        ["substep_count_gt_one", "each_substep_uses_fractional_delta"],
        { "moved": moved, "deltas": deltas }
    )
```

Register it in the motor cases list with ID:

```text
npc_motor_substep_uses_step_delta
```

### 10.2 Add a route reuse test for actor displacement

In `NpcAutonomyTestRunner.gd`, add this test:

```gdscript
func test_npc_motor_route_replans_after_actor_displacement(_mode: String) -> Dictionary:
    var controller = NpcRouteMovementControllerScript.new()
    controller.setup(self, self)

    var body := CharacterBody3D.new()
    add_child(body)
    body.global_position = Vector3.ZERO

    var entry := {
        "id": "npc:test:route-drift",
        "body": body,
        "routeStatus": "moving",
        "routeGoalKey": "move:10,0:true:false::false:1.013",
        "routeKey": "0,0->move:10,0:true:false::false:1.013",
        "routeSnapshotRevision": "rev-a",
        "routeStartCell": Vector2i(0, 0),
        "routeLastKnownCell": Vector2i(0, 0),
        "pathWaypoints": [Vector3(1.0, 0.0, 0.0)],
        "routeCells": [Vector2i(0, 0), Vector2i(1, 0)],
        "routeActions": {},
        "routeLease": { "leaseId": "lease:test" }
    }

    var world = FakeRouteWorld.new()
    world.revision_value = "rev-a"
    var planner = FakeRoutePlanner.new({
        "ok": true,
        "status": "routed",
        "reason": "",
        "cells": [Vector2i(20, 0), Vector2i(21, 0)],
        "waypoints": [Vector3(20.0, 0.0, 0.0), Vector3(21.0, 0.0, 0.0)],
        "actions": {},
        "targetCell": Vector2i(10, 0),
        "fallbackCell": Vector2i(10, 0),
        "routeAuthorityReady": true,
        "routeLease": { "leaseId": "lease:new" },
        "routeLeaseId": "lease:new"
    })

    body.global_position = Vector3(20.0, 0.0, 0.0)
    var intent := {
        "kind": "move",
        "target": Vector3(10.0, 0.0, 0.0),
        "targetCell": Vector2i(10, 0),
        "allowOutside": true,
        "movingHome": false,
        "arrivalRadius": 1.013
    }

    var route: Dictionary = controller.ensure_route(entry, intent, planner, world)
    body.queue_free()

    var passed := planner.calls >= 1 and String(entry.get("routeLeaseId", "")) == "lease:new" and not (entry.get("pathWaypoints", []) as Array).is_empty()
    return outcome(
        passed,
        "plannerCalls=%d route=%s entryKey=%s" % [planner.calls, JSON.stringify(route), String(entry.get("routeKey", ""))],
        ["displaced_actor_forces_replan", "new_lease_installed"],
        { "plannerCalls": planner.calls, "route": route, "entryRouteKey": String(entry.get("routeKey", "")) }
    )
```

Register it in the motor cases list with ID:

```text
npc_motor_route_replans_after_actor_displacement
```

### 10.3 Add a navmesh snapshot collision consistency test

Add a nav-world test that constructs or mocks a live tile block and asserts that `build_navmesh_tile_snapshot()` updates both:

```text
blocked / doors / paths
staticCollision / staticCollisionByCell / doorCollision / doorCollisionByCell
```

Register it with ID:

```text
npc_navworld_live_tile_snapshot_includes_collision_records
```

Minimum assertion list:

```text
live_static_block_updates_static_collision
live_door_updates_door_collision
collision_by_cell_matches_records
```

### 10.4 Add a generated fallback guard test

Add a route test that verifies:

```text
home route fallback remains disabled
insideHome route fallback remains disabled
door-adjacent route fallback remains disabled
open-terrain forage fallback may be enabled
```

Register it with ID:

```text
npc_route_generated_fallback_open_terrain_only
```

### 10.5 Run the new tests directly

```powershell
.\tools\npc\run-npc-suite.ps1 -Suite motor -Case npc_motor_substep_uses_step_delta -TimeMode Day -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite motor -Case npc_motor_route_replans_after_actor_displacement -TimeMode Day -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite nav_world -Case npc_navworld_live_tile_snapshot_includes_collision_records -TimeMode Day -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite route -Case npc_route_generated_fallback_open_terrain_only -TimeMode Day -WatchdogSeconds 60
```

Then run full affected suites:

```powershell
.\tools\npc\run-npc-suite.ps1 -Suite motor -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite nav_world -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite route -TimeMode Both -WatchdogSeconds 60
```

---

## Phase 11 — Run integration and soak verification

After all phases above compile and pass targeted tests, run the broader suites.

### 11.1 Core NPC suites

```powershell
.\tools\npc\run-npc-suite.ps1 -Suite contract -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite nav_world -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite motor -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite route -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite repair -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite door -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite avoidance -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite traffic -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite behavior -TimeMode Both -WatchdogSeconds 60
.\tools\npc\run-npc-suite.ps1 -Suite interaction -TimeMode Both -WatchdogSeconds 60
```

### 11.2 Scenario and visual playtests

```powershell
.\tools\run-npc-navigation-tests.ps1
.\tools\npc\run-npc-scenario-tests.ps1
.\tools\npc\run-npc-town-job-cycle-visual-playtest.ps1
.\tools\npc\run-npc-go-home-visual-playtest.ps1
```

### 11.3 Soak tests

```powershell
.\tools\npc\run-npc-suite.ps1 -Suite soak -TimeMode Both -WatchdogSeconds 180
.\tools\npc\run-npc-soak-tests.ps1
```

---

## Acceptance criteria

The implementation is complete only when all of these are true:

```text
Compile smoke passes.
Motor suite passes.
Nav-world suite passes.
Route suite passes.
Door suite passes.
Behavior suite passes.
NPC navigation playtest passes.
No visible NPC remains pending for more than 3 seconds without a diagnostic reason.
No home/interior route uses generated-cell fallback.
No generated-cell fallback route is followed without routeAuthorityReady == true.
No route is followed without a non-empty routeLease / routeLeaseId.
route_budget waits and navmesh_tile_budget waits drain under town load.
Door crossing tests do not deadlock permanently.
Collision probe failures remain visible instead of being suppressed.
Route tickets show queued/waiting/planning/probing/ready states in diagnostics.
```

For runtime metrics, target these thresholds after startup tile priming:

```text
Visible NPC p95 route wait < 0.5 seconds.
Max routeBudgetWaitFrames < 180 in normal town tests.
Max navmeshTileBudgetWaitFrames < 180 in normal town tests.
Zero static wall penetrations in door/capsule tests.
Zero permanent narrow-door deadlocks.
```

---

## Regression checklist before final commit

Search for these bad patterns and fix them if found:

```powershell
rg "collision_probe_required\s*=\s*false" scripts
rg "_should_try_generated_cell_home_route|_should_try_generated_cell_job_route|_should_try_prebudget_forage_departure_route" scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd -n
rg "routeAuthorityReady" scripts/npc_ai/movement/NpcRouteMovementController.gd
rg "routeLease" scripts/npc_ai/movement/NpcRouteMovementController.gd
rg "_snapshot_with_live_tile_blocks_for_navmesh_tile" scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd
```

Expected:

```text
No new code disables collision_probe_required.
Home generated-cell fallback still returns false; job/forage fallback is gated by `_safe_open_terrain_generated_fallback_allowed()`.
Movement only follows ready/leased routes.
build_navmesh_tile_snapshot uses _snapshot_with_live_tile_blocks, not the lighter helper.
```

---

## Final commit message template

Use this commit message:

```text
Fix NPC pathfinding route readiness, navmesh snapshots, and route tickets

- Fix movement substep physics delta propagation
- Make NPC component initialization retry-safe
- Build navmesh tile snapshots from live collision records
- Include door state in tile source keys
- Prevent stale active route reuse after actor displacement/world revision changes
- Prime essential startup navmesh tiles
- Add adaptive route and tile publish budgets
- Add route reason/authority diagnostics
- Add route-ticket broker behind NPC navigation feature flag
- Restrict generated-cell fallback to safe open-terrain routes only
- Add targeted route, motor, and nav-world regression tests
```
