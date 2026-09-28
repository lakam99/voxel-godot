extends RefCounted

## Pure local, fixed-X placement. NOT a global two-dimensional search.
## Closed domain, open positive-volume obstacle intersections (touch is legal).
## Optional continuation is zero-argument; false returns no partial placement.
const LIMIT := 10000.0
const MAX_OBSTACLES := 10000
const MAX_ENDPOINT_STEPS := 4
const MAX_COLUMN_ENDPOINTS := 2*MAX_OBSTACLES+3
const MAX_COLUMN_WORK := 16000000
const ConstructionMath = preload("res://scripts/buildings/ConstructionSeamMath.gd")

## Finite source-endpoint columns, nearest X then lower X; each column uses fit.
## Not a globally complete search or a minimum two-dimensional-distance solver.
## Conservative work charges include repeated fixed-X scans/sorts: exhaustion
## is explicit, never a sampled/subset no-fit. All source records remain values.
static func fit_columns(moving: AABB, allowed: Rect2, obstacles: Array, clearance: float, continuation: Callable = Callable()) -> Dictionary:
	if not _valid_box(moving) or not _valid_rect(allowed) or not is_finite(clearance) or clearance<0.0 or clearance>LIMIT or obstacles.size()>MAX_OBSTACLES:
		return _fail("invalid_boundary_infill_input")
	var source := obstacles.duplicate()
	var stopped := {"value":false}
	var proceed := func()->bool:
		if stopped.value: return false
		stopped.value=not _continue(continuation)
		return not stopped.value
	if not proceed.call(): return _fail("cancelled")
	for value: Variant in source:
		if not value is AABB or not _valid_box(value): return _fail("invalid_boundary_infill_obstacle")
		if not proceed.call(): return _fail("cancelled")
	var low := float(allowed.position.x)
	var high := minf(float(allowed.end.x),low+float(allowed.size.x))-float(moving.size.x)
	var z_high := minf(float(allowed.end.y),float(allowed.position.y)+float(allowed.size.y))
	if low>high or float(allowed.position.y)+float(moving.size.z)>z_high:
		return _fail("moving_bounds_exceed_domain")
	# Every original was validated above. Only this repeated-solver input is
	# pruned; the independent terminal scan below still uses ALL original boxes.
	# Positive-volume intersection with the complete allowed domain is necessary
	# for collision at any accepted pose. Clearance expands XZ only, never Y.
	var relevant: Array = []
	var x_high := minf(float(allowed.end.x),low+float(allowed.size.x))
	for obstacle: AABB in source:
		if not proceed.call(): return _fail("cancelled")
		if not _axis_overlap(moving,obstacle,1,0.0): continue
		if float(obstacle.position.x)-clearance>=x_high or _upper(obstacle,0)+clearance<=low: continue
		if float(obstacle.position.z)-clearance>=z_high or _upper(obstacle,2)+clearance<=float(allowed.position.y): continue
		relevant.append(obstacle)
	var endpoints: Array[Dictionary] = [
		{"x":clampf(float(moving.position.x),low,high),"direction":0.0},
		{"x":low,"direction":1.0},{"x":high,"direction":-1.0,"upper":minf(float(allowed.end.x),low+float(allowed.size.x))}]
	for obstacle: AABB in relevant:
		if not proceed.call(): return _fail("cancelled")
		endpoints.append({"x":float(obstacle.position.x)-float(moving.size.x)-clearance,"direction":-1.0,"upper":float(obstacle.position.x)-clearance})
		endpoints.append({"x":_upper(obstacle,0)+clearance,"direction":1.0})
		if endpoints.size()>MAX_COLUMN_ENDPOINTS: return _fail("column_endpoint_limit_exceeded")
	var candidates: Array[Dictionary] = []
	for endpoint: Dictionary in endpoints:
		if not proceed.call(): return _fail("cancelled")
		if endpoint.x<low or endpoint.x>high: continue
		var delta := float(Vector3(endpoint.x-float(moving.position.x),0,0).x)
		var column := AABB(moving.position+Vector3(delta,0,0),moving.size)
		for attempt in range(MAX_ENDPOINT_STEPS):
			if _column_endpoint_valid(column,allowed,endpoint): break
			if not proceed.call(): return _fail("cancelled")
			var direction: float = endpoint.direction
			if direction==0.0: direction=1.0 if float(column.position.x)<low else -1.0
			delta=_next_translation(float(moving.position.x),float(column.position.x),delta,direction)
			column=AABB(moving.position+Vector3(delta,0,0),moving.size)
		if not _column_endpoint_valid(column,allowed,endpoint): continue
		candidates.append({"bounds":column,"delta":delta,"distance":absf(float(column.position.x)-float(moving.position.x))})
	# Explicit tie order also makes duplicate represented columns independent
	# of obstacle enumeration when distinct deltas round onto the same position.
	candidates.sort_custom(func(a: Dictionary,b: Dictionary)->bool:
		if a.distance!=b.distance: return a.distance<b.distance
		if a.bounds.position.x!=b.bounds.position.x: return a.bounds.position.x<b.bounds.position.x
		return a.delta<b.delta)
	if not proceed.call(): return _fail("cancelled")
	var seen := {}
	var tested := 0
	var tested_columns := 0
	var work := source.size()*16+endpoints.size()*(32+int(ceil(log(float(endpoints.size()+1))/log(2.0))))
	for candidate: Dictionary in candidates:
		if not proceed.call(): return _fail("cancelled",tested)
		var column: AABB = candidate.bounds
		if seen.has(column.position.x): continue
		seen[column.position.x]=true
		# Fixed-X fitting can only be affected by obstacles that overlap this
		# actual column. Preserve the complete `relevant` inventory for endpoint
		# discovery and the final full-source proof; this local set merely avoids
		# repeatedly sorting Z intervals that cannot intersect this column.
		var column_relevant := _column_relevant(column,relevant,clearance,proceed)
		if not column_relevant.ready: return _fail(String(column_relevant.reason),tested)
		var column_boxes: Array = column_relevant.boxes
		var fit_charge: int = 128+relevant.size()+column_boxes.size()*(64+8*int(ceil(log(float(2*column_boxes.size()+4))/log(2.0))))
		if work+fit_charge>MAX_COLUMN_WORK:
			return {"ready":false,"reason":"column_work_limit_exceeded","testedCandidates":tested,"testedColumns":tested_columns,"workUpperBound":work,"nextColumnWork":fit_charge,"sourceObstacleCount":source.size(),"relevantObstacleCount":relevant.size()}
		work+=fit_charge
		tested_columns+=1
		var result := fit(column,allowed,column_boxes,clearance,proceed)
		tested+=int(result.get("testedCandidates",0))
		if stopped.value: return _fail("cancelled",tested)
		if not result.ready: continue
		# Never compose two rounded X moves. A column was already represented
		# from the ORIGINAL origin; fixed-X fit must leave that column intact.
		if result.translation.x!=0.0: return _fail("represented_column_changed",tested)
		var total := Vector3(candidate.delta,0,result.translation.z)
		var placed := AABB(moving.position+total,moving.size)
		if placed!=result.placedBounds or not _in_domain(placed,allowed): return _fail("represented_column_result_invalid",tested)
		for obstacle: AABB in source:
			if not proceed.call(): return _fail("cancelled",tested)
			if _axis_overlap(placed,obstacle,0,clearance) and _axis_overlap(placed,obstacle,1,0.0) and _axis_overlap(placed,obstacle,2,clearance):
				return _fail("represented_column_result_blocked",tested)
		if not proceed.call(): return _fail("cancelled",tested)
		return {"ready":true,"translation":total,"placedBounds":placed,"testedCandidates":tested,"testedColumns":tested_columns,
			"columnEndpoints":endpoints.size(),"workUpperBound":work,"sourceObstacleCount":source.size(),"relevantObstacleCount":relevant.size(),"searchScope":"finite_geometry_columns_nearest_x_then_lower_x_not_global_optimum"}
	return {"ready":false,"reason":"no_clear_endpoint_column","testedCandidates":tested,"testedColumns":tested_columns,"workUpperBound":work,"sourceObstacleCount":source.size(),"relevantObstacleCount":relevant.size()}

static func _column_relevant(column: AABB, relevant: Array, clearance: float, proceed: Callable) -> Dictionary:
	var boxes: Array = []
	for obstacle: AABB in relevant:
		if not proceed.call(): return _fail("cancelled")
		if _axis_overlap(column,obstacle,0,clearance) and _axis_overlap(column,obstacle,1,0.0):
			boxes.append(obstacle)
	return {"ready":true,"boxes":boxes}

static func _column_endpoint_valid(column: AABB,allowed: Rect2,endpoint: Dictionary) -> bool:
	if float(column.position.x)<float(allowed.position.x) or _upper(column,0)>minf(float(allowed.end.x),float(allowed.position.x)+float(allowed.size.x)): return false
	# The lower obstacle endpoint constrains its represented UPPER face, not
	# just its origin; the upper endpoint constrains the represented lower face.
	if endpoint.direction<0.0: return _upper(column,0)<=float(endpoint.upper)
	if endpoint.direction>0.0: return float(column.position.x)>=float(endpoint.x)
	return true

static func fit(moving: AABB, allowed: Rect2, obstacles: Array, clearance: float, continuation: Callable = Callable()) -> Dictionary:
	if not _valid_box(moving) or not _valid_rect(allowed) or not is_finite(clearance) or clearance<0.0 or clearance>LIMIT or obstacles.size()>MAX_OBSTACLES:
		return _fail("invalid_boundary_infill_input")
	# AABBs are values. Freeze membership before invoking an external callback.
	var source := obstacles.duplicate()
	if not _continue(continuation): return _fail("cancelled")
	for value: Variant in source:
		if not value is AABB or not _valid_box(value): return _fail("invalid_boundary_infill_obstacle")
		if not _continue(continuation): return _fail("cancelled")
	var x_min := float(allowed.position.x)
	var z_min := float(allowed.position.y)
	var x_max := minf(float(allowed.end.x),x_min+float(allowed.size.x))-float(moving.size.x)
	var z_max := minf(float(allowed.end.y),z_min+float(allowed.size.y))-float(moving.size.z)
	if x_min>x_max or z_min>z_max: return _fail("moving_bounds_exceed_domain")
	var fixed_x := clampf(float(moving.position.x),x_min,x_max)
	var x_translation := float(Vector3(fixed_x-float(moving.position.x),0,0).x)
	var fixed_position := moving.position+Vector3(x_translation,0,0)
	var fixed := AABB(fixed_position,moving.size)
	for attempt in range(MAX_ENDPOINT_STEPS):
		if float(fixed.position.x)>=x_min and _upper(fixed,0)<=x_max+float(moving.size.x): break
		if not _continue(continuation): return _fail("cancelled")
		var direction := 1.0 if float(fixed.position.x)<x_min else -1.0
		x_translation=_next_translation(float(moving.position.x),float(fixed.position.x),x_translation,direction)
		fixed=AABB(moving.position+Vector3(x_translation,0,0),moving.size)
	if float(fixed.position.x)<x_min or _upper(fixed,0)>x_max+float(moving.size.x):
		return _fail("unrepresentable_fixed_x")
	var intervals: Array[Dictionary] = []
	for obstacle: AABB in source:
		if not _continue(continuation): return _fail("cancelled")
		if not _axis_overlap(fixed,obstacle,0,clearance) or not _axis_overlap(fixed,obstacle,1,0.0): continue
		intervals.append({"low":float(obstacle.position.z)-clearance,"high":_upper(obstacle,2)+clearance})
	intervals.sort_custom(func(a: Dictionary,b: Dictionary)->bool:
		return a.low<b.low if a.low!=b.low else a.high<b.high)
	if not _continue(continuation): return _fail("cancelled")
	var merged: Array[Dictionary] = []
	for interval: Dictionary in intervals:
		if not _continue(continuation): return _fail("cancelled")
		if merged.is_empty() or interval.low>merged[-1].high:
			merged.append(interval.duplicate())
		else:
			merged[-1].high=maxf(merged[-1].high,interval.high)
	# Nearest original Z (zero translation), domain ends, and every forbidden
	# interval end. A positive-width moving box shifts each low end by its depth.
	# The direction belongs to the endpoint's feasible side. Rounding a lower
	# obstacle endpoint upward must not discard the adjacent legal float32 pose.
	var raw_candidates: Array[Dictionary] = [{"z":float(moving.position.z),"direction":0.0},
		{"z":z_min,"direction":1.0},{"z":z_max,"direction":-1.0}]
	for interval: Dictionary in merged:
		raw_candidates.append({"z":interval.low-float(moving.size.z),"direction":-1.0})
		raw_candidates.append({"z":interval.high,"direction":1.0})
	var seen := {}
	var candidates: Array[Dictionary] = []
	for endpoint: Dictionary in raw_candidates:
		if not _continue(continuation): return _fail("cancelled")
		var candidate: float = endpoint.z
		if candidate<z_min or candidate>z_max: continue
		var translation := Vector3(x_translation,0,candidate-float(moving.position.z))
		var placed := AABB(moving.position+translation,moving.size)
		for attempt in range(MAX_ENDPOINT_STEPS):
			if endpoint.direction==0.0 or (_in_domain(placed,allowed) and not _hits_union(placed,merged)): break
			if not _continue(continuation): return _fail("cancelled")
			translation.z=_next_translation(float(moving.position.z),float(placed.position.z),float(translation.z),endpoint.direction)
			placed=AABB(moving.position+translation,moving.size)
		if seen.has(placed.position.z): continue
		seen[placed.position.z]=true
		candidates.append({"translation":translation,"bounds":placed,"distance":absf(float(placed.position.z)-float(moving.position.z))})
	candidates.sort_custom(func(a: Dictionary,b: Dictionary)->bool:
		return a.distance<b.distance if a.distance!=b.distance else a.bounds.position.z<b.bounds.position.z)
	var tested := 0
	for candidate: Dictionary in candidates:
		if not _continue(continuation): return _fail("cancelled",tested)
		tested+=1
		var placed: AABB = candidate.bounds
		if not _in_domain(placed,allowed) or _hits_union(placed,merged): continue
		# Independent final scan is performed only for the selected candidate:
		# O(n log n) union/candidates + O(n) final proof, not n*candidates scans.
		for obstacle: AABB in source:
			if not _continue(continuation): return _fail("cancelled",tested)
			if _axis_overlap(placed,obstacle,0,clearance) and _axis_overlap(placed,obstacle,1,0.0) and _axis_overlap(placed,obstacle,2,clearance):
				return _fail("represented_placement_blocked",tested)
		if not _continue(continuation): return _fail("cancelled",tested)
		return {"ready":true,"translation":candidate.translation,"placedBounds":placed,"testedCandidates":tested}
	return _fail("no_clear_fixed_x_placement",tested)

static func _next_translation(origin: float,position: float,translation: float,direction: float) -> float:
	var next_position := direction*ConstructionMath.next_float32_up(direction*position)
	var next_translation := float(Vector3(next_position-origin,0,0).x)
	var reconstructed := float(Vector3(origin+next_translation,0,0).x)
	# At large origins, one position ULP can disappear when encoded as a delta.
	# Advance the stored translation itself by one ULP to reach the next pose.
	if direction*(reconstructed-position)<=0.0:
		next_translation=direction*ConstructionMath.next_float32_up(direction*translation)
	return next_translation

static func _hits_union(box: AABB, intervals: Array[Dictionary]) -> bool:
	var low := 0
	var high := intervals.size()
	while low<high:
		var middle: int = (low+high)/2
		if intervals[middle].high<=float(box.position.z): low=middle+1
		else: high=middle
	return low<intervals.size() and intervals[low].low<_upper(box,2)

static func _upper(box: AABB, axis: int) -> float:
	# Conservatively cover scalar and native AABB end reconstruction.
	return maxf(float(box.end[axis]),float(box.position[axis])+float(box.size[axis]))

static func _axis_overlap(a: AABB,b: AABB,axis: int,expansion: float) -> bool:
	return float(a.position[axis])<_upper(b,axis)+expansion and _upper(a,axis)>float(b.position[axis])-expansion

static func _in_domain(box: AABB,allowed: Rect2) -> bool:
	return float(box.position.x)>=float(allowed.position.x) and float(box.position.z)>=float(allowed.position.y) \
		and _upper(box,0)<=minf(float(allowed.end.x),float(allowed.position.x)+float(allowed.size.x)) \
		and _upper(box,2)<=minf(float(allowed.end.y),float(allowed.position.y)+float(allowed.size.y))

static func _valid_box(box: AABB) -> bool:
	if not box.position.is_finite() or not box.size.is_finite() or not box.end.is_finite(): return false
	for axis in range(3):
		if box.size[axis]<=0.0 or box.size[axis]>LIMIT or absf(box.position[axis])>LIMIT or absf(_upper(box,axis))>LIMIT: return false
	return true

static func _valid_rect(rect: Rect2) -> bool:
	if not rect.position.is_finite() or not rect.size.is_finite() or not rect.end.is_finite(): return false
	for axis in range(2):
		if rect.size[axis]<=0.0 or rect.size[axis]>LIMIT or absf(rect.position[axis])>LIMIT or absf(float(rect.position[axis])+float(rect.size[axis]))>LIMIT or absf(rect.end[axis])>LIMIT: return false
	return true

static func _continue(continuation: Callable) -> bool:
	return not continuation.is_valid() or continuation.call()==true

static func _fail(reason: String,tested := 0) -> Dictionary:
	return {"ready":false,"reason":reason,"testedCandidates":tested}
