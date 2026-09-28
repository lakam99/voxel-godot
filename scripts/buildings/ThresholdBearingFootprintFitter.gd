extends RefCounted

## Bounded, deterministic rectangular ground-column domains beneath a threshold.
## No source edits, physics calls, tolerance relaxation or geometry publication.
## The caller must still construct representable boxes and admit every candidate
## against the complete source and reservation set, not just the fitting bounds.
const Boxes = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const ConstructionMath = preload("res://scripts/buildings/ConstructionSeamMath.gd")
const MAX_CANDIDATES := 64
const MAX_BOUNDS := 4096

## A housed column must fit its selected seat, not merely overlap a small
## contact patch. Clip only the new column's XZ domain; no source/seat edits,
## seat selection, Y construction, rooted proof or collision admission here.
static func fit_seat_footprint(center: Vector3, size: Vector3, seat_center: Vector3, seat_size: Vector3, inset: float) -> Dictionary:
	if not is_finite(inset) or inset < 0.0:
		return _fail("invalid_threshold_seat_footprint")
	for box in [[center,size],[seat_center,seat_size]]:
		for axis in range(3):
			if not is_finite(float(box[0][axis])) or not is_finite(float(box[1][axis])) \
					or absf(float(box[0][axis])) > 10000.0 or float(box[1][axis]) < 0.02 or float(box[1][axis]) > 10000.0:
				return _fail("invalid_threshold_seat_footprint")
	var fitted_center := center
	var fitted_size := size
	for axis in [0,2]:
		var original_low := float(center[axis])-float(size[axis])*0.5
		var original_high := float(center[axis])+float(size[axis])*0.5
		var seat_low := float(seat_center[axis])-float(seat_size[axis])*0.5+inset
		var seat_high := float(seat_center[axis])+float(seat_size[axis])*0.5-inset
		if original_low > seat_low and original_high < seat_high: continue
		var low := maxf(original_low,seat_low)
		var high := minf(original_high,seat_high)
		if low >= high: return _fail("no_threshold_seat_footprint")
		fitted_center[axis]=(low+high)*0.5
		fitted_size[axis]=minf(float(size[axis]),2.0*minf(float(fitted_center[axis])-low,high-float(fitted_center[axis])))
		var contained := false
		for attempt in range(4):
			var stored_low := float(fitted_center[axis])-float(fitted_size[axis])*0.5
			var stored_high := float(fitted_center[axis])+float(fitted_size[axis])*0.5
			if fitted_size[axis] >= 0.02 and stored_low >= original_low and stored_high <= original_high and stored_low > seat_low and stored_high < seat_high:
				contained=true
				break
			fitted_size[axis]=-ConstructionMath.next_float32_up(-float(fitted_size[axis]))
		if not contained: return _fail("unrepresentable_threshold_seat_footprint")
	return {"ready":true,"position":fitted_center,"size":fitted_size,"changed":fitted_center!=center or fitted_size!=size}

static func derive(domain: Array, door_bounds: Array) -> Dictionary:
	if not Boxes.valid(domain) or door_bounds.size() > MAX_BOUNDS:
		return _fail("invalid_threshold_fit_domain")
	var scalar_bounds: Array = []
	for value: Variant in door_bounds:
		if not value is AABB or not value.position.is_finite() or not value.size.is_finite() \
			or not value.end.is_finite() or value.size.x <= 0.0 or value.size.y <= 0.0 or value.size.z <= 0.0:
			return _fail("invalid_threshold_fit_obstacle")
		# Admission represents an AABB as centre plus local scale. Use that exact
		# same stored pair; native position+size reconstruction may round inward.
		var center: Vector3 = value.get_center()
		var box := [float(center.x) - float(value.size.x) * 0.5, float(center.y) - float(value.size.y) * 0.5,
			float(center.z) - float(value.size.z) * 0.5, float(center.x) + float(value.size.x) * 0.5,
			float(center.y) + float(value.size.y) * 0.5, float(center.z) + float(value.size.z) * 0.5]
		if not Boxes.valid(box): return _fail("unsupported_threshold_fit_obstacle_bounds")
		scalar_bounds.append(box)
	return derive_scalar(domain, scalar_bounds)

## Already represented scalar intervals: never convert these source coordinates
## through AABB/Vector3. Validate every input before any empty-space early exit.
static func derive_scalar(domain: Array, obstacle_bounds: Array) -> Dictionary:
	if not Boxes.valid(domain) or obstacle_bounds.size() > MAX_BOUNDS:
		return _fail("invalid_threshold_fit_domain")
	var cuts: Array = []
	for box: Variant in obstacle_bounds:
		if not Boxes.valid(box): return _fail("invalid_threshold_fit_obstacle")
		# A single ground-to-threshold column cannot pass above/below an obstacle
		# occupying any of its height. Project the real intersecting volume onto XZ.
		if Boxes.intersection(domain, box).is_empty(): continue
		var cut := [maxf(domain[0], box[0]), domain[1], maxf(domain[2], box[2]),
			minf(domain[3], box[3]), domain[4], minf(domain[5], box[5])]
		if not cuts.has(cut): cuts.append(cut)
	cuts.sort_custom(_lexical)
	var cells: Array = [domain.duplicate()]
	var steps := 0
	for cut: Array in cuts:
		var next: Array = []
		for cell: Array in cells:
			steps += 1
			var overlap := Boxes.intersection(cell, cut)
			if overlap.is_empty():
				next.append(cell)
			else:
				var remainder := cell.duplicate()
				for axis in [0, 2]:
					if overlap[axis] > remainder[axis]:
						var low := remainder.duplicate()
						low[axis + 3] = overlap[axis]
						next.append(low)
						remainder[axis] = overlap[axis]
					if overlap[axis + 3] < remainder[axis + 3]:
						var high := remainder.duplicate()
						high[axis] = overlap[axis + 3]
						next.append(high)
						remainder[axis + 3] = overlap[axis + 3]
			# Do not silently truncate geometry or keep a lucky first subset.
			if next.size() > MAX_CANDIDATES: return _fail("threshold_fit_candidate_limit", {"steps": steps})
		cells = next
		if cells.is_empty(): break
	cells.sort_custom(func(a, b):
		var area_a: float = (a[3] - a[0]) * (a[5] - a[2])
		var area_b: float = (b[3] - b[0]) * (b[5] - b[2])
		return area_a > area_b if area_a != area_b else _lexical(a, b))
	return {"ready": true, "candidates": cells, "candidateCount": cells.size(),
		"cutCount": cuts.size(), "steps": steps, "reason": "" if not cells.is_empty() else "no_clear_threshold_footprint"}

## Scalar represented-box contact, independent of the structural validator's
## 5 cm graph margin. A positive gap is reported as a gap, not rounded to zero.
static func measure_contact(bearing, threshold, ground_plane: float) -> Dictionary:
	if bearing == null or threshold == null or not is_finite(ground_plane): return _fail("invalid_threshold_contact")
	for part in [bearing, threshold]:
		if part.rotation != Vector3.ZERO or not part.position.is_finite() or not part.size.is_finite() \
			or part.size.x <= 0.0 or part.size.y <= 0.0 or part.size.z <= 0.0: return _fail("invalid_threshold_contact")
	var a := _bounds(bearing)
	var b := _bounds(threshold)
	var width: float = maxf(0.0, minf(a[3], b[3]) - maxf(a[0], b[0]))
	var depth: float = maxf(0.0, minf(a[5], b[5]) - maxf(a[2], b[2]))
	var gap: float = b[1] - a[4]
	var ground_gap: float = a[1] - ground_plane
	return {"ready": true, "bearingBounds": a, "thresholdBounds": b,
		"contactArea": width * depth, "verticalGap": gap, "groundGap": ground_gap,
		"exactTopContact": gap == 0.0 and width > 0.0 and depth > 0.0,
		"meetsGroundPlane": ground_gap <= 0.0 and a[4] > ground_plane}

static func _bounds(part) -> Array:
	return [float(part.position.x) - float(part.size.x) * 0.5, float(part.position.y) - float(part.size.y) * 0.5,
		float(part.position.z) - float(part.size.z) * 0.5, float(part.position.x) + float(part.size.x) * 0.5,
		float(part.position.y) + float(part.size.y) * 0.5, float(part.position.z) + float(part.size.z) * 0.5]

static func _lexical(a: Array, b: Array) -> bool:
	for index in range(6):
		if a[index] != b[index]: return a[index] < b[index]
	return false

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["reason"] = reason
	return result
