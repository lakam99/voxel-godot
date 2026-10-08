extends RefCounted
class_name BuildingWindowVisualRecipe

## Shared local boxes for the published window and its section support.
static func boxes(size: Vector3) -> Array[Dictionary]:
	var rows: Array[Dictionary] = [{"name":"WindowGlass", "size":size,
		"offset":Vector3.ZERO, "trim":false}]
	if size.x < size.z:
		rows.append_array([
			{"name":"WindowFrameNear", "size":Vector3(size.x * 1.62, size.y * 1.18, 0.14), "offset":Vector3(0.0, 0.0, -size.z * 0.58), "trim":true},
			{"name":"WindowFrameFar", "size":Vector3(size.x * 1.62, size.y * 1.18, 0.14), "offset":Vector3(0.0, 0.0, size.z * 0.58), "trim":true},
			{"name":"WindowLintel", "size":Vector3(size.x * 1.62, 0.15, size.z * 1.30), "offset":Vector3(0.0, size.y * 0.59, 0.0), "trim":true},
			{"name":"WindowSill", "size":Vector3(size.x * 1.82, 0.17, size.z * 1.36), "offset":Vector3(0.0, -size.y * 0.59, 0.0), "trim":true},
			{"name":"WindowMullionHorizontal", "size":Vector3(size.x * 1.68, 0.075, size.z * 1.68), "offset":Vector3.ZERO, "trim":true},
			{"name":"WindowMullionVertical", "size":Vector3(size.x * 1.68, size.y * 1.05, 0.075), "offset":Vector3.ZERO, "trim":true}])
	else:
		rows.append_array([
			{"name":"WindowFrameNear", "size":Vector3(0.14, size.y * 1.18, size.z * 1.62), "offset":Vector3(-size.x * 0.58, 0.0, 0.0), "trim":true},
			{"name":"WindowFrameFar", "size":Vector3(0.14, size.y * 1.18, size.z * 1.62), "offset":Vector3(size.x * 0.58, 0.0, 0.0), "trim":true},
			{"name":"WindowLintel", "size":Vector3(size.x * 1.30, 0.15, size.z * 1.62), "offset":Vector3(0.0, size.y * 0.59, 0.0), "trim":true},
			{"name":"WindowSill", "size":Vector3(size.x * 1.36, 0.17, size.z * 1.82), "offset":Vector3(0.0, -size.y * 0.59, 0.0), "trim":true},
			{"name":"WindowMullionHorizontal", "size":Vector3(size.x * 1.68, 0.075, size.z * 1.68), "offset":Vector3.ZERO, "trim":true},
			{"name":"WindowMullionVertical", "size":Vector3(0.075, size.y * 1.05, size.z * 1.68), "offset":Vector3.ZERO, "trim":true}])
	return rows


static func visual_support_bounds(size: Vector3) -> AABB:
	var result := AABB()
	var first := true
	for row: Dictionary in boxes(size):
		var bounds := AABB(row.offset - row.size * 0.5, row.size)
		result = bounds if first else result.merge(bounds)
		first = false
	# Mesh and transform paths round independently at world-scale coordinates.
	return result.grow(0.001)
