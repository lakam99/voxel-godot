extends RefCounted
class_name NpcRouteCoordinatorAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavmeshRoutePlannerScript := preload("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")
const HierarchicalRoutePlannerScript := preload("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const LIVE_ROUTE_JOBS_PER_FRAME := 1
const ROUTE_BUDGET_GRANT_COOLDOWN_FRAMES := 2
const URGENT_ROUTE_EXTRA_JOBS_PER_FRAME := 1
const STARVED_ROUTE_BUDGET_FRAMES := 12
const STARVED_ROUTE_EXTRA_JOBS_PER_FRAME := 1
const ROUTE_CACHE_LIMIT := 128
const NAVMESH_TILE_PUBLISHES_PER_FRAME := 1
const ORDERED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 32

var system
var main
var world
var backend_config
var navmesh_planner
var navmesh_world
var generated_corridor_planner
var route_budget_frame := -1
var route_budget_tick := 0
var route_budget_engine_frame := -1
var route_budget_seen_tick := -1
var route_budget_serial := 0
var route_jobs_this_frame := 0
var urgent_route_jobs_this_frame := 0
var starved_route_jobs_this_frame := 0
var navmesh_tile_publish_engine_frame := -1
var navmesh_tile_publishes_this_frame := 0
var route_last_granted_actor_id := ""
var route_cache := {}
var route_cache_order: Array[String] = []
var published_navmesh_tile_keys := {}
var empty_navmesh_tile_keys := {}

func setup(system_node, main_node, navigation_world) -> void:
	system = system_node
	main = main_node
	world = navigation_world
	backend_config = NavigationBackendConfigScript.from_environment()
	navmesh_world = _navmesh_world_from_system()
	navmesh_planner = NavmeshRoutePlannerScript.new()
	navmesh_planner.setup(navmesh_world, system, main, world)
	generated_corridor_planner = HierarchicalRoutePlannerScript.new()
	generated_corridor_planner.setup(world)

func performance_monitor():
	return main.get("runtime_perf_monitor") if main != null else null

func begin_frame() -> void:
	route_budget_tick += 1

func invalidate() -> void:
	route_cache.clear()
	route_cache_order.clear()
	published_navmesh_tile_keys.clear()
	empty_navmesh_tile_keys.clear()
	if generated_corridor_planner != null and generated_corridor_planner.has_method("clear"):
		generated_corridor_planner.clear()

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	if navmesh_planner == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner = NavmeshRoutePlannerScript.new()
		navmesh_planner.setup(navmesh_world, system, main, world)
	elif navmesh_world == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner.setup(navmesh_world, system, main, world)
	if generated_corridor_planner == null:
		generated_corridor_planner = HierarchicalRoutePlannerScript.new()
		generated_corridor_planner.setup(world)
	if world == null:
		return route_failure("blocked", "missing_world", intent.get("targetCell", Vector2i(999999, 999999)))
	var monitor = performance_monitor()
	var cache_key := _route_cache_key(entry, intent)
	if route_cache.has(cache_key):
		if monitor != null:
			monitor.increment_counter("route_cache_hits")
		return _copy_cached_route(route_cache[cache_key])
	if monitor != null:
		monitor.increment_counter("route_cache_misses")
	if not _claim_route_budget(entry, intent):
		if monitor != null:
			monitor.increment_counter("route_jobs_pending")
		return route_failure("pending", "route_budget", intent.get("targetCell", Vector2i(999999, 999999)))
	if not _ensure_navmesh_route_tiles(entry, intent):
		if monitor != null:
			monitor.increment_counter("route_jobs_pending")
		return route_failure("pending", "navmesh_tile_budget", intent.get("targetCell", Vector2i(999999, 999999)))
	if navmesh_world != null and navmesh_world.has_method("sync_navigation_map_if_dirty"):
		var sync_start: int = monitor.begin_section("navmesh_map_sync") if monitor != null else Time.get_ticks_usec()
		navmesh_world.sync_navigation_map_if_dirty()
		if monitor != null:
			monitor.end_section("navmesh_map_sync", sync_start)
	var navmesh_start: int = monitor.begin_section("navmesh_route_query") if monitor != null else Time.get_ticks_usec()
	var result: Dictionary = navmesh_planner.plan_runtime_route(entry, intent, world, 0)
	if _should_use_generated_corridor_fallback(result, entry, intent):
		var fallback_start: int = monitor.begin_section("generated_corridor_route_query") if monitor != null else Time.get_ticks_usec()
		var fallback_result: Dictionary = generated_corridor_planner.plan_runtime_route(entry, intent, world, 200000)
		if monitor != null:
			monitor.end_section("generated_corridor_route_query", fallback_start)
			monitor.increment_counter("generated_corridor_route_queries")
			if bool(fallback_result.get("ok", false)):
				monitor.increment_counter("generated_corridor_route_successes")
			else:
				monitor.increment_counter("generated_corridor_route_failures")
		if bool(fallback_result.get("ok", false)) or String(fallback_result.get("status", "")) == "pending":
			fallback_result["source"] = "generated_corridor"
			fallback_result["navmeshFallbackReason"] = String(result.get("reason", ""))
			fallback_result["navmeshRoute"] = (result.get("navmeshRoute", {}) as Dictionary).duplicate(true) if result.get("navmeshRoute", {}) is Dictionary else result.duplicate(true)
			result = fallback_result
		else:
			result["generatedFallbackRoute"] = fallback_result.duplicate(true)
	if monitor != null:
		var navmesh_duration: float = monitor.end_section("navmesh_route_query", navmesh_start)
		monitor.observe_duration("route_planning", navmesh_duration)
		monitor.increment_counter("navmesh_route_queries")
		if bool(result.get("ok", false)):
			monitor.increment_counter("navmesh_route_successes")
		else:
			monitor.increment_counter("navmesh_route_failures")
		if String(result.get("status", "")) == "pending":
			monitor.increment_counter("route_jobs_pending")
		else:
			monitor.increment_counter("route_jobs_completed")
	if String(result.get("status", "")) != "pending":
		_store_route_cache(cache_key, result)
	return result

func _should_use_generated_corridor_fallback(result: Dictionary, entry: Dictionary, intent: Dictionary) -> bool:
	if generated_corridor_planner == null or world == null:
		return false
	if not (bool(intent.get("movingHome", false)) or String(intent.get("kind", "")) in ["home", "scripted"]):
		return false
	if String(result.get("status", "")) == "pending":
		return false
	if bool(result.get("ok", false)) and _route_dynamic_avoid_key(entry) != "":
		return true
	if bool(result.get("ok", false)):
		return false
	var reason := String(result.get("reason", ""))
	return reason in [
		"endpoint_not_server_walkable",
		"no_start_server_walkable",
		"no_target_server_walkable",
		"path_endpoint_mismatch",
		"no_route",
		"target_blocked",
		"forbidden_private_door_link"
	]

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = []) -> float:
	if world == null:
		return INF
	if navmesh_planner == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner = NavmeshRoutePlannerScript.new()
		navmesh_planner.setup(navmesh_world, system, main, world)
	elif navmesh_world == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner.setup(navmesh_world, system, main, world)
	if not _ensure_navmesh_route_tiles(entry, {
		"kind": "cost",
		"target": target,
		"targetCell": world.world_cell(target),
		"allowOutside": allow_outside,
		"movingHome": moving_home,
		"arrivalRadius": arrival_radius
	}):
		return INF
	return navmesh_planner.route_cost_for_runtime(entry, target, allow_outside, moving_home, arrival_radius, approach_cells, world)

func route_failure(status: String, reason: String, target_cell := Vector2i(999999, 999999)) -> Dictionary:
	return {
		"ok": false,
		"status": status,
		"reason": reason,
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": Vector2i(999999, 999999),
		"snapshotRevision": ""
	}

func process_navigation_events(events: Array, max_expansions := 128) -> Array[Dictionary]:
	var responses: Array[Dictionary] = []
	if events.is_empty():
		return responses
	var clear_cached_routes := false
	for event in events:
		if not (event is Dictionary):
			continue
		var kinds: Array = (event as Dictionary).get("changeKinds", []) if (event as Dictionary).get("changeKinds", []) is Array else []
		if _event_invalidates_route_cache(kinds):
			clear_cached_routes = true
		var tile_key := String((event as Dictionary).get("tileKey", ""))
		if tile_key != "" and _event_invalidates_published_navmesh_tile(kinds):
			published_navmesh_tile_keys.erase(tile_key)
			empty_navmesh_tile_keys.erase(tile_key)
		responses.append({
			"status": "invalidated",
			"reason": "navmesh_revision_changed",
			"event": (event as Dictionary).duplicate(true),
			"maxExpansionsIgnored": max_expansions
		})
	if clear_cached_routes:
		route_cache.clear()
		route_cache_order.clear()
	return responses

func _event_invalidates_route_cache(kinds: Array) -> bool:
	return _event_invalidates_published_navmesh_tile(kinds) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_DOOR_STATE) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED)

func _event_invalidates_published_navmesh_tile(kinds: Array) -> bool:
	return _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_PROP_CREATED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_PROP_REMOVED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_DOOR_REGISTERED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA)

func _event_has_kind(kinds: Array, expected: StringName) -> bool:
	for kind_value in kinds:
		if StringName(kind_value) == expected:
			return true
	return false

func stats() -> Dictionary:
	var result: Dictionary = {}
	result["backend"] = backend_config.to_summary() if backend_config != null else NavigationBackendConfigScript.default_config().to_summary()
	if navmesh_planner != null and navmesh_planner.has_method("stats"):
		result["navmesh"] = navmesh_planner.stats()
	return result

func _navmesh_world_from_system():
	if system == null:
		return null
	var autonomy = system.get("autonomy_system")
	if autonomy == null:
		return null
	return autonomy.get("navmesh_world")

func _ensure_navmesh_route_tiles(entry: Dictionary, intent: Dictionary) -> bool:
	if world == null or navmesh_world == null:
		return true
	if not world.has_method("route_navmesh_tile_keys") or not world.has_method("build_navmesh_tile_snapshot"):
		return true
	var body := entry.get("body") as Node3D
	var target: Vector3 = intent.get("target", body.global_position if body != null else Vector3.ZERO)
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	var route_kind := String(intent.get("kind", "move"))
	var ordered_route := moving_home or route_kind in ["home", "scripted"] or String(entry.get("activeDoorPortalId", "")) != ""
	var margin_cells := 12 if moving_home or route_kind in ["home", "scripted"] else 4
	var tile_keys: Array = world.route_navmesh_tile_keys(entry, start, target, allow_outside, moving_home, margin_cells)
	var source_key: String = String(world.navmesh_tile_source_key() if world.has_method("navmesh_tile_source_key") else world.revision())
	var monitor = performance_monitor()
	var publish_debug := []
	var published_tile_this_call := false
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		if tile_key == "":
			continue
		var published_key := "%s|%s" % [tile_key, source_key]
		if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
			publish_debug.append({ "tile": tile_key, "status": "cached_empty" })
			continue
		if String(published_navmesh_tile_keys.get(tile_key, "")) == published_key:
			var tile_status := _navmesh_tile_region_status(tile_key)
			if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
				publish_debug.append({ "tile": tile_key, "status": "cached", "region": tile_status })
				continue
		var extra_publishes := ORDERED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if ordered_route else 0
		if not _claim_navmesh_tile_publish_budget(extra_publishes):
			if monitor != null:
				monitor.increment_counter("navmesh_tile_publish_pending")
			publish_debug.append({ "tile": tile_key, "status": "pending_budget" })
			entry["lastNavmeshTilePublishDebug"] = publish_debug
			return false
		var snapshot: Dictionary = world.build_navmesh_tile_snapshot(tile_key)
		if snapshot.is_empty():
			empty_navmesh_tile_keys[tile_key] = published_key
			publish_debug.append({ "tile": tile_key, "status": "empty_snapshot" })
			continue
		var publish_start: int = monitor.begin_section("navmesh_tile_publish") if monitor != null else Time.get_ticks_usec()
		var publish_result: Dictionary = navmesh_world.register_tile_snapshot(snapshot)
		if monitor != null:
			monitor.end_section("navmesh_tile_publish", publish_start)
			monitor.increment_counter("navmesh_route_tiles_published")
		published_navmesh_tile_keys[tile_key] = published_key
		published_tile_this_call = true
		publish_debug.append({
			"tile": tile_key,
			"status": String(publish_result.get("status", "")),
			"surfaces": (snapshot.get("surfaces", []) as Array).size(),
			"doors": (snapshot.get("doorLinks", []) as Array).size(),
			"installed": bool(publish_result.get("installed", false))
		})
	entry["lastNavmeshTilePublishDebug"] = publish_debug
	if published_tile_this_call and not ordered_route:
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_deferred_queries")
		return false
	if published_tile_this_call and ordered_route and monitor != null:
		monitor.increment_counter("navmesh_tile_publish_inline_ordered_queries")
	return true

func _navmesh_tile_region_status(tile_key: String) -> Dictionary:
	if navmesh_world != null and navmesh_world.has_method("tile_region_status"):
		return navmesh_world.tile_region_status(tile_key)
	return {}

func _begin_navmesh_tile_publish_frame() -> void:
	var engine_frame := Engine.get_process_frames()
	if engine_frame == navmesh_tile_publish_engine_frame:
		return
	navmesh_tile_publish_engine_frame = engine_frame
	navmesh_tile_publishes_this_frame = 0

func _claim_navmesh_tile_publish_budget(extra_budget := 0) -> bool:
	_begin_navmesh_tile_publish_frame()
	var publish_limit := NAVMESH_TILE_PUBLISHES_PER_FRAME + maxi(0, int(extra_budget))
	if navmesh_tile_publishes_this_frame >= publish_limit:
		var monitor = performance_monitor()
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_budget_yields")
		return false
	navmesh_tile_publishes_this_frame += 1
	return true

func _begin_route_budget_frame() -> void:
	var engine_frame := Engine.get_process_frames()
	if engine_frame == route_budget_engine_frame and route_budget_tick == route_budget_seen_tick:
		return
	route_budget_engine_frame = engine_frame
	route_budget_seen_tick = route_budget_tick
	route_budget_serial += 1
	route_budget_frame = route_budget_serial
	route_jobs_this_frame = 0
	urgent_route_jobs_this_frame = 0
	starved_route_jobs_this_frame = 0

func _claim_route_budget(entry: Dictionary, intent: Dictionary) -> bool:
	_begin_route_budget_frame()
	var actor_id := String(entry.get("id", ""))
	if actor_id == "":
		route_jobs_this_frame += 1
		return true
	var route_actions: Dictionary = entry.get("routeActions", {})
	var direct_update_move := entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame")
	var external_direct_move := direct_update_move and String(entry.get("activeDoorPortalId", "")) == "" and route_actions.is_empty()
	var priority := maxi(int(intent.get("priority", 0)), int(entry.get("routePriority", 0)))
	var route_kind := String(intent.get("kind", "move"))
	var active_portal_route := String(entry.get("activeDoorPortalId", "")) != "" or bool(entry.get("holdDoorOrder", false))
	var critical_ordered_route := active_portal_route or route_kind in ["home", "scripted"]
	var threat_guard_route := route_kind == "guard" and bool(entry.get("guardRouteCritical", false))
	var routine_route := route_kind in ["guard", "work", "forage", "job", "idle", "move"]
	var urgent_route := critical_ordered_route or threat_guard_route or (priority >= 180 and not routine_route)
	var waited_frames := int(entry.get("routeBudgetWaitFrames", 0))
	var frames_since_grant := route_budget_frame - int(entry.get("routeBudgetGrantedFrame", -999999))
	if not external_direct_move and not urgent_route and waited_frames < STARVED_ROUTE_BUDGET_FRAMES and frames_since_grant >= 0 and frames_since_grant <= ROUTE_BUDGET_GRANT_COOLDOWN_FRAMES:
		entry["routeBudgetWaitFrames"] = waited_frames + 1
		var cooldown_monitor = performance_monitor()
		if cooldown_monitor != null:
			cooldown_monitor.increment_counter("route_budget_cooldown_yields")
		return false
	var starved_overflow := false
	var urgent_overflow := false
	if route_jobs_this_frame >= LIVE_ROUTE_JOBS_PER_FRAME:
		waited_frames += 1
		entry["routeBudgetWaitFrames"] = waited_frames
		if urgent_route and urgent_route_jobs_this_frame < URGENT_ROUTE_EXTRA_JOBS_PER_FRAME:
			urgent_route_jobs_this_frame += 1
			urgent_overflow = true
		elif not external_direct_move and waited_frames >= STARVED_ROUTE_BUDGET_FRAMES and starved_route_jobs_this_frame < STARVED_ROUTE_EXTRA_JOBS_PER_FRAME:
			starved_route_jobs_this_frame += 1
			starved_overflow = true
		else:
			return false
	if not critical_ordered_route and not external_direct_move and not starved_overflow and not urgent_overflow and actor_id == route_last_granted_actor_id and int(entry.get("routeBudgetYieldedFrame", -999999)) != route_budget_frame - 1:
		entry["routeBudgetYieldedFrame"] = route_budget_frame
		entry["routeBudgetWaitFrames"] = waited_frames + 1
		var monitor = performance_monitor()
		if monitor != null:
			monitor.increment_counter("route_budget_yields")
		return false
	route_jobs_this_frame += 1
	route_last_granted_actor_id = actor_id
	entry["routeBudgetGrantedFrame"] = route_budget_frame
	entry["routeBudgetWaitFrames"] = 0
	if urgent_overflow:
		var urgent_monitor = performance_monitor()
		if urgent_monitor != null:
			urgent_monitor.increment_counter("route_budget_urgent_grants")
	if starved_overflow:
		var monitor = performance_monitor()
		if monitor != null:
			monitor.increment_counter("route_budget_starved_grants")
	return true

func _route_cache_key(entry: Dictionary, intent: Dictionary) -> String:
	var body := entry.get("body") as Node3D
	var start_cell: Vector2i = world.world_cell(body.global_position) if body != null and world != null else Vector2i.ZERO
	var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", Vector3.ZERO)) if world != null else Vector2i.ZERO)
	var world_revision := ""
	if world != null and world.has_method("navmesh_tile_source_key"):
		world_revision = String(world.navmesh_tile_source_key())
	elif world != null and world.has_method("revision"):
		world_revision = world.revision()
	var navmesh_revision := ""
	if navmesh_world != null and navmesh_world.has_method("topology_revision_key"):
		navmesh_revision = String(navmesh_world.topology_revision_key())
	elif navmesh_world != null and navmesh_world.has_method("revision"):
		navmesh_revision = navmesh_world.revision()
	var profile_id := "adult_npc"
	var context = entry.get("agentContext")
	if context != null:
		profile_id = String(context.get("traversal_profile_id")) if context.get("traversal_profile_id") != null else profile_id
	var dynamic_avoid_key := _route_dynamic_avoid_key(entry)
	return "%s|%s|%s|%d,%d|%d,%d|%s|%s|%s|%s|%s|%s|%.3f" % [
		profile_id,
		world_revision,
		navmesh_revision,
		start_cell.x,
		start_cell.y,
		target_cell.x,
		target_cell.y,
		String(intent.get("kind", "move")),
		str(bool(intent.get("allowOutside", false))),
		str(bool(intent.get("movingHome", false))),
		String(intent.get("action", "")),
		dynamic_avoid_key,
		str(bool(intent.get("strictArrival", false))),
		float(intent.get("arrivalRadius", CELL * 0.75))
	]

func _route_dynamic_avoid_key(entry: Dictionary) -> String:
	var cells: Array[Vector2i] = []
	for cell_value in entry.get("routeDynamicAvoidCells", []):
		if cell_value is Vector2i:
			cells.append(cell_value)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y)
	)
	var parts: Array[String] = []
	for cell in cells:
		parts.append("%d,%d" % [cell.x, cell.y])
	return ";".join(parts)

func _store_route_cache(cache_key: String, route: Dictionary) -> void:
	if cache_key == "" or route.is_empty() or not bool(route.get("ok", false)):
		return
	route_cache[cache_key] = _compact_route_for_cache(route)
	route_cache_order.erase(cache_key)
	route_cache_order.append(cache_key)
	while route_cache_order.size() > ROUTE_CACHE_LIMIT:
		var evicted: String = route_cache_order.pop_front()
		route_cache.erase(evicted)

func _compact_route_for_cache(route: Dictionary) -> Dictionary:
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"cells": (route.get("cells", []) as Array).duplicate(),
		"waypoints": (route.get("waypoints", []) as Array).duplicate(),
		"actions": (route.get("actions", {}) as Dictionary).duplicate(true),
		"targetCell": route.get("targetCell", Vector2i(999999, 999999)),
		"fallbackCell": route.get("fallbackCell", Vector2i(999999, 999999)),
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"source": String(route.get("source", "")),
		"legacyFallbackUsed": bool(route.get("legacyFallbackUsed", false)),
		"navmeshRoute": (route.get("navmeshRoute", {}) as Dictionary).duplicate(true)
	}

func _copy_cached_route(route: Dictionary) -> Dictionary:
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"cells": (route.get("cells", []) as Array).duplicate(),
		"waypoints": (route.get("waypoints", []) as Array).duplicate(),
		"actions": (route.get("actions", {}) as Dictionary).duplicate(true),
		"targetCell": route.get("targetCell", Vector2i(999999, 999999)),
		"fallbackCell": route.get("fallbackCell", Vector2i(999999, 999999)),
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"source": String(route.get("source", "")),
		"legacyFallbackUsed": bool(route.get("legacyFallbackUsed", false)),
		"navmeshRoute": (route.get("navmeshRoute", {}) as Dictionary).duplicate(true)
	}
