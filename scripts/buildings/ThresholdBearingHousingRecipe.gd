extends RefCounted

## Pure geometry proposal, NOT rooted proof or overlap admission. The caller
## binds the unchanged selected seat to its initial Blueprint proof, constructs
## the actual Part, and checks every other source/reserved part as a blocker.
## A 70 mm masonry housing is a recipe-defined construction dimension, not a
## coordinate-dependent tolerance or a search for convenient float32 endpoints.
const EMBEDMENT := 0.07
const MIN_EMBEDMENT := 0.06
const MAX_EMBEDMENT := 0.08
const INSET := 0.005
const MIN_SPAN := 0.12
const MIN_VERTICAL := 0.04
const MIN_DIMENSION := 0.02
const MAX_DIMENSION := 10000.0


static func prepare(seat, upper: float, center: Vector3, size: Vector3) -> Dictionary:
	if seat == null or not is_finite(upper) or not _box(center, size):
		return _fail("invalid_threshold_housing_input")
	if not _full_box(seat):
		return _fail("invalid_threshold_housing_seat")
	var seat_top: float = float(seat.position.y) + float(seat.size.y) * 0.5
	var seat_bottom: float = float(seat.position.y) - float(seat.size.y) * 0.5
	if seat_bottom < 0.0 or seat_top <= 0.0 or upper <= seat_top or upper > MAX_DIMENSION:
		return _fail("invalid_threshold_housing_domain")
	# The WHOLE post footprint must fit, not merely the declared joint patch.
	for axis in [0, 2]:
		if absf(float(center[axis]) - float(seat.position[axis])) + float(size[axis]) * 0.5 \
				>= float(seat.size[axis]) * 0.5 - INSET:
			return _fail("threshold_housing_footprint_outside_seat")
	var position := Vector3(center.x, (seat_top - EMBEDMENT + upper) * 0.5, center.z)
	# Derive height from the ALREADY STORED center; upper remains a scalar double.
	var housed_size := Vector3(size.x, 2.0 * (upper - float(position.y)), size.z)
	var bottom := float(position.y) - float(housed_size.y) * 0.5
	var top := float(position.y) + float(housed_size.y) * 0.5
	var embedment := seat_top - bottom
	if not _box(position, housed_size) or top != upper:
		return _fail("unrepresentable_threshold_housing_upper")
	if embedment < MIN_EMBEDMENT or embedment > MAX_EMBEDMENT or bottom < seat_bottom + INSET:
		return _fail("threshold_housing_depth_outside_seat")
	var fact := _fact(seat, seat_top, position, housed_size)
	if fact.is_empty(): return _fail("threshold_housing_joint_does_not_fit")
	var result := _validate_geometry(position, housed_size, seat, fact)
	if not result.ready: return result
	result["position"] = position
	result["size"] = housed_size
	result["seatFact"] = fact
	return result


static func validate(bearing, seat, fact: Dictionary) -> Dictionary:
	# Independent of prepare's construction formula and of any cached proof.
	# Main separately requires byte-identical deterministic preparation and a
	# proof-bound seat; geometry alone cannot authorize a rooted load path.
	if not _full_box(bearing) or not _full_box(seat) or bearing == seat or String(bearing.id) == String(seat.id):
		return _fail("invalid_threshold_housing_boxes")
	return _validate_geometry(bearing.position, bearing.size, seat, fact)


static func _validate_geometry(position: Vector3, size: Vector3, seat, fact: Dictionary) -> Dictionary:
	var seat_top: float = float(seat.position.y) + float(seat.size.y) * 0.5
	var seat_bottom: float = float(seat.position.y) - float(seat.size.y) * 0.5
	var bottom := float(position.y) - float(size.y) * 0.5
	var top := float(position.y) + float(size.y) * 0.5
	var embedment := seat_top - bottom
	if not _box(position, size) or seat_bottom < 0.0 or seat_top <= 0.0 or top <= seat_top or top > MAX_DIMENSION:
		return _fail("invalid_threshold_housing_domain")
	if embedment < MIN_EMBEDMENT or embedment > MAX_EMBEDMENT or bottom < seat_bottom + INSET:
		return _fail("threshold_housing_depth_outside_seat")
	var intersection_min: Array = []
	var intersection_max: Array = []
	for axis in [0, 1, 2]:
		var post_low := float(position[axis]) - float(size[axis]) * 0.5
		var post_high := float(position[axis]) + float(size[axis]) * 0.5
		var seat_low: float = float(seat.position[axis]) - float(seat.size[axis]) * 0.5
		var seat_high: float = float(seat.position[axis]) + float(seat.size[axis]) * 0.5
		if axis != 1 and (post_low <= seat_low + INSET or post_high >= seat_high - INSET):
			return _fail("threshold_housing_footprint_outside_seat")
		var low := maxf(post_low, seat_low)
		var high := minf(post_high, seat_high)
		if low >= high: return _fail("threshold_housing_no_positive_intersection")
		intersection_min.append(low)
		intersection_max.append(high)
	# The ENTIRE penetration is the post footprint in the seat's top region,
	# not an arbitrary tiny witness legitimizing an unrelated side/bottom clash.
	if intersection_min[1] != bottom or intersection_max[1] != seat_top \
			or intersection_min[1] < seat_top - MAX_EMBEDMENT:
		return _fail("threshold_housing_intersection_outside_top_region")
	var witness := _witness(position, size, seat, fact)
	if witness.is_empty(): return _fail("invalid_threshold_housing_witness")
	# Bounds deliberately use scalar arrays, not AABB/Vector3 rounded endpoints.
	return {"ready": true, "seated": true, "seatId": String(seat.id), "seatPlane": seat_top,
		"actualEmbedment": embedment, "contactMode": "housed_overlap",
		"intersectionBounds": {"min": intersection_min, "max": intersection_max}, "witnessBounds": witness}


static func _fact(seat, seat_top: float, position: Vector3, size: Vector3) -> Dictionary:
	var local_center := Vector3(0.0, seat_top - 0.035 - float(position.y), 0.0)
	var half := Vector3(0.0, 0.025, 0.0)
	for axis in [0, 2]:
		var offset: float = float(seat.position[axis]) - float(position[axis])
		var low := maxf(-float(size[axis]) * 0.5 + INSET, offset - float(seat.size[axis]) * 0.5 + INSET)
		var high := minf(float(size[axis]) * 0.5 - INSET, offset + float(seat.size[axis]) * 0.5 - INSET)
		if low >= high: return {}
		local_center[axis] = (low + high) * 0.5
		half[axis] = (high - low) * 0.25
		# Recheck the stored fields, not their pre-conversion scalar expressions.
		if float(local_center[axis]) - float(half[axis]) < low \
				or float(local_center[axis]) + float(half[axis]) > high:
			return {}
	var span_axis := 0 if half.x >= half.z else 2
	if not local_center.is_finite() or not half.is_finite() or half.x <= 0.0 or half.y <= 0.0 or half.z <= 0.0 \
			or float(half[span_axis]) * 2.0 < MIN_SPAN or float(half.y) * 2.0 < MIN_VERTICAL:
		return {}
	# Existing GabledRoofFrameBuilder housed_joint_fact schema; no gravity-patch
	# loadDirection tag, since this is a volumetric housed joint, not a face seat.
	var fact := {"seatId": String(seat.id), "contactMode": "housed_overlap",
		"localSpanAxis": "x" if span_axis == 0 else "z",
		"localOverlapCenter": local_center, "localOverlapHalfExtents": half,
		"minimumLongitudinalEmbedment": MIN_SPAN, "minimumVerticalOverlap": MIN_VERTICAL}
	return fact if not _witness(position, size, seat, fact).is_empty() else {}


static func _witness(position: Vector3, size: Vector3, seat, fact: Dictionary) -> Dictionary:
	if fact.get("seatId") != String(seat.id) or fact.get("contactMode") != "housed_overlap" \
			or fact.get("localSpanAxis") not in ["x", "z"] \
			or not fact.get("localOverlapCenter") is Vector3 or not fact.get("localOverlapHalfExtents") is Vector3:
		return {}
	var local_center: Vector3 = fact.localOverlapCenter
	var half: Vector3 = fact.localOverlapHalfExtents
	var span_axis := 0 if fact.localSpanAxis == "x" else 2
	for key: String in ["minimumLongitudinalEmbedment", "minimumVerticalOverlap"]:
		if not (fact.get(key, 0.0) is float or fact.get(key, 0.0) is int) or not is_finite(float(fact.get(key, 0.0))):
			return {}
	if not local_center.is_finite() or not half.is_finite() or half.x <= 0 or half.y <= 0 or half.z <= 0 \
			or float(half[span_axis]) * 2.0 < maxf(MIN_SPAN, float(fact.get("minimumLongitudinalEmbedment", 0.0))) \
			or float(half.y) * 2.0 < maxf(MIN_VERTICAL, float(fact.get("minimumVerticalOverlap", 0.0))):
		return {}
	var witness_min: Array = []
	var witness_max: Array = []
	for axis in [0, 1, 2]:
		if absf(float(local_center[axis])) + float(half[axis]) > float(size[axis]) * 0.5 - INSET:
			return {}
		witness_min.append(float(position[axis]) + float(local_center[axis]) - float(half[axis]))
		witness_max.append(float(position[axis]) + float(local_center[axis]) + float(half[axis]))
	# Check scalar corners against both stored boxes AND the validator's stored
	# Vector3 transform path. Neither double nor float32 arithmetic may leak out.
	var bearer_transform := Transform3D(Basis.IDENTITY, position)
	var seat_inverse := Transform3D(Basis.IDENTITY, seat.position).affine_inverse()
	for x_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var signs := Vector3(x_sign, y_sign, z_sign)
				var local_point := local_center + half * signs
				var point_in_seat := seat_inverse * (bearer_transform * local_point)
				for axis in [0, 1, 2]:
					var corner := float(local_center[axis]) + float(half[axis]) * float(signs[axis])
					var seat_corner: float = float(position[axis]) + corner - float(seat.position[axis])
					if absf(corner) > float(size[axis]) * 0.5 - INSET \
							or absf(float(local_point[axis])) > float(size[axis]) * 0.5 - INSET \
							or absf(seat_corner) >= float(seat.size[axis]) * 0.5 - INSET \
							or absf(float(point_in_seat[axis])) >= float(seat.size[axis]) * 0.5 - INSET:
						return {}
	return {"min": witness_min, "max": witness_max}


static func _full_box(part) -> bool:
	return part != null and _box(part.position, part.size) and part.rotation.is_finite() \
		and part.rotation == Vector3.ZERO and not String(part.id).is_empty() \
		and part.kind == "foundation" and part.collision_enabled \
		and String(part.physical_intent) in ["", "structural_mass", "structural_root"] \
		and not part.recipe.has("masonryApertureSource") and not part.recipe.has("pavingFootingJoints")


static func _box(center: Vector3, size: Vector3) -> bool:
	if not center.is_finite() or not size.is_finite(): return false
	for axis in [0, 1, 2]:
		if absf(float(center[axis])) > MAX_DIMENSION or float(size[axis]) < MIN_DIMENSION \
				or float(size[axis]) > MAX_DIMENSION:
			return false
	return true


static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "seated": false, "reason": reason}
