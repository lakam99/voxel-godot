extends RefCounted

## Pure proposed footing/dressing construction. No source mutation, history
## generation, collision changes, root claim or placement acceptance.
## The returned originalArtifact is compiled ONCE from the supplied descriptor.
## Apertures are a canonical UNION of finite prisms, never a bounding-hull cut.
## Nominal joint is purposeful XZ construction space, not numerical tolerance.
## Main owns represented-mesh/real-foot clearance and atomic frame+cut commit.
const Artifact = preload("res://scripts/buildings/PavingConstructionArtifact.gd")
const Cut = preload("res://scripts/buildings/ConvexFootingAperture.gd")
const MAX_FEET := 16
const MAX_JOINT := 0.05
const MAX_WORK := 4000000


static func derive(described: Dictionary, part_transform: Transform3D, foot_bounds: Array[AABB], joint_width: float) -> Dictionary:
	if not is_finite(joint_width) or joint_width <= 0.0 or joint_width > MAX_JOINT: return _failure("invalid_nominal_joint")
	if foot_bounds.is_empty(): return _failure("missing_feet")
	# Limit RAW input before de-duplication so repeated inputs cannot hide work.
	if foot_bounds.size() > MAX_FEET: return _failure("foot_collection_limit")
	var feet: Array[AABB] = []
	for foot in foot_bounds:
		if not _valid_bounds(foot): return _failure("invalid_foot_bounds")
		if not feet.has(foot): feet.append(foot)
	feet.sort_custom(func(a: AABB, b: AABB): return _ordered_bounds(a, b))
	var original: Dictionary = Artifact.compile(described, part_transform, [])
	if not original.completed: return _failure("original_artifact_failed", original.work, original.get("reason", ""))
	var work: int = original.work
	if original.entries.is_empty() or original.entries.size() > Cut.HARD_LIMITS.maxSolids: return _failure("invalid_original_collection", work)
	var y_min := INF
	var y_max := -INF
	# Native bounds conservatively enclose every represented original corner.
	# Use scalar extrema, not repeated AABB.expand/merge reconstruction.
	for entry in original.entries:
		work += 1
		if work > MAX_WORK: return _failure("derivation_work_limit", work)
		if not entry.unchanged or entry.cells.size() != 1 or entry.cells[0].representation != "native_box": return _failure("original_artifact_not_native", work)
		var bounds: AABB = entry.cells[0].bounds
		if not _valid_bounds(bounds): return _failure("invalid_native_bounds", work)
		y_min = minf(y_min, float(bounds.position.y))
		y_max = maxf(y_max, float(bounds.end.y))
	var finish_height: float = y_max - y_min
	if not is_finite(finish_height) or finish_height <= 0.0: return _failure("degenerate_finish_height", work)
	var cut_bottom: float = y_min - finish_height
	var cut_height: float = 3.0 * finish_height
	var apertures: Array[AABB] = []
	var witnesses: Array = []
	for foot_index in range(feet.size()):
		var foot: AABB = feet[foot_index]
		var hit := false
		for entry in original.entries:
			work += 1
			if work >= MAX_WORK: return _failure("derivation_work_limit", work)
			if not _strict_overlap(entry.cells[0].bounds, foot): continue
			# AABB overlap is only a filter. Ask the existing exact convex cutter
			# for positive actual-solid intersection; a rotated native box can
			# miss a foot even when their broadphase bounds overlap.
			var probe_cuts: Array[AABB] = [foot]
			var probe: Dictionary = Cut.subtract_boxes([entry.original], probe_cuts, {"maxWork": MAX_WORK - work})
			work += int(probe.work)
			if not probe.completed: return _failure("finish_intersection_probe_failed", work, probe.get("reason", ""))
			if probe.removedVolume > 0.0:
				hit = true
				witnesses.append({"footIndex": foot_index, "solidId": entry.original.id, "intersectionVolume": probe.removedVolume})
				break
		if not hit: return _failure("foot_has_no_actual_finish_overlap", work)
		# Preserve the foot's declared size/pose. Only the finish is cut, with
		# one full finish height beyond each original Y extremum. No fixed Y
		# padding, footing-height assumption or infinite cutting column.
		var aperture := AABB(Vector3(float(foot.position.x) - joint_width, cut_bottom, float(foot.position.z) - joint_width),
			Vector3(float(foot.size.x) + 2.0 * joint_width, cut_height, float(foot.size.z) + 2.0 * joint_width))
		if not _valid_bounds(aperture): return _failure("invalid_derived_aperture", work)
		if aperture.position.y >= y_min or aperture.end.y <= y_max: return _failure("through_finish_extent_not_representable", work)
		if aperture.position.x >= foot.position.x or aperture.end.x <= foot.end.x or aperture.position.z >= foot.position.z or aperture.end.z <= foot.end.z: return _failure("nominal_joint_not_representable", work)
		if not apertures.has(aperture): apertures.append(aperture)
	apertures.sort_custom(func(a: AABB, b: AABB): return _ordered_bounds(a, b))
	return {"completed": true, "apertures": apertures, "originalArtifact": original, "feet": feet,
		"nominalJoint": joint_width, "finishYMinimum": y_min, "finishYMaximum": y_max, "finishHeight": finish_height,
		"nominalCutBottom": cut_bottom, "nominalCutTop": y_max + finish_height,
		"originalCompileCount": 1, "work": work, "overlapWitnesses": witnesses}


static func _valid_bounds(bounds: AABB) -> bool:
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite(): return false
	for axis in range(3):
		if bounds.size[axis] < Cut.MIN_AXIS or bounds.end[axis] <= bounds.position[axis] or absf(bounds.position[axis]) > Cut.MAX_COORD or absf(bounds.end[axis]) > Cut.MAX_COORD: return false
	return true


static func _strict_overlap(a: AABB, b: AABB) -> bool:
	return a.position.x < b.end.x and a.end.x > b.position.x and a.position.y < b.end.y and a.end.y > b.position.y and a.position.z < b.end.z and a.end.z > b.position.z


static func _ordered_bounds(a: AABB, b: AABB) -> bool:
	for axis in range(3):
		if a.position[axis] != b.position[axis]: return a.position[axis] < b.position[axis]
	for axis in range(3):
		if a.size[axis] != b.size[axis]: return a.size[axis] < b.size[axis]
	return false


static func _failure(reason: String, work := 0, detail := "") -> Dictionary:
	return {"completed": false, "reason": reason, "detail": detail, "work": work}
