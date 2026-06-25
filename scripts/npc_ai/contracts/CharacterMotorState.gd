extends RefCounted
class_name CharacterMotorState

var previous_position := Vector3.ZERO
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var requested_velocity := Vector3.ZERO
var applied_velocity := Vector3.ZERO
var displacement := Vector3.ZERO
var grounded := false
var terrain_grounded := false
var jumped := false
var blocked := false
var blocked_contact_category := ""
var jump_snap_time := 0.0
var upward_terrain_correction := 0.0
var downward_terrain_correction := 0.0
var airborne_obstacle_blocked := false

func flat_displacement() -> float:
	return Vector2(displacement.x, displacement.z).length()

func to_summary() -> Dictionary:
	return {
		"previousPosition": [previous_position.x, previous_position.y, previous_position.z],
		"position": [position.x, position.y, position.z],
		"velocity": [velocity.x, velocity.y, velocity.z],
		"requestedVelocity": [requested_velocity.x, requested_velocity.y, requested_velocity.z],
		"appliedVelocity": [applied_velocity.x, applied_velocity.y, applied_velocity.z],
		"displacement": [displacement.x, displacement.y, displacement.z],
		"flatDisplacement": flat_displacement(),
		"grounded": grounded,
		"terrainGrounded": terrain_grounded,
		"jumped": jumped,
		"blocked": blocked,
		"blockedContactCategory": blocked_contact_category,
		"jumpSnapTime": jump_snap_time,
		"upwardTerrainCorrection": upward_terrain_correction,
		"downwardTerrainCorrection": downward_terrain_correction,
		"airborneObstacleBlocked": airborne_obstacle_blocked
	}
