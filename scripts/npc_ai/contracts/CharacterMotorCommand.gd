extends RefCounted
class_name CharacterMotorCommand

var desired_direction := Vector3.ZERO
var desired_velocity := Vector3.ZERO
var speed := 0.0
var jump_requested := false
var sprint_requested := false
var grounded_hint := false
var terrain_grounded := false
var jump_snap_time := 0.0
var allow_jump := true
var update_snap_timer := true
var use_desired_velocity := false

static func from_direction(direction: Vector3, move_speed: float, jump := false, sprint := false):
	var command = load("res://scripts/npc_ai/contracts/CharacterMotorCommand.gd").new()
	command.desired_direction = direction
	command.speed = move_speed
	command.jump_requested = jump
	command.sprint_requested = sprint
	return command

static func from_velocity(velocity: Vector3):
	var command = load("res://scripts/npc_ai/contracts/CharacterMotorCommand.gd").new()
	command.desired_velocity = velocity
	command.use_desired_velocity = true
	return command

func horizontal_velocity() -> Vector3:
	if use_desired_velocity:
		return Vector3(desired_velocity.x, 0.0, desired_velocity.z)
	var direction := desired_direction
	direction.y = 0.0
	if direction.length_squared() > 0.001:
		direction = direction.normalized()
	return direction * speed

func to_summary() -> Dictionary:
	return {
		"desiredDirection": [desired_direction.x, desired_direction.y, desired_direction.z],
		"desiredVelocity": [desired_velocity.x, desired_velocity.y, desired_velocity.z],
		"speed": speed,
		"jumpRequested": jump_requested,
		"sprintRequested": sprint_requested,
		"groundedHint": grounded_hint,
		"terrainGrounded": terrain_grounded,
		"jumpSnapTime": jump_snap_time,
		"useDesiredVelocity": use_desired_velocity
	}
