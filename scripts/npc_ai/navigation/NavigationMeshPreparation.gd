extends RefCounted
class_name NavigationMeshPreparation

## Value-only preparation shared by every navigation installation. No Nodes,
## NavigationMesh resources, RIDs, server calls or route decisions live here.
const CELL := preload("res://scripts/npc_ai/NpcConstants.gd").CELL_SIZE
var _continuation: Callable

func compile(surfaces: Array, continuation: Callable = Callable()) -> Dictionary:
	_continuation = continuation
	var started := Time.get_ticks_usec()
	if not _continue("navigation_geometry_started"): return {}
	var sorted := surfaces.duplicate()
	sorted.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	var ownership := {}
	var vertices := PackedVector3Array()
	var vertex_indices := {}
	var polygons: Array[PackedInt32Array] = []
	for points in _navigation_mesh_polygons_for_surfaces(sorted, ownership):
		if not _continue("navigation_polygon_buffer"): return {}
		if points.size() < 3: continue
		var indices := PackedInt32Array()
		for point: Vector3 in points:
			var key := _navigation_mesh_vertex_key(point)
			if not vertex_indices.has(key):
				vertex_indices[key] = vertices.size()
				vertices.append(point)
			indices.append(int(vertex_indices[key]))
		polygons.append(indices)
	if not _continue("navigation_geometry_ready"): return {}
	ownership.make_read_only()
	polygons.make_read_only()
	var packet := {"vertices":vertices,"polygons":polygons,"surfacePolygons":ownership,
		"preparationUsec":Time.get_ticks_usec()-started,"threadId":OS.get_thread_caller_id()}
	packet.make_read_only()
	return packet

func _continue(stage: String) -> bool:
	return not _continuation.is_valid() or _continuation.call(stage)==true

static func _record_surface_polygon(ownership: Dictionary, surface_id: String, polygon_index: int) -> void:
	if surface_id.is_empty(): return
	# Duplicate source IDs are ambiguous even if they happen to share a polygon.
	ownership[surface_id] = -1 if ownership.has(surface_id) else polygon_index

func _navigation_mesh_vertex_key(point: Vector3) -> String:
	return "%d:%d:%d" % [
		roundi(point.x * 1000.0),
		roundi(point.y * 1000.0),
		roundi(point.z * 1000.0)
	]

func _navigation_mesh_polygons_for_surfaces(sorted_surfaces: Array, surface_polygons: Dictionary = {}) -> Array:
	var result := []
	var layers := {}
	var source_rectangles := {}
	var work_count := 0
	for surface_value in sorted_surfaces:
		work_count += 1
		if work_count % 256 == 0 and not _continue("navigation_surface_groups"): return []
		if not (surface_value is Dictionary):
			continue
		var surface: Dictionary = surface_value
		if not bool(surface.get("walkable", true)):
			continue
		if not _surface_mergeable_for_mesh(surface):
			var polygon := _surface_polygon(surface)
			var rectangle := _source_rectangle(surface,polygon)
			if not rectangle.is_empty():
				var owner := String(surface.get("geometryGroupId",surface.supportId))
				if not source_rectangles.has(owner): source_rectangles[owner]=[]
				source_rectangles[owner].append(rectangle)
				continue
			if polygon.size() >= 3:
				_record_surface_polygon(surface_polygons, String(surface.get("id", "")), result.size())
				result.append(polygon)
			continue
		var cell: Vector3i = surface.get("cell")
		var center: Vector3 = surface.get("center", Vector3(float(cell.x) * CELL, float(cell.y) * CELL, float(cell.z) * CELL))
		var layer_key := "%d:%d" % [cell.y, roundi(center.y * 100.0)]
		if not layers.has(layer_key):
			layers[layer_key] = {
				"cells": {},
				"owners": {},
				"y": center.y
			}
		var layer: Dictionary = layers[layer_key]
		var grid: Dictionary = layer.get("cells", {})
		grid[Vector2i(cell.x, cell.z)] = true
		var owners: Dictionary = layer.owners
		var cell_key := Vector2i(cell.x, cell.z)
		if not owners.has(cell_key): owners[cell_key] = []
		owners[cell_key].append(String(surface.get("id", "")))
	for owner: String in source_rectangles:
		# These are exact unions of touching rectangles from one source owner.
		# Removing internal sampling edges changes neither coverage nor ownership.
		var rectangles := _merge_source_rectangles(source_rectangles[owner],0)
		rectangles = _merge_source_rectangles(rectangles,1)
		for rectangle: Dictionary in rectangles:
			work_count += 1
			if work_count % 256 == 0 and not _continue("navigation_rectangle_output"): return []
			for id: String in rectangle.owners: _record_surface_polygon(surface_polygons,id,result.size())
			result.append(rectangle.points)
	for layer_key in layers.keys():
		var layer: Dictionary = layers[layer_key]
		var grid: Dictionary = layer.get("cells", {})
		result.append_array(_merged_grid_polygons(grid, float(layer.get("y", 0.0)), layer.owners, surface_polygons, result.size()))
	return result

func _source_rectangle(surface: Dictionary, polygon: Array) -> Dictionary:
	if String(surface.get("supportId","")).is_empty() or polygon.size()!=4: return {}
	var low := Vector2(polygon[0].x,polygon[0].z)
	var high := low
	var corners := {}
	for point: Vector3 in polygon:
		var xz := Vector2(point.x,point.z)
		low=low.min(xz); high=high.max(xz)
		corners[xz]=point
	if corners.size()!=4 or low.x>=high.x or low.y>=high.y: return {}
	var points: Array = []
	for corner in [low,Vector2(low.x,high.y),high,Vector2(high.x,low.y)]:
		if not corners.has(corner): return {}
		points.append(corners[corner])
	for index in range(polygon.size()):
		var first: Vector3 = polygon[index]
		var next: Vector3 = polygon[(index+1)%polygon.size()]
		if first.x!=next.x and first.z!=next.z: return {}
	# Flat rectangles and single-axis grades can merge along their level axis
	# without changing any height or removing a change of slope.
	if not (points[0].y==points[3].y and points[1].y==points[2].y) \
			and not (points[0].y==points[1].y and points[3].y==points[2].y): return {}
	return {"low":low,"high":high,"y":points[0].y,"points":points,"owners":[String(surface.get("id",""))]}

func _merge_source_rectangles(rectangles: Array, axis: int) -> Array:
	var other := 1-axis
	rectangles.sort_custom(func(a: Dictionary,b: Dictionary):
		if a.y!=b.y: return a.y<b.y
		if a.low[other]!=b.low[other]: return a.low[other]<b.low[other]
		if a.high[other]!=b.high[other]: return a.high[other]<b.high[other]
		return a.low[axis]<b.low[axis])
	var result: Array = []
	var work_count := 0
	for rectangle: Dictionary in rectangles:
		work_count += 1
		if work_count % 256 == 0 and not _continue("navigation_rectangle_merge"): return []
		if not result.is_empty():
			var previous: Dictionary = result[-1]
			if previous.y==rectangle.y and previous.low[other]==rectangle.low[other] \
					and previous.high[other]==rectangle.high[other] and previous.high[axis]==rectangle.low[axis] \
					and _rectangles_share_level_axis(previous.points,rectangle.points,axis):
				previous.high[axis]=rectangle.high[axis]
				previous.points[2]=rectangle.points[2]
				previous.points[3 if axis==0 else 1]=rectangle.points[3 if axis==0 else 1]
				previous.owners.append_array(rectangle.owners)
				continue
		result.append(rectangle)
	return result

func _rectangles_share_level_axis(first: Array, second: Array, axis: int) -> bool:
	var end := 3 if axis==0 else 1
	var across := 1 if axis==0 else 3
	return first[0].y==first[end].y and first[across].y==first[2].y \
		and second[0].y==second[end].y and second[across].y==second[2].y \
		and first[0].y==second[0].y and first[across].y==second[across].y

func _surface_mergeable_for_mesh(surface: Dictionary) -> bool:
	if surface.has("polygon"):
		var polygon_value = surface.get("polygon", [])
		if polygon_value is Array and polygon_value.size() >= 3:
			return false
	var cell_value = surface.get("cell")
	if not (cell_value is Vector3i):
		return false
	var size: Vector3 = surface.get("size", Vector3(CELL, 0.05, CELL))
	return absf(size.x - CELL) <= CELL * 0.05 and absf(size.z - CELL) <= CELL * 0.05

func _merged_grid_polygons(grid: Dictionary, y: float, owners: Dictionary = {}, surface_polygons: Dictionary = {}, polygon_offset := 0) -> Array:
	var result := []
	var keys: Array = grid.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y == b.y:
			return a.x < b.x
		return a.y < b.y
	)
	var visited := {}
	for key_value in keys:
		if not (key_value is Vector2i):
			continue
		var start: Vector2i = key_value
		if visited.has(start):
			continue
		var end_x := start.x
		while grid.has(Vector2i(end_x + 1, start.y)) and not visited.has(Vector2i(end_x + 1, start.y)):
			end_x += 1
		var end_z := start.y
		var can_extend := true
		while can_extend:
			var next_z := end_z + 1
			for x in range(start.x, end_x + 1):
				if not grid.has(Vector2i(x, next_z)) or visited.has(Vector2i(x, next_z)):
					can_extend = false
					break
			if can_extend:
				end_z = next_z
		for z in range(start.y, end_z + 1):
			for x in range(start.x, end_x + 1):
				visited[Vector2i(x, z)] = true
				for surface_id in owners.get(Vector2i(x, z), []):
					_record_surface_polygon(surface_polygons, String(surface_id), polygon_offset + result.size())
		var min_x := float(start.x) * CELL - CELL * 0.5
		var max_x := float(end_x) * CELL + CELL * 0.5
		var min_z := float(start.y) * CELL - CELL * 0.5
		var max_z := float(end_z) * CELL + CELL * 0.5
		result.append([
			Vector3(min_x, y, min_z),
			Vector3(min_x, y, max_z),
			Vector3(max_x, y, max_z),
			Vector3(max_x, y, min_z)
		])
	return result

func _surface_polygon(surface: Dictionary) -> Array[Vector3]:
	var polygon_value = surface.get("polygon", [])
	if polygon_value is Array and polygon_value.size() >= 3:
		var polygon: Array[Vector3] = []
		for point in polygon_value:
			if point is Vector3:
				polygon.append(point)
		if polygon.size() >= 3:
			return polygon
	var center: Vector3 = surface.get("center", Vector3.ZERO)
	var size: Vector3 = surface.get("size", Vector3.ONE)
	var half_x := maxf(size.x, 0.01) * 0.5
	var half_z := maxf(size.z, 0.01) * 0.5
	return [
		Vector3(center.x - half_x, center.y, center.z - half_z),
		Vector3(center.x - half_x, center.y, center.z + half_z),
		Vector3(center.x + half_x, center.y, center.z + half_z),
		Vector3(center.x + half_x, center.y, center.z - half_z)
	]

