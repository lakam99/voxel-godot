extends RefCounted

## Pure, atomic preparation from actual affine brick descriptors. Publish native
## entries unchanged; prepared meshes retain original.localTransform/materialKey/
## customData. Never re-centre fragments or substitute ideal clipped coordinates.
## transform is the caller's world frame, localTransform its existing model frame.
const Cut = preload("res://scripts/buildings/ConvexFootingAperture.gd")
const Fragment = preload("res://scripts/buildings/PavingFragmentMesh.gd")
const UnitSnapshot = preload("res://scripts/buildings/UnitBoxArraySnapshot.gd")
const MAX_VERTICES := 262144
const MAX_VERIFY_WORK := 4000000

static func prepare(solids: Array, apertures: Array[AABB], unit_box: BoxMesh, readback_telemetry: Dictionary = {}, unit_snapshot: RefCounted = null) -> Dictionary:
	if solids.size() > Cut.HARD_LIMITS.maxSolids or apertures.size() > Cut.HARD_LIMITS.maxApertures:
		return _fail("input_limit")
	if unit_box == null or unit_box.size != Vector3.ONE or unit_box.get_surface_count() != 1:
		return _fail("invalid_unit_box")
	var template: Array
	if unit_snapshot != null:
		if not unit_snapshot is UnitSnapshot: return _fail("invalid_unit_box_snapshot")
		template = unit_snapshot.arrays_for(unit_box)
		if template.is_empty(): return _fail("stale_unit_box_snapshot")
		if not readback_telemetry.is_empty(): readback_telemetry["unitBoxTemplateHits"] = int(readback_telemetry.get("unitBoxTemplateHits", 0)) + 1
	else:
		# Compatibility for standalone geometry callers; publication sessions
		# always supply their mandatory source-bound snapshot and never fall back.
		template = UnitSnapshot.read_arrays(unit_box, readback_telemetry)
	if not template[Mesh.ARRAY_VERTEX] is PackedVector3Array or template[Mesh.ARRAY_VERTEX].size() != 24:
		return _fail("invalid_unit_box_vertices")
	# Validate local publication frames even when an original is wholly unchanged.
	for value: Variant in solids:
		if not value is Dictionary or not value.get("localTransform") is Transform3D or not Cut._valid_transform(value.localTransform):
			return _fail("invalid_local_publication_frame")
	var construction: Dictionary = _centered_construction(solids, apertures)
	if not construction.get("completed", false):
		return _fail("clipping:" + String(construction.get("reason", "unknown")), {"clippingWork": construction.get("work", 0)})
	var prepared_meshes: Dictionary = {}
	var provenance: Array = []
	var context: Dictionary = {"work": 0, "vertices": 0}
	for entry: Dictionary in construction.entries:
		var original: Dictionary = entry.get("publicationOriginal", entry.original)
		var vertices: PackedVector3Array = template[Mesh.ARRAY_VERTEX]
		var prepared: Dictionary = {}
		if not entry.unchanged:
			prepared = Fragment.prepare(entry, unit_box)
			if not prepared.get("ready", false): return _fail("mesh:" + String(prepared.get("reason", "unknown")), {"solidId": original.id})
			if var_to_bytes(prepared.original) != var_to_bytes(entry.original): return _fail("mesh_changed_original_descriptor", {"solidId": original.id})
			# Only construction coordinates were translated; unit-box local mesh
			# coordinates and the original publication frame remain unchanged.
			prepared["constructionFrameOrigin"] = entry.constructionFrameOrigin
			prepared.original = original.duplicate(true)
			vertices = PackedVector3Array()
			if prepared.mesh != null:
				if not prepared.mesh is ArrayMesh or prepared.mesh.get_surface_count() != 1: return _fail("invalid_fragment_mesh", {"solidId": original.id})
				var arrays: Array = prepared.mesh.surface_get_arrays(0)
				vertices = arrays[Mesh.ARRAY_VERTEX]
				if not _attributes_valid(arrays): return _fail("invalid_fragment_attributes", {"solidId": original.id})
			elif not entry.cells.is_empty(): return _fail("missing_fragment_mesh", {"solidId": original.id})
			if vertices.size() != prepared.vertexCount: return _fail("fragment_vertex_count_mismatch", {"solidId": original.id})
		context.vertices += vertices.size()
		if context.vertices > MAX_VERTICES: return _fail("publication_vertex_limit")
		var proof: Dictionary = _verify_vertices(original, vertices, construction.canonicalApertures, context)
		if not proof.ready: return proof
		if entry.unchanged:
			var native := _verify_fragment_cells(original, vertices,
				[{"cellIndex": 0, "firstVertex": 0, "vertexCount": vertices.size()}], 1, construction.canonicalApertures, context)
			if not native.ready: return native
		else:
			var cells: Dictionary = _verify_fragment_cells(original, vertices, prepared.faceProvenance, entry.cells.size(), construction.canonicalApertures, context)
			if not cells.ready: return cells
			prepared_meshes[original.id] = prepared
			entry.original = original.duplicate(true)
			entry.erase("publicationOriginal")
		provenance.append({"solidId": original.id, "unchanged": entry.unchanged, "fragmentCount": entry.cells.size(), "vertexCount": vertices.size(),
			"inputVolume": entry.inputVolume, "remainingVolume": entry.remainingVolume, "removedVolume": entry.removedVolume,
			"faceProvenance": prepared.get("faceProvenance", []), "worldTransform": original.transform, "localTransform": original.localTransform,
			"constructionFrameOrigin": entry.get("constructionFrameOrigin", Vector3.ZERO), "apertures": construction.canonicalApertures.duplicate()})
	return {"ready": true, "reason": "", "entries": construction.entries, "preparedMeshes": prepared_meshes, "provenance": provenance,
		"canonicalApertures": construction.canonicalApertures, "removedVolume": construction.removedVolume, "remainingVolume": construction.remainingVolume,
		"clippingWork": construction.work, "verificationWork": context.work, "vertexCount": context.vertices,
		"precisionPolicy": "No cut expansion, vertex offsets or clearance epsilon. Float32 mesh vertices transformed through the original world frame must clear every finite aperture.",
		"scope": "CPU mesh preparation only; caller owns world/local-frame correspondence, publication and GPU verification."}

static func _centered_construction(solids: Array, apertures: Array[AABB]) -> Dictionary:
	# Validate the entire original domain first, even originals missing all cuts.
	var validated := Cut.subtract_boxes(solids, [])
	if not validated.get("completed", false): return validated
	var cuts := Cut.subtract_boxes([], apertures)
	if not cuts.get("completed", false): return cuts
	var entries: Array = []
	var work: int = validated.work + cuts.work
	var fragments := 0
	var removed := 0.0
	var remaining := 0.0
	for index in range(solids.size()):
		var source: Dictionary = solids[index]
		var origin: Vector3 = source.transform.origin
		var relevant: Array[AABB] = []
		for aperture: AABB in cuts.canonicalApertures:
			var separated := false
			for axis in range(3):
				var half_extent: float = (absf(source.transform.basis.x[axis]) + absf(source.transform.basis.y[axis]) + absf(source.transform.basis.z[axis])) * 0.5
				separated = separated or float(origin[axis]) + half_extent <= float(aperture.position[axis]) or float(origin[axis]) - half_extent >= float(aperture.end[axis])
			if separated: continue
			relevant.append(aperture)
		# Choose coordinates before clipping. Keep centred axes where subtraction
		# preserves every plane exactly; leave an unrepresentable axis untranslated.
		# This changes neither the declared cut nor the original publication frame.
		for aperture: AABB in relevant:
			var low := aperture.position - origin
			var high := aperture.end - origin
			var translated := AABB(low, high - low)
			for axis in range(3):
				if float(low[axis]) != float(aperture.position[axis]) - float(origin[axis]) or float(high[axis]) != float(aperture.end[axis]) - float(origin[axis]) or translated.end[axis] != high[axis]:
					origin[axis] = 0.0
		var centered: Dictionary = source.duplicate(true)
		centered.transform.origin = source.transform.origin - origin
		for axis in range(3):
			if float(centered.transform.origin[axis]) != float(source.transform.origin[axis]) - float(origin[axis]):
				return {"completed": false, "reason": "unrepresentable_construction_origin", "work": work}
		var local_cuts: Array[AABB] = []
		for aperture: AABB in relevant:
			var low := aperture.position - origin
			var high := aperture.end - origin
			var size := high - low
			for axis in range(3):
				if origin[axis] == 0.0: size[axis] = aperture.size[axis]
			var translated := AABB(low, size)
			# Reject a translation that cannot retain the exact declared planes.
			for axis in range(3):
				if float(low[axis]) != float(aperture.position[axis]) - float(origin[axis]) or float(high[axis]) != float(aperture.end[axis]) - float(origin[axis]) or translated.end[axis] != high[axis]:
					return {"completed": false, "reason": "unrepresentable_centered_aperture", "work": work}
			local_cuts.append(translated)
		var clipped := Cut.subtract_boxes([centered], local_cuts)
		work += int(clipped.get("work", 0))
		if not clipped.get("completed", false):
			clipped["work"] = work
			return clipped
		if work > Cut.HARD_LIMITS.maxWork: return {"completed": false, "reason": "aggregate_clipping_work_limit", "work": work}
		var entry: Dictionary = clipped.entries[0]
		if entry.unchanged:
			entry = validated.entries[index]
			entry["cellCoordinateSpace"] = "original_world"
		else:
			entry["publicationOriginal"] = source.duplicate(true)
			# Cell worldVertices are in this explicit translated construction frame,
			# not claimed to be actual published world vertices.
			entry["constructionFrameOrigin"] = origin
			entry["cellCoordinateSpace"] = "source_centered_construction"
		fragments += entry.cells.size()
		if fragments > Cut.HARD_LIMITS.maxFragments: return {"completed": false, "reason": "aggregate_fragment_limit", "work": work}
		removed += entry.removedVolume
		remaining += entry.remainingVolume
		entries.append(entry)
	return {"completed": true, "entries": entries, "canonicalApertures": cuts.canonicalApertures,
		"removedVolume": removed, "remainingVolume": remaining, "work": work}

static func _attributes_valid(arrays: Array) -> bool:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	if vertices.is_empty() or vertices.size() % 3 != 0 or normals.size() != vertices.size() or uvs.size() != vertices.size() or tangents.size() != vertices.size() * 4: return false
	for index: int in range(vertices.size()):
		if not vertices[index].is_finite() or not normals[index].is_finite() or normals[index].length_squared() == 0.0 or not uvs[index].is_finite(): return false
	for component: float in tangents:
		if not is_finite(component): return false
	return true

static func _verify_vertices(original: Dictionary, vertices: PackedVector3Array, apertures: Array, context: Dictionary) -> Dictionary:
	for index: int in range(vertices.size()):
		var local: Vector3 = vertices[index]
		var world: Vector3 = original.transform * local # Actual float32 Vector3 result, not ideal construction coordinates.
		if not local.is_finite() or not world.is_finite(): return _fail("nonfinite_emitted_vertex", {"solidId": original.id, "vertexIndex": index})
		# Publication retains the original affine frame. Unit-local containment
		# therefore proves no cut mesh expands beyond its original brick.
		if absf(local.x) > 0.5 or absf(local.y) > 0.5 or absf(local.z) > 0.5: return _fail("emitted_vertex_outside_original_brick", {"solidId": original.id, "vertexIndex": index})
		for aperture_index: int in range(apertures.size()):
			context.work += 1
			if context.work > MAX_VERIFY_WORK: return _fail("verification_work_limit")
			var aperture: AABB = apertures[aperture_index]
			if world.x > aperture.position.x and world.x < aperture.end.x and world.y > aperture.position.y and world.y < aperture.end.y and world.z > aperture.position.z and world.z < aperture.end.z:
				return _fail("float32_vertex_intrudes_requires_authoritative_representation_repair", {"solidId": original.id, "vertexIndex": index, "apertureIndex": aperture_index,
					"localVertex": local, "emittedWorldVertex": world, "aperturePosition": aperture.position, "apertureEnd": aperture.end,
					"interiorDistances": (world - aperture.position).min(aperture.end - world)})
	return {"ready": true}

static func _verify_fragment_cells(original: Dictionary, vertices: PackedVector3Array, faces: Array, count: int, apertures: Array, context: Dictionary) -> Dictionary:
	# Vertex exclusion alone cannot prove that triangle interiors clear a box.
	# Each convex subtraction fragment must retain a common separating aperture
	# plane for ALL its actual emitted vertices. This is sufficient, not a claim
	# of universal infeasibility if an oblique-only separation cannot be proved.
	var groups: Array = []
	for index: int in range(count): groups.append(PackedVector3Array())
	for face: Dictionary in faces:
		if face.cellIndex < 0 or face.cellIndex >= count or face.firstVertex < 0 or face.vertexCount < 3 or face.firstVertex + face.vertexCount > vertices.size(): return _fail("invalid_mesh_provenance")
		var points: PackedVector3Array = groups[face.cellIndex]
		for index: int in range(face.firstVertex, face.firstVertex + face.vertexCount): points.append(original.transform * vertices[index])
		groups[face.cellIndex] = points
	for cell_index: int in range(count):
		var points: PackedVector3Array = groups[cell_index]
		if points.is_empty(): return _fail("missing_emitted_cell")
		var minimum: Vector3 = points[0]
		var maximum: Vector3 = points[0]
		for point: Vector3 in points:
			minimum = minimum.min(point)
			maximum = maximum.max(point)
		for aperture_index: int in range(apertures.size()):
			context.work += points.size()
			if context.work > MAX_VERIFY_WORK: return _fail("verification_work_limit")
			var aperture: AABB = apertures[aperture_index]
			var separated: bool = false
			for axis: int in range(3): separated = separated or maximum[axis] <= aperture.position[axis] or minimum[axis] >= aperture.end[axis]
			if not separated: return _fail("emitted_fragment_clearance_unproven_requires_authoritative_representation_review", {"solidId": original.id, "cellIndex": cell_index, "apertureIndex": aperture_index, "emittedMinimum": minimum, "emittedMaximum": maximum})
	return {"ready": true}

static func _fail(reason: String, diagnostic: Dictionary = {}) -> Dictionary:
	# Never expose partially prepared entries or meshes on failure.
	return {"ready": false, "reason": reason, "diagnostic": diagnostic}
