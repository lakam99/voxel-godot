extends RefCounted
class_name CharacterMotorProfile

var id := "default"
var walk_speed := 9.5
var sprint_speed := 15.5
var acceleration := 14.0
var air_control := 0.42
var jump_speed := 8.9
var gravity := 26.0
var floor_snap_length := 0.32
var floor_max_angle_degrees := 46.0
var terrain_landing_distance := 0.18
var terrain_walkable_rise := 1.55
var terrain_walkable_drop := 1.55
var terrain_ascend_speed := 8.5
var terrain_descend_speed := 7.25
var jump_snap_suppression := 0.24
var capsule_radius := 0.42
var capsule_height := 1.72
var instant_horizontal_velocity := false
var use_terrain_grounding := true

static func player_default():
	var profile = load("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd").new()
	profile.id = "player"
	return profile

static func npc_default():
	var profile = load("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd").new()
	profile.id = "npc"
	profile.walk_speed = 2.6
	profile.sprint_speed = 10.8
	profile.acceleration = 64.0
	profile.air_control = 1.0
	profile.jump_speed = 6.2
	profile.gravity = 26.0
	profile.floor_snap_length = 0.32
	profile.floor_max_angle_degrees = 46.0
	profile.terrain_landing_distance = 0.20
	profile.terrain_walkable_rise = 1.20
	profile.terrain_walkable_drop = 1.35
	profile.terrain_ascend_speed = 8.5
	profile.terrain_descend_speed = 7.25
	profile.jump_snap_suppression = 0.18
	profile.capsule_radius = 0.34
	profile.capsule_height = 1.62
	profile.instant_horizontal_velocity = true
	return profile

static func from_traversal_profile(traversal_profile):
	var profile = npc_default()
	if traversal_profile != null:
		profile.capsule_radius = float(traversal_profile.get("body_radius"))
		profile.capsule_height = float(traversal_profile.get("standing_height"))
		profile.terrain_walkable_rise = float(traversal_profile.get("step_up_height"))
		profile.terrain_walkable_drop = float(traversal_profile.get("safe_step_drop_height"))
		profile.floor_max_angle_degrees = float(traversal_profile.get("maximum_floor_angle_degrees"))
		profile.walk_speed = float(traversal_profile.get("maximum_walk_speed"))
		profile.acceleration = float(traversal_profile.get("acceleration"))
	return profile

func to_summary() -> Dictionary:
	return {
		"id": id,
		"walkSpeed": walk_speed,
		"sprintSpeed": sprint_speed,
		"acceleration": acceleration,
		"airControl": air_control,
		"jumpSpeed": jump_speed,
		"gravity": gravity,
		"floorSnapLength": floor_snap_length,
		"floorMaxAngleDegrees": floor_max_angle_degrees,
		"terrainWalkableRise": terrain_walkable_rise,
		"terrainWalkableDrop": terrain_walkable_drop,
		"capsuleRadius": capsule_radius,
		"capsuleHeight": capsule_height,
		"instantHorizontalVelocity": instant_horizontal_velocity
	}
