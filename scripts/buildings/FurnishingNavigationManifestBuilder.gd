extends RefCounted
class_name FurnishingNavigationManifestBuilder

## Emits collision facts from the exact furnishing records used to publish the
## StaticBody3D colliders. Navigation consumes these data-only bounds instead
## of scanning visual or physics descendants for a separate obstacle model.

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const SCHEMA_VERSION := 2
const CELL := NpcConstantsScript.CELL_SIZE


static func build(plan, parent_transform := Transform3D.IDENTITY) -> Dictionary:
	var plan_id := String(plan.id) if plan != null else ""
	var source_blueprint_id := String(plan.source_blueprint_id) if plan != null else ""
	var collision_parts: Array[Dictionary] = []
	var has_bounds := false
	var combined_bounds := AABB()
	if plan == null:
		return _empty_manifest(plan_id, source_blueprint_id)
	for part in plan.parts:
		if part == null or not bool(part.collision_enabled):
			continue
		var part_id := String(part.id)
		if part_id == "":
			continue
		var body_transform := parent_transform * Transform3D(Basis.from_euler(part.rotation), part.position)
		var collider_transform := body_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, part.occupied_size.y * 0.5, 0.0))
		var bounds := _box_bounds(collider_transform, part.occupied_size)
		combined_bounds = bounds if not has_bounds else combined_bounds.merge(bounds)
		has_bounds = true
		collision_parts.append(_collision_fact(plan_id, source_blueprint_id, part, collider_transform, bounds))
	collision_parts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	return {
		"schemaVersion": SCHEMA_VERSION,
		"manifestId": "furnishing:%s:%s" % [source_blueprint_id, plan_id],
		"sourceKind": "furnishing",
		"sourcePlanId": plan_id,
		"sourceBlueprintId": source_blueprint_id,
		"bounds": combined_bounds if has_bounds else AABB(),
		"staticCollision": collision_parts,
		"staticCollisionCount": collision_parts.size()
	}


static func _empty_manifest(plan_id: String, source_blueprint_id: String) -> Dictionary:
	return {
		"schemaVersion": SCHEMA_VERSION,
		"manifestId": "furnishing:%s:%s" % [source_blueprint_id, plan_id],
		"sourceKind": "furnishing",
		"sourcePlanId": plan_id,
		"sourceBlueprintId": source_blueprint_id,
		"bounds": AABB(),
		"staticCollision": [],
		"staticCollisionCount": 0
	}


static func _collision_fact(plan_id: String, source_blueprint_id: String, part, collider_transform: Transform3D, bounds: AABB) -> Dictionary:
	var part_id := String(part.id)
	return {
		"id": "furnishing:%s:%s:%s" % [source_blueprint_id, plan_id, part_id],
		"sourceBlueprintId": source_blueprint_id,
		"sourcePlanId": plan_id,
		"sourcePartId": part_id,
		"sourceCollisionPartId": part_id,
		"kind": String(part.archetype),
		"semantic": String(part.semantic),
		"bounds": bounds,
		"footprint": _footprint_polygon(collider_transform, part.occupied_size),
		"tileKeys": _tile_keys_for_bounds(bounds)
	}


static func _box_bounds(transform: Transform3D, size: Vector3) -> AABB:
	var half := size * 0.5
	var corners := [
		Vector3(-half.x, -half.y, -half.z), Vector3(-half.x, -half.y, half.z),
		Vector3(-half.x, half.y, -half.z), Vector3(-half.x, half.y, half.z),
		Vector3(half.x, -half.y, -half.z), Vector3(half.x, -half.y, half.z),
		Vector3(half.x, half.y, -half.z), Vector3(half.x, half.y, half.z)
	]
	var bounds := AABB(transform * corners[0], Vector3.ZERO)
	for index in range(1, corners.size()):
		bounds = bounds.expand(transform * corners[index])
	return bounds


static func _footprint_polygon(transform: Transform3D, size: Vector3) -> Array[Vector3]:
	var half_x := size.x * 0.5
	var half_z := size.z * 0.5
	return [
		transform * Vector3(-half_x, 0.0, -half_z),
		transform * Vector3(-half_x, 0.0, half_z),
		transform * Vector3(half_x, 0.0, half_z),
		transform * Vector3(half_x, 0.0, -half_z)
	]


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
