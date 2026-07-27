extends RefCounted
class_name InteriorFurnishingLayout

## Reusable room-space policy for generated interiors. The building blueprint
## declares rooms and usable accesses; furnishing grammars consume those facts
## to reserve circulation and orient wall-supported objects toward the room.

const FLOOR_Y := 0.70


static func access_reservations(room_records: Array) -> Array[AABB]:
	var reservations: Array[AABB] = []
	var seen_ids := {}
	for raw_room in room_records:
		if not raw_room is Dictionary:
			continue
		var room := raw_room as Dictionary
		var accesses: Array = room.get("accesses", []) as Array
		for raw_access in accesses:
			if not raw_access is Dictionary:
				continue
			var access := raw_access as Dictionary
			var access_id := String(access.get("id", "")).strip_edges()
			if access_id.is_empty() or seen_ids.has(access_id):
				continue
			var position: Vector3 = access.get("position", Vector3.ZERO) as Vector3
			var size: Vector3 = access.get("size", Vector3.ZERO) as Vector3
			if size.x <= 0.0 or size.z <= 0.0:
				continue
			seen_ids[access_id] = true
			reservations.append(AABB(
				Vector3(position.x - size.x * 0.5, FLOOR_Y, position.z - size.z * 0.5),
				Vector3(size.x, maxf(0.10, size.y), size.z)
			))
	return reservations


static func wall_facing_rotation(wall_id: String) -> Vector3:
	# Local -Z is the readable/front side of cabinets, shelves and chests.
	# The returned yaw therefore points that face into the room.
	match wall_id.strip_edges().to_lower():
		"left":
			return Vector3(0.0, -PI * 0.5, 0.0)
		"right":
			return Vector3(0.0, PI * 0.5, 0.0)
		"front":
			return Vector3(0.0, PI, 0.0)
		_:
			return Vector3.ZERO # back wall



static func position_against_wall(room: Dictionary, wall_id: String, along: float, size: Vector3, padding := 0.06) -> Vector3:
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	var normalized := clampf(along, 0.0, 1.0)
	var wall := wall_id.strip_edges().to_lower()
	if wall in ["left", "right"]:
		var half_span := size.x * 0.5 + padding
		var minimum := bounds.position.z + half_span
		var maximum := bounds.end.z - half_span
		var z := lerpf(minimum, maximum, normalized) if maximum >= minimum else bounds.get_center().z
		var x := bounds.position.x + size.z * 0.5 + padding if wall == "left" else bounds.end.x - size.z * 0.5 - padding
		return Vector3(x, FLOOR_Y, z)
	var half_span := size.x * 0.5 + padding
	var minimum := bounds.position.x + half_span
	var maximum := bounds.end.x - half_span
	var x := lerpf(minimum, maximum, normalized) if maximum >= minimum else bounds.get_center().x
	var z := bounds.position.z + size.z * 0.5 + padding if wall == "front" else bounds.end.z - size.z * 0.5 - padding
	return Vector3(x, FLOOR_Y, z)


static func wall_mount_position(room: Dictionary, wall_id: String, along: float, size: Vector3) -> Vector3:
	# Room bounds lie at wall centres. A thin wall-mounted record is positioned
	# so that its local +Z face (the back of art) coincides with the interior
	# surface of its selected wall, irrespective of wall thickness.
	var wall_mount_inset := float(room.get("wallMountInset", 0.12))
	return position_against_wall(room, wall_id, along, size, wall_mount_inset)


static func wall_mount_back_face_is_on_wall(room: Dictionary, wall_id: String, position: Vector3, rotation: Vector3, size: Vector3, tolerance := 0.015) -> bool:
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	if bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
		return false
	var expected_rotation := wall_facing_rotation(wall_id)
	if absf(wrapf(rotation.y - expected_rotation.y, -PI, PI)) > 0.001:
		return false
	var wall_mount_inset := float(room.get("wallMountInset", 0.12))
	var local_back_face := Vector3(0.0, 0.0, size.z * 0.5)
	var back_face := position + local_back_face.rotated(Vector3.UP, rotation.y)
	match wall_id.strip_edges().to_lower():
		"left":
			return absf(back_face.x - (bounds.position.x + wall_mount_inset)) <= tolerance
		"right":
			return absf(back_face.x - (bounds.end.x - wall_mount_inset)) <= tolerance
		"front":
			return absf(back_face.z - (bounds.position.z + wall_mount_inset)) <= tolerance
		_:
			return absf(back_face.z - (bounds.end.z - wall_mount_inset)) <= tolerance


static func horizontal_bounds(position: Vector3, size: Vector3, rotation: Vector3, padding := 0.0) -> AABB:
	var yaw := rotation.y
	var extent_x := absf(cos(yaw)) * size.x + absf(sin(yaw)) * size.z
	var extent_z := absf(sin(yaw)) * size.x + absf(cos(yaw)) * size.z
	return AABB(
		Vector3(position.x - extent_x * 0.5 - padding, FLOOR_Y, position.z - extent_z * 0.5 - padding),
		Vector3(extent_x + padding * 2.0, maxf(0.10, size.y), extent_z + padding * 2.0)
	)


static func interaction_bounds(position: Vector3, size: Vector3, rotation: Vector3, depth: float, side_padding := 0.10) -> AABB:
	# Interactive furniture exposes local -Z as its usable/front side. Reserve a
	# player-sized standing band there rather than assuming collision-free space
	# means an action can actually be performed.
	var usable_depth := maxf(0.10, depth)
	var forward := Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, rotation.y)
	var center := position + forward * (size.z * 0.5 + usable_depth * 0.5)
	return horizontal_bounds(center, Vector3(size.x + side_padding * 2.0, size.y, usable_depth), rotation)


static func wall_mount_is_clear(existing_parts: Array, wall_id: String, position: Vector3, rotation: Vector3, size: Vector3, mount_height: float) -> bool:
	# A frame is not decoration wallpaper. Its visible plane must remain clear of
	# any substantial furnishing supported by the same wall, including a hearth.
	var candidate := horizontal_bounds(position, size, rotation)
	var candidate_bottom := position.y + mount_height - size.y * 0.5
	var candidate_top := position.y + mount_height + size.y * 0.5
	for part in existing_parts:
		if part == null or not part.has_method("snapshot"):
			continue
		if String(part.recipe.get("supportingWall", "")).strip_edges().to_lower() != wall_id.strip_edges().to_lower():
			continue
		var occupied := horizontal_bounds(part.position, part.occupied_size, part.rotation)
		var bottom: float = float(part.position.y)
		var top: float = float(part.position.y + part.occupied_size.y)
		if candidate.intersects(occupied) and candidate_bottom < top and candidate_top > bottom:
			return false
	return true


static func room_walkability(room: Dictionary, solid_parts: Array, actor_radius := 0.34, cell_size := 0.32) -> Dictionary:
	# Layout-time accessibility audit. The player body needs a connected standing
	# area, not merely non-overlapping furniture. Each room declares its own
	# access lanes, so a generated arrangement cannot strand usable floor space.
	var blocked: Array[AABB] = []
	for part in solid_parts:
		if part == null:
			continue
		blocked.append(horizontal_bounds(part.position, part.occupied_size, part.rotation, actor_radius))
	return room_walkability_for_blocked_bounds(room, blocked, actor_radius, cell_size)


static func room_walkability_for_blocked_bounds(room: Dictionary, blocked: Array[AABB], actor_radius := 0.34, cell_size := 0.32) -> Dictionary:
	# Shared lower-level form for procedural planners. It lets a candidate layout
	# prove that the player footprint still has one connected standing region
	# before the candidate is committed to the furnishing plan.
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	var minimum := Vector2(bounds.position.x + actor_radius, bounds.position.z + actor_radius)
	var maximum := Vector2(bounds.end.x - actor_radius, bounds.end.z - actor_radius)
	var steps_x := maxi(0, int(floor((maximum.x - minimum.x) / cell_size)))
	var steps_z := maxi(0, int(floor((maximum.y - minimum.y) / cell_size)))
	var free := {}
	var positions := {}
	for x_index in range(steps_x + 1):
		for z_index in range(steps_z + 1):
			var position := Vector3(minimum.x + float(x_index) * cell_size, FLOOR_Y, minimum.y + float(z_index) * cell_size)
			var occupied := false
			for obstacle in blocked:
				if point_inside_horizontal_bounds(position, obstacle):
					occupied = true
					break
			if not occupied:
				var key := "%d:%d" % [x_index, z_index]
				free[key] = true
				positions[key] = position
	var access_lanes := access_reservations([room])
	var frontier: Array[String] = []
	var visited := {}
	for key in free.keys():
		var position: Vector3 = positions[key] as Vector3
		for access in access_lanes:
			if point_inside_horizontal_bounds(position, access):
				visited[key] = true
				frontier.append(String(key))
				break
	var access_seed_cells := frontier.size()
	var cursor := 0
	while cursor < frontier.size():
		var key := frontier[cursor]
		cursor += 1
		var values := key.split(":")
		if values.size() != 2:
			continue
		var x_index := int(values[0])
		var z_index := int(values[1])
		for delta in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbour := "%d:%d" % [x_index + delta.x, z_index + delta.y]
			if free.has(neighbour) and not visited.has(neighbour):
				visited[neighbour] = true
				frontier.append(neighbour)
	return {
		"freeCells": free.size(),
		"reachableCells": visited.size(),
		"unreachableCells": maxi(0, free.size() - visited.size()),
		"accessSeedCells": access_seed_cells
	}


static func point_inside_horizontal_bounds(point: Vector3, bounds: AABB) -> bool:
	return point.x >= bounds.position.x and point.x <= bounds.end.x and point.z >= bounds.position.z and point.z <= bounds.end.z


static func intersects_any(candidate: AABB, occupied: Array[AABB]) -> bool:
	for existing in occupied:
		if candidate.intersects(existing):
			return true
	return false
