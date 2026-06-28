extends RefCounted
class_name CharacterMotor3D

const CharacterMotorStateScript := preload("res://scripts/npc_ai/contracts/CharacterMotorState.gd")

func apply(body: CharacterBody3D, command, profile, delta: float, terrain_provider: Node = null):
	var state = CharacterMotorStateScript.new()
	if body == null or command == null or profile == null or delta <= 0.0:
		return state

	state.previous_position = body.global_position
	var snap_time := float(command.get("jump_snap_time"))
	if bool(command.get("update_snap_timer")) and snap_time > 0.0:
		snap_time = maxf(0.0, snap_time - delta)

	body.floor_max_angle = deg_to_rad(float(profile.get("floor_max_angle_degrees")))
	body.floor_snap_length = 0.0 if body.velocity.y > 0.0 or snap_time > 0.0 else float(profile.get("floor_snap_length"))

	var requested: Vector3 = command.call("horizontal_velocity")
	var grounded := (body.is_on_floor() or bool(command.get("terrain_grounded")) or bool(command.get("grounded_hint"))) and snap_time <= 0.0
	var control := 1.0 if grounded else float(profile.get("air_control"))
	if bool(profile.get("instant_horizontal_velocity")):
		body.velocity.x = requested.x
		body.velocity.z = requested.z
	else:
		var blend: float = minf(1.0, float(profile.get("acceleration")) * control * delta)
		body.velocity.x = lerpf(body.velocity.x, requested.x, blend)
		body.velocity.z = lerpf(body.velocity.z, requested.z, blend)

	if grounded and bool(command.get("jump_requested")) and bool(command.get("allow_jump")):
		body.velocity.y = float(profile.get("jump_speed"))
		snap_time = float(profile.get("jump_snap_suppression"))
		state.jumped = true
	elif not grounded:
		body.velocity.y -= float(profile.get("gravity")) * delta

	if state.jumped and terrain_provider != null and terrain_provider.has_method("height_at_world"):
		var jump_ground_y: float = terrain_provider.call("height_at_world", body.global_position.x, body.global_position.z)
		move_vertical_toward(body, jump_ground_y + 0.08)

	var pre_slide_position := body.global_position
	body.move_and_slide()
	state.slide_collision_count = body.get_slide_collision_count()
	if state.slide_collision_count > 0:
		var collision := body.get_slide_collision(0)
		var collider = collision.get_collider() if collision != null else null
		if collider is Node:
			var collider_node := collider as Node
			state.blocked_contact_name = collider_node.name
			state.blocked_contact_kind = String(collider_node.get_meta("kind", ""))
			state.blocked_contact_type = collider_node.get_class()
		elif collider != null:
			state.blocked_contact_type = str(collider)
	if state.jumped:
		move_vertical_toward(body, pre_slide_position.y + float(profile.get("jump_speed")) * delta)
		body.velocity.y = maxf(body.velocity.y, float(profile.get("jump_speed")))

	if bool(profile.get("use_terrain_grounding")):
		apply_terrain_grounding(body, profile, delta, terrain_provider, grounded, state.jumped, pre_slide_position, state)
	else:
		state.terrain_grounded = body.is_on_floor()

	state.position = body.global_position
	state.velocity = body.velocity
	state.requested_velocity = requested
	state.applied_velocity = Vector3(
		(body.global_position.x - state.previous_position.x) / delta,
		(body.global_position.y - state.previous_position.y) / delta,
		(body.global_position.z - state.previous_position.z) / delta
	)
	state.displacement = body.global_position - state.previous_position
	state.grounded = body.is_on_floor() or state.terrain_grounded
	state.jump_snap_time = snap_time
	if requested.length_squared() > 0.001 and state.flat_displacement() <= 0.001:
		state.blocked = true
		state.blocked_contact_category = "static_or_dynamic_collision"
	return state

func apply_terrain_grounding(body: CharacterBody3D, profile, delta: float, terrain_provider: Node, was_grounded: bool, jumped: bool, previous_position: Vector3, state) -> void:
	if terrain_provider == null or not terrain_provider.has_method("height_at_world"):
		state.terrain_grounded = body.is_on_floor()
		return

	var ground_y: float = terrain_provider.call("height_at_world", body.global_position.x, body.global_position.z)
	var distance_above_ground: float = body.global_position.y - ground_y
	if distance_above_ground < 0.0:
		var rise_needed: float = -distance_above_ground
		var previous_ground_y: float = terrain_provider.call("height_at_world", previous_position.x, previous_position.z)
		var horizontal_move: float = Vector2(body.global_position.x - previous_position.x, body.global_position.z - previous_position.z).length()
		var obstacle_rise: float = ground_y - previous_ground_y
		if was_grounded and not jumped and rise_needed <= float(profile.get("terrain_walkable_rise")):
			var old_y: float = body.global_position.y
			var max_rise: float = float(profile.get("terrain_ascend_speed")) * delta
			move_vertical_toward(body, move_toward(body.global_position.y, ground_y, max_rise))
			state.upward_terrain_correction = maxf(0.0, body.global_position.y - old_y)
			body.velocity.y = 0.0
			state.terrain_grounded = true
			return
		if (not was_grounded or jumped) and horizontal_move > 0.001 and obstacle_rise > float(profile.get("terrain_walkable_rise")):
			move_horizontal_toward(body, previous_position)
			body.velocity.x = 0.0
			body.velocity.z = 0.0
			state.terrain_grounded = false
			state.blocked = true
			state.blocked_contact_category = "airborne_terrain_obstacle"
			state.airborne_obstacle_blocked = true
			if body.velocity.y <= 0.0 and body.global_position.y <= previous_ground_y + float(profile.get("terrain_landing_distance")):
				move_vertical_toward(body, previous_ground_y)
				body.velocity.y = 0.0
				state.terrain_grounded = true
			return
		if was_grounded and not jumped:
			move_horizontal_toward(body, previous_position)
			move_vertical_toward(body, maxf(previous_position.y, previous_ground_y))
			body.velocity = Vector3.ZERO
			state.terrain_grounded = true
			state.blocked = true
			state.blocked_contact_category = "terrain_step_rejected"
			return
		move_vertical_toward(body, ground_y)
		body.velocity.y = maxf(body.velocity.y, 0.0)
		state.terrain_grounded = not jumped
		return

	if jumped:
		state.terrain_grounded = false
		return
	if float(state.get("jump_snap_time")) > 0.0:
		state.terrain_grounded = false
		return
	if was_grounded and body.velocity.y <= 0.0 and distance_above_ground <= float(profile.get("terrain_walkable_drop")):
		var old_y: float = body.global_position.y
		var max_drop: float = float(profile.get("terrain_descend_speed")) * delta
		move_vertical_toward(body, move_toward(body.global_position.y, ground_y, max_drop))
		state.downward_terrain_correction = maxf(0.0, old_y - body.global_position.y)
		if body.global_position.y <= ground_y + 0.03:
			move_vertical_toward(body, ground_y)
			body.velocity.y = 0.0
		state.terrain_grounded = true
		return
	if body.velocity.y <= 0.0 and distance_above_ground <= float(profile.get("terrain_landing_distance")):
		move_vertical_toward(body, ground_y)
		body.velocity.y = 0.0
		state.terrain_grounded = true
	else:
		state.terrain_grounded = false

func move_vertical_toward(body: CharacterBody3D, target_y: float) -> void:
	var delta_y := target_y - body.global_position.y
	if absf(delta_y) <= 0.0001:
		return
	body.move_and_collide(Vector3(0.0, delta_y, 0.0))

func move_horizontal_toward(body: CharacterBody3D, target_position: Vector3) -> void:
	var correction := Vector3(target_position.x - body.global_position.x, 0.0, target_position.z - body.global_position.z)
	if correction.length_squared() <= 0.000001:
		return
	body.move_and_collide(correction)
