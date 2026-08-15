extends RefCounted
class_name BuildingNavigationManifestBuilder

## Emits immutable navigation facts from the exact BuildingPart records that
## publish construction collision.  It never inspects meshes or physics nodes:
## those are products of the same source parts, not a second authority.

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const SCHEMA_VERSION := 8
const CELL := NpcConstantsScript.CELL_SIZE
const MIN_WALKABLE_NORMAL_Y := 0.68
const DOOR_PORTAL_CLEARANCE := NpcConstantsScript.DEFAULT_NPC_RADIUS + 0.24
const DOOR_PORTAL_SUPPORT_INSET := CELL * 0.18
const DOOR_PORTAL_MIN_STAGING_DISTANCE := CELL * 1.10
const SUPPORT_SEAM_MIN_NORMAL_Y := 0.985
const SUPPORT_SEAM_LINK_INSET := CELL * 0.24
const SUPPORT_SEAM_CLEARANCE := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
const SUPPORT_SEAM_MIN_WIDTH := SUPPORT_SEAM_CLEARANCE * 2.0
const INTERIOR_PASSAGE_ENDPOINT_INSET := CELL * 0.08
const INTERIOR_PASSAGE_MIN_CROSSING := CELL * 1.10
const INTERIOR_PASSAGE_MIN_WIDTH := SUPPORT_SEAM_CLEARANCE * 2.0 + CELL * 0.50


static func build(blueprint, parent_transform := Transform3D.IDENTITY) -> Dictionary:
	var blueprint_id := String(blueprint.id) if blueprint != null else ""
	var source_blueprint_id := blueprint_id
	if blueprint != null and blueprint.recipe is Dictionary:
		source_blueprint_id = String((blueprint.recipe as Dictionary).get("sourceBlueprintId", blueprint_id))
	if source_blueprint_id.is_empty():
		source_blueprint_id = blueprint_id
	var supports: Array[Dictionary] = []
	var vertical_links: Array[Dictionary] = []
	var support_seam_links: Array[Dictionary] = []
	var interior_passage_links: Array[Dictionary] = []
	var door_facts: Array[Dictionary] = []
	var static_collision_parts: Array[Dictionary] = []
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
		if String(part.kind) != "door" and not _is_walkable_support_part(part):
			static_collision_parts.append(_static_collision_fact(source_blueprint_id, part, source_transform, part_bounds))
		if _is_walkable_support_part(part):
			var support := _support_fact(source_blueprint_id, part, source_transform, part_bounds)
			if not support.is_empty():
				supports.append(support)
		if _is_vertical_link_part(part):
			var link := _vertical_link_fact(source_blueprint_id, part, source_transform, part_bounds)
			if not link.is_empty():
				vertical_links.append(link)
		if String(part.kind) == "door":
			door_facts.append(_door_fact(source_blueprint_id, part, source_transform, part_bounds))
	for door_fact in door_facts:
		_resolve_door_portal_supports(door_fact, supports)
	for vertical_link in vertical_links:
		_resolve_vertical_link_supports(vertical_link, supports)
	support_seam_links = _support_seam_link_facts(source_blueprint_id, supports, static_collision_parts, door_facts)
	interior_passage_links = _interior_passage_link_facts(source_blueprint_id, blueprint.rooms, parent_transform, supports, static_collision_parts, door_facts)
	supports.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	vertical_links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	support_seam_links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	interior_passage_links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	door_facts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	static_collision_parts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	source_part_ids.sort()
	return {
		"schemaVersion": SCHEMA_VERSION,
		"buildingId": blueprint_id,
		"sourceBlueprintId": source_blueprint_id,
		"bounds": combined_bounds if has_bounds else AABB(),
		"sourcePartIds": source_part_ids,
		"supports": supports,
		"verticalLinks": vertical_links,
		"supportSeamLinks": support_seam_links,
		"interiorPassageLinks": interior_passage_links,
		"doors": door_facts,
		"staticCollision": static_collision_parts,
		"supportCount": supports.size(),
		"verticalLinkCount": vertical_links.size(),
		"supportSeamLinkCount": support_seam_links.size(),
		"interiorPassageLinkCount": interior_passage_links.size(),
		"doorCount": door_facts.size(),
		"staticCollisionCount": static_collision_parts.size()
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
		"supportSeamLinks": [],
		"interiorPassageLinks": [],
		"doors": [],
		"staticCollision": [],
		"supportCount": 0,
		"verticalLinkCount": 0,
		"supportSeamLinkCount": 0,
		"interiorPassageLinkCount": 0,
		"doorCount": 0,
		"staticCollisionCount": 0
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
		"tileKeys": _tile_keys_for_bounds(bounds),
		"startTileKey": _tile_key_for_position(start),
		"endTileKey": _tile_key_for_position(end),
		"ownerTileKey": _tile_key_for_position(start)
	}


static func _resolve_vertical_link_supports(link: Dictionary, supports: Array[Dictionary]) -> void:
	var source_part_id := String(link.get("sourceCollisionPartId", link.get("sourcePartId", "")))
	var start: Vector3 = link.get("start", Vector3.INF) as Vector3
	var end: Vector3 = link.get("end", Vector3.INF) as Vector3
	if source_part_id.is_empty() or not start.is_finite() or not end.is_finite():
		return
	var start_support := _support_for_vertical_link_endpoint(supports, start, source_part_id)
	var end_support := _support_for_vertical_link_endpoint(supports, end, source_part_id)
	if start_support.is_empty() or end_support.is_empty():
		return
	link["startSupportId"] = String(start_support.get("id", ""))
	link["endSupportId"] = String(end_support.get("id", ""))


static func _support_for_vertical_link_endpoint(supports: Array[Dictionary], position: Vector3, source_part_id: String) -> Dictionary:
	var result: Dictionary = {}
	var best_distance := INF
	var best_id := ""
	for support_value in supports:
		if not (support_value is Dictionary):
			continue
		var support: Dictionary = support_value
		if String(support.get("sourceCollisionPartId", support.get("sourcePartId", ""))) == source_part_id:
			continue
		var normal: Vector3 = support.get("floorNormal", Vector3.UP) if support.get("floorNormal", Vector3.UP) is Vector3 else Vector3.UP
		if normal.normalized().y < SUPPORT_SEAM_MIN_NORMAL_Y or not _point_within_support_xz(position, support):
			continue
		var distance := absf(_support_surface_y(support, position) - position.y)
		if distance > CELL * 0.82:
			continue
		var support_id := String(support.get("id", ""))
		if distance < best_distance or (is_equal_approx(distance, best_distance) and (best_id.is_empty() or support_id < best_id)):
			result = support
			best_distance = distance
			best_id = support_id
	return result


static func _support_seam_link_facts(blueprint_id: String, supports: Array[Dictionary], static_collision_parts: Array[Dictionary], door_facts: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var obstruction_parts: Array[Dictionary] = []
	obstruction_parts.append_array(static_collision_parts)
	obstruction_parts.append_array(door_facts)
	for support in supports:
		var normal: Vector3 = support.get("floorNormal", Vector3.UP) if support.get("floorNormal", Vector3.UP) is Vector3 else Vector3.UP
		if normal.normalized().y < SUPPORT_SEAM_MIN_NORMAL_Y:
			continue
		var bounds: AABB = support.get("bounds", AABB()) if support.get("bounds", AABB()) is AABB else AABB()
		if bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
			continue
		for link in _support_seam_links_for_axis(blueprint_id, support, obstruction_parts, bounds, 0):
			result.append(link)
		for link in _support_seam_links_for_axis(blueprint_id, support, obstruction_parts, bounds, 1):
			result.append(link)
	return result


static func _support_seam_links_for_axis(blueprint_id: String, support: Dictionary, obstruction_parts: Array[Dictionary], bounds: AABB, axis: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var tile_cells := NpcConstantsScript.NAV_TILE_CELL_SIZE
	var minimum := bounds.position.x if axis == 0 else bounds.position.z
	var maximum := bounds.end.x if axis == 0 else bounds.end.z
	var first_tile := floori((minimum / CELL + 0.5) / float(tile_cells))
	var last_tile := floori((maximum / CELL + 0.5) / float(tile_cells))
	for tile_index in range(first_tile + 1, last_tile + 1):
		var seam_coordinate := (float(tile_index * tile_cells) - 0.5) * CELL
		var link := _support_seam_link_fact(blueprint_id, support, obstruction_parts, axis, tile_index, seam_coordinate)
		if not link.is_empty():
			result.append(link)
	return result


static func _support_seam_link_fact(blueprint_id: String, support: Dictionary, obstruction_parts: Array[Dictionary], axis: int, tile_index: int, seam_coordinate: float) -> Dictionary:
	var span := _support_seam_span(support, axis, seam_coordinate)
	if span.y - span.x < SUPPORT_SEAM_MIN_WIDTH:
		return {}
	var lateral := (span.x + span.y) * 0.5
	var first := Vector3(seam_coordinate - SUPPORT_SEAM_LINK_INSET, 0.0, lateral) if axis == 0 else Vector3(lateral, 0.0, seam_coordinate - SUPPORT_SEAM_LINK_INSET)
	var second := Vector3(seam_coordinate + SUPPORT_SEAM_LINK_INSET, 0.0, lateral) if axis == 0 else Vector3(lateral, 0.0, seam_coordinate + SUPPORT_SEAM_LINK_INSET)
	if not _point_within_support_xz(first, support) or not _point_within_support_xz(second, support):
		return {}
	first.y = _support_surface_y(support, first) + 0.04
	second.y = _support_surface_y(support, second) + 0.04
	if _support_seam_link_blocked(first, second, obstruction_parts):
		return {}
	var source_part_id := String(support.get("sourcePartId", ""))
	if source_part_id.is_empty():
		return {}
	var axis_name := "x" if axis == 0 else "z"
	var link_bounds := AABB(first, Vector3.ZERO).expand(second).grow(CELL * 0.04)
	return {
		"id": "building:%s:support_seam:%s:%s:%d" % [blueprint_id, source_part_id, axis_name, tile_index],
		"sourceBlueprintId": blueprint_id,
		"sourcePartId": source_part_id,
		"sourceCollisionPartId": String(support.get("sourceCollisionPartId", source_part_id)),
		"supportId": String(support.get("id", "")),
		"kind": "support_seam",
		"semantic": String(support.get("semantic", "")),
		"axis": axis_name,
		"seamCoordinate": seam_coordinate,
		"start": first,
		"end": second,
		"bidirectional": true,
		"cost": first.distance_to(second),
		"bounds": link_bounds,
		"tileKeys": _tile_keys_for_bounds(link_bounds),
		"startTileKey": _tile_key_for_position(first),
		"endTileKey": _tile_key_for_position(second),
		"ownerTileKey": _tile_key_for_position(first)
	}


static func _support_seam_span(support: Dictionary, axis: int, seam_coordinate: float) -> Vector2:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return Vector2(INF, -INF)
	var intersections: Array[float] = []
	var previous: Vector3 = polygon[polygon.size() - 1] if polygon[polygon.size() - 1] is Vector3 else Vector3.ZERO
	for point_value in polygon:
		if not (point_value is Vector3):
			return Vector2(INF, -INF)
		var point: Vector3 = point_value
		var previous_axis := previous.x if axis == 0 else previous.z
		var point_axis := point.x if axis == 0 else point.z
		var previous_lateral := previous.z if axis == 0 else previous.x
		var point_lateral := point.z if axis == 0 else point.x
		if is_equal_approx(previous_axis, point_axis):
			if is_equal_approx(previous_axis, seam_coordinate):
				intersections.append(previous_lateral)
				intersections.append(point_lateral)
		elif seam_coordinate >= minf(previous_axis, point_axis) and seam_coordinate <= maxf(previous_axis, point_axis):
			var ratio := (seam_coordinate - previous_axis) / (point_axis - previous_axis)
			intersections.append(lerpf(previous_lateral, point_lateral, ratio))
		previous = point
	if intersections.size() < 2:
		return Vector2(INF, -INF)
	intersections.sort()
	return Vector2(intersections.front(), intersections.back())


static func _support_seam_link_blocked(first: Vector3, second: Vector3, obstruction_parts: Array[Dictionary]) -> bool:
	var corridor := AABB(first, Vector3.ZERO).expand(second).grow(SUPPORT_SEAM_CLEARANCE)
	var minimum_y := minf(first.y, second.y) + 0.02
	var maximum_y := maxf(first.y, second.y) + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
	for obstruction in obstruction_parts:
		var bounds: AABB = obstruction.get("bounds", AABB()) if obstruction.get("bounds", AABB()) is AABB else AABB()
		if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
			continue
		if bounds.end.y < minimum_y or bounds.position.y > maximum_y:
			continue
		if bounds.end.x < corridor.position.x or bounds.position.x > corridor.end.x:
			continue
		if bounds.end.z < corridor.position.z or bounds.position.z > corridor.end.z:
			continue
		var footprint: Array = obstruction.get("footprint", []) if obstruction.get("footprint", []) is Array else []
		if footprint.is_empty() or _footprint_intersects_corridor(first, second, SUPPORT_SEAM_CLEARANCE, footprint):
			return true
	return false


static func _interior_passage_link_facts(blueprint_id: String, room_records: Array, parent_transform: Transform3D, supports: Array[Dictionary], static_collision_parts: Array[Dictionary], door_facts: Array[Dictionary]) -> Array[Dictionary]:
	var passages_by_key := {}
	for room_value in room_records:
		if not (room_value is Dictionary):
			continue
		var room: Dictionary = room_value
		var room_id := String(room.get("id", ""))
		var room_bounds: AABB = room.get("bounds", AABB()) if room.get("bounds", AABB()) is AABB else AABB()
		if room_id.is_empty() or room_bounds.size.x <= 0.0 or room_bounds.size.z <= 0.0:
			continue
		var room_center := parent_transform * room_bounds.get_center()
		for access_value in room.get("accesses", []) as Array:
			if not (access_value is Dictionary):
				continue
			var access: Dictionary = access_value
			if String(access.get("kind", "")) != "interior_passage":
				continue
			var access_id := String(access.get("id", "")).strip_edges()
			var local_position: Vector3 = access.get("position", Vector3.ZERO) as Vector3
			var access_size: Vector3 = access.get("navigationSize", access.get("size", Vector3.ZERO)) as Vector3
			if access_id.is_empty() or access_size.x <= 0.0 or access_size.z <= 0.0:
				continue
			var world_position := parent_transform * local_position
			var access_orientation: Vector3 = access.get("orientation", Vector3.ZERO) as Vector3
			var access_basis := parent_transform.basis * Basis.from_euler(access_orientation)
			var crossing_axis: Vector3 = access_basis * (access.get("crossingAxis", Vector3.ZERO) as Vector3)
			crossing_axis.y = 0.0
			if crossing_axis.length_squared() > 0.0001:
				crossing_axis = crossing_axis.normalized()
			var access_key := "%s:%d:%d:%d" % [access_id, roundi(world_position.x / CELL), roundi(world_position.y / CELL), roundi(world_position.z / CELL)]
			var entries: Array = passages_by_key.get(access_key, []) as Array
			entries.append({
				"roomId": room_id,
				"roomCenter": room_center,
				"accessId": access_id,
				"accessKey": access_key,
				"worldPosition": world_position,
				"localSize": access_size,
				"worldAccessBasis": access_basis,
				"worldCrossingAxis": crossing_axis,
				"supportPartId": String(access.get("supportPartId", ""))
			})
			passages_by_key[access_key] = entries
	var obstruction_parts: Array[Dictionary] = []
	obstruction_parts.append_array(static_collision_parts)
	obstruction_parts.append_array(door_facts)
	var access_keys: Array = passages_by_key.keys()
	access_keys.sort()
	var result: Array[Dictionary] = []
	for access_key_value in access_keys:
		var access_key := String(access_key_value)
		var entries: Array = passages_by_key.get(access_key, []) as Array
		var pair := _furthest_interior_passage_entries(entries)
		if pair.size() != 2:
			continue
		var link := _interior_passage_link_fact(blueprint_id, pair[0] as Dictionary, pair[1] as Dictionary, parent_transform, supports, obstruction_parts)
		if not link.is_empty():
			result.append(link)
	return result


static func _furthest_interior_passage_entries(entries: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var greatest_distance := 0.0
	for first_index in range(entries.size()):
		if not (entries[first_index] is Dictionary):
			continue
		var first: Dictionary = entries[first_index]
		var first_center: Vector3 = first.get("roomCenter", Vector3.ZERO) as Vector3
		for second_index in range(first_index + 1, entries.size()):
			if not (entries[second_index] is Dictionary):
				continue
			var second: Dictionary = entries[second_index]
			var second_center: Vector3 = second.get("roomCenter", Vector3.ZERO) as Vector3
			var distance := Vector2(second_center.x - first_center.x, second_center.z - first_center.z).length()
			if distance <= greatest_distance:
				continue
			greatest_distance = distance
			result = [first, second]
	return result


static func _interior_passage_link_fact(blueprint_id: String, first_entry: Dictionary, second_entry: Dictionary, parent_transform: Transform3D, supports: Array[Dictionary], obstruction_parts: Array[Dictionary]) -> Dictionary:
	var first_center: Vector3 = first_entry.get("roomCenter", Vector3.ZERO) as Vector3
	var second_center: Vector3 = second_entry.get("roomCenter", Vector3.ZERO) as Vector3
	var explicit_crossing_axis: Vector3 = first_entry.get("worldCrossingAxis", Vector3.ZERO) as Vector3
	explicit_crossing_axis.y = 0.0
	var has_explicit_crossing_axis := explicit_crossing_axis.length_squared() > 0.0001
	var crossing_direction := explicit_crossing_axis.normalized() if has_explicit_crossing_axis else second_center - first_center
	crossing_direction.y = 0.0
	if crossing_direction.length_squared() <= 0.0001:
		return {}
	crossing_direction = crossing_direction.normalized()
	var access_position: Vector3 = first_entry.get("worldPosition", Vector3.ZERO) as Vector3
	var access_size: Vector3 = first_entry.get("localSize", Vector3.ZERO) as Vector3
	var access_basis: Basis = first_entry.get("worldAccessBasis", parent_transform.basis) as Basis
	var crossing_extent := _projected_access_extent(access_size, access_basis, crossing_direction)
	var lateral_direction := Vector3(-crossing_direction.z, 0.0, crossing_direction.x)
	var passage_width := _projected_access_extent(access_size, access_basis, lateral_direction)
	if crossing_extent < INTERIOR_PASSAGE_MIN_CROSSING or passage_width < INTERIOR_PASSAGE_MIN_WIDTH:
		return {}
	var endpoint_offset := crossing_extent * 0.5 - INTERIOR_PASSAGE_ENDPOINT_INSET
	if endpoint_offset <= SUPPORT_SEAM_CLEARANCE:
		return {}
	var floor_y := access_position.y
	var first_support_part_id := String(first_entry.get("supportPartId", ""))
	var second_support_part_id := String(second_entry.get("supportPartId", ""))
	var endpoint_resolution := _interior_passage_endpoint_resolution(supports, access_position, crossing_direction, endpoint_offset, floor_y, first_support_part_id, second_support_part_id)
	if has_explicit_crossing_axis and ((endpoint_resolution.get("firstSupport", {}) as Dictionary).is_empty() or (endpoint_resolution.get("secondSupport", {}) as Dictionary).is_empty()):
		endpoint_resolution = _interior_passage_endpoint_resolution(supports, access_position, -crossing_direction, endpoint_offset, floor_y, first_support_part_id, second_support_part_id)
	var first: Vector3 = endpoint_resolution.get("first", Vector3.ZERO) as Vector3
	var second: Vector3 = endpoint_resolution.get("second", Vector3.ZERO) as Vector3
	var first_support: Dictionary = endpoint_resolution.get("firstSupport", {}) as Dictionary
	var second_support: Dictionary = endpoint_resolution.get("secondSupport", {}) as Dictionary
	if first_support.is_empty() or second_support.is_empty():
		return {}
	first.y = _support_surface_y(first_support, first) + 0.04
	second.y = _support_surface_y(second_support, second) + 0.04
	if _support_seam_link_blocked(first, second, obstruction_parts):
		return {}
	var access_key := String(first_entry.get("accessKey", ""))
	var access_id := String(first_entry.get("accessId", ""))
	if access_key.is_empty() or access_id.is_empty():
		return {}
	var link_bounds := AABB(first, Vector3.ZERO).expand(second).grow(CELL * 0.18)
	return {
		"id": "building:%s:interior_passage:%s" % [blueprint_id, access_key],
		"sourceBlueprintId": blueprint_id,
		"sourceAccessId": access_id,
		"sourceAccessKey": access_key,
		"roomIds": [String(first_entry.get("roomId", "")), String(second_entry.get("roomId", ""))],
		"firstSupportId": String(first_support.get("id", "")),
		"secondSupportId": String(second_support.get("id", "")),
		"firstSupportPartId": String(first_support.get("sourcePartId", "")),
		"secondSupportPartId": String(second_support.get("sourcePartId", "")),
		"kind": "interior_passage",
		"semantic": "interior_passage",
		"start": first,
		"end": second,
		"bidirectional": true,
		"cost": first.distance_to(second),
		"bounds": link_bounds,
		"tileKeys": _tile_keys_for_bounds(link_bounds),
		"startTileKey": _tile_key_for_position(first),
		"endTileKey": _tile_key_for_position(second),
		"ownerTileKey": _tile_key_for_position(first)
	}


static func _interior_passage_endpoint_resolution(supports: Array[Dictionary], access_position: Vector3, crossing_direction: Vector3, endpoint_offset: float, floor_y: float, first_support_part_id: String, second_support_part_id: String) -> Dictionary:
	var first := access_position - crossing_direction * endpoint_offset
	var second := access_position + crossing_direction * endpoint_offset
	return {
		"first": first,
		"second": second,
		"firstSupport": _support_for_door_endpoint(supports, first, floor_y, first_support_part_id),
		"secondSupport": _support_for_door_endpoint(supports, second, floor_y, second_support_part_id)
	}


static func _projected_access_extent(access_size: Vector3, basis: Basis, direction: Vector3) -> float:
	var axis_x := basis * Vector3.RIGHT
	var axis_z := basis * Vector3.FORWARD
	axis_x.y = 0.0
	axis_z.y = 0.0
	if axis_x.length_squared() <= 0.0001 or axis_z.length_squared() <= 0.0001:
		return 0.0
	axis_x = axis_x.normalized()
	axis_z = axis_z.normalized()
	return absf(direction.dot(axis_x)) * access_size.x + absf(direction.dot(axis_z)) * access_size.z


static func _door_fact(blueprint_id: String, part, source_transform: Transform3D, bounds: AABB) -> Dictionary:
	var outward := source_transform.basis * Vector3(0.0, 0.0, -1.0)
	outward.y = 0.0
	if outward.length_squared() <= 0.0001:
		outward = Vector3(0.0, 0.0, -1.0)
	else:
		outward = outward.normalized()
	var endpoint_distance := maxf(part.size.z * 0.5 + DOOR_PORTAL_CLEARANCE, DOOR_PORTAL_MIN_STAGING_DISTANCE)
	var floor_y := bounds.position.y + 0.04
	var exterior := source_transform.origin + outward * endpoint_distance
	var interior := source_transform.origin - outward * endpoint_distance
	exterior.y = floor_y
	interior.y = floor_y
	return {
		"id": "building:%s:%s" % [blueprint_id, String(part.id)],
		"sourceBlueprintId": blueprint_id,
		"sourcePartId": String(part.id),
		"sourceCollisionPartId": String(part.id),
		"position": source_transform.origin,
		"rotation": source_transform.basis.get_euler(),
		"outward": outward,
		"interior": interior,
		"exterior": exterior,
		"sourcePortalReady": false,
		"bounds": bounds,
		"footprint": _footprint_polygon(source_transform, part.size),
		"tileKeys": _tile_keys_for_bounds(bounds)
	}


static func _resolve_door_portal_supports(door_fact: Dictionary, supports: Array[Dictionary]) -> void:
	var interior: Vector3 = door_fact.get("interior", Vector3.ZERO) as Vector3
	var exterior: Vector3 = door_fact.get("exterior", Vector3.ZERO) as Vector3
	var outward: Vector3 = door_fact.get("outward", Vector3.FORWARD) as Vector3
	if outward.length_squared() <= 0.0001:
		outward = Vector3.FORWARD
	else:
		outward = outward.normalized()
	interior -= outward * DOOR_PORTAL_SUPPORT_INSET
	exterior += outward * DOOR_PORTAL_SUPPORT_INSET
	var floor_y := minf(interior.y, exterior.y)
	var interior_support := _support_for_door_endpoint(supports, interior, floor_y)
	var exterior_support := _support_for_door_endpoint(supports, exterior, floor_y)
	if interior_support.is_empty() or exterior_support.is_empty():
		return
	interior.y = _support_surface_y(interior_support, interior) + 0.04
	exterior.y = _support_surface_y(exterior_support, exterior) + 0.04
	door_fact["interior"] = interior
	door_fact["exterior"] = exterior
	door_fact["interiorSupportId"] = String(interior_support.get("id", ""))
	door_fact["exteriorSupportId"] = String(exterior_support.get("id", ""))
	door_fact["sourcePortalReady"] = true
	var portal_bounds := AABB(interior, Vector3.ZERO).expand(exterior)
	portal_bounds = portal_bounds.grow(CELL * 0.18)
	door_fact["tileKeys"] = _tile_keys_for_bounds(portal_bounds)


static func _support_for_door_endpoint(supports: Array[Dictionary], position: Vector3, floor_y: float, preferred_source_part_id := "") -> Dictionary:
	var result: Dictionary = {}
	var highest_surface_y := -INF
	for support_value in supports:
		if not (support_value is Dictionary):
			continue
		var support: Dictionary = support_value
		if not preferred_source_part_id.is_empty() and String(support.get("sourcePartId", "")) != preferred_source_part_id:
			continue
		if not _point_within_support_xz(position, support):
			continue
		var support_y := _support_surface_y(support, position)
		var distance := absf(support_y - floor_y)
		if distance > CELL * 0.82 or support_y <= highest_surface_y:
			continue
		result = support
		highest_surface_y = support_y
	return result


static func _point_within_support_xz(position: Vector3, support: Dictionary) -> bool:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return false
	var inside := false
	var previous: Vector3 = polygon[polygon.size() - 1] if polygon[polygon.size() - 1] is Vector3 else Vector3.ZERO
	for point_value in polygon:
		if not (point_value is Vector3):
			return false
		var point: Vector3 = point_value
		var crosses := (point.z > position.z) != (previous.z > position.z)
		if crosses:
			var denominator := previous.z - point.z
			if absf(denominator) > 0.000001:
				var x_at_z := (previous.x - point.x) * (position.z - point.z) / denominator + point.x
				if position.x < x_at_z:
					inside = not inside
		previous = point
	return inside


static func _support_surface_y(support: Dictionary, position: Vector3) -> float:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() >= 3 and polygon[0] is Vector3 and polygon[1] is Vector3 and polygon[2] is Vector3:
		var a: Vector3 = polygon[0]
		var b: Vector3 = polygon[1]
		var c: Vector3 = polygon[2]
		var normal := (b - a).cross(c - a)
		if absf(normal.y) > 0.0001:
			return a.y - (normal.x * (position.x - a.x) + normal.z * (position.z - a.z)) / normal.y
	var center: Vector3 = support.get("worldPosition", position) if support.get("worldPosition", position) is Vector3 else position
	return center.y


static func _static_collision_fact(blueprint_id: String, part, source_transform: Transform3D, bounds: AABB) -> Dictionary:
	var source_part_id := String(part.id)
	return {
		"id": "building:%s:collision:%s" % [blueprint_id, source_part_id],
		"sourceBlueprintId": blueprint_id,
		"sourcePartId": source_part_id,
		"sourceCollisionPartId": source_part_id,
		"kind": String(part.kind),
		"semantic": String(part.semantic),
		"bounds": bounds,
		"footprint": _footprint_polygon(source_transform, part.size),
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


static func _footprint_polygon(source_transform: Transform3D, size: Vector3) -> Array[Vector3]:
	var half_x := size.x * 0.5
	var half_z := size.z * 0.5
	return [
		source_transform * Vector3(-half_x, 0.0, -half_z),
		source_transform * Vector3(-half_x, 0.0, half_z),
		source_transform * Vector3(half_x, 0.0, half_z),
		source_transform * Vector3(half_x, 0.0, -half_z)
	]


static func _footprint_intersects_corridor(first: Vector3, second: Vector3, clearance: float, footprint: Array) -> bool:
	if footprint.size() < 3:
		return true
	if _point_within_footprint_xz(first, footprint) or _point_within_footprint_xz(second, footprint):
		return true
	var first_point := Vector2(first.x, first.z)
	var second_point := Vector2(second.x, second.z)
	var clearance_squared := clearance * clearance
	var previous: Vector3 = footprint[footprint.size() - 1] if footprint[footprint.size() - 1] is Vector3 else Vector3.ZERO
	for point_value in footprint:
		if not (point_value is Vector3):
			return true
		var point: Vector3 = point_value
		var edge_start := Vector2(previous.x, previous.z)
		var edge_end := Vector2(point.x, point.z)
		if _segments_intersect_2d(first_point, second_point, edge_start, edge_end):
			return true
		if _point_to_segment_distance_squared(first_point, edge_start, edge_end) <= clearance_squared \
			or _point_to_segment_distance_squared(second_point, edge_start, edge_end) <= clearance_squared \
			or _point_to_segment_distance_squared(edge_start, first_point, second_point) <= clearance_squared \
			or _point_to_segment_distance_squared(edge_end, first_point, second_point) <= clearance_squared:
			return true
		previous = point
	return false


static func _point_within_footprint_xz(position: Vector3, footprint: Array) -> bool:
	if footprint.size() < 3:
		return false
	var inside := false
	var previous: Vector3 = footprint[footprint.size() - 1] if footprint[footprint.size() - 1] is Vector3 else Vector3.ZERO
	for point_value in footprint:
		if not (point_value is Vector3):
			return false
		var point: Vector3 = point_value
		var crosses := (point.z > position.z) != (previous.z > position.z)
		if crosses:
			var denominator := previous.z - point.z
			if absf(denominator) > 0.000001:
				var x_at_z := (previous.x - point.x) * (position.z - point.z) / denominator + point.x
				if position.x < x_at_z:
					inside = not inside
		previous = point
	return inside


static func _segments_intersect_2d(first_start: Vector2, first_end: Vector2, second_start: Vector2, second_end: Vector2) -> bool:
	var first_direction := first_end - first_start
	var second_direction := second_end - second_start
	var denominator := first_direction.cross(second_direction)
	var delta := second_start - first_start
	if absf(denominator) <= 0.000001:
		if absf(delta.cross(first_direction)) > 0.000001:
			return false
		var first_length_squared := first_direction.length_squared()
		if first_length_squared <= 0.000001:
			return first_start.distance_squared_to(second_start) <= 0.000001
		var start_projection := delta.dot(first_direction) / first_length_squared
		var end_projection := (second_end - first_start).dot(first_direction) / first_length_squared
		return maxf(minf(start_projection, end_projection), 0.0) <= minf(maxf(start_projection, end_projection), 1.0)
	var first_t := delta.cross(second_direction) / denominator
	var second_t := delta.cross(first_direction) / denominator
	return first_t >= -0.000001 and first_t <= 1.000001 and second_t >= -0.000001 and second_t <= 1.000001


static func _point_to_segment_distance_squared(point: Vector2, segment_start: Vector2, segment_end: Vector2) -> float:
	var segment := segment_end - segment_start
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return point.distance_squared_to(segment_start)
	var projection := clampf((point - segment_start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(segment_start + segment * projection)


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
	var min_x := floori(bounds.position.x / CELL + 0.5)
	var max_x := floori(bounds.end.x / CELL + 0.5)
	var min_z := floori(bounds.position.z / CELL + 0.5)
	var max_z := floori(bounds.end.z / CELL + 0.5)
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


static func _tile_key_for_position(position: Vector3) -> String:
	var tile_cells := NpcConstantsScript.NAV_TILE_CELL_SIZE
	var cell_x := roundi(position.x / CELL)
	var cell_z := roundi(position.z / CELL)
	return "%d,%d" % [
		floori(float(cell_x) / float(tile_cells)),
		floori(float(cell_z) / float(tile_cells))
	]
