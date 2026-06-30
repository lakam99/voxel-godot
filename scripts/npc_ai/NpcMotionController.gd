extends RefCounted
class_name NpcMotionController

const CharacterMotor3DScript := preload("res://scripts/npc_ai/motor/CharacterMotor3D.gd")
const CharacterMotorCommandScript := preload("res://scripts/npc_ai/contracts/CharacterMotorCommand.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcAgentScript := preload("res://scripts/npc_ai/NpcAgent.gd")

var system
var main
var motor = CharacterMotor3DScript.new()

func setup(system_node, main_node) -> void:
	system = system_node
	main = main_node

func apply_route_motion(entry: Dictionary, previous: Vector3, candidate: Vector3, physics_delta: float) -> Dictionary:
	var body := entry.get("body") as CharacterBody3D
	if body == null or physics_delta <= 0.0:
		return { "moved": 0.0, "reason": "missing_character_body" }
	var motor_delta := maxf(0.0001, physics_delta)
	var displacement := candidate - previous
	displacement.y = 0.0
	var desired_velocity := displacement / motor_delta
	var command = CharacterMotorCommandScript.from_velocity(desired_velocity)
	command.terrain_grounded = bool(body.get_meta("npc_terrain_grounded", true))
	command.grounded_hint = command.terrain_grounded
	command.jump_requested = bool(body.get_meta("npc_jump_intent", false))
	command.jump_snap_time = float(body.get_meta("npc_jump_snap_time", 0.0))
	var profile = entry.get("motorProfile")
	if profile == null:
		profile = CharacterMotorProfileScript.npc_default()
		entry["motorProfile"] = profile
	prealign_to_validated_terrain_step(body, candidate, profile, motor_delta)
	var state = motor.call("apply", body, command, profile, motor_delta, main)
	body.set_meta("npc_terrain_grounded", bool(state.get("terrain_grounded")))
	body.set_meta("npc_jump_snap_time", float(state.get("jump_snap_time")))
	body.set_meta("npc_requested_velocity", desired_velocity)
	body.set_meta("npc_applied_velocity", state.get("applied_velocity"))
	body.set_meta("npc_blocked_contact", String(state.get("blocked_contact_category")))
	body.set_meta("npc_blocked_contact_name", String(state.get("blocked_contact_name")))
	body.set_meta("npc_blocked_contact_kind", String(state.get("blocked_contact_kind")))
	body.set_meta("npc_blocked_contact_type", String(state.get("blocked_contact_type")))
	body.set_meta("npc_slide_collision_count", int(state.get("slide_collision_count")))
	body.set_meta("npc_last_displacement", state.get("displacement"))
	if body.get_script() == NpcAgentScript:
		body.set("last_motor_state", state)
	var facing_step: Vector3 = body.global_position - previous
	facing_step.y = 0.0
	if facing_step.length_squared() > 0.001:
		body.rotation.y = atan2(facing_step.x, facing_step.z)
	if system != null and system.get("autonomy_system") != null:
		system.autonomy_system.record_motion(entry, state)
	return {
		"moved": Vector2(facing_step.x, facing_step.z).length(),
		"position": body.global_position,
		"blocked": bool(state.get("blocked")),
		"reason": String(state.get("blocked_contact_category"))
	}

func prealign_to_validated_terrain_step(body: CharacterBody3D, candidate: Vector3, profile, motor_delta: float) -> void:
	if body == null or profile == null:
		return
	if not bool(profile.get("use_terrain_grounding")):
		return
	if not candidate.is_finite():
		return
	var vertical_delta := candidate.y - body.global_position.y
	if vertical_delta <= 0.015:
		return
	var walkable_limit := float(profile.get("terrain_walkable_rise"))
	if vertical_delta > walkable_limit + 0.02:
		return
	var max_step := maxf(0.05, float(profile.get("terrain_ascend_speed")) * maxf(0.0001, motor_delta))
	body.move_and_collide(Vector3(0.0, minf(vertical_delta, max_step), 0.0))
	body.velocity.y = 0.0

func slide_delta() -> float:
	var ticks_per_second := float(Engine.physics_ticks_per_second)
	return 1.0 / ticks_per_second if ticks_per_second > 0.0 else 1.0 / 60.0
