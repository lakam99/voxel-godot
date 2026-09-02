extends RefCounted
class_name BuildingTerrainProfile

## Pure generated-terrain input. It never creates a mesh, collision slab or
## terrain edit. Building visuals keep their local transforms; the owner applies
## origin once and terrain publishes the same ground plane from its volume.
const VERSION := 1
const MAX_APRON_CELLS := 128
const MAX_ABS_CELL := 1000000
const MAX_ROOTS := 20000
const GroundMask := preload("res://scripts/world/BuildingGroundMask.gd")


static func create(manifest: Dictionary, world_seed: String, site_id: String, origin_cell: Vector2i, level: float, apron_cells: int, cell_size: float = 1.35) -> Dictionary:
	if not manifest.get("ready", false) or world_seed.is_empty() or site_id.is_empty() or not is_finite(level) or not is_finite(cell_size) or cell_size <= 0.0:
		return {"ready": false, "reason": "invalid_terrain_profile_input"}
	if manifest.get("cellSize") != cell_size or not manifest.get("footprintCells") is Rect2i or not manifest.get("localBounds") is AABB or not manifest.get("groundRoots") is Array or manifest.groundRoots.is_empty() or manifest.groundRoots.size() > MAX_ROOTS:
		return {"ready": false, "reason": "missing_geometry_manifest"}
	if not manifest.get("sourceSignature") is String or manifest.sourceSignature.is_empty() or manifest.get("groundY") != 0.0 or apron_cells < 1 or apron_cells > MAX_APRON_CELLS:
		return {"ready": false, "reason": "invalid_ground_plane_or_apron"}
	var local: Rect2i = manifest.footprintCells
	if not _bounded_rect(local) or absi(origin_cell.x) > MAX_ABS_CELL or absi(origin_cell.y) > MAX_ABS_CELL:
		return {"ready": false, "reason": "invalid_geometry_footprint"}
	var reservation := Rect2i(origin_cell + local.position, local.size)
	var ground_points: Array[Vector3] = []
	for root in manifest.groundRoots:
		if not root is Dictionary or not root.get("corners") is Array or root.corners.size() != 4:
			return {"ready": false, "reason": "invalid_ground_root"}
		for point in root.corners:
			if not point is Vector3 or not point.is_finite() or absf(point.y) > 0.06:
				return {"ready": false, "reason": "nonplanar_ground_root"}
			if absf(point.x / cell_size) > MAX_ABS_CELL or absf(point.z / cell_size) > MAX_ABS_CELL:
				return {"ready": false, "reason": "unsupported_ground_root_coordinates"}
			var world_point: Vector3 = point + Vector3(float(origin_cell.x) * cell_size, level, float(origin_cell.y) * cell_size)
			ground_points.append(world_point)
	var mask := GroundMask.build(manifest, apron_cells, cell_size)
	if not mask.ready: return mask
	var core := Rect2i(origin_cell + mask.coreCells.position, mask.coreCells.size)
	var envelope := core.grow(apron_cells)
	if not _bounded_rect(envelope) or not _bounded_rect(reservation):
		return {"ready": false, "reason": "unsupported_terrain_profile_coordinates"}
	var profile := {
		"version": VERSION, "worldSeed": world_seed, "siteId": site_id,
		"sourceSignature": manifest.sourceSignature,
		"cellSize": cell_size, "coreCells": core, "envelopeCells": envelope,
		"origin": Vector3(float(origin_cell.x) * cell_size, level, float(origin_cell.y) * cell_size),
		"level": level, "apronCells": apron_cells,
		"groundRootPoints": ground_points,
		"reservationCells": reservation,
		# Godot PackedArrays cannot be frozen. Convert once on the source worker
		# to containers with enforced read-only state at admission; never share a
		# writable packed-array alias across native worker revisions.
		"supportMask": Array(mask.supportMask), "distanceCells": Array(mask.distanceCells),
	}
	if not valid(profile, world_seed, cell_size):
		return {"ready": false, "reason": "invalid_ground_root_extent"}
	return {"ready": true, "profile": profile}


static func valid(profile: Dictionary, world_seed: String, cell_size: float) -> bool:
	if profile.get("version") != VERSION or profile.get("worldSeed") != world_seed or profile.get("cellSize") != cell_size:
		return false
	if not profile.get("siteId") is String or profile.siteId.is_empty() or not profile.get("sourceSignature") is String or profile.sourceSignature.is_empty():
		return false
	if not profile.get("coreCells") is Rect2i or not profile.get("envelopeCells") is Rect2i or typeof(profile.get("apronCells")) != TYPE_INT:
		return false
	var core: Rect2i = profile.coreCells
	var apron: int = profile.apronCells
	if not _bounded_rect(core) or apron < 1 or apron > MAX_APRON_CELLS or not _bounded_rect(profile.envelopeCells) or profile.envelopeCells != core.grow(apron):
		return false
	var count := int(profile.envelopeCells.size.x) * int(profile.envelopeCells.size.y)
	if count > GroundMask.MAX_SAMPLES or not profile.get("supportMask") is Array or not profile.get("distanceCells") is Array or profile.supportMask.size() != count or profile.distanceCells.size() != count:
		return false
	if not profile.get("reservationCells") is Rect2i or not _bounded_rect(profile.reservationCells): return false
	for index in range(count):
		if typeof(profile.supportMask[index]) != TYPE_INT or profile.supportMask[index] not in [0,1] or typeof(profile.distanceCells[index]) != TYPE_FLOAT or not is_finite(profile.distanceCells[index]) or profile.distanceCells[index] < 0.0 or profile.supportMask[index] == 1 and profile.distanceCells[index] != 0.0:
			return false
	if typeof(profile.get("level")) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(profile.level)):
		return false
	if not profile.get("origin") is Vector3 or not profile.origin.is_finite() or absf(profile.origin.y - float(profile.level)) > 0.0001:
		return false
	if not profile.get("groundRootPoints") is Array or profile.groundRootPoints.is_empty() or profile.groundRootPoints.size() > MAX_ROOTS * 4 or profile.groundRootPoints.size() % 4 != 0:
		return false
	for point in profile.groundRootPoints:
		if not point is Vector3 or not point.is_finite() or absf(point.y - float(profile.level)) > 0.061:
			return false
		if point.x < float(core.position.x) * cell_size or point.x > float(core.end.x - 1) * cell_size or point.z < float(core.position.y) * cell_size or point.z > float(core.end.y - 1) * cell_size:
			return false
	return true


static func _bounded_rect(rect: Rect2i) -> bool:
	# Widen before adding to avoid int32 Rect2i.end overflow on malformed input.
	return rect.size.x > 0 and rect.size.y > 0 and absi(rect.position.x) <= MAX_ABS_CELL and absi(rect.position.y) <= MAX_ABS_CELL and int(rect.position.x) + int(rect.size.x) <= MAX_ABS_CELL and int(rect.position.y) + int(rect.size.y) <= MAX_ABS_CELL


static func freeze_profiles(profiles: Array) -> void:
	# Enforced immutable source buffers, not a read-only outer dictionary wrapped
	# around mutable PackedArrays. Exports duplicate before crossing the boundary.
	for profile: Dictionary in profiles:
		profile.groundRootPoints.make_read_only()
		profile.supportMask.make_read_only()
		profile.distanceCells.make_read_only()
		profile.make_read_only()
	profiles.make_read_only()


static func contains_core(profile: Dictionary, cell: Vector2i) -> bool:
	var envelope: Rect2i = profile.envelopeCells
	if not envelope.has_point(cell): return false
	return profile.supportMask[(cell.y-envelope.position.y)*envelope.size.x+cell.x-envelope.position.x] != 0


static func surface_y(profile: Dictionary, cell: Vector2i, natural_y: float) -> float:
	var envelope: Rect2i = profile.envelopeCells
	if not envelope.has_point(cell): return natural_y
	var distance: float = profile.distanceCells[(cell.y-envelope.position.y)*envelope.size.x+cell.x-envelope.position.x]
	var blend := clampf(distance / float(profile.apronCells), 0.0, 1.0)
	var eased := blend * blend * (3.0 - 2.0 * blend)
	return lerpf(float(profile.level), natural_y, eased)
