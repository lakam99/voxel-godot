extends RefCounted
class_name NpcRoutePlanner

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const HierarchicalRoutePlannerScript := preload("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")

const CELL := NpcConstantsScript.CELL_SIZE

var system
var main
var world
var coordinator

func setup(system_node, main_node, navigation_world) -> void:
	system = system_node
	main = main_node
	world = navigation_world
	coordinator = HierarchicalRoutePlannerScript.new()
	coordinator.setup(null)

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	if coordinator == null:
		coordinator = HierarchicalRoutePlannerScript.new()
	if world == null:
		return route_failure("blocked", "missing_world", intent.get("targetCell", Vector2i(999999, 999999)))
	var result: Dictionary = coordinator.plan_legacy_route(entry, intent, world)
	return result

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = []) -> float:
	if coordinator == null:
		coordinator = HierarchicalRoutePlannerScript.new()
	if world == null:
		return INF
	return coordinator.route_cost_for_legacy(entry, target, allow_outside, moving_home, arrival_radius, approach_cells, world)

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

func stats() -> Dictionary:
	return coordinator.stats() if coordinator != null and coordinator.has_method("stats") else {}
