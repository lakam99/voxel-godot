extends RefCounted
class_name BuildingNavigationTransitionCertifier


static func certify_endpoint(support: Dictionary, authored_position: Vector3, transition_axis: Vector3, lateral_clearance: float, blocker: Callable) -> Dictionary:
	if support.is_empty() or not authored_position.is_finite():
		return {"resolved": false, "reason": "missing_support_or_position"}
	var axis := transition_axis
	axis.y = 0.0
	if axis.length_squared() <= 0.0001:
		return {"resolved": false, "reason": "missing_transition_axis"}
	axis = axis.normalized()
	var lateral := Vector3(-axis.z, 0.0, axis.x)
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return {"resolved": false, "reason": "support_polygon_missing"}
	var lateral_min := INF
	var lateral_max := -INF
	for point_value in polygon:
		if not (point_value is Vector3):
			return {"resolved": false, "reason": "support_polygon_malformed"}
		var lateral_value := lateral.dot(point_value as Vector3)
		lateral_min = minf(lateral_min, lateral_value)
		lateral_max = maxf(lateral_max, lateral_value)
	var authored_lateral := lateral.dot(authored_position)
	if authored_lateral - lateral_clearance < lateral_min or authored_lateral + lateral_clearance > lateral_max:
		return {"resolved": false, "reason": "insufficient_lateral_clearance", "lateralMinimum": lateral_min, "lateralMaximum": lateral_max, "authoredLateral": authored_lateral}
	var candidate := authored_position
	candidate.y = _support_surface_y(support, candidate)
	if not _point_within_support_xz(candidate, polygon):
		return {"resolved": false, "reason": "endpoint_outside_declared_support"}
	var collision_blocker: Dictionary = blocker.call(candidate) as Dictionary if blocker.is_valid() else {}
	if not collision_blocker.is_empty():
		return {"resolved": false, "reason": "endpoint_collision_blocked", "blocker": collision_blocker, "position": candidate}
	return {"resolved": true, "position": candidate, "supportId": String(support.get("id", "")), "lateralClearance": minf(authored_lateral - lateral_min, lateral_max - authored_lateral)}


static func _support_surface_y(support: Dictionary, position: Vector3) -> float:
	var origin: Vector3 = support.get("worldPosition", Vector3.ZERO) as Vector3
	var normal: Vector3 = support.get("floorNormal", Vector3.UP) as Vector3
	if absf(normal.y) <= 0.0001:
		return origin.y
	return origin.y - (normal.x * (position.x - origin.x) + normal.z * (position.z - origin.z)) / normal.y


static func _point_within_support_xz(position: Vector3, polygon: Array) -> bool:
	var inside := false
	var previous: Vector3 = polygon[polygon.size() - 1] as Vector3
	for point_value in polygon:
		var point: Vector3 = point_value as Vector3
		var crosses := (point.z > position.z) != (previous.z > position.z)
		if crosses:
			var denominator := previous.z - point.z
			if absf(denominator) > 0.000001:
				var x_at_z := (previous.x - point.x) * (position.z - point.z) / denominator + point.x
				if position.x < x_at_z:
					inside = not inside
		previous = point
	return inside
