extends "res://scripts/testing/buildings/PavingConstructionArtifactContract.gd"

## Actual-source construction/publication-PAYLOAD contract. No scene acceptance.
const FootCuts = preload("res://scripts/buildings/PavingFootingCutRecipe.gd")


func _run() -> void:
	var output := OS.get_environment("VOXEL_PAVING_FOOTING_PUBLICATION_REPORT")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var report := _inspect_publication()
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report["evidenceLevel"] = "actual_source_represented_mesh_cells_and_real_proposed_foot_clearance_CPU_contract"
	report["doesNotProve"] = "No accepted complete frame placement, structural support gate, GPU storage/shader execution, lighting/shadows, headed appearance, navigation or gameplay. Ideal cut-plane deviations remain explicit diagnostics; nominal joint width is not measured clearance."
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if report.get("passed", false) else 2)


func _inspect_publication() -> Dictionary:
	var source := _bound_read("VOXEL_PAVING_ARTIFACT_SOURCE", WHOLE08_SHA, 33554432)
	if not source.completed: return source
	var diagnosis := _bound_read("VOXEL_PAVING_ARTIFACT_DIAGNOSIS", DIAG02_SHA, 2097152)
	if not diagnosis.completed: return diagnosis
	var archive: Dictionary = bytes_to_var(source.bytes)
	var diag: Dictionary = JSON.parse_string(diagnosis.bytes.get_string_from_utf8())
	if _archive_digest(archive.beforeSnapshot) != archive.sourceDigest: return {"reason": "invalid_source_digest"}
	var b = FacadeSource.copy_blueprint(archive.beforeSnapshot)
	var proposal: Dictionary = _diagnosed_proposal(b, diag)
	if not proposal.completed: return proposal
	var source_before := var_to_bytes(b.snapshot())
	var furniture_before := var_to_bytes(archive.furnitureSnapshot)
	var publisher := CpuContract.CpuMeshBatchPublisher.new()
	publisher.source_blueprint_id = publisher.canonical_source_blueprint_id(b)
	publisher.surface_history.configure(b.recipe, b.parts)
	var history_before := _paving_history_digest(publisher.surface_history)
	var described: Dictionary = PavingGeometry.describe_source(proposal.part, publisher.surface_history, publisher.source_blueprint_id)
	var descriptor_before := var_to_bytes(described)
	var transform: Transform3D = b.part_transform(proposal.part)
	var cuts: Dictionary = FootCuts.derive(described, transform, proposal.apertures, FacadeSource.CLEARANCE)
	if not cuts.completed: return {"reason": "cut_recipe_failed", "cutResult": cuts}
	var construction: Dictionary = Artifact.compile(described, transform, cuts.apertures, COMPILE_LIMITS)
	if not construction.completed: return {"reason": "construction_failed", "construction": construction}
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	var final: Dictionary = Artifact.finalize(construction, unit)
	if not final.completed: return {"reason": "finalization_failed", "finalization": final}
	var clearance: Dictionary = Artifact.clear_of_boxes(final, proposal.apertures)
	var checks := {"real_feet_strictly_clear": clearance.completed and clearance.get("clear", false),
		"native_entries_byte_exact": true, "original_payloads_exact": true, "local_containment_exact": true,
		"retained_original_face_planes_exact": true, "retained_original_corners_exact": true,
		"independent_actual_vertex_clearance": true, "mesh_and_source_cells_match": true}
	var changed: Array = []
	var minimum_independent_gap := INF
	for index in range(final.entries.size()):
		var entry: Dictionary = final.entries[index]
		var original: Dictionary = entry.original
		var payload: Dictionary = _independent_mesh_cells(entry, transform, unit)
		checks.mesh_and_source_cells_match = checks.mesh_and_source_cells_match and payload.matched
		checks.original_payloads_exact = checks.original_payloads_exact and var_to_bytes(original) == var_to_bytes(construction.entries[index].original)
		if entry.unchanged:
			checks.native_entries_byte_exact = checks.native_entries_byte_exact and var_to_bytes(entry) == var_to_bytes(construction.entries[index])
		else:
			changed.append({"id": original.id, "cellCount": entry.cells.size(), "vertexCount": entry.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if entry.mesh != null else 0})
			var retained: Array[Vector3] = []
			for cell in entry.cells:
				for face in cell.faces:
					for local in face.localVertices:
						checks.local_containment_exact = checks.local_containment_exact and absf(local.x) <= 0.5 and absf(local.y) <= 0.5 and absf(local.z) <= 0.5
						retained.append(local)
						if face.provenance.kind == "original_face":
							var axis: int = face.provenance.faceIndex / 2
							var coordinate := -0.5 if face.provenance.faceIndex % 2 == 0 else 0.5
							checks.retained_original_face_planes_exact = checks.retained_original_face_planes_exact and local[axis] == coordinate
			for local in _box_faces(Transform3D.IDENTITY).vertices:
				var point: Vector3 = original.transform * local
				var removed := false
				for cut in cuts.apertures:
					removed = removed or (point.x >= cut.position.x and point.x <= cut.end.x and point.y >= cut.position.y and point.y <= cut.end.y and point.z >= cut.position.z and point.z <= cut.end.z)
				if not removed: checks.retained_original_corners_exact = checks.retained_original_corners_exact and retained.has(local)
		for points in payload.cells:
			# Read actual mesh ARRAY_VERTEX and compose parent/instance matrices
			# independently. Never measure clearance from finalized source cells.
			var lo := Vector3(INF, INF, INF)
			var hi := Vector3(-INF, -INF, -INF)
			for point in points:
				lo = lo.min(point)
				hi = hi.max(point)
			for foot in proposal.apertures:
				var gap := -INF
				for axis in range(3): gap = maxf(gap, maxf(float(foot.position[axis]) - float(hi[axis]), float(lo[axis]) - float(foot.end[axis])))
				checks.independent_actual_vertex_clearance = checks.independent_actual_vertex_clearance and gap > 0.0
				minimum_independent_gap = minf(minimum_independent_gap, gap)
	var repeated: Dictionary = Artifact.finalize(construction, unit)
	checks["deterministic_represented_geometry"] = repeated.completed and repeated.geometryDigest == final.geometryDigest
	var negatives: Array = []
	# Real uncut and partially-cut geometry intrudes into the requested feet.
	# Finalize each through the same mesh path; no forged bounds/metadata proof.
	for mode in ["uncut_intrusion", "second_foot_uncut"]:
		var bad_cuts: Array[AABB] = []
		if mode == "second_foot_uncut": bad_cuts.append(cuts.apertures[0])
		var candidate: Dictionary = Artifact.compile(described, transform, bad_cuts, COMPILE_LIMITS)
		var bad: Dictionary = Artifact.finalize(candidate, unit) if candidate.completed else {"completed": false}
		var query: Dictionary = Artifact.clear_of_boxes(bad, proposal.apertures) if bad.completed else {"completed": false}
		negatives.append({"mode": mode, "passed": candidate.completed and bad.completed and query.completed and not query.clear, "query": query})
	var native_index := -1
	for index in range(construction.entries.size()):
		if construction.entries[index].unchanged:
			native_index = index
			break
	for mode in ["null_convex_cell", "shrunk_native_bounds", "mismatched_instance_frame", "consistently_collapsed_native"]:
		var forged: Dictionary = construction.duplicate(true)
		match mode:
			"null_convex_cell": forged.entries[0].cells[0] = null
			"shrunk_native_bounds": forged.entries[native_index].cells[0].bounds.size.x *= 0.5
			"mismatched_instance_frame": forged.entries[0].original.localTransform.origin.x += 0.01
			"consistently_collapsed_native":
				var local := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
				var world := transform * local
				forged.entries[native_index].original.localTransform = local
				forged.entries[native_index].original.transform = world
				forged.entries[native_index].cells[0].transform = world
				forged.entries[native_index].cells[0].bounds = AABB(world.origin, Vector3.ZERO)
		var rejected: Dictionary = Artifact.finalize(forged, unit)
		negatives.append({"mode": mode, "passed": not rejected.completed and not rejected.has("entries"), "reason": rejected.get("reason", "")})
	var forged_mesh: Dictionary = final.duplicate(true)
	var changed_entry: Dictionary = forged_mesh.entries[0]
	var arrays: Array = changed_entry.mesh.surface_get_arrays(0)
	var forged_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX].duplicate()
	forged_vertices[0] = (transform * changed_entry.original.localTransform).affine_inverse() * proposal.apertures[0].get_center()
	arrays[Mesh.ARRAY_VERTEX] = forged_vertices
	var intrusion := ArrayMesh.new()
	intrusion.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	changed_entry.mesh = intrusion
	var mismatch: Dictionary = _independent_mesh_cells(changed_entry, transform, unit)
	var forged_query: Dictionary = Artifact.clear_of_boxes(forged_mesh, proposal.apertures)
	negatives.append({"mode": "mesh_only_intrusion_source_cells_unchanged", "passed": not mismatch.matched and not forged_query.completed and forged_query.get("reason") == "prepared_mesh_changed_after_finalization", "query": forged_query})
	# Explicit isolated-cell synthetic query control, drawn from a real native
	# descriptor. Exact envelope contact and represented positive overlap must
	# remain unproven, never become a small-overlap clearance allowance.
	var isolated: Dictionary = final.duplicate()
	isolated.entries = [final.entries[native_index]]
	var occupied: AABB = isolated.entries[0].cells[0].bounds
	for depth in [0.0, 0.00002]:
		var contact := AABB(Vector3(occupied.end.x - depth, occupied.position.y, occupied.position.z), Vector3(0.36, 0.20, 0.36))
		var query: Dictionary = Artifact.clear_of_boxes(isolated, [contact])
		negatives.append({"mode": "isolated_native_envelope_contact_or_intrusion", "requestedDepth": depth,
			"passed": query.completed and not query.clear and query.signedAxisGap <= 0.0, "query": query})
	var preserved := {"source": source_before == var_to_bytes(b.snapshot()), "furniture": furniture_before == var_to_bytes(archive.furnitureSnapshot),
		"history": history_before == _paving_history_digest(publisher.surface_history), "descriptor": descriptor_before == var_to_bytes(described),
		"sourceFile": FileAccess.get_sha256(source.path) == source.sha256, "diagnosisFile": FileAccess.get_sha256(diagnosis.path) == diagnosis.sha256}
	return {"passed": checks.values().all(func(value): return value == true) and negatives.all(func(row): return row.passed) and preserved.values().all(func(value): return value == true),
		"checks": checks, "preservation": preserved, "negativeCases": negatives, "clearance": clearance,
		"minimumIndependentAxisGap": minimum_independent_gap, "nominalJointWidth": FacadeSource.CLEARANCE,
		"changedSolids": changed, "sourceSolidCount": final.entries.size(), "furnitureCount": archive.furnitureSnapshot.parts.size(),
		"representedGeometryDigest": final.geometryDigest, "idealPlaneDiagnostics": final.idealPlaneDiagnostics, "proposal": proposal.report}


func _independent_mesh_cells(entry: Dictionary, parent: Transform3D, unit: BoxMesh) -> Dictionary:
	var model: Transform3D = parent * entry.original.localTransform
	var cells: Array = []
	if entry.unchanged:
		var points := PackedVector3Array()
		for vertex in unit.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]: points.append(model * vertex)
		return {"matched": model == entry.original.transform and entry.cells.size() == 1 and entry.cells[0].transform == model, "cells": [points]}
	for cell in entry.cells: cells.append(PackedVector3Array())
	if entry.mesh != null:
		var vertices: PackedVector3Array = entry.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for face in entry.faceProvenance:
			for index in range(face.firstVertex, face.firstVertex + face.vertexCount, 3):
				for corner in [index, index + 2, index + 1]: cells[face.cellIndex].append(model * vertices[corner])
	var matched: bool = model == entry.original.transform
	for index in range(entry.cells.size()):
		var from_source := PackedVector3Array()
		for face in entry.cells[index].faces: from_source.append_array(face.worldVertices)
		matched = matched and from_source == cells[index]
	return {"matched": matched, "cells": cells}
