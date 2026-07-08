extends RefCounted
class_name HomeInteriorService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const INVALID_CELL := Vector2i(999999, 999999)

static func status(entry: Dictionary, position: Vector3, portal = null, options := {}) -> Dictionary:
	if entry.is_empty():
		return { "strictInside": false, "reason": "entry_missing" }
	var cell := flat_cell(position)
	var home_cell := cell_value(entry.get("homeCell", cell), cell)
	var porch_cell := cell_value(entry.get("porchCell", home_cell), home_cell)
	var door_cell := door_cell_for_entry(entry)
	var interior_min := cell_value(entry.get("interiorMinCell", home_cell), home_cell)
	var interior_max := cell_value(entry.get("interiorMaxCell", home_cell), home_cell)
	var inside_bounds := cell_inside_bounds(cell, interior_min, interior_max)
	var on_porch := cell == porch_cell
	var on_door_cell := is_valid_cell(door_cell) and cell == door_cell
	var threshold_occupied := false
	var sweep_occupied := false
	var clearance_occupied := false
	if not bool(options.get("ignoreDoorVolumes", false)):
		threshold_occupied = portal_volume_occupied(portal, position, "threshold")
		sweep_occupied = portal_volume_occupied(portal, position, "sweep")
		clearance_occupied = portal_volume_occupied(portal, position, "clearance")
	var clear_of_door := not threshold_occupied and not sweep_occupied and not clearance_occupied
	var inward := inward_direction_for_entry(entry)
	var past_door_plane := position_past_door_plane(position, door_cell, inward, float(options.get("doorPlaneCells", 0.55)))
	var inside_world_bounds := position_inside_cell_bounds(position, interior_min, interior_max, float(options.get("boundsMarginScale", 0.45)))
	var strict_inside := inside_bounds \
		and inside_world_bounds \
		and not on_porch \
		and not on_door_cell \
		and clear_of_door \
		and past_door_plane
	var reason := "interior_clear" if strict_inside else "not_inside_interior"
	if not inside_bounds:
		reason = "not_inside_interior_bounds"
	elif not inside_world_bounds:
		reason = "exterior_wall_edge_not_inside"
	elif on_porch:
		reason = "porch_not_inside"
	elif on_door_cell:
		reason = "door_cell_not_inside"
	elif not clear_of_door:
		reason = "door_clearance_not_inside"
	elif not past_door_plane:
		reason = "not_past_door_plane"
	return {
		"strictInside": strict_inside,
		"reason": reason,
		"cell": cell_summary(cell),
		"homeCell": cell_summary(home_cell),
		"porchCell": cell_summary(porch_cell),
		"doorCell": cell_summary(door_cell),
		"interiorMinCell": cell_summary(interior_min),
		"interiorMaxCell": cell_summary(interior_max),
		"insideBounds": inside_bounds,
		"insideWorldBounds": inside_world_bounds,
		"onPorch": on_porch,
		"onDoorCell": on_door_cell,
		"doorThresholdOccupied": threshold_occupied,
		"doorSweepOccupied": sweep_occupied,
		"doorClearanceOccupied": clearance_occupied,
		"clearOfDoor": clear_of_door,
		"pastDoorPlane": past_door_plane,
		"inward": cell_summary(inward),
		"hasPortal": portal != null
	}

static func is_strictly_inside(entry: Dictionary, position: Vector3, portal = null) -> bool:
	return bool(status(entry, position, portal).get("strictInside", false))

static func cell_inside_home_bounds(entry: Dictionary, cell: Vector2i, require_past_door := true) -> bool:
	if entry.is_empty():
		return false
	var home_cell := cell_value(entry.get("homeCell", cell), cell)
	var porch_cell := cell_value(entry.get("porchCell", home_cell), home_cell)
	var door_cell := door_cell_for_entry(entry)
	var interior_min := cell_value(entry.get("interiorMinCell", home_cell), home_cell)
	var interior_max := cell_value(entry.get("interiorMaxCell", home_cell), home_cell)
	if not cell_inside_bounds(cell, interior_min, interior_max):
		return false
	if cell == porch_cell:
		return false
	if is_valid_cell(door_cell) and cell == door_cell:
		return false
	if require_past_door:
		var inward := inward_direction_for_entry(entry)
		if inward != Vector2i.ZERO:
			var door_to_cell := cell - door_cell
			var projected := door_to_cell.x * inward.x + door_to_cell.y * inward.y
			return projected >= 1
	return true

static func portal_for_entry(entry: Dictionary, door_portal_service):
	if entry.is_empty() or door_portal_service == null:
		return null
	var portals_value = door_portal_service.get("portals")
	if not (portals_value is Dictionary):
		return null
	var portals: Dictionary = portals_value
	var active_id := String(entry.get("activeDoorPortalId", ""))
	if active_id != "" and portals.has(active_id):
		return portals.get(active_id)
	var door_cell := door_cell_for_entry(entry)
	if is_valid_cell(door_cell):
		for portal_id in sorted_keys(portals):
			var portal = portals.get(portal_id)
			if portal_has_cell(portal, door_cell, 0):
				return portal
	var porch_cell := cell_value(entry.get("porchCell", INVALID_CELL), INVALID_CELL)
	if is_valid_cell(porch_cell):
		for portal_id in sorted_keys(portals):
			var portal = portals.get(portal_id)
			if portal_has_cell(portal, porch_cell, 1):
				return portal
	return null

static func portal_volume_occupied(portal, position: Vector3, volume: String, radius := NpcConstantsScript.DEFAULT_NPC_RADIUS) -> bool:
	if portal == null:
		return false
	var bounds_value = portal.get("%s_bounds" % volume)
	if not (bounds_value is AABB):
		return false
	var bounds: AABB = bounds_value
	if bounds.size == Vector3.ZERO:
		return false
	var expanded := bounds.grow(radius)
	expanded.position.y -= NpcConstantsScript.CELL_SIZE
	expanded.size.y += NpcConstantsScript.CELL_SIZE
	return expanded.has_point(position)

static func door_cell_for_entry(entry: Dictionary) -> Vector2i:
	var home_cell := cell_value(entry.get("homeCell", INVALID_CELL), INVALID_CELL)
	var porch_cell := cell_value(entry.get("porchCell", home_cell), home_cell)
	var explicit_door := cell_value(entry.get("doorCell", INVALID_CELL), INVALID_CELL)
	if is_valid_cell(explicit_door):
		return explicit_door
	var inward := inward_direction_for_entry(entry)
	if is_valid_cell(porch_cell) and inward != Vector2i.ZERO:
		return porch_cell + inward
	return INVALID_CELL

static func inward_direction_for_entry(entry: Dictionary) -> Vector2i:
	var porch_cell := cell_value(entry.get("porchCell", INVALID_CELL), INVALID_CELL)
	var door_cell := cell_value(entry.get("doorCell", INVALID_CELL), INVALID_CELL)
	var landing_cell := cell_value(entry.get("interiorLandingCell", INVALID_CELL), INVALID_CELL)
	var home_cell := cell_value(entry.get("homeCell", INVALID_CELL), INVALID_CELL)
	if is_valid_cell(porch_cell) and is_valid_cell(door_cell) and door_cell != porch_cell:
		return cardinal_direction(door_cell - porch_cell)
	if is_valid_cell(door_cell) and is_valid_cell(landing_cell) and landing_cell != door_cell:
		return cardinal_direction(landing_cell - door_cell)
	if is_valid_cell(porch_cell) and is_valid_cell(landing_cell) and landing_cell != porch_cell:
		return cardinal_direction(landing_cell - porch_cell)
	if is_valid_cell(porch_cell) and is_valid_cell(home_cell) and home_cell != porch_cell:
		return cardinal_direction(home_cell - porch_cell)
	return Vector2i.ZERO

static func position_past_door_plane(position: Vector3, door_cell: Vector2i, inward: Vector2i, required_cells: float) -> bool:
	if inward == Vector2i.ZERO or not is_valid_cell(door_cell):
		return true
	var door_x := float(door_cell.x) * NpcConstantsScript.CELL_SIZE
	var door_z := float(door_cell.y) * NpcConstantsScript.CELL_SIZE
	var required := NpcConstantsScript.CELL_SIZE * required_cells
	if inward.x != 0:
		return (position.x - door_x) * float(inward.x) >= required
	return (position.z - door_z) * float(inward.y) >= required

static func position_inside_cell_bounds(position: Vector3, min_cell: Vector2i, max_cell: Vector2i, margin_scale: float) -> bool:
	var min_x := mini(min_cell.x, max_cell.x)
	var max_x := maxi(min_cell.x, max_cell.x)
	var min_z := mini(min_cell.y, max_cell.y)
	var max_z := maxi(min_cell.y, max_cell.y)
	var margin := NpcConstantsScript.DEFAULT_NPC_RADIUS * margin_scale
	var min_world_x := (float(min_x) - 0.5) * NpcConstantsScript.CELL_SIZE + margin
	var max_world_x := (float(max_x) + 0.5) * NpcConstantsScript.CELL_SIZE - margin
	var min_world_z := (float(min_z) - 0.5) * NpcConstantsScript.CELL_SIZE + margin
	var max_world_z := (float(max_z) + 0.5) * NpcConstantsScript.CELL_SIZE - margin
	return position.x >= min_world_x and position.x <= max_world_x and position.z >= min_world_z and position.z <= max_world_z

static func cell_inside_bounds(cell: Vector2i, min_cell: Vector2i, max_cell: Vector2i) -> bool:
	return cell.x >= mini(min_cell.x, max_cell.x) \
		and cell.x <= maxi(min_cell.x, max_cell.x) \
		and cell.y >= mini(min_cell.y, max_cell.y) \
		and cell.y <= maxi(min_cell.y, max_cell.y)

static func flat_cell(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))

static func cell_value(value, fallback: Vector2i) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector3i:
		var cell3: Vector3i = value
		return Vector2i(cell3.x, cell3.z)
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	if value is Dictionary:
		return Vector2i(int(value.get("x", fallback.x)), int(value.get("z", value.get("y", fallback.y))))
	return fallback

static func is_valid_cell(cell: Vector2i) -> bool:
	return cell != INVALID_CELL

static func cardinal_direction(delta: Vector2i) -> Vector2i:
	if delta == Vector2i.ZERO:
		return Vector2i.ZERO
	if absi(delta.x) >= absi(delta.y):
		return Vector2i(1 if delta.x > 0 else -1, 0)
	return Vector2i(0, 1 if delta.y > 0 else -1)

static func portal_has_cell(portal, cell: Vector2i, max_delta: int) -> bool:
	if portal == null or not is_valid_cell(cell):
		return false
	var leaf_cells_value = portal.get("leaf_cells")
	if leaf_cells_value is Array:
		for leaf_value in leaf_cells_value:
			var leaf_cell := cell_value(leaf_value, INVALID_CELL)
			if is_valid_cell(leaf_cell) and maxi(absi(leaf_cell.x - cell.x), absi(leaf_cell.y - cell.y)) <= max_delta:
				return true
	var bounds_value = portal.get("threshold_bounds")
	if bounds_value is AABB:
		var bounds: AABB = bounds_value
		var center := bounds.position + bounds.size * 0.5
		var portal_cell := flat_cell(center)
		return maxi(absi(portal_cell.x - cell.x), absi(portal_cell.y - cell.y)) <= max_delta
	return false

static func sorted_keys(dictionary: Dictionary) -> Array:
	var keys := dictionary.keys()
	keys.sort()
	return keys

static func cell_summary(cell: Vector2i) -> Array:
	return [cell.x, cell.y]
