extends RefCounted
class_name EcologyDetailSourceValueBuilder

## Converts the already generated detail transform batches to value-only
## source rows. This helper owns no RNG and never inspects scene Nodes.
const SCHEMA := "ecology.detail_source_rows.v1"


static func build_rows(source_inputs: Dictionary, batches: Dictionary,
		resolvers: Dictionary) -> Dictionary:
	var input_error := _validate_source_inputs(source_inputs)
	if not input_error.is_empty():
		return _result("pending", input_error, [], "")
	if source_inputs.get("generationStatus", "") != "complete" \
			or source_inputs.get("batchesComplete", false) != true:
		return _result("pending", "detail_batches_incomplete", [], "")
	if not batches.is_empty() and not _resolvers_available(resolvers):
		return _result("failed", "detail_source_resolver_unavailable", [], "")

	var rows: Array[Dictionary] = []
	var detail_types: Array = batches.keys()
	detail_types.sort()
	for detail_type_value: Variant in detail_types:
		var detail_type := String(detail_type_value)
		if detail_type.is_empty() or not batches[detail_type_value] is Array:
			return _result("failed", "invalid_detail_batch", [], "")
		var transforms: Array = batches[detail_type_value]
		var resolved: Dictionary = _resolve_mesh(detail_type, resolvers)
		if String(resolved.get("status", "failed")) != "ready":
			return _result("failed", String(resolved.get("reason", "detail_mesh_unavailable")), [], "")
		var mesh: Mesh = resolved.mesh
		var is_array_mesh := mesh is ArrayMesh
		var surface_count := mesh.get_surface_count() if is_array_mesh else 1
		if surface_count <= 0:
			return _result("failed", "detail_mesh_has_no_surfaces", [], "")
		for index in range(transforms.size()):
			var transform_value: Variant = transforms[index]
			if not transform_value is Transform3D:
				return _result("failed", "invalid_detail_transform", [], "")
			var transform: Transform3D = transform_value
			for surface_index in range(surface_count):
				var mesh_surface_index := surface_index if is_array_mesh else -1
				var surface_mesh: Variant = mesh
				if is_array_mesh:
					surface_mesh = _call(resolvers.meshSurface, [detail_type, surface_index])
				if not surface_mesh is Mesh:
					return _result("failed", "detail_surface_mesh_unavailable", [], "")
				var material_key_value: Variant = _call(resolvers.materialKey,
					[detail_type, mesh_surface_index])
				var material_value: Variant = _call(resolvers.material,
					[detail_type, mesh_surface_index])
				var mesh_digest_value: Variant = _call(resolvers.meshContentDigest,
					[surface_mesh])
				var material_digest_value: Variant = _call(resolvers.materialContentDigest,
					[material_value])
				if not material_key_value is String or String(material_key_value).is_empty():
					return _result("failed", "detail_material_key_unavailable", [], "")
				if not mesh_digest_value is String or not _valid_digest(mesh_digest_value) \
						or not material_digest_value is String or not _valid_digest(material_digest_value):
					return _result("pending", "detail_render_resource_digest_unavailable", [], "")
				var layer_value: Variant = _call(resolvers.renderLayer,
					[material_value, detail_type, mesh_surface_index])
				if not layer_value is String or String(layer_value).is_empty():
					return _result("failed", "detail_render_layer_unavailable", [], "")
				var color_value: Variant = _call(resolvers.instanceColor,
					[detail_type, transform, index])
				var phase_value: Variant = _call(resolvers.instancePhase,
					[detail_type, transform, index])
				var visibility_value: Variant = _call(resolvers.visibilityRangeEnd, [detail_type])
				if not color_value is Color or not phase_value is float \
						or not visibility_value is float or float(visibility_value) <= 0.0:
					return _result("failed", "detail_instance_visual_data_unavailable", [], "")
				var candidate := {
					"schema": SCHEMA,
					"sourceRevision": String(source_inputs.revisions.details),
					"sourceChunkKey": String(source_inputs.sourceChunkKey),
					"sourceId": "%s:detail:%d,%d:%s:%d:surface:%d" % [
						String(source_inputs.worldSeed), int(source_inputs.chunkX),
						int(source_inputs.chunkZ), detail_type, index, surface_index],
					"kind": "surface_detail",
					"detailType": detail_type,
					"surfaceIndex": mesh_surface_index,
					"renderLayers": [String(layer_value)],
					"materials": [String(material_key_value)],
					"meshContentDigest":String(mesh_digest_value),
					"materialContentDigest":String(material_digest_value),
					"resourceContentIdentitySchema":"ecology-render-member-content/v1",
					"meshSource": "procedural_detail:%s:surface:%d" % [detail_type, surface_index] \
						if is_array_mesh else "procedural_detail:%s" % detail_type,
					"transform": transform,
					"instanceColor": color_value,
					"customData": Color(float(phase_value), 0.0, 0.0, 1.0),
					"meshBounds": (surface_mesh as Mesh).get_aabb(),
					"localBounds": transform * (surface_mesh as Mesh).get_aabb(),
					"shadowCasting": "off",
					"visibilityRangeEnd": float(visibility_value)
				}
				rows.append(candidate)
	var digest := rows_digest(source_inputs, rows)
	return _result("ready", "", rows, digest)


static func rows_digest(source_inputs: Dictionary, rows: Array) -> String:
	var canonical_payload: Variant = _canonicalize({
		"schema": SCHEMA,
		"sourceInputs": source_inputs,
		"rows": rows
	})
	var hash := HashingContext.new()
	if hash.start(HashingContext.HASH_SHA256) != OK:
		return ""
	hash.update(var_to_bytes(canonical_payload))
	return hash.finish().hex_encode()


static func _validate_source_inputs(source_inputs: Dictionary) -> String:
	for field: String in ["worldId", "worldSeed", "sourceChunkKey"]:
		if String(source_inputs.get(field, "")).is_empty():
			return "detail_source_identity_pending"
	for field: String in ["chunkX", "chunkZ"]:
		if not source_inputs.has(field) or not source_inputs[field] is int:
			return "detail_source_chunk_coordinates_pending"
	if not source_inputs.get("chunkOrigin", Vector3.ZERO) is Vector3:
		return "detail_source_chunk_origin_pending"
	var revisions: Variant = source_inputs.get("revisions", null)
	if not revisions is Dictionary:
		return "detail_source_revisions_pending"
	for field: String in ["terrain", "structure", "details"]:
		if String(revisions.get(field, "")).is_empty():
			return "detail_source_revisions_pending"
	return ""


static func _resolvers_available(resolvers: Dictionary) -> bool:
	for name: String in ["mesh", "meshSurface", "materialKey", "material", "renderLayer",
			"meshContentDigest", "materialContentDigest",
			"instanceColor", "instancePhase", "visibilityRangeEnd"]:
		if not resolvers.get(name, Callable()).is_valid():
			return false
	return true


static func _valid_digest(value: String) -> bool:
	return value.length() == 64 and value.is_valid_hex_number(false)


static func _resolve_mesh(detail_type: String, resolvers: Dictionary) -> Dictionary:
	var mesh_value: Variant = _call(resolvers.mesh, [detail_type])
	if not mesh_value is Mesh:
		return {"status": "failed", "reason": "detail_mesh_unavailable"}
	return {"status": "ready", "mesh": mesh_value}


static func _call(resolver: Callable, arguments: Array) -> Variant:
	if not resolver.is_valid():
		return null
	return resolver.callv(arguments)


static func _canonicalize(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var sorted: Dictionary = {}
		for key: Variant in keys:
			sorted[key] = _canonicalize(value[key])
		return sorted
	if value is Array:
		var items: Array = []
		for item: Variant in value:
			items.append(_canonicalize(item))
		return items
	return value


static func _result(status: String, reason: String, rows: Array, digest: String) -> Dictionary:
	return {"status": status, "reason": reason, "schema": SCHEMA,
		"rows": rows, "sourceManifestDigest": digest}
