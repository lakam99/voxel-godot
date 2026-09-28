extends RefCounted

## Actual ArrayMesh CPU arrays only. Caller keeps its AABB occluder whenever
## valid=false; a partial/budget-limited answer is NEVER a clear sightline.
## Caller owns the global 200k-triangle budget and checks identity_matches at
## index/end. Do not mutate prepared data between those checks. No GPU proof.
const MAX_TRIANGLES := 200000
const MAX_SURFACES := 128
const MAX_VERTICES := MAX_TRIANGLES * 3

static func prepare(mesh: ArrayMesh, max_triangles: int = MAX_TRIANGLES) -> Dictionary:
	var captured: Dictionary = _capture(mesh, max_triangles)
	if not captured.valid: return captured
	var triangles := PackedVector3Array()
	for arrays in captured.arrays:
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		var indexed: bool = indices is PackedInt32Array and not indices.is_empty()
		var count: int = indices.size() if indexed else vertices.size()
		for first in range(0, count, 3):
			var a: Vector3 = vertices[indices[first] if indexed else first]
			var b: Vector3 = vertices[indices[first + 1] if indexed else first + 1]
			var c: Vector3 = vertices[indices[first + 2] if indexed else first + 2]
			if _cross(_sub(_xyz(b), _xyz(a)), _sub(_xyz(c), _xyz(a))) == [0.0, 0.0, 0.0]: return _fail("degenerate_triangle")
			triangles.append_array(PackedVector3Array([a, b, c]))
	var identity: Dictionary = {"meshInstanceId": mesh.get_instance_id(), "arraysDigest": _digest(captured.arrays), "trianglesDigest": _digest(triangles)}
	return {"valid": true, "identity": identity, "localtriangles": triangles, "triangleCount": triangles.size() / 3}

static func identity_matches(mesh: ArrayMesh, prepared: Dictionary) -> bool:
	if mesh == null or not _prepared_valid(prepared) or not prepared.get("identity") is Dictionary: return false
	if prepared.identity.get("meshInstanceId") != mesh.get_instance_id(): return false
	var current: Dictionary = _capture(mesh, MAX_TRIANGLES)
	return current.valid and _digest(current.arrays) == prepared.identity.get("arraysDigest") and _digest(prepared.localtriangles) == prepared.identity.get("trianglesDigest")

static func intersect(prepared: Dictionary, actualtransform: Transform3D, from: Vector3, to: Vector3, max_tests: int) -> Dictionary:
	if not _prepared_valid(prepared) or not from.is_finite() or not to.is_finite() or from == to: return _fail("invalid_prepared_or_segment")
	var count: int = prepared.localtriangles.size() / 3
	if max_tests < 0 or count > max_tests: return _fail("triangle_budget")
	if not actualtransform.origin.is_finite() or not actualtransform.basis.x.is_finite() or not actualtransform.basis.y.is_finite() or not actualtransform.basis.z.is_finite(): return _fail("nonfinite_transform")
	# Scalar inverse avoids an extra float32 Basis.inverse/Vector3 round trip.
	var x: Array = _xyz(actualtransform.basis.x)
	var y: Array = _xyz(actualtransform.basis.y)
	var z: Array = _xyz(actualtransform.basis.z)
	var rows: Array = [_cross(y, z), _cross(z, x), _cross(x, y)]
	var determinant: float = _dot(x, rows[0])
	if not is_finite(determinant) or determinant == 0.0: return _fail("singular_transform")
	var origin: Array = _sub(_xyz(from), _xyz(actualtransform.origin))
	var endpoint: Array = _sub(_xyz(to), _xyz(actualtransform.origin))
	var local_from: Array = []
	var local_to: Array = []
	for row in rows:
		local_from.append(_dot(row, origin) / determinant)
		local_to.append(_dot(row, endpoint) / determinant)
	if not _finite(local_from) or not _finite(local_to): return _fail("nonfinite_inverse")
	var direction: Array = _sub(local_to, local_from)
	var nearest: float = INF
	var triangle_index: int = -1
	for index in range(count):
		var a: Array = _xyz(prepared.localtriangles[index * 3])
		var b: Array = _xyz(prepared.localtriangles[index * 3 + 1])
		var c: Array = _xyz(prepared.localtriangles[index * 3 + 2])
		var hit: Dictionary = _triangle(local_from, direction, a, b, c)
		if not hit.valid: return _fail(hit.reason, index + 1)
		if hit.hit and hit.t < nearest:
			nearest = hit.t
			triangle_index = index
	var point := Vector3.ZERO
	if triangle_index >= 0:
		point = Vector3(float(from.x) + (float(to.x) - float(from.x)) * nearest, float(from.y) + (float(to.y) - float(from.y)) * nearest, float(from.z) + (float(to.z) - float(from.z)) * nearest)
		if not point.is_finite(): return _fail("nonfinite_hit", count)
	return {"valid": true, "hit": triangle_index >= 0, "point": point, "tests": count, "t": nearest if triangle_index >= 0 else null, "triangleIndex": triangle_index}

static func _capture(mesh: ArrayMesh, limit: int) -> Dictionary:
	if mesh == null or limit <= 0 or limit > MAX_TRIANGLES or mesh.get_surface_count() <= 0 or mesh.get_surface_count() > MAX_SURFACES or mesh.get_blend_shape_count() != 0: return _fail("invalid_mesh_or_limit")
	var surfaces: Array = []
	var triangle_count: int = 0
	var vertex_count: int = 0
	for surface in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES: return _fail("non_triangle_surface")
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() != Mesh.ARRAY_MAX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array: return _fail("invalid_vertex_array")
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		vertex_count += vertices.size()
		if vertices.is_empty() or vertex_count > MAX_VERTICES: return _fail("vertex_budget")
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices != null and not indices is PackedInt32Array: return _fail("invalid_index_array")
		var indexed: bool = indices is PackedInt32Array and not indices.is_empty()
		var count: int = indices.size() if indexed else vertices.size()
		if count == 0 or count % 3 != 0: return _fail("incomplete_triangle")
		triangle_count += count / 3
		if triangle_count > limit: return _fail("triangle_budget")
		for vertex in vertices:
			if not vertex.is_finite(): return _fail("nonfinite_vertex")
		if indexed:
			for index in indices:
				if index < 0 or index >= vertices.size(): return _fail("index_out_of_range")
		# Bone-deformed meshes are not the static published cut-mesh contract.
		for slot in [Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
			if arrays[slot] != null and not arrays[slot].is_empty(): return _fail("skinned_mesh_not_static")
		surfaces.append(arrays)
	return {"valid": true, "arrays": surfaces}

static func _prepared_valid(value: Dictionary) -> bool:
	return value.get("valid") == true and value.get("identity") is Dictionary and value.get("localtriangles") is PackedVector3Array and not value.localtriangles.is_empty() and value.localtriangles.size() % 3 == 0 and value.localtriangles.size() <= MAX_VERTICES and value.get("triangleCount") == value.localtriangles.size() / 3

static func _triangle(origin: Array, direction: Array, a: Array, b: Array, c: Array) -> Dictionary:
	if not _finite(a) or not _finite(b) or not _finite(c): return _fail("nonfinite_triangle")
	var ab: Array = _sub(b, a)
	var ac: Array = _sub(c, a)
	var normal: Array = _cross(ab, ac)
	if not _finite(normal) or normal == [0.0, 0.0, 0.0]: return _fail("degenerate_triangle")
	var p: Array = _cross(direction, ac)
	var det: float = _dot(ab, p)
	var offset: Array = _sub(origin, a)
	if not is_finite(det): return _fail("nonfinite_intersection")
	if det == 0.0:
		var plane: float = _dot(normal, offset)
		if not is_finite(plane): return _fail("nonfinite_intersection")
		return _coplanar(origin, direction, a, b, c, normal) if plane == 0.0 else {"valid": true, "hit": false}
	var q: Array = _cross(offset, ab)
	var u: float = _dot(offset, p) / det
	var v: float = _dot(direction, q) / det
	var t: float = _dot(ac, q) / det
	if not is_finite(u) or not is_finite(v) or not is_finite(t): return _fail("nonfinite_intersection")
	return {"valid": true, "hit": u >= 0.0 and v >= 0.0 and u + v <= 1.0 and t >= 0.0 and t <= 1.0, "t": t}

static func _coplanar(origin: Array, direction: Array, a: Array, b: Array, c: Array, normal: Array) -> Dictionary:
	var drop: int = 0
	for axis in [1, 2]:
		if absf(normal[axis]) > absf(normal[drop]): drop = axis
	var x: int = (drop + 1) % 3
	var y: int = (drop + 2) % 3
	var orientation: float = 1.0 if normal[drop] > 0.0 else -1.0
	var low: float = 0.0
	var high: float = 1.0
	for edge in [[a, b], [b, c], [c, a]]:
		var dx: float = edge[1][x] - edge[0][x]
		var dy: float = edge[1][y] - edge[0][y]
		var start: float = orientation * (dx * (origin[y] - edge[0][y]) - dy * (origin[x] - edge[0][x]))
		var delta: float = orientation * (dx * direction[y] - dy * direction[x])
		if not is_finite(start) or not is_finite(delta): return _fail("nonfinite_coplanar_intersection")
		if delta == 0.0:
			if start < 0.0: return {"valid": true, "hit": false}
		elif delta > 0.0: low = maxf(low, -start / delta)
		else: high = minf(high, -start / delta)
		if low > high: return {"valid": true, "hit": false}
	return {"valid": true, "hit": true, "t": low}

static func _xyz(value: Vector3) -> Array:
	return [float(value.x), float(value.y), float(value.z)]

static func _sub(a: Array, b: Array) -> Array:
	return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]

static func _cross(a: Array, b: Array) -> Array:
	return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]

static func _dot(a: Array, b: Array) -> float:
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

static func _finite(a: Array) -> bool:
	return is_finite(a[0]) and is_finite(a[1]) and is_finite(a[2])

static func _digest(value: Variant) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()

static func _fail(reason: String, tests: int = 0) -> Dictionary:
	return {"valid": false, "hit": false, "point": Vector3.ZERO, "tests": tests, "reason": reason}
