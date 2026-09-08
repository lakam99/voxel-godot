extends RefCounted
## Construct stored panel intervals inside the requested faces. Both scalar
## box faces and float32 AABB reconstruction must remain inside; no tolerance.
const Math = preload("res://scripts/buildings/ConstructionSeamMath.gd")

static func interval(low: float, high: float) -> Dictionary:
	if not is_finite(low) or not is_finite(high) or high - low < 0.02:
		return {"ready": false, "reason": "invalid_partition_interval"}
	var stored := Vector2((low + high) * 0.5, high - low)
	for attempt in range(16):
		var bounds := Rect2(Vector2(stored.x - stored.y * 0.5, 0), Vector2(stored.y, 1))
		var corners := Vector2(stored.x - stored.y * 0.5, stored.x + stored.y * 0.5)
		var transformed := Rect2(Vector2(corners.x, 0), Vector2(corners.y - corners.x, 1))
		if stored.y >= 0.02 and float(stored.x) - float(stored.y) * 0.5 >= low and float(stored.x) + float(stored.y) * 0.5 <= high and bounds.position.x >= low and bounds.end.x <= high and transformed.position.x >= low and transformed.end.x <= high:
			return {"ready": true, "center": float(stored.x), "size": float(stored.y)}
		# Keep the center and reduce only the represented extent. The requested
		# interval is authority; a rounded midpoint must not expand its faces.
		var limit := 2.0 * minf(float(stored.x) - low, high - float(stored.x))
		var reconstruction_excess := maxf(0.0, maxf(low - float(bounds.position.x), float(bounds.end.x) - high))
		reconstruction_excess = maxf(reconstruction_excess, maxf(low - float(transformed.position.x), float(transformed.end.x) - high))
		stored.y = minf(stored.y - 2.0 * reconstruction_excess, limit)
		stored.y = -Math.next_float32_up(-float(stored.y))
	return {"ready": false, "reason": "unrepresentable_partition_interval"}
