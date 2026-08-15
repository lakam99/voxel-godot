extends RefCounted
class_name ReciprocalAvoidanceAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var system: Node = null
var main: Node = null
var frame_index := 0
var physics_frame := -1
var agents_by_actor_id := {}
var safe_velocity_by_actor_id := {}
var safe_velocity_frame_by_actor_id := {}
var safe_velocity_request_key_by_actor_id := {}
var callback_diagnostics_by_actor_id := {}
var submission_diagnostics_by_actor_id := {}
var request_key_changed_frame_by_actor_id := {}
var callback_callable_by_actor_id := {}
var velocity_consumer_by_actor_id := {}
var realized_velocity_state_by_actor_id := {}
var active_actor_ids := {}
var metrics := {
	"activeRegistrations": 0,
	"registeredAgents": 0,
	"computeCalls": 0,
	"callbackHits": 0,
	"callbackDeliveries": 0,
	"realizedVelocityCorrections": 0,
	"staleCallbacks": 0,
	"fallbackPredictions": 0,
	"zeroCallbackFallbacks": 0,
	"freshZeroHolds": 0,
	"deterministicYieldRecoveries": 0,
	"laneBiasFrames": 0,
	"inactiveSkips": 0,
	"portalModeFrames": 0
}

func setup(system_node: Node = null, main_node: Node = null) -> void:
	system = system_node
	main = main_node

func begin_frame() -> void:
	frame_index += 1
	physics_frame = Engine.get_physics_frames()
	active_actor_ids.clear()

func ensure_physics_frame() -> void:
	if physics_frame != Engine.get_physics_frames():
		begin_frame()

func compute_safe_velocity(entry: Dictionary, body: CharacterBody3D, desired_velocity: Vector3, context := {}) -> Dictionary:
	ensure_physics_frame()
	metrics["computeCalls"] = int(metrics.get("computeCalls", 0)) + 1
	var actor_id := actor_id_for(entry, body)
	var profile = context.get("profile")
	var actors: Array = context.get("actors", [])
	var portal_mode := bool(context.get("portalMode", false))
	var corridor_direction: Vector3 = context.get("corridorDirection", Vector3.ZERO)
	corridor_direction.y = 0.0
	if corridor_direction.length_squared() > 0.0001:
		corridor_direction = corridor_direction.normalized()
	var max_speed := maxf(0.0, float(context.get("maxSpeed", desired_velocity.length())))
	if max_speed > 0.0 and desired_velocity.length() > max_speed:
		desired_velocity = desired_velocity.normalized() * max_speed
	if body == null:
		disable_actor(actor_id)
		metrics["inactiveSkips"] = int(metrics.get("inactiveSkips", 0)) + 1
		return result(false, desired_velocity, Vector3.ZERO, "inactive", "missing_body", false, false)
	if bool(entry.get("abstractSimulated", false)) or bool(entry.get("avoidanceDisabled", false)):
		disable_actor(actor_id)
		metrics["inactiveSkips"] = int(metrics.get("inactiveSkips", 0)) + 1
		return result(false, desired_velocity, desired_velocity, "inactive", "abstract_or_disabled", false, false)
	if desired_velocity.length_squared() <= 0.000001:
		velocity_consumer_by_actor_id.erase(actor_id)
		sync_physical_actor(entry, body, Vector3.ZERO, false)
		metrics["inactiveSkips"] = int(metrics.get("inactiveSkips", 0)) + 1
		return result(false, desired_velocity, Vector3.ZERO, "stationary", "no_desired_velocity", false, false)
	if portal_mode:
		metrics["portalModeFrames"] = int(metrics.get("portalModeFrames", 0)) + 1
		disable_actor(actor_id)
		var portal_velocity := project_to_axis(desired_velocity, corridor_direction, NpcConstantsScript.AVOIDANCE_PORTAL_LATERAL_SCALE)
		return result(false, desired_velocity, portal_velocity, "portal", "portal_reservation_authority", false, false)
	var velocity_snapshot: Dictionary = context.get("actorVelocitySnapshot", {}) if context.get("actorVelocitySnapshot", {}) is Dictionary else {}
	var requested_velocity_snapshot: Dictionary = context.get("actorRequestedVelocitySnapshot", {}) if context.get("actorRequestedVelocitySnapshot", {}) is Dictionary else {}
	var relevant_actors := relevant_moving_actors(entry, body, actors, desired_velocity, velocity_snapshot, requested_velocity_snapshot)
	if relevant_actors.is_empty() and not bool(context.get("forceAvoidance", false)):
		disable_actor(actor_id)
		metrics["inactiveSkips"] = int(metrics.get("inactiveSkips", 0)) + 1
		return result(false, desired_velocity, desired_velocity, "inactive", "no_relevant_neighbors", false, false)
	if not context.has("avoidanceTarget") or not (context.get("avoidanceTarget") is Vector3):
		disable_actor(actor_id)
		var invalid := result(false, desired_velocity, Vector3.ZERO, "invalid_config", "missing_avoidance_target", false, false)
		invalid["movementBlocked"] = true
		return invalid

	active_actor_ids[actor_id] = true
	var steering := {
		"preferredVelocity": desired_velocity,
		"active": false,
		"reason": "navigation_avoidance_authority",
		"conflict": {}
	}
	var preferred_velocity := desired_velocity
	var request_key := String(context.get("avoidanceRequestKey", ""))
	var velocity_consumer: Callable = context.get("safeVelocityConsumer", Callable())
	var lane_bias_applied := bool(steering.get("active", false))
	if lane_bias_applied:
		metrics["laneBiasFrames"] = int(metrics.get("laneBiasFrames", 0)) + 1
	var avoidance_priority := float(entry.get("_crowdAvoidancePriority", 0.72))
	var agent: NavigationAgent3D = ensure_agent(actor_id, body, profile, max_speed, avoidance_priority)
	if agent != null:
		apply_agent_profile(agent, profile, max_speed, avoidance_priority)
		configure_agent(agent, body, preferred_velocity, context, request_key, velocity_consumer)

	var safe_velocity := Vector3.ZERO
	var callback_fresh := false
	var fallback_used := false
	if safe_velocity_by_actor_id.has(actor_id):
		var safe_frame := int(safe_velocity_frame_by_actor_id.get(actor_id, -9999))
		callback_fresh = frame_index - safe_frame <= NpcConstantsScript.AVOIDANCE_CALLBACK_STALE_FRAMES \
			and String(safe_velocity_request_key_by_actor_id.get(actor_id, "")) == request_key
		if callback_fresh:
			safe_velocity = safe_velocity_by_actor_id.get(actor_id)
			metrics["callbackHits"] = int(metrics.get("callbackHits", 0)) + 1
	if not callback_fresh:
		if safe_velocity_by_actor_id.has(actor_id):
			metrics["staleCallbacks"] = int(metrics.get("staleCallbacks", 0)) + 1
		safe_velocity = Vector3.ZERO
		fallback_used = true
	elif safe_velocity.length_squared() <= 0.000001 and desired_velocity.length_squared() > 0.000001:
		var zero_frames := int(entry.get("avoidanceFreshZeroFrames", 0)) + 1
		entry["avoidanceFreshZeroFrames"] = zero_frames
		metrics["freshZeroHolds"] = int(metrics.get("freshZeroHolds", 0)) + 1
	else:
		entry["avoidanceFreshZeroFrames"] = 0
	if max_speed > 0.0 and safe_velocity.length() > max_speed:
		safe_velocity = safe_velocity.normalized() * max_speed
	var response := result(true, desired_velocity, safe_velocity, "active", "safe_velocity", callback_fresh, fallback_used)
	response["preferredVelocity"] = preferred_velocity
	response["laneBiasApplied"] = lane_bias_applied
	response["steering"] = steering
	response["encounterActorId"] = _encounter_actor_id(steering, relevant_actors)
	response["selfAvoidancePriority"] = avoidance_priority
	response["encounterAvoidancePriority"] = _encounter_priority(String(response.get("encounterActorId", "")), relevant_actors)
	response["encounterStationary"] = _encounter_stationary(String(response.get("encounterActorId", "")), relevant_actors)
	response["solverAgent"] = agent_diagnostics(actor_id)
	return response


func sync_physical_actor(entry: Dictionary, body: CharacterBody3D, observed_velocity: Vector3, execution_active: bool) -> void:
	ensure_physics_frame()
	if body == null or not is_instance_valid(body):
		return
	var actor_id := actor_id_for(entry, body)
	if bool(entry.get("abstractSimulated", false)) or bool(entry.get("avoidanceDisabled", false)):
		disable_actor(actor_id)
		return
	var profile = entry.get("motorProfile")
	var max_speed := NpcConstantsScript.DEFAULT_NPC_WALK_SPEED
	if profile != null and profile.has_method("get"):
		var walk_speed = profile.get("walk_speed")
		if walk_speed != null:
			max_speed = maxf(max_speed, float(walk_speed))
	var priority := float(entry.get("_crowdAvoidancePriority", 0.72)) if execution_active else 0.95
	var agent: NavigationAgent3D = ensure_agent(actor_id, body, profile, max_speed, priority)
	if agent == null:
		return
	apply_agent_profile(agent, profile, max_speed, priority)
	var velocity_state: Dictionary = realized_velocity_state_by_actor_id.get(actor_id, {}) if realized_velocity_state_by_actor_id.get(actor_id, {}) is Dictionary else {}
	var committed_velocity: Vector3 = body.get_meta("npc_avoidance_committed_velocity", observed_velocity)
	var mismatch := execution_active and committed_velocity.distance_to(observed_velocity) > 0.05
	var entering_stationary := not execution_active and not bool(velocity_state.get("stationary", false))
	var entering_mismatch := mismatch and not bool(velocity_state.get("mismatch", false))
	if entering_stationary or entering_mismatch:
		agent.set_velocity_forced(observed_velocity)
		metrics["realizedVelocityCorrections"] = int(metrics.get("realizedVelocityCorrections", 0)) + 1
	velocity_state["stationary"] = not execution_active
	velocity_state["mismatch"] = mismatch
	realized_velocity_state_by_actor_id[actor_id] = velocity_state
	agent.set("target_position", body.global_position)
	agent.set_meta("npc_avoidance_target", body.global_position)
	agent.set("avoidance_enabled", true)
	if not execution_active:
		var stationary_submission_key := "__stationary__|p%d|f%d" % [Engine.get_physics_frames(), frame_index]
		_bind_velocity_callback(agent, actor_id, stationary_submission_key, "__stationary__", Callable())
		agent.set_meta("npc_avoidance_request_key", "__stationary__")
		agent.set_meta("npc_avoidance_submission_key", stationary_submission_key)
		agent.set("velocity", Vector3.ZERO)
	body.set_meta("npc_avoidance_priority", priority)

func record_safe_velocity(actor_id: String, safe_velocity: Vector3, request_key := "") -> void:
	if actor_id == "":
		return
	safe_velocity_by_actor_id[actor_id] = safe_velocity
	safe_velocity_frame_by_actor_id[actor_id] = frame_index
	safe_velocity_request_key_by_actor_id[actor_id] = request_key

func record_deterministic_yield_recovery() -> void:
	metrics["deterministicYieldRecoveries"] = int(metrics.get("deterministicYieldRecoveries", 0)) + 1

func active_registration_count() -> int:
	return active_actor_ids.size()

func stats() -> Dictionary:
	var copy: Dictionary = metrics.duplicate(true)
	copy["activeRegistrations"] = active_registration_count()
	copy["registeredAgents"] = agents_by_actor_id.size()
	return copy

func cleanup_missing_actors(valid_actor_ids: Array[String]) -> void:
	for actor_id in agents_by_actor_id.keys().duplicate():
		if not valid_actor_ids.has(String(actor_id)):
			disable_actor(String(actor_id), true)

func cleanup_all() -> int:
	var count := agents_by_actor_id.size()
	for actor_id in agents_by_actor_id.keys().duplicate():
		disable_actor(String(actor_id), true)
	return count

func ensure_agent(actor_id: String, body: CharacterBody3D, profile, max_speed: float, priority: float):
	if actor_id == "" or body == null or not is_instance_valid(body):
		return null
	var existing = agents_by_actor_id.get(actor_id)
	if existing != null and is_instance_valid(existing):
		return existing
	if existing != null:
		agents_by_actor_id.erase(actor_id)
		safe_velocity_by_actor_id.erase(actor_id)
		safe_velocity_frame_by_actor_id.erase(actor_id)
		safe_velocity_request_key_by_actor_id.erase(actor_id)
		request_key_changed_frame_by_actor_id.erase(actor_id)
		callback_callable_by_actor_id.erase(actor_id)
		velocity_consumer_by_actor_id.erase(actor_id)
	var agent := NavigationAgent3D.new()
	agent.name = "NpcAvoidanceAgent"
	body.add_child(agent)
	agents_by_actor_id[actor_id] = agent
	metrics["registeredAgents"] = agents_by_actor_id.size()
	apply_agent_profile(agent, profile, max_speed, priority)
	return agent

func configure_agent(agent: NavigationAgent3D, body: CharacterBody3D, desired_velocity: Vector3, context: Dictionary, request_key: String, velocity_consumer: Callable) -> void:
	if agent == null or body == null:
		return
	if context.has("avoidanceTarget"):
		var target: Vector3 = context.get("avoidanceTarget")
		agent.set("target_position", target)
		agent.set_meta("npc_avoidance_target", target)
	var actor_id := actor_id_for({}, body)
	var previous_key := String(agent.get_meta("npc_avoidance_request_key", ""))
	if previous_key != request_key:
		request_key_changed_frame_by_actor_id[actor_id] = frame_index
		safe_velocity_by_actor_id.erase(actor_id)
		safe_velocity_frame_by_actor_id.erase(actor_id)
		safe_velocity_request_key_by_actor_id.erase(actor_id)
	var submission_key := "%s|p%d|f%d" % [request_key, Engine.get_physics_frames(), frame_index]
	_bind_velocity_callback(agent, actor_id, submission_key, request_key, velocity_consumer)
	agent.set("avoidance_enabled", true)
	agent.set_meta("npc_avoidance_request_key", request_key)
	agent.set_meta("npc_avoidance_submission_key", submission_key)
	agent.set("velocity", desired_velocity)
	submission_diagnostics_by_actor_id[actor_id] = {
		"frame": frame_index,
		"physicsFrame": Engine.get_physics_frames(),
		"requestKey": request_key,
		"submissionKey": submission_key,
		"submittedVelocity": desired_velocity
	}


func agent_diagnostics(actor_id: String) -> Dictionary:
	var agent = agents_by_actor_id.get(actor_id)
	if agent == null or not is_instance_valid(agent):
		return {}
	var parent := agent.get_parent() as Node3D
	var node_position := parent.global_position if parent != null else Vector3.ZERO
	var server_position: Vector3 = node_position
	if NavigationServer3D.has_method("agent_get_position"):
		server_position = NavigationServer3D.agent_get_position(agent.get_rid())
	return {
		"nodePosition": node_position,
		"serverPosition": server_position,
		"radius": float(agent.get("radius")),
		"submission": (submission_diagnostics_by_actor_id.get(actor_id, {}) as Dictionary).duplicate(true),
		"callback": (callback_diagnostics_by_actor_id.get(actor_id, {}) as Dictionary).duplicate(true)
	}

func apply_agent_profile(agent: NavigationAgent3D, profile, max_speed: float, priority: float) -> void:
	var radius := NpcConstantsScript.DEFAULT_NPC_RADIUS
	var height := NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
	if profile != null:
		var capsule_radius = profile.get("capsule_radius") if profile.has_method("get") else null
		var body_radius = profile.get("body_radius") if profile.has_method("get") else null
		var capsule_height = profile.get("capsule_height") if profile.has_method("get") else null
		var standing_height = profile.get("standing_height") if profile.has_method("get") else null
		if capsule_radius != null:
			radius = float(capsule_radius)
		elif body_radius != null:
			radius = float(body_radius)
		if capsule_height != null:
			height = float(capsule_height)
		elif standing_height != null:
			height = float(standing_height)
	agent.set("radius", radius + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN)
	agent.set("height", height)
	agent.set("neighbor_distance", NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE)
	agent.set("max_neighbors", NpcConstantsScript.AVOIDANCE_MAX_NEIGHBORS)
	agent.set("time_horizon_agents", NpcConstantsScript.AVOIDANCE_TIME_HORIZON_AGENTS)
	agent.set("time_horizon_obstacles", NpcConstantsScript.AVOIDANCE_TIME_HORIZON_OBSTACLES)
	agent.set("max_speed", maxf(max_speed, NpcConstantsScript.DEFAULT_NPC_WALK_SPEED))
	agent.set("avoidance_priority", clampf(priority, 0.25, 1.0))

func relevant_moving_actors(entry: Dictionary, body: CharacterBody3D, actors: Array, desired_velocity: Vector3, velocity_snapshot := {}, requested_velocity_snapshot := {}) -> Array:
	var relevant: Array = []
	if body == null:
		return relevant
	var self_id := actor_id_for(entry, body)
	for actor in actors:
		var other := actor as Node3D
		if other == null or other == body or not is_instance_valid(other):
			continue
		var other_id := actor_id_for({}, other)
		if other_id == self_id:
			continue
		var offset: Vector3 = other.global_position - body.global_position
		offset.y = 0.0
		var distance := offset.length()
		if distance > NpcConstantsScript.AVOIDANCE_ACTIVE_DISTANCE:
			continue
		var other_velocity := Vector3.ZERO
		if velocity_snapshot is Dictionary and velocity_snapshot.has(other.get_instance_id()):
			other_velocity = velocity_snapshot.get(other.get_instance_id(), Vector3.ZERO)
		elif other.has_meta("npc_applied_velocity"):
			other_velocity = other.get_meta("npc_applied_velocity")
		elif other.has_meta("npc_requested_velocity"):
			other_velocity = other.get_meta("npc_requested_velocity")
		var other_requested_velocity := other_velocity
		if requested_velocity_snapshot is Dictionary and requested_velocity_snapshot.has(other.get_instance_id()):
			other_requested_velocity = requested_velocity_snapshot.get(other.get_instance_id(), other_velocity)
		elif other.has_meta("npc_requested_velocity"):
			other_requested_velocity = other.get_meta("npc_requested_velocity")
		if other_velocity.length_squared() <= 0.0001 and desired_velocity.length_squared() <= 0.0001:
			continue
		relevant.append({
			"actor": other,
			"id": other_id,
			"offset": offset,
			"distance": distance,
			"velocity": other_velocity,
			"requestedVelocity": other_requested_velocity,
			"avoidancePriority": float(other.get_meta("npc_avoidance_priority", 0.72))
		})
	relevant.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	return relevant

func _encounter_actor_id(steering: Dictionary, relevant_actors: Array) -> String:
	var conflict: Dictionary = steering.get("conflict", {}) if steering.get("conflict", {}) is Dictionary else {}
	var conflict_id := String(conflict.get("actorId", ""))
	if conflict_id != "":
		return conflict_id
	var nearest_id := ""
	var nearest_distance := INF
	for actor_info_value in relevant_actors:
		if not (actor_info_value is Dictionary):
			continue
		var actor_info: Dictionary = actor_info_value
		var distance := float(actor_info.get("distance", INF))
		var actor_id := String(actor_info.get("id", ""))
		if distance < nearest_distance or (is_equal_approx(distance, nearest_distance) and actor_id < nearest_id):
			nearest_distance = distance
			nearest_id = actor_id
	return nearest_id

func _encounter_priority(encounter_actor_id: String, relevant_actors: Array) -> float:
	for actor_info_value in relevant_actors:
		if actor_info_value is Dictionary and String((actor_info_value as Dictionary).get("id", "")) == encounter_actor_id:
			return float((actor_info_value as Dictionary).get("avoidancePriority", 0.72))
	return 0.72

func _encounter_stationary(encounter_actor_id: String, relevant_actors: Array) -> bool:
	for actor_info_value in relevant_actors:
		if not (actor_info_value is Dictionary):
			continue
		var actor_info: Dictionary = actor_info_value
		if String(actor_info.get("id", "")) != encounter_actor_id:
			continue
		var velocity: Vector3 = actor_info.get("velocity", Vector3.ZERO)
		var requested: Vector3 = actor_info.get("requestedVelocity", Vector3.ZERO)
		return velocity.length_squared() <= 0.0001 and requested.length_squared() <= 0.0001
	return false

func project_to_axis(velocity: Vector3, axis: Vector3, lateral_scale: float) -> Vector3:
	if axis.length_squared() <= 0.0001:
		return velocity
	axis = axis.normalized()
	var forward_component := axis * velocity.dot(axis)
	var lateral := velocity - forward_component
	return forward_component + lateral * lateral_scale

func disable_actor(actor_id: String, erase := false) -> void:
	if actor_id == "":
		return
	var agent = agents_by_actor_id.get(actor_id)
	if agent != null and is_instance_valid(agent):
		var callback: Callable = callback_callable_by_actor_id.get(actor_id, Callable())
		if callback.is_valid() and agent.velocity_computed.is_connected(callback):
			agent.velocity_computed.disconnect(callback)
		agent.set("avoidance_enabled", false)
		if erase:
			var parent: Node = agent.get_parent() as Node
			if parent != null:
				parent.remove_child(agent)
			agent.free()
	safe_velocity_by_actor_id.erase(actor_id)
	safe_velocity_frame_by_actor_id.erase(actor_id)
	safe_velocity_request_key_by_actor_id.erase(actor_id)
	request_key_changed_frame_by_actor_id.erase(actor_id)
	callback_callable_by_actor_id.erase(actor_id)
	velocity_consumer_by_actor_id.erase(actor_id)
	realized_velocity_state_by_actor_id.erase(actor_id)
	callback_diagnostics_by_actor_id.erase(actor_id)
	submission_diagnostics_by_actor_id.erase(actor_id)
	if erase:
		agents_by_actor_id.erase(actor_id)

func actor_id_for(entry: Dictionary, actor: Node) -> String:
	var id := String(entry.get("id", ""))
	if id != "":
		return id
	if actor != null:
		if actor.has_meta("npc_stable_id"):
			return String(actor.get_meta("npc_stable_id"))
		return "%s:%d" % [actor.name, actor.get_instance_id()]
	return ""

func result(active: bool, desired_velocity: Vector3, safe_velocity: Vector3, status: String, reason: String, callback_fresh: bool, fallback_used: bool) -> Dictionary:
	return {
		"active": active,
		"desiredVelocity": desired_velocity,
		"safeVelocity": safe_velocity,
		"status": status,
		"reason": reason,
		"callbackFresh": callback_fresh,
		"fallbackUsed": fallback_used,
		"activeRegistrationCount": active_registration_count(),
		"frame": frame_index,
		"metrics": stats()
	}

func _bind_velocity_callback(agent: NavigationAgent3D, actor_id: String, submission_key: String, request_key: String, consumer: Callable) -> void:
	if agent == null or not agent.has_signal("velocity_computed"):
		return
	var previous: Callable = callback_callable_by_actor_id.get(actor_id, Callable())
	if previous.is_valid() and agent.velocity_computed.is_connected(previous) and String(agent.get_meta("npc_avoidance_submission_key", "")) == submission_key:
		return
	if previous.is_valid() and agent.velocity_computed.is_connected(previous):
		agent.velocity_computed.disconnect(previous)
	var callback := Callable(self, "_on_velocity_computed").bind(actor_id, submission_key, request_key, consumer)
	agent.velocity_computed.connect(callback)
	callback_callable_by_actor_id[actor_id] = callback


func _on_velocity_computed(safe_velocity: Vector3, actor_id: String, callback_submission_key: String, callback_request_key: String, consumer: Callable) -> void:
	var agent = agents_by_actor_id.get(actor_id)
	var submission_key := String(agent.get_meta("npc_avoidance_submission_key", "")) if agent != null and is_instance_valid(agent) else ""
	if callback_submission_key != submission_key:
		metrics["staleCallbacks"] = int(metrics.get("staleCallbacks", 0)) + 1
		return
	metrics["callbackDeliveries"] = int(metrics.get("callbackDeliveries", 0)) + 1
	callback_diagnostics_by_actor_id[actor_id] = {
		"frame": frame_index,
		"physicsFrame": Engine.get_physics_frames(),
		"requestKey": callback_request_key,
		"submissionKey": callback_submission_key,
		"safeVelocity": safe_velocity
	}
	record_safe_velocity(actor_id, safe_velocity, callback_request_key)
	if consumer.is_valid():
		consumer.call(safe_velocity, callback_request_key)
