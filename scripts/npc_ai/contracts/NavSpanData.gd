extends RefCounted
class_name NavSpanData

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NavSpanKeyScript := preload("res://scripts/npc_ai/contracts/NavSpanKey.gd")

var key = null
var cell := Vector3i.ZERO
var world_position := Vector3.ZERO
var floor_normal := Vector3.UP
var floor_angle_degrees := 0.0
var headroom := 999.0
var lateral_clearance := 999.0
var walkable := true
var blocker_kind := ""
var semantic_region_ids: Array[String] = []
var traversal_tags: Array[StringName] = []
var flags := {}

static func from_surface(tile_key: String, surface: Dictionary, span_index := 0):
	var span = load("res://scripts/npc_ai/contracts/NavSpanData.gd").new()
	span.cell = surface.get("cell", Vector3i(int(surface.get("x", 0)), int(surface.get("y", 0)), int(surface.get("z", 0))))
	if not (span.cell is Vector3i):
		span.cell = Vector3i.ZERO
	span.key = NavSpanKeyScript.make(tile_key, span.cell, span_index)
	span.world_position = surface.get("worldPosition", Vector3(float(span.cell.x) * NpcConstantsScript.CELL_SIZE, float(span.cell.y) * NpcConstantsScript.CELL_SIZE, float(span.cell.z) * NpcConstantsScript.CELL_SIZE))
	span.floor_normal = surface.get("floorNormal", Vector3.UP)
	if span.floor_normal.length_squared() < 0.001:
		span.floor_normal = Vector3.UP
	span.floor_normal = span.floor_normal.normalized()
	span.floor_angle_degrees = rad_to_deg(acos(clampf(span.floor_normal.dot(Vector3.UP), -1.0, 1.0)))
	span.headroom = float(surface.get("headroom", span.headroom))
	span.lateral_clearance = float(surface.get("lateralClearance", span.lateral_clearance))
	span.walkable = not bool(surface.get("blocked", false))
	span.blocker_kind = String(surface.get("blockerKind", ""))
	var semantics: Array = surface.get("semanticRegionIds", [])
	for semantic in semantics:
		span.semantic_region_ids.append(String(semantic))
	var tags: Array = surface.get("traversalTags", [])
	for tag in tags:
		span.traversal_tags.append(StringName(String(tag)))
	span.flags = surface.get("flags", {}).duplicate()
	return span

func key_string() -> String:
	return key.as_string() if key != null else ""

func supports_profile(profile) -> bool:
	var required_headroom := _profile_float(profile, "standing_height", NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT) + _profile_float(profile, "headroom_margin", NpcConstantsScript.DEFAULT_HEADROOM_MARGIN)
	var required_radius := _profile_float(profile, "body_radius", NpcConstantsScript.DEFAULT_NPC_RADIUS) + _profile_float(profile, "personal_space_margin", NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN)
	var max_floor_angle := _profile_float(profile, "maximum_floor_angle_degrees", NpcConstantsScript.DEFAULT_NPC_MAX_FLOOR_ANGLE_DEGREES)
	return walkable and floor_angle_degrees <= max_floor_angle and headroom >= required_headroom and lateral_clearance >= required_radius

func _profile_float(profile, property_name: String, fallback: float) -> float:
	if profile == null:
		return fallback
	var value = profile.get(property_name)
	if value == null:
		return fallback
	return float(value)

func to_summary() -> Dictionary:
	return {
		"key": key_string(),
		"cell": [cell.x, cell.y, cell.z],
		"worldPosition": [world_position.x, world_position.y, world_position.z],
		"floorAngle": floor_angle_degrees,
		"headroom": headroom,
		"lateralClearance": lateral_clearance,
		"walkable": walkable,
		"blockerKind": blocker_kind,
		"semanticRegionIds": semantic_region_ids.duplicate(),
		"traversalTags": traversal_tags.duplicate()
	}
