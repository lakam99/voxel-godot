extends RefCounted
class_name BuildingNavigationManifestBuilder

## Emits immutable navigation facts from the exact BuildingPart records that
## publish construction collision.  It never inspects meshes or physics nodes:
## those are products of the same source parts, not a second authority.

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const SCHEMA_VERSION := 1
const CELL := NpcConstantsScript.CELL_SIZE
const MIN_WALKABLE_NORMAL_Y := 0.68


static func build(blueprint, parent_transform := Transform3D.IDENTITY) -> Dictionary:
	var blueprint_id := String(blueprint.id) if blueprint != null else ""
	var supports: Array[Dictionary] = []
	var vertical_links: Array[Dictionary] = []
	var door_facts: Array[Dictionary] = []
	var source_part_ids: Array[String] = []
	var has_bounds := false
	var combined_bounds := AABB()
	if blueprint == null:
		return _empty_manifest(blueprint_id)
	for part in blueprint.parts:
		if part == null:
			continue
		if not bool(part.collision_enabled):
			continue
		var part_id := String(part.id)
		if part_id == "":
			continue
		var source_transform := parent_transform * Transform3D(Basis.from_euler(part.rotation), part.position)
		var part_bounds := _box_bounds(source_transform, part.size)
		combined_bounds = part_bounds if not has_bounds else combined_bounds.merge(part_bounds)
		has_bounds = true
		source_part_ids.append(part_id)
		if _is_walkable_support_part(part):
			var support := _support_fact(blueprint_id, part, source_transform, part_bounds)
			if not support.is_empty():
				supports.append(support)
		if _is_vertical_link_part(part):
			var link := _vertical_link_fact(blueprint_id, part, source_transform, part_bounds)
			if not link.is_empty():
				vertical_links.append(link)
		if String(part.kind) == "door":
			door_facts.append(_door_fact(blueprint_id, part, source_transform, part_bounds))
	supports.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	vertical_links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	door_facts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	source_part_ids.sort()
	return {
		"schemaVersion": SCHEMA_VERSION,
		"buildingId": blueprint_id,
		"sourceBlueprintId": blueprint_id,
		"bounds": combined_bounds if has_bounds else AABB(),
		"sourcePartIds": source_part_ids,
		"supports": supports,
		"verticalLinks": vertical_links,
		"doors": door_facts,
		"supportCount": supports.size(),
		"verticalLinkCount": vertical_links.size(),
		"doorCount": door_facts.size()
	}


static func _empty_manifest(blueprint_id: String) -> Dictionary:
	return {
		"schemaVersion": SCHEMA_VERSION,
		"buildingId": blueprint_id,
		"sourceBlueprintId": blueprint_id,
		"bounds": AABB(),
		"sourcePartIds": [],
		"supports": [],
		"verticalLinks": [],
		"doors": [],
		"supportCount": 0,
		"verticalLinkCount": 0,
		"doorCount": 0
	}


static func _is_walkable_support_part(part) -> bool:
	var kind := String(part.kind)
	if kind in ["floor", "ramp"]:
		return true
	if kind != "foundation":
		return false
	var semantic := String(part.semantic).to_lower()
	return semantic.contains("paving") or semantic.contains("courtyard") or semantic.contains("walkway") or semantic.contains("landing") or semantic.contains("floor")


static func _is_vertical_link_part(part) -> bool:
	if String(part.kind) != "ramp":
		return false
	var semantic := String(part.semantic).to_lower()
	return semantic.contains("stair") or semantic.contains("ramp")


static func _support_fact(blueprint_id: String, part, source_transform: Transform3D, bounds: AABB) -> Dictionary:
	var size: Vector3 = part.size
	var normal: Vector3 = (source_transform.basis * Vector3.UP).normalized()
	if normal.y < MIN_WALKABLE_NORMAL_Y:
		return {}
	var top_center: Vector3 = source_transform * Vector3(0.0, size.y * 0.5, 0.0)
	var top_polygon := _top_polygon(source_transform, size)
	if top_polygon.size() != 4:
		return {}
	var world_cell := Vector3i(roundi(top_center.x / CELL), floori(top_center.y / CELL), roundi(top_center.z / CELL))
	var source_part_id := String(part.id)
	return {
		"id": "building:%s:support:%s" % [blueprint_id, source_part_id],
		"sourceBlueprintId": blueprint_id,
		"sourcePartId": source_part_id,
		"sourceCollisionPartId": source_part_id,
		"kind": String(part.kind),
		"semantic": String(part.semantic),
		"cell": world_cell,
		"worldPosition": top_center,
		"floorNormal": normal,
		"polygon": top_polygon,
		"bounds": bounds,
		"headroom": 3.0,
		"lateralClearance": maxf(0.1, minf(size.x, size.z) * 0.5),
		"traversalTags": ["building", "support", String(part.kind)],
		"tileKeys": _tile_keys_for_bounds(bounds)
	}


static func _vertical_link_fact(blueprint_id: String, part, source_transform: Transform3D, bounds: AABB) -> Dictionary:
	var size: Vector3 = part.size
	var top_offset := size.y * 0.5
	var first: Vector3 = source_transform * Vector3(0.0, top_offset, -size.z * 0.5)
	var second: Vector3 = source_transform * Vector3(0.0, top_offset, size.z * 0.5)
	if absf(first.y - second.y) < CELL * 0.12:
		return {}
	var start := first if first.y <= second.y else second
	var end := second if first.y <= second.y else first
	var source_part_id := String(part.id)
	return {
		"id": "building:%s:vertical:%s" % [blueprint_id, source_part_id],
		"sourceBlueprintId": blueprint_id,
		"sourcePartId": source_part_id,
		"sourceCollisionPartId": source_part_id,
		"kind": "stair_ramp",
		"semantic": String(part.semantic),
		"start": start,
		"end": end,
		"bidirectional": true,
		"cost": start.distance_to(end),
		"bounds": bounds,
		"tileKeys": _tile_keys_for_bounds(bounds)
	}


static func _door_fact(blueprint_id: String, part, source_transform: Transform3D, bounds: AABB) -> Dictionary:
	return {
		"id": "building:%s:%s" % [blueprint_id, String(part.id)],
		"sourceBlueprintId": blueprint_id,
		"sourcePartId": String(part.id),
		"sourceCollisionPartId": String(part.id),
		"position": source_transform.origin,
		"rotation": source_transform.basis.get_euler(),
		"bounds": bounds,
		"tileKeys": _tile_keys_for_bounds(bounds)
	}


static func _top_polygon(source_transform: Transform3D, size: Vector3) -> Array[Vector3]:
	var half_x := size.x * 0.5
	var half_z := size.z * 0.5
	var y := size.y * 0.5
	return [
		source_transform * Vector3(-half_x, y, -half_z),
		source_transform * Vector3(-half_x, y, half_z),
		source_transform * Vector3(half_x, y, half_z),
		source_transform * Vector3(half_x, y, -half_z)
	]


static func _box_bounds(source_transform: Transform3D, size: Vector3) -> AABB:
	var half := size * 0.5
	var corners := [
		Vector3(-half.x, -half.y, -half.z), Vector3(-half.x, -half.y, half.z),
		Vector3(-half.x, half.y, -half.z), Vector3(-half.x, half.y, half.z),
		Vector3(half.x, -half.y, -half.z), Vector3(half.x, -half.y, half.z),
		Vector3(half.x, half.y, -half.z), Vector3(half.x, half.y, half.z)
	]
	var first: Vector3 = source_transform * corners[0]
	var bounds := AABB(first, Vector3.ZERO)
	for index in range(1, corners.size()):
		bounds = bounds.expand(source_transform * corners[index])
	return bounds


static func _tile_keys_for_bounds(bounds: AABB) -> Array[String]:
	var tile_cells := NpcConstantsScript.NAV_TILE_CELL_SIZE
	var min_x := floori(bounds.position.x / CELL)
	var max_x := floori(bounds.end.x / CELL)
	var min_z := floori(bounds.position.z / CELL)
	var max_z := floori(bounds.end.z / CELL)
	var min_tile_x := floori(float(min_x) / float(tile_cells))
	var max_tile_x := floori(float(max_x) / float(tile_cells))
	var min_tile_z := floori(float(min_z) / float(tile_cells))
	var max_tile_z := floori(float(max_z) / float(tile_cells))
	var keys: Array[String] = []
	for tile_z in range(min_tile_z, max_tile_z + 1):
		for tile_x in range(min_tile_x, max_tile_x + 1):
			keys.append("%d,%d" % [tile_x, tile_z])
	keys.sort()
	return keys
