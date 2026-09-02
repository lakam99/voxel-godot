extends RefCounted

## Pure represented-height proposal only: no source, admission or publication.
## Positive endpoint domain (0, 10000]; endpoints are NEVER rounded or moved.
## Faces are scalar doubles reconstructed from stored float32 Vector3 fields,
## not Vector3 endpoint arithmetic (which would round the faces a second time).
const MIN_HEIGHT := 0.02
const MAX_DIMENSION := 10000.0
const MAX_CANDIDATES := 64
const MIN_EXPONENT := -126
const MAX_EXPONENT := 13
const NEIGHBOR_STEPS := 4


static func prepare(lower: float, upper: float) -> Dictionary:
	if not is_finite(lower) or not is_finite(upper):
		return _fail("nonfinite_threshold_course_input")
	if lower <= 0.0 or upper <= lower or upper > MAX_DIMENSION:
		return _fail("invalid_threshold_course_bounds")
	var singleton := _exact_course(lower, upper)
	if not singleton.is_empty():
		return {"ready": true, "courses": [singleton], "splitTrials": 0, "candidateCount": 0}
	if upper - lower < MIN_HEIGHT:
		return _fail("threshold_course_span_too_short")
	# Enumeration is unconditionally bounded: 140 exponents * 9 planes = 1260.
	# Collect the COMPLETE eligible set before testing any split. Even a known
	# early fit must fail closed when the total exceeds MAX_CANDIDATES.
	var unique: Dictionary = {}
	for exponent in range(MIN_EXPONENT, MAX_EXPONENT + 1):
		var power := pow(2.0, exponent)
		_collect(unique, power, lower, upper)
		var predecessor := power
		var successor := power
		for _step in range(NEIGHBOR_STEPS):
			predecessor = _step_positive_float32(predecessor, -1)
			successor = _step_positive_float32(successor, 1)
			_collect(unique, predecessor, lower, upper)
			_collect(unique, successor, lower, upper)
	var planes: Array = unique.keys()
	planes.sort()
	if planes.size() > MAX_CANDIDATES:
		return _fail("threshold_course_search_overflow", 0, planes.size())
	var trials := 0
	for plane: float in planes:
		trials += 1
		var bottom_course := _exact_course(lower, plane)
		var top_course := _exact_course(plane, upper)
		if not bottom_course.is_empty() and not top_course.is_empty():
			return {"ready": true, "courses": [bottom_course, top_course],
				"splitTrials": trials, "candidateCount": planes.size()}
	return _fail("no_exact_threshold_courses", trials, planes.size())


static func _exact_course(bottom: float, top: float) -> Dictionary:
	var stored_center := Vector3(0.0, (bottom + top) * 0.5, 0.0)
	var stored_size := Vector3(1.0, top - bottom, 1.0)
	var center_y := float(stored_center.y)
	var height := float(stored_size.y)
	if height < MIN_HEIGHT or height > MAX_DIMENSION:
		return {}
	if center_y - height * 0.5 != bottom or center_y + height * 0.5 != top:
		return {}
	return {"centerY": center_y, "height": height, "bottom": bottom, "top": top}


static func _collect(unique: Dictionary, plane: float, lower: float, upper: float) -> void:
	# Eligibility is geometric, not an exact-pair prefilter. Neither course may
	# be shorter than BuildingPart's minimum, even before float32 storage.
	if plane > lower and plane < upper and plane - lower >= MIN_HEIGHT and upper - plane >= MIN_HEIGHT:
		unique[plane] = true


static func _step_positive_float32(value: float, direction: int) -> float:
	# Only called with finite positive powers/neighbours inside the fixed bound.
	# Own bit stepping avoids adding dependencies to shared seam/admission math.
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	bytes.encode_u32(0, bytes.decode_u32(0) + direction)
	return bytes.decode_float(0)


static func _fail(reason: String, trials: int = 0, count: int = 0) -> Dictionary:
	# Fixed-size diagnostics: no unbounded plane list or invalid NAN/INF payload.
	return {"ready": false, "courses": [], "splitTrials": trials,
		"candidateCount": count, "candidateLimit": MAX_CANDIDATES, "reason": reason}
