extends SceneTree

## Phase A: capture the untouched publisher BEFORE shared-owner extraction.
## Source/service only: real publish_visual/material_for/variation_for and goods
## primitive construction, intercepted scene sinks and material allocation.
## No geometry formulas are copied here. No scene, physics or render acceptance.
## Required env: VOXEL_GOODS_GEOMETRY_PARITY_MODE = baseline | replay
## VOXEL_GOODS_GEOMETRY_PARITY_BASELINE = absolute JSON (fresh for baseline)
## VOXEL_GOODS_GEOMETRY_PARITY_REPORT = different fresh absolute JSON
## Replay also requires VOXEL_GOODS_GEOMETRY_PARITY_BASELINE_SHA256 from the
## successful capture report. Neither mode can replace an existing file.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const PUBLISHER_PATH := "res://scripts/buildings/BuildingPartPublisher.gd"
const FORMAT := "building_goods_geometry_exact_v1"
const MAX_BASELINE_BYTES := 16 * 1024 * 1024
const EXPECTED_CASES := 192
const MAX_EVENTS_PER_CASE := 32

class PublisherCapture extends "res://scripts/buildings/BuildingPartPublisher.gd":
	var events: Array = []
	var errors: Array = []
	var material_tokens: Dictionary = {}
	var material_handles: Array = []

	func variation_for(part) -> float:
		var value: float = super.variation_for(part)
		events.append({"op": "variation_for", "partId": part.id, "result": value})
		return value

	func material_for(part) -> Material:
		events.append({"op": "material_for", "partId": part.id})
		# Preserve the real delegation and evaluation order. Only the final
		# material factory/cache is stubbed; requested inputs remain observable.
		return super.material_for(part)

	func material_for_id(material_id: String, variation := 0.0) -> Material:
		var token := material_handles.size()
		events.append({"op": "material_for_id", "materialId": material_id, "variation": variation, "token": token})
		var material := StandardMaterial3D.new()
		material_handles.append(material)
		material_tokens[material.get_instance_id()] = token
		return material

	func add_mesh_visual(_parent: Node3D, mesh: Mesh, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
		_emit("add_mesh_visual", mesh, size, position, material, node_name)

	func add_box_visual(_parent: Node3D, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
		# The real box sink uses this actual inherited unit_box, not a new box
		# with guessed defaults. Its dimensions are then scaled by 'size'.
		_emit("add_box_visual", unit_box, size, position, material, node_name)

	func _emit(operation: String, mesh: Mesh, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
		var token := -1
		if material != null: token = int(material_tokens.get(material.get_instance_id(), -1))
		if token < 0: errors.append("primitive_material_was_not_requested")
		if mesh == null:
			errors.append("missing_primitive_mesh")
			return
		var properties: Dictionary = {}
		for info in mesh.get_property_list():
			if (int(info.usage) & PROPERTY_USAGE_STORAGE) == 0: continue
			var key := String(info.name)
			# Asset-location/editor identities are not geometry. All stored mesh
			# shape/render properties (including defaults) remain in the trace.
			if key in ["resource_path", "resource_scene_unique_id"]: continue
			properties[key] = mesh.get(key)
		var required: Array = []
		match mesh.get_class():
			"CylinderMesh": required = ["top_radius", "bottom_radius", "height", "radial_segments", "rings"]
			"TorusMesh": required = ["inner_radius", "outer_radius", "rings", "ring_segments"]
			"BoxMesh": required = ["size", "subdivide_width", "subdivide_height", "subdivide_depth"]
			_: errors.append("unexpected_mesh_type:" + mesh.get_class())
		for key in required:
			if not properties.has(key): errors.append("missing_mesh_property:" + key)
		var local := Transform3D(Basis.from_scale(size), position)
		events.append({"op": operation, "nodeName": node_name, "materialToken": token,
			"primitiveClass": mesh.get_class(), "meshProperties": properties,
			"scale": size, "position": position, "localTransform": local,
			"meshAabb": mesh.get_aabb(), "localAabb": local * mesh.get_aabb()})

var _checks: Array = []
var _encoding_errors: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var mode := OS.get_environment("VOXEL_GOODS_GEOMETRY_PARITY_MODE").strip_edges()
	var baseline_path := _env_path("VOXEL_GOODS_GEOMETRY_PARITY_BASELINE")
	var report_path := _env_path("VOXEL_GOODS_GEOMETRY_PARITY_REPORT")
	if mode not in ["baseline", "replay"] or not _json_path(baseline_path) or not _json_path(report_path) or baseline_path.to_lower() == report_path.to_lower() or FileAccess.file_exists(report_path):
		printerr("Parity requires mode baseline/replay, distinct absolute JSON paths, and a fresh report")
		quit(2)
		return
	if (mode == "baseline" and FileAccess.file_exists(baseline_path)) or (mode == "replay" and not FileAccess.file_exists(baseline_path)):
		printerr("Baseline must be fresh for capture, existing for replay; never overwritten")
		quit(2)
		return
	var expected: Dictionary = {}
	var baseline_sha := ""
	if mode == "replay":
		baseline_sha = FileAccess.get_sha256(baseline_path)
		var pin := OS.get_environment("VOXEL_GOODS_GEOMETRY_PARITY_BASELINE_SHA256").strip_edges().to_lower()
		if pin.length() != 64 or pin != baseline_sha:
			printerr("Replay requires the exact baseline SHA-256 from the capture report")
			quit(2)
			return
		var file := FileAccess.open(baseline_path, FileAccess.READ)
		if file == null:
			quit(2)
			return
		if file.get_length() > MAX_BASELINE_BYTES:
			file.close()
			quit(2)
			return
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if not parsed is Dictionary or parsed.get("format") != FORMAT or parsed.get("mode") != "baseline" or parsed.get("passed") != true or not parsed.get("cases") is Array or parsed.cases.size() != EXPECTED_CASES:
			printerr("Not a successful, bounded goods-geometry capture baseline")
			quit(2)
			return
		expected = parsed
	var cases := _capture_cases()
	_check("complete_variant_matrix", cases.size() == EXPECTED_CASES)
	_check("all_values_exactly_encodable", _encoding_errors.is_empty(), _encoding_errors)
	_comparison_controls(cases)
	var engine := String(Engine.get_version_info().get("string", ""))
	var case_digest := _canonical(cases).sha256_text()
	if mode == "replay":
		_check("same_engine_resource_defaults", expected.get("engine") == engine)
		_check("baseline_case_digest_valid", expected.get("caseDigest") == _canonical(expected.cases).sha256_text())
		for index in range(cases.size()):
			var actual: Dictionary = cases[index]
			var reference: Variant = expected.cases[index]
			var same: bool = _canonical(reference) == _canonical(actual)
			_check("exact_replay:" + actual.caseId, same, "" if same else {"firstDifference": _first_difference(reference, actual, "case"), "expectedDigest": _canonical(reference).sha256_text(), "actualDigest": _canonical(actual).sha256_text()})
		_check("immutable_baseline_unchanged", FileAccess.get_sha256(baseline_path) == baseline_sha)
	var passed: bool = _checks.all(func(check): return bool(check.passed))
	if mode == "baseline" and passed:
		var capture := {"format": FORMAT, "mode": "baseline", "passed": true, "engine": engine,
			"publisherSha256": FileAccess.get_sha256(PUBLISHER_PATH), "contractSha256": FileAccess.get_sha256(get_script().resource_path),
			"caseDigest": case_digest, "cases": cases,
			"evidenceLevel": "real_publisher_local_primitive_and_material_request_service",
			"doesNotProve": "Actual material shader/cache output, scene publication, batching, rendering, physics or gameplay."}
		var written := _write_fresh(baseline_path, capture)
		_check("fresh_baseline_written", written)
		passed = passed and written
		if written: baseline_sha = FileAccess.get_sha256(baseline_path)
	var report := {"format": FORMAT, "mode": mode, "passed": passed, "engine": engine,
		"baselinePath": baseline_path, "baselineSha256": baseline_sha, "caseDigest": case_digest,
		"caseCount": cases.size(), "publisherSha256": FileAccess.get_sha256(PUBLISHER_PATH), "checks": _checks,
		"evidenceLevel": "source_service_exact_parity_not_visual_acceptance",
		"doesNotProve": "Material shader/cache equivalence, scene publication, batching, rendered visuals, physical support, navigation or gameplay."}
	if not _write_fresh(report_path, report):
		quit(2)
		return
	print("Goods geometry parity %s: %s (%d cases); baseline SHA256=%s" % [mode, "PASS" if passed else "FAIL", cases.size(), baseline_sha])
	quit(0 if passed else 1)

func _capture_cases() -> Array:
	var cases: Array = []
	for kind in ["sack", "basket", "pottery"]:
		var native_size := Vector3(0.46, 0.72, 0.42) if kind == "sack" else Vector3(0.48, 0.46, 0.48)
		var sizes: Array = [native_size, native_size * 1.75, Vector3(0.137, 0.913, 0.271), Vector3(0.02, 2.3, 0.031)]
		var variations: Array = [null, 0.0, -0.125, 0.015]
		var primary := "linen" if kind == "sack" else ("timber_board" if kind == "basket" else "ceramic_glaze")
		for size_index in range(sizes.size()):
			for variation_index in range(variations.size()):
				for material_id in [primary, "wool_moss"]:
					for pose_index in range(2):
						var case_id := "%s:size%d:variation%d:%s:pose%d" % [kind, size_index, variation_index, material_id, pose_index]
						var recipe: Dictionary = {"preserve": ["source_metadata"], "collision": false}
						if variations[variation_index] != null: recipe["variation"] = variations[variation_index]
						var part := Part.new({"id": case_id, "kind": kind, "material": material_id, "size": sizes[size_index],
							"position": Vector3.ZERO if pose_index == 0 else Vector3(17.25, -2.17, 31.7),
							"rotation": Vector3.ZERO if pose_index == 0 else Vector3(0.17, 0.61, -0.23),
							"collision": false, "recipe": recipe})
						var before: Dictionary = part.snapshot()
						var capture := PublisherCapture.new()
						capture.publish_visual(part, null)
						var primitive_count := capture.events.filter(func(event): return event.op in ["add_mesh_visual", "add_box_visual"]).size()
						var intact: bool = var_to_bytes(before) == var_to_bytes(part.snapshot())
						_check("capture_valid:" + case_id, intact and capture.errors.is_empty() and capture.events.size() <= MAX_EVENTS_PER_CASE and primitive_count == {"sack": 4, "basket": 5, "pottery": 2}[kind], capture.errors)
						# Repeat via the direct entrypoint too: dispatch must not alter
						# call ordering, source state or generated local primitives.
						var direct := PublisherCapture.new()
						direct.call("publish_" + kind, part, null)
						var trace: Variant = _encode(capture.events)
						_check("direct_dispatch_exact:" + case_id, direct.errors.is_empty() and _canonical(trace) == _canonical(_encode(direct.events)) and var_to_bytes(before) == var_to_bytes(part.snapshot()))
						cases.append({"caseId": case_id, "input": _encode(before), "events": trace})
	return cases

func _comparison_controls(cases: Array) -> void:
	_check("float_bits_not_decimal_tolerance", _canonical(_encode(0.1)) != _canonical(_encode(0.1 + 0.000000000000001)))
	# Construct IEEE-754 binary64 negative zero directly: GDScript may fold
	# the -0.0 literal to positive zero before the encoder ever receives it.
	var negative_zero_bytes := PackedByteArray()
	negative_zero_bytes.resize(8)
	negative_zero_bytes.encode_u32(0, 0)
	negative_zero_bytes.encode_u32(4, 0x80000000)
	var negative_zero := negative_zero_bytes.decode_double(0)
	_check("signed_zero_is_preserved", _canonical(_encode(0.0)) != _canonical(_encode(negative_zero)))
	if cases.is_empty(): return
	var original: Dictionary = cases[0]
	var primitive_index := -1
	var material_index := -1
	for index in range(original.events.size()):
		if original.events[index].get("op") == "add_mesh_visual" and primitive_index < 0: primitive_index = index
		if original.events[index].get("op") == "material_for_id" and material_index < 0: material_index = index
	_check("comparison_controls_have_real_capture", primitive_index >= 0 and material_index >= 0)
	if primitive_index < 0 or material_index < 0: return
	for field in ["primitiveClass", "meshProperties", "scale", "position", "localTransform", "nodeName", "materialToken"]:
		var changed := original.duplicate(true)
		changed.events[primitive_index][field] = "intentional_negative_control"
		_check("reject_changed_primitive:" + field, _canonical(changed) != _canonical(original) and not _first_difference(original, changed, "case").is_empty())
	for field in ["materialId", "variation"]:
		var changed := original.duplicate(true)
		changed.events[material_index][field] = "intentional_negative_control"
		_check("reject_changed_material_request:" + field, _canonical(changed) != _canonical(original))
	var reordered := original.duplicate(true)
	var first: Variant = reordered.events[0]
	reordered.events[0] = reordered.events[1]
	reordered.events[1] = first
	_check("reject_changed_call_order", _canonical(reordered) != _canonical(original))

func _encode(value: Variant) -> Variant:
	# JSON decimal numbers alone are not the precision authority. Float bit
	# strings preserve every double bit, including signed zero; vector tags
	# preserve their types and represented components. No epsilon comparison.
	if value == null or value is bool or value is String: return value
	if value is StringName: return {"StringName": String(value)}
	if value is int: return {"int": str(value)}
	if value is float:
		var bytes := PackedByteArray()
		bytes.resize(8)
		bytes.encode_double(0, value)
		if not is_finite(value): _encoding_errors.append("nonfinite_capture_value")
		return {"float64": bytes.hex_encode(), "display": str(value)}
	if value is Vector2: return {"Vector2": [_encode(value.x), _encode(value.y)]}
	if value is Vector2i: return {"Vector2i": [_encode(value.x), _encode(value.y)]}
	if value is Vector3: return {"Vector3": [_encode(value.x), _encode(value.y), _encode(value.z)]}
	if value is Vector3i: return {"Vector3i": [_encode(value.x), _encode(value.y), _encode(value.z)]}
	if value is Color: return {"Color": [_encode(value.r), _encode(value.g), _encode(value.b), _encode(value.a)]}
	if value is AABB: return {"AABB": [_encode(value.position), _encode(value.size)]}
	if value is Basis: return {"Basis": [_encode(value.x), _encode(value.y), _encode(value.z)]}
	if value is Transform3D: return {"Transform3D": [_encode(value.basis), _encode(value.origin)]}
	if value is Array: return value.map(func(item): return _encode(item))
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			if not key is String and not key is StringName: _encoding_errors.append("nonstring_capture_key")
			result[String(key)] = _encode(value[key])
		return result
	_encoding_errors.append("unsupported_capture_type:" + type_string(typeof(value)))
	return {"unsupportedType": type_string(typeof(value))}

static func _canonical(value: Variant) -> String:
	return JSON.stringify(value, "", true)

static func _first_difference(expected: Variant, actual: Variant, path: String) -> String:
	if typeof(expected) != typeof(actual): return path + ":type"
	if expected is Dictionary:
		var keys: Array = expected.keys()
		keys.sort()
		if keys.size() != actual.size(): return path + ":keys"
		for key in keys:
			if not actual.has(key): return path + "." + key + ":missing"
			var nested := _first_difference(expected[key], actual[key], path + "." + key)
			if not nested.is_empty(): return nested
		return ""
	if expected is Array:
		if expected.size() != actual.size(): return path + ":length"
		for index in range(expected.size()):
			var nested := _first_difference(expected[index], actual[index], path + "[%d]" % index)
			if not nested.is_empty(): return nested
		return ""
	return "" if expected == actual else path

static func _env_path(name: String) -> String:
	return OS.get_environment(name).strip_edges().simplify_path()

static func _json_path(path: String) -> bool:
	return path.is_absolute_path() and path.get_extension().to_lower() == "json" and DirAccess.dir_exists_absolute(path.get_base_dir())

static func _write_fresh(path: String, payload: Dictionary) -> bool:
	if FileAccess.file_exists(path): return false
	var text := JSON.stringify(payload, "\t", true)
	if text.to_utf8_buffer().size() > MAX_BASELINE_BYTES: return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(text)
	file.flush()
	var okay := file.get_error() == OK
	file.close()
	return okay

func _check(name: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": name, "passed": passed, "detail": detail})
