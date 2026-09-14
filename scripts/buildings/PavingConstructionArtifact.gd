extends RefCounted

## Immutable-by-convention construction value; no rendering or support authority.
## Describe the ORIGINAL finish once, then compile the complete aperture union.
## Source-space convex cells and publication payloads share this one result.
## Native entries retain exact local transforms: never round-trip unchanged
## stones through world coordinates or generate a new paving lattice per hole.
const Cut = preload("res://scripts/buildings/ConvexFootingAperture.gd")
const FragmentMesh = preload("res://scripts/buildings/PavingFragmentMesh.gd")
const MAX_PUBLICATION_VERTICES := 262144


static func finalize(construction: Dictionary, unit_box: BoxMesh) -> Dictionary:
	# Legacy main-thread entry point. Keep its public mesh-bearing result intact;
	# all geometry reasoning now happens in the value-only preparation below.
	var unit_surface_arrays: Array = []
	if _construction_requires_fragment_mesh(construction):
		if unit_box == null or unit_box.size != Vector3.ONE or unit_box.get_surface_count() != 1:
			return _failure("mesh_preparation:invalid_original_mesh_frame")
		unit_surface_arrays = unit_box.surface_get_arrays(0)
	var finalized := finalize_value(construction, unit_surface_arrays)
	if not finalized.completed:
		return finalized
	return hydrate_value(finalized)


## Worker-safe finalization. This produces only typed packet values, never a
## Mesh/ArrayMesh. Legacy callers must hydrate the retained meshPayloads via
## finalize(); future workers may carry this result without Resource values.
static func finalize_value(construction: Dictionary, unit_surface_arrays: Array) -> Dictionary:
	## Final source occupancy is reconstructed from the exact prepared mesh
	## payload, through the retained parent/instance matrix. Ideal clipping
	## planes remain diagnostics, never a second obstacle representation.
	if not construction.get("completed", false) or not construction.get("entries") is Array or construction.entries.is_empty() or construction.entries.size() > Cut.HARD_LIMITS.maxSolids or not construction.get("sourceTransform") is Transform3D or not construction.get("constructionDigest") is String or not construction.get("descriptorDigest") is String or not construction.get("canonicalApertures") is Array:
		return _failure("invalid_construction_to_finalize")
	var entries: Array = []
	var vertex_count := 0
	var changed_count := 0
	var deviations: Array = []
	var ctx := {"work": 0, "error": "", "limits": Cut.HARD_LIMITS.duplicate(), "fragments": 0}
	for entry in construction.entries:
		if not entry is Dictionary or not entry.get("original") is Dictionary or not entry.get("cells") is Array or entry.cells.size() > 256 or not entry.get("unchanged") is bool:
			return _failure("invalid_construction_entry")
		var original: Dictionary = entry.original
		if not original.get("transform") is Transform3D or not original.get("localTransform") is Transform3D or original.transform != construction.sourceTransform * original.localTransform:
			return _failure("inconsistent_construction_instance_frame")
		if not Cut._valid_transform(original.transform) or not Cut._valid_transform(original.localTransform):
			return _failure("invalid_construction_instance_frame")
		if entry.unchanged:
			# Keep native descriptors on the exact ordinary box publication path.
			if entry.cells.size() != 1 or not entry.cells[0] is Dictionary or entry.cells[0].get("representation") != "native_box" or entry.cells[0].get("transform") != original.transform or not entry.cells[0].get("bounds") is AABB:
				return _failure("invalid_native_construction_entry")
			var native_bounds: AABB = Cut._point_bounds(Cut._corners(original.transform), ctx)
			if not ctx.error.is_empty(): return _failure(ctx.error)
			if not Cut._valid_bounds(native_bounds) or entry.cells[0].bounds != native_bounds: return _failure("native_bounds_do_not_enclose_source")
			entries.append(entry.duplicate(true))
			continue
		var prepared: Dictionary = FragmentMesh.prepare_arrays(entry, unit_surface_arrays)
		if not prepared.ready: return _failure("mesh_preparation:" + String(prepared.reason))
		var mesh_payload: Variant = null
		if prepared.arrays != null:
			var packet := FragmentMesh.packet_payload(prepared.arrays)
			if not packet.ready: return _failure("mesh_preparation:" + String(packet.reason))
			mesh_payload = packet.payload
		vertex_count += prepared.vertexCount
		if vertex_count > MAX_PUBLICATION_VERTICES: return _failure("publication_vertex_limit")
		var cells: Array = []
		for ignored in entry.cells: cells.append({"representation": "convex_polyhedron", "faces": []})
		var max_deviation := 0.0
		var outside_original := false
		if prepared.arrays != null:
			var arrays: Array = prepared.arrays
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for face in prepared.faceProvenance:
				for index in range(face.firstVertex, face.firstVertex + face.vertexCount, 3):
					# Restore outward CCW source faces from Godot's CW triangles.
					var local := PackedVector3Array([vertices[index], vertices[index + 2], vertices[index + 1]])
					var world := PackedVector3Array()
					for point in local:
						outside_original = outside_original or absf(point.x) > 0.5 or absf(point.y) > 0.5 or absf(point.z) > 0.5
						var represented: Vector3 = original.transform * point
						if not represented.is_finite(): return _failure("nonfinite_represented_vertex")
						world.append(represented)
						if face.source.kind == "cut_plane":
							var axis: int = face.source.planeIndex / 2
							var plane: float = face.source.aperture.end[axis] if face.source.planeIndex % 2 == 1 else face.source.aperture.position[axis]
							max_deviation = maxf(max_deviation, absf(represented[axis] - plane))
					var normal: Vector3 = (world[1] - world[0]).cross(world[2] - world[0])
					if not normal.is_finite() or normal.length_squared() == 0.0: return _failure("degenerate_represented_triangle")
					cells[face.cellIndex].faces.append({"worldVertices": world, "localVertices": local, "normal": normal.normalized(), "provenance": face.source.duplicate(true)})
		if outside_original: return _failure("represented_local_vertex_outside_original")
		var kept := 0.0
		for cell in cells:
			var points := PackedVector3Array()
			var volume_faces: Array = []
			for face in cell.faces:
				points.append_array(face.worldVertices)
				volume_faces.append({"vertices": face.worldVertices})
			if points.is_empty(): return _failure("empty_represented_cell")
			cell["bounds"] = Cut._point_bounds(points, ctx)
			cell["volume"] = Cut._volume({"faces": volume_faces}, ctx)
			if not ctx.error.is_empty(): return _failure(ctx.error)
			if not is_finite(cell.volume) or cell.volume <= 0.0: return _failure("nonpositive_represented_volume")
			kept += cell.volume
		var output: Dictionary = entry.duplicate(true)
		output["cells"] = cells
		output["meshPayload"] = mesh_payload
		output["meshVertexDigest"] = _digest(prepared.arrays[Mesh.ARRAY_VERTEX]) if prepared.arrays != null else _digest(PackedVector3Array())
		output["faceProvenance"] = prepared.faceProvenance
		output["remainingVolume"] = kept
		output["removedVolume"] = entry.inputVolume - kept
		entries.append(output)
		changed_count += 1
		deviations.append({"id": original.id, "maximumAbsoluteIdealPlaneDeviation": max_deviation,
			"exactIdealPlanes": max_deviation == 0.0, "status": "exact" if max_deviation == 0.0 else "RED_ideal_plane_deviation_not_clearance_acceptance"})
	return {"completed": true, "stage": "represented_publication_geometry", "entries": entries,
		"sourceTransform": construction.sourceTransform, "constructionDigest": construction.constructionDigest,
		"descriptorDigest": construction.descriptorDigest, "canonicalApertures": construction.canonicalApertures.duplicate(),
		"vertexCount": vertex_count, "changedSolidCount": changed_count, "idealPlaneDiagnostics": deviations,
		"work": ctx.work, "geometryDigest": _represented_digest(entries)}


## Main-thread-only compatibility boundary for a completed value artifact.
static func hydrate_value(value_finalized: Dictionary) -> Dictionary:
	# The value result has already validated geometry and packet identity. This
	# is the sole legacy Resource allocation boundary.
	# Do not duplicate packet dictionaries here: packet_payload deliberately
	# freezes them, and hydration validates that frozen identity.
	# Packet values are deeply sealed. Copy only the outer artifact and entries
	# we must augment with a main-thread mesh, preserving each frozen payload for
	# hydrate_packet_payload's identity validation.
	var result: Dictionary = value_finalized.duplicate(false)
	var entries: Array = []
	for source_entry in value_finalized.entries:
		if not source_entry is Dictionary: return _failure("invalid_value_finalized_entry")
		entries.append(source_entry.duplicate(false))
	result["entries"] = entries
	for entry in entries:
		if entry.get("unchanged", true):
			continue
		var payload: Variant = entry.get("meshPayload")
		var mesh: Variant = null
		if payload != null:
			var hydrated := FragmentMesh.hydrate_packet_payload(payload)
			if not hydrated.ready:
				return _failure("mesh_preparation:" + String(hydrated.reason))
			mesh = hydrated.mesh
		entry["mesh"] = mesh
		entry.erase("meshPayload")
	return result


static func _construction_requires_fragment_mesh(construction: Dictionary) -> bool:
	if not construction.get("entries") is Array:
		return false
	for entry in construction.entries:
		if entry is Dictionary and entry.get("unchanged") is bool and not entry.unchanged:
			return true
	return false


static func clear_of_boxes(finalized: Dictionary, boxes: Array[AABB]) -> Dictionary:
	return _clear_of_boxes(finalized, boxes, false)


## Worker-safe clearance proof for finalize_value output. The sealed packet is
## the mesh identity: validate it before trusting the represented cells.
static func clear_of_boxes_value(finalized: Dictionary, boxes: Array[AABB]) -> Dictionary:
	return _clear_of_boxes(finalized, boxes, true)


static func _clear_of_boxes(finalized: Dictionary, boxes: Array[AABB], value_mode: bool) -> Dictionary:
	## Conservative proof only: a strict axis separation proves the actual
	## occupied cell clear. An overlapping envelope is NOT labelled collision
	## or waived; it requires finer proof before the recipe may use the result.
	if not finalized.get("completed", false) or finalized.get("stage") != "represented_publication_geometry" or not finalized.get("entries") is Array or finalized.entries.is_empty() or finalized.entries.size() > Cut.HARD_LIMITS.maxSolids or boxes.is_empty() or boxes.size() > Cut.HARD_LIMITS.maxApertures:
		return _failure("invalid_represented_clearance_query")
	for box in boxes:
		if not Cut._valid_bounds(box): return _failure("invalid_clearance_box")
	var pair_count := 0
	var minimum_gap := INF
	for entry in finalized.entries:
		if not entry is Dictionary or not entry.get("original") is Dictionary or not entry.original.get("id") is String or not entry.get("cells") is Array or entry.cells.size() > 256: return _failure("invalid_clearance_entry")
		# The prepared mesh and obstacle artifact must still be the same value.
		# A mesh-only edit invalidates the artifact instead of leaving a stale
		# clear source envelope in front of a newly intrusive rendered triangle.
		if not entry.get("unchanged", true):
			if not entry.get("meshVertexDigest") is String: return _failure("missing_mesh_vertex_identity")
			if value_mode:
				var payload: Variant = entry.get("meshPayload")
				if payload == null:
					if entry.meshVertexDigest != _digest(PackedVector3Array()): return _failure("prepared_mesh_changed_after_finalization")
				elif not payload is Dictionary:
					return _failure("invalid_fragment_packet_payload")
				else:
					var payload_check := FragmentMesh.validate_packet_payload(payload)
					if not payload_check.ready or payload.vertexDigest != entry.meshVertexDigest:
						return _failure("prepared_mesh_changed_after_finalization")
			else:
				var mesh: Variant = entry.get("mesh")
				if mesh != null and (not mesh is ArrayMesh or mesh.get_surface_count() != 1): return _failure("invalid_prepared_mesh")
				var actual: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] if mesh != null else PackedVector3Array()
				if _digest(actual) != entry.meshVertexDigest: return _failure("prepared_mesh_changed_after_finalization")
		for cell in entry.cells:
			if not cell is Dictionary or not cell.get("bounds") is AABB or not Cut._valid_bounds(cell.bounds): return _failure("invalid_clearance_cell")
			var occupied: AABB = cell.bounds
			for box_index in range(boxes.size()):
				pair_count += 1
				if pair_count > Cut.HARD_LIMITS.maxFragments * Cut.HARD_LIMITS.maxApertures: return _failure("clearance_pair_limit")
				var box: AABB = boxes[box_index]
				var gap := -INF
				for axis in range(3):
					gap = maxf(gap, maxf(float(box.position[axis]) - float(occupied.end[axis]), float(occupied.position[axis]) - float(box.end[axis])))
				if gap <= 0.0:
					return {"completed": true, "clear": false, "reason": "cell_envelope_not_strictly_separated", "solidId": entry.original.id, "boxIndex": box_index, "signedAxisGap": gap, "pairCount": pair_count}
				minimum_gap = minf(minimum_gap, gap)
	return {"completed": true, "clear": true, "pairCount": pair_count, "minimumProvenAxisGap": minimum_gap if pair_count > 0 else null,
		"scope": "strict conservative represented-cell bounds separation; not a Euclidean or nominal joint-width measurement"}


static func _represented_digest(entries: Array) -> String:
	# Resource IDs never contribute to deterministic construction identity.
	var geometry: Array = []
	for entry in entries: geometry.append([entry.original, entry.cells])
	return _digest(geometry)


static func compile(described: Dictionary, part_transform: Transform3D, apertures: Array[AABB], limits: Dictionary = {}) -> Dictionary:
	if described.get("ready") != true or not described.get("bed") is Dictionary:
		return _failure("invalid_paving_descriptor")
	var bed: Dictionary = described.bed
	if not bed.get("size") is Vector3 or not bed.get("position") is Vector3 or not bed.get("materialId") is String:
		return _failure("invalid_bed_descriptor")
	if not bed.size.is_finite() or not bed.position.is_finite() or bed.size.x <= 0.0 or bed.size.y <= 0.0 or bed.size.z <= 0.0 or bed.materialId.is_empty():
		return _failure("invalid_bed_descriptor")
	var count := 1
	for group in ["regular", "worn"]:
		for suffix in ["Transforms", "CustomData", "Ids"]:
			if not described.get(group + suffix) is Array:
				return _failure("invalid_paving_parallel_arrays")
		var transforms: Array = described[group + "Transforms"]
		if transforms.size() != described[group + "CustomData"].size() or transforms.size() != described[group + "Ids"].size():
			return _failure("invalid_paving_parallel_arrays")
		count += transforms.size()
	if count > Cut.HARD_LIMITS.maxSolids:
		return _failure("solid_limit_exceeded")
	# Never allocate a partially publishable artifact. The cutter validates all
	# affine solids, cuts and work limits before returning any output entries.
	var bed_local := Transform3D(Basis.IDENTITY.scaled(bed.size), bed.position)
	var solids: Array = [{"id": "bed", "transform": part_transform * bed_local,
		"materialKey": bed.materialId, "customData": null, "group": "bed",
		"ordinal": 0, "localTransform": bed_local, "latticeId": null}]
	var seen_lattice: Dictionary = {}
	for group in ["regular", "worn"]:
		var transforms: Array = described[group + "Transforms"]
		var custom: Array = described[group + "CustomData"]
		var ids: Array = described[group + "Ids"]
		for index in range(transforms.size()):
			if not transforms[index] is Transform3D or not custom[index] is Color or not ids[index] is Vector2i:
				return _failure("invalid_paving_stone_descriptor")
			var lattice: Vector2i = ids[index]
			if seen_lattice.has(lattice):
				return _failure("duplicate_paving_lattice_id")
			seen_lattice[lattice] = true
			solids.append({"id": "%s:%d:%d" % [group, lattice.x, lattice.y],
				"transform": part_transform * transforms[index], "materialKey": group,
				"customData": custom[index], "group": group, "ordinal": index,
				"localTransform": transforms[index], "latticeId": lattice})
	var result: Dictionary = Cut.subtract_boxes(solids, apertures, limits)
	if not result.completed:
		return result
	# Identity covers the complete original generated geometry and local/world
	# mapping. The recipe owner additionally binds its source/history revision;
	# this is not a cache and does not authorize replay from external cut cells.
	result["descriptorDigest"] = _digest(described)
	result["sourceTransform"] = part_transform
	result["constructionDigest"] = _digest([described, part_transform, result.canonicalApertures])
	result["sourceSolidCount"] = solids.size()
	result["changedSolidCount"] = result.entries.filter(func(entry): return not entry.unchanged).size()
	return result


static func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()


static func _failure(reason: String) -> Dictionary:
	return {"completed": false, "reason": reason, "work": 0}
