extends RefCounted

## Canonical value-only unit-box attributes for worker-side clipped fragments.
## This deliberately constructs typed values, never a BoxMesh or ArrayMesh.
static func canonical() -> Array:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	for face in range(6):
		var axis: int = face / 2
		var sign := -1.0 if face % 2 == 0 else 1.0
		var normal := Vector3.ZERO
		normal[axis] = sign
		var u: int = (axis + 1) % 3
		var v: int = (axis + 2) % 3
		var tangent := Vector3.ZERO
		tangent[u] = 1.0
		for corner in [Vector2(-0.5,-0.5),Vector2(0.5,-0.5),Vector2(0.5,0.5),Vector2(-0.5,0.5)]:
			var point := Vector3.ZERO
			point[axis] = sign * 0.5
			point[u] = corner.x
			point[v] = corner.y
			vertices.append(point)
			normals.append(normal)
			uvs.append(corner + Vector2(0.5,0.5))
			tangents.append_array(PackedFloat32Array([tangent.x,tangent.y,tangent.z,1.0]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays.make_read_only()
	return arrays
