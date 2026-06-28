extends RefCounted
class_name NavmeshRoutePlanner

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const INVALID_CELL := Vector2i(999999, 999999)

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
	if navmesh_world == null:
		return _route_failure("blocked", "missing_navmesh_world", target_cell)
	var body := entry.get("body") as Node3D
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	var route: Dictionary = navmesh_world.query_route(start, target, {
		"actorId": String(entry.get("id", "")),
		"kind": String(intent.get("kind", "move")),
		"allowOutside": bool(intent.get("allowOutside", false)),
		"movingHome": bool(intent.get("movingHome", false)),
		"arrivalRadius": float(intent.get("arrivalRadius", CELL * 0.75)),
		"targetCell": target_cell
	})
	last_stats = navmesh_world.stats() if navmesh_world.has_method("stats") else {}
	last_stats["lastRouteSource"] = String(route.get("source", "navmesh"))
	last_stats["legacyFallbackUsed"] = false
	if not bool(route.get("ok", false)):
		return _route_failure(String(route.get("status", "blocked")), String(route.get("reason", "no_route")), target_cell, route)
	var waypoints: Array = _path_waypoints(route.get("path", []), start, target)
	var cells: Array[Vector2i] = _cells_for_waypoints(waypoints, generated_world)
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
	var route: Dictionary = navmesh_world.query_route(start, target, {
		"actorId": String(entry.get("id", "")),
		"kind": "cost",
		"allowOutside": allow_outside,
		"movingHome": moving_home,
		"arrivalRadius": arrival_radius,
		"targetCell": _world_cell(target, generated_world)
	})
	if not bool(route.get("ok", false)):
		return INF
	return float(route.get("distance", INF))

func stats() -> Dictionary:
	return last_stats.duplicate(true)

func _path_waypoints(path_value, start: Vector3, target: Vector3) -> Array[Vector3]:
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
	if result.is_empty() and start.distance_to(target) > CELL * 0.08:
		result.append(target)
	if not result.is_empty() and result[result.size() - 1].distance_to(target) > CELL * 0.12:
		result.append(target)
	return result

func _cells_for_waypoints(waypoints: Array[Vector3], generated_world = null) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for waypoint in waypoints:
		var cell := _world_cell(waypoint, generated_world)
		if cells.is_empty() or cells[cells.size() - 1] != cell:
			cells.append(cell)
	return cells

func _world_cell(position: Vector3, generated_world = null) -> Vector2i:
	if generated_world != null and generated_world.has_method("world_cell"):
		return generated_world.world_cell(position)
	if world_adapter != null and world_adapter.has_method("world_cell"):
		return world_adapter.world_cell(position)
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

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
