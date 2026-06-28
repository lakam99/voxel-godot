extends RefCounted
class_name ReciprocalAvoidanceAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var system: Node = null
var main: Node = null
var frame_index := 0
var agents_by_actor_id := {}
var safe_velocity_by_actor_id := {}
var safe_velocity_frame_by_actor_id := {}
var active_actor_ids := {}
var metrics := {
	"activeRegistrations": 0,
	"registeredAgents": 0,
	"computeCalls": 0,
	"callbackHits": 0,
	"staleCallbacks": 0,
	"fallbackPredictions": 0,
	"zeroCallbackFallbacks": 0,
	"inactiveSkips": 0,
	"portalModeFrames": 0
}

func setup(system_node: Node = null, main_node: Node = null) -> void:
	system = system_node
	main = main_node

func begin_frame() -> void:
	frame_index += 1
	active_actor_ids.clear()

func compute_safe_velocity(entry: Dictionary, body: CharacterBody3D, desired_velocity: Vector3, context := {}) -> Dictionary:
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
	if body == null or desired_velocity.length_squared() <= 0.000001:
		disable_actor(actor_id)
		metrics["inactiveSkips"] = int(metrics.get("inactiveSkips", 0)) + 1
		return result(false, desired_velocity, Vector3.ZERO, "inactive", "no_desired_velocity", false, false)
	if bool(entry.get("abstractSimulated", false)) or bool(entry.get("avoidanceDisabled", false)):
		disable_actor(actor_id)
		metrics["inactiveSkips"] = int(metrics.get("inactiveSkips", 0)) + 1
		return result(false, desired_velocity, desired_velocity, "inactive", "abstract_or_disabled", false, false)
	if portal_mode:
		metrics["portalModeFrames"] = int(metrics.get("portalModeFrames", 0)) + 1
		disable_actor(actor_id)
		var portal_velocity := project_to_axis(desired_velocity, corridor_direction, NpcConstantsScript.AVOIDANCE_PORTAL_LATERAL_SCALE)
		return result(false, desired_velocity, portal_velocity, "portal", "portal_reservation_authority", false, false)
	var relevant_actors := relevant_moving_actors(entry, body, actors, desired_velocity)
	if relevant_actors.is_empty() and not bool(context.get("forceAvoidance", false)):
		disable_actor(actor_id)
		metrics["inactiveSkips"] = int(metrics.get("inactiveSkips", 0)) + 1
		return result(false, desired_velocity, desired_velocity, "inactive", "no_relevant_neighbors", false, false)

	active_actor_ids[actor_id] = true
	var agent: NavigationAgent3D = ensure_agent(actor_id, body, profile, max_speed, int(context.get("priority", 0)))
	if agent != null:
		configure_agent(agent, body, desired_velocity, context)

	var safe_velocity := Vector3.ZERO
	var callback_fresh := false
	var fallback_used := false
	if safe_velocity_by_actor_id.has(actor_id):
		var safe_frame := int(safe_velocity_frame_by_actor_id.get(actor_id, -9999))
		callback_fresh = frame_index - safe_frame <= NpcConstantsScript.AVOIDANCE_CALLBACK_STALE_FRAMES
		if callback_fresh:
			safe_velocity = safe_velocity_by_actor_id.get(actor_id)
			metrics["callbackHits"] = int(metrics.get("callbackHits", 0)) + 1
	if not callback_fresh:
		if safe_velocity_by_actor_id.has(actor_id):
			metrics["staleCallbacks"] = int(metrics.get("staleCallbacks", 0)) + 1
		safe_velocity = predictive_velocity(entry, body, desired_velocity, relevant_actors, corridor_direction, max_speed)
		fallback_used = true
		metrics["fallbackPredictions"] = int(metrics.get("fallbackPredictions", 0)) + 1
	elif safe_velocity.length_squared() <= 0.000001 and desired_velocity.length_squared() > 0.000001:
		var predicted_velocity := predictive_velocity(entry, body, desired_velocity, relevant_actors, corridor_direction, max_speed)
		if predicted_velocity.length_squared() > 0.000001:
			safe_velocity = predicted_velocity
			callback_fresh = false
			fallback_used = true
			metrics["fallbackPredictions"] = int(metrics.get("fallbackPredictions", 0)) + 1
			metrics["zeroCallbackFallbacks"] = int(metrics.get("zeroCallbackFallbacks", 0)) + 1
	if max_speed > 0.0 and safe_velocity.length() > max_speed:
		safe_velocity = safe_velocity.normalized() * max_speed
	return result(true, desired_velocity, safe_velocity, "active", "safe_velocity", callback_fresh, fallback_used)

func record_safe_velocity(actor_id: String, safe_velocity: Vector3) -> void:
	if actor_id == "":
		return
	safe_velocity_by_actor_id[actor_id] = safe_velocity
	safe_velocity_frame_by_actor_id[actor_id] = frame_index

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

func ensure_agent(actor_id: String, body: CharacterBody3D, profile, max_speed: float, priority: int):
	if actor_id == "" or body == null or not is_instance_valid(body):
		return null
	var existing = agents_by_actor_id.get(actor_id)
	if existing != null and is_instance_valid(existing):
		return existing
	var agent := NavigationAgent3D.new()
	agent.name = "NpcAvoidanceAgent"
	agent.set_process(false)
	agent.set_physics_process(false)
	body.add_child(agent)
	agents_by_actor_id[actor_id] = agent
	metrics["registeredAgents"] = agents_by_actor_id.size()
	if agent.has_signal("velocity_computed"):
		agent.velocity_computed.connect(Callable(self, "_on_velocity_computed").bind(actor_id))
	apply_agent_profile(agent, profile, max_speed, priority)
	return agent

func configure_agent(agent: NavigationAgent3D, body: CharacterBody3D, desired_velocity: Vector3, context: Dictionary) -> void:
	if agent == null or body == null:
		return
	agent.set("avoidance_enabled", true)
	agent.set("velocity", desired_velocity)
	if context.has("avoidanceTarget"):
		var target: Vector3 = context.get("avoidanceTarget")
		agent.set_meta("npc_avoidance_target", target)

func apply_agent_profile(agent: NavigationAgent3D, profile, max_speed: float, priority: int) -> void:
	var radius := NpcConstantsScript.DEFAULT_NPC_RADIUS
	var height := NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
	if profile != null:
		radius = float(profile.get("body_radius")) if profile.has_method("get") and profile.get("body_radius") != null else radius
		height = float(profile.get("standing_height")) if profile.has_method("get") and profile.get("standing_height") != null else height
	agent.set("radius", radius + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN)
	agent.set("height", height)
	agent.set("neighbor_distance", NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE)
	agent.set("max_neighbors", NpcConstantsScript.AVOIDANCE_MAX_NEIGHBORS)
	agent.set("time_horizon_agents", NpcConstantsScript.AVOIDANCE_TIME_HORIZON_AGENTS)
	agent.set("time_horizon_obstacles", NpcConstantsScript.AVOIDANCE_TIME_HORIZON_OBSTACLES)
	agent.set("max_speed", maxf(max_speed, NpcConstantsScript.DEFAULT_NPC_WALK_SPEED))
	agent.set("avoidance_priority", clampf(0.5 + float(priority) * 0.05, 0.1, 1.0))

func relevant_moving_actors(entry: Dictionary, body: CharacterBody3D, actors: Array, desired_velocity: Vector3) -> Array:
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
		if other.has_meta("npc_applied_velocity"):
			other_velocity = other.get_meta("npc_applied_velocity")
		elif other.has_meta("npc_requested_velocity"):
			other_velocity = other.get_meta("npc_requested_velocity")
		if other_velocity.length_squared() <= 0.0001 and desired_velocity.length_squared() <= 0.0001:
			continue
		relevant.append({
			"actor": other,
			"id": other_id,
			"offset": offset,
			"distance": distance,
			"velocity": other_velocity
		})
	relevant.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	return relevant

func predictive_velocity(entry: Dictionary, body: CharacterBody3D, desired_velocity: Vector3, relevant_actors: Array, corridor_direction: Vector3, max_speed: float) -> Vector3:
	var adjusted := desired_velocity
	if desired_velocity.length_squared() <= 0.0001:
		return Vector3.ZERO
	var forward := desired_velocity.normalized()
	var side := Vector3(-forward.z, 0.0, forward.x)
	var self_id := actor_id_for(entry, body)
	for actor_info in relevant_actors:
		var offset: Vector3 = actor_info.get("offset", Vector3.ZERO)
		var distance := maxf(0.001, float(actor_info.get("distance", offset.length())))
		var other_velocity: Vector3 = actor_info.get("velocity", Vector3.ZERO)
		other_velocity.y = 0.0
		var closing_speed := (desired_velocity - other_velocity).dot(offset.normalized())
		var ahead := forward.dot(offset.normalized()) > -0.2
		if not ahead or closing_speed <= 0.01:
			continue
		var time_to_conflict := distance / closing_speed
		if time_to_conflict > NpcConstantsScript.AVOIDANCE_TIME_HORIZON_AGENTS:
			continue
		var other_id := String(actor_info.get("id", ""))
		var sign := pair_side_sign(self_id, other_id)
		var urgency := clampf(1.0 - time_to_conflict / NpcConstantsScript.AVOIDANCE_TIME_HORIZON_AGENTS, 0.0, 1.0)
		adjusted += side * sign * desired_velocity.length() * (0.35 + 0.45 * urgency)
	if corridor_direction.length_squared() > 0.0001:
		adjusted = project_to_axis(adjusted, corridor_direction, 1.0)
	if max_speed > 0.0 and adjusted.length() > max_speed:
		adjusted = adjusted.normalized() * max_speed
	return adjusted

func pair_side_sign(a: String, b: String) -> float:
	var first := a if a < b else b
	var second := b if a < b else a
	var value := 2166136261
	var text := "%s|%s" % [first, second]
	for i in range(text.length()):
		value = int((value ^ text.unicode_at(i)) * 16777619) & 0x7fffffff
	return 1.0 if (value & 1) == 0 else -1.0

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
		agent.set("avoidance_enabled", false)
		if erase:
			var parent: Node = agent.get_parent() as Node
			if parent != null:
				parent.remove_child(agent)
			agent.free()
	if erase:
		agents_by_actor_id.erase(actor_id)
		safe_velocity_by_actor_id.erase(actor_id)
		safe_velocity_frame_by_actor_id.erase(actor_id)

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

func _on_velocity_computed(safe_velocity: Vector3, actor_id: String) -> void:
	record_safe_velocity(actor_id, safe_velocity)
