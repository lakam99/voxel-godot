extends RefCounted
## Value-only presentation membership in the same
## section candidate as geometry. Live bindings remain in the install session.
const SCHEMA := "static-section-presentation-member/v2"
const MAX_MEMBERS := 256
const MAX_STREAM_DEPENDENCIES := 4096
const FIELDS := ["schema", "sourceId", "sourcePartId", "sourceRevision", "producerSourceRevision",
	"presentationMemberId", "attachmentKey", "ownershipKind", "intendedVisible",
	"neutralParentToWorld", "sweptWorldBounds", "motion"]


static func validate(value: Variant, source_id: String, part_id: String,
		revision: String) -> Dictionary:
	if not value is Dictionary or not value.is_read_only():
		return _failed("mutable_or_invalid_presentation_member")
	var row: Dictionary = value
	if row.size() != FIELDS.size():
		return _failed("presentation_member_fields_not_exact")
	for field: String in FIELDS:
		if not row.has(field): return _failed("presentation_member_field_missing:" + field)
	for field: String in ["schema", "sourceId", "sourcePartId", "sourceRevision", "producerSourceRevision",
			"presentationMemberId", "attachmentKey", "ownershipKind"]:
		if not row[field] is String or String(row[field]).strip_edges().is_empty():
			return _failed("presentation_member_identity_invalid:" + field)
	if row.schema != SCHEMA or row.sourceId != source_id \
			or row.sourcePartId != part_id or row.sourceRevision != revision:
		return _failed("presentation_member_source_identity_mismatch")
	if row.ownershipKind != "borrowed_presentation" or not row.intendedVisible is bool:
		return _failed("presentation_member_policy_invalid")
	if not row.neutralParentToWorld is Transform3D \
			or not row.neutralParentToWorld.is_finite() \
			or is_zero_approx(row.neutralParentToWorld.basis.determinant()):
		return _failed("presentation_member_neutral_transform_invalid")
	if not row.sweptWorldBounds is AABB:
		return _failed("presentation_member_bounds_missing")
	var bounds: AABB = row.sweptWorldBounds
	if not bounds.position.is_finite() or not bounds.size.is_finite() \
			or not bounds.end.is_finite() or bounds.size.x <= 0.0 \
			or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return _failed("presentation_member_bounds_invalid")
	if not _valid_motion(row.motion):
		return _failed("presentation_member_motion_invalid")
	return {"status":"ready"}


static func _valid_motion(value: Variant) -> bool:
	if not value is Dictionary or not value.is_read_only() or value.size() != 4:
		return false
	var motion: Dictionary = value
	if not motion.get("kind") is String or motion.kind not in ["static", "swing", "raise"] \
			or not motion.get("closedParentToBody") is Transform3D \
			or not motion.closedParentToBody.is_finite() \
			or is_zero_approx(motion.closedParentToBody.basis.determinant()) \
			or not motion.get("raiseOffset") is Vector3 or not motion.raiseOffset.is_finite() \
			or not motion.get("swing") is float or not is_finite(motion.swing):
		return false
	if motion.kind == "static":
		return motion.raiseOffset == Vector3.ZERO and motion.swing == 0.0
	if motion.kind == "swing":
		return motion.raiseOffset == Vector3.ZERO and absf(motion.swing) > 0.0 \
			and absf(motion.swing) <= PI
	return motion.swing == 0.0 and motion.raiseOffset.length_squared() > 0.000001


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason}


static func validate_stream_dependency_bounds(bounds: AABB, chunk_size: float) -> Dictionary:
	# Check in floating point before integer conversion or enumeration. This is
	# an explicit candidate resource limit, never permission to truncate coverage.
	if not is_finite(chunk_size) or chunk_size <= 0.0:
		return _failed("presentation_dependency_chunk_size_invalid")
	var low_x := floorf(bounds.position.x / chunk_size)
	var low_z := floorf(bounds.position.z / chunk_size)
	var high_x := ceilf(bounds.end.x / chunk_size) - 1.0
	var high_z := ceilf(bounds.end.z / chunk_size) - 1.0
	if not is_finite(low_x) or not is_finite(low_z) \
			or not is_finite(high_x) or not is_finite(high_z) \
			or low_x < -2147483648.0 or low_z < -2147483648.0 \
			or low_x >= 2147483648.0 or low_z >= 2147483648.0 \
			or high_x >= 2147483648.0 or high_z >= 2147483648.0:
		return _failed("presentation_dependency_coordinate_out_of_range")
	var width := maxf(1.0, high_x - low_x + 1.0)
	var depth := maxf(1.0, high_z - low_z + 1.0)
	if width > MAX_STREAM_DEPENDENCIES or depth > MAX_STREAM_DEPENDENCIES \
			or width * depth > MAX_STREAM_DEPENDENCIES:
		return _failed("presentation_dependency_capacity")
	return {"status":"ready"}


static func valid_grid_position(position: Vector3, grid_size: float) -> bool:
	if not position.is_finite() or not is_finite(grid_size) or grid_size <= 0.0:
		return false
	for component: float in [position.x, position.y, position.z]:
		var coordinate := component / grid_size
		if coordinate < -2147483648.0 or coordinate >= 2147483648.0:
			return false
	return true
