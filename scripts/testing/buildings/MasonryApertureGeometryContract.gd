extends SceneTree

## Synthetic CPU preparation plus one supplied affine reproduction. No publisher/GPU proof.
const Geometry = preload("res://scripts/buildings/MasonryApertureGeometry.gd")
var _checks: Dictionary = {}
var _rows: Array = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_MASONRY_APERTURE_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var unit: BoxMesh = BoxMesh.new()
	unit.size = Vector3.ONE
	var unit_before: PackedByteArray = var_to_bytes(unit.surface_get_arrays(0))
	var upper: Array[AABB] = [AABB(Vector3(-2.0, 0.0, -2.0), Vector3(4.0, 2.0, 4.0))]
	_case("unchanged", [_solid("native", Transform3D.IDENTITY)], [AABB(Vector3(4, 4, 4), Vector3.ONE)], unit, false)
	_case("empty_apertures", [_solid("native", Transform3D.IDENTITY)], [], unit, false)
	_case("rotated_cut", [_solid("rotated", Transform3D(Basis(Vector3(0.75, 0, 0.5), Vector3.UP, Vector3(-0.5, 0, 0.75)), Vector3.ZERO))], upper, unit, true)
	_case("sheared_cut", [_solid("sheared", Transform3D(Basis(Vector3(1, 0, 0.25), Vector3.UP, Vector3(0.25, 0, 1)), Vector3.ZERO))], upper, unit, true)
	_case("multiple_apertures", [_solid("multiple", Transform3D.IDENTITY)], [upper[0], AABB(Vector3(0, -2, -2), Vector3(2, 4, 4))], unit, true)
	_case("fully_removed", [_solid("removed", Transform3D.IDENTITY)], [AABB(Vector3.ONE * -2.0, Vector3.ONE * 4.0)], unit, true)
	_frame_pair("rotated", Basis(Vector3(0.75, 0, 0.5), Vector3.UP, Vector3(-0.5, 0, 0.75)), unit)
	_frame_pair("sheared", Basis(Vector3(1, 0, 0.25), Vector3.UP, Vector3(0.25, 0, 1)), unit)
	_unrepresentable_endpoints(unit)
	_enclosed_aperture_requires_cell_proof(unit)
	for mode: String in ["missing_local", "singular_local", "singular_world", "nonfinite_world", "malformed", "duplicate_id", "invalid_custom", "invalid_aperture", "null_unit", "wrong_unit"]:
		var solids: Array = [_solid("negative", Transform3D.IDENTITY)]
		var cuts: Array[AABB] = upper.duplicate()
		var box: BoxMesh = unit
		match mode:
			"missing_local": solids[0].erase("localTransform")
			"singular_local": solids[0].localTransform.basis.x = Vector3.ZERO
			"singular_world": solids[0].transform.basis.x = Vector3.ZERO
			"nonfinite_world": solids[0].transform.origin.x = NAN
			"malformed": solids.append(null)
			"duplicate_id": solids.append(solids[0].duplicate(true))
			"invalid_custom": solids[0].customData = "bad"
			"invalid_aperture": cuts = [AABB(Vector3.ZERO, Vector3(1, -1, 1))]
			"null_unit": box = null
			"wrong_unit":
				box = BoxMesh.new()
				box.size = Vector3.ONE * 2.0
		var frozen: PackedByteArray = var_to_bytes([solids, cuts])
		var rejected: Dictionary = Geometry.prepare(solids, cuts, box)
		_checks["reject:" + mode] = not rejected.ready and not rejected.has("entries") and not rejected.has("preparedMeshes") and not rejected.reason.is_empty() and frozen == var_to_bytes([solids, cuts])
	var pose: Transform3D = Transform3D(Basis(Vector3(0.277995139360428, -0.000236838517594151, 0), Vector3(0.00164602766744792, 0.0399992987513542, 0), Vector3(0, 0, 0.0654793307185173)), Vector3(53.6753082275391, 5.37307929992676, 36.4605445861816))
	var low: Vector3 = Vector3(53.5199966430664, 5.3899998664856, 35.3199996948242)
	var high: Vector3 = Vector3(53.819995880127, 6.84999990463257, 36.4799995422363)
	var reproduction: Dictionary = _case("reported_affine_reproduction", [_solid("reproduction", pose)], [AABB(low, high - low)], unit, true, true)
	_checks["unit_template_immutable"] = unit_before == var_to_bytes(unit.surface_get_arrays(0)) and unit.size == Vector3.ONE
	var passed: bool = _checks.values().all(func(value): return value == true)
	var report: Dictionary = {"passed": passed, "checks": _checks, "cases": _rows, "reproduction": reproduction,
		"reproducedConstructionFeasible": reproduction.ready, "evidenceLevel": "synthetic_CPU_mesh_preparation_and_supplied_precision_reproduction",
		"status": "construction_precision_blocked_guard_verified" if not reproduction.ready and passed else ("synthetic_contract_passed" if passed else "contract_failed"),
		"doesNotProve": "No engine run is implied by source creation. When executed: no actual publisher, GPU shader arithmetic, collision, visual or gameplay acceptance. Guard success is not construction feasibility. A failed common-plane proof does not establish universal impossibility."}
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)

func _solid(id: String, pose: Transform3D) -> Dictionary:
	return {"id": id, "materialKey": "masonry:test", "customData": Color(0.1, 0.2, 0.3, 0.4), "transform": pose, "localTransform": pose, "opaqueAttribute": {"preserve": [1, 2, 3]}}

func _case(name: String, solids: Array, cuts: Array[AABB], unit: BoxMesh, changed: bool, precision_case: bool = false) -> Dictionary:
	var frozen: PackedByteArray = var_to_bytes([solids, cuts])
	var result: Dictionary = Geometry.prepare(solids, cuts, unit)
	var again: Dictionary = Geometry.prepare(solids, cuts, unit)
	var counters: Dictionary = {"callerMarker": "preserved"}
	var measured: Dictionary = Geometry.prepare(solids, cuts, unit, counters)
	_checks[name + ":telemetry_preserves_exact_result"] = _serial(result) == _serial(measured)
	_checks[name + ":one_existing_read_measured"] = counters.get("unitBoxArrayReadCount") == 1 and counters.get("callerMarker") == "preserved" and int(counters.get("unitBoxArrayReadUsec", -1)) >= int(counters.get("maxUnitBoxArrayReadUsec", -1)) and int(counters.get("maxUnitBoxArrayReadUsec", -1)) >= 0
	_checks[name + ":immutable"] = frozen == var_to_bytes([solids, cuts])
	_checks[name + ":deterministic"] = _serial(result) == _serial(again)
	var precision_blocked: bool = not result.ready and String(result.reason).begins_with("float32_vertex_intrudes_") and not result.has("entries") and result.get("diagnostic") is Dictionary and result.diagnostic.has("emittedWorldVertex")
	_checks[name + ":ready_or_explicit_precision_guard"] = result.ready or precision_case and precision_blocked
	if result.ready:
		_checks[name + ":original_descriptors_exact"] = result.entries.size() == solids.size() and result.entries[0].original == solids[0] and var_to_bytes(result.entries[0].original) == var_to_bytes(solids[0])
		_checks[name + ":expected_clipping"] = (not result.entries[0].unchanged) == changed and (result.removedVolume > 0.0) == changed
		_checks[name + ":independent_emitted_vertices_clear"] = _clear(result, cuts, unit)
		_checks[name + ":original_unit_local_containment"] = _local_contained(result, unit)
		if changed:
			_checks[name + ":original_shader_frame_attributes"] = result.preparedMeshes.has(solids[0].id) and var_to_bytes(result.preparedMeshes[solids[0].id].original) == var_to_bytes(solids[0])
		else:
			_checks[name + ":native_not_remeshed"] = result.preparedMeshes.is_empty()
			_checks[name + ":native_primitive_parity"] = _native_parity(result.entries[0], solids[0], unit)
	_rows.append({"name": name, "ready": result.ready, "reason": result.reason, "diagnostic": result.get("diagnostic", {}), "removedVolume": result.get("removedVolume"), "vertexCount": result.get("vertexCount")})
	return {"ready": result.ready, "reason": result.reason, "diagnostic": result.get("diagnostic", {}), "guardVerified": precision_blocked}

func _frame_pair(label: String, basis: Basis, unit: BoxMesh) -> void:
	# Dyadic translations and aperture endpoints are exactly representable.
	# A distinct, fixed parent-local publication frame must never be re-centred.
	var results: Array[Dictionary] = []
	for origin: Vector3 in [Vector3(0.125, -0.25, 0.5), Vector3(64.125, 7.75, 32.5)]:
		var source: Dictionary = _solid("frame_" + label, Transform3D(basis, origin))
		source.localTransform = Transform3D(basis, Vector3(2, 3, 4))
		var cuts: Array[AABB] = [AABB(origin + Vector3(-2, 0, -2), Vector3(4, 2, 4))]
		var name: String = label + (":near" if results.is_empty() else ":translated")
		_case(name, [source], cuts, unit, true)
		_case(name + ":native", [source], [AABB(origin + Vector3(4, 4, 4), Vector3.ONE)], unit, false)
		var result: Dictionary = Geometry.prepare([source], cuts, unit)
		_checks[name + ":strict_ready"] = result.ready
		if result.ready:
			var prepared: Dictionary = result.preparedMeshes[source.id]
			_checks[name + ":publication_frames_exact"] = prepared.original.transform == source.transform and prepared.original.localTransform == source.localTransform
			_checks[name + ":construction_origin_explicit"] = prepared.constructionFrameOrigin == origin and result.entries[0].constructionFrameOrigin == origin
		results.append(result)
	var exact: bool = results[0].ready and results[1].ready
	if exact:
		var first: Dictionary = results[0].preparedMeshes["frame_" + label]
		var second: Dictionary = results[1].preparedMeshes["frame_" + label]
		exact = first.mesh != null and second.mesh != null
		if exact:
			exact = var_to_bytes(first.mesh.surface_get_arrays(0)) == var_to_bytes(second.mesh.surface_get_arrays(0)) and first.original.localTransform == second.original.localTransform
		_checks[label + ":translated_volumes_exact"] = results[0].removedVolume == results[1].removedVolume and results[0].remainingVolume == results[1].remainingVolume
	_checks[label + ":translated_mesh_arrays_and_local_frame_exact"] = exact

func _unrepresentable_endpoints(unit: BoxMesh) -> void:
	# Both world endpoints are valid float32 numbers, but subtraction from the
	# nearby source origin loses 2^-26 at the chosen +/-1 endpoint.
	for lower: bool in [true, false]:
		var delta: float = 1.0 / 67108864.0
		var origin: Vector3 = Vector3(delta if lower else -delta, 0, 0)
		var cut: AABB = AABB(Vector3(-1 if lower else 0, -1, -1), Vector3(1, 2, 2))
		var endpoint: Vector3 = cut.position if lower else cut.end
		var relative: Vector3 = endpoint - origin
		var name: String = "unrepresentable_" + ("lower" if lower else "upper")
		_checks[name + ":fixture_loses_endpoint"] = float(relative.x) != float(endpoint.x) - float(origin.x)
		var solids: Array = [_solid(name, Transform3D(Basis.IDENTITY, origin))]
		var cuts: Array[AABB] = [cut]
		var frozen: PackedByteArray = var_to_bytes([solids, cuts])
		var result: Dictionary = Geometry.prepare(solids, cuts, unit)
		_checks[name + ":exact_frame_ready"] = result.ready
		_checks[name + ":original_planes_clear"] = result.ready and _clear(result,cuts,unit) and _local_contained(result,unit)
		_checks[name + ":untranslated_axis_and_original_frame"] = result.ready and result.entries[0].constructionFrameOrigin.x==0.0 and result.entries[0].original.transform==solids[0].transform and result.entries[0].original.localTransform==solids[0].localTransform
		_checks[name + ":immutable_deterministic"] = frozen == var_to_bytes([solids, cuts]) and _serial(result) == _serial(Geometry.prepare(solids, cuts, unit))

func _enclosed_aperture_requires_cell_proof(unit: BoxMesh) -> void:
	# Synthetic intact-box proof probe: every emitted corner is outside, but
	# the box volume encloses the protected aperture. Vertex exclusion is insufficient.
	var source: Dictionary = _solid("enclosed_aperture", Transform3D.IDENTITY)
	var vertices: PackedVector3Array = unit.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var cuts: Array[AABB] = [AABB(Vector3(-0.1, -0.1, -0.1), Vector3(0.2, 0.2, 0.2))]
	var faces: Array = [{"cellIndex": 0, "firstVertex": 0, "vertexCount": vertices.size()}]
	var frozen: PackedByteArray = var_to_bytes([source, vertices, cuts, faces])
	var vertex_proof: Dictionary = Geometry._verify_vertices(source, vertices, cuts, {"work": 0, "vertices": 0})
	var cell_proof: Dictionary = Geometry._verify_fragment_cells(source, vertices, faces, 1, cuts, {"work": 0, "vertices": 0})
	_checks["enclosed_aperture:all_24_vertices_outside"] = vertices.size() == 24 and vertex_proof.ready
	_checks["enclosed_aperture:whole_cell_rejected"] = not cell_proof.ready and cell_proof.reason == "emitted_fragment_clearance_unproven_requires_authoritative_representation_review" and not cell_proof.has("entries") and not cell_proof.has("preparedMeshes")
	_checks["enclosed_aperture:proof_inputs_immutable"] = frozen == var_to_bytes([source, vertices, cuts, faces])

func _local_contained(result: Dictionary, unit: BoxMesh) -> bool:
	for entry: Dictionary in result.entries:
		var vertices: PackedVector3Array = unit.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		if not entry.unchanged:
			var mesh: Variant = result.preparedMeshes[entry.original.id].mesh
			vertices = PackedVector3Array() if mesh == null else mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for point: Vector3 in vertices:
			if not point.is_finite(): return false
			for axis: int in range(3):
				if point[axis] < -0.5 or point[axis] > 0.5: return false
	return true

func _native_parity(entry: Dictionary, source: Dictionary, unit: BoxMesh) -> bool:
	if not entry.unchanged or entry.cells.size() != 1 or var_to_bytes(entry.original) != var_to_bytes(source): return false
	var cell: Dictionary = entry.cells[0]
	if cell.representation != "native_box" or cell.transform != source.transform: return false
	var expected: PackedVector3Array = PackedVector3Array()
	for x: float in [-0.5, 0.5]:
		for y: float in [-0.5, 0.5]:
			for z: float in [-0.5, 0.5]: expected.append(source.transform * Vector3(x, y, z))
	var emitted: Array[Vector3] = []
	for local: Vector3 in unit.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		var point: Vector3 = cell.transform * local
		if not expected.has(point): return false
		if not emitted.has(point): emitted.append(point)
	return emitted.size() == 8

func _clear(result: Dictionary, cuts: Array[AABB], unit: BoxMesh) -> bool:
	for entry: Dictionary in result.entries:
		var vertices: PackedVector3Array = unit.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		if not entry.unchanged:
			var prepared: Dictionary = result.preparedMeshes[entry.original.id]
			vertices = PackedVector3Array() if prepared.mesh == null else prepared.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for local: Vector3 in vertices:
			var point: Vector3 = entry.original.transform * local
			if not point.is_finite(): return false
			for cut: AABB in cuts:
				var outside: bool = false
				for axis: int in range(3): outside = outside or point[axis] <= cut.position[axis] or point[axis] >= cut.end[axis]
				if not outside: return false
	return true

func _serial(result: Dictionary) -> PackedByteArray:
	var value: Dictionary = result.duplicate(true)
	for prepared: Dictionary in value.get("preparedMeshes", {}).values():
		var mesh: Variant = prepared.mesh
		prepared["meshArrays"] = [] if mesh == null else mesh.surface_get_arrays(0)
		prepared.erase("mesh")
	return var_to_bytes(value)

func _json(value: Variant) -> Variant:
	if value is Vector3: return [value.x, value.y, value.z]
	if value is Dictionary:
		var output: Dictionary = {}
		for key: Variant in value: output[key] = _json(value[key])
		return output
	if value is Array: return value.map(_json)
	return value
