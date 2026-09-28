extends RefCounted
## Construct stored panel intervals inside the requested faces. Both scalar
## box faces and float32 AABB reconstruction must remain inside; no tolerance.
const Math = preload("res://scripts/buildings/ConstructionSeamMath.gd")
const MIN_PARTITION_SIZE := 0.02
const MAX_CENTER_ULP_OFFSETS := 8

static func interval(low: float, high: float) -> Dictionary:
	if not is_finite(low) or not is_finite(high) or high - low < MIN_PARTITION_SIZE:
		return {"ready": false, "reason": "invalid_partition_interval"}
	var requested_center := (low + high) * 0.5
	var best_center := INF
	var best_size := -INF
	var best_distance := INF
	# The source interval is double precision but BuildingPart storage is
	# float32. For every nearby representable midpoint, find the greatest
	# representable extent that passes the *actual* scalar and Rect2 face tests.
	# This is a monotone bit-range search, not a retry limit or seam tolerance.
	for center_step in range(-MAX_CENTER_ULP_OFFSETS, MAX_CENTER_ULP_OFFSETS + 1):
		var center := requested_center
		for ignored in range(abs(center_step)):
			center = Math.next_float32_up(center) if center_step > 0 else -Math.next_float32_up(-center)
		var stored_center := float(Vector2(center, 0.0).x)
		var candidate_size := _largest_fitting_size(stored_center, high - low, low, high)
		if candidate_size < MIN_PARTITION_SIZE:
			continue
		var distance := absf(stored_center - requested_center)
		if candidate_size > best_size or (candidate_size == best_size and (distance < best_distance \
				or (is_equal_approx(distance, best_distance) and stored_center < best_center))):
			best_center = stored_center
			best_size = candidate_size
			best_distance = distance
	if best_center < INF:
		return {"ready": true, "center": best_center, "size": best_size}
	return {"ready": false, "reason": "unrepresentable_partition_interval"}


static func _largest_fitting_size(center: float, maximum_size: float, low: float, high: float) -> float:
	var minimum_bits := _float32_bits(MIN_PARTITION_SIZE)
	var maximum_bits := _float32_bits(float(Vector2(0.0, maximum_size).y))
	var best_size := -INF
	while minimum_bits <= maximum_bits:
		var midpoint_bits := minimum_bits + (maximum_bits - minimum_bits) / 2
		var candidate_size := _float32_from_bits(midpoint_bits)
		if _fits_source_faces(Vector2(center, candidate_size), low, high):
			best_size = candidate_size
			minimum_bits = midpoint_bits + 1
		else:
			maximum_bits = midpoint_bits - 1
	return best_size


static func _float32_bits(value: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	return int(bytes.decode_u32(0))


static func _float32_from_bits(bits: int) -> float:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, bits)
	return bytes.decode_float(0)


static func _fits_source_faces(stored: Vector2, low: float, high: float) -> bool:
	if stored.y < MIN_PARTITION_SIZE:
		return false
	var scalar_low := float(stored.x) - float(stored.y) * 0.5
	var scalar_high := float(stored.x) + float(stored.y) * 0.5
	var bounds := Rect2(Vector2(scalar_low, 0), Vector2(stored.y, 1))
	var corners := Vector2(scalar_low, scalar_high)
	var transformed := Rect2(Vector2(corners.x, 0), Vector2(corners.y - corners.x, 1))
	return scalar_low >= low and scalar_high <= high and bounds.position.x >= low and bounds.end.x <= high \
		and transformed.position.x >= low and transformed.end.x <= high
