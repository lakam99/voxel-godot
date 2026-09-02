extends RefCounted
## Camera-review heuristic only, never gameplay or geometry acceptance.
## Caller supplies nine independently measured first-hit flags for ONE target.
## False includes blocked/missing hits; incomplete work must not be padded true.
const GRID_FRACTIONS := [0.15, 0.5, 0.85]
const SAMPLE_COUNT := 9
const MIN_VISIBLE_COUNT := 6
const MIN_SPREAD_FRACTION := 0.5
const MIN_PROJECTED_PIXELS := 4.0

static func sample_positions(rect: Variant) -> Array[Vector2]:
	var points: Array[Vector2] = []
	if not _rect_reason(rect).is_empty(): return points
	var box: Rect2 = rect
	for y_fraction in GRID_FRACTIONS:
		for x_fraction in GRID_FRACTIONS:
			var point: Vector2 = box.position + box.size * Vector2(float(x_fraction), float(y_fraction))
			if not point.is_finite(): return []
			points.append(point)
	return points

static func evaluate(rect: Variant, flags: Variant) -> Dictionary:
	var result: Dictionary = {"passed": false, "reason": "", "sampleCount": 0,
		"visibleCount": 0, "spreadX": 0.0, "spreadY": 0.0}
	var rect_reason: String = _rect_reason(rect)
	if not rect_reason.is_empty():
		result.reason = rect_reason
		return result
	if not flags is Array:
		result.reason = "flags_not_array"
		return result
	result.sampleCount = flags.size()
	if flags.size() != SAMPLE_COUNT:
		result.reason = "incomplete_or_invalid_sample_count"
		return result
	for flag in flags:
		if not flag is bool:
			result.reason = "non_boolean_sample"
			return result
	var points: Array[Vector2] = sample_positions(rect)
	if points.size() != SAMPLE_COUNT:
		result.reason = "invalid_projected_samples"
		return result
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for index in range(SAMPLE_COUNT):
		if not flags[index]: continue
		result.visibleCount = int(result.visibleCount) + 1
		low = low.min(points[index])
		high = high.max(points[index])
	if int(result.visibleCount) > 0:
		var box: Rect2 = rect
		result.spreadX = float(high.x - low.x) / float(box.size.x)
		result.spreadY = float(high.y - low.y) / float(box.size.y)
	if int(result.visibleCount) < MIN_VISIBLE_COUNT:
		result.reason = "insufficient_visible_samples"
	elif float(result.spreadX) < MIN_SPREAD_FRACTION or float(result.spreadY) < MIN_SPREAD_FRACTION:
		result.reason = "insufficient_visible_spread"
	else:
		result.passed = true
		result.reason = "distributed_coverage"
	return result

static func _rect_reason(rect: Variant) -> String:
	if not rect is Rect2: return "invalid_projected_rect_type"
	var box: Rect2 = rect
	if not box.position.is_finite() or not box.size.is_finite() or not box.end.is_finite():
		return "nonfinite_projected_rect"
	if box.size.x <= 0.0 or box.size.y <= 0.0 or box.end.x <= box.position.x or box.end.y <= box.position.y:
		return "degenerate_projected_rect"
	if box.size.x < MIN_PROJECTED_PIXELS or box.size.y < MIN_PROJECTED_PIXELS:
		return "projected_rect_too_small"
	return ""
