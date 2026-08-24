extends RefCounted
class_name NpcCrowdVelocityService

const ReciprocalAvoidanceAdapterScript := preload("res://scripts/npc_ai/movement/ReciprocalAvoidanceAdapter.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var system = null
var main = null
var adapter = null
var active_entries: Array = []
var active_bodies: Array = []
var velocity_snapshot_by_instance_id := {}
var requested_velocity_snapshot_by_instance_id := {}
var bodies_by_spatial_cell := {}
var resolved_actor_ids := {}
var pending_tickets_by_actor_id := {}
var safe_velocity_by_actor_id := {}
var submissions_closed := false
var ticket_metrics := {
	"missingCallbackFrames": 0,
	"missingCallbackTickets": 0,
	"lastMissingCallbackActorIds": [],
	"safetyProjectionFrames": 0,
	"safetyProjectionCorrections": 0,
	"safetyCertificateStops": 0,
	"minimumCertifiedPredictedSeparation": INF
}
var physics_frame := -1
var gather_samples_usec: Array[int] = []
var resolve_samples_usec: Array[int] = []

const MAX_TIMING_SAMPLES := 256


func setup(system_node, main_node) -> void:
	system = system_node
	main = main_node
	adapter = ReciprocalAvoidanceAdapterScript.new()
	adapter.setup(system, main)


func begin_physics_frame(entries: Array) -> void:
	var started_usec := Time.get_ticks_usec()
	if not pending_tickets_by_actor_id.is_empty():
		var missing_actor_ids: Array = pending_tickets_by_actor_id.keys()
		missing_actor_ids.sort()
		ticket_metrics["missingCallbackFrames"] = int(ticket_metrics.get("missingCallbackFrames", 0)) + 1
		ticket_metrics["missingCallbackTickets"] = int(ticket_metrics.get("missingCallbackTickets", 0)) + missing_actor_ids.size()
		ticket_metrics["lastMissingCallbackActorIds"] = missing_actor_ids
		pending_tickets_by_actor_id.clear()
		safe_velocity_by_actor_id.clear()
	physics_frame = Engine.get_physics_frames()
	submissions_closed = false
	active_entries.clear()
	active_bodies.clear()
	velocity_snapshot_by_instance_id.clear()
	requested_velocity_snapshot_by_instance_id.clear()
	bodies_by_spatial_cell.clear()
	resolved_actor_ids.clear()
	var sorted_entries: Array = []
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var body := entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body) or bool(entry.get("abstractSimulated", false)):
			continue
		sorted_entries.append(entry)
	sorted_entries.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left.get("id", "")) < String(right.get("id", ""))
	)
	if adapter != null:
		adapter.begin_frame()
	_assign_deterministic_avoidance_priorities(sorted_entries)
	var valid_actor_ids: Array[String] = []
	for entry in sorted_entries:
		var body := entry.get("body") as CharacterBody3D
		active_entries.append(entry)
		active_bodies.append(body)
		var spatial_cell := _spatial_cell(body.global_position)
		var bucket: Array = bodies_by_spatial_cell.get(spatial_cell, []) if bodies_by_spatial_cell.get(spatial_cell, []) is Array else []
		bucket.append(body)
		bodies_by_spatial_cell[spatial_cell] = bucket
		var lease: Dictionary = entry.get("routeLease", {}) if entry.get("routeLease", {}) is Dictionary else {}
		var execution_active := not lease.is_empty() and String(entry.get("routeStatus", "")) in ["moving", "waiting"]
		var solver_active := execution_active
		var observed_velocity: Vector3 = body.get_meta("npc_applied_velocity", body.velocity) if solver_active else Vector3.ZERO
		var requested_velocity: Vector3 = body.get_meta("npc_requested_velocity", body.velocity) if solver_active else Vector3.ZERO
		velocity_snapshot_by_instance_id[body.get_instance_id()] = observed_velocity
		requested_velocity_snapshot_by_instance_id[body.get_instance_id()] = requested_velocity
		valid_actor_ids.append(String(entry.get("id", body.name)))
		if adapter != null:
			adapter.sync_physical_actor(entry, body, observed_velocity, solver_active)
	if adapter != null:
		adapter.cleanup_missing_actors(valid_actor_ids)
	_record_timing(gather_samples_usec, Time.get_ticks_usec() - started_usec)


func _assign_deterministic_avoidance_priorities(sorted_entries: Array) -> void:
	for entry_value in sorted_entries:
		var entry: Dictionary = entry_value
		var lease: Dictionary = entry.get("routeLease", {}) if entry.get("routeLease", {}) is Dictionary else {}
		var execution_active := not lease.is_empty() and String(entry.get("routeStatus", "")) in ["moving", "waiting"]
		if not execution_active:
			entry["_crowdAvoidancePriority"] = 0.95
			entry["crowdAvoidanceWaitFrames"] = 0
			continue
		var wait_frames := int(entry.get("crowdAvoidanceWaitFrames", 0))
		entry["_crowdAvoidancePriority"] = minf(0.82, 0.50 + float(wait_frames) / 480.0)
		var avoidance: Dictionary = entry.get("routeLeaseAvoidance", {}) if entry.get("routeLeaseAvoidance", {}) is Dictionary else {}
		var reverse_yield: Dictionary = avoidance.get("reverseYield", {}) if avoidance.get("reverseYield", {}) is Dictionary else {}
		var applied: Vector3 = avoidance.get("appliedVelocity", Vector3.ZERO) if avoidance.get("appliedVelocity", Vector3.ZERO) is Vector3 else Vector3.ZERO
		var desired: Vector3 = avoidance.get("desiredVelocity", Vector3.ZERO) if avoidance.get("desiredVelocity", Vector3.ZERO) is Vector3 else Vector3.ZERO
		var making_progress := applied.length_squared() > 0.01 and desired.length_squared() > 0.01 and applied.normalized().dot(desired.normalized()) > 0.2
		var waiting := bool(reverse_yield.get("exhausted", false)) or (bool(avoidance.get("active", false)) and not making_progress)
		entry["crowdAvoidanceWaitFrames"] = wait_frames + 1 if waiting else 0
		var lease_id := String(lease.get("leaseId", entry.get("routineRouteV2RequestId", entry.get("homeRouteV2RequestId", ""))))
		if String(entry.get("_crowdAvoidancePriorityLeaseId", "")) != lease_id:
			entry["_crowdAvoidancePriorityLeaseId"] = lease_id
			entry["_crowdAvoidanceInitialRemaining"] = _remaining_route_distance(entry)


func _remaining_route_distance(entry: Dictionary) -> float:
	var lease: Dictionary = entry.get("routeLease", {}) if entry.get("routeLease", {}) is Dictionary else {}
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	var body := entry.get("body") as CharacterBody3D
	if body == null or waypoints.is_empty():
		return INF
	var index := clampi(int(entry.get("_v2LeaseExecutorWaypointIndex", 0)), 0, waypoints.size() - 1)
	var remaining := body.global_position.distance_to(waypoints[index] as Vector3)
	for waypoint_index in range(index, waypoints.size() - 1):
		remaining += (waypoints[waypoint_index] as Vector3).distance_to(waypoints[waypoint_index + 1] as Vector3)
	return remaining


func begin_frame() -> void:
	if physics_frame == Engine.get_physics_frames():
		return
	var entries: Array = system.get("npcs") if system != null and system.get("npcs") is Array else []
	begin_physics_frame(entries)


func compute_safe_velocity(entry: Dictionary, body: CharacterBody3D, desired_velocity: Vector3, context := {}) -> Dictionary:
	return resolve_safe_velocity(entry, body, desired_velocity, context)


func resolve_safe_velocity(entry: Dictionary, body: CharacterBody3D, desired_velocity: Vector3, context := {}) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	if adapter == null:
		var missing := _inactive_result(Vector3.ZERO, "missing_adapter")
		missing["movementBlocked"] = true
		return missing
	if physics_frame != Engine.get_physics_frames():
		var entries: Array = system.get("npcs") if system != null and system.get("npcs") is Array else []
		begin_physics_frame(entries)
	var request: Dictionary = context.duplicate(true)
	var actor_id := String(entry.get("id", body.name if body != null else ""))
	resolved_actor_ids[actor_id] = true
	request["actors"] = _nearby_bodies(body)
	request["actorVelocitySnapshot"] = velocity_snapshot_by_instance_id
	request["actorRequestedVelocitySnapshot"] = requested_velocity_snapshot_by_instance_id
	var external_consumer: Callable = request.get("safeVelocityConsumer", Callable())
	var request_key := String(request.get("avoidanceRequestKey", ""))
	pending_tickets_by_actor_id[actor_id] = {
		"actorId": actor_id,
		"physicsFrame": physics_frame,
		"requestKey": request_key,
		"consumer": external_consumer,
		"velocityFilter": request.get("safeVelocityFilter", Callable()),
		"body": body,
		"radius": _avoidance_radius(entry),
		"priority": float(entry.get("_crowdAvoidancePriority", 0.72)),
		"desiredVelocity": desired_velocity,
		"maxSpeed": maxf(0.0, float(request.get("maxSpeed", desired_velocity.length()))),
		"physicsDelta": maxf(0.001, float(request.get("physicsDelta", 1.0 / 60.0))),
		"neighborActorIds": _actor_ids_for_bodies(request.get("actors", []))
	}
	request["safeVelocityConsumer"] = Callable(self, "_receive_safe_velocity").bind(actor_id, physics_frame)
	var result: Dictionary = adapter.compute_safe_velocity(entry, body, desired_velocity, request)
	if not bool(result.get("active", false)):
		pending_tickets_by_actor_id.erase(actor_id)
	result["crowdPhysicsFrame"] = physics_frame
	result["crowdActorCount"] = active_bodies.size()
	_record_timing(resolve_samples_usec, Time.get_ticks_usec() - started_usec)
	return result


func end_physics_frame() -> void:
	if adapter == null:
		return
	for entry_value in active_entries:
		var entry: Dictionary = entry_value
		var body := entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var actor_id := String(entry.get("id", body.name))
		var lease: Dictionary = entry.get("routeLease", {}) if entry.get("routeLease", {}) is Dictionary else {}
		var execution_active := not lease.is_empty() and String(entry.get("routeStatus", "")) in ["moving", "waiting"]
		if not execution_active:
			adapter.sync_physical_actor(entry, body, Vector3.ZERO, false)
	submissions_closed = true
	_commit_ready_tickets()


func _receive_safe_velocity(safe_velocity: Vector3, callback_request_key: String, actor_id: String, ticket_physics_frame: int) -> void:
	var ticket: Dictionary = pending_tickets_by_actor_id.get(actor_id, {}) if pending_tickets_by_actor_id.get(actor_id, {}) is Dictionary else {}
	if ticket.is_empty() or ticket_physics_frame != physics_frame:
		return
	if String(ticket.get("requestKey", "")) != callback_request_key:
		return
	var velocity_filter: Callable = ticket.get("velocityFilter", Callable())
	if velocity_filter.is_valid():
		safe_velocity = velocity_filter.call(safe_velocity)
	safe_velocity_by_actor_id[actor_id] = safe_velocity
	_commit_ready_tickets()


func _commit_ready_tickets() -> void:
	if not submissions_closed or pending_tickets_by_actor_id.is_empty():
		return
	for component_value in _pending_ticket_components():
		var component: Array = component_value
		var ready := true
		for actor_id_value in component:
			if not safe_velocity_by_actor_id.has(String(actor_id_value)):
				ready = false
				break
		if not ready:
			continue
		component.sort()
		var certified_velocities := _certify_component_velocities(component)
		for actor_id_value in component:
			var actor_id := String(actor_id_value)
			var ticket: Dictionary = pending_tickets_by_actor_id.get(actor_id, {})
			var consumer: Callable = ticket.get("consumer", Callable())
			if consumer.is_valid():
				consumer.call(certified_velocities.get(actor_id, Vector3.ZERO), String(ticket.get("requestKey", "")))
			pending_tickets_by_actor_id.erase(actor_id)
			safe_velocity_by_actor_id.erase(actor_id)


func _certify_component_velocities(component: Array) -> Dictionary:
	var certified := {}
	var reset_to_desired := {}
	for actor_id_value in component:
		var actor_id := String(actor_id_value)
		certified[actor_id] = safe_velocity_by_actor_id.get(actor_id, Vector3.ZERO)
	var corrections := 0
	for _iteration in range(16):
		_clamp_component_velocities(component, certified)
		var changed := false
		for left_index in range(component.size()):
			var left_id := String(component[left_index])
			var left_ticket: Dictionary = pending_tickets_by_actor_id.get(left_id, {})
			var left_body := left_ticket.get("body") as CharacterBody3D
			if left_body == null or not is_instance_valid(left_body):
				continue
			for right_index in range(left_index + 1, component.size()):
				var right_id := String(component[right_index])
				var right_ticket: Dictionary = pending_tickets_by_actor_id.get(right_id, {})
				var right_body := right_ticket.get("body") as CharacterBody3D
				if right_body == null or not is_instance_valid(right_body):
					continue
				var offset := right_body.global_position - left_body.global_position
				offset.y = 0.0
				var distance := offset.length()
				if distance <= 0.0001:
					continue
				var required := float(left_ticket.get("radius", 0.0)) + float(right_ticket.get("radius", 0.0))
				if distance > required + NpcConstantsScript.DEFAULT_NPC_WALK_SPEED * 0.2:
					continue
				var delta := minf(float(left_ticket.get("physicsDelta", 1.0 / 60.0)), float(right_ticket.get("physicsDelta", 1.0 / 60.0)))
				var normal := offset / distance
				var left_velocity: Vector3 = certified.get(left_id, Vector3.ZERO)
				var right_velocity: Vector3 = certified.get(right_id, Vector3.ZERO)
				var required_rate := (required - distance) / delta
				var relative_rate := normal.dot(right_velocity - left_velocity)
				if relative_rate + 0.0001 >= required_rate:
					continue
				if not reset_to_desired.has(left_id):
					left_velocity = left_ticket.get("desiredVelocity", left_velocity)
					reset_to_desired[left_id] = true
				if not reset_to_desired.has(right_id):
					right_velocity = right_ticket.get("desiredVelocity", right_velocity)
					reset_to_desired[right_id] = true
				relative_rate = normal.dot(right_velocity - left_velocity)
				if relative_rate + 0.0001 >= required_rate:
					certified[left_id] = left_velocity
					certified[right_id] = right_velocity
					corrections += 1
					changed = true
					continue
				var correction_rate := required_rate - relative_rate
				var left_priority := maxf(0.01, float(left_ticket.get("priority", 0.72)))
				var right_priority := maxf(0.01, float(right_ticket.get("priority", 0.72)))
				var priority_sum := left_priority + right_priority
				left_velocity -= normal * correction_rate * (right_priority / priority_sum)
				right_velocity += normal * correction_rate * (left_priority / priority_sum)
				certified[left_id] = left_velocity
				certified[right_id] = right_velocity
				corrections += 1
				changed = true
		var external_corrections := _certify_against_external_actors(component, certified, reset_to_desired)
		if external_corrections > 0:
			corrections += external_corrections
			changed = true
		if not changed:
			break
	if corrections > 0:
		ticket_metrics["safetyProjectionFrames"] = int(ticket_metrics.get("safetyProjectionFrames", 0)) + 1
		ticket_metrics["safetyProjectionCorrections"] = int(ticket_metrics.get("safetyProjectionCorrections", 0)) + corrections
	certified = _bound_and_validate_component(component, certified)
	_record_certified_minimum(component, certified)
	return certified


func _bound_and_validate_component(component: Array, certified: Dictionary) -> Dictionary:
	_clamp_component_velocities(component, certified)
	if _component_prediction_is_safe(component, certified):
		return certified
	for _iteration in range(8):
		_project_internal_constraints_once(component, certified)
		_project_external_constraints_once(component, certified)
		_clamp_component_velocities(component, certified)
		if _component_prediction_is_safe(component, certified):
			return certified
	for actor_id_value in component:
		certified[String(actor_id_value)] = Vector3.ZERO
	ticket_metrics["safetyCertificateStops"] = int(ticket_metrics.get("safetyCertificateStops", 0)) + 1
	return certified


func _clamp_component_velocities(component: Array, certified: Dictionary) -> void:
	for actor_id_value in component:
		var actor_id := String(actor_id_value)
		var ticket: Dictionary = pending_tickets_by_actor_id.get(actor_id, {})
		var velocity: Vector3 = certified.get(actor_id, Vector3.ZERO)
		var max_speed := maxf(0.0, float(ticket.get("maxSpeed", velocity.length())))
		if max_speed > 0.0 and velocity.length() > max_speed:
			certified[actor_id] = velocity.normalized() * max_speed


func _project_internal_constraints_once(component: Array, certified: Dictionary) -> void:
	for left_index in range(component.size()):
		var left_id := String(component[left_index])
		var left_ticket: Dictionary = pending_tickets_by_actor_id.get(left_id, {})
		var left_body := left_ticket.get("body") as CharacterBody3D
		if left_body == null or not is_instance_valid(left_body):
			continue
		for right_index in range(left_index + 1, component.size()):
			var right_id := String(component[right_index])
			var right_ticket: Dictionary = pending_tickets_by_actor_id.get(right_id, {})
			var right_body := right_ticket.get("body") as CharacterBody3D
			if right_body == null or not is_instance_valid(right_body):
				continue
			var offset := right_body.global_position - left_body.global_position
			offset.y = 0.0
			var distance := offset.length()
			if distance <= 0.0001:
				continue
			var required := float(left_ticket.get("radius", 0.0)) + float(right_ticket.get("radius", 0.0))
			if distance > required + NpcConstantsScript.DEFAULT_NPC_WALK_SPEED * 0.2:
				continue
			var delta := minf(float(left_ticket.get("physicsDelta", 1.0 / 60.0)), float(right_ticket.get("physicsDelta", 1.0 / 60.0)))
			var normal := offset / distance
			var left_velocity: Vector3 = certified.get(left_id, Vector3.ZERO)
			var right_velocity: Vector3 = certified.get(right_id, Vector3.ZERO)
			var required_rate := (required - distance) / delta
			var relative_rate := normal.dot(right_velocity - left_velocity)
			if relative_rate >= required_rate:
				continue
			var correction_rate := required_rate - relative_rate
			left_velocity -= normal * correction_rate * 0.5
			right_velocity += normal * correction_rate * 0.5
			certified[left_id] = left_velocity
			certified[right_id] = right_velocity


func _project_external_constraints_once(component: Array, certified: Dictionary) -> void:
	for actor_id_value in component:
		var actor_id := String(actor_id_value)
		var ticket: Dictionary = pending_tickets_by_actor_id.get(actor_id, {})
		var body := ticket.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		for other_entry_value in active_entries:
			var other_entry: Dictionary = other_entry_value
			var other_body := other_entry.get("body") as CharacterBody3D
			if other_body == null or not is_instance_valid(other_body) or other_body == body or component.has(String(other_entry.get("id", other_body.name))):
				continue
			var offset := other_body.global_position - body.global_position
			offset.y = 0.0
			var distance := offset.length()
			if distance <= 0.0001:
				continue
			var required := float(ticket.get("radius", 0.0)) + _avoidance_radius(other_entry)
			if distance > required + NpcConstantsScript.DEFAULT_NPC_WALK_SPEED * 0.2:
				continue
			var delta := float(ticket.get("physicsDelta", 1.0 / 60.0))
			var normal := offset / distance
			var velocity: Vector3 = certified.get(actor_id, Vector3.ZERO)
			var other_velocity: Vector3 = velocity_snapshot_by_instance_id.get(other_body.get_instance_id(), Vector3.ZERO)
			var required_rate := (required - distance) / delta
			var relative_rate := normal.dot(other_velocity - velocity)
			if relative_rate < required_rate:
				certified[actor_id] = velocity - normal * (required_rate - relative_rate)


func _component_prediction_is_safe(component: Array, velocities: Dictionary) -> bool:
	var component_ids := {}
	for actor_id_value in component:
		component_ids[String(actor_id_value)] = true
	for left_index in range(component.size()):
		var left_id := String(component[left_index])
		var left_ticket: Dictionary = pending_tickets_by_actor_id.get(left_id, {})
		var left_body := left_ticket.get("body") as CharacterBody3D
		if left_body == null or not is_instance_valid(left_body):
			continue
		var delta := float(left_ticket.get("physicsDelta", 1.0 / 60.0))
		var left_next := left_body.global_position + (velocities.get(left_id, Vector3.ZERO) as Vector3) * delta
		for right_index in range(left_index + 1, component.size()):
			var right_id := String(component[right_index])
			var right_ticket: Dictionary = pending_tickets_by_actor_id.get(right_id, {})
			var right_body := right_ticket.get("body") as CharacterBody3D
			if right_body == null or not is_instance_valid(right_body):
				continue
			var right_delta := float(right_ticket.get("physicsDelta", delta))
			var right_next := right_body.global_position + (velocities.get(right_id, Vector3.ZERO) as Vector3) * right_delta
			var required := float(left_ticket.get("radius", 0.0)) + float(right_ticket.get("radius", 0.0))
			var current_distance := Vector2(left_body.global_position.x - right_body.global_position.x, left_body.global_position.z - right_body.global_position.z).length()
			var minimum_allowed := minf(required, current_distance)
			if Vector2(left_next.x - right_next.x, left_next.z - right_next.z).length() + 0.0001 < minimum_allowed:
				return false
		for other_entry_value in active_entries:
			var other_entry: Dictionary = other_entry_value
			var other_body := other_entry.get("body") as CharacterBody3D
			if other_body == null or not is_instance_valid(other_body) or other_body == left_body:
				continue
			var other_id := String(other_entry.get("id", other_body.name))
			if component_ids.has(other_id):
				continue
			var other_velocity: Vector3 = velocity_snapshot_by_instance_id.get(other_body.get_instance_id(), Vector3.ZERO)
			var other_next := other_body.global_position + other_velocity * delta
			var required := float(left_ticket.get("radius", 0.0)) + _avoidance_radius(other_entry)
			var current_distance := Vector2(left_body.global_position.x - other_body.global_position.x, left_body.global_position.z - other_body.global_position.z).length()
			var minimum_allowed := minf(required, current_distance)
			if Vector2(left_next.x - other_next.x, left_next.z - other_next.z).length() + 0.0001 < minimum_allowed:
				return false
	return true


func _certify_against_external_actors(component: Array, certified: Dictionary, reset_to_desired: Dictionary) -> int:
	var component_ids := {}
	for actor_id_value in component:
		component_ids[String(actor_id_value)] = true
	var corrections := 0
	for actor_id_value in component:
		var actor_id := String(actor_id_value)
		var ticket: Dictionary = pending_tickets_by_actor_id.get(actor_id, {})
		var body := ticket.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		for other_entry_value in active_entries:
			var other_entry: Dictionary = other_entry_value
			var other_body := other_entry.get("body") as CharacterBody3D
			if other_body == null or not is_instance_valid(other_body) or other_body == body:
				continue
			var other_id := String(other_entry.get("id", other_body.name))
			if component_ids.has(other_id):
				continue
			var offset := other_body.global_position - body.global_position
			offset.y = 0.0
			var distance := offset.length()
			if distance <= 0.0001:
				continue
			var required := float(ticket.get("radius", 0.0)) + _avoidance_radius(other_entry)
			if distance > required + NpcConstantsScript.DEFAULT_NPC_WALK_SPEED * 0.2:
				continue
			var delta := float(ticket.get("physicsDelta", 1.0 / 60.0))
			var normal := offset / distance
			var velocity: Vector3 = certified.get(actor_id, Vector3.ZERO)
			var other_velocity: Vector3 = velocity_snapshot_by_instance_id.get(other_body.get_instance_id(), Vector3.ZERO)
			var required_rate := (required - distance) / delta
			var relative_rate := normal.dot(other_velocity - velocity)
			if relative_rate + 0.0001 >= required_rate:
				continue
			if not reset_to_desired.has(actor_id):
				velocity = ticket.get("desiredVelocity", velocity)
				reset_to_desired[actor_id] = true
				relative_rate = normal.dot(other_velocity - velocity)
			if relative_rate + 0.0001 >= required_rate:
				certified[actor_id] = velocity
				corrections += 1
				continue
			velocity -= normal * (required_rate - relative_rate)
			certified[actor_id] = velocity
			corrections += 1
	return corrections


func _record_certified_minimum(component: Array, velocities: Dictionary) -> void:
	for left_index in range(component.size()):
		var left_id := String(component[left_index])
		var left_ticket: Dictionary = pending_tickets_by_actor_id.get(left_id, {})
		var left_body := left_ticket.get("body") as CharacterBody3D
		if left_body == null or not is_instance_valid(left_body):
			continue
		for right_index in range(left_index + 1, component.size()):
			var right_id := String(component[right_index])
			var right_ticket: Dictionary = pending_tickets_by_actor_id.get(right_id, {})
			var right_body := right_ticket.get("body") as CharacterBody3D
			if right_body == null or not is_instance_valid(right_body):
				continue
			var delta := minf(float(left_ticket.get("physicsDelta", 1.0 / 60.0)), float(right_ticket.get("physicsDelta", 1.0 / 60.0)))
			var left_next := left_body.global_position + (velocities.get(left_id, Vector3.ZERO) as Vector3) * delta
			var right_next := right_body.global_position + (velocities.get(right_id, Vector3.ZERO) as Vector3) * delta
			var predicted := Vector2(left_next.x - right_next.x, left_next.z - right_next.z).length()
			ticket_metrics["minimumCertifiedPredictedSeparation"] = minf(float(ticket_metrics.get("minimumCertifiedPredictedSeparation", INF)), predicted)


func _avoidance_radius(entry: Dictionary) -> float:
	var profile = entry.get("motorProfile")
	var radius := NpcConstantsScript.DEFAULT_NPC_RADIUS
	if profile != null and profile.has_method("get"):
		var capsule_radius = profile.get("capsule_radius")
		if capsule_radius != null:
			radius = float(capsule_radius)
	return radius + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN


func _pending_ticket_components() -> Array:
	var components: Array = []
	var unvisited: Dictionary = pending_tickets_by_actor_id.duplicate()
	var sorted_ids: Array = unvisited.keys()
	sorted_ids.sort()
	for start_value in sorted_ids:
		var start_id := String(start_value)
		if not unvisited.has(start_id):
			continue
		var component: Array = []
		var frontier: Array = [start_id]
		unvisited.erase(start_id)
		while not frontier.is_empty():
			var actor_id := String(frontier.pop_front())
			component.append(actor_id)
			var ticket: Dictionary = pending_tickets_by_actor_id.get(actor_id, {})
			for neighbor_value in ticket.get("neighborActorIds", []):
				var neighbor_id := String(neighbor_value)
				if unvisited.has(neighbor_id):
					unvisited.erase(neighbor_id)
					frontier.append(neighbor_id)
		components.append(component)
	return components


func _actor_ids_for_bodies(bodies_value) -> Array:
	var actor_ids: Array = []
	if not (bodies_value is Array):
		return actor_ids
	for body_value in bodies_value:
		var body := body_value as Node
		if body == null:
			continue
		var actor_id := String(body.get_meta("npc_stable_id", body.name))
		if actor_id != "":
			actor_ids.append(actor_id)
	actor_ids.sort()
	return actor_ids


func _spatial_cell(position: Vector3) -> Vector2i:
	var cell_size := maxf(0.5, NpcConstantsScript.AVOIDANCE_ACTIVE_DISTANCE)
	return Vector2i(floori(position.x / cell_size), floori(position.z / cell_size))


func _nearby_bodies(body: CharacterBody3D) -> Array:
	if body == null:
		return []
	var center := _spatial_cell(body.global_position)
	var nearby: Array = []
	for x_offset in range(-1, 2):
		for z_offset in range(-1, 2):
			var bucket_value = bodies_by_spatial_cell.get(center + Vector2i(x_offset, z_offset), [])
			if bucket_value is Array:
				for candidate_value in bucket_value:
					var candidate := candidate_value as CharacterBody3D
					if candidate == null or candidate == body:
						continue
					var offset := candidate.global_position - body.global_position
					offset.y = 0.0
					if offset.length() <= NpcConstantsScript.AVOIDANCE_ACTIVE_DISTANCE:
						nearby.append(candidate)
	return nearby


func disable_actor(actor_id: String, erase := false) -> void:
	if adapter != null:
		adapter.disable_actor(actor_id, erase)


func record_deterministic_yield_recovery() -> void:
	if adapter != null and adapter.has_method("record_deterministic_yield_recovery"):
		adapter.record_deterministic_yield_recovery()


func clear() -> void:
	if adapter != null:
		adapter.cleanup_all()
	active_entries.clear()
	active_bodies.clear()
	velocity_snapshot_by_instance_id.clear()
	requested_velocity_snapshot_by_instance_id.clear()
	bodies_by_spatial_cell.clear()
	resolved_actor_ids.clear()
	pending_tickets_by_actor_id.clear()
	safe_velocity_by_actor_id.clear()
	submissions_closed = false
	physics_frame = -1
	gather_samples_usec.clear()
	resolve_samples_usec.clear()


func cleanup_all() -> int:
	var count: int = int(adapter.cleanup_all()) if adapter != null else 0
	active_entries.clear()
	active_bodies.clear()
	velocity_snapshot_by_instance_id.clear()
	requested_velocity_snapshot_by_instance_id.clear()
	bodies_by_spatial_cell.clear()
	resolved_actor_ids.clear()
	pending_tickets_by_actor_id.clear()
	safe_velocity_by_actor_id.clear()
	submissions_closed = false
	physics_frame = -1
	gather_samples_usec.clear()
	resolve_samples_usec.clear()
	return count


func stats() -> Dictionary:
	var result: Dictionary = adapter.stats() if adapter != null else {}
	result["crowdPhysicsFrame"] = physics_frame
	result["crowdActorCount"] = active_bodies.size()
	result["timing"] = {
		"gather": _timing_summary(gather_samples_usec),
		"resolve": _timing_summary(resolve_samples_usec)
	}
	result["tickets"] = ticket_metrics.duplicate(true)
	return result


func _record_timing(samples: Array[int], elapsed_usec: int) -> void:
	samples.append(maxi(0, elapsed_usec))
	if samples.size() > MAX_TIMING_SAMPLES:
		samples.pop_front()


func _timing_summary(samples: Array[int]) -> Dictionary:
	if samples.is_empty():
		return { "sampleCount": 0, "p50Ms": 0.0, "p95Ms": 0.0, "maxMs": 0.0 }
	var sorted := samples.duplicate()
	sorted.sort()
	var p50_index := clampi(ceili(float(sorted.size()) * 0.50) - 1, 0, sorted.size() - 1)
	var p95_index := clampi(ceili(float(sorted.size()) * 0.95) - 1, 0, sorted.size() - 1)
	return {
		"sampleCount": sorted.size(),
		"p50Ms": float(sorted[p50_index]) / 1000.0,
		"p95Ms": float(sorted[p95_index]) / 1000.0,
		"maxMs": float(sorted[sorted.size() - 1]) / 1000.0
	}


func _inactive_result(desired_velocity: Vector3, reason: String) -> Dictionary:
	return {
		"active": false,
		"safeVelocity": desired_velocity,
		"status": "inactive",
		"reason": reason,
		"callbackFresh": false,
		"fallbackUsed": true,
		"activeRegistrationCount": 0,
		"crowdPhysicsFrame": physics_frame,
		"crowdActorCount": active_bodies.size()
	}
