extends RefCounted
class_name DoorTraversalExecutor

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var door_portals = null
var active_crossings := {}
var metrics := {
	"requests": 0,
	"granted": 0,
	"waiting": 0,
	"released": 0
}

func setup(door_portal_service) -> void:
	door_portals = door_portal_service

func request_crossing(door: Node, actor: Node, entry: Dictionary = {}, action: Dictionary = {}) -> Dictionary:
	metrics["requests"] = int(metrics.get("requests", 0)) + 1
	if door_portals == null or door == null:
		return { "ok": false, "status": "failed", "reason": "missing_door_service" }
	var portal_id: String = door_portals.register_door(door, action)
	var portal = door_portals.portals.get(portal_id)
	var actor_id := _actor_id(actor, entry)
	var direction := _direction_for_action(action, entry)
	if direction == "unknown" and portal != null:
		direction = _direction_for_actor_goal(portal, actor, entry)
	var active: Dictionary = active_crossings.get(portal_id, {})
	if not active.is_empty() and String(active.get("actorId", "")) != actor_id and String(active.get("direction", "")) != direction:
		var stage_position := Vector3.ZERO
		var has_stage := false
		if portal != null:
			portal.queue(actor_id, direction)
			stage_position = _stage_position_for_waiting_actor(portal, actor)
			has_stage = true
		metrics["waiting"] = int(metrics.get("waiting", 0)) + 1
		var waiting := { "ok": false, "status": "waiting", "reason": "door_reserved", "portalId": portal_id }
		if has_stage:
			waiting["stagePosition"] = stage_position
		return waiting
	var result = door_portals.hold_open(door, actor, "npc", { "portalId": portal_id, "actors": [actor], "authorized": bool(entry.get("canUseLockedDoors", false)) })
	if result == null or result.status != NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED:
		metrics["waiting"] = int(metrics.get("waiting", 0)) + 1
		return { "ok": false, "status": "waiting", "reason": String(result.reason) if result != null else "door_failed", "portalId": portal_id }
	active_crossings[portal_id] = {
		"actorId": actor_id,
		"direction": direction,
		"actor": actor
	}
	if entry is Dictionary:
		entry["activeDoorPortalId"] = portal_id
		entry["activeDoorActorId"] = actor_id
		entry["activeDoorDirection"] = direction
	metrics["granted"] = int(metrics.get("granted", 0)) + 1
	return { "ok": true, "status": "open", "reason": "", "portalId": portal_id, "result": result.to_summary() }

func release_actor(actor_or_id, schedule_close := true) -> void:
	if door_portals == null:
		return
	var actor_id := String(actor_or_id)
	if actor_or_id is Node:
		actor_id = _actor_id(actor_or_id, {})
	for portal_id in active_crossings.keys().duplicate():
		var active: Dictionary = active_crossings[portal_id]
		if String(active.get("actorId", "")) == actor_id:
			active_crossings.erase(portal_id)
			door_portals.release_actor(portal_id, actor_id, schedule_close)
			metrics["released"] = int(metrics.get("released", 0)) + 1

func cancel_actor(actor_or_id) -> void:
	release_actor(actor_or_id, true)

func stats() -> Dictionary:
	return {
		"activeCrossings": active_crossings.size(),
		"metrics": metrics.duplicate()
	}

func _actor_id(actor: Node, entry: Dictionary) -> String:
	if entry is Dictionary and String(entry.get("id", "")) != "":
		return String(entry.get("id"))
	if actor != null and is_instance_valid(actor):
		if actor.has_meta("npc_stable_id"):
			return String(actor.get_meta("npc_stable_id"))
		return "%s:%d" % [actor.name, actor.get_instance_id()]
	return "npc"

func _direction_for_action(action: Dictionary, entry: Dictionary) -> String:
	var goal_cell: Vector2i = entry.get("routeGoalCell", Vector2i.ZERO)
	var cell_value = action.get("cell")
	if cell_value is Vector2i:
		var delta := goal_cell - (cell_value as Vector2i)
		if abs(delta.x) >= abs(delta.y) and delta.x != 0:
			return "x+" if delta.x > 0 else "x-"
		if delta.y != 0:
			return "z+" if delta.y > 0 else "z-"
	return "unknown"

func _direction_for_actor_goal(portal, actor: Node, entry: Dictionary) -> String:
	var center: Vector3 = portal.threshold_bounds.position + portal.threshold_bounds.size * 0.5
	var goal_cell: Vector2i = entry.get("routeGoalCell", Vector2i.ZERO)
	var goal_x := float(goal_cell.x) * NpcConstantsScript.CELL_SIZE
	var goal_z := float(goal_cell.y) * NpcConstantsScript.CELL_SIZE
	if String(portal.crossing_axis) == "x":
		if absf(goal_x - center.x) > NpcConstantsScript.CELL_SIZE * 0.1:
			return "x+" if goal_x > center.x else "x-"
	elif String(portal.crossing_axis) == "z":
		if absf(goal_z - center.z) > NpcConstantsScript.CELL_SIZE * 0.1:
			return "z+" if goal_z > center.z else "z-"
	if actor is Node3D and is_instance_valid(actor):
		var position: Vector3 = (actor as Node3D).global_position
		if String(portal.crossing_axis) == "x":
			return "x+" if position.x <= center.x else "x-"
		return "z+" if position.z <= center.z else "z-"
	return "unknown"

func _stage_position_for_waiting_actor(portal, actor: Node) -> Vector3:
	var center: Vector3 = portal.threshold_bounds.position + portal.threshold_bounds.size * 0.5
	var current: Vector3 = center
	if actor is Node3D and is_instance_valid(actor):
		current = (actor as Node3D).global_position
	var clearance_center: Vector3 = portal.clearance_bounds.position + portal.clearance_bounds.size * 0.5
	var stage_distance := NpcConstantsScript.CELL_SIZE * 1.2
	var actor_key := _actor_id(actor, {})
	var lateral_sign := 1.0 if (hash(actor_key) & 1) == 0 else -1.0
	var lateral_offset := NpcConstantsScript.CELL_SIZE * 1.35
	if String(portal.crossing_axis) == "x":
		stage_distance = portal.clearance_bounds.size.x * 0.5 + NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.CELL_SIZE * 0.55
		return Vector3(
			clearance_center.x - stage_distance if current.x <= center.x else clearance_center.x + stage_distance,
			current.y,
			clearance_center.z + lateral_sign * lateral_offset
		)
	stage_distance = portal.clearance_bounds.size.z * 0.5 + NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.CELL_SIZE * 0.55
	return Vector3(
		clearance_center.x + lateral_sign * lateral_offset,
		current.y,
		clearance_center.z - stage_distance if current.z <= center.z else clearance_center.z + stage_distance
	)
