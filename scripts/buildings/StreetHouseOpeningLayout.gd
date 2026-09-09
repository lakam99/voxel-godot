extends RefCounted

## Reserve masonry beside a doorway before partitioning the facade. Both end
## sockets and the original panel's gravity patch must fit outside room access.
const Bearing = preload("res://scripts/buildings/ConstructionBearingDimensions.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Door = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const DOOR_SIZE := Vector3(1.25, 2.5, 0.14)
const DOOR_WIDTH := 1.48
const ACCESS_WIDTH := 1.86
const WINDOW_WIDTH := 1.16
const ROOM_INSET := 0.34

static func stone_base_height(wall_height: float) -> float:
	var sampled := minf(2.1, wall_height * 0.27)
	var first_window_bottom := 2.75 - 1.46 * 0.5
	var thin_course := first_window_bottom - sampled
	if thin_course > 0.0 and thin_course < Bearing.LOWER_BEARING_HEIGHT:
		return minf(wall_height - Bearing.LOWER_BEARING_HEIGHT, first_window_bottom)
	return sampled

static func protected_half_span(wall_height: float = 6.2) -> float:
	var access_half := ACCESS_WIDTH * 0.5
	var sill_top := stone_base_height(wall_height)
	var sill_bottom := sill_top - Bearing.LOWER_BEARING_HEIGHT
	# The existing publisher owns frame and swing geometry. Its frame is wider
	# than room access; neither can be treated as the other's clearance proxy.
	var swept := Door.ordinary_sweep_bounds(DOOR_SIZE, Transform3D(Basis.from_euler(Vector3(0.0, -PI * 0.5, 0.0)), Vector3(0.0,1.25,0.0)))
	if swept.is_empty(): return INF
	for primitive: Dictionary in swept:
		var bounds: AABB = primitive.bounds
		if not bearing_height_overlap(bounds,sill_bottom,sill_top): continue
		access_half = maxf(access_half, maxf(absf(bounds.position.z), absf(bounds.end.z)))
	return access_half

static func bearing_height_overlap(bounds: AABB, bottom: float, top: float) -> bool:
	# Retain touching outward-rounded envelopes conservatively as well.
	return bounds.end.y >= bottom and bounds.position.y <= top

static func minimum_window_offset(wall_height: float = 6.2) -> float:
	var access_half := protected_half_span(wall_height)
	var door_half := DOOR_WIDTH * 0.5
	var patch_inner := 2.0 * (access_half + Bearing.GRAVITY_PATCH_MAX_HALF + Blueprint.PHYSICAL_CONTACT_MARGIN + Bearing.CONNECTION_PADDING) - door_half
	# The sill is split into two half-bodies. Each must house a complete padded
	# socket. Leave construction room for exact float32 boundary fitting too;
	# downstream collision and socket checks remain strict.
	var sockets_inner := access_half + 4.0 * (Bearing.LOWER_CORBEL_SOCKET_HALF.z + Bearing.CONNECTION_PADDING) + 2.0 * Bearing.CONNECTION_PADDING
	return maxf(patch_inner, sockets_inner) + WINDOW_WIDTH * 0.5

static func minimum_depth(wall_height: float = 6.2) -> float:
	return 2.0 * (minimum_window_offset(wall_height) + WINDOW_WIDTH * 0.5 + ROOM_INSET)

static func prepare(depth: float, wall_height: float = 6.2) -> Dictionary:
	if not is_finite(wall_height) or wall_height <= Bearing.LOWER_BEARING_HEIGHT or not is_finite(depth) or depth < minimum_depth(wall_height):
		return {"ready": false, "reason": "insufficient_facade_bearing_space"}
	var offset := maxf(minf(depth * 0.25, 2.2), minimum_window_offset(wall_height))
	if offset + WINDOW_WIDTH * 0.5 + ROOM_INSET > depth * 0.5:
		return {"ready": false, "reason": "window_outside_room_span"}
	return {"ready": true, "windowOffset": offset}
