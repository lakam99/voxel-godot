extends RefCounted
## Stable identity and conservative CPU payload estimate for immutable render meshes.
## Keep the payload shape/version in sync with ChunkRenderPacketBackend.

const SCHEMA := "chunk-render-mesh-content/v1"


static func inspect(mesh: Mesh) -> Dictionary:
	if not is_instance_valid(mesh) or mesh.get_surface_count() < 1:
		return {"status":"failed", "reason":"mesh_has_no_surfaces"}
	var payload: Array = [SCHEMA, mesh.get_aabb(), mesh.get_surface_count()]
	var bytes := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX \
				or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array \
				or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			return {"status":"failed", "reason":"mesh_surface_missing_vertices"}
		payload.append(surface_index)
		payload.append(mesh.surface_get_primitive_type(surface_index))
		payload.append(arrays)
		for value: Variant in arrays:
			var size := _packed_array_bytes(value)
			if size < 0 or bytes > 9223372036854775807 - size:
				return {"status":"failed", "reason":"mesh_surface_payload_unmeasurable"}
			bytes += size
	if bytes <= 0:
		return {"status":"failed", "reason":"mesh_surface_payload_empty"}
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(payload)) != OK:
		return {"status":"failed", "reason":"mesh_content_digest_failed"}
	return {"status":"ready", "schema":SCHEMA,
		"contentDigest":context.finish().hex_encode(), "cpuArrayBytes":bytes}


static func _packed_array_bytes(value: Variant) -> int:
	if value == null:
		return 0
	if value is PackedByteArray: return value.size()
	if value is PackedInt32Array: return value.size() * 4
	if value is PackedInt64Array: return value.size() * 8
	if value is PackedFloat32Array: return value.size() * 4
	if value is PackedFloat64Array: return value.size() * 8
	if value is PackedVector2Array: return value.size() * 8
	if value is PackedVector3Array: return value.size() * 12
	if value is PackedVector4Array: return value.size() * 16
	if value is PackedColorArray: return value.size() * 16
	return -1
