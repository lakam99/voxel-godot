extends RefCounted

## Unwired publication preparation for ONE changed original paving solid.
## Keep the returned mesh under original.localTransform (including affine
## scale/shear) and the original material/custom-data instance. Do not publish
## fragments as newly centred pieces: the shader uses both MODEL_MATRIX and
## unit-box local position. Unchanged entries must use the native box path.
const MAX_VERTICES := 32768


static func prepare(entry: Dictionary, unit_box: BoxMesh) -> Dictionary:
	if entry.get("unchanged", true) or not entry.get("original") is Dictionary or not entry.get("cells") is Array or entry.cells.size() > 256:
		return _fail("requires_changed_construction_entry")
	var original: Dictionary = entry.original
	if not original.get("transform") is Transform3D or not original.get("localTransform") is Transform3D or unit_box == null or unit_box.size != Vector3.ONE or unit_box.get_surface_count() != 1:
		return _fail("invalid_original_mesh_frame")
	for transform in [original.transform, original.localTransform]:
		if not transform.origin.is_finite() or not transform.basis.is_finite() or not is_finite(transform.basis.determinant()) or transform.basis.determinant() <= 0.0 or not transform.basis.inverse().is_finite():
			return _fail("invalid_original_mesh_frame")
	var template: Array = unit_box.surface_get_arrays(0)
	var faces: Dictionary = _template_faces(template)
	if faces.size() != 6: return _fail("unsupported_unit_box_attributes")
	var coordinates: Dictionary = _source_face_coordinates(entry)
	if not coordinates.ready: return coordinates
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	var provenance: Array = []
	var cell_index := 0
	for cell in entry.cells:
		if not cell is Dictionary or cell.get("representation") != "convex_polyhedron" or not cell.get("faces") is Array or cell.faces.size() < 4 or cell.faces.size() > 128:
			return _fail("invalid_convex_cell")
		for face in cell.faces:
			if not face is Dictionary or not face.get("localVertices") is PackedVector3Array or not face.get("provenance") is Dictionary:
				return _fail("invalid_convex_face")
			var vertices := PackedVector3Array()
			for world_point in face.worldVertices: vertices.append(coordinates.byWorld[world_point])
			if vertices.size() < 3 or vertices.size() > 128 or positions.size() + (vertices.size() - 2) * 3 > MAX_VERTICES:
				return _fail("fragment_mesh_vertex_limit")
			var source_face: Dictionary = face.provenance
			var is_original: bool = source_face.get("kind") == "original_face"
			if not is_original and source_face.get("kind") != "cut_plane": return _fail("invalid_face_provenance")
			var attributes: Dictionary = {}
			var normal := Vector3.ZERO
			var tangent := Vector3.ZERO
			var tangent_w := 1.0
			if is_original:
				if not faces.has(source_face.get("faceIndex")): return _fail("invalid_original_face")
				attributes = faces[source_face.faceIndex]
				normal = attributes.normal
				tangent = attributes.tangent
				tangent_w = attributes.tangentW
			else:
				if not face.get("normal") is Vector3: return _fail("invalid_cut_normal")
				# n_world = inverse(M).transpose() * n_local.
				normal = (original.transform.basis.transposed() * face.normal).normalized()
				var reference := Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT
				tangent = reference.cross(normal).normalized()
			if not normal.is_finite() or not tangent.is_finite() or normal.length_squared() == 0.0 or tangent.length_squared() == 0.0:
				return _fail("invalid_mesh_normal_or_tangent")
			var start := positions.size()
			# Construction faces are outward CCW; Godot's front faces are CW.
			for index in range(1, vertices.size() - 1):
				var area: Vector3 = (vertices[index] - vertices[0]).cross(vertices[index + 1] - vertices[0])
				if not area.is_finite() or area.length_squared() == 0.0:
					return _fail("degenerate_fragment_triangle")
				for corner in [0, index + 1, index]:
					var point: Vector3 = vertices[corner]
					if not point.is_finite(): return _fail("nonfinite_local_vertex")
					positions.append(point)
					normals.append(normal)
					uvs.append(_original_uv(point, attributes) if is_original else Vector2(point.dot(tangent), point.dot(normal.cross(tangent))))
					tangents.append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, tangent_w]))
			provenance.append({"cellIndex": cell_index, "firstVertex": start, "vertexCount": positions.size() - start, "source": source_face.duplicate(true)})
		cell_index += 1
	var mesh: ArrayMesh = null
	if not positions.is_empty():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_TANGENT] = tangents
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"ready": true, "mesh": mesh, "original": original.duplicate(true), "faceProvenance": provenance, "vertexCount": positions.size(),
		"boundarySemantics": "solid_union_with_enclosed_partition_caps"}


static func _template_faces(arrays: Array) -> Dictionary:
	var result: Dictionary = {}
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	if points.size() != 24 or normals.size() != 24 or uvs.size() != 24 or tangents.size() != 96: return {}
	for axis in range(3):
		for side in [-1.0, 1.0]:
			var normal := Vector3.ZERO
			normal[axis] = side
			var corners: Array = []
			var tangent := Vector3.ZERO
			var tangent_w := 0.0
			var represented_normal := Vector3.ZERO
			for index in range(points.size()):
				# Surface readback decodes Godot's packed normals; cardinal faces
				# need not decode to exact cardinal vectors. Classify by the
				# geometric face and dominant normal, then retain actual attributes.
				if points[index][axis] != side * 0.5 or normals[index].dot(normal) < 0.99: continue
				var t := Vector3(tangents[index * 4], tangents[index * 4 + 1], tangents[index * 4 + 2])
				if not corners.is_empty() and (t != tangent or tangents[index * 4 + 3] != tangent_w or normals[index] != represented_normal): return {}
				represented_normal = normals[index]
				tangent = t
				tangent_w = tangents[index * 4 + 3]
				corners.append({"position": points[index], "uv": uvs[index]})
			if corners.size() != 4: return {}
			result[result.size()] = {"axis": axis, "normal": represented_normal, "tangent": tangent, "tangentW": tangent_w, "corners": corners}
	return result


static func _source_face_coordinates(entry: Dictionary) -> Dictionary:
	# Inverse-transform roundoff must not move retained original box faces.
	# Accumulate the source-face constraints for each shared vertex first, then
	# use ONE local value on every adjoining face. Exact original corners thus
	# stay exact +/-0.5 corners; no per-face crack or altered stone silhouette.
	var points: Dictionary = {}
	var constraints: Dictionary = {}
	for cell in entry.cells:
		if not cell is Dictionary or not cell.get("faces") is Array or cell.faces.size() < 4 or cell.faces.size() > 128: return _fail("invalid_convex_cell")
		for face in cell.faces:
			if not face is Dictionary or not face.get("worldVertices") is PackedVector3Array or not face.get("localVertices") is PackedVector3Array or not face.get("provenance") is Dictionary:
				return _fail("invalid_convex_face")
			if face.worldVertices.size() != face.localVertices.size() or face.worldVertices.size() < 3 or face.worldVertices.size() > 128: return _fail("invalid_convex_face")
			for index in range(face.worldVertices.size()):
				var world: Vector3 = face.worldVertices[index]
				var local: Vector3 = face.localVertices[index]
				if not world.is_finite() or not local.is_finite(): return _fail("nonfinite_local_vertex")
				if points.has(world) and points[world] != local: return _fail("inconsistent_shared_local_vertex")
				points[world] = local
				if points.size() > MAX_VERTICES: return _fail("fragment_mesh_vertex_limit")
				if face.provenance.get("kind") != "original_face": continue
				var face_index: Variant = face.provenance.get("faceIndex")
				if not face_index is int or face_index < 0 or face_index >= 6: return _fail("invalid_original_face")
				var axis: int = face_index / 2
				var value := -0.5 if face_index % 2 == 0 else 0.5
				if not constraints.has(world): constraints[world] = {}
				if constraints[world].has(axis) and constraints[world][axis] != value: return _fail("contradictory_original_face")
				if absf(local[axis] - value) > 0.00002: return _fail("invalid_original_face_coordinate")
				constraints[world][axis] = value
	for world in points:
		var local: Vector3 = points[world]
		for axis in constraints.get(world, {}): local[axis] = constraints[world][axis]
		if absf(local.x) > 0.5 or absf(local.y) > 0.5 or absf(local.z) > 0.5: return _fail("local_vertex_outside_original_stone")
		points[world] = local
	return {"ready": true, "byWorld": points}


static func _original_uv(point: Vector3, attributes: Dictionary) -> Vector2:
	var u: int = (attributes.axis + 1) % 3
	var v: int = (attributes.axis + 2) % 3
	var uv := Vector2.ZERO
	for corner in attributes.corners:
		uv += corner.uv * (0.5 + 2.0 * corner.position[u] * point[u]) * (0.5 + 2.0 * corner.position[v] * point[v])
	return uv


static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
