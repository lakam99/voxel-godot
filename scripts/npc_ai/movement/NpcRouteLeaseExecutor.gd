extends RefCounted
class_name NpcRouteLeaseExecutor

const CharacterMotor3DScript := preload("res://scripts/npc_ai/motor/CharacterMotor3D.gd")
const CharacterMotorCommandScript := preload("res://scripts/npc_ai/contracts/CharacterMotorCommand.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const DEFAULT_WAYPOINT_RADIUS := 0.18
const STUCK_TIME_SECONDS := 0.75
const MIN_PROGRESS_DISTANCE := 0.002
const MIN_TARGET_PROGRESS_DISTANCE := 0.01

var route_authority = null
var terrain_provider = null
var system = null
var motor = null


func setup(authority, terrain_node = null, system_node = null) -> void:
	route_authority = authority
	terrain_provider = terrain_node
	system = system_node
	motor = CharacterMotor3DScript.new()


func execute(entry: Dictionary, request_id: String, lease: Dictionary, delta: float, options := {}) -> Dictionary:
	var rejection := _validate_execution_context(entry, request_id, lease, delta)
	if not bool(rejection.get("ok", false)):
		return rejection
	var body := entry.get("body") as CharacterBody3D
	var waypoints: Array = lease.get("waypoints", [])
	var waypoint_radius := float(options.get("waypointRadius", DEFAULT_WAYPOINT_RADIUS))
	var new_request := _reset_if_new_request(entry, request_id)
	if new_request:
		_mirror_lease_for_runtime_services(entry, lease, options)
	if not bool(entry.get("_v2LeaseExecutorMoving", false)):
		var moving: Dictionary = route_authority.begin_moving(request_id, "lease_executor_started") if route_authority != null else { "ok": true }
		if not bool(moving.get("ok", false)):
			return { "ok": false, "status": "rejected", "reason": String(moving.get("reason", "route_not_ready")), "authority": moving }
		entry["_v2LeaseExecutorMoving"] = true
	var index := clampi(int(entry.get("_v2LeaseExecutorWaypointIndex", 0)), 0, waypoints.size())
	index = _skip_reached_waypoints(entry, request_id, body, lease, waypoints, index, waypoint_radius)
	if index >= waypoints.size():
		if bool(options.get("deferArrivalReport", false)):
			return { "ok": true, "status": "route_complete", "reason": "awaiting_semantic_arrival", "moved": 0.0 }
		var arrived: Dictionary = route_authority.report_arrived(request_id, "lease_executor_arrived") if route_authority != null else { "ok": true }
		_clear_request(entry)
		return { "ok": true, "status": "arrived", "reason": "", "authority": arrived }
	if int(entry.get("_v2LeaseExecutorActiveSegment", -1)) != index:
		entry["_v2LeaseExecutorActiveSegment"] = index
		if route_authority != null:
			route_authority.report_segment_started(request_id, index, { "target": waypoints[index] })
	var door_result := _handle_door_action(entry, request_id, lease, index, body, delta, options)
	if not bool(door_result.get("ok", true)):
		return door_result
	var target: Vector3 = waypoints[index]
	var previous: Vector3 = body.global_position
	var offset := target - previous
	offset.y = 0.0
	var flat_distance := offset.length()
	_reset_progress_watch_if_target_changed(entry, "waypoint", index, target, flat_distance)
	if flat_distance <= waypoint_radius:
		_reset_progress_watch(entry)
		entry["_v2LeaseExecutorWaypointIndex"] = index + 1
		if route_authority != null:
			route_authority.report_segment_completed(request_id, index, { "position": body.global_position })
		return execute(entry, request_id, lease, delta, options)
	var profile = entry.get("motorProfile")
	if profile == null:
		profile = CharacterMotorProfileScript.npc_default()
		entry["motorProfile"] = profile
	var requested_speed := float(options.get("speed", profile.get("walk_speed")))
	var speed := minf(requested_speed, flat_distance / maxf(delta, 0.001))
	var command = CharacterMotorCommandScript.from_velocity(offset.normalized() * speed)
	command.grounded_hint = true
	command.terrain_grounded = true
	var motor_state = motor.apply(body, command, profile, delta, terrain_provider)
	var moved := Vector2(body.global_position.x - previous.x, body.global_position.z - previous.z).length()
	entry["_v2LeaseExecutorLastMove"] = moved
	if bool(motor_state.get("blocked")):
		_report_collision(entry, request_id, motor_state)
		return {
			"ok": false,
			"status": "waiting",
			"reason": "unexpected_collision",
			"moved": moved,
			"motor": motor_state.to_summary() if motor_state.has_method("to_summary") else {}
		}
	if moved <= MIN_PROGRESS_DISTANCE:
		var stuck_time := float(entry.get("_v2LeaseExecutorStuckTime", 0.0)) + delta
		entry["_v2LeaseExecutorStuckTime"] = stuck_time
		if stuck_time >= STUCK_TIME_SECONDS:
			if route_authority != null:
				route_authority.report_stuck(request_id, "stuck", { "stuckTime": stuck_time, "target": target })
			return { "ok": false, "status": "waiting", "reason": "stuck", "moved": moved }
	else:
		entry["_v2LeaseExecutorStuckTime"] = 0.0
	var no_progress := _update_progress_watch(entry, request_id, "waypoint", index, target, flat_distance, body.global_position, delta, moved, waypoint_radius)
	if not bool(no_progress.get("ok", true)):
		return no_progress
	if Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length() <= waypoint_radius:
		_reset_progress_watch(entry)
		entry["_v2LeaseExecutorWaypointIndex"] = index + 1
		if route_authority != null:
			route_authority.report_segment_completed(request_id, index, { "position": body.global_position })
		if index + 1 >= waypoints.size():
			if bool(options.get("deferArrivalReport", false)):
				return { "ok": true, "status": "route_complete", "reason": "awaiting_semantic_arrival", "moved": moved }
			var arrived_after_move: Dictionary = route_authority.report_arrived(request_id, "lease_executor_arrived") if route_authority != null else { "ok": true }
			_clear_request(entry)
			return { "ok": true, "status": "arrived", "reason": "", "moved": moved, "authority": arrived_after_move }
	return {
		"ok": true,
		"status": "moving",
		"reason": "",
		"moved": moved,
		"waypointIndex": int(entry.get("_v2LeaseExecutorWaypointIndex", index))
	}


func _validate_execution_context(entry: Dictionary, request_id: String, lease: Dictionary, delta: float) -> Dictionary:
	if request_id == "":
		return { "ok": false, "status": "rejected", "reason": "missing_request_id" }
	if delta <= 0.0:
		return { "ok": false, "status": "rejected", "reason": "invalid_delta" }
	if entry.get("body") as CharacterBody3D == null:
		return { "ok": false, "status": "rejected", "reason": "missing_body" }
	if lease.is_empty():
		return { "ok": false, "status": "rejected", "reason": "missing_route_lease" }
	if String(lease.get("state", "")) != "ready":
		return { "ok": false, "status": "rejected", "reason": "lease_not_ready" }
	var certificate: Dictionary = lease.get("probeCertificate", {}) if lease.get("probeCertificate", {}) is Dictionary else {}
	if not bool(certificate.get("ok", false)) or not bool(certificate.get("authoritative", false)):
		return { "ok": false, "status": "rejected", "reason": "lease_missing_probe_certificate" }
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	if waypoints.is_empty():
		return { "ok": false, "status": "rejected", "reason": "lease_missing_waypoints" }
	for waypoint in waypoints:
		if not (waypoint is Vector3):
			return { "ok": false, "status": "rejected", "reason": "lease_invalid_waypoint" }
	return { "ok": true }


func _reset_if_new_request(entry: Dictionary, request_id: String) -> bool:
	if String(entry.get("_v2LeaseExecutorRequestId", "")) == request_id:
		return false
	_clear_request(entry)
	entry["_v2LeaseExecutorRequestId"] = request_id
	entry["_v2LeaseExecutorWaypointIndex"] = 0
	entry["_v2LeaseExecutorActiveSegment"] = -1
	entry["_v2LeaseExecutorMoving"] = false
	entry["_v2LeaseExecutorStuckTime"] = 0.0
	return true


func _mirror_lease_for_runtime_services(entry: Dictionary, lease: Dictionary, options := {}) -> void:
	entry["routeActions"] = (lease.get("actions", {}) as Dictionary).duplicate(true) if lease.get("actions", {}) is Dictionary else {}
	entry["routeCells"] = (lease.get("cells", []) as Array).duplicate() if lease.get("cells", []) is Array else []
	entry["pathWaypoints"] = (lease.get("waypoints", []) as Array).duplicate() if lease.get("waypoints", []) is Array else []
	var target_cell = lease.get("targetCell", Vector2i(999999, 999999))
	if target_cell is Vector2i:
		entry["routeGoalCell"] = target_cell
	var semantic_kind := String(options.get("semanticKind", lease.get("semanticKind", "")))
	var intent_kind := String(options.get("intentKind", lease.get("intentKind", "")))
	var moving_home := bool(options.get("movingHome", semantic_kind == "home_interior" or intent_kind == "home"))
	entry["routeMovingHome"] = moving_home
	entry["movingHome"] = moving_home


func _clear_request(entry: Dictionary) -> void:
	entry.erase("_v2LeaseExecutorRequestId")
	entry.erase("_v2LeaseExecutorWaypointIndex")
	entry.erase("_v2LeaseExecutorActiveSegment")
	entry.erase("_v2LeaseExecutorMoving")
	entry.erase("_v2LeaseExecutorStuckTime")
	entry.erase("_v2LeaseExecutorLastMove")
	entry.erase("_v2LeaseExecutorProgressKey")
	entry.erase("_v2LeaseExecutorBestDistance")
	entry.erase("_v2LeaseExecutorLastDistance")
	entry.erase("_v2LeaseExecutorNoProgressTime")


func _skip_reached_waypoints(entry: Dictionary, request_id: String, body: CharacterBody3D, lease: Dictionary, waypoints: Array, index: int, waypoint_radius: float) -> int:
	var cursor := index
	while cursor < waypoints.size():
		var waypoint: Vector3 = waypoints[cursor]
		var reached := Vector2(body.global_position.x - waypoint.x, body.global_position.z - waypoint.z).length() <= waypoint_radius
		if not reached and cursor + 1 < waypoints.size() and _door_action_for_waypoint(lease, cursor).is_empty():
			reached = _actor_has_passed_waypoint(body.global_position, waypoint, waypoints[cursor + 1], waypoint_radius)
		if not reached:
			break
		if route_authority != null:
			route_authority.report_segment_completed(request_id, cursor, { "position": body.global_position, "alreadyReached": true })
		cursor += 1
	entry["_v2LeaseExecutorWaypointIndex"] = cursor
	return cursor


func _actor_has_passed_waypoint(position: Vector3, waypoint: Vector3, next_waypoint: Vector3, waypoint_radius: float) -> bool:
	var segment := Vector2(next_waypoint.x - waypoint.x, next_waypoint.z - waypoint.z)
	var segment_length := segment.length()
	if segment_length <= 0.001:
		return false
	var from_waypoint := Vector2(position.x - waypoint.x, position.z - waypoint.z)
	var direction := segment / segment_length
	var projected := from_waypoint.dot(direction)
	if projected <= waypoint_radius:
		return false
	var perpendicular := (from_waypoint - direction * projected).length()
	return perpendicular <= maxf(waypoint_radius * 2.5, NpcConstantsScript.CELL_SIZE * 0.35)


func _handle_door_action(entry: Dictionary, request_id: String, lease: Dictionary, waypoint_index: int, body: CharacterBody3D, delta: float, options := {}) -> Dictionary:
	var action := _door_action_for_waypoint(lease, waypoint_index)
	if action.is_empty():
		return { "ok": true, "status": "clear" }
	if not _door_action_is_local(action, body):
		return { "ok": true, "status": "approaching_door" }
	var door = action.get("door") as Node
	if door == null or not is_instance_valid(door):
		if route_authority != null:
			route_authority.report_door_wait(request_id, "missing_door_action_node", { "waypointIndex": waypoint_index })
		return { "ok": false, "status": "waiting", "reason": "missing_door_action_node", "moved": 0.0 }
	if system == null or not system.has_method("request_npc_door_traversal"):
		if route_authority != null:
			route_authority.report_door_wait(request_id, "missing_door_traversal_service", { "waypointIndex": waypoint_index })
		return { "ok": false, "status": "waiting", "reason": "missing_door_traversal_service", "moved": 0.0 }
	var traversal: Dictionary = system.call("request_npc_door_traversal", door, body, entry, action)
	if bool(traversal.get("ok", false)):
		entry["_v2LeaseExecutorDoorOpen"] = String(traversal.get("portalId", action.get("portalId", "")))
		return { "ok": true, "status": "door_open", "door": traversal }
	if route_authority != null:
		route_authority.report_door_wait(request_id, String(traversal.get("reason", "door_waiting")), traversal)
	var stage_position = traversal.get("stagePosition", null)
	if stage_position is Vector3 and bool(options.get("allowDoorStageMotion", true)):
		var stage_move := _move_toward_position(entry, request_id, body, stage_position, delta, options)
		stage_move["status"] = "waiting"
		if String(stage_move.get("reason", "")) != "stuck":
			stage_move["reason"] = String(traversal.get("reason", "door_stage_required"))
		stage_move["door"] = traversal
		return stage_move
	return {
		"ok": false,
		"status": "waiting",
		"reason": String(traversal.get("reason", "door_waiting")),
		"moved": 0.0,
		"door": traversal
	}


func _door_action_for_waypoint(lease: Dictionary, waypoint_index: int) -> Dictionary:
	var actions: Dictionary = lease.get("actions", {}) if lease.get("actions", {}) is Dictionary else {}
	if actions.is_empty():
		return {}
	var cells: Array = lease.get("cells", []) if lease.get("cells", []) is Array else []
	if waypoint_index >= 0 and waypoint_index < cells.size() and cells[waypoint_index] is Vector2i:
		var cell: Vector2i = cells[waypoint_index]
		var key := "%d,%d" % [cell.x, cell.y]
		var action_value = actions.get(key)
		if action_value is Dictionary:
			var action: Dictionary = action_value
			if String(action.get("kind", "")) == "door" and bool(action.get("enabled", true)):
				return action
	return {}


func _door_action_is_local(action: Dictionary, body: CharacterBody3D) -> bool:
	if body == null:
		return false
	var entry_position = action.get("entryPosition", null)
	if entry_position is Vector3:
		var entry_distance := Vector2(body.global_position.x - entry_position.x, body.global_position.z - entry_position.z).length()
		if entry_distance <= NpcConstantsScript.CELL_SIZE * 1.35:
			return true
	var door = action.get("door") as Node3D
	if door != null and is_instance_valid(door):
		var door_distance := Vector2(body.global_position.x - door.global_position.x, body.global_position.z - door.global_position.z).length()
		return door_distance <= NpcConstantsScript.CELL_SIZE * 1.8
	return false


func _move_toward_position(entry: Dictionary, request_id: String, body: CharacterBody3D, target: Vector3, delta: float, options := {}) -> Dictionary:
	var offset := target - body.global_position
	offset.y = 0.0
	var flat_distance := offset.length()
	_reset_progress_watch_if_target_changed(entry, "door_stage", -1, target, flat_distance)
	if flat_distance <= DEFAULT_WAYPOINT_RADIUS:
		_reset_progress_watch(entry)
		return { "ok": false, "status": "waiting", "reason": "door_stage_wait", "moved": 0.0 }
	var profile = entry.get("motorProfile")
	if profile == null:
		profile = CharacterMotorProfileScript.npc_default()
		entry["motorProfile"] = profile
	var requested_speed := float(options.get("speed", profile.get("walk_speed")))
	var speed := minf(requested_speed, flat_distance / maxf(delta, 0.001))
	var command = CharacterMotorCommandScript.from_velocity(offset.normalized() * speed)
	command.grounded_hint = true
	command.terrain_grounded = true
	var previous := body.global_position
	var motor_state = motor.apply(body, command, profile, delta, terrain_provider)
	var moved := Vector2(body.global_position.x - previous.x, body.global_position.z - previous.z).length()
	if bool(motor_state.get("blocked")):
		return { "ok": false, "status": "waiting", "reason": "door_stage_blocked", "moved": moved }
	var no_progress := _update_progress_watch(entry, request_id, "door_stage", -1, target, flat_distance, body.global_position, delta, moved, DEFAULT_WAYPOINT_RADIUS)
	if not bool(no_progress.get("ok", true)):
		no_progress["status"] = "waiting"
		return no_progress
	return { "ok": false, "status": "waiting", "reason": "door_stage_required", "moved": moved }


func _reset_progress_watch_if_target_changed(entry: Dictionary, kind: String, index: int, target: Vector3, distance: float) -> void:
	var key := "%s|%d|%.3f|%.3f|%.3f" % [kind, index, target.x, target.y, target.z]
	if String(entry.get("_v2LeaseExecutorProgressKey", "")) == key:
		return
	entry["_v2LeaseExecutorProgressKey"] = key
	entry["_v2LeaseExecutorBestDistance"] = distance
	entry["_v2LeaseExecutorLastDistance"] = distance
	entry["_v2LeaseExecutorNoProgressTime"] = 0.0


func _reset_progress_watch(entry: Dictionary) -> void:
	entry["_v2LeaseExecutorNoProgressTime"] = 0.0
	entry.erase("_v2LeaseExecutorBestDistance")
	entry.erase("_v2LeaseExecutorLastDistance")


func _update_progress_watch(entry: Dictionary, request_id: String, kind: String, index: int, target: Vector3, previous_distance: float, position: Vector3, delta: float, moved: float, waypoint_radius: float) -> Dictionary:
	var current_distance := Vector2(position.x - target.x, position.z - target.z).length()
	var best_distance := float(entry.get("_v2LeaseExecutorBestDistance", previous_distance))
	var progress_epsilon := maxf(MIN_TARGET_PROGRESS_DISTANCE, waypoint_radius * 0.05)
	if current_distance <= waypoint_radius or current_distance < best_distance - progress_epsilon:
		entry["_v2LeaseExecutorBestDistance"] = current_distance
		entry["_v2LeaseExecutorLastDistance"] = current_distance
		entry["_v2LeaseExecutorNoProgressTime"] = 0.0
		return { "ok": true }
	entry["_v2LeaseExecutorLastDistance"] = current_distance
	if moved <= MIN_PROGRESS_DISTANCE:
		return { "ok": true }
	var no_progress_time := float(entry.get("_v2LeaseExecutorNoProgressTime", 0.0)) + delta
	entry["_v2LeaseExecutorNoProgressTime"] = no_progress_time
	if no_progress_time < STUCK_TIME_SECONDS:
		return { "ok": true }
	var details := {
		"stuckKind": "no_target_progress",
		"targetKind": kind,
		"waypointIndex": index,
		"stuckTime": no_progress_time,
		"previousDistance": previous_distance,
		"currentDistance": current_distance,
		"bestDistance": best_distance,
		"moved": moved,
		"target": target
	}
	if route_authority != null:
		route_authority.report_stuck(request_id, "stuck", details)
	return {
		"ok": false,
		"status": "waiting",
		"reason": "stuck",
		"moved": moved,
		"details": details
	}


func _report_collision(entry: Dictionary, request_id: String, motor_state) -> void:
	var details := {}
	if motor_state != null:
		details = {
			"blockedContactName": String(motor_state.get("blocked_contact_name")),
			"blockedContactKind": String(motor_state.get("blocked_contact_kind")),
			"blockedContactType": String(motor_state.get("blocked_contact_type")),
			"blockedContactCategory": String(motor_state.get("blocked_contact_category")),
			"slideCollisionCount": int(motor_state.get("slide_collision_count"))
		}
	if route_authority != null:
		route_authority.report_unexpected_collision(request_id, "unexpected_collision", details)
