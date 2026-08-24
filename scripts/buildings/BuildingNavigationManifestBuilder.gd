extends RefCounted
class_name BuildingNavigationManifestBuilder

## Emits immutable navigation facts from the exact BuildingPart records that
## publish construction collision.  It never inspects meshes or physics nodes:
## those are products of the same source parts, not a second authority.

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const BuildingNavigationTransitionCertifierScript := preload("res://scripts/buildings/BuildingNavigationTransitionCertifier.gd")

const SCHEMA_VERSION := 8
const CELL := NpcConstantsScript.CELL_SIZE
const MIN_WALKABLE_NORMAL_Y := 0.68
const DOOR_PORTAL_CLEARANCE := NpcConstantsScript.DEFAULT_NPC_RADIUS + 0.24
const DOOR_PORTAL_SUPPORT_INSET := CELL * 0.18
const DOOR_PORTAL_MIN_STAGING_DISTANCE := CELL * 1.10
const DOOR_PORTAL_STAGING_CLEARANCE := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
const DOOR_PORTAL_STAGING_STEP := CELL * 0.08
const DOOR_PORTAL_STAGING_MAX_ADJUSTMENT := CELL * 0.90
const DOOR_PORTAL_MAX_SUPPORT_HEIGHT_DELTA := CELL * 0.82
const SUPPORT_SEAM_MIN_NORMAL_Y := 0.985
const SUPPORT_SEAM_LINK_INSET := CELL * 0.24
const SUPPORT_SEAM_CLEARANCE := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
const SUPPORT_SEAM_MIN_WIDTH := SUPPORT_SEAM_CLEARANCE * 2.0
const INTERIOR_PASSAGE_ENDPOINT_INSET := CELL * 0.08
const INTERIOR_PASSAGE_MIN_CROSSING := CELL * 1.10
const INTERIOR_PASSAGE_MIN_WIDTH := SUPPORT_SEAM_CLEARANCE * 2.0 + CELL * 0.50
const NAVIGATION_ROLE_WALKABLE_SUPPORT := "walkable_support"
const NAVIGATION_ROLE_STRUCTURAL_MASS := "structural_mass"
const NAVIGATION_ROLE_TRANSITION := "transition"
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
	var interior_passage_rejections: Array[Dictionary] = []
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
		_resolve_door_portal_supports(door_fact, supports, static_collision_parts)
	for vertical_link in vertical_links:
		_resolve_vertical_link_supports(vertical_link, supports, static_collision_parts)
	for door_fact in door_facts:
		_resolve_required_door_egress(door_fact, vertical_links)
	support_seam_links = _support_seam_link_facts(source_blueprint_id, supports, static_collision_parts, door_facts)
	var interior_passage_result := _interior_passage_link_facts(source_blueprint_id, blueprint.rooms, parent_transform, supports, static_collision_parts, door_facts)
	interior_passage_links = interior_passage_result.get("links", []) as Array[Dictionary]
	interior_passage_rejections = interior_passage_result.get("rejections", []) as Array[Dictionary]
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
		"interiorPassageRejections": interior_passage_rejections,
		"doors": door_facts,
		"staticCollision": static_collision_parts,
		"supportCount": supports.size(),
		"verticalLinkCount": vertical_links.size(),
		"supportSeamLinkCount": support_seam_links.size(),
		"interiorPassageLinkCount": interior_passage_links.size(),
		"interiorPassageRejectionCount": interior_passage_rejections.size(),
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
		"interiorPassageRejections": [],
		"doors": [],
		"staticCollision": [],
		"supportCount": 0,
		"verticalLinkCount": 0,
		"supportSeamLinkCount": 0,
		"interiorPassageLinkCount": 0,
		"interiorPassageRejectionCount": 0,
		"doorCount": 0,
		"staticCollisionCount": 0
	}


static func _is_walkable_support_part(part) -> bool:
	var navigation_role := _navigation_role(part)
	if not navigation_role.is_empty():
		return navigation_role in [NAVIGATION_ROLE_WALKABLE_SUPPORT, NAVIGATION_ROLE_TRANSITION]
	var kind := String(part.kind)
	if kind in ["floor", "ramp"]:
		return true
	if kind != "foundation":
		return false
	var semantic := String(part.semantic).to_lower()
	return semantic.contains("paving") or semantic.contains("courtyard") or semantic.contains("walkway") or semantic.contains("landing") or semantic.contains("floor")


static func _is_vertical_link_part(part) -> bool:
	return String(part.kind) == "ramp" and (_navigation_role(part) == NAVIGATION_ROLE_TRANSITION or _navigation_role(part).is_empty())


static func _navigation_role(part) -> String:
	if part == null or not (part.recipe is Dictionary):
		return ""
	var role := String((part.recipe as Dictionary).get("navigationRole", "")).strip_edges().to_lower()
	if role in [NAVIGATION_ROLE_WALKABLE_SUPPORT, NAVIGATION_ROLE_STRUCTURAL_MASS, NAVIGATION_ROLE_TRANSITION]:
		return role
	return ""


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
		"navigationRole": _navigation_role(part),
		"minimumNavigationLaneCount": maxi(0, int((part.recipe as Dictionary).get("minimumNavigationLaneCount", 0))) if part.recipe is Dictionary else 0,
		"semantic": String(part.semantic),
		"egressOwnerDoorPartId": String((part.recipe as Dictionary).get("doorEgressFor", "")) if part.recipe is Dictionary else "",
		"cell": world_cell,
		"worldPosition": top_center,
		"floorNormal": normal,
		"polygon": top_polygon,
		"bounds": bounds,
		"headroom": 3.0,
		"lateralClearance": maxf(0.1, minf(size.x, size.z) * 0.5),
		"traversalTags": ["building", "support", String(part.kind)],
		"tileKeys": _tile_keys_for_bounds(bounds),
		"producerTileKey": _tile_key_for_position(top_center)
	}


static func _vertical_link_fact(blueprint_id: String, part, source_transform: Transform3D, bounds: AABB) -> Dictionary:
	var size: Vector3 = part.size
	var top_offset := size.y * 0.5
	var first: Vector3 = source_transform * Vector3(0.0, top_offset, -size.z * 0.5)
	var second: Vector3 = source_transform * Vector3(0.0, top_offset, size.z * 0.5)
	var minimum_rise := 0.01 if _navigation_role(part) == NAVIGATION_ROLE_TRANSITION else CELL * 0.12
	if absf(first.y - second.y) < minimum_rise:
		return {}
	var start := first if first.y <= second.y else second
	var end := second if first.y <= second.y else first
	var source_part_id := String(part.id)
	return {
		"id": "building:%s:vertical:%s" % [blueprint_id, source_part_id],
		"sourceBlueprintId": blueprint_id,
		"sourcePartId": source_part_id,
		"sourceCollisionPartId": source_part_id,
		"startSupportPartId": String((part.recipe as Dictionary).get("navigationStartSupportPartId", "")) if part.recipe is Dictionary else "",
		"endSupportPartId": String((part.recipe as Dictionary).get("navigationEndSupportPartId", "")) if part.recipe is Dictionary else "",
		"kind": "stair_ramp",
		"semantic": String(part.semantic),
		"egressOwnerDoorPartId": String((part.recipe as Dictionary).get("doorEgressFor", "")) if part.recipe is Dictionary else "",
		"declaredTransition": _navigation_role(part) == NAVIGATION_ROLE_TRANSITION,
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


static func _resolve_vertical_link_supports(link: Dictionary, supports: Array[Dictionary], static_collision_parts: Array[Dictionary]) -> void:
	var source_part_id := String(link.get("sourceCollisionPartId", link.get("sourcePartId", "")))
	var start: Vector3 = link.get("start", Vector3.INF) as Vector3
	var end: Vector3 = link.get("end", Vector3.INF) as Vector3
	if source_part_id.is_empty() or not start.is_finite() or not end.is_finite():
		return
	var start_support := _support_for_vertical_link_endpoint(supports, start, source_part_id, String(link.get("startSupportPartId", "")))
	var end_support := _support_for_vertical_link_endpoint(supports, end, source_part_id, String(link.get("endSupportPartId", "")))
	if start_support.is_empty() or end_support.is_empty():
		return
	link["startSupportId"] = String(start_support.get("id", ""))
	link["endSupportId"] = String(end_support.get("id", ""))
	var egress_owner_door_part_id := String(link.get("egressOwnerDoorPartId", ""))
	if not egress_owner_door_part_id.is_empty() and (String(start_support.get("egressOwnerDoorPartId", "")) != egress_owner_door_part_id or String(end_support.get("egressOwnerDoorPartId", "")) != egress_owner_door_part_id):
		link["endpointCertification"] = {"resolved": false, "reason": "egress_support_owner_mismatch", "egressOwnerDoorPartId": egress_owner_door_part_id, "startSupportOwner": String(start_support.get("egressOwnerDoorPartId", "")), "endSupportOwner": String(end_support.get("egressOwnerDoorPartId", ""))}
		return
	var transition_axis := end - start
	transition_axis.y = 0.0
	var start_resolution := BuildingNavigationTransitionCertifierScript.certify_endpoint(start_support, start, transition_axis, DOOR_PORTAL_STAGING_CLEARANCE, func(position: Vector3) -> Dictionary: return _static_collision_blocking_npc_clearance(position, static_collision_parts))
	var end_resolution := BuildingNavigationTransitionCertifierScript.certify_endpoint(end_support, end, transition_axis, DOOR_PORTAL_STAGING_CLEARANCE, func(position: Vector3) -> Dictionary: return _static_collision_blocking_npc_clearance(position, static_collision_parts))
	link["endpointCertification"] = {"start": start_resolution, "end": end_resolution, "resolved": bool(start_resolution.get("resolved", false)) and bool(end_resolution.get("resolved", false))}
	if not bool(start_resolution.get("resolved", false)) or not bool(end_resolution.get("resolved", false)):
		return
	link["authoredStart"] = start
	link["authoredEnd"] = end
	link["start"] = start_resolution.get("position", start)
	link["end"] = end_resolution.get("position", end)


static func _resolve_required_door_egress(door_fact: Dictionary, vertical_links: Array[Dictionary]) -> void:
	var door_egress: Dictionary = door_fact.get("doorEgress", {}) as Dictionary
	if door_egress.is_empty():
		return
	var outward_endpoint_part_id := String(door_egress.get("outwardEndpointPartId", ""))
	var required_link: Dictionary = {}
	for link_value in vertical_links:
		if link_value is Dictionary and String((link_value as Dictionary).get("sourcePartId", "")) == outward_endpoint_part_id:
			required_link = link_value as Dictionary
			break
	var resolved := not outward_endpoint_part_id.is_empty() \
		and not required_link.is_empty() \
		and String(required_link.get("egressOwnerDoorPartId", "")) == String(door_fact.get("sourcePartId", "")) \
		and not String(required_link.get("startSupportId", "")).is_empty() \
		and not String(required_link.get("endSupportId", "")).is_empty() \
		and bool((required_link.get("endpointCertification", {}) as Dictionary).get("resolved", false))
	door_fact["egressResolution"] = {
		"resolved": resolved,
		"outwardEndpointPartId": outward_endpoint_part_id,
		"verticalLinkId": String(required_link.get("id", "")),
		"startSupportId": String(required_link.get("startSupportId", "")),
		"endSupportId": String(required_link.get("endSupportId", "")),
		"reason": "" if resolved else "required_egress_transition_unresolved"
	}
	if not resolved:
		door_fact["sourcePortalReady"] = false
		var portal_resolution: Dictionary = door_fact.get("portalSupportResolution", {}) as Dictionary
		portal_resolution["sourcePortalReady"] = false
		portal_resolution["reason"] = "required_egress_transition_unresolved"
		door_fact["portalSupportResolution"] = portal_resolution


static func _support_for_vertical_link_endpoint(supports: Array[Dictionary], position: Vector3, source_part_id: String, preferred_support_part_id := "") -> Dictionary:
	var result: Dictionary = {}
	var best_distance := INF
	var best_id := ""
	for support_value in supports:
		if not (support_value is Dictionary):
			continue
		var support: Dictionary = support_value
		if String(support.get("sourceCollisionPartId", support.get("sourcePartId", ""))) == source_part_id:
			continue
		if not preferred_support_part_id.is_empty() and String(support.get("sourcePartId", "")) != preferred_support_part_id:
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
	return not _support_seam_link_blocker(first, second, obstruction_parts).is_empty()


static func _support_seam_link_blocker(first: Vector3, second: Vector3, obstruction_parts: Array[Dictionary]) -> Dictionary:
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
			return obstruction
	return {}


static func _interior_passage_link_facts(blueprint_id: String, room_records: Array, parent_transform: Transform3D, supports: Array[Dictionary], static_collision_parts: Array[Dictionary], door_facts: Array[Dictionary]) -> Dictionary:
	var passages_by_key := {}
	var rejections: Array[Dictionary] = []
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
				rejections.append({
					"sourceAccessId": access_id,
					"roomId": room_id,
					"reason": "passage_access_record_malformed",
					"accessSize": access_size
				})
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
				"endpointSide": int(access.get("endpointSide", 0)),
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
		if entries.size() != 2:
			rejections.append({"sourceAccessKey": access_key, "reason": "passage_requires_exactly_two_entries", "entryCount": entries.size()})
			continue
		var pair := _furthest_interior_passage_entries(entries)
		if pair.size() != 2:
			rejections.append({"sourceAccessKey": access_key, "reason": "passage_requires_two_distinct_rooms", "entryCount": entries.size()})
			continue
		var link := _interior_passage_link_fact(blueprint_id, pair[0] as Dictionary, pair[1] as Dictionary, parent_transform, supports, obstruction_parts, rejections)
		if not link.is_empty():
			result.append(link)
	return {"links": result, "rejections": rejections}


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


static func _interior_passage_link_fact(blueprint_id: String, first_entry: Dictionary, second_entry: Dictionary, parent_transform: Transform3D, supports: Array[Dictionary], obstruction_parts: Array[Dictionary], rejections: Array[Dictionary]) -> Dictionary:
	var first_position: Vector3 = first_entry.get("worldPosition", Vector3.INF) as Vector3
	var second_position: Vector3 = second_entry.get("worldPosition", Vector3.INF) as Vector3
	var first_size: Vector3 = first_entry.get("localSize", Vector3.ZERO) as Vector3
	var second_size: Vector3 = second_entry.get("localSize", Vector3.ZERO) as Vector3
	var first_basis: Basis = first_entry.get("worldAccessBasis", Basis.IDENTITY) as Basis
	var second_basis: Basis = second_entry.get("worldAccessBasis", Basis.IDENTITY) as Basis
	if not first_position.is_finite() or not second_position.is_finite() or first_position.distance_squared_to(second_position) > 0.000001 \
		or first_size.distance_squared_to(second_size) > 0.000001 or not _passage_bases_match(first_basis, second_basis):
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "passage_entry_geometry_mismatch",
			"firstPosition": first_position,
			"secondPosition": second_position,
			"firstSize": first_size,
			"secondSize": second_size
		})
		return {}
	if first_size.y < NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT:
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "passage_height_undersized",
			"passageHeight": first_size.y,
			"minimumPassageHeight": NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
		})
		return {}
	var first_support_part_id := String(first_entry.get("supportPartId", ""))
	var second_support_part_id := String(second_entry.get("supportPartId", ""))
	var first_axis: Vector3 = first_entry.get("worldCrossingAxis", Vector3.ZERO) as Vector3
	var second_axis: Vector3 = second_entry.get("worldCrossingAxis", Vector3.ZERO) as Vector3
	first_axis.y = 0.0
	second_axis.y = 0.0
	var first_endpoint_side := int(first_entry.get("endpointSide", 0))
	var second_endpoint_side := int(second_entry.get("endpointSide", 0))
	if first_support_part_id.is_empty() or second_support_part_id.is_empty() or not first_axis.is_finite() or not second_axis.is_finite() or first_axis.length_squared() <= 0.0001 or second_axis.length_squared() <= 0.0001:
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "passage_provenance_missing",
			"firstSupportPartId": first_support_part_id,
			"secondSupportPartId": second_support_part_id,
			"firstCrossingAxis": first_axis,
			"secondCrossingAxis": second_axis
		})
		return {}
	first_axis = first_axis.normalized()
	second_axis = second_axis.normalized()
	if first_axis.dot(second_axis) < 0.999:
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "declared_passage_axes_misaligned",
			"firstCrossingAxis": first_axis,
			"secondCrossingAxis": second_axis
		})
		return {}
	var declared_first_support := _support_with_source_part_id(supports, first_support_part_id)
	var declared_second_support := _support_with_source_part_id(supports, second_support_part_id)
	if first_endpoint_side not in [-1, 1] or second_endpoint_side not in [-1, 1] or first_endpoint_side == second_endpoint_side:
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "declared_passage_endpoint_sides_invalid",
			"firstEndpointSide": first_endpoint_side,
			"secondEndpointSide": second_endpoint_side
		})
		return {}
	if declared_first_support.is_empty() or declared_second_support.is_empty():
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "declared_passage_support_missing",
			"firstSupportPartId": first_support_part_id,
			"secondSupportPartId": second_support_part_id,
			"firstResolved": not declared_first_support.is_empty(),
			"secondResolved": not declared_second_support.is_empty()
		})
		return {}
	var crossing_direction := first_axis
	var access_position: Vector3 = first_entry.get("worldPosition", Vector3.ZERO) as Vector3
	var access_size: Vector3 = first_entry.get("localSize", Vector3.ZERO) as Vector3
	var access_basis: Basis = first_entry.get("worldAccessBasis", parent_transform.basis) as Basis
	var crossing_extent := _projected_access_extent(access_size, access_basis, crossing_direction)
	var lateral_direction := Vector3(-crossing_direction.z, 0.0, crossing_direction.x)
	var passage_width := _projected_access_extent(access_size, access_basis, lateral_direction)
	if crossing_extent < INTERIOR_PASSAGE_MIN_CROSSING or passage_width < INTERIOR_PASSAGE_MIN_WIDTH:
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "passage_clearance_undersized",
			"crossingExtent": crossing_extent,
			"minimumCrossingExtent": INTERIOR_PASSAGE_MIN_CROSSING,
			"passageWidth": passage_width,
			"minimumPassageWidth": INTERIOR_PASSAGE_MIN_WIDTH
		})
		return {}
	var endpoint_offset := crossing_extent * 0.5 - INTERIOR_PASSAGE_ENDPOINT_INSET
	if endpoint_offset <= SUPPORT_SEAM_CLEARANCE:
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "passage_endpoint_inset_unresolvable",
			"endpointOffset": endpoint_offset,
			"minimumEndpointOffset": SUPPORT_SEAM_CLEARANCE
		})
		return {}
	var endpoint_resolution := _declared_interior_passage_endpoint_resolution(access_position, crossing_direction, endpoint_offset, declared_first_support, declared_second_support, first_endpoint_side, second_endpoint_side)
	var first: Vector3 = endpoint_resolution.get("first", Vector3.ZERO) as Vector3
	var second: Vector3 = endpoint_resolution.get("second", Vector3.ZERO) as Vector3
	var first_support: Dictionary = endpoint_resolution.get("firstSupport", {}) as Dictionary
	var second_support: Dictionary = endpoint_resolution.get("secondSupport", {}) as Dictionary
	if first_support.is_empty() or second_support.is_empty():
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "passage_endpoint_support_unresolved",
			"firstSupportPartId": first_support_part_id,
			"secondSupportPartId": second_support_part_id,
			"firstResolved": not first_support.is_empty(),
			"secondResolved": not second_support.is_empty(),
			"accessPosition": access_position,
			"crossingDirection": crossing_direction,
			"firstEndpointSide": first_endpoint_side,
			"secondEndpointSide": second_endpoint_side,
			"first": endpoint_resolution.get("first", Vector3.INF),
			"second": endpoint_resolution.get("second", Vector3.INF),
			"firstPreferredSupport": _support_diagnostic_for_source_part(supports, first_support_part_id),
			"secondPreferredSupport": _support_diagnostic_for_source_part(supports, second_support_part_id)
		})
		return {}
	first.y = _support_surface_y(first_support, first) + 0.04
	second.y = _support_surface_y(second_support, second) + 0.04
	var passage_blocker := _support_seam_link_blocker(first, second, obstruction_parts)
	if not passage_blocker.is_empty():
		rejections.append({
			"sourceAccessKey": String(first_entry.get("accessKey", "")),
			"sourceAccessId": String(first_entry.get("accessId", "")),
			"reason": "passage_collision_blocked",
			"firstSupportPartId": first_support_part_id,
			"secondSupportPartId": second_support_part_id,
			"start": first,
			"end": second,
			"blockerId": String(passage_blocker.get("id", "")),
			"blockerSourcePartId": String(passage_blocker.get("sourcePartId", "")),
			"blockerBounds": passage_blocker.get("bounds", AABB())
		})
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


static func _passage_bases_match(first: Basis, second: Basis) -> bool:
	return first.x.distance_squared_to(second.x) <= 0.000001 \
		and first.y.distance_squared_to(second.y) <= 0.000001 \
		and first.z.distance_squared_to(second.z) <= 0.000001


static func _declared_interior_passage_endpoint_resolution(access_position: Vector3, crossing_direction: Vector3, maximum_offset: float, first_support: Dictionary, second_support: Dictionary, first_endpoint_side: int, second_endpoint_side: int) -> Dictionary:
	var first := _inset_position_on_declared_support(access_position, crossing_direction * float(first_endpoint_side), first_support, maximum_offset)
	var second := _inset_position_on_declared_support(access_position, crossing_direction * float(second_endpoint_side), second_support, maximum_offset)
	return {
		"first": first,
		"second": second,
		"firstSupport": first_support if first.is_finite() else {},
		"secondSupport": second_support if second.is_finite() else {}
	}


static func _inset_position_on_declared_support(access_position: Vector3, direction: Vector3, support: Dictionary, maximum_offset: float) -> Vector3:
	direction.y = 0.0
	if direction.length_squared() <= 0.0001:
		return Vector3.INF
	direction = direction.normalized()
	var best := access_position
	var found := false
	for step in range(13):
		var candidate := access_position + direction * (maximum_offset * float(step) / 12.0)
		if _point_within_support_xz(candidate, support):
			best = candidate
			found = true
	if not found:
		return Vector3.INF
	return best


static func _support_diagnostic_for_source_part(supports: Array[Dictionary], source_part_id: String) -> Dictionary:
	var support := _support_with_source_part_id(supports, source_part_id)
	if not support.is_empty():
		return {
			"id": String(support.get("id", "")),
			"worldPosition": support.get("worldPosition", Vector3.INF),
			"polygon": (support.get("polygon", []) as Array).duplicate()
		}
	return {}


static func _support_with_source_part_id(supports: Array[Dictionary], source_part_id: String) -> Dictionary:
	for support_value in supports:
		if support_value is Dictionary and String((support_value as Dictionary).get("sourcePartId", "")) == source_part_id:
			return support_value as Dictionary
	return {}


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
	var door_egress: Dictionary = (part.recipe as Dictionary).get("doorEgress", {}) as Dictionary if part.recipe is Dictionary else {}
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
		"doorEgress": door_egress.duplicate(true),
		"bounds": bounds,
		"footprint": _footprint_polygon(source_transform, part.size),
		"tileKeys": _tile_keys_for_bounds(bounds)
	}


static func _resolve_door_portal_supports(door_fact: Dictionary, supports: Array[Dictionary], static_collision_parts: Array[Dictionary]) -> void:
	var authored_interior: Vector3 = door_fact.get("interior", Vector3.ZERO) as Vector3
	var authored_exterior: Vector3 = door_fact.get("exterior", Vector3.ZERO) as Vector3
	var interior := authored_interior
	var exterior := authored_exterior
	var outward: Vector3 = door_fact.get("outward", Vector3.FORWARD) as Vector3
	if outward.length_squared() <= 0.0001:
		outward = Vector3.FORWARD
	else:
		outward = outward.normalized()
	interior -= outward * DOOR_PORTAL_SUPPORT_INSET
	exterior += outward * DOOR_PORTAL_SUPPORT_INSET
	var floor_y := minf(interior.y, exterior.y)
	var interior_owner_prefix := _door_interior_support_owner_prefix(String(door_fact.get("sourcePartId", "")))
	var interior_resolution := _door_staging_resolution(supports, static_collision_parts, interior, floor_y, outward, interior_owner_prefix)
	var exterior_resolution := _door_staging_resolution(supports, static_collision_parts, exterior, floor_y, outward)
	var interior_support: Dictionary = interior_resolution.get("support", {}) as Dictionary
	var exterior_support: Dictionary = exterior_resolution.get("support", {}) as Dictionary
	if not bool(interior_resolution.get("resolved", false)) or not bool(exterior_resolution.get("resolved", false)):
		door_fact["portalSupportResolution"] = {
			"resolved": false,
			"sourcePortalReady": false,
			"interiorOwnerPrefix": interior_owner_prefix,
			"authoredInterior": authored_interior,
			"authoredExterior": authored_exterior,
			"interior": _portal_support_diagnostic(interior_resolution),
			"exterior": _portal_support_diagnostic(exterior_resolution)
		}
		return
	interior = interior_resolution.get("position", interior) as Vector3
	exterior = exterior_resolution.get("position", exterior) as Vector3
	var corridor_resolution := _door_portal_corridor_resolution(door_fact, interior, exterior, supports, static_collision_parts)
	if not bool(corridor_resolution.get("resolved", false)):
		door_fact["portalSupportResolution"] = {
			"resolved": false,
			"sourcePortalReady": false,
			"reason": "portal_corridor_blocked",
			"interiorOwnerPrefix": interior_owner_prefix,
			"authoredInterior": authored_interior,
			"authoredExterior": authored_exterior,
			"interior": _portal_support_diagnostic(interior_resolution),
			"exterior": _portal_support_diagnostic(exterior_resolution),
			"corridor": corridor_resolution
		}
		return
	door_fact["interior"] = interior
	door_fact["exterior"] = exterior
	door_fact["interiorSupportId"] = String(interior_support.get("id", ""))
	door_fact["exteriorSupportId"] = String(exterior_support.get("id", ""))
	door_fact["interiorTileKey"] = _tile_key_for_position(interior)
	door_fact["exteriorTileKey"] = _tile_key_for_position(exterior)
	door_fact["ownerTileKey"] = String(door_fact.get("interiorTileKey", ""))
	door_fact["sourcePortalReady"] = true
	door_fact["portalSupportResolution"] = {
		"resolved": true,
		"sourcePortalReady": true,
		"interiorOwnerPrefix": interior_owner_prefix,
		"authoredInterior": authored_interior,
		"authoredExterior": authored_exterior,
		"interior": _portal_support_diagnostic(interior_resolution),
		"exterior": _portal_support_diagnostic(exterior_resolution),
		"corridor": corridor_resolution
	}
	var portal_bounds := AABB(interior, Vector3.ZERO).expand(exterior)
	portal_bounds = portal_bounds.grow(CELL * 0.18)
	door_fact["tileKeys"] = _tile_keys_for_bounds(portal_bounds)


static func _portal_support_diagnostic(resolution: Dictionary) -> Dictionary:
	return {
		"resolved": bool(resolution.get("resolved", false)),
		"reason": String(resolution.get("reason", "")),
		"requestedPosition": resolution.get("requestedPosition", Vector3.INF),
		"selectedPosition": resolution.get("position", Vector3.INF),
		"supportId": String(resolution.get("supportId", "")),
		"sourcePartPrefix": String(resolution.get("sourcePartPrefix", "")),
		"floorDistance": float(resolution.get("floorDistance", INF)),
		"adjustment": float(resolution.get("adjustment", INF)),
		"candidateWindowMargin": float(resolution.get("candidateWindowMargin", 0.0)),
		"candidates": resolution.get("candidates", [])
	}


static func _door_interior_support_owner_prefix(source_part_id: String) -> String:
	var delimiter := source_part_id.find("__")
	return source_part_id.left(delimiter + 2) if delimiter >= 0 else ""


static func _door_staging_resolution(supports: Array[Dictionary], static_collision_parts: Array[Dictionary], requested_position: Vector3, floor_y: float, crossing_axis: Vector3, source_part_prefix := "") -> Dictionary:
	var direction := crossing_axis
	direction.y = 0.0
	if direction.length_squared() <= 0.0001:
		direction = Vector3.FORWARD
	else:
		direction = direction.normalized()
	var best: Dictionary = {}
	var best_floor_distance := INF
	var best_adjustment := INF
	var best_area := INF
	var best_id := ""
	var first_collision_blocker: Dictionary = {}
	var candidates: Array[Dictionary] = []
	var search_margin := DOOR_PORTAL_STAGING_CLEARANCE + DOOR_PORTAL_STAGING_MAX_ADJUSTMENT + CELL * 0.05
	for support_value in supports:
		if not (support_value is Dictionary):
			continue
		var support: Dictionary = support_value
		var support_id := String(support.get("id", ""))
		if support_id.is_empty():
			continue
		var source_part_id := String(support.get("sourcePartId", ""))
		if not source_part_prefix.is_empty() and not source_part_id.begins_with(source_part_prefix):
			continue
		if not _support_intersects_staging_window(support, requested_position, search_margin):
			continue
		var support_y := _support_surface_y(support, requested_position)
		var floor_distance := absf(support_y - floor_y)
		var support_area := _support_footprint_area(support)
		if floor_distance > DOOR_PORTAL_MAX_SUPPORT_HEIGHT_DELTA:
			candidates.append({
				"supportId": support_id,
				"supportSurfaceY": support_y,
				"floorDistance": floor_distance,
				"requestedPosition": requested_position,
				"resolved": false,
				"reason": "support_plane_out_of_range",
				"edgeClearance": -1.0,
				"adjustment": INF
			})
			continue
		var staging := _nearest_safe_door_staging_position(requested_position, direction, support)
		var candidate: Dictionary = {
			"supportId": support_id,
			"supportSurfaceY": support_y,
			"floorDistance": floor_distance,
			"supportArea": support_area,
			"requestedPosition": requested_position,
			"resolved": bool(staging.get("resolved", false)),
			"reason": String(staging.get("reason", "")),
			"edgeClearance": float(staging.get("edgeClearance", -1.0)),
			"adjustment": float(staging.get("adjustment", INF))
		}
		if bool(staging.get("resolved", false)):
			var position: Vector3 = staging.get("position", requested_position) as Vector3
			position.y = _support_surface_y(support, position) + 0.04
			candidate["position"] = position
			var blocker := _static_collision_blocking_npc_clearance(position, static_collision_parts)
			if not blocker.is_empty():
				candidate["resolved"] = false
				candidate["reason"] = "endpoint_embedded_in_static_collision"
				candidate["blocker"] = blocker
				if first_collision_blocker.is_empty():
					first_collision_blocker = blocker
		candidates.append(candidate)
		if not bool(candidate.get("resolved", false)):
			continue
		var adjustment := float(staging.get("adjustment", INF))
		if floor_distance > best_floor_distance + 0.0001:
			continue
		if is_equal_approx(floor_distance, best_floor_distance) and adjustment > best_adjustment + 0.0001:
			continue
		if is_equal_approx(floor_distance, best_floor_distance) and is_equal_approx(adjustment, best_adjustment) and support_area > best_area + 0.0001:
			continue
		if is_equal_approx(floor_distance, best_floor_distance) and is_equal_approx(adjustment, best_adjustment) and is_equal_approx(support_area, best_area) and not best_id.is_empty() and support_id >= best_id:
			continue
		best = {"support": support, "position": candidate.get("position", requested_position)}
		best_floor_distance = floor_distance
		best_adjustment = adjustment
		best_area = support_area
		best_id = support_id
	candidates.sort_custom(func(first: Dictionary, second: Dictionary) -> bool: return String(first.get("supportId", "")) < String(second.get("supportId", "")))
	if best.is_empty():
		return {"resolved": false, "requestedPosition": requested_position, "reason": "endpoint_embedded_in_static_collision" if not first_collision_blocker.is_empty() else "no_npc_clearance_support", "blocker": first_collision_blocker, "sourcePartPrefix": source_part_prefix, "candidateWindowMargin": search_margin, "candidates": candidates}
	return {
		"resolved": true,
		"requestedPosition": requested_position,
		"position": best.get("position", requested_position),
		"support": best.get("support", {}),
		"supportId": best_id,
		"floorDistance": best_floor_distance,
		"adjustment": best_adjustment,
		"supportArea": best_area,
		"sourcePartPrefix": source_part_prefix,
		"candidateWindowMargin": search_margin,
		"candidates": candidates
	}


static func _door_portal_corridor_resolution(door_fact: Dictionary, interior: Vector3, exterior: Vector3, supports: Array[Dictionary], static_collision_parts: Array[Dictionary]) -> Dictionary:
	const CORRIDOR_SAMPLE_COUNT := 8
	var samples: Array[Dictionary] = []
	for sample_index in range(CORRIDOR_SAMPLE_COUNT + 1):
		var progress := float(sample_index) / float(CORRIDOR_SAMPLE_COUNT)
		var requested := interior.lerp(exterior, progress)
		var support := _support_for_door_endpoint(supports, requested, requested.y)
		if support.is_empty():
			return {"resolved": false, "reason": "portal_corridor_missing_support", "sampleIndex": sample_index, "samples": samples}
		var position := requested
		position.y = _support_surface_y(support, position) + 0.04
		var blocker := _static_collision_blocking_npc_clearance(position, static_collision_parts)
		var sample := {
			"index": sample_index,
			"requestedPosition": requested,
			"position": position,
			"supportId": String(support.get("id", "")),
			"blocker": blocker,
			"passed": blocker.is_empty()
		}
		samples.append(sample)
		if not blocker.is_empty():
			return {"resolved": false, "reason": "portal_corridor_blocked", "sampleIndex": sample_index, "blocker": blocker, "samples": samples}
	return {
		"resolved": true,
		"sourceDoorPosition": door_fact.get("position", Vector3.INF),
		"samples": samples
	}


static func _static_collision_blocking_npc_clearance(position: Vector3, static_collision_parts: Array[Dictionary]) -> Dictionary:
	var radius := DOOR_PORTAL_STAGING_CLEARANCE
	var clearance_bottom := position.y + 0.01
	var clearance_top := clearance_bottom + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
	for fact_value in static_collision_parts:
		if not (fact_value is Dictionary):
			continue
		var fact: Dictionary = fact_value as Dictionary
		var bounds: AABB = fact.get("bounds", AABB()) if fact.get("bounds", AABB()) is AABB else AABB()
		if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
			continue
		if bounds.end.y <= clearance_bottom or bounds.position.y >= clearance_top:
			continue
		if position.x + radius <= bounds.position.x or position.x - radius >= bounds.end.x:
			continue
		if position.z + radius <= bounds.position.z or position.z - radius >= bounds.end.z:
			continue
		var footprint: Array = fact.get("footprint", []) if fact.get("footprint", []) is Array else []
		if not footprint.is_empty() and not _footprint_intersects_corridor(position, position, radius, footprint):
			continue
		return {
			"id": String(fact.get("id", "")),
			"sourcePartId": String(fact.get("sourcePartId", "")),
			"semantic": String(fact.get("semantic", "")),
			"bounds": bounds,
			"position": position,
			"clearanceRadius": radius,
			"clearanceBottom": clearance_bottom,
			"clearanceTop": clearance_top
		}
	return {}


static func _support_intersects_staging_window(support: Dictionary, requested_position: Vector3, margin: float) -> bool:
	var bounds: AABB = support.get("bounds", AABB()) if support.get("bounds", AABB()) is AABB else AABB()
	if bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
		return false
	var window := bounds.grow(margin)
	return requested_position.x >= window.position.x and requested_position.x <= window.end.x and requested_position.z >= window.position.z and requested_position.z <= window.end.z


static func _support_footprint_area(support: Dictionary) -> float:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return INF
	var signed_area := 0.0
	var previous: Vector3 = polygon[polygon.size() - 1] if polygon[polygon.size() - 1] is Vector3 else Vector3.ZERO
	for point_value in polygon:
		if not (point_value is Vector3):
			return INF
		var point: Vector3 = point_value
		signed_area += previous.x * point.z - point.x * previous.z
		previous = point
	return absf(signed_area) * 0.5


static func _nearest_safe_door_staging_position(requested_position: Vector3, direction: Vector3, support: Dictionary) -> Dictionary:
	var step_count := ceili(DOOR_PORTAL_STAGING_MAX_ADJUSTMENT / DOOR_PORTAL_STAGING_STEP)
	for step_index in range(step_count + 1):
		var offsets: Array[float] = []
		if step_index == 0:
			offsets.append(0.0)
		else:
			offsets.append(-float(step_index) * DOOR_PORTAL_STAGING_STEP)
			offsets.append(float(step_index) * DOOR_PORTAL_STAGING_STEP)
		for offset in offsets:
			var candidate := requested_position + direction * offset
			var clearance := _support_edge_clearance(candidate, support)
			if not bool(clearance.get("inside", false)):
				continue
			if float(clearance.get("distance", 0.0)) + 0.0001 < DOOR_PORTAL_STAGING_CLEARANCE:
				continue
			return {
				"resolved": true,
				"position": candidate,
				"adjustment": absf(offset),
				"edgeClearance": float(clearance.get("distance", 0.0)),
				"reason": ""
			}
	var requested_clearance := _support_edge_clearance(requested_position, support)
	return {
		"resolved": false,
		"reason": "outside_support" if not bool(requested_clearance.get("inside", false)) else "insufficient_npc_clearance",
		"adjustment": INF,
		"edgeClearance": float(requested_clearance.get("distance", -1.0))
	}


static func _support_edge_clearance(position: Vector3, support: Dictionary) -> Dictionary:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return {"inside": false, "distance": -1.0}
	var minimum_distance_squared := INF
	var point := Vector2(position.x, position.z)
	for index in range(polygon.size()):
		if not (polygon[index] is Vector3) or not (polygon[(index + 1) % polygon.size()] is Vector3):
			return {"inside": false, "distance": -1.0}
		var first: Vector3 = polygon[index] as Vector3
		var second: Vector3 = polygon[(index + 1) % polygon.size()] as Vector3
		minimum_distance_squared = minf(minimum_distance_squared, _point_to_segment_distance_squared(point, Vector2(first.x, first.z), Vector2(second.x, second.z)))
	return {"inside": _point_within_support_xz(position, support), "distance": sqrt(maxf(0.0, minimum_distance_squared))}


static func _support_for_door_endpoint(supports: Array[Dictionary], position: Vector3, floor_y: float, preferred_source_part_id := "") -> Dictionary:
	var result: Dictionary = {}
	var closest_floor_distance := INF
	var result_id := ""
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
		var support_id := String(support.get("id", ""))
		if distance > closest_floor_distance + 0.0001:
			continue
		if is_equal_approx(distance, closest_floor_distance) and not result_id.is_empty() and support_id >= result_id:
			continue
		result = support
		closest_floor_distance = distance
		result_id = support_id
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
