extends RefCounted
class_name NpcRouteCoordinatorAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const HierarchicalRoutePlannerScript := preload("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")
const IncrementalRouteRepairScript := preload("res://scripts/npc_ai/routing/IncrementalRouteRepair.gd")
const NavmeshRoutePlannerScript := preload("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const LIVE_ROUTE_JOBS_PER_FRAME := 2
const LIVE_ROUTE_EXPANSIONS_PER_FRAME := 8
const EXTERNAL_DIRECT_ROUTE_EXPANSIONS := 64
const ROUTE_BUDGET_GRANT_COOLDOWN_FRAMES := 2
const URGENT_ROUTE_EXTRA_JOBS_PER_FRAME := 12
const STARVED_ROUTE_BUDGET_FRAMES := 12
const STARVED_ROUTE_EXTRA_JOBS_PER_FRAME := 1
const ROUTE_CACHE_LIMIT := 128
const FULL_REPAIR_REGISTRATION_NODE_LIMIT := 128

var system
var main
var world
var backend_config
var coordinator
var navmesh_planner
var navmesh_world
var repair_service
var active_route_entries := {}
var route_budget_frame := -1
var route_budget_tick := 0
var route_budget_engine_frame := -1
var route_budget_seen_tick := -1
var route_budget_serial := 0
var route_jobs_this_frame := 0
var urgent_route_jobs_this_frame := 0
var starved_route_jobs_this_frame := 0
var route_last_granted_actor_id := ""
var route_cache := {}
var route_cache_order: Array[String] = []

func setup(system_node, main_node, navigation_world) -> void:
	system = system_node
	main = main_node
	world = navigation_world
	backend_config = NavigationBackendConfigScript.from_environment()
	coordinator = HierarchicalRoutePlannerScript.new()
	coordinator.setup(null)
	navmesh_world = _navmesh_world_from_system()
	navmesh_planner = NavmeshRoutePlannerScript.new()
	navmesh_planner.setup(navmesh_world, system, main, world)
	repair_service = IncrementalRouteRepairScript.new()
	repair_service.setup(coordinator)

func performance_monitor():
	return main.get("runtime_perf_monitor") if main != null else null

func begin_frame() -> void:
	route_budget_tick += 1

func invalidate() -> void:
	route_cache.clear()
	route_cache_order.clear()
	active_route_entries.clear()
	if coordinator != null and coordinator.has_method("clear"):
		coordinator.clear()
	if repair_service != null and repair_service.has_method("clear"):
		repair_service.clear()

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	if coordinator == null:
		coordinator = HierarchicalRoutePlannerScript.new()
	if navmesh_planner == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner = NavmeshRoutePlannerScript.new()
		navmesh_planner.setup(navmesh_world, system, main, world)
	if repair_service == null:
		repair_service = IncrementalRouteRepairScript.new()
		repair_service.setup(coordinator)
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
	if _use_navmesh_backend():
		var navmesh_start: int = monitor.begin_section("navmesh_route_query") if monitor != null else Time.get_ticks_usec()
		var navmesh_result: Dictionary = navmesh_planner.plan_runtime_route(entry, intent, world, 0)
		if monitor != null:
			monitor.end_section("navmesh_route_query", navmesh_start)
			monitor.increment_counter("navmesh_route_queries")
			if bool(navmesh_result.get("ok", false)):
				monitor.increment_counter("navmesh_route_successes")
			else:
				monitor.increment_counter("navmesh_route_failures")
		if String(navmesh_result.get("status", "")) != "pending":
			_store_route_cache(cache_key, navmesh_result)
		return navmesh_result
	var external_direct_route := entry.has("_externalDirectMoveFrame")
	var route_section := "route_planning_external_direct" if external_direct_route else "route_planning"
	var route_start: int = monitor.begin_section(route_section) if monitor != null else Time.get_ticks_usec()
	var expansion_budget := _expansion_budget_for(entry, intent)
	var result: Dictionary = coordinator.plan_runtime_route(entry, intent, world, expansion_budget)
	if monitor != null:
		monitor.end_section(route_section, route_start)
		if String(result.get("status", "")) == "pending":
			monitor.increment_counter("route_jobs_pending")
		else:
			monitor.increment_counter("route_jobs_completed")
	if String(result.get("status", "")) != "pending":
		_store_route_cache(cache_key, result)
	_register_repair_route(entry, result)
	return result

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = []) -> float:
	if coordinator == null:
		coordinator = HierarchicalRoutePlannerScript.new()
	if world == null:
		return INF
	if _use_navmesh_backend():
		if navmesh_planner == null:
			navmesh_world = _navmesh_world_from_system()
			navmesh_planner = NavmeshRoutePlannerScript.new()
			navmesh_planner.setup(navmesh_world, system, main, world)
		return navmesh_planner.route_cost_for_runtime(entry, target, allow_outside, moving_home, arrival_radius, approach_cells, world)
	return coordinator.route_cost_for_runtime(entry, target, allow_outside, moving_home, arrival_radius, approach_cells, world)

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
	if repair_service == null:
		return responses
	for event in events:
		var route_ids: Array[String] = repair_service.routes_for_event(event)
		for route_id in route_ids:
			var response: Dictionary = repair_service.repair_after_event(route_id, event, {}, max_expansions)
			responses.append(response)
			_apply_repair_response(route_id, response)
	return responses

func stats() -> Dictionary:
	var result: Dictionary = coordinator.stats() if coordinator != null and coordinator.has_method("stats") else {}
	result["backend"] = backend_config.to_summary() if backend_config != null else NavigationBackendConfigScript.default_config().to_summary()
	if navmesh_planner != null and navmesh_planner.has_method("stats"):
		result["navmesh"] = navmesh_planner.stats()
	if repair_service != null:
		result["repair"] = repair_service.stats()
	return result

func _use_navmesh_backend() -> bool:
	if backend_config == null:
		backend_config = NavigationBackendConfigScript.from_environment()
	if not backend_config.use_navmesh():
		return false
	if navmesh_world == null:
		navmesh_world = _navmesh_world_from_system()
		if navmesh_planner != null:
			navmesh_planner.setup(navmesh_world, system, main, world)
	return navmesh_world != null

func _navmesh_world_from_system():
	if system == null:
		return null
	var autonomy = system.get("autonomy_system")
	if autonomy == null:
		return null
	return autonomy.get("navmesh_world")

func _register_repair_route(entry: Dictionary, route: Dictionary) -> void:
	if repair_service == null or not bool(route.get("ok", false)):
		return
	var typed_result = route.get("typedResult")
	if typed_result == null or typed_result.get("corridor") == null:
		return
	var graph: Dictionary = typed_result.get("repair_graph")
	var start_key: String = String(typed_result.get("repair_start_key"))
	var goal_keys: Array = typed_result.get("repair_goal_keys")
	if graph.is_empty() or start_key == "" or goal_keys.is_empty():
		repair_service.index_result(_route_id_for_entry(entry), typed_result)
		return
	var route_id: String = _route_id_for_entry(entry)
	var monitor = performance_monitor()
	var node_count := (graph.get("nodes", {}) as Dictionary).size()
	if node_count <= FULL_REPAIR_REGISTRATION_NODE_LIMIT:
		repair_service.register_route(route_id, graph, start_key, goal_keys, typed_result.get("repair_request"), typed_result.get("corridor"))
		if monitor != null:
			monitor.increment_counter("repair_route_full_registrations")
	else:
		repair_service.index_result(route_id, typed_result)
		if monitor != null:
			monitor.increment_counter("repair_route_indexed_registrations")
	active_route_entries[route_id] = entry

func _apply_repair_response(route_id: String, response: Dictionary) -> void:
	var entry: Dictionary = active_route_entries.get(route_id, {})
	if entry.is_empty():
		return
	var status: StringName = response.get("status")
	var reason: StringName = response.get("reason")
	if status == NpcEnumsScript.REPAIR_STATUS_UNCHANGED:
		return
	if String(reason) == "indexed_only":
		entry["routeForceReplan"] = true
		entry["routeStatus"] = "waiting"
		entry["routeReason"] = "indexed_replan"
		return
	if status == NpcEnumsScript.REPAIR_STATUS_REPAIRED and response.get("routeResult") != null:
		var route_result = response.get("routeResult")
		var corridor = route_result.get("corridor")
		if corridor != null:
			entry["routeCells"] = corridor.cells_2d()
			entry["pathWaypoints"] = corridor.waypoints.duplicate()
			entry["routeActions"] = corridor.actions_by_cell()
			entry["routeReason"] = ""
			entry["routeStatus"] = "moving"
			entry["routeForceReplan"] = false
			return
	entry["routeForceReplan"] = status == NpcEnumsScript.REPAIR_STATUS_ACTION_REVISION or status == NpcEnumsScript.REPAIR_STATUS_FAILED
	if bool((response.get("metrics", {}) as Dictionary).get("safeStopRequired", false)):
		entry["pathWaypoints"] = []
	entry["routeStatus"] = "waiting" if status == NpcEnumsScript.REPAIR_STATUS_WAITING else "blocked"
	entry["routeReason"] = String(reason)

func _route_id_for_entry(entry: Dictionary) -> String:
	return "runtime:%s" % String(entry.get("id", "npc"))

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
	var urgent_route := priority >= 90 or route_kind in ["home", "scripted", "job"]
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
	if not external_direct_move and not starved_overflow and not urgent_overflow and actor_id == route_last_granted_actor_id and int(entry.get("routeBudgetYieldedFrame", -999999)) != route_budget_frame - 1:
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

func _expansion_budget_for(entry: Dictionary, intent: Dictionary) -> int:
	if entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame"):
		return EXTERNAL_DIRECT_ROUTE_EXPANSIONS
	if bool(intent.get("movingHome", false)) or String(intent.get("kind", "")) in ["home", "scripted"]:
		return EXTERNAL_DIRECT_ROUTE_EXPANSIONS
	if bool(entry.get("tutorial", false)) or int(entry.get("routePriority", 0)) >= 140:
		return EXTERNAL_DIRECT_ROUTE_EXPANSIONS
	return LIVE_ROUTE_EXPANSIONS_PER_FRAME

func _route_cache_key(entry: Dictionary, intent: Dictionary) -> String:
	var body := entry.get("body") as Node3D
	var start_cell: Vector2i = world.world_cell(body.global_position) if body != null and world != null else Vector2i.ZERO
	var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", Vector3.ZERO)) if world != null else Vector2i.ZERO)
	var static_revision := 0
	if world != null:
		static_revision = int(world.get("static_snapshot_revision"))
	var profile_id := "adult_npc"
	var context = entry.get("agentContext")
	if context != null:
		profile_id = String(context.get("traversal_profile_id")) if context.get("traversal_profile_id") != null else profile_id
	return "%s|%d|%d,%d|%d,%d|%s|%s|%s|%s|%s|%.3f" % [
		profile_id,
		static_revision,
		start_cell.x,
		start_cell.y,
		target_cell.x,
		target_cell.y,
		String(intent.get("kind", "move")),
		str(bool(intent.get("allowOutside", false))),
		str(bool(intent.get("movingHome", false))),
		String(intent.get("action", "")),
		str(bool(intent.get("strictArrival", false))),
		float(intent.get("arrivalRadius", CELL * 0.75))
	]

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
