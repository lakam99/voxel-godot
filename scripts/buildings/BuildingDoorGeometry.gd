extends RefCounted

const DEFAULT_OPEN_SWING := -PI * 0.5

## Closed ordinary door visual geometry. Pure value descriptions, shared by
## the existing publisher and construction-clearance queries. Door motion,
## collision, interaction and material evaluation remain with their owners.
## Expression order matches the original publish_door_boards implementation.
static func describe(size: Vector3) -> Dictionary:
	var boards: Array = []
	for index in range(5):
		var width := size.x / float(5)
		boards.append(_piece(Vector3(maxf(0.04, width - 0.018), size.y, size.z), Vector3(-size.x * 0.5 + width * (float(index) + 0.5), 0.0, 0.0)))
	return {
		"pivotPosition": Vector3(-size.x * 0.5, 0.0, 0.0),
		"leafPosition": Vector3(size.x * 0.5, 0.0, 0.0), "boards": boards,
		"brace": _piece(Vector3(size.x * 0.86, 0.10, size.z * 1.22), Vector3(0.0, -size.y * 0.10, size.z * 0.40)),
		"frameLeft": _piece(Vector3(0.14, size.y * 1.12, size.z * 1.55), Vector3(-size.x * 0.58, 0.0, 0.0)),
		"frameRight": _piece(Vector3(0.14, size.y * 1.12, size.z * 1.55), Vector3(size.x * 0.58, 0.0, 0.0)),
		"frameTop": _piece(Vector3(size.x * 1.28, 0.14, size.z * 1.55), Vector3(0.0, size.y * 0.56, 0.0)),
		"handle": _piece(Vector3(0.105, 0.105, 0.090), Vector3(size.x * 0.27, -0.04, -size.z * 0.70))}

static func _piece(size: Vector3, position: Vector3) -> Dictionary:
	return {"size": size, "position": position}

## Exact existing grille/lever recipe, shared by publication and construction.
static func describe_portcullis(size: Vector3) -> Dictionary:
	var bar_count := maxi(4, ceili(size.x / 0.30))
	var bar_width := minf(0.12, size.x / float(bar_count) * 0.48)
	var bars: Array = []
	for index in range(bar_count):
		var x := -size.x * 0.5 + size.x * (float(index) + 0.5) / float(bar_count)
		bars.append(_piece(Vector3(bar_width, size.y, maxf(0.12, size.z * 1.35)), Vector3(x, 0.0, 0.0)))
	var crossbars: Array = []
	for ratio in [-0.30, 0.20]:
		crossbars.append(_piece(Vector3(size.x, 0.12, maxf(0.14, size.z * 1.45)), Vector3(0.0, size.y * ratio, 0.0)))
	return {"bars": bars, "crossbars": crossbars,
		"leverPosition": Vector3(size.x * 0.5 + 0.42, -size.y * 0.24, -maxf(0.44, size.z * 2.60)),
		"leverRotation": Vector3(0.0, 0.0, -0.52),
		"mount": _piece(Vector3(0.34, 0.46, 0.12), Vector3.ZERO),
		"arm": _piece(Vector3(0.10, 0.58, 0.10), Vector3(0.0, 0.24, -0.09)),
		"handle": _piece(Vector3(0.19, 0.19, 0.19), Vector3(0.0, 0.52, -0.09))}

static func raised_visual_offset(size: Vector3) -> Vector3:
	return Vector3(0.0, size.y + 0.18, 0.0)

static func portcullis_closed_primitives(size: Vector3, world_transform: Transform3D) -> Array:
	var description := describe_portcullis(size)
	var primitives: Array = []
	for key in ["bars", "crossbars"]:
		for index in range(description[key].size()):
			var piece := _placed(key + "_%d" % index, description[key][index], world_transform)
			piece["moving"] = true
			primitives.append(piece)
	var lever := world_transform * Transform3D(Basis.IDENTITY, description.leverPosition)
	var arm := lever * Transform3D(Basis.from_euler(description.leverRotation), Vector3.ZERO)
	for key in ["mount", "arm", "handle"]:
		var piece := _placed(key, description[key], lever if key == "mount" else arm)
		piece["moving"] = false
		primitives.append(piece)
	return primitives

## Conservative full translated sweep; stationary lever pieces do not rise.
## The existing door controller consumes the same published raise offset.
static func portcullis_sweep_bounds(size: Vector3, world_transform: Transform3D) -> Array:
	var bounds: Array = []
	var offset := world_transform.basis * raised_visual_offset(size)
	for piece: Dictionary in portcullis_closed_primitives(size, world_transform):
		var pose: Transform3D = piece.transform * Transform3D(Basis.from_scale(piece.size), Vector3.ZERO)
		bounds.append(_translated_box_envelope(pose, offset if piece.moving else Vector3.ZERO))
	return bounds

static func _translated_box_envelope(pose: Transform3D, offset: Vector3) -> AABB:
	# Transform the same unit-box corners as publication, including size in the
	# basis. Endpoint extrema enclose the full linear translation. Round OUTWARD
	# by adjacent native floats so storing min+size cannot shave off a corner.
	var low := Vector3(INF, INF, INF)
	var high := Vector3(-INF, -INF, -INF)
	for amount in [0.0, 1.0]:
		var at := pose
		at.origin += offset * amount
		for corner in range(8):
			var point: Vector3 = at * AABB(Vector3.ONE * -0.5, Vector3.ONE).get_endpoint(corner)
			low = low.min(point)
			high = high.max(point)
	if not low.is_finite() or not high.is_finite(): return AABB()
	for axis in range(3):
		low[axis] = _adjacent_float32(low[axis], false)
		high[axis] = _adjacent_float32(high[axis], true)
	var extent := high - low
	for axis in range(3):
		for correction in range(4):
			if (low + extent)[axis] >= high[axis]: break
			extent[axis] = _adjacent_float32(extent[axis], true)
		if (low + extent)[axis] < high[axis]: return AABB()
	return AABB(low, extent)

static func _adjacent_float32(value: float, upward: bool) -> float:
	var bytes := PackedFloat32Array([value]).to_byte_array()
	var bits := bytes.decode_u32(0)
	if value == 0.0: bits = 1 if upward else 0x80000001
	else: bits += 1 if (value > 0.0) == upward else -1
	bytes.encode_u32(0, bits)
	return bytes.decode_float(0)

static func closed_primitives(size: Vector3, world_transform: Transform3D) -> Array:
	var description := describe(size)
	var pivot := Transform3D(Basis.IDENTITY, description.pivotPosition)
	var leaf: Transform3D = pivot * Transform3D(Basis.IDENTITY, description.leafPosition)
	var primitives: Array = []
	for index in range(description.boards.size()):
		primitives.append(_placed("DoorBoard_%d" % index, description.boards[index], world_transform * leaf))
	for key in ["brace", "frameLeft", "frameRight", "frameTop", "handle"]:
		primitives.append(_placed(key, description[key], world_transform * leaf if key in ["brace", "handle"] else world_transform))
	return primitives

## Exact production ordinary-door motion ownership. Moving leaf pieces rotate
## from closed to the publisher-bound +90 degree default; frame pieces stay put.
## Each returned AABB is rounded OUTWARD and owns one published primitive.
static func ordinary_sweep_bounds(size: Vector3, world_transform: Transform3D, open_swing: float = DEFAULT_OPEN_SWING) -> Array:
	if not size.is_finite() or size.x < 0.02 or size.y < 0.02 or size.z < 0.02 or not world_transform.is_finite() or not is_finite(open_swing) or absf(open_swing) > PI: return []
	var description := describe(size)
	var low_angle := minf(0.0, open_swing)
	var high_angle := maxf(0.0, open_swing)
	var result: Array = []
	for index in range(description.boards.size()):
		result.append({"name": "DoorBoard_%d" % index, "moving": true,
			"bounds": _ordinary_rotated_piece_envelope(description.boards[index], description.leafPosition, description.pivotPosition, world_transform, low_angle, high_angle)})
	for key in ["brace", "handle"]:
		result.append({"name": key, "moving": true,
			"bounds": _ordinary_rotated_piece_envelope(description[key], description.leafPosition, description.pivotPosition, world_transform, low_angle, high_angle)})
	for key in ["frameLeft", "frameRight", "frameTop"]:
		var piece: Dictionary = description[key]
		var pose := world_transform * Transform3D(Basis.IDENTITY, piece.position) * Transform3D(Basis.from_scale(piece.size), Vector3.ZERO)
		result.append({"name": key, "moving": false, "bounds": _translated_box_envelope(pose, Vector3.ZERO)})
	if result.any(func(row): return not row.bounds is AABB or row.bounds.size.x <= 0.0 or row.bounds.size.y <= 0.0 or row.bounds.size.z <= 0.0): return []
	return result

static func _ordinary_rotated_piece_envelope(piece: Dictionary, leaf_position: Vector3, pivot_position: Vector3, world: Transform3D, low_angle: float, high_angle: float) -> AABB:
	var low := Vector3(INF, INF, INF)
	var high := Vector3(-INF, -INF, -INF)
	for corner in range(8):
		var point: Vector3 = leaf_position + piece.position + AABB(-piece.size * 0.5, piece.size).get_endpoint(corner)
		for axis in range(3):
			var fixed: float = world.origin[axis] + (world.basis * (pivot_position + Vector3(0.0, point.y, 0.0)))[axis]
			var cosine: float = world.basis.x[axis] * point.x + world.basis.z[axis] * point.z
			var sine: float = world.basis.x[axis] * point.z - world.basis.z[axis] * point.x
			var angles: Array = [low_angle, high_angle]
			var maximum := atan2(sine, cosine)
			for base in [maximum, maximum + PI]:
				for turn in range(-2, 3):
					var candidate: float = base + float(turn) * TAU
					if candidate >= low_angle and candidate <= high_angle: angles.append(candidate)
			for angle: float in angles:
				var value: float = fixed + cosine * cos(angle) + sine * sin(angle)
				low[axis] = minf(low[axis], value)
				high[axis] = maxf(high[axis], value)
	return _outward_aabb(low, high)

static func _outward_aabb(low: Vector3, high: Vector3) -> AABB:
	if not low.is_finite() or not high.is_finite(): return AABB()
	for axis in range(3):
		# Analytic scalar trig and native Basis construction can differ by a few
		# representable steps. Expand only outward; never shrink a reservation.
		for representation_step in range(8):
			low[axis] = _adjacent_float32(low[axis], false)
			high[axis] = _adjacent_float32(high[axis], true)
	var extent := high - low
	for axis in range(3):
		for correction in range(4):
			if (low + extent)[axis] >= high[axis]: break
			extent[axis] = _adjacent_float32(extent[axis], true)
		if (low + extent)[axis] < high[axis]: return AABB()
	return AABB(low, extent)

static func _placed(name: String, piece: Dictionary, parent: Transform3D) -> Dictionary:
	var pose := parent * Transform3D(Basis.IDENTITY, piece.position)
	return {"name": name, "transform": pose, "size": piece.size,
		"bounds": pose * AABB(-piece.size * 0.5, piece.size)}
