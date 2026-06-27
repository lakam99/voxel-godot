extends RefCounted
class_name NpcRouteCoordinatorAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const HierarchicalRoutePlannerScript := preload("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")
const IncrementalRouteRepairScript := preload("res://scripts/npc_ai/routing/IncrementalRouteRepair.gd")

const CELL := NpcConstantsScript.CELL_SIZE

var system
var main
var world
var coordinator
var repair_service
var active_route_entries := {}

func setup(system_node, main_node, navigation_world) -> void:
	system = system_node
	main = main_node
	world = navigation_world
	coordinator = HierarchicalRoutePlannerScript.new()
	coordinator.setup(null)
	repair_service = IncrementalRouteRepairScript.new()
	repair_service.setup(coordinator)

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	if coordinator == null:
		coordinator = HierarchicalRoutePlannerScript.new()
	if repair_service == null:
		repair_service = IncrementalRouteRepairScript.new()
		repair_service.setup(coordinator)
	if world == null:
		return route_failure("blocked", "missing_world", intent.get("targetCell", Vector2i(999999, 999999)))
	var result: Dictionary = coordinator.plan_runtime_route(entry, intent, world)
	_register_repair_route(entry, result)
	return result

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = []) -> float:
	if coordinator == null:
		coordinator = HierarchicalRoutePlannerScript.new()
	if world == null:
		return INF
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
	if repair_service != null:
		result["repair"] = repair_service.stats()
	return result

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
	repair_service.register_route(route_id, graph, start_key, goal_keys, typed_result.get("repair_request"), typed_result.get("corridor"))
	active_route_entries[route_id] = entry

func _apply_repair_response(route_id: String, response: Dictionary) -> void:
	var entry: Dictionary = active_route_entries.get(route_id, {})
	if entry.is_empty():
		return
	var status: StringName = response.get("status")
	var reason: StringName = response.get("reason")
	if status == NpcEnumsScript.REPAIR_STATUS_UNCHANGED:
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
