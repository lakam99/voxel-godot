extends RefCounted
class_name ConvexFootingAperture

## Pure construction geometry, NOT a support/root/collision readiness authority.
## A source transform maps the centered unit box into world space (scale included).
## Entries preserve original descriptors; arbitrary extra fields are opaque.
## Native cells explicitly denote an intact box; polyhedra have real closed faces.
## Faces wind counterclockwise viewed from OUTSIDE (reverse for Godot front faces).
## Cut-plane caps also include internal partition faces between surviving cells:
## the geometry is their solid UNION, not a claim that every cap is exposed.
## Replay: supply original boxes and the union of old/new apertures. Never feed
## result cells back as original boxes or trust an externally supplied cut cache.
## Domain: positive-determinant affine box, axis lengths [1e-4,1e4], coordinates within 1e5;
## aperture extents >=1e-4. Smaller/ill-conditioned inputs fail, never disappear.

const HARD_LIMITS := {"maxSolids": 8192, "maxApertures": 16, "maxFragments": 32768,
	"maxFragmentsPerSolid": 256, "maxFacesPerCell": 128, "maxVerticesPerFace": 128,
	"maxWork": 4000000}
const MAX_COORD := 100000.0
const MIN_AXIS := 0.0001
const MAX_AXIS := 10000.0
# Arithmetic checks only: these do not grow cuts or classify penetration away.
const REL_VOLUME_ERROR := 0.0001
const LOCAL_ERROR := 0.00002


static func subtract_boxes(solids: Array, apertures: Array[AABB], limits: Dictionary = {}) -> Dictionary:
	var ctx: Dictionary = {"work": 0, "error": "", "limits": HARD_LIMITS.duplicate(), "fragments": 0}
	for key in limits:
		if not HARD_LIMITS.has(key) or not limits[key] is int or limits[key] < 1 or limits[key] > HARD_LIMITS[key]:
			return _fail("invalid_limits", ctx)
		ctx.limits[key] = limits[key]
	if solids.size() > ctx.limits.maxSolids: return _fail("solid_limit_exceeded", ctx)
	if apertures.size() > ctx.limits.maxApertures: return _fail("aperture_limit_exceeded", ctx)
	var cuts: Array[AABB] = []
	for cut in apertures:
		if not _spend(ctx, 1): return _fail(ctx.error, ctx)
		if not _valid_bounds(cut): return _fail("invalid_aperture", ctx)
		if not cuts.has(cut): cuts.append(cut)
	cuts.sort_custom(func(a: AABB, b: AABB): return _bounds_less(a, b))
	var ids: Dictionary = {}
	var validated: Array = []
	# Validate the ENTIRE input before building any candidate output.
	for value in solids:
		if not _spend(ctx, 8): return _fail(ctx.error, ctx)
		if not value is Dictionary: return _fail("invalid_solid", ctx)
		var source: Dictionary = value
		if not source.get("id") is String or String(source.id).is_empty() or ids.has(source.id): return _fail("invalid_or_duplicate_solid_id", ctx)
		if not source.get("materialKey") is String or not source.has("customData"): return _fail("invalid_material_or_custom_data", ctx)
		if source.customData != null and not source.customData is Color: return _fail("invalid_material_or_custom_data", ctx)
		if source.customData is Color:
			var color: Color = source.customData
			if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b) or not is_finite(color.a): return _fail("invalid_material_or_custom_data", ctx)
		if not source.get("transform") is Transform3D: return _fail("invalid_transform", ctx)
		var transform: Transform3D = source.transform
		if not _valid_transform(transform): return _fail("invalid_transform", ctx)
		var corners: PackedVector3Array = _corners(transform)
		var bounds: AABB = _point_bounds(corners, ctx)
		if not ctx.error.is_empty(): return _fail(ctx.error, ctx)
		if not _valid_bounds(bounds): return _fail("invalid_world_bounds", ctx)
		ids[source.id] = true
		validated.append({"source": source, "bounds": bounds, "volume": transform.basis.determinant()})
	var entries: Array = []
	var input_volume := 0.0
	var remaining_volume := 0.0
	var removed_volume := 0.0
	for item in validated:
		var source: Dictionary = item.source
		var transform: Transform3D = source.transform
		var source_volume: float = item.volume
		input_volume += source_volume
		var relevant: Array[AABB] = []
		for cut in cuts:
			if not _spend(ctx, 1): return _fail(ctx.error, ctx)
			if _strict_overlap(item.bounds, cut): relevant.append(cut)
		if relevant.is_empty():
			if not _add_fragments(ctx, 1): return _fail(ctx.error, ctx)
			entries.append(_native_entry(source, item.bounds, source_volume))
			remaining_volume += source_volume
			continue
		if ctx.limits.maxFacesPerCell < 6: return _fail("face_limit_exceeded", ctx)
		if ctx.limits.maxVerticesPerFace < 4: return _fail("face_vertex_limit_exceeded", ctx)
		var initial: Dictionary = _box_poly(transform)
		var pieces: Array = [initial]
		var changed := false
		var removed := 0.0
		for cut in relevant:
			var next: Array = []
			for piece in pieces:
				if not _spend(ctx, 1): return _fail(ctx.error, ctx)
				var piece_bounds: AABB = _poly_bounds(piece, ctx)
				if not ctx.error.is_empty(): return _fail(ctx.error, ctx)
				if not _strict_overlap(piece_bounds, cut):
					next.append(piece)
					continue
				var split: Dictionary = _subtract_one(piece, cut, ctx)
				if not ctx.error.is_empty(): return _fail(ctx.error, ctx)
				next.append_array(split.pieces)
				changed = changed or split.changed
				removed += float(split.removedVolume)
				if next.size() > ctx.limits.maxFragmentsPerSolid: return _fail("fragment_limit_exceeded", ctx)
			pieces = next
		var kept := 0.0
		var cells: Array = []
		if not changed:
			if not _add_fragments(ctx, 1): return _fail(ctx.error, ctx)
			entries.append(_native_entry(source, item.bounds, source_volume))
			remaining_volume += source_volume
			continue
		for piece in pieces:
			var cell: Dictionary = _export_cell(piece, transform, ctx)
			if not ctx.error.is_empty(): return _fail(ctx.error, ctx)
			kept += float(cell.volume)
			cells.append(cell)
		if not _volume_equal(source_volume, kept + removed): return _fail("volume_conservation_failed", ctx)
		if not _add_fragments(ctx, cells.size()): return _fail(ctx.error, ctx)
		entries.append({"original": source.duplicate(true), "unchanged": false, "cells": cells,
			"inputVolume": source_volume, "remainingVolume": kept, "removedVolume": removed})
		remaining_volume += kept
		removed_volume += removed
	return {"completed": true, "entries": entries, "canonicalApertures": cuts,
		"inputVolume": input_volume, "remainingVolume": remaining_volume, "removedVolume": removed_volume,
		"work": ctx.work, "fragmentCount": ctx.fragments, "limits": ctx.limits}


static func _subtract_one(poly: Dictionary, cut: AABB, ctx: Dictionary) -> Dictionary:
	# First establish positive-volume intersection. A rotated box can overlap the
	# AABB of a cut yet miss its actual solid; in that case retain the native box.
	var interior: Dictionary = poly
	for plane_index in range(6):
		interior = _clip(interior, cut, plane_index, true, ctx)
		if not ctx.error.is_empty(): return {}
		if interior.is_empty(): return {"pieces": [poly], "changed": false, "removedVolume": 0.0}
	var removed: float = _volume(interior, ctx)
	if not ctx.error.is_empty(): return {}
	if removed <= 0.0:
		ctx.error = "degenerate_intersection"
		return {}
	# Retain disjoint outside pieces, carrying only the inside remainder forward.
	# This subtracts the whole finite prism, NOT an infinite vertical column.
	var pieces: Array = []
	var remainder: Dictionary = poly
	for plane_index in range(6):
		var outside: Dictionary = _clip(remainder, cut, plane_index, false, ctx)
		if not ctx.error.is_empty(): return {}
		if not outside.is_empty(): pieces.append(outside)
		remainder = _clip(remainder, cut, plane_index, true, ctx)
		if not ctx.error.is_empty(): return {}
		if remainder.is_empty():
			ctx.error = "inconsistent_intersection"
			return {}
	var sum := removed
	for piece in pieces: sum += _volume(piece, ctx)
	var original_volume: float = _volume(poly, ctx)
	if not ctx.error.is_empty(): return {}
	if not _volume_equal(original_volume, sum): ctx.error = "split_volume_conservation_failed"
	return {"pieces": pieces, "changed": true, "removedVolume": removed}


static func _clip(poly: Dictionary, cut: AABB, plane_index: int, keep_inside: bool, ctx: Dictionary) -> Dictionary:
	if poly.is_empty(): return {}
	var axis: int = plane_index / 2
	var high: bool = plane_index % 2 == 1
	var coordinate: float = cut.end[axis] if high else cut.position[axis]
	var sign: float = 1.0 if high else -1.0
	if not keep_inside: sign = -sign
	var minimum := INF
	var maximum := -INF
	for face in poly.faces:
		for point in face.vertices:
			if not _spend(ctx, 1): return {}
			var distance: float = sign * (point[axis] - coordinate)
			minimum = minf(minimum, distance)
			maximum = maxf(maximum, distance)
	if maximum <= 0.0: return poly
	if minimum >= 0.0: return {} # Empty volume / boundary contact, no tolerance.
	var faces: Array = []
	var cap: PackedVector3Array = []
	for face in poly.faces:
		var input: PackedVector3Array = face.vertices
		var output: PackedVector3Array = []
		for index in range(input.size()):
			if not _spend(ctx, 1): return {}
			var a: Vector3 = input[index]
			var b: Vector3 = input[(index + 1) % input.size()]
			var da: float = sign * (a[axis] - coordinate)
			var db: float = sign * (b[axis] - coordinate)
			if da <= 0.0: _append_distinct(output, a)
			if (da < 0.0 and db > 0.0) or (da > 0.0 and db < 0.0):
				# Canonical edge arithmetic gives adjacent faces identical endpoints.
				var start: Vector3 = a if _vector_less(a, b) else b
				var end: Vector3 = b if _vector_less(a, b) else a
				var t: float = (coordinate - start[axis]) / (end[axis] - start[axis])
				var point: Vector3 = start + (end - start) * t
				point[axis] = coordinate
				_append_distinct(output, point)
		if output.size() > 1 and output[0] == output[output.size() - 1]: output.remove_at(output.size() - 1)
		if output.size() >= 3 and _area_vector(output).length_squared() > 0.0:
			if output.size() > ctx.limits.maxVerticesPerFace:
				ctx.error = "face_vertex_limit_exceeded"
				return {}
			faces.append({"vertices": output, "provenance": face.provenance})
			for point in output:
				if not _spend(ctx, cap.size() + 1): return {}
				if point[axis] == coordinate and not cap.has(point): cap.append(point)
				if cap.size() > ctx.limits.maxVerticesPerFace:
					ctx.error = "face_vertex_limit_exceeded"
					return {}
	if cap.size() < 3:
		ctx.error = "degenerate_cut_cap"
		return {}
	if cap.size() > ctx.limits.maxVerticesPerFace:
		ctx.error = "face_vertex_limit_exceeded"
		return {}
	var normal := Vector3.ZERO
	normal[axis] = sign
	if not _spend(ctx, cap.size() * cap.size()): return {}
	cap = _ordered_cap(cap, axis, normal)
	faces.append({"vertices": cap, "provenance": {"kind": "cut_plane", "aperture": cut,
		"planeIndex": plane_index, "insideHalfspace": keep_inside}})
	if faces.size() > ctx.limits.maxFacesPerCell:
		ctx.error = "face_limit_exceeded"
		return {}
	return {"faces": faces}


static func _ordered_cap(points: PackedVector3Array, axis: int, normal: Vector3) -> PackedVector3Array:
	var center := Vector3.ZERO
	for point in points: center += point
	center /= float(points.size())
	var u: int = (axis + 1) % 3
	var v: int = (axis + 2) % 3
	var sorted: Array = Array(points)
	sorted.sort_custom(func(a: Vector3, b: Vector3):
		var aa := atan2(a[v] - center[v], a[u] - center[u])
		var bb := atan2(b[v] - center[v], b[u] - center[u])
		return aa < bb if aa != bb else _vector_less(a, b))
	var result := PackedVector3Array(sorted)
	if _area_vector(result).dot(normal) < 0.0: result.reverse()
	# Stable cyclic start independent of angle wrap and cap orientation.
	var first := 0
	for index in range(1, result.size()):
		if _vector_less(result[index], result[first]): first = index
	var rotated: PackedVector3Array = []
	for index in range(result.size()): rotated.append(result[(index + first) % result.size()])
	return rotated


static func _export_cell(poly: Dictionary, transform: Transform3D, ctx: Dictionary) -> Dictionary:
	if not _closed_convex(poly, ctx): return {}
	var inverse: Transform3D = transform.affine_inverse()
	var faces: Array = []
	var points: PackedVector3Array = []
	if poly.faces.size() > ctx.limits.maxFacesPerCell:
		ctx.error = "face_limit_exceeded"
		return {}
	for face in poly.faces:
		var world: PackedVector3Array = face.vertices
		var local: PackedVector3Array = []
		if world.size() > ctx.limits.maxVerticesPerFace:
			ctx.error = "face_vertex_limit_exceeded"
			return {}
		for point in world:
			if not _spend(ctx, 1): return {}
			var p: Vector3 = inverse * point
			if not p.is_finite() or maxf(absf(p.x), maxf(absf(p.y), absf(p.z))) > 0.5 + LOCAL_ERROR:
				ctx.error = "fragment_outside_original_box"
				return {}
			local.append(p)
			points.append(point)
		var area: Vector3 = _area_vector(world)
		if not area.is_finite() or area.length_squared() == 0.0:
			ctx.error = "degenerate_output_face"
			return {}
		faces.append({"worldVertices": world, "localVertices": local, "normal": area.normalized(),
			"provenance": face.provenance.duplicate(true)})
	var volume: float = _volume(poly, ctx)
	if not ctx.error.is_empty(): return {}
	if not is_finite(volume) or volume <= 0.0:
		ctx.error = "degenerate_output_cell"
		return {}
	var bounds: AABB = _point_bounds(points, ctx)
	if not ctx.error.is_empty(): return {}
	return {"representation": "convex_polyhedron", "faces": faces, "bounds": bounds, "volume": volume}


static func _closed_convex(poly: Dictionary, ctx: Dictionary) -> bool:
	var edges: Dictionary = {}
	var vertices: Dictionary = {}
	for face in poly.faces:
		var points: PackedVector3Array = face.vertices
		for index in range(points.size()):
			if not _spend(ctx, 1): return false
			var a: Vector3 = points[index]
			var b: Vector3 = points[(index + 1) % points.size()]
			if not a.is_finite() or a == b:
				ctx.error = "degenerate_output_edge"
				return false
			vertices[a] = true
			if not edges.has(a): edges[a] = {}
			edges[a][b] = int(edges[a].get(b, 0)) + 1
	for a in edges:
		for b in edges[a]:
			if not _spend(ctx, 1): return false
			if edges[a][b] != 1 or not edges.has(b) or edges[b].get(a, 0) != 1:
				ctx.error = "open_or_nonmanifold_fragment"
				return false
	var bounds: AABB = _poly_bounds(poly, ctx)
	if not ctx.error.is_empty(): return false
	var error: float = bounds.size.length() * LOCAL_ERROR
	for face in poly.faces:
		var points: PackedVector3Array = face.vertices
		var area: Vector3 = _area_vector(points)
		if not area.is_finite() or area.length_squared() == 0.0:
			ctx.error = "degenerate_output_face"
			return false
		var normal: Vector3 = area.normalized()
		for point in points:
			if not _spend(ctx, 1): return false
			if absf(normal.dot(point - points[0])) > error:
				ctx.error = "nonplanar_fragment_face"
				return false
		for point in vertices:
			if not _spend(ctx, 1): return false
			if normal.dot(point - points[0]) > error:
				ctx.error = "nonconvex_or_inverted_fragment"
				return false
	return true


static func _box_poly(transform: Transform3D) -> Dictionary:
	var faces: Array = []
	for axis in range(3):
		for side in [-1.0, 1.0]:
			var vertices: PackedVector3Array = []
			for uv in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]:
				var point := Vector3.ZERO
				point[axis] = side * 0.5
				point[(axis + 1) % 3] = uv.x
				point[(axis + 2) % 3] = uv.y
				vertices.append(transform * point)
			if side < 0.0: vertices.reverse()
			faces.append({"vertices": vertices, "provenance": {"kind": "original_face", "faceIndex": faces.size()}})
	return {"faces": faces}


static func _volume(poly: Dictionary, ctx: Dictionary) -> float:
	if poly.is_empty(): return 0.0
	# Reference near the solid, avoiding cancellation from large world origins.
	var reference: Vector3 = poly.faces[0].vertices[0]
	var sum := 0.0
	for face in poly.faces:
		var vertices: PackedVector3Array = face.vertices
		for index in range(1, vertices.size() - 1):
			if not _spend(ctx, 1): return 0.0
			var a: Vector3 = vertices[0] - reference
			var b: Vector3 = vertices[index] - reference
			var c: Vector3 = vertices[index + 1] - reference
			sum += a.dot(b.cross(c)) / 6.0
	return sum


static func _native_entry(source: Dictionary, bounds: AABB, volume: float) -> Dictionary:
	return {"original": source.duplicate(true), "unchanged": true,
		"cells": [{"representation": "native_box", "transform": source.transform, "bounds": bounds, "volume": volume}],
		"inputVolume": volume, "remainingVolume": volume, "removedVolume": 0.0}


static func _valid_transform(transform: Transform3D) -> bool:
	if not transform.origin.is_finite() or not transform.basis.is_finite(): return false
	var axes: Array[Vector3] = [transform.basis.x, transform.basis.y, transform.basis.z]
	for axis in axes:
		if axis.length() < MIN_AXIS or axis.length() > MAX_AXIS: return false
	# Basis.scaled() in the actual cobble generator scales world rows, so a
	# tilted anisotropic box need not have orthogonal columns. Preserve that
	# exact affine solid; do NOT orthonormalize it or reinterpret its scale.
	var determinant: float = transform.basis.determinant()
	if determinant <= 0.0 or not is_finite(determinant): return false
	var normalized_volume: float = determinant / (axes[0].length() * axes[1].length() * axes[2].length())
	if normalized_volume < 0.00001: return false
	var inverse: Basis = transform.basis.inverse()
	if not inverse.is_finite() or maxf(inverse.x.length(), maxf(inverse.y.length(), inverse.z.length())) > 1.0 / MIN_AXIS: return false
	return true


static func _valid_bounds(bounds: AABB) -> bool:
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite(): return false
	for axis in range(3):
		if bounds.size[axis] < MIN_AXIS or bounds.end[axis] <= bounds.position[axis] or absf(bounds.position[axis]) > MAX_COORD or absf(bounds.end[axis]) > MAX_COORD: return false
	return true


static func _corners(transform: Transform3D) -> PackedVector3Array:
	var result: PackedVector3Array = []
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]: result.append(transform * Vector3(x, y, z))
	return result


static func _poly_bounds(poly: Dictionary, ctx: Dictionary) -> AABB:
	var points: PackedVector3Array = []
	for face in poly.faces: points.append_array(face.vertices)
	return _point_bounds(points, ctx)


static func _point_bounds(points: PackedVector3Array, ctx: Dictionary) -> AABB:
	# AABB.expand repeatedly reconstructs a float32 extent and may put end
	# INSIDE a represented corner. Compute extrema once, then round ONLY the
	# broadphase extent outward until its represented end encloses the maximum.
	# Source vertices and aperture planes are never moved/grown by this step.
	var minimum: Vector3 = points[0]
	var maximum: Vector3 = points[0]
	for point in points:
		if not _spend(ctx, 1): return AABB()
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	var result := AABB(minimum, maximum - minimum)
	for axis in range(3):
		var steps := 0
		while result.end[axis] < maximum[axis] and steps < 4:
			if not _spend(ctx, 1): return AABB()
			var extent: Vector3 = result.size
			extent[axis] = _next_positive_float32(extent[axis])
			result.size = extent
			steps += 1
		if not result.end.is_finite() or result.position[axis] > minimum[axis] or result.end[axis] < maximum[axis]:
			ctx.error = "conservative_bounds_unrepresentable"
			return AABB()
	return result


static func _next_positive_float32(value: float) -> float:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	bytes.encode_u32(0, bytes.decode_u32(0) + 1)
	return bytes.decode_float(0)


static func _area_vector(points: PackedVector3Array) -> Vector3:
	var result := Vector3.ZERO
	for index in range(1, points.size() - 1): result += (points[index] - points[0]).cross(points[index + 1] - points[0])
	return result


static func _strict_overlap(a: AABB, b: AABB) -> bool:
	return a.position.x < b.end.x and a.end.x > b.position.x and a.position.y < b.end.y and a.end.y > b.position.y and a.position.z < b.end.z and a.end.z > b.position.z


static func _bounds_less(a: AABB, b: AABB) -> bool:
	if a.position != b.position: return _vector_less(a.position, b.position)
	return _vector_less(a.size, b.size)


static func _vector_less(a: Vector3, b: Vector3) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


static func _append_distinct(points: PackedVector3Array, point: Vector3) -> void:
	if points.is_empty() or points[points.size() - 1] != point: points.append(point)


static func _volume_equal(a: float, b: float) -> bool:
	return is_finite(a) and is_finite(b) and absf(a - b) <= maxf(absf(a), absf(b)) * REL_VOLUME_ERROR


static func _spend(ctx: Dictionary, amount: int) -> bool:
	ctx.work += amount
	if ctx.work > ctx.limits.maxWork: ctx.error = "work_limit_exceeded"
	return ctx.error.is_empty()


static func _add_fragments(ctx: Dictionary, count: int) -> bool:
	ctx.fragments += count
	if ctx.fragments > ctx.limits.maxFragments: ctx.error = "fragment_limit_exceeded"
	return ctx.error.is_empty()


static func _fail(reason: String, ctx: Dictionary) -> Dictionary:
	return {"completed": false, "reason": reason, "work": ctx.work}
