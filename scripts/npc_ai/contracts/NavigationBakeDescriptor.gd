extends RefCounted
class_name NavigationBakeDescriptor

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

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
var door_links: Array[Dictionary] = []

static func create(region_id_value: String, tile_key_value: String, bounds_value := AABB()):
	var descriptor = load("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd").new()
	descriptor.region_id = region_id_value
	descriptor.tile_key = tile_key_value
	descriptor.bounds = bounds_value
	return descriptor

static func chunk_region_id(tile_key_value: String) -> String:
	return "region:chunk:%s" % tile_key_value

static func semantic_region_id(region_id_value: String) -> String:
	return "region:semantic:%s" % region_id_value

static func from_tile_snapshot(snapshot: Dictionary):
	var tile_key_value := String(snapshot.get("tileKey", "0,0"))
	var region_id_value := String(snapshot.get("regionId", chunk_region_id(tile_key_value)))
	var descriptor = create(region_id_value, tile_key_value)
	descriptor.loaded = not bool(snapshot.get("unloaded", false))
	descriptor.revision = int(snapshot.get("sourceRevision", snapshot.get("topologyRevision", 1)))
	descriptor.metadata = {
		"source": "tile_snapshot",
		"dynamicRevision": int(snapshot.get("dynamicRevision", 0)),
		"semanticRevision": int(snapshot.get("semanticRevision", 0))
	}
	var has_bounds := false
	var merged_bounds := AABB()
	var index := 0
	for surface_value in snapshot.get("surfaces", []):
		if not (surface_value is Dictionary):
			continue
		var surface: Dictionary = surface_value
		var cell: Vector3i = surface.get("cell", Vector3i.ZERO)
		if not (cell is Vector3i):
			cell = Vector3i(int(surface.get("x", 0)), int(surface.get("y", 0)), int(surface.get("z", 0)))
		var center: Vector3 = surface.get("worldPosition", Vector3(float(cell.x) * NpcConstantsScript.CELL_SIZE, float(cell.y) * NpcConstantsScript.CELL_SIZE, float(cell.z) * NpcConstantsScript.CELL_SIZE))
		var size := Vector3(NpcConstantsScript.CELL_SIZE, 0.05, NpcConstantsScript.CELL_SIZE)
		var span_index := int(surface.get("spanIndex", index))
		var surface_id := "surface:%s:%d,%d,%d:%d" % [tile_key_value, cell.x, cell.y, cell.z, span_index]
		var extra := {
			"cell": cell,
			"floorNormal": surface.get("floorNormal", Vector3.UP),
			"headroom": float(surface.get("headroom", 0.0)),
			"lateralClearance": float(surface.get("lateralClearance", 0.0)),
			"semanticRegionIds": surface.get("semanticRegionIds", []),
			"traversalTags": surface.get("traversalTags", [])
		}
		var surface_bounds := _surface_bounds(center, size)
		if bool(surface.get("blocked", false)):
			descriptor.add_blocker("blocker:%s" % surface_id, surface_bounds, {
				"cell": cell,
				"blockerKind": String(surface.get("blockerKind", "blocked_surface"))
			})
		else:
			descriptor.add_walkable_surface(surface_id, center, size, extra)
		merged_bounds = surface_bounds if not has_bounds else merged_bounds.merge(surface_bounds)
		has_bounds = true
		index += 1
	for semantic_value in snapshot.get("semanticRegions", []):
		if not (semantic_value is Dictionary):
			continue
		var semantic: Dictionary = semantic_value
		var semantic_id := String(semantic.get("id", ""))
		if semantic_id == "":
			continue
		var semantic_position := _position_from_semantic(semantic, merged_bounds if has_bounds else AABB())
		descriptor.add_semantic_anchor("semantic:%s" % semantic_id, String(semantic.get("kind", "semantic")), semantic_position, semantic)
	for portal_value in snapshot.get("doorPortals", []):
		if not (portal_value is Dictionary):
			continue
		var portal: Dictionary = portal_value
		var portal_id := String(portal.get("id", ""))
		if portal_id == "":
			continue
		descriptor.add_door_portal(portal_id, portal.get("entrance", Vector3.ZERO), portal.get("exit", Vector3.ZERO), portal)
	for link_value in snapshot.get("doorLinks", []):
		if not (link_value is Dictionary):
			continue
		var link: Dictionary = link_value
		var portal_id := String(link.get("portalId", ""))
		if portal_id == "":
			continue
		descriptor.add_door_link(String(link.get("from", "")), String(link.get("to", "")), portal_id, link)
	if has_bounds:
		descriptor.bounds = merged_bounds
	return descriptor

static func from_semantic_region(kind: String, region_id_value: String, bounds_value: AABB, metadata_value := {}):
	var descriptor = create(semantic_region_id(region_id_value), String(metadata_value.get("tileKey", region_id_value)), bounds_value)
	descriptor.metadata = {
		"source": "semantic_region",
		"semanticKind": kind,
		"semanticRegionId": region_id_value,
		"metadata": metadata_value.duplicate(true) if metadata_value is Dictionary else {}
	}
	var routeable := bool(metadata_value.get("routeable", true)) if metadata_value is Dictionary else true
	descriptor.metadata["routeable"] = routeable
	var center := bounds_value.position + bounds_value.size * 0.5
	if routeable:
		var surface_center := Vector3(center.x, bounds_value.position.y + 0.05, center.z)
		var surface_size := Vector3(maxf(bounds_value.size.x, NpcConstantsScript.CELL_SIZE), 0.05, maxf(bounds_value.size.z, NpcConstantsScript.CELL_SIZE))
		descriptor.add_walkable_surface("surface:semantic:%s" % region_id_value, surface_center, surface_size, {
			"semanticRegionIds": [region_id_value],
			"semanticKind": kind
		})
	descriptor.add_semantic_anchor("anchor:%s" % region_id_value, kind, center, metadata_value)
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

func add_door_link(from_key: String, to_key: String, portal_id: String, extra := {}) -> void:
	var link_id := String(extra.get("id", "door-link:%s:%s:%s" % [portal_id, from_key, to_key]))
	var link := {
		"id": link_id,
		"from": from_key,
		"to": to_key,
		"portalId": portal_id,
		"actionId": String(extra.get("actionId", "open")),
		"cost": float(extra.get("cost", 1.5)),
		"bidirectional": bool(extra.get("bidirectional", true)),
		"openable": bool(extra.get("openable", true)),
		"enabled": bool(extra.get("enabled", true))
	}
	_merge_extra(link, extra)
	door_links.append(link)

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
		"doorPortals": _sorted_summary_array(door_portals),
		"doorLinks": _sorted_summary_array(door_links)
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

static func _surface_bounds(center: Vector3, size: Vector3) -> AABB:
	var safe_size := Vector3(maxf(size.x, 0.01), maxf(size.y, 0.05), maxf(size.z, 0.01))
	return AABB(center - safe_size * 0.5, safe_size)

static func _position_from_semantic(semantic: Dictionary, fallback_bounds: AABB) -> Vector3:
	if semantic.has("position") and semantic["position"] is Vector3:
		return semantic["position"]
	if semantic.has("bounds") and semantic["bounds"] is AABB:
		var bounds: AABB = semantic["bounds"]
		return bounds.position + bounds.size * 0.5
	if fallback_bounds.size != Vector3.ZERO:
		return fallback_bounds.position + fallback_bounds.size * 0.5
	return Vector3.ZERO
