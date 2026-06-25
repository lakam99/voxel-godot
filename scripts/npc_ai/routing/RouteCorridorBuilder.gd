extends RefCounted
class_name RouteCorridorBuilder

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const RouteCorridorScript := preload("res://scripts/npc_ai/contracts/RouteCorridor.gd")
const RouteStepScript := preload("res://scripts/npc_ai/contracts/RouteStep.gd")
const TraversalActionScript := preload("res://scripts/npc_ai/contracts/TraversalAction.gd")

func build(graph: Dictionary, path: Array, edge_records: Array, breakdowns: Array, request, smooth := true):
	var corridor = RouteCorridorScript.new()
	corridor.arrival_contract = String(request.get("goal_kind")) if request != null else ""
	if path.size() <= 1:
		return corridor
	for i in range(1, path.size()):
		var from_key := String(path[i - 1])
		var to_key := String(path[i])
		var edge_record: Dictionary = edge_records[i - 1] if i - 1 < edge_records.size() else {}
		var to_span = (graph.get("nodes", {}) as Dictionary).get(to_key)
		if to_span == null:
			continue
		var edge = edge_record.get("edge")
		var kind: StringName = edge.get("traversal_kind") if edge != null else NpcEnumsScript.TRAVERSAL_KIND_WALK
		var breakdown: Dictionary = breakdowns[i - 1] if i - 1 < breakdowns.size() else {}
		var step = RouteStepScript.make(from_key, to_key, to_span.get("world_position"), to_span.get("cell"), kind, float(breakdown.get("total", edge_record.get("baseCost", 1.0))))
		step.cost_breakdown = breakdown.duplicate(true)
		step.semantic_region_ids = to_span.get("semantic_region_ids").duplicate()
		step.portal_id = String(edge.get("portal_id")) if edge != null else String(edge_record.get("portalId", ""))
		step.metadata = edge.get("metadata").duplicate(true) if edge != null else edge_record.get("metadata", {}).duplicate(true)
		if kind in [NpcEnumsScript.TRAVERSAL_KIND_DOOR, NpcEnumsScript.TRAVERSAL_KIND_SPECIAL] or bool(edge_record.get("bottleneck", false)):
			step.bottleneck = true
			step.reservation_required = true
		if kind == NpcEnumsScript.TRAVERSAL_KIND_DOOR:
			var action = TraversalActionScript.make(&"door", from_key, to_key, step.portal_id, float(breakdown.get("doorCost", 0.0)))
			action.metadata = step.metadata.duplicate(true)
			step.action_id = action.action_id
			corridor.add_action(action)
		corridor.add_step(step)
		corridor.add_dependency("tiles", String(edge_record.get("fromTile", "")))
		corridor.add_dependency("tiles", String(edge_record.get("toTile", "")))
		corridor.add_dependency("edges", "%s->%s" % [from_key, to_key])
	if smooth:
		_smooth_waypoints(corridor)
	return corridor

func _smooth_waypoints(corridor) -> void:
	if corridor.steps.size() <= 2:
		corridor.smoothed = true
		return
	var smoothed: Array[Vector3] = []
	var previous_direction := Vector3.ZERO
	for i in range(corridor.steps.size()):
		var step = corridor.steps[i]
		var position: Vector3 = step.get("world_position")
		if i == 0 or i == corridor.steps.size() - 1 or String(step.get("action_id")) != "":
			smoothed.append(position)
			if i > 0:
				previous_direction = _flat_direction(corridor.steps[i - 1].get("world_position"), position)
			continue
		var next_position: Vector3 = corridor.steps[i + 1].get("world_position")
		var direction := _flat_direction(position, next_position)
		if previous_direction == Vector3.ZERO or direction != previous_direction:
			smoothed.append(position)
		else:
			step.set("reservation_required", bool(step.get("reservation_required")))
		previous_direction = direction
	corridor.waypoints = smoothed
	corridor.smoothed = true

func _flat_direction(a: Vector3, b: Vector3) -> Vector3:
	var delta := b - a
	delta.y = 0.0
	if delta.length_squared() < 0.001:
		return Vector3.ZERO
	delta = delta.normalized()
	return Vector3(signf(delta.x), 0.0, signf(delta.z))
