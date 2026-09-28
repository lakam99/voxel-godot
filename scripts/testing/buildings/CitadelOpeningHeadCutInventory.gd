extends RefCounted

## Inspection inventory only. Preserves actual artifact objects; no mesh creation,
## source repair, triangle/ray proof, rendering or acceptance claim.
const Preparation = preload("res://scripts/testing/buildings/CitadelOpeningHeadVisualPreparation.gd")
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_SOURCE_PARTS := 10000
const MAX_PARTS := 512
const MAX_ENTRIES := 65536
const MAX_MASONRY_ENTRIES := 8192
const MAX_MESHES := 4096
const MAX_VERTICES := 600000
const MAX_CELLS := 32768

static func collect(publisher: Variant) -> Dictionary:
	if not is_instance_valid(publisher): return _fail("missing_publisher")
	var job: Variant = publisher._masonry_preparation
	if not is_instance_valid(job) or job.state != "ready" or not is_instance_valid(job._blueprint): return _fail("masonry_not_ready")
	var source: Variant = job._blueprint
	if source.parts.is_empty() or source.parts.size() > MAX_SOURCE_PARTS: return _fail("source_limit")
	var by_id: Dictionary = {}
	var required: Dictionary = {}
	for value: Variant in source.parts:
		if not value is Part: return _fail("invalid_source_part")
		var part: Part = value
		if part.id.is_empty() or by_id.has(part.id): return _fail("duplicate_source_id")
		by_id[part.id] = part
		if part.recipe.has("masonryApertureSource"): required[part.id] = part
	if required.size() > MAX_PARTS or not _same_keys(required, job._artifacts) or not _same_keys(required, job._marked): return _fail("masonry_source_artifact_membership")
	if job._requests.size() != required.size(): return _fail("masonry_request_membership")
	if not required.is_empty() and (source.parts != job._source_order or source.parts.size() != job._source_count): return _fail("stale_source_order")
	if job.context_binding(publisher) != job._context: return _fail("stale_publication_context")
	var requests: Dictionary = {}
	var declarations: Dictionary = {}
	for value: Variant in job._requests:
		if not value is Dictionary: return _fail("malformed_request")
		var request: Dictionary = value
		var part: Variant = request.get("part")
		if not part is Part or required.get(part.id) != part or requests.has(part.id) or job._marked.get(part.id) != part: return _fail("foreign_or_duplicate_request")
		var key: Variant = part.recipe.get("masonryApertureSource")
		if not key is String or key.is_empty() or request.get("key") != key or part.kind != "wall" or not Materials.is_masonry_material(part.material_id) or part.recipe.get("visual", true) != true: return _fail("invalid_marked_masonry")
		if not source.recipe.get("facadeApertures") is Dictionary: return _fail("missing_declarations")
		var declaration: Variant = source.recipe.facadeApertures.get(key)
		if not declaration is Dictionary or declaration.get("producerPrefix") != key or not declaration.get("partIds") is Array or not declaration.partIds.has(part.id): return _fail("unbound_declaration")
		if var_to_bytes(declaration) != request.get("record") or var_to_bytes(part.snapshot()) != request.get("source"): return _fail("stale_request")
		if not declarations.has(key):
			if not Aperture.validate(declaration, by_id): return _fail("invalid_declaration_binding")
			declarations[key] = true
		requests[part.id] = request
	if not _same_keys(declarations, job._declarations): return _fail("orphan_declaration")
	var state: Dictionary = {"entries": [], "resources": {}, "ids": {}, "vertices": 0, "triangleVertices": 0, "cells": 0, "visited": 0}
	# Validate layouts before calling the existing paving identity reader, which
	# expects prepared artifact dictionaries rather than arbitrary Variant input.
	if not publisher._paving_artifacts is Dictionary or publisher._paving_artifacts.size() > publisher.MAX_JOINTED_FINISHES: return _fail("paving_part_limit")
	var paving_ids: Array = publisher._paving_artifacts.keys()
	paving_ids.sort()
	for id: Variant in paving_ids:
		if not id is String or not by_id.has(id): return _fail("foreign_paving_part")
		var wrapper: Variant = publisher._paving_artifacts[id]
		if not wrapper is Dictionary or not wrapper.get("artifact") is Dictionary: return _fail("malformed_paving_artifact")
		var artifact: Dictionary = wrapper.artifact
		if artifact.get("completed") != true or artifact.get("stage") != "represented_publication_geometry" or not _entries_valid(artifact.get("entries")): return _fail("paving_not_finalized")
		for value: Variant in artifact.entries:
			var reason: String = _entry(id, value, {}, by_id[id], false, state)
			if not reason.is_empty(): return _fail(reason)
	var paving_proof: Dictionary = Preparation.source_bound_paving_identity(publisher)
	if paving_proof.get("ready") != true: return _fail("paving_source_membership_or_binding")
	var paving_count: int = state.entries.size()
	var masonry_ids: Array = required.keys()
	masonry_ids.sort()
	var brick_count: int = 0
	var changed_count: int = 0
	for id: String in masonry_ids:
		var artifact: Variant = job._artifacts[id]
		if not artifact is Dictionary or not _entries_valid(artifact.get("entries")) or not artifact.get("preparedMeshes") is Dictionary: return _fail("malformed_masonry_artifact")
		brick_count += artifact.entries.size()
		if brick_count > MAX_MASONRY_ENTRIES or artifact.preparedMeshes.size() > artifact.entries.size(): return _fail("masonry_entry_limit")
		var changed: Dictionary = {}
		for value: Variant in artifact.entries:
			var reason: String = _entry(id, value, artifact.preparedMeshes, required[id], true, state)
			if not reason.is_empty(): return _fail(reason)
			if not value.unchanged: changed[value.original.id] = true
		if not _same_keys(changed, artifact.preparedMeshes): return _fail("orphan_prepared_mesh")
		changed_count += changed.size()
	if brick_count != job.metrics.get("bricks") or changed_count != job.metrics.get("changedBricks") or required.size() != job.metrics.get("parts"): return _fail("masonry_inventory_metrics_mismatch")
	if state.entries.is_empty(): return _fail("empty_cut_inventory")
	return {"ready": true, "entries": state.entries, "masonryMeshCount": state.entries.size() - paving_count,
		"pavingMeshCount": paving_count, "reason": ""}

static func _entry(part_id: String, value: Variant, prepared: Dictionary, part: Part, masonry: bool, state: Dictionary) -> String:
	state.visited += 1
	if state.visited > MAX_ENTRIES: return "entry_limit"
	if not value is Dictionary or not value.get("original") is Dictionary or not value.get("unchanged") is bool: return "malformed_entry"
	var entry: Dictionary = value
	var original: Dictionary = entry.original
	var id: Variant = original.get("id")
	if not id is String or id.is_empty(): return "invalid_original_id"
	var identity: Array = [part_id, id]
	if state.ids.has(identity): return "duplicate_original_id"
	state.ids[identity] = true
	if not _frame_valid(original.get("transform")) or not _frame_valid(original.get("localTransform")): return "invalid_original_frame"
	var source_frame := Transform3D(Basis.from_euler(part.rotation), part.position)
	if original.transform != source_frame * original.localTransform: return "original_source_frame_mismatch"
	if entry.unchanged:
		if prepared.has(id) or entry.get("mesh") != null: return "unchanged_has_prepared_mesh"
		return ""
	if not entry.get("cells") is Array or entry.cells.size() > 256: return "invalid_cut_cells"
	state.cells += entry.cells.size()
	if state.cells > MAX_CELLS: return "cell_limit"
	var mesh_value: Variant = entry.get("mesh")
	if masonry:
		var record: Variant = prepared.get(id)
		if not record is Dictionary or record.get("ready") != true or not record.has("mesh") or not record.get("original") is Dictionary: return "missing_ready_prepared_mesh"
		if var_to_bytes(record.original) != var_to_bytes(original): return "prepared_original_mismatch"
		mesh_value = record.mesh
	elif not entry.has("mesh"):
		return "missing_paving_mesh_field"
	if mesh_value == null:
		if masonry and prepared[id].get("vertexCount") != 0: return "null_mesh_vertex_count"
		return "" if entry.cells.is_empty() else "null_mesh_nonempty_cells"
	if entry.cells.is_empty() or not mesh_value is ArrayMesh: return "invalid_cut_mesh"
	var mesh: ArrayMesh = mesh_value
	var resource_id: int = mesh.get_instance_id()
	if state.resources.has(resource_id): return "duplicate_mesh_resource"
	if state.resources.size() >= MAX_MESHES or mesh.get_surface_count() != 1 or mesh.surface_get_primitive_type(0) != Mesh.PRIMITIVE_TRIANGLES: return "mesh_shape_or_count_limit"
	var bounds: AABB = mesh.get_aabb()
	if not bounds.position.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0 or bounds.size.y <= 0 or bounds.size.z <= 0: return "invalid_mesh_bounds"
	var world_bounds: AABB = original.transform * bounds
	if not world_bounds.position.is_finite() or not world_bounds.end.is_finite(): return "invalid_world_bounds"
	var arrays: Array = mesh.surface_get_arrays(0)
	if arrays.size() != Mesh.ARRAY_MAX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array: return "invalid_mesh_arrays"
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	state.vertices += vertices.size()
	if vertices.is_empty() or state.vertices > MAX_VERTICES: return "vertex_limit"
	for vertex: Vector3 in vertices:
		if not vertex.is_finite(): return "nonfinite_mesh_vertex"
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if indices != null and not indices is PackedInt32Array: return "invalid_mesh_indices"
	var indexed: bool = indices is PackedInt32Array and not indices.is_empty()
	var count: int = indices.size() if indexed else vertices.size()
	state.triangleVertices += count
	if count == 0 or count % 3 != 0 or state.triangleVertices > MAX_VERTICES: return "invalid_triangle_count_or_aggregate_limit"
	if indexed:
		for index: int in indices:
			if index < 0 or index >= vertices.size(): return "invalid_mesh_index"
	if masonry and prepared[id].get("vertexCount") != vertices.size(): return "prepared_vertex_count_mismatch"
	state.resources[resource_id] = true
	# Keep these objects, not copies or reconstructed/centred meshes. In particular
	# constructionFrameOrigin is not a publication transform and is never applied.
	state.entries.append({"partId": part_id, "mesh": mesh, "original": original})
	return ""

static func _entries_valid(value: Variant) -> bool:
	return value is Array and not value.is_empty() and value.size() <= MAX_MASONRY_ENTRIES

static func _frame_valid(value: Variant) -> bool:
	if not value is Transform3D or not value.is_finite(): return false
	var frame: Transform3D = value
	var determinant: float = frame.basis.determinant()
	return is_finite(determinant) and determinant != 0.0 and frame.affine_inverse().is_finite()

static func _same_keys(first: Dictionary, second: Dictionary) -> bool:
	if first.size() != second.size(): return false
	for key: Variant in first:
		if not second.has(key): return false
	return true

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "entries": [], "masonryMeshCount": 0, "pavingMeshCount": 0, "reason": reason}
