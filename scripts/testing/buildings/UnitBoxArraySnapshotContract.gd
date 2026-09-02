extends SceneTree

## Synthetic CPU resource/cache contract, not publisher, GPU or gameplay proof.
const Snapshot = preload("res://scripts/buildings/UnitBoxArraySnapshot.gd")
const Geometry = preload("res://scripts/buildings/MasonryApertureGeometry.gd")
class ScriptedBox extends BoxMesh:
	pass

var _checks: Dictionary = {}
var _cases: Array[Dictionary] = []
var _normalization_valid: bool = true

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output: String = OS.get_environment("VOXEL_UNIT_BOX_SNAPSHOT_REPORT")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var unit: BoxMesh = _unit()
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.5, 0.75, 1.0)
	unit.material = material
	var native: PackedByteArray = var_to_bytes(unit.surface_get_arrays(0))
	var properties: PackedByteArray = _stored_properties(unit)
	var counters: Dictionary = {"callerMarker": "synthetic_capture"}
	var snapshot: RefCounted = Snapshot.new()
	_checks.capture_once = snapshot.capture(unit, counters)
	_checks.same_resource_matches = snapshot.matches(unit)
	_checks.actual_bound_arrays = var_to_bytes(snapshot.arrays_for(unit)) == native
	_checks.all_native_attributes_exact = var_to_bytes(snapshot._arrays) == native
	_checks.repeat_array_access_exact = var_to_bytes(snapshot.arrays_for(unit)) == native
	_checks.native_properties_and_material_unchanged = _stored_properties(unit) == properties and unit.material == material and material.albedo_color == Color(0.25, 0.5, 0.75, 1.0)
	var upper: Array[AABB] = [AABB(Vector3(-2, 0, -2), Vector3(4, 2, 4))]
	_case("unchanged", Transform3D.IDENTITY, [AABB(Vector3(4, 4, 4), Vector3.ONE)], unit, snapshot, counters, false, false)
	_case("cut", Transform3D.IDENTITY, upper, unit, snapshot, counters, true, false)
	_case("fully_removed", Transform3D.IDENTITY, [AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))], unit, snapshot, counters, true, true)
	var affine: Transform3D = Transform3D(Basis(Vector3(0.75, 0, 0.5), Vector3(0, 0.5, 0), Vector3(-0.25, 0, 1)), Vector3(8, 4, 2))
	_case("affine_cut", affine, [AABB(Vector3(6, 4, 0), Vector3(4, 2, 4))], unit, snapshot, counters, true, false)
	_checks.capture_read_once = counters.get("unitBoxArrayReadCount") == 1
	_checks.cache_hits_reused = int(counters.get("unitBoxTemplateHits", 0)) > 1
	_checks.caller_telemetry_preserved = counters.get("callerMarker") == "synthetic_capture"
	_checks.source_arrays_and_material_still_exact = native == var_to_bytes(unit.surface_get_arrays(0)) and properties == _stored_properties(unit) and unit.material == material
	_checks.recapture_rejected = not snapshot.capture(unit, counters)
	_checks.recapture_no_extra_read = counters.get("unitBoxArrayReadCount") == 1
	_wrong_resource()
	for property: String in ["size", "subdivide_width", "subdivide_height", "subdivide_depth", "flip_faces", "material"]:
		_mutated_property(property)
	_corrupted_arrays()
	var empty: RefCounted = Snapshot.new()
	_checks.uncaptured_rejected = not empty.matches(unit) and empty.arrays_for(unit).is_empty()
	var null_snapshot: RefCounted = Snapshot.new()
	_checks.null_capture_rejected = not null_snapshot.capture(null)
	var scripted: BoxMesh = ScriptedBox.new()
	scripted.size = Vector3.ONE
	var scripted_snapshot: RefCounted = Snapshot.new()
	_checks.script_subclass_rejected = not scripted_snapshot.capture(scripted)
	_checks.normalization_complete = _normalization_valid
	var passed: bool = _checks.values().all(func(value: Variant) -> bool: return value == true)
	var stored_names: Array[String] = []
	for property: Dictionary in unit.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_STORAGE) != 0: stored_names.append(String(property.name))
	var report: Dictionary = {"passed": passed, "checkCount": _checks.size(), "checks": _checks,
		"nativeBoxMeshStoredPropertyNames": stored_names,
		"cases": _cases, "captureTelemetry": counters, "evidenceLevel": "synthetic_CPU_unit_box_snapshot_and_geometry_parity",
		"helperSHA256": FileAccess.get_sha256("res://scripts/buildings/UnitBoxArraySnapshot.gd"),
		"geometrySHA256": FileAccess.get_sha256("res://scripts/buildings/MasonryApertureGeometry.gd"),
		"doesNotProve": "No full-session 5509-brick reuse, publisher ownership/WeakRef lifetime, actual world publication, GPU, visual or gameplay acceptance."}
	var text: String = JSON.stringify(report, "  ") + "\n"
	var file: FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(text)
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	written = written and FileAccess.get_sha256(output) == text.sha256_text()
	quit(0 if passed and written else 2)

func _case(label: String, pose: Transform3D, cuts: Array[AABB], unit: BoxMesh, snapshot: RefCounted, counters: Dictionary, changed: bool, removed: bool) -> void:
	var original: Dictionary = {"id": label, "materialKey": "synthetic:stone", "customData": Color(0.125, 0.25, 0.5, 1),
		"transform": pose, "localTransform": Transform3D(pose.basis, Vector3(1, 2, 3)), "preservedAttribute": {"tags": ["contract", 17]}}
	var solids: Array = [original]
	var frozen: PackedByteArray = var_to_bytes([solids, cuts])
	var uncached_telemetry: Dictionary = {"callerMarker": label}
	var uncached: Dictionary = Geometry.prepare(solids, cuts, unit, uncached_telemetry)
	var cached: Dictionary = Geometry.prepare(solids, cuts, unit, counters, snapshot)
	var repeated: Dictionary = Geometry.prepare(solids, cuts, unit, counters, snapshot)
	_checks[label + ":all_ready"] = uncached.get("ready") == true and cached.get("ready") == true and repeated.get("ready") == true
	_checks[label + ":exact_result_arrays_original_provenance"] = var_to_bytes(_normalize(uncached)) == var_to_bytes(_normalize(cached))
	_checks[label + ":repeat_deterministic"] = var_to_bytes(_normalize(cached)) == var_to_bytes(_normalize(repeated))
	_checks[label + ":inputs_immutable"] = frozen == var_to_bytes([solids, cuts])
	_checks[label + ":uncached_one_measured_read"] = uncached_telemetry.get("unitBoxArrayReadCount") == 1
	if cached.get("ready") == true:
		_checks[label + ":exact_original_frame_material_attributes"] = cached.entries.size() == 1 and var_to_bytes(cached.entries[0].original) == var_to_bytes(original)
		_checks[label + ":expected_changed"] = cached.entries[0].unchanged == (not changed)
		if changed:
			var prepared: Dictionary = cached.preparedMeshes[label]
			_checks[label + ":prepared_original_exact"] = var_to_bytes(prepared.original) == var_to_bytes(original)
			_checks[label + ":mesh_presence"] = (prepared.mesh == null) == removed
		else:
			_checks[label + ":unchanged_native_no_mesh"] = cached.preparedMeshes.is_empty()
	_cases.append({"case": label, "cachedReady": cached.get("ready", false), "cachedReason": cached.get("reason", ""),
		"uncachedReady": uncached.get("ready", false), "uncachedReason": uncached.get("reason", ""), "uncachedTelemetry": uncached_telemetry})

func _wrong_resource() -> void:
	var unit: BoxMesh = _unit()
	var other: BoxMesh = _unit()
	var snapshot: RefCounted = Snapshot.new()
	_checks.wrong_resource_setup = snapshot.capture(unit)
	_checks.wrong_resource_arrays_identical = var_to_bytes(unit.surface_get_arrays(0)) == var_to_bytes(other.surface_get_arrays(0))
	_checks.wrong_resource_rejected = not snapshot.matches(other) and snapshot.arrays_for(other).is_empty()
	_checks.wrong_resource_invalidation_sticky = not snapshot.matches(unit) and snapshot.arrays_for(unit).is_empty()

func _mutated_property(property: String) -> void:
	var unit: BoxMesh = _unit()
	var snapshot: RefCounted = Snapshot.new()
	var old: Variant = unit.get(property)
	_checks[property + ":capture"] = snapshot.capture(unit)
	match property:
		"size": unit.size = Vector3(2, 1, 1)
		"flip_faces": unit.flip_faces = true
		"material": unit.material = StandardMaterial3D.new()
		_: unit.set(property, 1)
	_checks[property + ":rejected"] = not snapshot.matches(unit) and snapshot.arrays_for(unit).is_empty()
	unit.set(property, old)
	_checks[property + ":restored_but_sticky"] = not snapshot.matches(unit) and snapshot.arrays_for(unit).is_empty()

func _corrupted_arrays() -> void:
	var unit: BoxMesh = _unit()
	var snapshot: RefCounted = Snapshot.new()
	_checks.corruption_capture = snapshot.capture(unit)
	var old: Array = snapshot._arrays.duplicate(true)
	var vertices: PackedVector3Array = snapshot._arrays[Mesh.ARRAY_VERTEX].duplicate()
	vertices[0] += Vector3(0.125, 0, 0)
	snapshot._arrays[Mesh.ARRAY_VERTEX] = vertices
	_checks.cached_corruption_rejected = not snapshot.matches(unit) and snapshot.arrays_for(unit).is_empty()
	snapshot._arrays = old
	_checks.cached_corruption_sticky = not snapshot.matches(unit) and snapshot.arrays_for(unit).is_empty()
	var cuts: Array[AABB] = []
	var source: Array = [{"id": "invalidated", "materialKey": "stone", "customData": Color.WHITE, "transform": Transform3D.IDENTITY, "localTransform": Transform3D.IDENTITY}]
	var result: Dictionary = Geometry.prepare(source, cuts, unit, {}, snapshot)
	_checks.invalidated_snapshot_no_uncached_fallback = result.get("ready") == false and not result.has("entries") and not result.has("preparedMeshes")

func _normalize(value: Variant) -> Variant:
	if value is Mesh:
		var mesh: Mesh = value
		var surfaces: Array = []
		for index: int in range(mesh.get_surface_count()):
			surfaces.append({"primitive": mesh.surface_get_primitive_type(index), "arrays": mesh.surface_get_arrays(index), "material": mesh.surface_get_material(index)})
		return {"meshClass": mesh.get_class(), "bounds": mesh.get_aabb(), "surfaces": surfaces}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[key] = _normalize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for element: Variant in value: result.append(_normalize(element))
		return result
	if value is Object: _normalization_valid = false
	return value

func _stored_properties(unit: BoxMesh) -> PackedByteArray:
	var properties: Dictionary = {}
	for property: Dictionary in unit.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_STORAGE) != 0: properties[property.name] = unit.get(property.name)
	return var_to_bytes(properties)

func _unit() -> BoxMesh:
	var unit: BoxMesh = BoxMesh.new()
	unit.size = Vector3.ONE
	return unit
