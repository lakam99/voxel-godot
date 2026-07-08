extends RefCounted
class_name NavmeshRoutePlanner

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const INVALID_CELL := Vector2i(999999, 999999)
const INITIAL_HAIRPIN_MAX_DISTANCE := CELL * 1.25
const INITIAL_HAIRPIN_TARGET_MARGIN := CELL * 0.12
const GENERATED_CELL_BRIDGE_MAX_VISITS := 1536
const GENERATED_CELL_BRIDGE_ACTIVE_JOB_MAX_VISITS := 192
const GENERATED_CELL_BRIDGE_ROUTINE_MAX_VISITS := 32
const GENERATED_CELL_BRIDGE_MARGIN_CELLS := 8
const GENERATED_CELL_BRIDGE_MAX_USEC := 5500
const GENERATED_CELL_BRIDGE_ACTIVE_JOB_MAX_USEC := 1500
const GENERATED_CELL_BRIDGE_ROUTINE_MAX_USEC := 250
const GENERATED_CELL_BRIDGE_FRAME_MAX_USEC := 7000
const GENERATED_CELL_BRIDGE_MAX_VALIDATION_STEPS := 160
const GENERATED_CELL_BRIDGE_ACTIVE_JOB_MAX_VALIDATION_STEPS := 80
const GENERATED_CELL_BRIDGE_ROUTINE_MAX_VALIDATION_STEPS := 24

var navmesh_world = null
var system = null
var main = null
var world_adapter = null
var last_stats := {}
var _generated_bridge_came_from := {}
var _generated_bridge_block_reasons := {}
var _generated_bridge_last_visited := 0
var _generated_bridge_last_reason := ""
var _generated_bridge_budget_frame := -1
var _generated_bridge_budget_used_usec := 0

func setup(navmesh_service = null, system_node = null, main_node = null, generated_world_adapter = null) -> void:
	navmesh_world = navmesh_service
	system = system_node
	main = main_node
	world_adapter = generated_world_adapter

func plan_runtime_route(entry: Dictionary, intent: Dictionary, generated_world = null, _max_expansions := 0) -> Dictionary:
	var target: Vector3 = intent.get("target", Vector3.ZERO)
	var target_cell: Vector2i = _world_cell(target, generated_world)
	var query_target := _nav_query_position(target, target_cell, generated_world)
	if navmesh_world == null:
		return _route_failure("blocked", "missing_navmesh_world", target_cell)
	var body := entry.get("body") as Node3D
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	var start_cell: Vector2i = _world_cell(start, generated_world)
	var query_start_position := _nav_query_position(start, start_cell, generated_world)
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	var target_block_start: int = monitor.begin_section("navmesh_route_target_block_check") if monitor != null else Time.get_ticks_usec()
	var blocked_target := _target_cell_blocked(entry, target_cell, generated_world, bool(intent.get("allowOutside", false)), bool(intent.get("movingHome", false)))
	if monitor != null:
		monitor.end_section("navmesh_route_target_block_check", target_block_start)
	if blocked_target:
		return _route_failure("blocked", "target_blocked", target_cell, { "targetCell": target_cell })
	var query_api := _runtime_query_api(intent)
	var forbidden_private_door_ids := _forbidden_private_door_portal_ids(entry, generated_world)
	var primary_query_start: int = monitor.begin_section("navmesh_route_primary_query") if monitor != null else Time.get_ticks_usec()
	var route: Dictionary = navmesh_world.query_route(query_start_position, query_target, {
		"actorId": String(entry.get("id", "")),
		"kind": String(intent.get("kind", "move")),
		"allowOutside": bool(intent.get("allowOutside", false)),
		"movingHome": bool(intent.get("movingHome", false)),
		"arrivalRadius": float(intent.get("arrivalRadius", CELL * 0.75)),
		"targetCell": target_cell,
		"maxSnapDistance": maxf(float(intent.get("arrivalRadius", CELL * 0.75)), CELL * 0.95),
		"queryApi": query_api,
		"preferDescriptorEndpoint": true,
		"forbiddenDoorPortalIds": forbidden_private_door_ids
	})
	if monitor != null:
		monitor.end_section("navmesh_route_primary_query", primary_query_start)
	last_stats = navmesh_world.stats() if navmesh_world.has_method("stats") else {}
	last_stats["lastRouteSource"] = String(route.get("source", "navmesh"))
	last_stats["legacyFallbackUsed"] = false
	if not bool(route.get("ok", false)):
		var bridge_allowed := _initial_failure_cell_bridge_allowed(entry, intent, route)
		var bridge_first := bridge_allowed and _prefer_generated_bridge_before_navmesh_fallback(intent)
		var bridge_intent := _cell_bridge_repair_intent(intent) if bridge_allowed else intent
		if bridge_first:
			var bridge_start: int = monitor.begin_section("navmesh_route_generated_bridge") if monitor != null else Time.get_ticks_usec()
			var cell_bridge_route := _plan_generated_cell_bridge_route(entry, bridge_intent, generated_world, start_cell, target_cell, route)
			if monitor != null:
				monitor.end_section("navmesh_route_generated_bridge", bridge_start)
			if not cell_bridge_route.is_empty():
				return cell_bridge_route
		var fallback_start: int = monitor.begin_section("navmesh_route_fallback_cells") if monitor != null else Time.get_ticks_usec()
		var fallback_route := _plan_fallback_cell_route(entry, intent, generated_world, start, start_cell, target_cell, route, forbidden_private_door_ids)
		if monitor != null:
			monitor.end_section("navmesh_route_fallback_cells", fallback_start)
		if not fallback_route.is_empty():
			return fallback_route
		if bridge_allowed and not bridge_first:
			var bridge_start: int = monitor.begin_section("navmesh_route_generated_bridge") if monitor != null else Time.get_ticks_usec()
			var cell_bridge_route := _plan_generated_cell_bridge_route(entry, bridge_intent, generated_world, start_cell, target_cell, route)
			if monitor != null:
				monitor.end_section("navmesh_route_generated_bridge", bridge_start)
			if not cell_bridge_route.is_empty():
				return cell_bridge_route
		elif not bridge_allowed and route is Dictionary:
			route["generatedCellBridge"] = {
				"ok": false,
				"reason": "skipped_routine_endpoint_mismatch"
			}
			return _route_failure(String(route.get("status", "blocked")), String(route.get("reason", "no_route")), target_cell, route)
		if route is Dictionary:
			return _route_failure(String(route.get("status", "blocked")), String(route.get("reason", "no_route")), target_cell, route)
	var fallback_cell: Vector2i = route.get("fallbackCell", target_cell) if route.get("fallbackCell", target_cell) is Vector2i else target_cell
	var validate_build_start: int = monitor.begin_section("navmesh_route_validate_build") if monitor != null else Time.get_ticks_usec()
	var runtime_route := _build_runtime_route_from_navmesh(entry, intent, generated_world, start, query_start_position, query_target, target_cell, fallback_cell, route)
	if monitor != null:
		monitor.end_section("navmesh_route_validate_build", validate_build_start)
	if bool(runtime_route.get("ok", false)):
		return runtime_route
	var rejected_navmesh_route: Dictionary = runtime_route.get("navmeshRoute", route) if runtime_route.get("navmeshRoute", route) is Dictionary else route
	var repair_route: Dictionary = runtime_route
	if not _post_validation_cell_repair_allowed(runtime_route, intent) and not _post_validation_cell_repair_allowed(rejected_navmesh_route, intent):
		return runtime_route
	var bridge_first_after_validation := _prefer_generated_bridge_before_navmesh_fallback(intent)
	if bridge_first_after_validation:
		var bridge_after_start: int = monitor.begin_section("navmesh_route_post_validation_bridge") if monitor != null else Time.get_ticks_usec()
		var bridge_after_validation := _plan_generated_cell_bridge_route(entry, _cell_bridge_repair_intent(intent), generated_world, start_cell, target_cell, repair_route)
		if monitor != null:
			monitor.end_section("navmesh_route_post_validation_bridge", bridge_after_start)
		if not bridge_after_validation.is_empty():
			return bridge_after_validation
	var fallback_after_start: int = monitor.begin_section("navmesh_route_post_validation_fallback_cells") if monitor != null else Time.get_ticks_usec()
	var fallback_after_validation := _plan_fallback_cell_route(entry, intent, generated_world, start, start_cell, target_cell, repair_route, forbidden_private_door_ids)
	if monitor != null:
		monitor.end_section("navmesh_route_post_validation_fallback_cells", fallback_after_start)
	if not fallback_after_validation.is_empty():
		return fallback_after_validation
	if not bridge_first_after_validation:
		var bridge_after_start: int = monitor.begin_section("navmesh_route_post_validation_bridge") if monitor != null else Time.get_ticks_usec()
		var bridge_after_validation := _plan_generated_cell_bridge_route(entry, _cell_bridge_repair_intent(intent), generated_world, start_cell, target_cell, repair_route)
		if monitor != null:
			monitor.end_section("navmesh_route_post_validation_bridge", bridge_after_start)
		if not bridge_after_validation.is_empty():
			return bridge_after_validation
	return runtime_route

func plan_generated_cell_route(entry: Dictionary, intent: Dictionary, generated_world = null) -> Dictionary:
	if _home_route_requires_complete_navmesh(intent):
		return {}
	var source = generated_world if generated_world != null else world_adapter
	if source == null:
		return {}
	var target: Vector3 = intent.get("target", Vector3.ZERO)
	var target_cell := _world_cell(target, source)
	var body := entry.get("body") as Node3D
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	var start_cell := _world_cell(start, source)
	var failed_route := {
		"ok": false,
		"status": "blocked",
		"reason": "generated_cell_primary",
		"source": "generated_cell_bridge"
	}
	var route := _plan_generated_cell_bridge_route(entry, intent, source, start_cell, target_cell, failed_route)
	if route.is_empty():
		return {}
	route["source"] = "generated_cell_bridge"
	route["legacyFallbackUsed"] = false
	route["navmeshRoute"] = failed_route
	return route

func _post_validation_cell_repair_allowed(route: Dictionary, intent: Dictionary) -> bool:
	var route_kind := String(intent.get("kind", "move"))
	var status := String(route.get("status", ""))
	var reason := String(route.get("reason", ""))
	if bool(intent.get("movingHome", false)) or route_kind == "home":
		if reason == "path_endpoint_partial" and status in ["pending", "partial"]:
			return true
		if status != "blocked":
			return false
		return reason in [
			"path_endpoint_mismatch",
			"path_crosses_static_collision",
			"blocked_static_collision",
			"blocked_static_transition"
		]
	if status == "partial" and reason == "path_endpoint_partial":
		return true
	if bool(intent.get("movingHome", false)) and status == "blocked":
		return reason in [
			"path_crosses_static_collision",
			"blocked_static_collision",
			"blocked_static_transition"
		]
	if route_kind in ["idle", "move", "forage", "work", "job", "guard"] and status == "blocked":
		return reason in [
			"path_crosses_static_collision",
			"blocked_static_collision",
			"blocked_static_transition"
		]
	return false

func _prefer_generated_bridge_before_navmesh_fallback(intent: Dictionary) -> bool:
	var route_kind := String(intent.get("kind", "move"))
	if _home_route_requires_complete_navmesh(intent):
		return false
	if _routine_route_kind(route_kind):
		return false
	return bool(intent.get("movingHome", false)) \
		or bool(intent.get("strictArrival", false)) \
		or route_kind in ["home", "scripted"] \
		or int(intent.get("priority", 0)) >= 180

func _initial_failure_cell_bridge_allowed(entry: Dictionary, intent: Dictionary, route: Dictionary) -> bool:
	var reason := String(route.get("reason", ""))
	var route_kind := String(intent.get("kind", "move"))
	if _home_route_requires_complete_navmesh(intent):
		return reason == "path_endpoint_mismatch"
	if bool(intent.get("movingHome", false)) or (bool(intent.get("strictArrival", false)) and not _routine_route_kind(route_kind)):
		return true
	if route_kind in ["home", "scripted"]:
		return true
	if _routine_route_kind(route_kind):
		return reason in [
			"navmesh_tile_budget",
			"navmesh_tile_publish_frame_budget",
			"route_budget",
			"endpoint_not_server_walkable",
			"path_endpoint_mismatch",
			"path_crosses_static_collision",
			"blocked_static_collision",
			"blocked_static_transition"
		]
	if reason != "path_endpoint_mismatch":
		return true
	return false

func _plan_fallback_cell_route(entry: Dictionary, intent: Dictionary, generated_world, start: Vector3, start_cell: Vector2i, target_cell: Vector2i, failed_route: Dictionary, forbidden_private_door_ids: Array[String]) -> Dictionary:
	var fallback_cells_value = intent.get("fallbackCells", [])
	if not (fallback_cells_value is Array):
		return {}
	var source = generated_world if generated_world != null else world_adapter
	if source == null or not source.has_method("cell_position"):
		return {}
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	var arrival_radius := float(intent.get("arrivalRadius", CELL * 0.75))
	var query_start_position := _nav_query_position(start, start_cell, generated_world)
	var tried := {}
	var fallback_debug := []
	for fallback_value in fallback_cells_value:
		if not (fallback_value is Vector2i):
			continue
		var fallback_cell: Vector2i = fallback_value
		if fallback_cell == target_cell or tried.has(fallback_cell):
			continue
		tried[fallback_cell] = true
		if _target_cell_blocked(entry, fallback_cell, generated_world, allow_outside, moving_home):
			fallback_debug.append({ "cell": fallback_cell, "status": "blocked_target" })
			continue
		var fallback_position: Vector3 = source.cell_position(fallback_cell)
		var query_target := _nav_query_position(fallback_position, fallback_cell, generated_world)
		var route: Dictionary = navmesh_world.query_route(query_start_position, query_target, {
			"actorId": String(entry.get("id", "")),
			"kind": String(intent.get("kind", "move")),
			"allowOutside": allow_outside,
			"movingHome": moving_home,
			"arrivalRadius": maxf(arrival_radius, CELL * 0.55),
			"targetCell": fallback_cell,
			"maxSnapDistance": maxf(arrival_radius, CELL * 0.95),
			"queryApi": _runtime_query_api(intent),
			"preferDescriptorEndpoint": true,
			"forbiddenDoorPortalIds": forbidden_private_door_ids
		})
		fallback_debug.append({
			"cell": fallback_cell,
			"ok": bool(route.get("ok", false)),
			"status": String(route.get("status", "")),
			"reason": String(route.get("reason", "")),
			"pointCount": int(route.get("pointCount", 0))
		})
		if not bool(route.get("ok", false)):
			continue
		var runtime_route := _build_runtime_route_from_navmesh(entry, intent, generated_world, start, query_start_position, query_target, target_cell, fallback_cell, route)
		if bool(runtime_route.get("ok", false)):
			runtime_route["navmeshFallbackReason"] = String(failed_route.get("reason", "fallback_cell_route"))
			runtime_route["navmeshFallbackAttempts"] = fallback_debug
			return runtime_route
	if failed_route is Dictionary:
		failed_route["fallbackAttempts"] = fallback_debug
	return {}

func _plan_generated_cell_bridge_route(entry: Dictionary, intent: Dictionary, generated_world, start_cell: Vector2i, target_cell: Vector2i, failed_route: Dictionary) -> Dictionary:
	if _home_route_requires_complete_navmesh(intent):
		if failed_route is Dictionary:
			failed_route["generatedCellBridge"] = {
				"ok": false,
				"reason": "home_route_requires_complete_navmesh"
			}
		return {}
	var source = generated_world if generated_world != null else world_adapter
	if source == null \
		or not source.has_method("cached_static_tile_snapshot") \
		or not source.has_method("cell_transition_pathable") \
		or not source.has_method("cell_position"):
		return {}
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	var snapshot: Dictionary = source.cached_static_tile_snapshot(allow_outside, moving_home)
	var goal_cells := _generated_bridge_goal_cells(intent, target_cell)
	if goal_cells.is_empty():
		return {}
	var target_lookup := {}
	for goal in goal_cells:
		target_lookup[goal] = true
	if bool(intent.get("strictArrival", false)) or bool(intent.get("movingHome", false)):
		target_lookup["_strictTargetCollision"] = true
	var bounds := _generated_bridge_bounds(start_cell, goal_cells)
	var visit_budget := _generated_bridge_visit_budget(entry, intent)
	var requested_usec_budget := _generated_bridge_usec_budget(entry, intent)
	var frame_usec_budget := _generated_bridge_frame_budget_remaining_usec()
	if frame_usec_budget <= 0:
		if failed_route is Dictionary:
			failed_route["generatedCellBridge"] = {
				"ok": false,
				"reason": "generated_cell_bridge_frame_budget",
				"goals": goal_cells.size(),
				"visited": 0,
				"maxVisits": visit_budget,
				"maxUsec": 0,
				"blockedReasons": {}
			}
		var frame_budget_monitor = main.get("runtime_perf_monitor") if main != null else null
		if frame_budget_monitor != null:
			frame_budget_monitor.increment_counter("generated_cell_bridge_frame_budget_yields")
		return {}
	var usec_budget := mini(requested_usec_budget, frame_usec_budget)
	var bridge_search_start_usec := Time.get_ticks_usec()
	var found_cell := _generated_bridge_search(entry, source, snapshot, start_cell, target_lookup, bounds, visit_budget, usec_budget, bool(intent.get("allowPartial", false)))
	_consume_generated_bridge_frame_budget(bridge_search_start_usec)
	if found_cell == INVALID_CELL:
		if failed_route is Dictionary:
			failed_route["generatedCellBridge"] = {
				"ok": false,
				"reason": _generated_bridge_last_reason if _generated_bridge_last_reason != "" else "no_generated_cell_route",
				"goals": goal_cells.size(),
				"visited": _generated_bridge_last_visited,
				"maxVisits": visit_budget,
				"maxUsec": usec_budget,
				"blockedReasons": _generated_bridge_block_reasons.duplicate()
			}
		return {}
	var cells := _generated_bridge_reconstruct_path(found_cell)
	var validation_step_budget := _generated_bridge_validation_step_budget(entry, intent)
	if validation_step_budget > 0 and cells.size() - 1 > validation_step_budget:
		if failed_route is Dictionary:
			failed_route["generatedCellBridge"] = {
				"ok": false,
				"reason": "generated_cell_bridge_validation_step_budget",
				"goals": goal_cells.size(),
				"visited": _generated_bridge_last_visited,
				"maxVisits": visit_budget,
				"maxUsec": usec_budget,
				"maxValidationSteps": validation_step_budget,
				"blockedReasons": _generated_bridge_block_reasons.duplicate()
			}
		return {}
	var validation_usec_budget := 0 if _generated_bridge_critical(intent) else _generated_bridge_frame_budget_remaining_usec()
	if validation_usec_budget <= 0 and not _generated_bridge_critical(intent):
		if failed_route is Dictionary:
			failed_route["generatedCellBridge"] = {
				"ok": false,
				"reason": "generated_cell_bridge_validation_frame_budget",
				"goals": goal_cells.size(),
				"visited": _generated_bridge_last_visited,
				"maxVisits": visit_budget,
				"maxUsec": usec_budget,
				"maxValidationSteps": validation_step_budget,
				"blockedReasons": _generated_bridge_block_reasons.duplicate()
			}
		var validation_budget_monitor = main.get("runtime_perf_monitor") if main != null else null
		if validation_budget_monitor != null:
			validation_budget_monitor.increment_counter("generated_cell_bridge_validation_frame_budget_yields")
		return {}
	var validation_start_usec := Time.get_ticks_usec()
	var validation := _generated_bridge_validate_path(entry, source, snapshot, cells, target_lookup, validation_usec_budget)
	_consume_generated_bridge_frame_budget(validation_start_usec)
	if not bool(validation.get("ok", false)):
		if failed_route is Dictionary:
			failed_route["generatedCellBridge"] = {
				"ok": false,
				"reason": String(validation.get("reason", "generated_cell_bridge_validation_failed")),
				"goals": goal_cells.size(),
				"visited": _generated_bridge_last_visited,
				"maxVisits": visit_budget,
				"maxUsec": usec_budget,
				"maxValidationSteps": validation_step_budget,
				"blockedReasons": _generated_bridge_block_reasons.duplicate(),
				"validation": validation
			}
		return {}
	if cells.size() <= 1:
		return {
			"ok": true,
			"status": "arrived",
			"reason": "",
			"cells": [],
			"waypoints": [],
			"actions": {},
			"targetCell": target_cell,
			"fallbackCell": found_cell,
			"snapshotRevision": "",
			"source": "navmesh",
			"legacyFallbackUsed": false,
			"navmeshRoute": failed_route,
			"generatedCellBridge": true
		}
	var waypoints: Array[Vector3] = []
	for index in range(1, cells.size()):
		waypoints.append(source.cell_position(cells[index]))
	var actions := _generated_bridge_door_actions(entry, source, snapshot, cells)
	var using_fallback := found_cell != target_cell
	return {
		"ok": true,
		"status": "partial" if using_fallback else "routed",
		"reason": "generated_cell_bridge" if using_fallback else "",
		"cells": cells.slice(1),
		"waypoints": waypoints,
		"actions": actions,
		"targetCell": target_cell,
		"fallbackCell": found_cell,
		"snapshotRevision": "",
		"source": "navmesh",
		"legacyFallbackUsed": false,
		"navmeshFallbackReason": String(failed_route.get("reason", "")) if failed_route is Dictionary else "",
		"navmeshRoute": failed_route,
		"generatedCellBridge": true
	}

func _generated_bridge_goal_cells(intent: Dictionary, target_cell: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	result.append(target_cell)
	if not bool(intent.get("strictArrival", false)):
		var arrival_radius := float(intent.get("arrivalRadius", CELL * 0.75))
		var radius_cells := maxi(0, floori((arrival_radius + CELL * 0.05) / CELL))
		for z in range(-radius_cells, radius_cells + 1):
			for x in range(-radius_cells, radius_cells + 1):
				if x == 0 and z == 0:
					continue
				var offset := Vector2(float(x) * CELL, float(z) * CELL)
				if offset.length() > arrival_radius + CELL * 0.05:
					continue
				var cell := target_cell + Vector2i(x, z)
				if not result.has(cell):
					result.append(cell)
	var fallback_cells = intent.get("fallbackCells", [])
	if fallback_cells is Array:
		for value in fallback_cells:
			if value is Vector2i and not result.has(value):
				result.append(value)
	return result

func _generated_bridge_bounds(start_cell: Vector2i, goals: Array[Vector2i]) -> Dictionary:
	var min_x := start_cell.x
	var max_x := start_cell.x
	var min_z := start_cell.y
	var max_z := start_cell.y
	for goal in goals:
		min_x = mini(min_x, goal.x)
		max_x = maxi(max_x, goal.x)
		min_z = mini(min_z, goal.y)
		max_z = maxi(max_z, goal.y)
	return {
		"minX": min_x - GENERATED_CELL_BRIDGE_MARGIN_CELLS,
		"maxX": max_x + GENERATED_CELL_BRIDGE_MARGIN_CELLS,
		"minZ": min_z - GENERATED_CELL_BRIDGE_MARGIN_CELLS,
		"maxZ": max_z + GENERATED_CELL_BRIDGE_MARGIN_CELLS
	}

func _generated_bridge_visit_budget(entry: Dictionary, intent: Dictionary) -> int:
	var override := int(intent.get("generatedBridgeMaxVisits", 0))
	if override > 0:
		return override
	var route_kind := String(intent.get("kind", "move"))
	var critical_bridge := _generated_bridge_critical(intent)
	if (entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame")) and critical_bridge:
		return GENERATED_CELL_BRIDGE_MAX_VISITS
	if route_kind in ["guard", "work", "forage", "job"]:
		return GENERATED_CELL_BRIDGE_ACTIVE_JOB_MAX_VISITS
	if _routine_route_kind(route_kind):
		return GENERATED_CELL_BRIDGE_ROUTINE_MAX_VISITS
	if critical_bridge:
		return GENERATED_CELL_BRIDGE_MAX_VISITS
	return GENERATED_CELL_BRIDGE_ROUTINE_MAX_VISITS

func _generated_bridge_usec_budget(entry: Dictionary, intent: Dictionary) -> int:
	var override := int(intent.get("generatedBridgeUsecBudget", 0))
	if override > 0:
		return override
	var route_kind := String(intent.get("kind", "move"))
	var critical_bridge := _generated_bridge_critical(intent)
	if (entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame")) and critical_bridge:
		return GENERATED_CELL_BRIDGE_MAX_USEC
	if route_kind in ["guard", "work", "forage", "job"]:
		return GENERATED_CELL_BRIDGE_ACTIVE_JOB_MAX_USEC
	if _routine_route_kind(route_kind):
		return GENERATED_CELL_BRIDGE_ROUTINE_MAX_USEC
	if critical_bridge:
		return GENERATED_CELL_BRIDGE_MAX_USEC
	return GENERATED_CELL_BRIDGE_ROUTINE_MAX_USEC

func _generated_bridge_validation_step_budget(entry: Dictionary, intent: Dictionary) -> int:
	var route_kind := String(intent.get("kind", "move"))
	if _generated_bridge_critical(intent):
		return GENERATED_CELL_BRIDGE_MAX_VALIDATION_STEPS
	if route_kind in ["guard", "work", "forage", "job"]:
		return GENERATED_CELL_BRIDGE_ACTIVE_JOB_MAX_VALIDATION_STEPS
	if _routine_route_kind(route_kind):
		return GENERATED_CELL_BRIDGE_ROUTINE_MAX_VALIDATION_STEPS
	return GENERATED_CELL_BRIDGE_ROUTINE_MAX_VALIDATION_STEPS

func _generated_bridge_critical(intent: Dictionary) -> bool:
	if bool(intent.get("generatedBridgeCritical", false)):
		return true
	var route_kind := String(intent.get("kind", "move"))
	return bool(intent.get("movingHome", false)) \
		or bool(intent.get("strictArrival", false)) \
		or route_kind in ["home", "scripted"] \
		or int(intent.get("priority", 0)) >= 180

func _home_route_requires_complete_navmesh(intent: Dictionary) -> bool:
	var route_kind := String(intent.get("kind", "move"))
	return (bool(intent.get("movingHome", false)) or route_kind == "home") and not bool(intent.get("allowHomeCellBridgeRepair", false))

func _cell_bridge_repair_intent(intent: Dictionary) -> Dictionary:
	if not bool(intent.get("movingHome", false)) and String(intent.get("kind", "move")) != "home":
		return intent
	var repair_intent := intent.duplicate(true)
	repair_intent["allowHomeCellBridgeRepair"] = true
	return repair_intent

func _begin_generated_bridge_budget_frame() -> void:
	var engine_frame := Engine.get_process_frames()
	if _generated_bridge_budget_frame == engine_frame:
		return
	_generated_bridge_budget_frame = engine_frame
	_generated_bridge_budget_used_usec = 0

func _generated_bridge_frame_budget_remaining_usec() -> int:
	_begin_generated_bridge_budget_frame()
	return maxi(0, GENERATED_CELL_BRIDGE_FRAME_MAX_USEC - _generated_bridge_budget_used_usec)

func _consume_generated_bridge_frame_budget(start_usec: int) -> void:
	_begin_generated_bridge_budget_frame()
	_generated_bridge_budget_used_usec += maxi(0, Time.get_ticks_usec() - start_usec)

func _routine_route_kind(route_kind: String) -> bool:
	return route_kind in ["guard", "work", "forage", "job", "idle", "move"]

func _generated_bridge_search(entry: Dictionary, source, snapshot: Dictionary, start_cell: Vector2i, target_lookup: Dictionary, bounds: Dictionary, max_visits: int, max_usec: int, allow_partial := false) -> Vector2i:
	_generated_bridge_came_from = {}
	_generated_bridge_block_reasons = {}
	_generated_bridge_last_visited = 0
	_generated_bridge_last_reason = ""
	var avoid_lookup := _generated_bridge_avoid_lookup(entry, target_lookup)
	var search_start_usec := Time.get_ticks_usec()
	var open: Array[Vector2i] = [start_cell]
	var closed := {}
	var g_score := { start_cell: 0 }
	var directions: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var visit_limit := maxi(1, max_visits)
	var usec_limit := maxi(1, max_usec)
	while not open.is_empty() and closed.size() < visit_limit:
		if closed.size() > 0 and Time.get_ticks_usec() - search_start_usec >= usec_limit:
			_generated_bridge_last_visited = closed.size()
			var partial_cell := _generated_bridge_best_partial_cell(closed, start_cell, target_lookup) if allow_partial else INVALID_CELL
			if allow_partial and partial_cell != INVALID_CELL:
				_generated_bridge_last_reason = "generated_cell_bridge_time_budget_partial"
				return partial_cell
			_generated_bridge_last_reason = "generated_cell_bridge_time_budget"
			return INVALID_CELL
		var best_index := _generated_bridge_best_open_index(open, g_score, target_lookup)
		var cell := open[best_index]
		open.remove_at(best_index)
		if closed.has(cell):
			continue
		closed[cell] = true
		if target_lookup.has(cell):
			_generated_bridge_last_visited = closed.size()
			return cell
		for direction in directions:
			var next := cell + direction
			if closed.has(next) or not _generated_bridge_cell_in_bounds(next, bounds):
				continue
			if avoid_lookup.has(next):
				_generated_bridge_block_reasons["route_avoid_cell"] = int(_generated_bridge_block_reasons.get("route_avoid_cell", 0)) + 1
				continue
			var transition: Dictionary = {}
			if source.has_method("cell_bridge_search_pathable"):
				transition = source.cell_bridge_search_pathable(entry, snapshot, cell, next, target_lookup, true)
			elif source.has_method("cell_transition_pathable"):
				transition = source.cell_transition_pathable(entry, snapshot, cell, next, target_lookup, true)
			elif source.has_method("cell_pathable"):
				transition = source.cell_pathable(entry, snapshot, cell, next, target_lookup, true)
			else:
				transition = source.cell_transition_pathable(entry, snapshot, cell, next, target_lookup, true)
			if not bool(transition.get("ok", false)):
				var reason := String(transition.get("reason", "blocked"))
				_generated_bridge_block_reasons[reason] = int(_generated_bridge_block_reasons.get(reason, 0)) + 1
				continue
			var tentative_g := int(g_score.get(cell, 0)) + 1
			if g_score.has(next) and tentative_g >= int(g_score.get(next, 0)):
				continue
			g_score[next] = tentative_g
			_generated_bridge_came_from[next] = cell
			if not open.has(next):
				open.append(next)
	_generated_bridge_last_visited = closed.size()
	_generated_bridge_last_reason = "generated_cell_bridge_visit_budget" if closed.size() >= visit_limit else "no_generated_cell_route"
	if allow_partial and closed.size() >= visit_limit:
		var partial_cell := _generated_bridge_best_partial_cell(closed, start_cell, target_lookup)
		if partial_cell != INVALID_CELL:
			_generated_bridge_last_reason = "generated_cell_bridge_visit_budget_partial"
			return partial_cell
	return INVALID_CELL

func _generated_bridge_avoid_lookup(entry: Dictionary, target_lookup: Dictionary) -> Dictionary:
	var lookup := {}
	for cell_value in entry.get("routeDynamicAvoidCells", []):
		if cell_value is Vector2i and not target_lookup.has(cell_value):
			lookup[cell_value] = true
	return lookup

func _generated_bridge_best_partial_cell(closed: Dictionary, start_cell: Vector2i, target_lookup: Dictionary) -> Vector2i:
	var start_h := _generated_bridge_heuristic(start_cell, target_lookup)
	var best_cell := INVALID_CELL
	var best_h := start_h
	var best_g := 2147483647
	for cell_value in closed.keys():
		if not (cell_value is Vector2i):
			continue
		var cell: Vector2i = cell_value
		if cell == start_cell:
			continue
		var h := _generated_bridge_heuristic(cell, target_lookup)
		var g := absi(cell.x - start_cell.x) + absi(cell.y - start_cell.y)
		if h < best_h or (h == best_h and g < best_g):
			best_cell = cell
			best_h = h
			best_g = g
	return best_cell

func _generated_bridge_best_open_index(open: Array[Vector2i], g_score: Dictionary, target_lookup: Dictionary) -> int:
	var best_index := 0
	var best_f := 2147483647
	var best_h := 2147483647
	var best_g := 2147483647
	for index in range(open.size()):
		var cell := open[index]
		var g := int(g_score.get(cell, 2147483647))
		var h := _generated_bridge_heuristic(cell, target_lookup)
		var f := g + h
		var best_cell := open[best_index]
		if f < best_f \
			or (f == best_f and h < best_h) \
			or (f == best_f and h == best_h and g < best_g) \
			or (f == best_f and h == best_h and g == best_g and (cell.x < best_cell.x or (cell.x == best_cell.x and cell.y < best_cell.y))):
			best_index = index
			best_f = f
			best_h = h
			best_g = g
	return best_index

func _generated_bridge_heuristic(cell: Vector2i, target_lookup: Dictionary) -> int:
	var best := 2147483647
	for target_value in target_lookup.keys():
		if not (target_value is Vector2i):
			continue
		var target: Vector2i = target_value
		best = mini(best, absi(cell.x - target.x) + absi(cell.y - target.y))
	return 0 if best == 2147483647 else best

func _generated_bridge_cell_in_bounds(cell: Vector2i, bounds: Dictionary) -> bool:
	return cell.x >= int(bounds.get("minX", cell.x)) \
		and cell.x <= int(bounds.get("maxX", cell.x)) \
		and cell.y >= int(bounds.get("minZ", cell.y)) \
		and cell.y <= int(bounds.get("maxZ", cell.y))

func _generated_bridge_reconstruct_path(found_cell: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = [found_cell]
	var cursor := found_cell
	while _generated_bridge_came_from.has(cursor):
		cursor = _generated_bridge_came_from[cursor]
		cells.push_front(cursor)
	return cells

func _generated_bridge_validate_path(entry: Dictionary, source, snapshot: Dictionary, cells: Array[Vector2i], target_lookup: Dictionary, max_usec := 0) -> Dictionary:
	if cells.size() <= 1 or not source.has_method("cell_transition_pathable"):
		return { "ok": true, "reason": "" }
	var validation_start_usec := Time.get_ticks_usec()
	var usec_limit := maxi(0, max_usec)
	for index in range(1, cells.size()):
		if usec_limit > 0 and index > 1 and Time.get_ticks_usec() - validation_start_usec >= usec_limit:
			return {
				"ok": false,
				"reason": "generated_cell_bridge_validation_time_budget",
				"pathIndex": index
			}
		var from_cell: Vector2i = cells[index - 1]
		var to_cell: Vector2i = cells[index]
		var transition: Dictionary = source.cell_transition_pathable(entry, snapshot, from_cell, to_cell, target_lookup, true)
		if not bool(transition.get("ok", false)):
			transition["ok"] = false
			transition["reason"] = String(transition.get("reason", "generated_cell_bridge_validation_failed"))
			transition["fromCell"] = from_cell
			transition["toCell"] = to_cell
			transition["pathIndex"] = index
			return transition
	return { "ok": true, "reason": "" }

func _generated_bridge_door_actions(entry: Dictionary, source, snapshot: Dictionary, cells: Array[Vector2i]) -> Dictionary:
	var actions := {}
	if not source.has_method("door_at"):
		return actions
	for index in range(1, cells.size()):
		var from_cell := cells[index - 1]
		var to_cell := cells[index]
		var door = source.door_at(snapshot, to_cell)
		if door == null:
			door = source.door_at(snapshot, from_cell)
		if door == null:
			door = _live_door_at_flat_cell(to_cell)
		if door == null:
			door = _live_door_at_flat_cell(from_cell)
		if not (door is Node):
			continue
		var portal_id := _generated_bridge_door_portal_id(source, door, to_cell)
		var action_cell := to_cell
		actions["%d,%d" % [action_cell.x, action_cell.y]] = {
			"kind": "door",
			"portalId": portal_id,
			"actionId": "open",
			"cell": action_cell,
			"entryCell": from_cell,
			"entryPosition": source.cell_position(from_cell),
			"exitPosition": source.cell_position(to_cell),
			"direction": _generated_bridge_direction(from_cell, to_cell),
			"navLink": false,
			"requiresSmartObject": true,
			"enabled": true,
			"door": door
		}
	return actions

func _live_door_at_flat_cell(cell: Vector2i) -> Node:
	if main == null:
		return null
	var blocks_value = main.get("blocks")
	if not (blocks_value is Dictionary):
		return null
	var blocks: Dictionary = blocks_value
	for key_value in blocks.keys():
		if not (key_value is Vector3i):
			continue
		var key: Vector3i = key_value
		if key.x != cell.x or key.z != cell.y:
			continue
		var block = blocks.get(key)
		if block == null or not is_instance_valid(block) or not (block is Node):
			continue
		var node := block as Node
		if String(node.get_meta("block_type", "")) == "door":
			return node
	return null

func _generated_bridge_door_portal_id(source, door: Node, cell: Vector2i) -> String:
	if source != null and source.has_method("_door_portal_id"):
		return String(source.call("_door_portal_id", door, cell))
	if door.has_meta("door_portal_id"):
		return String(door.get_meta("door_portal_id"))
	return "door:%d,0,%d" % [cell.x, cell.y]

func _generated_bridge_direction(from_cell: Vector2i, to_cell: Vector2i) -> String:
	var delta := to_cell - from_cell
	if abs(delta.x) >= abs(delta.y) and delta.x != 0:
		return "x+" if delta.x > 0 else "x-"
	if delta.y != 0:
		return "z+" if delta.y > 0 else "z-"
	return ""

func _build_runtime_route_from_navmesh(entry: Dictionary, intent: Dictionary, generated_world, start: Vector3, fallback_query_start: Vector3, query_target: Vector3, target_cell: Vector2i, fallback_cell: Vector2i, route: Dictionary) -> Dictionary:
	var query_start: Vector3 = route.get("startPosition", fallback_query_start)
	var route_target: Vector3 = route.get("targetPosition", query_target)
	var raw_points := _route_points_for_validation(route.get("path", []), query_start, route_target)
	var validation := _validate_generated_world_route(entry, intent, generated_world, raw_points, target_cell, route)
	if not bool(validation.get("ok", false)):
		var rejected_route := route.duplicate(true)
		rejected_route["validation"] = validation
		return _route_failure("blocked", "path_crosses_static_collision", target_cell, rejected_route)
	var waypoints: Array = _path_waypoints(raw_points, query_start, route_target, generated_world, entry, bool(intent.get("allowOutside", false)), bool(intent.get("movingHome", false)))
	var cells: Array[Vector2i] = _cells_for_waypoints(waypoints, generated_world)
	var sampled_cells: Array[Vector2i] = _cells_for_route_points(raw_points, generated_world)
	var actions := _route_actions_with_detected_doors(entry, intent, generated_world, sampled_cells, route.get("actions", {}))
	cells = _preserve_route_action_cells(cells, actions)
	var using_fallback := fallback_cell != target_cell
	if using_fallback and (bool(intent.get("movingHome", false)) or String(intent.get("kind", "move")) == "home"):
		var partial_route := route.duplicate(true)
		partial_route["fallbackCell"] = fallback_cell
		partial_route["targetCell"] = target_cell
		partial_route["cells"] = cells
		return _route_failure("pending", "path_endpoint_partial", target_cell, partial_route)
	var status := "arrived" if waypoints.is_empty() and not using_fallback else "partial" if using_fallback else "routed"
	var reason := "fallback_cell_route" if using_fallback else ""
	return {
		"ok": true,
		"status": status,
		"reason": reason,
		"cells": cells,
		"waypoints": waypoints,
		"actions": actions,
		"targetCell": target_cell,
		"fallbackCell": fallback_cell if using_fallback else cells[cells.size() - 1] if not cells.is_empty() else target_cell,
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"source": "navmesh",
		"legacyFallbackUsed": false,
		"navmeshRoute": route
	}

func route_cost_for_runtime(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, _approach_cells: Array = [], generated_world = null) -> float:
	if navmesh_world == null:
		return INF
	var body := entry.get("body") as Node3D
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	var target_cell := _world_cell(target, generated_world)
	var start_cell := _world_cell(start, generated_world)
	if _target_cell_blocked(entry, target_cell, generated_world, allow_outside, moving_home):
		return INF
	var forbidden_private_door_ids := _forbidden_private_door_portal_ids(entry, generated_world)
	var route: Dictionary = navmesh_world.query_route(_nav_query_position(start, start_cell, generated_world), _nav_query_position(target, target_cell, generated_world), {
		"actorId": String(entry.get("id", "")),
		"kind": "cost",
		"allowOutside": allow_outside,
		"movingHome": moving_home,
		"arrivalRadius": arrival_radius,
		"targetCell": target_cell,
		"maxSnapDistance": maxf(arrival_radius, CELL * 0.95),
		"costOnly": true,
		"queryApi": "map_get_path",
		"optimizePath": false,
		"forbiddenDoorPortalIds": forbidden_private_door_ids
	})
	if not bool(route.get("ok", false)):
		var intent := {
			"kind": "cost",
			"target": target,
			"targetCell": target_cell,
			"allowOutside": allow_outside,
			"movingHome": moving_home,
			"arrivalRadius": arrival_radius,
			"priority": 180,
			"strictArrival": false,
			"fallbackCells": []
		}
		var generated_route := _plan_generated_cell_bridge_route(entry, intent, generated_world, start_cell, target_cell, route)
		if bool(generated_route.get("ok", false)):
			return _route_flat_distance(start, generated_route)
		return INF
	return float(route.get("distance", INF))

func _route_flat_distance(start: Vector3, route: Dictionary) -> float:
	var points: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	if points.is_empty():
		return 0.0
	var distance := 0.0
	var previous := start
	for point_value in points:
		if not (point_value is Vector3):
			continue
		var point: Vector3 = point_value
		distance += _flat_distance(previous, point)
		previous = point
	return distance

func stats() -> Dictionary:
	return last_stats.duplicate(true)

func _runtime_query_api(intent: Dictionary) -> String:
	if _routine_route_kind(String(intent.get("kind", "move"))):
		return "map_get_path"
	return "query_path"

func _forbidden_private_door_portal_ids(entry: Dictionary, generated_world = null) -> Array[String]:
	var source = generated_world if generated_world != null else world_adapter
	if source == null or not source.has_method("forbidden_private_door_portal_ids_for_entry"):
		return []
	return source.forbidden_private_door_portal_ids_for_entry(entry)

func _route_points_for_validation(path_value, start: Vector3, target: Vector3) -> Array:
	var points: Array = []
	if path_value is PackedVector3Array:
		for point in path_value:
			points.append(point)
	elif path_value is Array:
		for point in path_value:
			if point is Vector3:
				points.append(point)
	if points.is_empty() or (points[0] as Vector3).distance_to(start) > CELL * 0.08:
		points.push_front(start)
	if points.is_empty() or (points[points.size() - 1] as Vector3).distance_to(target) > CELL * 0.12:
		points.append(target)
	return points

func _validate_generated_world_route(entry: Dictionary, intent: Dictionary, generated_world, points: Array, target_cell: Vector2i, route: Dictionary) -> Dictionary:
	var source = generated_world if generated_world != null else world_adapter
	if source == null or not source.has_method("validate_waypoint_route"):
		return { "ok": true, "reason": "" }
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	var snapshot: Dictionary = source.cached_static_tile_snapshot(allow_outside, moving_home) if source.has_method("cached_static_tile_snapshot") else source.build_snapshot(entry, allow_outside, moving_home)
	var target_lookup := { target_cell: true }
	if bool(intent.get("strictArrival", false)) or moving_home:
		target_lookup["_strictTargetCollision"] = true
	var actions: Dictionary = route.get("actions", {}) if route.get("actions", {}) is Dictionary else {}
	for action_value in actions.values():
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value
		var action_cell = action.get("cell")
		if action_cell is Vector2i:
			target_lookup[action_cell] = true
	return source.validate_waypoint_route(entry, snapshot, points, target_lookup, true)

func _path_waypoints(path_value, start: Vector3, target: Vector3, generated_world = null, entry := {}, allow_outside := false, moving_home := false) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if path_value is PackedVector3Array:
		for point in path_value:
			result.append(point)
	elif path_value is Array:
		for point in path_value:
			if point is Vector3:
				result.append(point)
	while not result.is_empty() and result[0].distance_to(start) <= CELL * 0.08:
		result.remove_at(0)
	result = _prune_initial_hairpin_waypoints(result, start, target)
	if result.is_empty() and start.distance_to(target) > CELL * 0.08:
		result.append(target)
	if not result.is_empty() and result[result.size() - 1].distance_to(target) > CELL * 0.12:
		result.append(target)
	return result

func _prune_initial_hairpin_waypoints(waypoints: Array[Vector3], start: Vector3, target: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = waypoints.duplicate()
	var target_delta := _flat_delta(start, target)
	if target_delta.length_squared() <= 0.0001:
		return result
	var target_direction := target_delta.normalized()
	while result.size() >= 2:
		var first: Vector3 = result[0]
		var second: Vector3 = result[1]
		var first_delta := _flat_delta(start, first)
		if first_delta.length() > INITIAL_HAIRPIN_MAX_DISTANCE:
			break
		var second_delta := _flat_delta(start, second)
		var first_projection := first_delta.dot(target_direction)
		var second_projection := second_delta.dot(target_direction)
		var first_to_target := _flat_distance(first, target)
		var second_to_target := _flat_distance(second, target)
		var target_opposing := first_projection < -INITIAL_HAIRPIN_TARGET_MARGIN
		var dominated_by_next := second_projection > first_projection and second_to_target + INITIAL_HAIRPIN_TARGET_MARGIN < first_to_target
		if not target_opposing and not dominated_by_next:
			break
		result.remove_at(0)
	return result

func _cells_for_waypoints(waypoints: Array[Vector3], generated_world = null) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for waypoint in waypoints:
		var cell := _world_cell(waypoint, generated_world)
		if cells.is_empty() or cells[cells.size() - 1] != cell:
			cells.append(cell)
	return cells

func _cells_for_route_points(points: Array, generated_world = null) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var has_previous := false
	var previous_cell := INVALID_CELL
	for point_value in points:
		if not (point_value is Vector3):
			continue
		var sample_cell := _world_cell(point_value, generated_world)
		if not has_previous:
			cells.append(sample_cell)
			previous_cell = sample_cell
			has_previous = true
			continue
		var cursor := previous_cell
		while cursor != sample_cell:
			var delta := sample_cell - cursor
			var step := Vector2i(clampi(delta.x, -1, 1), clampi(delta.y, -1, 1))
			if step == Vector2i.ZERO:
				break
			cursor += step
			if cells.is_empty() or cells[cells.size() - 1] != cursor:
				cells.append(cursor)
		previous_cell = sample_cell
	return cells

func _route_actions_with_detected_doors(entry: Dictionary, intent: Dictionary, generated_world, sampled_cells: Array[Vector2i], existing_actions_value) -> Dictionary:
	var actions: Dictionary = (existing_actions_value as Dictionary).duplicate(true) if existing_actions_value is Dictionary else {}
	if sampled_cells.size() <= 1:
		return actions
	var source = generated_world if generated_world != null else world_adapter
	if source == null or not source.has_method("door_at"):
		return actions
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	var snapshot: Dictionary = {}
	if source.has_method("cached_static_tile_snapshot"):
		snapshot = source.cached_static_tile_snapshot(allow_outside, moving_home)
	elif source.has_method("build_snapshot"):
		snapshot = source.build_snapshot(entry, allow_outside, moving_home)
	if snapshot.is_empty():
		return actions
	var detected_actions := _generated_bridge_door_actions(entry, source, snapshot, sampled_cells)
	for key in detected_actions.keys():
		if not actions.has(key):
			actions[key] = detected_actions[key]
	return actions

func _preserve_route_action_cells(cells: Array[Vector2i], actions_value) -> Array[Vector2i]:
	var result: Array[Vector2i] = cells.duplicate()
	if not (actions_value is Dictionary):
		return result
	var actions: Dictionary = actions_value
	var keys := actions.keys()
	keys.sort()
	for action_key in keys:
		var action_value = actions[action_key]
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value
		if String(action.get("kind", "")) != "door":
			continue
		var cell_value = action.get("cell")
		if not (cell_value is Vector2i):
			continue
		var action_cell: Vector2i = cell_value
		if result.has(action_cell):
			continue
		var entry_cell := INVALID_CELL
		var entry_value = action.get("entryCell")
		if entry_value is Vector2i:
			entry_cell = entry_value
		var insert_index := _route_action_cell_insert_index(result, action_cell, entry_cell)
		result.insert(insert_index, action_cell)
	return result

func _route_action_cell_insert_index(cells: Array[Vector2i], action_cell: Vector2i, entry_cell: Vector2i) -> int:
	if cells.is_empty():
		return 0
	var best_index := 0
	var best_score := 2147483647
	for index in range(cells.size() + 1):
		var score := 0
		if index == 0:
			score += _cell_manhattan(entry_cell, action_cell) if entry_cell != INVALID_CELL else 0
		else:
			score += _cell_manhattan(cells[index - 1], action_cell)
		if index < cells.size():
			score += _cell_manhattan(action_cell, cells[index])
		if score < best_score:
			best_score = score
			best_index = index
	return best_index

func _cell_manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)

func _flat_delta(from: Vector3, to: Vector3) -> Vector2:
	return Vector2(to.x - from.x, to.z - from.z)

func _flat_distance(a: Vector3, b: Vector3) -> float:
	return _flat_delta(a, b).length()

func _world_cell(position: Vector3, generated_world = null) -> Vector2i:
	if generated_world != null and generated_world.has_method("world_cell"):
		return generated_world.world_cell(position)
	if world_adapter != null and world_adapter.has_method("world_cell"):
		return world_adapter.world_cell(position)
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func _cell_position(cell: Vector2i, generated_world = null) -> Vector3:
	var source = generated_world if generated_world != null else world_adapter
	if source != null and source.has_method("cell_position"):
		return source.cell_position(cell)
	return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)

func _nav_query_position(position: Vector3, cell: Vector2i, generated_world = null) -> Vector3:
	var result := position
	var source = generated_world if generated_world != null else world_adapter
	if source != null and source.has_method("cell_position"):
		var cell_position: Vector3 = source.cell_position(cell)
		result.y = cell_position.y
	elif main != null and main.has_method("surface_y_at_position"):
		result.y = float(main.call("surface_y_at_position", position)) + 0.04
	return result

func _target_cell_blocked(entry: Dictionary, target_cell: Vector2i, generated_world = null, allow_outside := false, moving_home := false) -> bool:
	var source = generated_world if generated_world != null else world_adapter
	if source == null or not source.has_method("build_snapshot"):
		return false
	if source.has_method("cell_is_standable_goal"):
		return not bool(source.cell_is_standable_goal(entry, target_cell, allow_outside, moving_home))
	if source.has_method("private_interior_blocks_entry") and source.private_interior_blocks_entry(entry, target_cell):
		return true
	if source.has_method("live_static_blocker_for_cell") and source.live_static_blocker_for_cell(target_cell) != null:
		return true
	var snapshot: Dictionary = source.cached_static_tile_snapshot(allow_outside, moving_home) if source.has_method("cached_static_tile_snapshot") else source.build_snapshot(entry, allow_outside, moving_home)
	if source.has_method("static_blocker") and source.static_blocker(snapshot, target_cell) != null:
		return true
	if source.has_method("prop_clearance_blocker") and source.prop_clearance_blocker(snapshot, target_cell) != null:
		return true
	return false

func _route_failure(status: String, reason: String, target_cell := INVALID_CELL, navmesh_route := {}) -> Dictionary:
	return {
		"ok": false,
		"status": status,
		"reason": reason,
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": INVALID_CELL,
		"snapshotRevision": "",
		"source": "navmesh",
		"legacyFallbackUsed": false,
		"navmeshRoute": navmesh_route
	}
