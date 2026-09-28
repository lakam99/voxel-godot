extends RefCounted

## Reconcile two independently rounded outputs of the same producer ground
## plane. This changes only the failed threshold's thickness, never its centre.
const Math = preload("res://scripts/buildings/ConstructionSeamMath.gd")
const Boxes = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const MAX_CORRECTION := 0.000001

static func normalize(threshold, foundation) -> Dictionary:
	for part in [threshold, foundation]:
		if part == null or part.rotation != Vector3.ZERO or not part.position.is_finite() or not part.size.is_finite() \
			or part.size.x < 0.02 or part.size.y < 0.02 or part.size.z < 0.02:
			return {"ready": false, "reason": "invalid_threshold_plane_source"}
	var center: float = threshold.position.y
	var old_height: float = threshold.size.y
	var foundation_top: float = float(foundation.position.y) + float(foundation.size.y) * 0.5
	var height := float(Vector3(0.0, 2.0 * (center - foundation_top), 0.0).y)
	# Independent producer-error bound: one full representable step for each
	# stored centre and half-height term, propagated through h = 2(C - F), plus
	# one step for the originally stored thickness. It does not depend on the
	# correction being requested; the absolute ceiling is also mandatory.
	var terms := {"thresholdCenterUlp": _ulp(center), "foundationCenterUlp": _ulp(foundation.position.y),
		"foundationHeightUlp": _ulp(foundation.size.y), "thresholdHeightUlp": _ulp(old_height)}
	var rounding_bound: float = 2.0 * (terms.thresholdCenterUlp + terms.foundationCenterUlp + 0.5 * terms.foundationHeightUlp) + terms.thresholdHeightUlp
	var correction: float = height - old_height
	var new_bottom: float = center - height * 0.5
	if not is_finite(height) or height < 0.02 or absf(correction) > MAX_CORRECTION or absf(correction) > rounding_bound \
		or new_bottom != foundation_top:
		return {"ready": false, "reason": "unrepresentable_threshold_construction_plane",
			"oldHeight": old_height, "proposedHeight": height, "correction": correction, "roundingBound": rounding_bound}
	var record: Dictionary = threshold.snapshot()
	var size: Vector3 = record.size
	size.y = height
	record.size = size
	var old_box := _bounds(threshold.position, threshold.size)
	var new_box := _bounds(threshold.position, size)
	var delta := Boxes.removed([new_box], [old_box])
	if not delta.ready: return {"ready": false, "reason": "threshold_plane_delta_failed"}
	return {"ready": true, "record": record, "oldHeight": old_height, "newHeight": height,
		"correction": correction, "roundingBound": rounding_bound, "roundingTerms": terms,
		"absoluteCeiling": MAX_CORRECTION, "oldBottom": old_box[1], "newBottom": new_box[1],
		"oldTop": old_box[4], "newTop": new_box[4],
		"bottomDisplacement": new_box[1] - old_box[1], "topDisplacement": new_box[4] - old_box[4],
		"foundationTop": foundation_top, "exactSharedPlane": new_box[1] == foundation_top,
		"addedVolumes": delta.cells}

static func _ulp(value: float) -> float:
	var magnitude := absf(value)
	return Math.next_float32_up(magnitude) - magnitude

static func _bounds(center: Vector3, size: Vector3) -> Array:
	return [float(center.x) - float(size.x) * 0.5, float(center.y) - float(size.y) * 0.5, float(center.z) - float(size.z) * 0.5,
		float(center.x) + float(size.x) * 0.5, float(center.y) + float(size.y) * 0.5, float(center.z) + float(size.z) * 0.5]
