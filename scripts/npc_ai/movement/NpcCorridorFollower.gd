extends RefCounted
class_name NpcCorridorFollower

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var metrics := {
	"steps": 0,
	"arrivals": 0,
	"candidateRejected": 0,
	"staticBlocks": 0,
	"dynamicBlocks": 0,
	"trafficWaits": 0,
	"doorWaits": 0,
	"staleCorridors": 0,
	"invalidGoals": 0,
	"oscillationSignChanges": 0,
	"headingReversals": 0,
	"noProgressClassifications": 0
}

func compute_step(entry: Dictionary, body: CharacterBody3D, previous: Vector3, target: Vector3, path_waypoints: Array, intent: Dictionary, max_distance: float, world, locomotion, avoidance_adapter, actors: Array = []) -> Dictionary:
	metrics["steps"] = int(metrics.get("steps", 0)) + 1
	if body == null or world == null or locomotion == null:
		return rejected("missing_context", "invalid_goal")
	if path_waypoints.is_empty():
		metrics["invalidGoals"] = int(metrics.get("invalidGoals", 0)) + 1
		return rejected("empty_corridor", "invalid_goal")

	var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 1.0 / 60.0)))
	var arrival_radius := float(intent.get("arrivalRadius", NpcConstantsScript.CELL_SIZE * 0.75))
	var remaining := remaining_distance(previous, path_waypoints)
	var final_distance := flat_distance(previous, target)
	if final_distance <= minf(arrival_radius, NpcConstantsScript.CORRIDOR_ARRIVAL_STOP_RADIUS):
		metrics["arrivals"] = int(metrics.get("arrivals", 0)) + 1
		return {
			"ok": true,
			"arrived": true,
			"candidate": previous,
			"desiredVelocity": Vector3.ZERO,
			"safeVelocity": Vector3.ZERO,
			"reason": "arrived",
			"classification": "arrival",
			"remainingDistance": remaining
		}

	var lookahead := select_lookahead(previous, path_waypoints, max_distance, entry)
	var corridor_direction := lookahead - previous
	corridor_direction.y = 0.0
	if corridor_direction.length_squared() <= 0.0001:
		return rejected("lookahead_close", "invalid_goal")
	corridor_direction = corridor_direction.normalized()
	var speed_scale := speed_scale_for_corridor(previous, path_waypoints, entry)
	var step_distance := minf(max_distance * speed_scale, flat_distance(previous, lookahead))
	var desired_velocity := corridor_direction * (step_distance / physics_delta)
	var portal_mode := is_portal_mode(entry, path_waypoints, world)
	var context := {
		"profile": entry.get("agentContext").get("traversal_profile") if entry.get("agentContext") != null else null,
		"actors": actors,
		"portalMode": portal_mode,
		"corridorDirection": corridor_direction,
		"maxSpeed": max_distance / physics_delta,
		"priority": int(entry.get("routePriority", 0)),
		"avoidanceTarget": lookahead
	}
	var terminal_direct := String(intent.get("kind", "")) == "scripted" and remaining <= NpcConstantsScript.AVOIDANCE_TERMINAL_DIRECT_DISTANCE
	var avoidance: Dictionary = {
		"active": false,
		"safeVelocity": desired_velocity,
		"status": "inactive",
		"reason": "terminal_direct",
		"callbackFresh": false,
		"fallbackUsed": false,
		"activeRegistrationCount": 0
	} if terminal_direct else (avoidance_adapter.compute_safe_velocity(entry, body, desired_velocity, context) if avoidance_adapter != null else {
		"active": false,
		"safeVelocity": desired_velocity,
		"status": "inactive",
		"reason": "missing_adapter",
		"callbackFresh": false,
		"fallbackUsed": true,
		"activeRegistrationCount": 0
	})
	var safe_velocity: Vector3 = avoidance.get("safeVelocity", desired_velocity)
	safe_velocity = stabilize_lateral_velocity(entry, safe_velocity, corridor_direction)
	var candidate := previous + safe_velocity * physics_delta
	candidate.y = previous.y
	candidate = clamp_candidate_to_corridor(previous, candidate, lookahead, portal_mode)
	if flat_distance(previous, candidate) > max_distance:
		var clamped_delta := candidate - previous
		clamped_delta.y = 0.0
		candidate = previous + clamped_delta.normalized() * max_distance
	var validation: Dictionary = locomotion.call(
		"validate_candidate",
		entry,
		previous,
		candidate,
		bool(intent.get("movingHome", false)),
		bool(intent.get("allowOutside", false)),
		world,
		int(entry.get("routePriority", 0))
	)
	var direct_validation := {}
	if not bool(validation.get("ok", false)):
		metrics["candidateRejected"] = int(metrics.get("candidateRejected", 0)) + 1
		var direct_candidate := previous + desired_velocity * physics_delta
		direct_candidate.y = previous.y
		direct_candidate = clamp_candidate_to_corridor(previous, direct_candidate, lookahead, portal_mode)
		direct_validation = locomotion.call(
			"validate_candidate",
			entry,
			previous,
			direct_candidate,
			bool(intent.get("movingHome", false)),
			bool(intent.get("allowOutside", false)),
			world,
			int(entry.get("routePriority", 0))
		)
		if bool(direct_validation.get("ok", false)) and not bool(avoidance.get("callbackFresh", false)):
			candidate = direct_validation.get("candidate", direct_candidate)
			validation = direct_validation
		else:
			var reason := String(validation.get("reason", "blocked"))
			var classification := classify_blocker(reason)
			increment_classification(classification)
			return {
				"ok": false,
				"reason": reason,
				"classification": classification,
				"candidate": candidate,
				"blocker": validation.get("blocker"),
				"desiredVelocity": desired_velocity,
				"safeVelocity": safe_velocity,
				"avoidance": avoidance,
				"directValidation": direct_validation,
				"portalMode": portal_mode
			}
	var final_candidate: Vector3 = validation.get("candidate", candidate)
	update_pre_motion_metrics(entry, previous, final_candidate, corridor_direction, remaining, path_waypoints)
	return {
		"ok": true,
		"arrived": false,
		"candidate": final_candidate,
		"desiredVelocity": desired_velocity,
		"safeVelocity": safe_velocity,
		"avoidance": avoidance,
		"reason": String(avoidance.get("reason", "")),
		"classification": "moving",
		"portalMode": portal_mode,
		"remainingDistance": remaining,
		"lookahead": lookahead
	}

func record_motion(entry: Dictionary, previous: Vector3, actual_position: Vector3, path_waypoints: Array, motor_reason := "") -> Dictionary:
	var remaining := remaining_distance(actual_position, path_waypoints)
	var previous_remaining := float(entry.get("corridorRemainingDistance", remaining))
	var progress := previous_remaining - remaining
	entry["corridorRemainingDistance"] = remaining
	entry["corridorLastProgress"] = progress
	if progress <= NpcConstantsScript.CORRIDOR_PROGRESS_EPSILON and flat_distance(previous, actual_position) <= NpcConstantsScript.CORRIDOR_PROGRESS_EPSILON:
		entry["corridorNoProgressTicks"] = int(entry.get("corridorNoProgressTicks", 0)) + 1
	else:
		entry["corridorNoProgressTicks"] = 0
	var classification := "moving"
	if int(entry.get("corridorNoProgressTicks", 0)) >= NpcConstantsScript.CORRIDOR_NO_PROGRESS_TICKS:
		classification = classify_blocker(motor_reason)
		metrics["noProgressClassifications"] = int(metrics.get("noProgressClassifications", 0)) + 1
	entry["corridorBlockerClass"] = classification
	return {
		"remainingDistance": remaining,
		"progress": progress,
		"noProgressTicks": int(entry.get("corridorNoProgressTicks", 0)),
		"classification": classification
	}

func select_lookahead(previous: Vector3, path_waypoints: Array, max_distance: float, entry: Dictionary) -> Vector3:
	var target_distance := clampf(max_distance * 3.0, NpcConstantsScript.CORRIDOR_LOOKAHEAD_MIN_DISTANCE, NpcConstantsScript.CORRIDOR_LOOKAHEAD_MAX_DISTANCE)
	var last := previous
	var travelled := 0.0
	for waypoint_index in range(path_waypoints.size()):
		var waypoint_value = path_waypoints[waypoint_index]
		if not (waypoint_value is Vector3):
			continue
		var waypoint: Vector3 = waypoint_value
		var segment := flat_distance(last, waypoint)
		if waypoint_index == 0 and segment < target_distance and should_hold_turn_waypoint(previous, path_waypoints):
			return waypoint
		if travelled + segment >= target_distance and segment > 0.001:
			var t := (target_distance - travelled) / segment
			return last.lerp(waypoint, clampf(t, 0.0, 1.0))
		travelled += segment
		last = waypoint
	return path_waypoints[0] if not path_waypoints.is_empty() else previous

func should_hold_turn_waypoint(previous: Vector3, path_waypoints: Array) -> bool:
	if path_waypoints.size() < 2 or not (path_waypoints[0] is Vector3):
		return false
	var first: Vector3 = path_waypoints[0]
	var first_leg := first - previous
	first_leg.y = 0.0
	if first_leg.length() <= NpcConstantsScript.CORRIDOR_TURN_WAYPOINT_CLEARANCE:
		return false
	for next_index in range(1, path_waypoints.size()):
		if not (path_waypoints[next_index] is Vector3):
			continue
		var second: Vector3 = path_waypoints[next_index]
		var second_leg := second - first
		second_leg.y = 0.0
		if second_leg.length_squared() <= 0.0001 or first_leg.length_squared() <= 0.0001:
			return false
		var angle := rad_to_deg(acos(clampf(first_leg.normalized().dot(second_leg.normalized()), -1.0, 1.0)))
		return angle >= NpcConstantsScript.CORRIDOR_TURN_SLOW_ANGLE_DEGREES
	return false

func speed_scale_for_corridor(previous: Vector3, path_waypoints: Array, entry: Dictionary) -> float:
	var scale := 1.0
	if path_waypoints.size() >= 2:
		var first: Vector3 = path_waypoints[0]
		var second: Vector3 = path_waypoints[1]
		var a := first - previous
		var b := second - first
		a.y = 0.0
		b.y = 0.0
		if a.length_squared() > 0.0001 and b.length_squared() > 0.0001:
			var angle := rad_to_deg(acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0)))
			if angle >= NpcConstantsScript.CORRIDOR_TURN_SLOW_ANGLE_DEGREES:
				scale = minf(scale, NpcConstantsScript.CORRIDOR_TURN_SLOW_FACTOR)
	var actions: Dictionary = entry.get("routeActions", {})
	if not actions.is_empty() and not path_waypoints.is_empty():
		var first_distance := flat_distance(previous, path_waypoints[0])
		if first_distance <= NpcConstantsScript.CORRIDOR_ACTION_SLOW_DISTANCE:
			scale = minf(scale, 0.64)
	return scale

func clamp_candidate_to_corridor(previous: Vector3, candidate: Vector3, lookahead: Vector3, portal_mode := false) -> Vector3:
	var axis := lookahead - previous
	axis.y = 0.0
	if axis.length_squared() <= 0.0001:
		return previous
	axis = axis.normalized()
	var offset := candidate - previous
	offset.y = 0.0
	var forward_distance := maxf(0.0, offset.dot(axis))
	var forward := axis * forward_distance
	var lateral := offset - forward
	var tolerance := NpcConstantsScript.CORRIDOR_PORTAL_LATERAL_TOLERANCE if portal_mode else NpcConstantsScript.CORRIDOR_LATERAL_TOLERANCE
	if lateral.length() > tolerance:
		lateral = lateral.normalized() * tolerance
	var result := previous + forward + lateral
	result.y = candidate.y
	return result

func stabilize_lateral_velocity(entry: Dictionary, velocity: Vector3, corridor_direction: Vector3) -> Vector3:
	if corridor_direction.length_squared() <= 0.0001 or velocity.length_squared() <= 0.0001:
		return velocity
	var axis := corridor_direction.normalized()
	var side := Vector3(-axis.z, 0.0, axis.x)
	var lateral_speed := side.dot(velocity)
	if absf(lateral_speed) <= NpcConstantsScript.CORRIDOR_OSCILLATION_SIGN_EPSILON:
		return velocity
	var lateral_sign := signf(lateral_speed)
	var preferred := float(entry.get("corridorPreferredLateralSign", 0.0))
	var forward := axis * velocity.dot(axis)
	if absf(preferred) > 0.0 and lateral_sign != preferred:
		return forward + side * absf(lateral_speed) * preferred
	entry["corridorPreferredLateralSign"] = lateral_sign
	return velocity

func is_portal_mode(entry: Dictionary, path_waypoints: Array, world) -> bool:
	if String(entry.get("activeDoorPortalId", "")) != "":
		return true
	if world == null or path_waypoints.is_empty():
		return false
	var next_cell: Vector2i = world.world_cell(path_waypoints[0])
	var actions: Dictionary = entry.get("routeActions", {})
	var action: Dictionary = actions.get(world.cell_key(next_cell), {})
	return not action.is_empty() and String(action.get("kind", "")) == "door"

func update_pre_motion_metrics(entry: Dictionary, previous: Vector3, candidate: Vector3, corridor_direction: Vector3, remaining: float, path_waypoints: Array) -> void:
	var movement := candidate - previous
	movement.y = 0.0
	if movement.length_squared() > 0.0001:
		var side := Vector3(-corridor_direction.z, 0.0, corridor_direction.x)
		if side.length_squared() > 0.0001:
			side = side.normalized()
			var lateral_component := side.dot(movement)
			var sign := signf(lateral_component)
			var preferred_sign := float(entry.get("corridorPreferredLateralSign", 0.0))
			var previous_sign := float(entry.get("corridorLateralSign", 0.0))
			var meaningful_lateral := absf(lateral_component) > NpcConstantsScript.CORRIDOR_OSCILLATION_SIGN_EPSILON
			var recentering_against_preference := meaningful_lateral and absf(preferred_sign) > 0.0 and sign != preferred_sign
			if meaningful_lateral and not recentering_against_preference:
				if absf(previous_sign) > 0.0 and sign != previous_sign:
					entry["corridorOscillationSignChanges"] = int(entry.get("corridorOscillationSignChanges", 0)) + 1
					metrics["oscillationSignChanges"] = int(metrics.get("oscillationSignChanges", 0)) + 1
				entry["corridorLateralSign"] = sign
		var previous_heading: Vector3 = entry.get("corridorLastHeading", Vector3.ZERO)
		if previous_heading.length_squared() > 0.0001 and previous_heading.normalized().dot(movement.normalized()) < -0.25:
			entry["corridorHeadingReversals"] = int(entry.get("corridorHeadingReversals", 0)) + 1
			metrics["headingReversals"] = int(metrics.get("headingReversals", 0)) + 1
		entry["corridorLastHeading"] = movement
	entry["corridorRemainingDistance"] = remaining

func remaining_distance(position: Vector3, path_waypoints: Array) -> float:
	if path_waypoints.is_empty():
		return 0.0
	var total := 0.0
	var last := position
	for waypoint_value in path_waypoints:
		if waypoint_value is Vector3:
			var waypoint: Vector3 = waypoint_value
			total += flat_distance(last, waypoint)
			last = waypoint
	return total

func classify_blocker(reason: String) -> String:
	if reason in ["blocked_static", "blocked_capsule", "terrain_step_rejected", "outside_area"]:
		return "static_collision"
	if reason in ["blocked_dynamic", "static_or_dynamic_collision"]:
		return "dynamic_actor"
	if reason in ["yielding", "cell_reserved", "yield_blocked"]:
		return "traffic_reservation"
	if reason.begins_with("door") or reason in ["closed_door", "locked_unauthorized", "jammed"]:
		return "door_state"
	if reason in ["stale_generation", "stale_corridor"]:
		return "stale_corridor"
	if reason in ["empty_route", "missing_context", "no_forward", "lookahead_close"]:
		return "invalid_goal"
	return "blocked"

func increment_classification(classification: String) -> void:
	if classification == "static_collision":
		metrics["staticBlocks"] = int(metrics.get("staticBlocks", 0)) + 1
	elif classification == "dynamic_actor":
		metrics["dynamicBlocks"] = int(metrics.get("dynamicBlocks", 0)) + 1
	elif classification == "traffic_reservation":
		metrics["trafficWaits"] = int(metrics.get("trafficWaits", 0)) + 1
	elif classification == "door_state":
		metrics["doorWaits"] = int(metrics.get("doorWaits", 0)) + 1
	elif classification == "stale_corridor":
		metrics["staleCorridors"] = int(metrics.get("staleCorridors", 0)) + 1
	elif classification == "invalid_goal":
		metrics["invalidGoals"] = int(metrics.get("invalidGoals", 0)) + 1

func rejected(reason: String, classification: String) -> Dictionary:
	increment_classification(classification)
	return {
		"ok": false,
		"reason": reason,
		"classification": classification,
		"candidate": Vector3.ZERO,
		"desiredVelocity": Vector3.ZERO,
		"safeVelocity": Vector3.ZERO
	}

func stats() -> Dictionary:
	return metrics.duplicate(true)

func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
