extends RefCounted

## Rear storage keeps its seeded design/yaw/contents, but reserves the canopy's
## actual rear post plane. No named stall, seed, world pose or report input.
static func place(blueprint, member_ids: Array, front: Vector3) -> Dictionary:
	if blueprint == null or member_ids.is_empty() or member_ids.size() > 128 or blueprint.parts.size() > 32768 or not front.is_finite() or front.y != 0.0 or front.length_squared() != 1.0:
		return {"ready": false, "reason": "invalid_storage_layout_input"}
	var ids: Dictionary = {}
	for id in member_ids:
		if not id is String or ids.has(id):
			return {"ready": false, "reason": "invalid_or_duplicate_member"}
		ids[id] = true
	var members: Dictionary = {}
	for part in blueprint.parts:
		if not ids.has(part.id):
			continue
		if members.has(part.id) or not blueprint.has_finite_positive_bounds(part):
			return {"ready": false, "reason": "invalid_or_duplicate_member"}
		members[part.id] = part
	if members.size() != ids.size():
		return {"ready": false, "reason": "missing_member"}
	var ridges: Array = members.values().filter(func(part): return part.semantic == "citadel_market_canopy_ridge")
	var knees: Array = members.values().filter(func(part): return part.semantic == "citadel_market_joinery")
	if ridges.size() != 1 or knees.size() != 4:
		return {"ready": false, "reason": "missing_canopy_geometry"}
	var ridge = ridges[0]
	# Knee centres describe the rear post plane only along the canopy depth.
	# Reject other orientations rather than underestimating the leaning frame.
	var ridge_basis := Basis.from_euler(ridge.rotation)
	if not ridge_basis.y.is_equal_approx(Vector3.UP) or not is_equal_approx(absf(front.dot(ridge_basis.z)), 1.0):
		return {"ready": false, "reason": "unsupported_canopy_front"}
	var section: float = maxf(ridge.size.y, ridge.size.z) * 1.5
	for knee in knees:
		section = maxf(section, maxf(knee.size.x, knee.size.z) * 1.5)
	var rear := -front
	var rear_plane := -INF
	for knee in knees:
		rear_plane = maxf(rear_plane, (knee.position - ridge.position).dot(rear) + section * 0.5)
	var clearance := section * 0.2
	var storage: Array = []
	var group_shift := 0.0
	var changes: Array = []
	for part in members.values():
		if part.semantic != "citadel_market_storage":
			continue
		var basis := Basis.from_euler(part.rotation)
		var half_extent: float = (absf(basis.x.dot(rear)) * part.size.x + absf(basis.y.dot(rear)) * part.size.y + absf(basis.z.dot(rear)) * part.size.z) * 0.5
		var shift := maxf(0.0, rear_plane + clearance + half_extent - (part.position - ridge.position).dot(rear))
		if not is_finite(shift):
			return {"ready": false, "reason": "invalid_storage_position"}
		group_shift = maxf(group_shift, shift)
		storage.append(part)
	# Translate the complete storage group, preserving the seeded arrangement.
	# Moving a single barrel can push it into its unchanged neighbour.
	for part in storage:
		var after: Vector3 = part.position + rear * group_shift
		if not after.is_finite():
			return {"ready": false, "reason": "invalid_storage_position"}
		if after != part.position:
			changes.append({"partId": part.id, "before": part.position, "after": after})
	# Validate the complete proposal before mutating any source record.
	for change in changes:
		members[change.partId].position = change.after
	return {"ready": true, "reason": "", "changes": changes, "rear": rear,
		"rearPostPlane": rear_plane, "clearance": clearance}
