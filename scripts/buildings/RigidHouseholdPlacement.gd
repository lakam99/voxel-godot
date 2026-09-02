extends RefCounted

const MAX_OBSTACLES := 32

## Deterministic rigid placement from caller-supplied authoritative footprints.
## This solver neither authors household geometry nor moves source records.
static func find_translation(moving: Rect2, allowed: Rect2, obstacles: Array, clearance: float) -> Dictionary:
	if not _valid(moving) or not _valid(allowed) or not is_finite(clearance) or clearance < 0.0:
		return {"ready": false, "reason": "invalid_placement_bounds"}
	# Explicit finite search envelope; callers must not silently omit obstacles.
	if obstacles.size() > MAX_OBSTACLES:
		return {"ready": false, "reason": "placement_obstacle_limit", "limit": MAX_OBSTACLES}
	var xs: Array = [0.0, allowed.position.x - moving.position.x, allowed.end.x - moving.end.x]
	var zs: Array = [0.0, allowed.position.y - moving.position.y, allowed.end.y - moving.end.y]
	var reserved: Array[Rect2] = []
	for value in obstacles:
		if not value is Rect2 or not _valid(value):
			return {"ready": false, "reason": "invalid_reserved_footprint"}
		var rect: Rect2 = value.grow(clearance)
		if not _valid(rect):
			return {"ready": false, "reason": "invalid_expanded_footprint"}
		reserved.append(rect)
		xs.append(rect.position.x - moving.end.x)
		xs.append(rect.end.x - moving.position.x)
		zs.append(rect.position.y - moving.end.y)
		zs.append(rect.end.y - moving.position.y)
	# The nearest point outside axis-aligned forbidden translation rectangles
	# lies at zero or one of their boundary coordinates. No random/grid search.
	var best := Vector2.INF
	var best_distance := INF
	var tested := 0
	for x in xs:
		for z in zs:
			var delta := Vector2(x, z)
			var distance := delta.length_squared()
			if distance > best_distance:
				continue
			var placed := Rect2(moving.position + delta, moving.size)
			tested += 1
			if not allowed.encloses(placed):
				continue
			if reserved.any(func(rect: Rect2): return rect.intersects(placed)):
				continue
			if distance < best_distance or distance == best_distance and (delta.x < best.x or delta.x == best.x and delta.y < best.y):
				best = delta
				best_distance = distance
	if best == Vector2.INF:
		return {"ready": false, "reason": "no_placement_under_envelope_policy", "testedCandidates": tested}
	return {"ready": true, "reason": "", "translation": Vector3(best.x, 0.0, best.y), "testedCandidates": tested,
		"clearance": clearance, "placedFootprint": Rect2(moving.position + best, moving.size)}

static func _valid(rect: Rect2) -> bool:
	return rect.position.is_finite() and rect.size.is_finite() and rect.end.is_finite() and rect.size.x > 0.0 and rect.size.y > 0.0
