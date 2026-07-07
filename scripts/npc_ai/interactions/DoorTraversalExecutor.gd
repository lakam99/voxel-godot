extends RefCounted
class_name DoorTraversalExecutor

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const BottleneckClassifierScript := preload("res://scripts/npc_ai/traffic/BottleneckClassifier.gd")
const SafeIntervalPlannerScript := preload("res://scripts/npc_ai/traffic/SafeIntervalPlanner.gd")
const WaitForGraphScript := preload("res://scripts/npc_ai/traffic/WaitForGraph.gd")
const TrafficPriorityPolicyScript := preload("res://scripts/npc_ai/traffic/TrafficPriorityPolicy.gd")
const TrafficReservationServiceScript := preload("res://scripts/npc_ai/traffic/TrafficReservationService.gd")

var door_portals = null
var traffic_reservations = null
var bottleneck_classifier = null
var traffic_priority_policy = null
var wait_graph = null
var active_crossings := {}
var metrics := {
	"requests": 0,
	"granted": 0,
	"waiting": 0,
	"released": 0,
	"trafficDenied": 0,
	"trafficContinuity": 0
}

func setup(door_portal_service, traffic_service = null, classifier = null, priority_policy = null, graph = null) -> void:
	door_portals = door_portal_service
	bottleneck_classifier = classifier if classifier != null else BottleneckClassifierScript.new()
	traffic_priority_policy = priority_policy if priority_policy != null else TrafficPriorityPolicyScript.new()
	wait_graph = graph if graph != null else WaitForGraphScript.new()
	if traffic_service != null:
		traffic_reservations = traffic_service
	else:
		traffic_reservations = TrafficReservationServiceScript.new()
		traffic_reservations.setup(bottleneck_classifier, SafeIntervalPlannerScript.new(), wait_graph, traffic_priority_policy)

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
	if portal != null:
		direction = _normalize_direction_for_portal(portal, direction, actor, entry)
	var active_key := _active_key(portal_id, actor_id)
	var active: Dictionary = active_crossings.get(active_key, {})
	if active.is_empty():
		var stage_check := _portal_stage_check(portal, actor, actor_id, direction)
		if not bool(stage_check.get("ok", true)):
			metrics["waiting"] = int(metrics.get("waiting", 0)) + 1
			var stage_wait := {
				"ok": false,
				"status": "waiting",
				"reason": String(stage_check.get("reason", "door_stage_required")),
				"portalId": portal_id,
				"direction": direction,
				"stagePosition": stage_check.get("stagePosition", Vector3.ZERO),
				"stageCheck": stage_check
			}
			return stage_wait
	var traffic_result := _request_traffic(portal, actor, actor_id, direction, entry, action, active)
	if not bool(traffic_result.get("ok", false)):
		if portal != null:
			portal.queue(actor_id, direction)
		metrics["waiting"] = int(metrics.get("waiting", 0)) + 1
		metrics["trafficDenied"] = int(metrics.get("trafficDenied", 0)) + 1
		var waiting := {
			"ok": false,
			"status": "waiting",
			"reason": "door_reserved",
			"trafficReason": String(traffic_result.get("reason", "traffic_wait")),
			"portalId": portal_id,
			"groupId": String(traffic_result.get("groupId", ""))
		}
		if traffic_result.has("stagePosition"):
			waiting["stagePosition"] = traffic_result.get("stagePosition")
		if traffic_result.has("cycleResolution"):
			waiting["cycleResolution"] = traffic_result.get("cycleResolution")
			waiting["reason"] = "door_retreat"
		return waiting
	var result = door_portals.hold_open(door, actor, "npc", {
		"portalId": portal_id,
		"actors": [actor],
		"authorized": bool(entry.get("canUseLockedDoors", false)),
		"direction": direction,
		"actionCell": _cell_summary(action.get("cell"))
	})
	if result == null or result.status != NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED:
		if traffic_reservations != null and String(traffic_result.get("groupId", "")) != "":
			traffic_reservations.release_group(String(traffic_result.get("groupId", "")), "door_open_failed")
		metrics["waiting"] = int(metrics.get("waiting", 0)) + 1
		return { "ok": false, "status": "waiting", "reason": String(result.reason) if result != null else "door_failed", "portalId": portal_id }
	active_crossings[active_key] = {
		"portalId": portal_id,
		"actorId": actor_id,
		"direction": direction,
		"actor": actor,
		"groupId": String(traffic_result.get("groupId", "")),
		"reservationIds": traffic_result.get("reservationIds", [])
	}
	if entry is Dictionary:
		entry["activeDoorPortalId"] = portal_id
		entry["activeDoorActorId"] = actor_id
		entry["activeDoorDirection"] = direction
		entry["activeDoorTrafficGroupId"] = String(traffic_result.get("groupId", ""))
	metrics["granted"] = int(metrics.get("granted", 0)) + 1
	if bool(traffic_result.get("activeContinuity", false)):
		metrics["trafficContinuity"] = int(metrics.get("trafficContinuity", 0)) + 1
	return { "ok": true, "status": "open", "reason": "", "portalId": portal_id, "result": result.to_summary() }

func release_actor(actor_or_id, schedule_close := true) -> void:
	if door_portals == null:
		return
	var actor_id := ""
	if actor_or_id is Node:
		actor_id = _actor_id(actor_or_id, {})
	else:
		actor_id = String(actor_or_id)
	for active_key in active_crossings.keys().duplicate():
		var active: Dictionary = active_crossings[active_key]
		if String(active.get("actorId", "")) == actor_id:
			active_crossings.erase(active_key)
			var portal_id := String(active.get("portalId", ""))
			if traffic_reservations != null and String(active.get("groupId", "")) != "":
				traffic_reservations.release_group(String(active.get("groupId", "")), "door_crossing_released")
			door_portals.release_actor(portal_id, actor_id, schedule_close)
			metrics["released"] = int(metrics.get("released", 0)) + 1

func cancel_actor(actor_or_id) -> void:
	var actor_id := ""
	if actor_or_id is Node:
		actor_id = _actor_id(actor_or_id, {})
	else:
		actor_id = String(actor_or_id)
	if traffic_reservations != null:
		traffic_reservations.cancel_owner(actor_id)
	release_actor(actor_or_id, true)

func stats() -> Dictionary:
	return {
		"activeCrossings": active_crossings.size(),
		"metrics": metrics.duplicate(),
		"traffic": traffic_reservations.stats() if traffic_reservations != null else {}
	}

func _request_traffic(portal, actor: Node, actor_id: String, direction: String, entry: Dictionary, action: Dictionary, active: Dictionary) -> Dictionary:
	if traffic_reservations == null or portal == null:
		return { "ok": true, "status": "granted", "reason": "traffic_unavailable" }
	var priority_class: String = traffic_priority_policy.priority_class_for(entry, {
		"kind": "door",
		"movingHome": bool(entry.get("movingHome", entry.get("routeMovingHome", false)))
	}) if traffic_priority_policy != null else "idle"
	var current_position := Vector3.ZERO
	if actor is Node3D and is_instance_valid(actor):
		current_position = (actor as Node3D).global_position
	var owner_generation := int(entry.get("trafficOwnerGeneration", entry.get("routeGeneration", entry.get("cancellation_generation", 1))))
	if owner_generation <= 0:
		owner_generation = 1
		entry["trafficOwnerGeneration"] = owner_generation
	var group_id := String(active.get("groupId", ""))
	return traffic_reservations.request_portal_crossing(portal, actor_id, direction, {
		"ownerGeneration": owner_generation,
		"actionGeneration": int(entry.get("trafficActionGeneration", entry.get("actionGeneration", 0))),
		"groupId": group_id,
		"priority": int(entry.get("routePriority", action.get("priority", 0))),
		"priorityClass": priority_class,
		"currentPosition": current_position,
		"activeCrossing": not active.is_empty() and String(active.get("actorId", "")) == actor_id,
		"metadata": {
			"kind": "portal",
			"doorName": String(actor.name) if actor != null else "",
			"actionCell": _cell_summary(action.get("cell"))
		}
	})

func _active_key(portal_id: String, actor_id: String) -> String:
	return "%s:%s" % [portal_id, actor_id]

func _actor_id(actor: Node, entry: Dictionary) -> String:
	if entry is Dictionary and String(entry.get("id", "")) != "":
		return String(entry.get("id"))
	if actor != null and is_instance_valid(actor):
		if actor.has_meta("npc_stable_id"):
			return String(actor.get_meta("npc_stable_id"))
		return "%s:%d" % [actor.name, actor.get_instance_id()]
	return "npc"

func _direction_for_action(action: Dictionary, entry: Dictionary) -> String:
	var explicit_direction := String(action.get("direction", ""))
	if explicit_direction != "":
		return explicit_direction
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

func _normalize_direction_for_portal(portal, direction: String, actor: Node, entry: Dictionary) -> String:
	if portal == null:
		return direction
	var axis := String(portal.get("crossing_axis"))
	if axis == "x":
		if direction == "x+" or direction == "x-":
			return direction
		return _direction_for_actor_goal(portal, actor, entry)
	if axis == "z":
		if direction == "z+" or direction == "z-":
			return direction
		return _direction_for_actor_goal(portal, actor, entry)
	return direction

func _portal_stage_check(portal, actor: Node, actor_id: String, direction: String) -> Dictionary:
	if portal == null or not (actor is Node3D) or not is_instance_valid(actor):
		return { "ok": true }
	var actor_body := actor as Node3D
	if portal.has_method("has_any_occupancy") and bool(portal.has_any_occupancy([actor_body])):
		return { "ok": true, "reason": "already_in_portal_volume" }
	var center: Vector3 = portal.get("threshold_bounds").position + portal.get("threshold_bounds").size * 0.5
	var threshold: AABB = portal.get("threshold_bounds")
	var clearance: AABB = portal.get("clearance_bounds")
	var axis := String(portal.get("crossing_axis"))
	var radius := NpcConstantsScript.DEFAULT_NPC_RADIUS
	var lateral_delta := 0.0
	var lateral_limit := 0.0
	var axis_delta := 0.0
	var axis_limit := 0.0
	var wrong_side := false
	if axis == "x":
		lateral_delta = absf(actor_body.global_position.z - center.z)
		lateral_limit = threshold.size.z * 0.5 + radius * 1.25
		axis_delta = absf(actor_body.global_position.x - center.x)
		axis_limit = clearance.size.x * 0.5 + NpcConstantsScript.CELL_SIZE * 1.85
		wrong_side = (direction == "x+" and actor_body.global_position.x > center.x + radius) or (direction == "x-" and actor_body.global_position.x < center.x - radius)
	elif axis == "z":
		lateral_delta = absf(actor_body.global_position.x - center.x)
		lateral_limit = threshold.size.x * 0.5 + radius * 1.25
		axis_delta = absf(actor_body.global_position.z - center.z)
		axis_limit = clearance.size.z * 0.5 + NpcConstantsScript.CELL_SIZE * 1.85
		wrong_side = (direction == "z+" and actor_body.global_position.z > center.z + radius) or (direction == "z-" and actor_body.global_position.z < center.z - radius)
	else:
		return { "ok": true, "reason": "unknown_axis" }
	if lateral_delta <= lateral_limit and axis_delta <= axis_limit and not wrong_side:
		return {
			"ok": true,
			"reason": "staged",
			"lateralDelta": lateral_delta,
			"lateralLimit": lateral_limit,
			"axisDelta": axis_delta,
			"axisLimit": axis_limit
		}
	var stage_position := _stage_position_for_waiting_actor(portal, actor_body)
	if bottleneck_classifier != null:
		stage_position = bottleneck_classifier.stage_position_for_portal(portal, actor_id, direction, actor_body.global_position)
	return {
		"ok": false,
		"reason": "door_stage_required",
		"stagePosition": stage_position,
		"direction": direction,
		"lateralDelta": lateral_delta,
		"lateralLimit": lateral_limit,
		"axisDelta": axis_delta,
		"axisLimit": axis_limit,
		"wrongSide": wrong_side
	}

func _stage_position_for_waiting_actor(portal, actor: Node) -> Vector3:
	if bottleneck_classifier != null:
		return bottleneck_classifier.stage_position_for_portal(portal, _actor_id(actor, {}), "unknown", (actor as Node3D).global_position if actor is Node3D else Vector3.ZERO)
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

func _cell_summary(value) -> Array:
	if value is Vector2i:
		return [value.x, value.y]
	return []
