extends RefCounted
class_name NpcRouteCoordinatorAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavmeshRoutePlannerScript := preload("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const LIVE_ROUTE_JOBS_PER_FRAME := 2
const ROUTE_BUDGET_GRANT_COOLDOWN_FRAMES := 2
const URGENT_ROUTE_EXTRA_JOBS_PER_FRAME := 1
const SCRIPTED_ROUTE_EXTRA_JOBS_PER_FRAME := 1
const ACTIVE_JOB_ROUTE_EXTRA_JOBS_PER_FRAME := 1
const ACTIVE_JOB_ROUTE_STARVED_FRAMES := 4
const ACTIVE_JOB_NAVMESH_TILE_STARVED_FRAMES := 8
const ACTIVE_JOB_NAVMESH_TILE_FORCE_FRAMES := 48
const STARVED_ROUTE_BUDGET_FRAMES := 12
const STARVED_ROUTE_EXTRA_JOBS_PER_FRAME := 2
const STARVED_HOME_NAVMESH_TILE_FRAMES := 12
const STARVED_HOME_GENERATED_BRIDGE_USEC := 2400
const STARVED_HOME_GENERATED_BRIDGE_VISITS := 1024
const ROUTE_CACHE_LIMIT := 128
const NAVMESH_TILE_PUBLISHES_PER_FRAME := 1
const BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME := 1
const BACKGROUND_NAVMESH_TILE_PUBLISH_FRAME_INTERVAL := 2
const BACKGROUND_NAVMESH_TILE_MAX_CHUNK_FRAME_MS := 6.0
const BACKGROUND_NAVMESH_TILE_MAX_HOSTILE_FRAME_MS := 8.0
const ORDERED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 1
const SCRIPTED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 1
const DIRECT_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 1
const COST_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 0
const ACTIVE_JOB_NAVMESH_TILE_EXTRA_PUBLISHES := 1
const ROUTINE_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 0

var system
var main
var world
var backend_config
var navmesh_planner
var navmesh_world
var route_budget_frame := -1
var route_budget_tick := 0
var route_budget_engine_frame := -1
var route_budget_seen_tick := -1
var route_budget_serial := 0
var route_jobs_this_frame := 0
var urgent_route_jobs_this_frame := 0
var scripted_route_jobs_this_frame := 0
var active_job_route_jobs_this_frame := 0
var starved_route_jobs_this_frame := 0
var navmesh_tile_publish_engine_frame := -1
var navmesh_tile_publish_seen_tick := -1
var navmesh_tile_publishes_this_frame := 0
var navmesh_tile_publish_work_this_frame := false
var route_last_granted_actor_id := ""
var route_cache := {}
var route_cache_order: Array[String] = []
var published_navmesh_tile_keys := {}
var empty_navmesh_tile_keys := {}
var queued_navmesh_tile_source_keys := {}
var queued_navmesh_tile_priority_keys := {}
var queued_navmesh_tile_keys: Array[String] = []
var last_navmesh_tile_queue_debug: Array[Dictionary] = []

func setup(system_node, main_node, navigation_world) -> void:
	system = system_node
	main = main_node
	world = navigation_world
	backend_config = NavigationBackendConfigScript.from_environment()
	navmesh_world = _navmesh_world_from_system()
	navmesh_planner = NavmeshRoutePlannerScript.new()
	navmesh_planner.setup(navmesh_world, system, main, world)

func performance_monitor():
	return main.get("runtime_perf_monitor") if main != null else null

func begin_frame() -> void:
	route_budget_tick += 1
	navmesh_tile_publish_work_this_frame = false
	if BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME > 0 and route_budget_tick % BACKGROUND_NAVMESH_TILE_PUBLISH_FRAME_INTERVAL == 0:
		if _background_navmesh_tile_publish_should_wait():
			var monitor = performance_monitor()
			if monitor != null:
				monitor.increment_counter("navmesh_tile_publish_queue_deferred_frame_work")
				monitor.increment_counter("queued_navmesh_tile_depth", queued_navmesh_tile_keys.size())
		else:
			_process_queued_navmesh_tile_publishes(BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME)

func invalidate() -> void:
	route_cache.clear()
	route_cache_order.clear()
	published_navmesh_tile_keys.clear()
	empty_navmesh_tile_keys.clear()
	queued_navmesh_tile_source_keys.clear()
	queued_navmesh_tile_priority_keys.clear()
	queued_navmesh_tile_keys.clear()

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	if navmesh_planner == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner = NavmeshRoutePlannerScript.new()
		navmesh_planner.setup(navmesh_world, system, main, world)
	elif navmesh_world == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner.setup(navmesh_world, system, main, world)
	if world == null:
		return route_failure("blocked", "missing_world", intent.get("targetCell", Vector2i(999999, 999999)))
	var monitor = performance_monitor()
	var cache_key_start: int = monitor.begin_section("route_cache_key") if monitor != null else Time.get_ticks_usec()
	var cache_key := _route_cache_key(entry, intent)
	if monitor != null:
		monitor.end_section("route_cache_key", cache_key_start)
	var force_replan := bool(entry.get("routeForceReplan", false))
	if not force_replan and route_cache.has(cache_key):
		if monitor != null:
			monitor.increment_counter("route_cache_hits")
		return _copy_cached_route(route_cache[cache_key])
	if monitor != null:
		monitor.increment_counter("route_cache_misses")
	var generated_section := ""
	if _should_try_generated_cell_home_route(entry, intent):
		generated_section = "generated_cell_home_route"
	elif _should_try_generated_cell_job_route(entry, intent):
		generated_section = "generated_cell_job_route"
	var intent_kind := String(intent.get("kind", ""))
	var prebudget_home_exit_route := generated_section == "generated_cell_job_route" \
		and bool(entry.get("insideHome", false)) \
		and intent_kind in ["work", "forage", "job"]
	var prebudget_forage_departure_route := _should_try_prebudget_forage_departure_route(entry, intent)
	if prebudget_forage_departure_route and generated_section == "":
		generated_section = "generated_cell_job_route"
	if prebudget_home_exit_route or prebudget_forage_departure_route:
		var prebudget_generated_start: int = monitor.begin_section(generated_section) if monitor != null else Time.get_ticks_usec()
		var prebudget_generated_intent := intent.duplicate(true) if prebudget_forage_departure_route else intent
		if prebudget_forage_departure_route:
			prebudget_generated_intent["generatedBridgeReason"] = "forage_departure_navmesh_budget_fallback"
			prebudget_generated_intent["allowPartial"] = true
			prebudget_generated_intent["generatedBridgeCritical"] = true
		var prebudget_generated_route: Dictionary = navmesh_planner.plan_generated_cell_route(entry, prebudget_generated_intent, world) if navmesh_planner != null and navmesh_planner.has_method("plan_generated_cell_route") else {}
		if monitor != null:
			monitor.end_section(generated_section, prebudget_generated_start)
		if not prebudget_generated_route.is_empty() and bool(prebudget_generated_route.get("ok", false)):
			_annotate_route_intent(prebudget_generated_route, intent)
			if prebudget_forage_departure_route:
				prebudget_generated_route["navmeshFallbackReason"] = "forage_departure_navmesh_budget_fallback"
			if monitor != null:
				monitor.increment_counter("generated_cell_forage_departure_routes" if prebudget_forage_departure_route else "generated_cell_home_exit_job_routes")
				monitor.increment_counter("route_jobs_completed")
			_store_route_cache(cache_key, prebudget_generated_route)
			return prebudget_generated_route
	if generated_section == "" and _routine_route_should_wait_after_navmesh_tile_publish(entry, intent):
		if monitor != null:
			monitor.increment_counter("route_jobs_pending")
			monitor.increment_counter("navmesh_tile_publish_frame_route_yields")
		var publish_frame_failure := route_failure("pending", "navmesh_tile_publish_frame_budget", intent.get("targetCell", Vector2i(999999, 999999)))
		publish_frame_failure["intentKind"] = String(intent.get("kind", ""))
		publish_frame_failure["intentPriority"] = int(intent.get("priority", 0))
		return publish_frame_failure
	var budget_start: int = monitor.begin_section("route_budget_claim") if monitor != null else Time.get_ticks_usec()
	if not _claim_route_budget(entry, intent):
		if monitor != null:
			monitor.end_section("route_budget_claim", budget_start)
			monitor.increment_counter("route_jobs_pending")
		var failure := route_failure("pending", "route_budget", intent.get("targetCell", Vector2i(999999, 999999)))
		failure["intentKind"] = String(intent.get("kind", ""))
		failure["intentPriority"] = int(intent.get("priority", 0))
		failure["routeBudgetWaitFrames"] = int(entry.get("routeBudgetWaitFrames", 0))
		return failure
	if monitor != null:
		monitor.end_section("route_budget_claim", budget_start)
	if generated_section != "":
		var generated_start: int = monitor.begin_section(generated_section) if monitor != null else Time.get_ticks_usec()
		var generated_intent := intent
		if generated_section == "generated_cell_home_route":
			generated_intent = intent.duplicate(true)
			generated_intent["generatedBridgeUsecBudget"] = STARVED_HOME_GENERATED_BRIDGE_USEC
			generated_intent["generatedBridgeMaxVisits"] = STARVED_HOME_GENERATED_BRIDGE_VISITS
			generated_intent["generatedBridgeReason"] = "starved_home_navmesh_tile_fallback"
		elif prebudget_forage_departure_route:
			generated_intent = intent.duplicate(true)
			generated_intent["generatedBridgeReason"] = "forage_departure_navmesh_budget_fallback"
			generated_intent["allowPartial"] = true
			generated_intent["generatedBridgeCritical"] = true
		var generated_route: Dictionary = navmesh_planner.plan_generated_cell_route(entry, generated_intent, world) if navmesh_planner != null and navmesh_planner.has_method("plan_generated_cell_route") else {}
		if monitor != null:
			monitor.end_section(generated_section, generated_start)
		if not generated_route.is_empty() and bool(generated_route.get("ok", false)):
			_annotate_route_intent(generated_route, intent)
			if generated_section == "generated_cell_home_route":
				generated_route["navmeshFallbackReason"] = "starved_home_navmesh_tile_fallback"
			if monitor != null:
				monitor.increment_counter("generated_cell_home_routes" if generated_section == "generated_cell_home_route" else "generated_cell_job_routes")
				monitor.increment_counter("route_jobs_completed")
			_store_route_cache(cache_key, generated_route)
			return generated_route
	var tile_prepare_start: int = monitor.begin_section("navmesh_route_tile_prepare") if monitor != null else Time.get_ticks_usec()
	if not _ensure_navmesh_route_tiles(entry, intent):
		if monitor != null:
			monitor.end_section("navmesh_route_tile_prepare", tile_prepare_start)
			monitor.increment_counter("route_jobs_pending")
		var failure := route_failure("pending", "navmesh_tile_budget", intent.get("targetCell", Vector2i(999999, 999999)))
		failure["intentKind"] = String(intent.get("kind", ""))
		failure["intentPriority"] = int(intent.get("priority", 0))
		return failure
	if monitor != null:
		monitor.end_section("navmesh_route_tile_prepare", tile_prepare_start)
	if navmesh_world != null and navmesh_world.has_method("sync_navigation_map_if_dirty"):
		var sync_start: int = monitor.begin_section("navmesh_map_sync") if monitor != null else Time.get_ticks_usec()
		navmesh_world.sync_navigation_map_if_dirty()
		if monitor != null:
			monitor.end_section("navmesh_map_sync", sync_start)
	var navmesh_start: int = monitor.begin_section("navmesh_route_query") if monitor != null else Time.get_ticks_usec()
	var result: Dictionary = navmesh_planner.plan_runtime_route(entry, intent, world, 0)
	_annotate_route_intent(result, intent)
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

func _annotate_route_intent(route: Dictionary, intent: Dictionary) -> void:
	route["intentKind"] = String(intent.get("kind", ""))
	route["intentPriority"] = int(intent.get("priority", 0))
	route["intentMovingHome"] = bool(intent.get("movingHome", false))

func _should_try_generated_cell_home_route(entry: Dictionary, intent: Dictionary) -> bool:
	if world == null or navmesh_planner == null:
		return false
	var route_kind := String(intent.get("kind", "move"))
	var moving_home := bool(intent.get("movingHome", false))
	if not moving_home and route_kind not in ["home", "scripted"]:
		return false
	# Returning home is a door/structure route. The generated cell bridge can cut
	# smoothed movement corners through wall blocks even when the discrete cells
	# look pathable, so home routes must wait for prioritized navmesh tiles.
	return false

func _should_try_generated_cell_job_route(entry: Dictionary, intent: Dictionary) -> bool:
	if world == null or navmesh_planner == null:
		return false
	var route_kind := String(intent.get("kind", "move"))
	if route_kind not in ["guard", "work", "forage", "job"]:
		return false
	if bool(intent.get("movingHome", false)):
		return false
	if String(entry.get("activeDoorPortalId", "")) != "":
		return false
	if entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame"):
		return false
	if int(intent.get("priority", int(entry.get("routePriority", 0)))) >= 180:
		return false
	return true

func _should_try_prebudget_forage_departure_route(entry: Dictionary, intent: Dictionary) -> bool:
	if world == null or navmesh_planner == null:
		return false
	if String(intent.get("kind", "move")) != "forage":
		return false
	if String(entry.get("job", "")) != "forage":
		return false
	if String(entry.get("jobObjectId", "")) != "":
		return false
	if String(entry.get("jobPhase", "")) != "searching":
		return false
	if String(entry.get("activeDoorPortalId", "")) != "":
		return false
	if bool(entry.get("insideHome", false)):
		return false
	if entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame"):
		return false
	var current_waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
	if not current_waypoints.is_empty():
		return false
	var body := entry.get("body") as Node3D
	if body == null or not is_instance_valid(body):
		return false
	var target: Vector3 = intent.get("target", body.global_position)
	if world.has_method("point_inside_town"):
		if not bool(world.point_inside_town(entry, body.global_position)):
			return false
		if bool(world.point_inside_town(entry, target)):
			return false
	return true

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = [], require_ready := false) -> float:
	if world == null:
		return INF
	if navmesh_planner == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner = NavmeshRoutePlannerScript.new()
		navmesh_planner.setup(navmesh_world, system, main, world)
	elif navmesh_world == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner.setup(navmesh_world, system, main, world)
	var cost_kind := "forage" if require_ready and String(entry.get("job", "")) == "forage" else "job" if require_ready else "cost"
	var cost_priority := maxi(int(entry.get("routePriority", 0)), 90) if require_ready else int(entry.get("routePriority", 0))
	if not _ensure_navmesh_route_tiles(entry, {
		"kind": cost_kind,
		"target": target,
		"targetCell": world.world_cell(target),
		"allowOutside": allow_outside,
		"movingHome": moving_home,
		"arrivalRadius": arrival_radius,
		"priority": cost_priority
	}):
		return INF if require_ready else _estimated_route_cost(entry, target)
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
			"event": _navigation_event_summary(event as Dictionary),
			"maxExpansionsIgnored": max_expansions
		})
	if clear_cached_routes:
		route_cache.clear()
		route_cache_order.clear()
	return responses

func _navigation_event_summary(event: Dictionary) -> Dictionary:
	var kinds: Array = event.get("changeKinds", []) if event.get("changeKinds", []) is Array else []
	return {
		"tileKey": String(event.get("tileKey", "")),
		"revision": int(event.get("revision", 0)),
		"changeKinds": kinds.duplicate(),
		"coalescedCount": int(event.get("coalescedCount", 0))
	}

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
	result["queuedNavmeshTiles"] = queued_navmesh_tile_keys.size()
	result["queuedNavmeshTileKeys"] = queued_navmesh_tile_keys.duplicate()
	result["queuedNavmeshPriorityTiles"] = queued_navmesh_tile_priority_keys.size()
	result["lastNavmeshTileQueueDebug"] = last_navmesh_tile_queue_debug.duplicate(true)
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

func _background_navmesh_tile_publish_should_wait() -> bool:
	if queued_navmesh_tile_keys.is_empty():
		return false
	if main == null:
		return false
	var chunk_ms_value = main.get("perf_chunk_ms")
	if (typeof(chunk_ms_value) == TYPE_FLOAT or typeof(chunk_ms_value) == TYPE_INT) and float(chunk_ms_value) >= BACKGROUND_NAVMESH_TILE_MAX_CHUNK_FRAME_MS:
		return true
	var hostile_ms_value = main.get("perf_hostiles_ms")
	if (typeof(hostile_ms_value) == TYPE_FLOAT or typeof(hostile_ms_value) == TYPE_INT) and float(hostile_ms_value) >= BACKGROUND_NAVMESH_TILE_MAX_HOSTILE_FRAME_MS:
		return true
	return false

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
	var start_cell: Vector2i = world.world_cell(start) if world.has_method("world_cell") else Vector2i(roundi(start.x / CELL), roundi(start.z / CELL))
	var target_cell: Vector2i = intent.get("targetCell", world.world_cell(target) if world.has_method("world_cell") else Vector2i(roundi(target.x / CELL), roundi(target.z / CELL)))
	var endpoint_tile_keys := _endpoint_navmesh_tile_keys(start_cell, target_cell)
	var route_kind := String(intent.get("kind", "move"))
	var priority := maxi(int(intent.get("priority", 0)), int(entry.get("routePriority", 0)))
	var priority_scripted_route := route_kind == "scripted" and priority >= 180
	var direct_update_move := entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame")
	var cost_route := route_kind == "cost"
	var active_job_route := route_kind in ["forage", "work", "job", "guard"]
	var routine_route := route_kind in ["guard", "work", "forage", "job", "idle", "move"]
	var high_priority_route := priority >= 180
	var home_exit_job_route := active_job_route and bool(entry.get("insideHome", false)) and route_kind in ["work", "forage", "job"]
	var margin_cells := 6 if moving_home or route_kind in ["home", "scripted"] else 4
	var active_job_route_needs_tiles := active_job_route \
		and (entry.get("pathWaypoints", []) as Array).is_empty() \
		and not _routine_route_is_background(entry, intent)
	var tile_budget_wait_frames := int(entry.get("navmeshTileBudgetWaitFrames", 0))
	var active_job_route_starved_for_tiles := active_job_route_needs_tiles and tile_budget_wait_frames >= 2
	var active_portal_route := String(entry.get("activeDoorPortalId", "")) != ""
	var critical_route_needs_tiles := moving_home or route_kind in ["home", "scripted"] or high_priority_route or active_portal_route
	var inline_publish_route := not cost_route and direct_update_move
	var burst_publish_route := false
	var monitor = performance_monitor()
	var tile_keys_start: int = monitor.begin_section("navmesh_route_tile_keys") if monitor != null else Time.get_ticks_usec()
	var tile_keys: Array = world.route_navmesh_tile_keys(entry, start, target, allow_outside, moving_home, margin_cells)
	if monitor != null:
		monitor.end_section("navmesh_route_tile_keys", tile_keys_start)
	if critical_route_needs_tiles:
		tile_keys = _route_tiles_with_endpoints_first(tile_keys, endpoint_tile_keys)
	var publish_debug := []
	var published_tile_this_call := false
	var queued_tile_this_call := false
	var queued_endpoint_tile_this_call := false
	var missing_endpoint_tile_keys := {}
	if not inline_publish_route:
		for endpoint_tile_key_value in endpoint_tile_keys.keys():
			var endpoint_tile_key := String(endpoint_tile_key_value)
			var endpoint_source_key := _navmesh_tile_source_key(endpoint_tile_key)
			var endpoint_published_key := "%s|%s" % [endpoint_tile_key, endpoint_source_key]
			if not _navmesh_tile_ready_for_route(endpoint_tile_key, endpoint_published_key):
				missing_endpoint_tile_keys[endpoint_tile_key] = true
	if critical_route_needs_tiles and not inline_publish_route and not missing_endpoint_tile_keys.is_empty():
		var endpoint_publish_count := 0
		for endpoint_tile_key_value in endpoint_tile_keys.keys():
			if endpoint_publish_count >= 2:
				break
			var endpoint_tile_key := String(endpoint_tile_key_value)
			if not missing_endpoint_tile_keys.has(endpoint_tile_key):
				continue
			var endpoint_source_key := _navmesh_tile_source_key(endpoint_tile_key)
			var endpoint_inline_result := _publish_navmesh_tile_inline(endpoint_tile_key, endpoint_source_key, 1)
			publish_debug.append(endpoint_inline_result)
			if not bool(endpoint_inline_result.get("published", false)):
				break
			missing_endpoint_tile_keys.erase(endpoint_tile_key)
			published_tile_this_call = true
			endpoint_publish_count += 1
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		if tile_key == "":
			continue
		var source_key := _navmesh_tile_source_key(tile_key)
		var published_key := "%s|%s" % [tile_key, source_key]
		if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
			publish_debug.append({ "tile": tile_key, "status": "cached_empty" })
			continue
		var endpoint_tile := endpoint_tile_keys.has(tile_key)
		var status_start: int = monitor.begin_section("navmesh_tile_status") if monitor != null else Time.get_ticks_usec()
		var tile_status := _navmesh_tile_region_status(tile_key)
		if monitor != null:
			monitor.end_section("navmesh_tile_status", status_start)
		if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
			published_navmesh_tile_keys[tile_key] = published_key
			publish_debug.append({ "tile": tile_key, "status": "cached", "region": tile_status })
			continue
		if not inline_publish_route:
			if not cost_route:
				if not endpoint_tile and not missing_endpoint_tile_keys.is_empty():
					publish_debug.append({ "tile": tile_key, "status": "skipped_until_endpoint_tiles" })
					continue
				var critical_endpoint_force_publish := critical_route_needs_tiles \
					and endpoint_tile \
					and not published_tile_this_call
				if critical_endpoint_force_publish:
					var endpoint_inline_result := _publish_navmesh_tile_inline(tile_key, source_key, 1)
					publish_debug.append(endpoint_inline_result)
					if bool(endpoint_inline_result.get("published", false)):
						missing_endpoint_tile_keys.erase(tile_key)
						published_tile_this_call = true
						continue
				var critical_route_tile_starved := critical_route_needs_tiles \
					and tile_budget_wait_frames >= 12 \
					and not published_tile_this_call \
					and not navmesh_tile_publish_work_this_frame
				var critical_route_force_publish := critical_route_tile_starved and tile_budget_wait_frames >= 90
				var active_job_route_tile_starved := active_job_route_needs_tiles \
					and tile_budget_wait_frames >= ACTIVE_JOB_NAVMESH_TILE_STARVED_FRAMES \
					and not published_tile_this_call
				var active_job_route_force_publish := active_job_route_tile_starved and tile_budget_wait_frames >= ACTIVE_JOB_NAVMESH_TILE_FORCE_FRAMES
				var can_publish_starved_route_tile := not navmesh_tile_publish_work_this_frame or critical_route_force_publish or active_job_route_force_publish
				if (critical_route_tile_starved or active_job_route_tile_starved) and can_publish_starved_route_tile and (critical_route_force_publish or active_job_route_force_publish or not _background_navmesh_tile_publish_should_wait()):
					var inline_budget := 1 if endpoint_tile or tile_budget_wait_frames >= 24 else 0
					var inline_result := _publish_navmesh_tile_inline(tile_key, source_key, inline_budget)
					publish_debug.append(inline_result)
					if bool(inline_result.get("published", false)):
						if endpoint_tile:
							missing_endpoint_tile_keys.erase(tile_key)
						published_tile_this_call = true
						continue
				var priority_queue := endpoint_tile \
					or active_job_route_needs_tiles \
					or critical_route_needs_tiles \
					or home_exit_job_route \
					or active_job_route_starved_for_tiles
				_enqueue_navmesh_tile_publish(tile_key, source_key, priority_queue)
				queued_tile_this_call = true
				if endpoint_tile:
					queued_endpoint_tile_this_call = true
				publish_debug.append({ "tile": tile_key, "status": "queued_priority" if priority_queue else "queued_budgeted" })
			else:
				publish_debug.append({ "tile": tile_key, "status": "cost_skipped_budgeted" })
			continue
		if published_tile_this_call:
			_enqueue_navmesh_tile_publish(tile_key, source_key, true)
			entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
			publish_debug.append({ "tile": tile_key, "status": "queued_after_inline_publish" })
			entry["lastNavmeshTilePublishDebug"] = publish_debug
			return false
		var extra_publishes := ORDERED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if burst_publish_route else COST_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if cost_route else SCRIPTED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if priority_scripted_route else DIRECT_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if direct_update_move else ACTIVE_JOB_NAVMESH_TILE_EXTRA_PUBLISHES if active_job_route else ROUTINE_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if routine_route else 1 if inline_publish_route else 0
		if burst_publish_route and tile_budget_wait_frames >= 2:
			extra_publishes += mini(3, tile_budget_wait_frames / 2)
		if not _claim_navmesh_tile_publish_budget(extra_publishes):
			if monitor != null:
				monitor.increment_counter("navmesh_tile_publish_pending")
			entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
			publish_debug.append({ "tile": tile_key, "status": "pending_budget" })
			entry["lastNavmeshTilePublishDebug"] = publish_debug
			return false
		var snapshot_start: int = monitor.begin_section("navmesh_tile_snapshot_build") if monitor != null else Time.get_ticks_usec()
		var snapshot: Dictionary = world.build_navmesh_tile_snapshot(tile_key)
		if monitor != null:
			monitor.end_section("navmesh_tile_snapshot_build", snapshot_start)
		if snapshot.is_empty():
			empty_navmesh_tile_keys[tile_key] = published_key
			publish_debug.append({ "tile": tile_key, "status": "empty_snapshot" })
			continue
		var publish_start: int = monitor.begin_section("navmesh_tile_publish") if monitor != null else Time.get_ticks_usec()
		var publish_result: Dictionary = navmesh_world.register_tile_snapshot(snapshot)
		if monitor != null:
			monitor.end_section("navmesh_tile_publish", publish_start)
			monitor.increment_counter("navmesh_route_tiles_published")
		_mark_navmesh_tile_publish_work()
		published_navmesh_tile_keys[tile_key] = published_key
		if endpoint_tile:
			missing_endpoint_tile_keys.erase(tile_key)
		published_tile_this_call = true
		publish_debug.append({
			"tile": tile_key,
			"status": String(publish_result.get("status", "")),
			"surfaces": (snapshot.get("surfaces", []) as Array).size(),
			"doors": (snapshot.get("doorLinks", []) as Array).size(),
			"installed": bool(publish_result.get("installed", false))
		})
	entry["lastNavmeshTilePublishDebug"] = publish_debug
	if queued_tile_this_call:
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_queued_queries")
		entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
		if critical_route_needs_tiles and missing_endpoint_tile_keys.is_empty():
			return true
		if active_job_route_starved_for_tiles and missing_endpoint_tile_keys.is_empty():
			entry["navmeshTileBudgetWaitFrames"] = 0
			return true
		if active_job_route:
			return false
		if routine_route:
			return true
		return false
	if published_tile_this_call and not inline_publish_route:
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_deferred_queries")
		if critical_route_needs_tiles and missing_endpoint_tile_keys.is_empty() and not queued_tile_this_call:
			return true
		if active_job_route_starved_for_tiles and missing_endpoint_tile_keys.is_empty():
			entry["navmeshTileBudgetWaitFrames"] = 0
			return true
		entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
		return false
	if published_tile_this_call and inline_publish_route and monitor != null:
		monitor.increment_counter("navmesh_tile_publish_inline_ordered_queries")
	entry["navmeshTileBudgetWaitFrames"] = 0
	return true

func _navmesh_tile_region_status(tile_key: String) -> Dictionary:
	if navmesh_world != null and navmesh_world.has_method("tile_region_status"):
		return navmesh_world.tile_region_status(tile_key)
	return {}

func _enqueue_navmesh_tile_publish(tile_key: String, source_key: String, priority := false) -> void:
	if tile_key == "" or source_key == "":
		return
	var was_queued := queued_navmesh_tile_source_keys.has(tile_key)
	queued_navmesh_tile_source_keys[tile_key] = source_key
	if priority:
		if queued_navmesh_tile_priority_keys.has(tile_key) and was_queued:
			return
		queued_navmesh_tile_priority_keys[tile_key] = true
		if was_queued:
			queued_navmesh_tile_keys.erase(tile_key)
		var insert_index := 0
		while insert_index < queued_navmesh_tile_keys.size() and queued_navmesh_tile_priority_keys.has(String(queued_navmesh_tile_keys[insert_index])):
			insert_index += 1
		queued_navmesh_tile_keys.insert(insert_index, tile_key)
	elif not was_queued:
		queued_navmesh_tile_keys.append(tile_key)

func _process_queued_navmesh_tile_publishes(max_tiles: int) -> int:
	if max_tiles <= 0 or world == null or navmesh_world == null:
		return 0
	if not world.has_method("build_navmesh_tile_snapshot"):
		return 0
	last_navmesh_tile_queue_debug = []
	var processed := 0
	var attempts := queued_navmesh_tile_keys.size()
	var monitor = performance_monitor()
	while processed < max_tiles and attempts > 0 and not queued_navmesh_tile_keys.is_empty():
		attempts -= 1
		var tile_key := String(queued_navmesh_tile_keys.pop_front())
		var requested_source_key := String(queued_navmesh_tile_source_keys.get(tile_key, ""))
		var priority_tile := queued_navmesh_tile_priority_keys.has(tile_key)
		queued_navmesh_tile_source_keys.erase(tile_key)
		queued_navmesh_tile_priority_keys.erase(tile_key)
		if tile_key == "" or requested_source_key == "":
			continue
		var source_key := _navmesh_tile_source_key(tile_key)
		if requested_source_key != source_key and monitor != null:
			monitor.increment_counter("navmesh_tile_publish_queue_source_refresh")
		var debug_record := {
			"tile": tile_key,
			"requestedSource": requested_source_key,
			"source": source_key,
			"priority": priority_tile,
			"status": "started"
		}
		var published_key := "%s|%s" % [tile_key, source_key]
		if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
			debug_record["status"] = "cached_empty"
			_record_navmesh_queue_debug(debug_record)
			continue
		if String(published_navmesh_tile_keys.get(tile_key, "")) == published_key:
			var tile_status := _navmesh_tile_region_status(tile_key)
			if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
				debug_record["status"] = "cached"
				debug_record["region"] = tile_status
				_record_navmesh_queue_debug(debug_record)
				continue
		if not _claim_navmesh_tile_publish_budget(1 if priority_tile else 0):
			_enqueue_navmesh_tile_publish(tile_key, requested_source_key, true)
			debug_record["status"] = "budget_denied"
			_record_navmesh_queue_debug(debug_record)
			break
		var snapshot_start: int = monitor.begin_section("navmesh_tile_snapshot_build") if monitor != null else Time.get_ticks_usec()
		var snapshot: Dictionary = world.build_navmesh_tile_snapshot(tile_key)
		if monitor != null:
			monitor.end_section("navmesh_tile_snapshot_build", snapshot_start)
		if snapshot.is_empty():
			empty_navmesh_tile_keys[tile_key] = published_key
			processed += 1
			_mark_navmesh_tile_publish_work()
			debug_record["status"] = "empty_snapshot"
			_record_navmesh_queue_debug(debug_record)
			continue
		var publish_start: int = monitor.begin_section("navmesh_tile_publish") if monitor != null else Time.get_ticks_usec()
		var publish_result: Dictionary = navmesh_world.register_tile_snapshot(snapshot)
		if monitor != null:
			monitor.end_section("navmesh_tile_publish", publish_start)
			monitor.increment_counter("navmesh_route_tiles_published")
			monitor.increment_counter("navmesh_tile_publish_queue_processed")
		published_navmesh_tile_keys[tile_key] = published_key
		processed += 1
		_mark_navmesh_tile_publish_work()
		debug_record["status"] = String(publish_result.get("status", "published"))
		debug_record["surfaces"] = (snapshot.get("surfaces", []) as Array).size()
		debug_record["installed"] = bool(publish_result.get("installed", false))
		_record_navmesh_queue_debug(debug_record)
	return processed

func _record_navmesh_queue_debug(record: Dictionary) -> void:
	last_navmesh_tile_queue_debug.append(record)
	while last_navmesh_tile_queue_debug.size() > 8:
		last_navmesh_tile_queue_debug.pop_front()

func _begin_navmesh_tile_publish_frame() -> void:
	var engine_frame := Engine.get_process_frames()
	if engine_frame == navmesh_tile_publish_engine_frame and navmesh_tile_publish_seen_tick == route_budget_tick:
		return
	navmesh_tile_publish_engine_frame = engine_frame
	navmesh_tile_publish_seen_tick = route_budget_tick
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

func _navmesh_tile_source_key(tile_key: String) -> String:
	if world != null and world.has_method("navmesh_tile_source_key_for_tile"):
		return String(world.navmesh_tile_source_key_for_tile(tile_key))
	if world != null and world.has_method("navmesh_tile_source_key"):
		return String(world.navmesh_tile_source_key())
	return String(world.revision()) if world != null and world.has_method("revision") else ""

func queue_navmesh_tile_publish(tile_key: String, priority := false) -> bool:
	if tile_key == "" or world == null or navmesh_world == null:
		return false
	var source_key := _navmesh_tile_source_key(tile_key)
	if source_key == "":
		return false
	var published_key := "%s|%s" % [tile_key, source_key]
	if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
		return false
	if String(published_navmesh_tile_keys.get(tile_key, "")) == published_key:
		var tile_status := _navmesh_tile_region_status(tile_key)
		if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
			return false
	_enqueue_navmesh_tile_publish(tile_key, source_key, priority)
	var monitor = performance_monitor()
	if monitor != null:
		monitor.increment_counter("navmesh_tile_publish_startup_queued")
		monitor.increment_counter("queued_navmesh_tile_depth", queued_navmesh_tile_keys.size())
	return true

func _publish_navmesh_tile_inline(tile_key: String, source_key: String, extra_budget: int) -> Dictionary:
	var result := { "tile": tile_key, "status": "pending_budget", "published": false }
	if tile_key == "" or source_key == "" or world == null or navmesh_world == null:
		result["status"] = "missing_context"
		return result
	var monitor = performance_monitor()
	if not _claim_navmesh_tile_publish_budget(extra_budget):
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_pending")
		return result
	var snapshot_start: int = monitor.begin_section("navmesh_tile_snapshot_build") if monitor != null else Time.get_ticks_usec()
	var snapshot: Dictionary = world.build_navmesh_tile_snapshot(tile_key)
	if monitor != null:
		monitor.end_section("navmesh_tile_snapshot_build", snapshot_start)
	var published_key := "%s|%s" % [tile_key, source_key]
	if snapshot.is_empty():
		empty_navmesh_tile_keys[tile_key] = published_key
		result["status"] = "empty_snapshot"
		result["published"] = true
		return result
	var publish_start: int = monitor.begin_section("navmesh_tile_publish") if monitor != null else Time.get_ticks_usec()
	var publish_result: Dictionary = navmesh_world.register_tile_snapshot(snapshot)
	if monitor != null:
		monitor.end_section("navmesh_tile_publish", publish_start)
		monitor.increment_counter("navmesh_route_tiles_published")
		monitor.increment_counter("navmesh_tile_publish_inline_endpoint_queries")
	_mark_navmesh_tile_publish_work()
	published_navmesh_tile_keys[tile_key] = published_key
	result["status"] = String(publish_result.get("status", "published"))
	result["published"] = true
	result["surfaces"] = (snapshot.get("surfaces", []) as Array).size()
	result["doors"] = (snapshot.get("doorLinks", []) as Array).size()
	result["installed"] = bool(publish_result.get("installed", false))
	return result

func _mark_navmesh_tile_publish_work() -> void:
	navmesh_tile_publish_work_this_frame = true

func _routine_route_should_wait_after_navmesh_tile_publish(entry: Dictionary, intent: Dictionary) -> bool:
	if not navmesh_tile_publish_work_this_frame:
		return false
	var route_kind := String(intent.get("kind", "move"))
	var priority := maxi(int(intent.get("priority", 0)), int(entry.get("routePriority", 0)))
	if bool(intent.get("movingHome", false)) or route_kind in ["home", "scripted"] or priority >= 180:
		return false
	if String(entry.get("activeDoorPortalId", "")) != "":
		return false
	if entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame"):
		return false
	return route_kind in ["guard", "work", "forage", "job", "idle", "move"]

func _navmesh_tile_ready_for_route(tile_key: String, published_key: String) -> bool:
	if tile_key == "" or published_key == "":
		return false
	if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
		return true
	var tile_status := _navmesh_tile_region_status(tile_key)
	if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
		published_navmesh_tile_keys[tile_key] = published_key
		return true
	return false

func _endpoint_navmesh_tile_keys(start_cell: Vector2i, target_cell: Vector2i) -> Dictionary:
	var result := {}
	if world != null and world.has_method("tile_key_for_cell"):
		result[String(world.tile_key_for_cell(start_cell))] = true
		result[String(world.tile_key_for_cell(target_cell))] = true
		return result
	var tile_size: int = maxi(1, NpcConstantsScript.NAV_TILE_CELL_SIZE)
	result["%d,%d" % [floori(float(start_cell.x) / float(tile_size)), floori(float(start_cell.y) / float(tile_size))]] = true
	result["%d,%d" % [floori(float(target_cell.x) / float(tile_size)), floori(float(target_cell.y) / float(tile_size))]] = true
	return result

func _route_tiles_with_endpoints_first(tile_keys: Array, endpoint_tile_keys: Dictionary) -> Array:
	if tile_keys.is_empty() or endpoint_tile_keys.is_empty():
		return tile_keys
	var ordered := []
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		if tile_key != "" and endpoint_tile_keys.has(tile_key) and not ordered.has(tile_key):
			ordered.append(tile_key)
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		if tile_key != "" and not ordered.has(tile_key):
			ordered.append(tile_key)
	return ordered

func _estimated_route_cost(entry: Dictionary, target: Vector3) -> float:
	var body := entry.get("body") as Node3D
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	return Vector2(start.x - target.x, start.z - target.z).length()

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
	scripted_route_jobs_this_frame = 0
	active_job_route_jobs_this_frame = 0
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
	var critical_ordered_route := route_kind == "home"
	var threat_guard_route := route_kind == "guard" and bool(entry.get("guardRouteCritical", false))
	var priority_scripted_route := route_kind == "scripted" and priority >= 180
	var routine_route := route_kind in ["guard", "work", "forage", "job", "idle", "move", "scripted"]
	var active_job_route := route_kind in ["guard", "forage", "work", "job"]
	var urgent_route := critical_ordered_route or threat_guard_route or priority_scripted_route or (priority >= 180 and not routine_route)
	var waited_frames := int(entry.get("routeBudgetWaitFrames", 0))
	var frames_since_grant := route_budget_frame - int(entry.get("routeBudgetGrantedFrame", -999999))
	if routine_route and not urgent_route and route_kind != "scripted" and _routine_route_is_background(entry, intent):
		entry["routeBudgetWaitFrames"] = waited_frames + 1
		var background_monitor = performance_monitor()
		if background_monitor != null:
			background_monitor.increment_counter("route_budget_background_yields")
		return false
	if not external_direct_move and not urgent_route and not active_job_route and waited_frames < STARVED_ROUTE_BUDGET_FRAMES and frames_since_grant >= 0 and frames_since_grant <= ROUTE_BUDGET_GRANT_COOLDOWN_FRAMES:
		entry["routeBudgetWaitFrames"] = waited_frames + 1
		var cooldown_monitor = performance_monitor()
		if cooldown_monitor != null:
			cooldown_monitor.increment_counter("route_budget_cooldown_yields")
		return false
	var starved_overflow := false
	var urgent_overflow := false
	var scripted_overflow := false
	var active_job_overflow := false
	if route_jobs_this_frame >= LIVE_ROUTE_JOBS_PER_FRAME:
		waited_frames += 1
		entry["routeBudgetWaitFrames"] = waited_frames
		if priority_scripted_route and scripted_route_jobs_this_frame < SCRIPTED_ROUTE_EXTRA_JOBS_PER_FRAME:
			scripted_route_jobs_this_frame += 1
			scripted_overflow = true
		elif urgent_route and urgent_route_jobs_this_frame < URGENT_ROUTE_EXTRA_JOBS_PER_FRAME:
			urgent_route_jobs_this_frame += 1
			urgent_overflow = true
		elif active_job_route and active_job_route_jobs_this_frame < ACTIVE_JOB_ROUTE_EXTRA_JOBS_PER_FRAME:
			active_job_route_jobs_this_frame += 1
			active_job_overflow = true
		elif route_kind != "scripted" and not external_direct_move and waited_frames >= (ACTIVE_JOB_ROUTE_STARVED_FRAMES if active_job_route else STARVED_ROUTE_BUDGET_FRAMES) and starved_route_jobs_this_frame < STARVED_ROUTE_EXTRA_JOBS_PER_FRAME:
			starved_route_jobs_this_frame += 1
			starved_overflow = true
		else:
			return false
	if not active_job_route and not critical_ordered_route and not priority_scripted_route and not external_direct_move and not starved_overflow and not active_job_overflow and not urgent_overflow and not scripted_overflow and actor_id == route_last_granted_actor_id and int(entry.get("routeBudgetYieldedFrame", -999999)) != route_budget_frame - 1:
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
	if scripted_overflow:
		var scripted_monitor = performance_monitor()
		if scripted_monitor != null:
			scripted_monitor.increment_counter("route_budget_scripted_grants")
	if active_job_overflow:
		var active_job_monitor = performance_monitor()
		if active_job_monitor != null:
			active_job_monitor.increment_counter("route_budget_active_job_grants")
	if starved_overflow:
		var monitor = performance_monitor()
		if monitor != null:
			monitor.increment_counter("route_budget_starved_grants")
	return true

func _routine_route_is_background(entry: Dictionary, intent: Dictionary) -> bool:
	if main == null:
		return false
	var player_node := main.get("player") as Node3D
	if player_node == null:
		return false
	var body := entry.get("body") as Node3D
	var actor_position: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", player_node.global_position))
	if absf(actor_position.y - player_node.global_position.y) > CELL * 12.0:
		return true
	var route_kind := String(intent.get("kind", "move"))
	if _player_is_sprinting(player_node):
		if route_kind == "guard" and not bool(entry.get("guardRouteCritical", false)):
			return true
		if route_kind in ["forage", "work", "job", "idle", "move"]:
			var flat_delta := Vector2(actor_position.x - player_node.global_position.x, actor_position.z - player_node.global_position.z)
			if flat_delta.length() > CELL * 20.0:
				return true
	return false

func _player_is_sprinting(player_node: Node3D) -> bool:
	if bool(player_node.get("is_sprinting")):
		return true
	if bool(player_node.get("automated_sprint")):
		return true
	var body := player_node as CharacterBody3D
	if body == null:
		return false
	var horizontal_velocity := Vector2(body.velocity.x, body.velocity.z).length()
	return horizontal_velocity >= CELL * 8.0

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
	var route_kind_for_cache := String(intent.get("kind", "move"))
	var dynamic_avoid_key := "" if route_kind_for_cache == "scripted" else _route_dynamic_avoid_key(entry)
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
	if cache_key == "" or route.is_empty():
		return
	if not bool(route.get("ok", false)) and not _route_failure_cacheable(route):
		return
	route_cache[cache_key] = _compact_route_for_cache(route)
	route_cache_order.erase(cache_key)
	route_cache_order.append(cache_key)
	while route_cache_order.size() > ROUTE_CACHE_LIMIT:
		var evicted: String = route_cache_order.pop_front()
		route_cache.erase(evicted)

func _route_failure_cacheable(route: Dictionary) -> bool:
	if String(route.get("status", "")) == "pending":
		return false
	var reason := String(route.get("reason", ""))
	return reason in [
		"target_blocked",
		"no_route",
		"path_endpoint_mismatch",
		"path_crosses_static_collision",
		"blocked_static_collision",
		"blocked_static_transition",
		"forbidden_private_door_link"
	]

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
