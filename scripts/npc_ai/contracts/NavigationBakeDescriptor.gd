extends RefCounted
class_name NavigationBakeDescriptor

const SCHEMA_VERSION := 1

var region_id := ""
var tile_key := ""
var bounds := AABB()
var revision := 1
var loaded := true
var metadata := {}
var walkable_surfaces: Array[Dictionary] = []
var blockers: Array[Dictionary] = []
var semantic_anchors: Array[Dictionary] = []
var door_portals: Array[Dictionary] = []

static func create(region_id_value: String, tile_key_value: String, bounds_value := AABB()):
	var descriptor = load("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd").new()
	descriptor.region_id = region_id_value
	descriptor.tile_key = tile_key_value
	descriptor.bounds = bounds_value
	return descriptor

func add_walkable_surface(surface_id: String, center: Vector3, size := Vector3.ONE, extra := {}) -> void:
	var surface := {
		"id": surface_id,
		"center": center,
		"size": size,
		"normal": Vector3.UP,
		"walkable": true
	}
	_merge_extra(surface, extra)
	walkable_surfaces.append(surface)

func add_blocker(blocker_id: String, blocker_bounds: AABB, extra := {}) -> void:
	var blocker := {
		"id": blocker_id,
		"bounds": blocker_bounds
	}
	_merge_extra(blocker, extra)
	blockers.append(blocker)

func add_semantic_anchor(anchor_id: String, kind: String, position: Vector3, extra := {}) -> void:
	var anchor := {
		"id": anchor_id,
		"kind": kind,
		"position": position
	}
	_merge_extra(anchor, extra)
	semantic_anchors.append(anchor)

func add_door_portal(portal_id: String, entrance: Vector3, exit: Vector3, extra := {}) -> void:
	var portal := {
		"id": portal_id,
		"entrance": entrance,
		"exit": exit,
		"enabled": true
	}
	_merge_extra(portal, extra)
	door_portals.append(portal)

func stable_signature() -> String:
	return JSON.stringify(to_summary())

func to_summary() -> Dictionary:
	return {
		"schemaVersion": SCHEMA_VERSION,
		"regionId": region_id,
		"tileKey": tile_key,
		"bounds": _aabb_summary(bounds),
		"revision": revision,
		"loaded": loaded,
		"metadata": _canonical_value(metadata),
		"walkableSurfaces": _sorted_summary_array(walkable_surfaces),
		"blockers": _sorted_summary_array(blockers),
		"semanticAnchors": _sorted_summary_array(semantic_anchors),
		"doorPortals": _sorted_summary_array(door_portals)
	}

func _merge_extra(target: Dictionary, extra := {}) -> void:
	for key in extra.keys():
		target[key] = extra[key]

func _sorted_summary_array(items: Array) -> Array:
	var summaries: Array = []
	for item in items:
		summaries.append(_canonical_value(item))
	summaries.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	return summaries

func _canonical_value(value):
	if value is Dictionary:
		var result := {}
		var keys: Array = value.keys()
		keys.sort()
		for key in keys:
			result[String(key)] = _canonical_value(value[key])
		return result
	if value is Array:
		var result_array: Array = []
		for item in value:
			result_array.append(_canonical_value(item))
		return result_array
	if value is Vector3:
		return _vector3_summary(value)
	if value is Vector2:
		return [snappedf(value.x, 0.001), snappedf(value.y, 0.001)]
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector2i:
		return [value.x, value.y]
	if value is AABB:
		return _aabb_summary(value)
	if value is StringName:
		return String(value)
	return value

func _aabb_summary(value: AABB) -> Dictionary:
	return {
		"position": _vector3_summary(value.position),
		"size": _vector3_summary(value.size)
	}

func _vector3_summary(value: Vector3) -> Array:
	return [snappedf(value.x, 0.001), snappedf(value.y, 0.001), snappedf(value.z, 0.001)]
