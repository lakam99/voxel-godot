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
const TRANSITION_STAGE_RADIUS := NpcConstantsScript.NAVIGATION_TRANSITION_PHASE_RADIUS
const TRANSITION_ACTIVATION_DISTANCE := NpcConstantsScript.CELL_SIZE * 1.25

var route_authority = null
var terrain_provider = null
var system = null
var motor = null
var crowd_velocity_service = null


func setup(authority, terrain_node = null, system_node = null, crowd_service = null) -> void:
	route_authority = authority
	terrain_provider = terrain_node
	system = system_node
	motor = CharacterMotor3DScript.new()
	crowd_velocity_service = crowd_service


func cancel_entry(entry: Dictionary) -> void:
	entry["_v2LeaseExecutorGeneration"] = int(entry.get("_v2LeaseExecutorGeneration", 0)) + 1
	entry.erase("_v2LeaseExecutorPendingAvoidance")
	_release_surface_transition(entry, "route_cancelled")
	_clear_request(entry)
	var body := entry.get("body") as CharacterBody3D
	if body != null and is_instance_valid(body):
		body.set_meta("npc_requested_velocity", Vector3.ZERO)
		body.set_meta("npc_avoidance_committed_velocity", Vector3.ZERO)
		body.set_meta("npc_applied_velocity", Vector3.ZERO)
	if crowd_velocity_service != null and crowd_velocity_service.has_method("disable_actor"):
		crowd_velocity_service.disable_actor(String(entry.get("id", body.name if body != null else "")))


func execute(entry: Dictionary, request_id: String, lease: Dictionary, delta: float, options := {}) -> Dictionary:
	var rejection := _validate_execution_context(entry, request_id, lease, delta)
	if not bool(rejection.get("ok", false)):
		return rejection
	var body := entry.get("body") as CharacterBody3D
	var waypoints: Array = lease.get("waypoints", [])
	var waypoint_radius := float(options.get("waypointRadius", DEFAULT_WAYPOINT_RADIUS))
	var final_waypoint_radius := float(options.get("finalWaypointRadius", waypoint_radius))
	var deferred_execution := _take_deferred_execution_result(entry, request_id)
	if not deferred_execution.is_empty():
		return deferred_execution
	var new_request := _reset_if_new_request(entry, request_id)
	if new_request:
		_mirror_lease_for_runtime_services(entry, lease, options)
		if String(entry.get("activeDoorPortalId", "")) != "" and system != null and system.has_method("bind_npc_door_crossing_successor"):
			entry["activeDoorSuccessorBinding"] = system.call(
				"bind_npc_door_crossing_successor",
				entry,
				request_id,
				int(lease.get("generation", -1)),
				String(lease.get("leaseId", ""))
			)
	if not bool(entry.get("_v2LeaseExecutorMoving", false)):
		var moving: Dictionary = route_authority.begin_moving(request_id, "lease_executor_started") if route_authority != null else { "ok": true }
		if not bool(moving.get("ok", false)):
			return { "ok": false, "status": "rejected", "reason": String(moving.get("reason", "route_not_ready")), "authority": moving }
		entry["_v2LeaseExecutorMoving"] = true
	var index := clampi(int(entry.get("_v2LeaseExecutorWaypointIndex", 0)), 0, waypoints.size())
	index = _skip_reached_waypoints(entry, request_id, body, lease, waypoints, index, waypoint_radius, final_waypoint_radius)
	if index >= waypoints.size():
		_publish_motion_metadata(body, Vector3.ZERO, Vector3.ZERO)
		if bool(options.get("deferArrivalReport", false)):
			return { "ok": true, "status": "route_complete", "reason": "awaiting_semantic_arrival", "moved": 0.0 }
		var arrived: Dictionary = route_authority.report_arrived(request_id, "lease_executor_arrived") if route_authority != null else { "ok": true }
		_clear_request(entry)
		return { "ok": true, "status": "arrived", "reason": "", "authority": arrived }
	var transition_result := _handle_surface_transition(entry, request_id, lease, index, body, delta, options)
	if bool(transition_result.get("handled", false)):
		transition_result.erase("handled")
		return transition_result
	if int(entry.get("_v2LeaseExecutorActiveSegment", -1)) != index:
		entry["_v2LeaseExecutorActiveSegment"] = index
		entry["_v2LeaseExecutorSegmentStart"] = body.global_position
		if route_authority != null:
			route_authority.report_segment_started(request_id, index, { "target": waypoints[index] })
	var door_result := _handle_door_action(entry, request_id, lease, index, body, delta, options)
	if not bool(door_result.get("ok", true)):
		return door_result
	var target: Vector3 = waypoints[index]
	var active_waypoint_radius := final_waypoint_radius if index + 1 >= waypoints.size() else waypoint_radius
	var previous: Vector3 = body.global_position
	var offset := target - previous
	offset.y = 0.0
	var flat_distance := offset.length()
	_reset_progress_watch_if_target_changed(entry, "waypoint", index, target, flat_distance)
	if flat_distance <= active_waypoint_radius:
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
	var desired_velocity := offset.normalized() * speed
	var avoidance_options: Dictionary = options.duplicate(true)
	avoidance_options["physicsDelta"] = delta
	var execution_generation := int(entry.get("_v2LeaseExecutorGeneration", 0))
	var avoidance_request_key := "%s|%d|%.3f|%.3f|%.3f|g%d" % [request_id, index, target.x, target.y, target.z, execution_generation]
	avoidance_options["avoidanceRequestKey"] = avoidance_request_key
	avoidance_options["safeVelocityConsumer"] = Callable(self, "_commit_deferred_safe_velocity").bind(entry)
	avoidance_options["safeVelocityFilter"] = Callable(self, "_filter_reverse_velocity_candidate").bind(entry, request_id, lease, index, body, target, desired_velocity, flat_distance, active_waypoint_radius, delta)
	var avoidance := _safe_velocity(entry, body, desired_velocity, target, profile, avoidance_options)
	if bool(avoidance.get("active", false)):
		entry["_v2LeaseExecutorPendingAvoidance"] = {
			"generation": execution_generation,
			"requestKey": avoidance_request_key,
			"requestId": request_id,
			"lease": lease,
			"index": index,
			"body": body,
			"target": target,
			"activeWaypointRadius": active_waypoint_radius,
			"profile": profile,
			"speed": speed,
			"desiredVelocity": desired_velocity,
			"flatDistance": flat_distance,
			"delta": delta,
			"options": options,
			"avoidance": avoidance
		}
		body.set_meta("npc_requested_velocity", desired_velocity)
		body.set_meta("npc_applied_velocity", Vector3.ZERO)
		return { "ok": true, "status": "moving", "reason": "avoidance_submitted", "moved": 0.0, "avoidance": _avoidance_debug(avoidance, desired_velocity, Vector3.ZERO, Vector3.ZERO) }
	entry.erase("_v2LeaseExecutorPendingAvoidance")
	var raw_safe_velocity: Vector3 = avoidance.get("safeVelocity", desired_velocity)
	return _apply_velocity_and_advance(entry, request_id, lease, index, body, target, active_waypoint_radius, profile, speed, desired_velocity, flat_distance, delta, options, avoidance, raw_safe_velocity)


func _commit_deferred_safe_velocity(safe_velocity: Vector3, callback_request_key: String, entry: Dictionary) -> void:
	var pending: Dictionary = entry.get("_v2LeaseExecutorPendingAvoidance", {}) if entry.get("_v2LeaseExecutorPendingAvoidance", {}) is Dictionary else {}
	if pending.is_empty() or String(pending.get("requestKey", "")) != callback_request_key:
		return
	if int(entry.get("_v2LeaseExecutorGeneration", -1)) != int(pending.get("generation", -2)):
		entry.erase("_v2LeaseExecutorPendingAvoidance")
		return
	if String(entry.get("_v2LeaseExecutorRequestId", "")) != String(pending.get("requestId", "")):
		entry.erase("_v2LeaseExecutorPendingAvoidance")
		return
	if int(entry.get("_v2LeaseExecutorWaypointIndex", -1)) != int(pending.get("index", -2)):
		entry.erase("_v2LeaseExecutorPendingAvoidance")
		return
	entry.erase("_v2LeaseExecutorPendingAvoidance")
	var result := _apply_velocity_and_advance(
		entry,
		String(pending.get("requestId", "")),
		pending.get("lease", {}),
		int(pending.get("index", 0)),
		pending.get("body") as CharacterBody3D,
		pending.get("target", Vector3.ZERO),
		float(pending.get("activeWaypointRadius", DEFAULT_WAYPOINT_RADIUS)),
		pending.get("profile"),
		float(pending.get("speed", 0.0)),
		pending.get("desiredVelocity", Vector3.ZERO),
		float(pending.get("flatDistance", 0.0)),
		float(pending.get("delta", 0.0)),
		pending.get("options", {}),
		pending.get("avoidance", {}),
		safe_velocity
	)
	result["requestId"] = String(pending.get("requestId", ""))
	result["executionGeneration"] = int(pending.get("generation", -1))
	entry["routeLeaseDeferredExecution"] = result


func _take_deferred_execution_result(entry: Dictionary, request_id: String) -> Dictionary:
	var deferred: Dictionary = entry.get("routeLeaseDeferredExecution", {}) if entry.get("routeLeaseDeferredExecution", {}) is Dictionary else {}
	entry.erase("routeLeaseDeferredExecution")
	if deferred.is_empty():
		return {}
	if String(deferred.get("requestId", request_id)) != request_id:
		return {}
	if int(deferred.get("executionGeneration", int(entry.get("_v2LeaseExecutorGeneration", -1)))) != int(entry.get("_v2LeaseExecutorGeneration", -1)):
		return {}
	return deferred


func _apply_velocity_and_advance(entry: Dictionary, request_id: String, lease: Dictionary, index: int, body: CharacterBody3D, target: Vector3, active_waypoint_radius: float, profile, speed: float, desired_velocity: Vector3, flat_distance: float, delta: float, options: Dictionary, avoidance: Dictionary, raw_safe_velocity: Vector3) -> Dictionary:
	if body == null or not is_instance_valid(body):
		return { "ok": false, "status": "rejected", "reason": "missing_character_body", "moved": 0.0 }
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	var previous: Vector3 = body.global_position
	var applied_velocity := raw_safe_velocity
	var terminal_route_length := _remaining_waypoint_route_length(body.global_position, waypoints, index)
	var terminal_pending_door := _lease_has_pending_door_from(lease, index)
	var terminal_direct := terminal_route_length <= NpcConstantsScript.AVOIDANCE_TERMINAL_DIRECT_DISTANCE \
		and String(entry.get("activeDoorPortalId", "")) == "" \
		and not terminal_pending_door
	avoidance["terminalRouteLength"] = terminal_route_length
	avoidance["terminalPendingDoor"] = terminal_pending_door
	avoidance["terminalDirectEligible"] = terminal_direct
	var reverse_result: Dictionary = entry.get("_v2AvoidancePendingReverseResult", {}) if entry.get("_v2AvoidancePendingReverseResult", {}) is Dictionary else {}
	entry.erase("_v2AvoidancePendingReverseResult")
	if reverse_result.is_empty():
		reverse_result = {"velocity": applied_velocity, "exhausted": false, "telemetry": {}}
	reverse_result["velocity"] = applied_velocity
	entry["routeLeaseAvoidance"] = _avoidance_debug(avoidance, desired_velocity, raw_safe_velocity, applied_velocity)
	entry["routeLeaseAvoidance"]["reverseYield"] = reverse_result.get("telemetry", {}).duplicate(true)
	body.set_meta("npc_requested_velocity", desired_velocity)
	body.set_meta("npc_avoidance_committed_velocity", applied_velocity)
	if bool(avoidance.get("movementBlocked", false)) or (bool(avoidance.get("active", false)) and applied_velocity.length_squared() <= 0.000001):
		body.set_meta("npc_applied_velocity", Vector3.ZERO)
		return { "ok": false, "status": "waiting", "reason": "blocked_dynamic", "classification": "crowd_avoidance", "moved": 0.0, "avoidance": entry["routeLeaseAvoidance"] }
	var command = CharacterMotorCommandScript.from_velocity(applied_velocity)
	command.grounded_hint = true
	command.terrain_grounded = true
	var motor_state = motor.apply(body, command, profile, delta, terrain_provider)
	var moved := Vector2(body.global_position.x - previous.x, body.global_position.z - previous.z).length()
	var realized_velocity := (body.global_position - previous) / maxf(delta, 0.001)
	realized_velocity.y = 0.0
	body.set_meta("npc_applied_velocity", realized_velocity)
	entry["routeLeaseAvoidance"]["realizedVelocity"] = realized_velocity
	entry["_v2LeaseExecutorLastMove"] = moved
	if bool(motor_state.get("blocked")):
		if String(motor_state.get("blocked_contact_category")) == "dynamic_actor":
			return {
				"ok": false,
				"status": "waiting",
				"reason": "blocked_dynamic",
				"classification": "motor_actor_contact",
				"moved": moved,
				"motor": motor_state.to_summary() if motor_state.has_method("to_summary") else {}
			}
		_report_collision(entry, request_id, motor_state)
		return {
			"ok": false,
			"status": "waiting",
			"reason": "unexpected_collision",
			"moved": moved,
			"motor": motor_state.to_summary() if motor_state.has_method("to_summary") else {}
		}
	if moved <= MIN_PROGRESS_DISTANCE:
		if bool(avoidance.get("active", false)):
			entry["_v2LeaseExecutorStuckTime"] = 0.0
			return { "ok": false, "status": "waiting", "reason": "blocked_dynamic", "classification": "crowd_avoidance", "moved": moved, "avoidance": entry["routeLeaseAvoidance"] }
		var stuck_time := float(entry.get("_v2LeaseExecutorStuckTime", 0.0)) + delta
		entry["_v2LeaseExecutorStuckTime"] = stuck_time
		if stuck_time >= STUCK_TIME_SECONDS:
			if route_authority != null:
				route_authority.report_stuck(request_id, "stuck", { "stuckTime": stuck_time, "target": target })
			return { "ok": false, "status": "waiting", "reason": "stuck", "moved": moved }
	else:
		entry["_v2LeaseExecutorStuckTime"] = 0.0
	# The route is collision-proven in continuous space, while a live frame can
	# move farther than the remaining distance to a waypoint.  Treat a waypoint
	# crossed by this exact motor displacement as completed before the generic
	# progress watchdog runs.  Without this, the actor can oscillate across a
	# corner on coarse frames and be reported as dynamically stuck even though it
	# actually traversed the waypoint corridor.
	var terminal_waypoint := index + 1 >= waypoints.size()
	var crossed_waypoint := _crossed_waypoint(previous, body.global_position, target, active_waypoint_radius)
	if crossed_waypoint and (not terminal_waypoint or bool(options.get("allowTerminalWaypointCrossing", false))):
		_reset_progress_watch(entry)
		entry["_v2LeaseExecutorWaypointIndex"] = index + 1
		if route_authority != null:
			route_authority.report_segment_completed(request_id, index, {
				"position": body.global_position,
				"completion": "crossed_waypoint"
			})
		if index + 1 >= waypoints.size():
			if bool(options.get("deferArrivalReport", false)):
				return { "ok": true, "status": "route_complete", "reason": "awaiting_semantic_arrival", "moved": moved }
			var arrived_after_crossing: Dictionary = route_authority.report_arrived(request_id, "lease_executor_arrived") if route_authority != null else { "ok": true }
			_clear_request(entry)
			return { "ok": true, "status": "arrived", "reason": "", "moved": moved, "authority": arrived_after_crossing }
		return { "ok": true, "status": "moving", "reason": "", "moved": moved, "waypointIndex": index + 1 }
	var no_progress := _update_progress_watch(entry, request_id, "waypoint", index, target, flat_distance, body.global_position, delta, moved, active_waypoint_radius, bool(avoidance.get("active", false)))
	if not bool(no_progress.get("ok", true)):
		return no_progress
	if Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length() <= active_waypoint_radius:
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


func _crossed_waypoint(previous: Vector3, current: Vector3, target: Vector3, waypoint_radius: float) -> bool:
	var travel := current - previous
	travel.y = 0.0
	var travel_length_squared := travel.length_squared()
	if travel_length_squared <= 0.000001:
		return false
	var target_offset := target - previous
	target_offset.y = 0.0
	var fraction := clampf(target_offset.dot(travel) / travel_length_squared, 0.0, 1.0)
	var closest := previous + travel * fraction
	closest.y = target.y
	return Vector2(closest.x - target.x, closest.z - target.z).length() <= waypoint_radius


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
	entry["_v2LeaseExecutorGeneration"] = int(entry.get("_v2LeaseExecutorGeneration", 0)) + 1
	entry["_v2LeaseExecutorRequestId"] = request_id
	entry["_v2LeaseExecutorWaypointIndex"] = 0
	entry["_v2LeaseExecutorActiveSegment"] = -1
	entry["_v2LeaseExecutorMoving"] = false
	entry["_v2LeaseExecutorStuckTime"] = 0.0
	entry["_v2AvoidanceReplanCount"] = int(entry.get("crowdAvoidanceReplanCount", 0))
	return true


func _mirror_lease_for_runtime_services(entry: Dictionary, lease: Dictionary, options := {}) -> void:
	entry["routeActions"] = (lease.get("actions", {}) as Dictionary).duplicate(true) if lease.get("actions", {}) is Dictionary else {}
	entry["routeCells"] = (lease.get("cells", []) as Array).duplicate() if lease.get("cells", []) is Array else []
	entry["pathWaypoints"] = (lease.get("waypoints", []) as Array).duplicate() if lease.get("waypoints", []) is Array else []
	entry["routeDoorWaypointBindings"] = _door_waypoint_bindings(lease)
	var target_cell = lease.get("targetCell", Vector2i(999999, 999999))
	if target_cell is Vector2i:
		entry["routeGoalCell"] = target_cell
	var semantic_kind := String(options.get("semanticKind", lease.get("semanticKind", "")))
	var intent_kind := String(options.get("intentKind", lease.get("intentKind", "")))
	var moving_home := bool(options.get("movingHome", semantic_kind == "home_interior" or intent_kind == "home"))
	entry["routeMovingHome"] = moving_home
	entry["movingHome"] = moving_home


func _clear_request(entry: Dictionary) -> void:
	_release_surface_transition(entry, "route_request_cleared")
	entry.erase("pendingNavigationTransition")
	entry.erase("_v2LeaseExecutorPendingAvoidance")
	entry.erase("routeLeaseDeferredExecution")
	entry.erase("_v2LeaseExecutorRequestId")
	entry.erase("_v2LeaseExecutorWaypointIndex")
	entry.erase("_v2LeaseExecutorActiveSegment")
	entry.erase("_v2LeaseExecutorSegmentStart")
	entry.erase("_v2LeaseExecutorMoving")
	entry.erase("_v2LeaseExecutorStuckTime")
	entry.erase("_v2LeaseExecutorLastMove")
	entry.erase("_v2LeaseExecutorProgressKey")
	entry.erase("_v2LeaseExecutorBestDistance")
	entry.erase("_v2LeaseExecutorLastDistance")
	entry.erase("_v2LeaseExecutorNoProgressTime")
	entry.erase("_v2AvoidanceReverseKey")
	entry.erase("_v2AvoidanceReverseFrames")
	entry.erase("_v2AvoidanceReverseDistance")
	entry.erase("_v2AvoidanceLastDirectionSign")
	entry.erase("_v2AvoidanceDirectionFlips")
	entry.erase("_v2AvoidanceInitialDistance")
	entry.erase("_v2AvoidanceBestDistance")


func _publish_motion_metadata(body: CharacterBody3D, requested_velocity: Vector3, applied_velocity: Vector3) -> void:
	if body == null or not is_instance_valid(body):
		return
	var requested_planar := Vector3(requested_velocity.x, 0.0, requested_velocity.z)
	var applied_planar := Vector3(applied_velocity.x, 0.0, applied_velocity.z)
	body.set_meta("npc_requested_velocity", requested_planar)
	body.set_meta("npc_avoidance_committed_velocity", applied_planar)
	body.set_meta("npc_applied_velocity", applied_planar)


func _skip_reached_waypoints(entry: Dictionary, request_id: String, body: CharacterBody3D, lease: Dictionary, waypoints: Array, index: int, waypoint_radius: float, final_waypoint_radius: float) -> int:
	var cursor := index
	while cursor < waypoints.size():
		var waypoint: Vector3 = waypoints[cursor]
		var active_radius := final_waypoint_radius if cursor + 1 >= waypoints.size() else waypoint_radius
		var reached := Vector2(body.global_position.x - waypoint.x, body.global_position.z - waypoint.z).length() <= active_radius
		if not reached and cursor + 1 < waypoints.size() \
			and _door_action_for_waypoint(lease, cursor).is_empty() \
			and _surface_transition_action_for_waypoint(lease, cursor).is_empty():
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
	var door := _action_door_node(action)
	if door == null or not is_instance_valid(door):
		_publish_motion_metadata(body, Vector3.ZERO, Vector3.ZERO)
		if route_authority != null:
			route_authority.report_door_wait(request_id, "missing_door_action_node", { "waypointIndex": waypoint_index })
		return { "ok": false, "status": "waiting", "reason": "missing_door_action_node", "moved": 0.0 }
	if system == null or not system.has_method("request_npc_door_traversal"):
		_publish_motion_metadata(body, Vector3.ZERO, Vector3.ZERO)
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
	_publish_motion_metadata(body, Vector3.ZERO, Vector3.ZERO)
	return {
		"ok": false,
		"status": "waiting",
		"reason": String(traversal.get("reason", "door_waiting")),
		"moved": 0.0,
		"door": traversal
	}


func _move_toward_position(entry: Dictionary, request_id: String, body: CharacterBody3D, target: Vector3, delta: float, options := {}) -> Dictionary:
	var offset := target - body.global_position
	offset.y = 0.0
	var flat_distance := offset.length()
	_reset_progress_watch_if_target_changed(entry, "door_stage", -1, target, flat_distance)
	if flat_distance <= DEFAULT_WAYPOINT_RADIUS:
		_reset_progress_watch(entry)
		_publish_motion_metadata(body, Vector3.ZERO, Vector3.ZERO)
		return { "ok": false, "status": "waiting", "reason": "door_stage_wait", "moved": 0.0 }
	var profile = entry.get("motorProfile")
	if profile == null:
		profile = CharacterMotorProfileScript.npc_default()
		entry["motorProfile"] = profile
	var requested_speed := float(options.get("speed", profile.get("walk_speed")))
	var speed := minf(requested_speed, flat_distance / maxf(delta, 0.001))
	var desired_velocity := offset.normalized() * speed
	var avoidance := _safe_velocity(entry, body, desired_velocity, target, profile, options)
	var raw_safe_velocity: Vector3 = avoidance.get("safeVelocity", desired_velocity)
	var applied_velocity := raw_safe_velocity
	if applied_velocity.length() > speed:
		applied_velocity = applied_velocity.normalized() * speed
	entry["routeLeaseAvoidance"] = _avoidance_debug(avoidance, desired_velocity, raw_safe_velocity, applied_velocity)
	if bool(avoidance.get("movementBlocked", false)) or (bool(avoidance.get("active", false)) and applied_velocity.length_squared() <= 0.000001):
		_publish_motion_metadata(body, desired_velocity, Vector3.ZERO)
		return { "ok": false, "status": "waiting", "reason": "blocked_dynamic", "classification": "crowd_avoidance", "moved": 0.0, "avoidance": entry["routeLeaseAvoidance"] }
	var command = CharacterMotorCommandScript.from_velocity(applied_velocity)
	command.grounded_hint = true
	command.terrain_grounded = true
	var previous := body.global_position
	var motor_state = motor.apply(body, command, profile, delta, terrain_provider)
	var moved := Vector2(body.global_position.x - previous.x, body.global_position.z - previous.z).length()
	var realized_velocity := (body.global_position - previous) / maxf(delta, 0.001)
	realized_velocity.y = 0.0
	_publish_motion_metadata(body, desired_velocity, realized_velocity)
	entry["routeLeaseAvoidance"]["realizedVelocity"] = realized_velocity
	if bool(motor_state.get("blocked")):
		return { "ok": false, "status": "waiting", "reason": "door_stage_blocked", "moved": moved }
	var no_progress := _update_progress_watch(entry, request_id, "door_stage", -1, target, flat_distance, body.global_position, delta, moved, DEFAULT_WAYPOINT_RADIUS, bool(avoidance.get("active", false)))
	if not bool(no_progress.get("ok", true)):
		no_progress["status"] = "waiting"
		return no_progress
	return { "ok": false, "status": "waiting", "reason": "door_stage_required", "moved": moved }


func _door_action_for_waypoint(lease: Dictionary, waypoint_index: int) -> Dictionary:
	var actions: Dictionary = lease.get("actions", {}) if lease.get("actions", {}) is Dictionary else {}
	if actions.is_empty():
		return {}
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	if waypoint_index < 0 or waypoint_index >= waypoints.size() or not (waypoints[waypoint_index] is Vector3):
		return {}
	var waypoint: Vector3 = waypoints[waypoint_index]
	var best_action: Dictionary = {}
	var best_distance := INF
	var best_uses_navigation_link := false
	var action_keys := actions.keys()
	action_keys.sort()
	for action_key in action_keys:
		var action_value = actions.get(action_key)
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value
		if String(action.get("kind", "")) != "door" or not bool(action.get("enabled", true)):
			continue
		var binding := _door_action_waypoint_binding(action, waypoint)
		if binding.is_empty():
			continue
		var distance := float(binding.get("distance", INF))
		var uses_navigation_link := bool(action.get("navLink", false))
		if distance < best_distance - 0.001 \
			or (is_equal_approx(distance, best_distance) and uses_navigation_link and not best_uses_navigation_link):
			best_action = action
			best_distance = distance
			best_uses_navigation_link = uses_navigation_link
	return best_action


func _door_action_waypoint_binding(action: Dictionary, waypoint: Vector3) -> Dictionary:
	var closest_distance := INF
	var closest_phase := ""
	var entry_position = action.get("entryPosition", null)
	if entry_position is Vector3:
		closest_distance = waypoint.distance_to(entry_position)
		closest_phase = "entry"
	var door := _action_door_node(action)
	if closest_phase == "" and door != null:
		closest_distance = waypoint.distance_to(door.global_position)
		closest_phase = "door"
	if closest_phase == "" or closest_distance > NpcConstantsScript.DOOR_PORTAL_PATH_POINT_EPSILON:
		return {}
	return {
		"distance": closest_distance,
		"phase": closest_phase
	}


func _door_waypoint_bindings(lease: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen_portals := {}
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	for waypoint_index in range(waypoints.size()):
		if not (waypoints[waypoint_index] is Vector3):
			continue
		var action := _door_action_for_waypoint(lease, waypoint_index)
		if action.is_empty():
			continue
		var portal_id := String(action.get("portalId", ""))
		var portal_key := portal_id if portal_id != "" else "%s|%s" % [String(action.get("cell", "")), String(action.get("direction", ""))]
		if seen_portals.has(portal_key):
			continue
		var waypoint: Vector3 = waypoints[waypoint_index]
		var binding := _door_action_waypoint_binding(action, waypoint)
		seen_portals[portal_key] = true
		result.append({
			"portalId": portal_id,
			"actionCell": action.get("cell", Vector2i(999999, 999999)),
			"direction": String(action.get("direction", "")),
			"navLink": bool(action.get("navLink", false)),
			"waypointIndex": waypoint_index,
			"waypoint": waypoint,
			"phase": String(binding.get("phase", "")),
			"distance": float(binding.get("distance", INF))
		})
	return result


func _action_door_node(action: Dictionary) -> Node3D:
	var door_value = action.get("door", null)
	if door_value == null or not is_instance_valid(door_value) or not (door_value is Node3D):
		return null
	return door_value as Node3D


func _door_action_is_local(action: Dictionary, body: CharacterBody3D) -> bool:
	if body == null:
		return false
	var entry_position = action.get("entryPosition", null)
	if entry_position is Vector3:
		var entry_distance := Vector2(body.global_position.x - entry_position.x, body.global_position.z - entry_position.z).length()
		if entry_distance <= NpcConstantsScript.CELL_SIZE * 1.35:
			return true
	var door := _action_door_node(action)
	if door != null:
		var door_distance := Vector2(body.global_position.x - door.global_position.x, body.global_position.z - door.global_position.z).length()
		return door_distance <= NpcConstantsScript.CELL_SIZE * 1.8
	return false


func _handle_surface_transition(entry: Dictionary, request_id: String, lease: Dictionary, waypoint_index: int, body: CharacterBody3D, delta: float, options: Dictionary) -> Dictionary:
	var active: Dictionary = entry.get("activeNavigationTransition", {}) if entry.get("activeNavigationTransition", {}) is Dictionary else {}
	var pending: Dictionary = entry.get("pendingNavigationTransition", {}) if entry.get("pendingNavigationTransition", {}) is Dictionary else {}
	var action: Dictionary = {}
	if not active.is_empty() and active.get("action", {}) is Dictionary:
		action = active.get("action", {}) as Dictionary
	elif not pending.is_empty() and pending.get("action", {}) is Dictionary:
		action = pending.get("action", {}) as Dictionary
	else:
		action = _surface_transition_action_for_waypoint(lease, waypoint_index)
	if action.is_empty():
		return {"handled": false}
	var corridor_certificate: Dictionary = action.get("corridorCertificate", {}) if action.get("corridorCertificate", {}) is Dictionary else {}
	if not bool(corridor_certificate.get("collisionBacked", false)) or not bool(corridor_certificate.get("standable", false)):
		return {"handled": true, "ok": false, "status": "rejected", "reason": "surface_transition_missing_corridor_certificate", "moved": 0.0}
	if system == null or not system.has_method("revalidate_navigation_transition_action"):
		return {"handled": true, "ok": false, "status": "rejected", "reason": "navigation_transition_validation_authority_unavailable", "moved": 0.0}
	var revalidation: Dictionary = system.call("revalidate_navigation_transition_action", action, corridor_certificate)
	if not bool(revalidation.get("ok", false)):
		_release_surface_transition(entry, "corridor_revalidation_failed")
		return {"handled": true, "ok": false, "status": "rejected", "reason": "navigation_transition_corridor_changed", "classification": String(revalidation.get("reason", "uncertified")), "moved": 0.0, "revalidation": revalidation, "action": action.duplicate(true)}
	if bool(revalidation.get("revalidated", false)) and revalidation.get("certificate", {}) is Dictionary:
		corridor_certificate = revalidation.get("certificate", {}) as Dictionary
		action["corridorCertificate"] = corridor_certificate
		if not active.is_empty():
			active["action"] = action.duplicate(true)
			entry["activeNavigationTransition"] = active
		elif not pending.is_empty():
			pending["action"] = action.duplicate(true)
			entry["pendingNavigationTransition"] = pending
	if system == null or not system.has_method("navigation_transition_action_is_current") or not bool(system.call("navigation_transition_action_is_current", action)):
		_release_surface_transition(entry, "topology_revision_changed")
		return {"handled": true, "ok": false, "status": "rejected", "reason": "navigation_transition_topology_changed", "moved": 0.0, "action": action.duplicate(true)}
	var lease_revision := String(lease.get("snapshotRevision", ""))
	if not lease_revision.is_empty() and String(action.get("snapshotRevision", lease_revision)) != lease_revision:
		_release_surface_transition(entry, "topology_revision_changed")
		return {"handled": true, "ok": false, "status": "rejected", "reason": "surface_transition_revision_mismatch", "moved": 0.0, "action": action.duplicate(true)}
	var staging_position: Vector3 = action.get("stagingPosition", action.get("entryPosition", Vector3.INF)) as Vector3
	var clearance_position: Vector3 = action.get("clearancePosition", action.get("exitPosition", Vector3.INF)) as Vector3
	if not staging_position.is_finite() or not clearance_position.is_finite():
		return {"handled": true, "ok": false, "status": "rejected", "reason": "surface_transition_missing_corridor", "moved": 0.0}
	if active.is_empty():
		if pending.is_empty() and _flat_position_distance(body.global_position, staging_position) > TRANSITION_ACTIVATION_DISTANCE:
			return {"handled": false}
		if system == null or not system.has_method("request_npc_navigation_transition"):
			return {"handled": true, "ok": false, "status": "rejected", "reason": "missing_navigation_transition_traffic", "moved": 0.0}
		var reservation: Dictionary = system.call("request_npc_navigation_transition", entry, action, {
			"priority": int(options.get("priority", entry.get("routePriority", 0))),
			"kind": String(options.get("intentKind", "move"))
		})
		if not bool(reservation.get("ok", false)):
			var queue_position: Vector3 = action.get("queuePosition", Vector3.INF) as Vector3
			pending = {
				"action": action.duplicate(true),
				"groupId": String(reservation.get("groupId", "")),
				"queuePosition": queue_position,
				"snapshotRevision": lease_revision
			}
			entry["pendingNavigationTransition"] = pending
			if not queue_position.is_finite():
				_publish_motion_metadata(body, Vector3.ZERO, Vector3.ZERO)
				return {"handled": true, "ok": false, "status": "waiting", "reason": "surface_transition_missing_queue_position", "classification": "traffic_reservation", "moved": 0.0, "transition": reservation}
			var queue_move := _move_toward_position(entry, request_id, body, queue_position, delta, options)
			queue_move["handled"] = true
			queue_move["ok"] = false
			queue_move["status"] = "waiting"
			queue_move["reason"] = String(reservation.get("reason", "traffic_wait"))
			queue_move["classification"] = "traffic_reservation"
			queue_move["transition"] = pending.duplicate(true)
			return queue_move
		entry.erase("pendingNavigationTransition")
		var exit_waypoint_index := _surface_transition_exit_waypoint_index(lease, waypoint_index, action)
		if exit_waypoint_index < waypoint_index:
			if system.has_method("release_npc_navigation_transition"):
				system.call("release_npc_navigation_transition", entry, "missing_exit_waypoint")
			return {"handled": true, "ok": false, "status": "rejected", "reason": "surface_transition_missing_exit_waypoint", "moved": 0.0}
		active = {
			"action": action.duplicate(true),
			"linkId": String(action.get("linkId", "")),
			"linkRid": int(action.get("linkRid", 0)),
			"groupId": String(reservation.get("groupId", "")),
			"phase": "staging",
			"entryWaypointIndex": waypoint_index,
			"exitWaypointIndex": exit_waypoint_index,
			"entryPosition": action.get("entryPosition", Vector3.INF),
			"exitPosition": action.get("exitPosition", Vector3.INF),
			"stagingPosition": staging_position,
			"clearancePosition": clearance_position,
			"snapshotRevision": lease_revision,
			"corridorConstrained": true
		}
		entry["activeNavigationTransition"] = active
	var phase := String(active.get("phase", "staging"))
	var target := staging_position if phase == "staging" else clearance_position
	if _flat_position_distance(body.global_position, target) <= TRANSITION_STAGE_RADIUS:
		if phase == "staging":
			active["phase"] = "crossing"
			entry["activeNavigationTransition"] = active
			target = clearance_position
		else:
			var exit_index := int(active.get("exitWaypointIndex", waypoint_index))
			entry["_v2LeaseExecutorWaypointIndex"] = _surface_transition_clearance_successor_waypoint_index(lease, exit_index, action)
			if route_authority != null:
				route_authority.report_segment_completed(request_id, exit_index, {"position": body.global_position, "completion": "surface_transition_clearance"})
			_release_surface_transition(entry, "surface_transition_cleared")
			_publish_motion_metadata(body, Vector3.ZERO, Vector3.ZERO)
			return {"handled": true, "ok": true, "status": "moving", "reason": "surface_transition_cleared", "moved": 0.0, "waypointIndex": exit_index + 1}
	var move := _move_toward_position(entry, request_id, body, target, delta, options)
	var move_reason := String(move.get("reason", ""))
	if move_reason == "door_stage_blocked":
		move["reason"] = "unexpected_collision"
	elif move_reason not in ["blocked_dynamic", "stuck"]:
		move["ok"] = true
		move["status"] = "moving"
		move["reason"] = "surface_transition_%s" % phase
	move["handled"] = true
	move["transition"] = active.duplicate(true)
	return move


func _surface_transition_action_for_waypoint(lease: Dictionary, waypoint_index: int) -> Dictionary:
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	if waypoint_index < 0 or waypoint_index >= waypoints.size() or not (waypoints[waypoint_index] is Vector3):
		return {}
	var waypoint: Vector3 = waypoints[waypoint_index]
	var actions: Dictionary = lease.get("actions", {}) if lease.get("actions", {}) is Dictionary else {}
	var keys := actions.keys()
	keys.sort()
	for key in keys:
		var action_value = actions.get(key)
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value
		if String(action.get("kind", "")) != "surface_transition" or not bool(action.get("enabled", true)):
			continue
		var entry_value = action.get("entryPosition", null)
		if entry_value is Vector3 and waypoint.distance_to(entry_value as Vector3) <= 0.001:
			return action
	return {}


func _surface_transition_exit_waypoint_index(lease: Dictionary, entry_index: int, action: Dictionary) -> int:
	var exit_value = action.get("exitPosition", null)
	if not (exit_value is Vector3):
		return -1
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	for index in range(entry_index + 1, waypoints.size()):
		if waypoints[index] is Vector3 and (waypoints[index] as Vector3).distance_to(exit_value as Vector3) <= 0.001:
			return index
	return -1


func _surface_transition_clearance_successor_waypoint_index(lease: Dictionary, exit_index: int, action: Dictionary) -> int:
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	var entry_position: Vector3 = action.get("entryPosition", Vector3.INF) as Vector3
	var exit_position: Vector3 = action.get("exitPosition", Vector3.INF) as Vector3
	var clearance_position: Vector3 = action.get("clearancePosition", Vector3.INF) as Vector3
	var crossing_axis := exit_position - entry_position
	crossing_axis.y = 0.0
	if not entry_position.is_finite() or not exit_position.is_finite() or not clearance_position.is_finite() or crossing_axis.length_squared() <= 0.000001:
		return mini(waypoints.size(), exit_index + 1)
	crossing_axis = crossing_axis.normalized()
	var clearance_projection := (clearance_position - exit_position).dot(crossing_axis)
	for index in range(exit_index + 1, waypoints.size()):
		if not (waypoints[index] is Vector3):
			continue
		var waypoint: Vector3 = waypoints[index] as Vector3
		if (waypoint - exit_position).dot(crossing_axis) > clearance_projection + TRANSITION_STAGE_RADIUS:
			return index
	return waypoints.size()


func _flat_position_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x - second.x, first.z - second.z).length()


func _release_surface_transition(entry: Dictionary, reason: String) -> void:
	var has_active := entry.get("activeNavigationTransition", {}) is Dictionary and not (entry.get("activeNavigationTransition", {}) as Dictionary).is_empty()
	var has_pending := entry.get("pendingNavigationTransition", {}) is Dictionary and not (entry.get("pendingNavigationTransition", {}) as Dictionary).is_empty()
	if (has_active or has_pending) and system != null and system.has_method("release_npc_navigation_transition"):
		system.call("release_npc_navigation_transition", entry, reason)
	entry.erase("activeNavigationTransition")
	entry.erase("pendingNavigationTransition")


func _filter_reverse_velocity_candidate(safe_velocity: Vector3, entry: Dictionary, request_id: String, lease: Dictionary, segment_index: int, body: CharacterBody3D, target: Vector3, desired_velocity: Vector3, target_distance: float, arrival_radius: float, delta: float) -> Vector3:
	var avoidance: Dictionary = entry.get("routeLeaseAvoidance", {}) if entry.get("routeLeaseAvoidance", {}) is Dictionary else {}
	var result := _apply_bounded_reverse_yield(entry, request_id, lease, segment_index, body, target, desired_velocity, safe_velocity, target_distance, arrival_radius, delta, avoidance)
	entry["_v2AvoidancePendingReverseResult"] = result
	return result.get("velocity", safe_velocity)


func avoidance_stats() -> Dictionary:
	return crowd_velocity_service.stats() if crowd_velocity_service != null else {}


func _safe_velocity(entry: Dictionary, body: CharacterBody3D, desired_velocity: Vector3, target: Vector3, profile, options: Dictionary) -> Dictionary:
	if crowd_velocity_service == null:
		return {
			"active": false,
			"safeVelocity": Vector3.ZERO,
			"status": "blocked",
			"reason": "missing_crowd_authority",
			"callbackFresh": false,
			"fallbackUsed": false,
			"movementBlocked": true,
			"activeRegistrationCount": 0
		}
	var active_transition: Dictionary = entry.get("activeNavigationTransition", {}) if entry.get("activeNavigationTransition", {}) is Dictionary else {}
	var corridor_direction := target - body.global_position
	if String(active_transition.get("phase", "")) == "crossing":
		corridor_direction = (active_transition.get("exitPosition", target) as Vector3) - (active_transition.get("entryPosition", body.global_position) as Vector3)
	corridor_direction.y = 0.0
	return crowd_velocity_service.resolve_safe_velocity(entry, body, desired_velocity, {
		"profile": profile,
		"portalMode": String(entry.get("activeDoorPortalId", "")) != "" or not active_transition.is_empty(),
		"corridorDirection": corridor_direction,
		"maxSpeed": desired_velocity.length(),
		"priority": int(entry.get("routePriority", options.get("priority", 0))),
		"physicsDelta": float(options.get("physicsDelta", options.get("delta", 1.0 / 60.0))),
		"avoidanceTarget": target,
		"avoidanceRequestKey": String(options.get("avoidanceRequestKey", "")),
		"safeVelocityConsumer": options.get("safeVelocityConsumer", Callable()),
		"safeVelocityFilter": options.get("safeVelocityFilter", Callable())
	})

func _avoidance_debug(avoidance: Dictionary, desired_velocity: Vector3, raw_safe_velocity: Vector3, applied_velocity: Vector3) -> Dictionary:
	return {
		"active": bool(avoidance.get("active", false)),
		"status": String(avoidance.get("status", "")),
		"reason": String(avoidance.get("reason", "")),
		"callbackFresh": bool(avoidance.get("callbackFresh", false)),
		"fallbackUsed": bool(avoidance.get("fallbackUsed", false)),
		"movementBlocked": bool(avoidance.get("movementBlocked", false)),
		"activeRegistrationCount": int(avoidance.get("activeRegistrationCount", 0)),
		"desiredVelocity": desired_velocity,
		"preferredVelocity": avoidance.get("preferredVelocity", desired_velocity),
		"laneBiasApplied": bool(avoidance.get("laneBiasApplied", false)),
		"encounterActorId": String(avoidance.get("encounterActorId", "")),
		"selfAvoidancePriority": float(avoidance.get("selfAvoidancePriority", 0.0)),
		"encounterAvoidancePriority": float(avoidance.get("encounterAvoidancePriority", 0.0)),
		"encounterStationary": bool(avoidance.get("encounterStationary", false)),
		"certifiedLaneOverride": bool(avoidance.get("certifiedLaneOverride", false)),
		"terminalDirectOverride": bool(avoidance.get("terminalDirectOverride", false)),
		"terminalRouteLength": float(avoidance.get("terminalRouteLength", INF)),
		"terminalPendingDoor": bool(avoidance.get("terminalPendingDoor", false)),
		"deterministicEncounterPrecedence": bool(avoidance.get("deterministicEncounterPrecedence", false)),
		"solverAgent": avoidance.get("solverAgent", {}),
		"rawSafeVelocity": raw_safe_velocity,
		"appliedVelocity": applied_velocity,
		"corridorConstrained": bool(avoidance.get("corridorConstrained", false)) or not raw_safe_velocity.is_equal_approx(applied_velocity),
		"metrics": avoidance.get("metrics", {})
	}


func _remaining_waypoint_route_length(position: Vector3, waypoints: Array, index: int) -> float:
	if index < 0 or index >= waypoints.size():
		return 0.0
	var remaining := position.distance_to(waypoints[index] as Vector3)
	for waypoint_index in range(index, waypoints.size() - 1):
		remaining += (waypoints[waypoint_index] as Vector3).distance_to(waypoints[waypoint_index + 1] as Vector3)
	return remaining


func _lease_has_pending_door_from(lease: Dictionary, index: int) -> bool:
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	for waypoint_index in range(maxi(0, index), waypoints.size()):
		if not _door_action_for_waypoint(lease, waypoint_index).is_empty():
			return true
	return false


func _apply_bounded_reverse_yield(entry: Dictionary, request_id: String, lease: Dictionary, segment_index: int, body: CharacterBody3D, target: Vector3, desired_velocity: Vector3, applied_velocity: Vector3, target_distance: float, arrival_radius: float, delta: float, avoidance: Dictionary) -> Dictionary:
	var desired_axis := desired_velocity.normalized() if desired_velocity.length_squared() > 0.0001 else Vector3.ZERO
	var signed_speed := applied_velocity.dot(desired_axis) if desired_axis.length_squared() > 0.0001 else 0.0
	var direction_sign := -1 if signed_speed < -0.01 else (1 if signed_speed > 0.01 else 0)
	var prior_sign := int(entry.get("_v2AvoidanceLastDirectionSign", 0))
	if direction_sign != 0 and prior_sign != 0 and direction_sign != prior_sign:
		entry["_v2AvoidanceDirectionFlips"] = int(entry.get("_v2AvoidanceDirectionFlips", 0)) + 1
	if direction_sign != 0:
		entry["_v2AvoidanceLastDirectionSign"] = direction_sign
	var initial_distance := float(entry.get("_v2AvoidanceInitialDistance", target_distance))
	var best_distance := minf(float(entry.get("_v2AvoidanceBestDistance", initial_distance)), target_distance)
	entry["_v2AvoidanceInitialDistance"] = initial_distance
	entry["_v2AvoidanceBestDistance"] = best_distance
	var encounter_actor_id := String(avoidance.get("encounterActorId", ""))
	var reverse_key := "%s|%d" % [request_id, segment_index]
	if String(entry.get("_v2AvoidanceReverseKey", "")) != reverse_key:
		entry["_v2AvoidanceReverseKey"] = reverse_key
		entry["_v2AvoidanceReverseFrames"] = 0
		entry["_v2AvoidanceReverseDistance"] = 0.0
		entry["_v2AvoidanceReverseStreak"] = 0
	var reverse_frames := int(entry.get("_v2AvoidanceReverseFrames", 0))
	var reverse_distance := float(entry.get("_v2AvoidanceReverseDistance", 0.0))
	var reverse_streak := int(entry.get("_v2AvoidanceReverseStreak", 0))
	var reversing := signed_speed < -0.01
	var portal_mode := String(entry.get("activeDoorPortalId", "")) != "" or not _door_action_for_waypoint(lease, segment_index).is_empty()
	var terminal_mode := segment_index + 1 >= (lease.get("waypoints", []) as Array).size() and target_distance <= maxf(0.0, arrival_radius)
	var rear_clear := true
	if reversing:
		var reverse_direction := applied_velocity.normalized()
		var probe_distance := maxf(applied_velocity.length() * delta, NpcConstantsScript.AVOIDANCE_REVERSE_REAR_PROBE_DISTANCE)
		rear_clear = _motion_collision(body, reverse_direction * probe_distance) == null
	var permitted := reversing and not portal_mode and not terminal_mode and rear_clear \
		and reverse_frames < NpcConstantsScript.AVOIDANCE_MAX_YIELD_REVERSE_FRAMES \
		and reverse_distance < NpcConstantsScript.AVOIDANCE_MAX_YIELD_REVERSE_DISTANCE
	if reversing and permitted:
		var remaining_distance := maxf(0.0, NpcConstantsScript.AVOIDANCE_MAX_YIELD_REVERSE_DISTANCE - reverse_distance)
		var limited_speed := minf(minf(applied_velocity.length(), NpcConstantsScript.AVOIDANCE_MAX_YIELD_REVERSE_SPEED), remaining_distance / maxf(delta, 0.001))
		applied_velocity = applied_velocity.normalized() * limited_speed
		reverse_frames += 1
		reverse_streak += 1
		reverse_distance += limited_speed * delta
		entry["_v2AvoidanceReverseFrames"] = reverse_frames
		entry["_v2AvoidanceReverseDistance"] = reverse_distance
		entry["_v2AvoidanceReverseStreak"] = reverse_streak
	else:
		reverse_streak = 0
		entry["_v2AvoidanceReverseStreak"] = 0
	var exhausted := reversing and not permitted
	return {
		"velocity": desired_velocity if exhausted else applied_velocity,
		"exhausted": exhausted,
		"telemetry": {
			"encounterActorId": encounter_actor_id,
			"desiredSafeDot": desired_axis.dot(avoidance.get("safeVelocity", Vector3.ZERO)) if desired_axis.length_squared() > 0.0001 else 0.0,
			"consecutiveReverseFrames": reverse_streak,
			"totalReverseFrames": reverse_frames,
			"reverseDisplacement": reverse_distance,
			"directionFlips": int(entry.get("_v2AvoidanceDirectionFlips", 0)),
			"netProgress": maxf(0.0, initial_distance - target_distance),
			"bestProgress": maxf(0.0, initial_distance - best_distance),
			"recoveryCount": int(entry.get("crowdAvoidanceRecoveryCount", 0)),
			"replanCount": int(entry.get("crowdAvoidanceReplanCount", 0)),
			"rearClear": rear_clear,
			"portalMode": portal_mode,
			"terminalMode": terminal_mode,
			"exhausted": exhausted
		}
	}


func _motion_collision(body: CharacterBody3D, displacement: Vector3):
	if body == null or not body.is_inside_tree() or displacement.length_squared() <= 0.000001:
		return null
	return body.move_and_collide(displacement, true, 0.001, false, 8)


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


func _update_progress_watch(entry: Dictionary, request_id: String, kind: String, index: int, target: Vector3, previous_distance: float, position: Vector3, delta: float, moved: float, waypoint_radius: float, crowd_active := false) -> Dictionary:
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
	if crowd_active:
		entry["_v2LeaseExecutorNoProgressTime"] = 0.0
		return {
			"ok": false,
			"status": "waiting",
			"reason": "blocked_dynamic",
			"classification": "crowd_avoidance",
			"moved": moved,
			"details": {"stuckKind": "crowd_no_target_progress", "target": target}
		}
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
			"blockedContactShapeName": String(motor_state.get("blocked_contact_shape_name")),
			"blockedContactPartId": String(motor_state.get("blocked_contact_part_id")),
			"blockedContactPartKind": String(motor_state.get("blocked_contact_part_kind")),
			"blockedContactSemantic": String(motor_state.get("blocked_contact_semantic")),
			"blockedContacts": (motor_state.get("blocked_contacts") as Array).duplicate(true),
			"blockedContactCategory": String(motor_state.get("blocked_contact_category")),
			"slideCollisionCount": int(motor_state.get("slide_collision_count"))
		}
	if route_authority != null:
		route_authority.report_unexpected_collision(request_id, "unexpected_collision", details)
