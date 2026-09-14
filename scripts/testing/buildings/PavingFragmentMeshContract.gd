extends "res://scripts/testing/buildings/ConvexFootingApertureContract.gd"

## CPU mesh/shader-input contract, never screenshot or game acceptance.
const Prepare = preload("res://scripts/buildings/PavingFragmentMesh.gd")
const Artifact = preload("res://scripts/buildings/PavingConstructionArtifact.gd")
const CpuPublication = preload("res://scripts/testing/buildings/CitadelMarketPublishedOverlapContract.gd")


func _run() -> void:
	var output := OS.get_environment("VOXEL_PAVING_FRAGMENT_REPORT")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	var unit_arrays: Array = unit.surface_get_arrays(0)
	var template_rows: Array = []
	for index in range(mini(32, unit_arrays[Mesh.ARRAY_VERTEX].size())):
		template_rows.append({"position": str(unit_arrays[Mesh.ARRAY_VERTEX][index]), "normal": str(unit_arrays[Mesh.ARRAY_NORMAL][index]), "uv": str(unit_arrays[Mesh.ARRAY_TEX_UV][index]), "tangent": Array(unit_arrays[Mesh.ARRAY_TANGENT].slice(index * 4, index * 4 + 4))})
	var cases: Array = []
	var finalize_value_parity_rows: Array = []
	for mode in ["axis_stone", "tilted_stone", "distinct_parent_and_local", "null_custom_bed"]:
		var rotation := Vector3.ZERO if mode in ["axis_stone", "null_custom_bed"] else Vector3(0.12, 0.32, -0.18)
		var local := Transform3D(Basis.from_euler(rotation).scaled(Vector3(2, 1.5, 2.4)), Vector3.ZERO)
		var parent := Transform3D(Basis(Vector3.UP, 0.41), Vector3(5.3, 1.1, -3.2)) if mode == "distinct_parent_and_local" else Transform3D.IDENTITY
		var transform := parent * local
		var original := _solid("test_stone", transform, mode == "null_custom_bed")
		original["localTransform"] = local
		var cuts: Array[AABB] = [AABB(transform.origin + Vector3(0, -4, -4), Vector3(4, 8, 8))]
		var construction: Dictionary = Cut.subtract_boxes([original], cuts)
		var row := {"mode": mode, "constructionCompleted": construction.completed, "reason": construction.get("reason", ""), "passed": false}
		if construction.completed:
			var entry: Dictionary = construction.entries[0]
			var prepared: Dictionary = Prepare.prepare(entry, unit)
			var value_prepared: Dictionary = Prepare.prepare_arrays(entry, unit_arrays)
			var payload_result: Dictionary = Prepare.packet_payload(value_prepared.get("arrays",[])) if value_prepared.get("ready",false) and value_prepared.get("arrays")!=null else {"ready":false}
			var hydrated: Dictionary = Prepare.hydrate_packet_payload(payload_result.get("payload",{})) if payload_result.get("ready",false) else {"ready":false}
			row["preparationReady"] = prepared.ready
			row["reason"] = prepared.get("reason", "")
			row["valuePreparationReady"] = value_prepared.ready
			row["packetPayloadReady"] = payload_result.get("ready",false) and payload_result.payload.is_read_only()
			row["packetHydrationReady"] = hydrated.get("ready",false)
			var rendered_arrays: Array = prepared.mesh.surface_get_arrays(0) if prepared.ready and prepared.mesh != null else []
			# ArrayMesh readback is engine-packed for normals/tangents. The exact
			# transport value is the typed input array; compare position identity and
			# all attribute cardinalities, not packed readback bytes.
			row["valueArraysMatchMainThreadMesh"] = value_prepared.ready and prepared.ready and value_prepared.arrays != null \
				and value_prepared.arrays[Mesh.ARRAY_VERTEX]==rendered_arrays[Mesh.ARRAY_VERTEX] \
				and value_prepared.arrays[Mesh.ARRAY_NORMAL].size()==rendered_arrays[Mesh.ARRAY_NORMAL].size() \
				and value_prepared.arrays[Mesh.ARRAY_TEX_UV].size()==rendered_arrays[Mesh.ARRAY_TEX_UV].size() \
				and value_prepared.arrays[Mesh.ARRAY_TANGENT].size()==rendered_arrays[Mesh.ARRAY_TANGENT].size()
			row["hydratedVerticesMatchValue"] = hydrated.get("ready",false) \
				and hydrated.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]==value_prepared.arrays[Mesh.ARRAY_VERTEX]
			var artifact_construction: Dictionary = construction.duplicate(true)
			artifact_construction["sourceTransform"] = parent
			artifact_construction["constructionDigest"] = "synthetic_fragment_contract:" + mode
			artifact_construction["descriptorDigest"] = "synthetic_fragment_descriptor:" + mode
			artifact_construction["canonicalApertures"] = construction.canonicalApertures.duplicate(true)
			var finalize_value_parity := _finalize_value_parity(artifact_construction, unit_arrays, unit)
			row["finalizeValueParity"] = finalize_value_parity
			finalize_value_parity_rows.append({"mode": mode, "passed": finalize_value_parity.passed, "checks": finalize_value_parity.checks})
			if prepared.ready and prepared.mesh != null:
				row.merge(_inspect_mesh(entry, prepared, cuts, unit, parent), true)
				row["passed"] = row.passed and row.valueArraysMatchMainThreadMesh and row.packetPayloadReady and row.packetHydrationReady and row.hydratedVerticesMatchValue and finalize_value_parity.passed
		cases.append(row)
	var negative_cases := _mesh_negative_controls(unit)
	var native := {"unchanged": true, "original": {}, "cells": []}
	var rejects_native: bool = not Prepare.prepare(native, unit).ready
	var report := {"passed": cases.all(func(row): return row.passed) and rejects_native and negative_cases.all(func(row): return row.passed),
		"evidenceLevel": "synthetic_CPU_fragment_mesh_and_instance_shader_inputs", "cases": cases,
		"finalizeValueParity": {"passed": finalize_value_parity_rows.all(func(row): return row.passed), "rows": finalize_value_parity_rows,
			"scope": "Value finalization packet identity and legacy hydration parity; no publication or gameplay acceptance."},
		"negativeCases": negative_cases,
		"unitTemplate": {"vertexCount": unit_arrays[Mesh.ARRAY_VERTEX].size(), "normalCount": unit_arrays[Mesh.ARRAY_NORMAL].size(), "uvCount": unit_arrays[Mesh.ARRAY_TEX_UV].size(), "tangentCount": unit_arrays[Mesh.ARRAY_TANGENT].size(), "rows": template_rows},
		"rejectsNativePathReplacement": rejects_native,
		"doesNotProve": "No production publication, GPU image, cut-edge lighting/shadows, actual civic paving, support placement or physical-gate acceptance."}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if report.passed else 2)


func _finalize_value_parity(construction: Dictionary, unit_arrays: Array, unit: BoxMesh) -> Dictionary:
	var value: Dictionary = Artifact.finalize_value(construction, unit_arrays)
	var legacy: Dictionary = Artifact.finalize(construction, unit)
	var checks := {"value_completed": value.get("completed", false), "legacy_completed": legacy.get("completed", false),
		"value_contains_no_object_or_resource": not _contains_object(value), "matching_geometry_digest": false,
		"matching_counts": false, "matching_cells_after_ignoring_mesh_transport": false,
		"changed_entries_have_sealed_valid_payloads": false, "value_clear_of_remote_box": false,
		"legacy_clear_of_remote_box": false, "matching_value_and_legacy_clearance": false}
	if checks.value_completed and checks.legacy_completed:
		checks.matching_geometry_digest = value.geometryDigest == legacy.geometryDigest
		checks.matching_counts = value.vertexCount == legacy.vertexCount and value.changedSolidCount == legacy.changedSolidCount
		checks.matching_cells_after_ignoring_mesh_transport = var_to_bytes(_without_mesh_transport(value.entries)) == var_to_bytes(_without_mesh_transport(legacy.entries))
		var payloads_valid := true
		for entry in value.entries:
			if entry.get("unchanged", true):
				continue
			var payload: Variant = entry.get("meshPayload")
			var payload_check := Prepare.validate_packet_payload(payload) if payload is Dictionary else {"ready": false}
			payloads_valid = payloads_valid and payload is Dictionary and payload.is_read_only() and payload_check.ready and payload.vertexDigest == entry.meshVertexDigest
		checks.changed_entries_have_sealed_valid_payloads = payloads_valid
		var remote_boxes: Array[AABB] = [AABB(Vector3(10000.0, 10000.0, 10000.0), Vector3.ONE)]
		var value_cleared: Dictionary = Artifact.clear_of_boxes_value(value, remote_boxes)
		var legacy_cleared: Dictionary = Artifact.clear_of_boxes(legacy, remote_boxes)
		checks.value_clear_of_remote_box = value_cleared.get("completed", false) and value_cleared.get("clear", false)
		checks.legacy_clear_of_remote_box = legacy_cleared.get("completed", false) and legacy_cleared.get("clear", false)
		checks.matching_value_and_legacy_clearance = var_to_bytes(value_cleared) == var_to_bytes(legacy_cleared)
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks,
		"valueReason": value.get("reason", ""), "legacyReason": legacy.get("reason", "")}


func _without_mesh_transport(entries: Array) -> Array:
	var result: Array = []
	for source in entries:
		var entry: Dictionary = source.duplicate(true)
		entry.erase("mesh")
		entry.erase("meshPayload")
		result.append(entry)
	return result


func _contains_object(value: Variant) -> bool:
	if value is Object:
		return true
	if value is Dictionary:
		for key in value:
			if _contains_object(key) or _contains_object(value[key]):
				return true
	elif value is Array:
		for item in value:
			if _contains_object(item):
				return true
	return false


func _inspect_mesh(entry: Dictionary, prepared: Dictionary, cuts: Array[AABB], unit: BoxMesh, parent: Transform3D) -> Dictionary:
	var original: Dictionary = entry.original
	var arrays: Array = prepared.mesh.surface_get_arrays(0)
	var template: Array = unit.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var checks := {"original_descriptor_exact": var_to_bytes(original) == var_to_bytes(prepared.original),
		"triangle_count_and_attributes": vertices.size() > 0 and vertices.size() % 3 == 0 and vertices.size() == normals.size() and vertices.size() == uvs.size() and vertices.size() * 4 == tangents.size(),
		"outward_clockwise_faces": true, "retained_corner_attributes": true, "interpolated_attributes": true, "represented_solid_proof": false,
		"submitted_instance_transform_exact": false, "submitted_instance_custom_exact": false, "parent_local_world_exact": false}
	var represented: Dictionary = entry.duplicate(true)
	for cell in represented.cells: cell.faces = []
	var corner_count := 0
	var interpolated_count := 0
	var maximum_uv_error := 0.0
	for face in prepared.faceProvenance:
		for index in range(face.firstVertex, face.firstVertex + face.vertexCount, 3):
			var local := PackedVector3Array([vertices[index], vertices[index + 2], vertices[index + 1]])
			var world := PackedVector3Array()
			for point in local: world.append(original.transform * point)
			var area: Vector3 = (world[1] - world[0]).cross(world[2] - world[0])
			var normal: Vector3 = (original.transform.basis.inverse().transposed() * normals[index]).normalized()
			checks.outward_clockwise_faces = checks.outward_clockwise_faces and area.dot(normal) > 0.0
			represented.cells[face.cellIndex].faces.append({"worldVertices": world, "localVertices": local, "normal": area.normalized(), "provenance": face.source})
		if face.source.kind != "original_face": continue
		for index in range(face.firstVertex, face.firstVertex + face.vertexCount):
			var attributes := _independent_face_attributes(vertices[index], face.source.faceIndex, template)
			if attributes.is_empty():
				checks.interpolated_attributes = false
			else:
				var uv_error: float = uvs[index].distance_to(attributes.uv)
				maximum_uv_error = maxf(maximum_uv_error, uv_error)
				checks.interpolated_attributes = checks.interpolated_attributes and uv_error <= 0.000001 and normals[index] == attributes.normal
				for component in range(4): checks.interpolated_attributes = checks.interpolated_attributes and tangents[index * 4 + component] == attributes.tangent[component]
				if not attributes.corner: interpolated_count += 1
			for template_index in range(template[Mesh.ARRAY_VERTEX].size()):
				if vertices[index] != template[Mesh.ARRAY_VERTEX][template_index] or normals[index] != template[Mesh.ARRAY_NORMAL][template_index]: continue
				corner_count += 1
				checks.retained_corner_attributes = checks.retained_corner_attributes and uvs[index] == template[Mesh.ARRAY_TEX_UV][template_index]
				for component in range(4):
					checks.retained_corner_attributes = checks.retained_corner_attributes and tangents[index * 4 + component] == template[Mesh.ARRAY_TANGENT][template_index * 4 + component]
	var proof: Dictionary = _entry_proof(represented, original, cuts)
	checks.represented_solid_proof = proof.passed
	var readback: Dictionary = {"status": "not_applicable_plain_bed_instance"}
	if original.customData == null:
		# Ordinary non-batched bed has no per-instance custom override. Keep that
		# path explicit; this does not certify the separate static batching path.
		var instance := MeshInstance3D.new()
		instance.mesh = prepared.mesh
		instance.transform = original.localTransform
		checks.submitted_instance_transform_exact = instance.transform == original.localTransform
		checks.submitted_instance_custom_exact = prepared.original.customData == null and instance.get_class() == "MeshInstance3D"
		checks.parent_local_world_exact = parent * instance.transform == original.transform
		instance.free()
	else:
		# Direct-helper SYNTHETIC CPU submission, using the existing intercept
		# before unchanged super. Getter failures remain explicit and cannot
		# become GPU acceptance or be used as source geometry.
		var publisher := CpuPublication.CpuMeshBatchPublisher.new()
		var node := Node3D.new()
		node.transform = parent
		var material: Material = publisher.material_for_id("cobblestone", 0.0)
		var instance: MultiMeshInstance3D = publisher.add_mesh_batch(node, prepared.mesh, [original.localTransform], material, "SyntheticCutSubmission", [original.customData])
		var capture: Dictionary = publisher.captured_mesh_batches[instance.get_instance_id()]
		checks.submitted_instance_transform_exact = capture.transforms == [original.localTransform] and capture.mesh == prepared.mesh and instance.get_parent() == node
		checks.submitted_instance_custom_exact = capture.customDataOverride == [original.customData] and capture.material == material
		checks.parent_local_world_exact = parent * capture.transforms[0] == original.transform
		readback = {"status": "observed_not_acceptance", "transformMatches": instance.multimesh.get_instance_transform(0) == original.localTransform,
			"customMatches": instance.multimesh.get_instance_custom_data(0) == original.customData,
			"doesNotProve": "CPU submission does not establish GPU storage, shader invocation or rendered appearance; mismatched getters are not silently accepted as renderer proof."}
		node.free()
	return {"passed": interpolated_count > 0 and checks.values().all(func(value): return value == true), "checks": checks,
		"retainedCornerChecks": corner_count, "interpolatedChecks": interpolated_count, "maximumUvError": maximum_uv_error,
		"vertices": vertices.size(), "representedGeometry": proof, "rendererReadback": readback}


func _independent_face_attributes(point: Vector3, face_index: int, template: Array) -> Dictionary:
	var axis: int = face_index / 2
	var normal := Vector3.ZERO
	normal[axis] = -1.0 if face_index % 2 == 0 else 1.0
	var indices: Array = []
	var positions: PackedVector3Array = template[Mesh.ARRAY_VERTEX]
	for index in range(positions.size()):
		if positions[index][axis] == normal[axis] * 0.5 and template[Mesh.ARRAY_NORMAL][index].dot(normal) > 0.99: indices.append(index)
	if indices.size() != 4: return {}
	# Independent affine UV derivative from actual template edges (not the
	# implementation's four-corner bilinear weighting).
	var first: int = indices[0]
	var p0: Vector3 = positions[first]
	var u: int = (axis + 1) % 3
	var v: int = (axis + 2) % 3
	var du := Vector2.ZERO
	var dv := Vector2.ZERO
	var corner := false
	for index in indices:
		var p: Vector3 = positions[index]
		corner = corner or p == point
		if p[u] != p0[u] and p[v] == p0[v]: du = (template[Mesh.ARRAY_TEX_UV][index] - template[Mesh.ARRAY_TEX_UV][first]) / (p[u] - p0[u])
		if p[v] != p0[v] and p[u] == p0[u]: dv = (template[Mesh.ARRAY_TEX_UV][index] - template[Mesh.ARRAY_TEX_UV][first]) / (p[v] - p0[v])
	return {"uv": template[Mesh.ARRAY_TEX_UV][first] + du * (point[u] - p0[u]) + dv * (point[v] - p0[v]), "normal": template[Mesh.ARRAY_NORMAL][first],
		"tangent": template[Mesh.ARRAY_TANGENT].slice(first * 4, first * 4 + 4), "corner": corner}


func _mesh_negative_controls(unit: BoxMesh) -> Array:
	var original := _solid("control", Transform3D.IDENTITY)
	original["localTransform"] = Transform3D.IDENTITY
	var result: Dictionary = Cut.subtract_boxes([original], [AABB(Vector3(0, -1, -1), Vector3(1, 2, 2))])
	if not result.completed: return [{"passed": false, "reason": "negative_control_setup_failed"}]
	var rows: Array = []
	for mode in ["null_cell", "null_face", "nonfinite_world_frame", "singular_local_frame", "collinear_fan_triangle"]:
		var entry: Dictionary = result.entries[0].duplicate(true)
		match mode:
			"null_cell": entry.cells[0] = null
			"null_face": entry.cells[0].faces[0] = null
			"nonfinite_world_frame": entry.original.transform.origin.x = NAN
			"singular_local_frame": entry.original.localTransform.basis = Basis.from_scale(Vector3(0, 1, 1))
			"collinear_fan_triangle":
				var vertices: PackedVector3Array = entry.cells[0].faces[0].localVertices
				vertices.insert(1, (vertices[0] + vertices[1]) * 0.5)
				entry.cells[0].faces[0].localVertices = vertices
				var world: PackedVector3Array = entry.cells[0].faces[0].worldVertices
				world.insert(1, (world[0] + world[1]) * 0.5)
				entry.cells[0].faces[0].worldVertices = world
		var before := var_to_bytes(entry)
		var prepared: Dictionary = Prepare.prepare(entry, unit)
		var expected := "invalid_original_mesh_frame" if mode in ["nonfinite_world_frame", "singular_local_frame"] else ("invalid_convex_cell" if mode == "null_cell" else ("invalid_convex_face" if mode == "null_face" else "degenerate_fragment_triangle"))
		rows.append({"mode": mode, "passed": not prepared.ready and not prepared.has("mesh") and before == var_to_bytes(entry) and prepared.reason == expected, "reason": prepared.get("reason", ""), "expectedReason": expected})
	return rows
