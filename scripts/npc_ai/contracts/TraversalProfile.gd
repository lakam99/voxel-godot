extends RefCounted
class_name TraversalProfile

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var profile_id := "adult_npc"
var body_radius := NpcConstantsScript.DEFAULT_NPC_RADIUS
var standing_height := NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
var crouched_height := 0.0
var step_up_height := NpcConstantsScript.DEFAULT_NPC_STEP_UP
var safe_step_drop_height := NpcConstantsScript.DEFAULT_NPC_SAFE_DROP
var maximum_floor_angle_degrees := NpcConstantsScript.DEFAULT_NPC_MAX_FLOOR_ANGLE_DEGREES
var maximum_walk_speed := NpcConstantsScript.DEFAULT_NPC_WALK_SPEED
var acceleration := NpcConstantsScript.DEFAULT_NPC_ACCELERATION
var deceleration := NpcConstantsScript.DEFAULT_NPC_ACCELERATION
var turning_response := 1.0
var door_minimum_width := NpcConstantsScript.DEFAULT_DOOR_MINIMUM_WIDTH
var headroom_margin := NpcConstantsScript.DEFAULT_HEADROOM_MARGIN
var personal_space_margin := NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
var abilities := {
	&"walk": true,
	&"sprint": false,
	&"jump": false,
	&"crouch": false,
	&"swim": false,
	&"climb": false,
	&"open_doors": true,
	&"use_locked_doors": false,
	&"break_doors": false,
	&"carry_bulky_item": false
}
var terrain_capability_tags: Array[StringName] = [&"town", &"path", &"terrain"]
var hazard_tolerances := {}
var traversal_cost_modifiers := {}

static func default_adult_npc():
	return load("res://scripts/npc_ai/contracts/TraversalProfile.gd").new()

static func from_legacy_profile(profile: Dictionary, can_fight := false):
	var traversal = default_adult_npc()
	traversal.profile_id = String(profile.get("traversalProfileId", "adult_npc"))
	traversal.maximum_walk_speed = float(profile.get("walkSpeed", traversal.maximum_walk_speed))
	traversal.abilities[&"sprint"] = can_fight
	traversal.abilities[&"carry_bulky_item"] = String(profile.get("job", "")) in ["wood", "stone"]
	return traversal

func can(ability: StringName) -> bool:
	return bool(abilities.get(ability, false))

func to_summary() -> Dictionary:
	return {
		"profileId": profile_id,
		"radius": body_radius,
		"standingHeight": standing_height,
		"stepUp": step_up_height,
		"safeDrop": safe_step_drop_height,
		"maxFloorAngle": maximum_floor_angle_degrees,
		"walkSpeed": maximum_walk_speed,
		"doorMinimumWidth": door_minimum_width,
		"abilities": abilities.duplicate()
	}
