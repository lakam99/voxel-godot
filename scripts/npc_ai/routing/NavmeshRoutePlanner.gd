extends RefCounted
class_name NavmeshRoutePlanner

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const INVALID_CELL := Vector2i(999999, 999999)
const INITIAL_HAIRPIN_MAX_DISTANCE := CELL * 1.25
const INITIAL_HAIRPIN_TARGET_MARGIN := CELL * 0.12

var navmesh_world = null
var system = null
var main = null
var world_adapter = null
var last_stats := {}

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
	var blocked_target := _target_cell_blocked(entry, target_cell, generated_world, bool(intent.get("allowOutside", false)), bool(intent.get("movingHome", false)))
	if blocked_target:
		return _route_failure("blocked", "target_blocked", target_cell, { "targetCell": target_cell })
	var query_api := _runtime_query_api(intent)
	var forbidden_private_door_ids := _forbidden_private_door_portal_ids(entry, generated_world)
	var route: Dictionary = navmesh_world.query_route(query_start_position, query_target, {
		"actorId": String(entry.get("id", "")),
		"kind": String(intent.get("kind", "move")),
		"allowOutside": bool(intent.get("allowOutside", false)),
		"movingHome": bool(intent.get("movingHome", false)),
		"arrivalRadius": float(intent.get("arrivalRadius", CELL * 0.75)),
		"targetCell": target_cell,
		"maxSnapDistance": maxf(float(intent.get("arrivalRadius", CELL * 0.75)), CELL * 0.95),
		"queryApi": query_api,
		"forbiddenDoorPortalIds": forbidden_private_door_ids
	})
	last_stats = navmesh_world.stats() if navmesh_world.has_method("stats") else {}
	last_stats["lastRouteSource"] = String(route.get("source", "navmesh"))
	last_stats["legacyFallbackUsed"] = false
	if not bool(route.get("ok", false)):
		return _route_failure(String(route.get("status", "blocked")), String(route.get("reason", "no_route")), target_cell, route)
	var query_start: Vector3 = route.get("startPosition", start)
	var route_target: Vector3 = route.get("targetPosition", query_target)
	var waypoints: Array = _path_waypoints(route.get("path", []), query_start, route_target, generated_world, entry, bool(intent.get("allowOutside", false)), bool(intent.get("movingHome", false)))
	var cells: Array[Vector2i] = _cells_for_waypoints(waypoints, generated_world)
	cells = _preserve_route_action_cells(cells, route.get("actions", {}))
	var status := "arrived" if waypoints.is_empty() else "routed"
	return {
		"ok": true,
		"status": status,
		"reason": "",
		"cells": cells,
		"waypoints": waypoints,
		"actions": (route.get("actions", {}) as Dictionary).duplicate(true),
		"targetCell": target_cell,
		"fallbackCell": cells[cells.size() - 1] if not cells.is_empty() else target_cell,
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
		return INF
	return float(route.get("distance", INF))

func stats() -> Dictionary:
	return last_stats.duplicate(true)

func _runtime_query_api(intent: Dictionary) -> String:
	if bool(intent.get("movingHome", false)) or String(intent.get("kind", "")) == "scripted":
		return "query_path"
	return "map_get_path"

func _forbidden_private_door_portal_ids(entry: Dictionary, generated_world = null) -> Array[String]:
	var source = generated_world if generated_world != null else world_adapter
	if source == null or not source.has_method("forbidden_private_door_portal_ids_for_entry"):
		return []
	return source.forbidden_private_door_portal_ids_for_entry(entry)

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
	if moving_home and source.has_method("cell_inside_entry_home") and source.cell_inside_entry_home(entry, target_cell):
		return false
	var snapshot: Dictionary = source.build_snapshot(entry, allow_outside, moving_home)
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
