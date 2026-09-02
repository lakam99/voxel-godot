extends SceneTree

## Synthetic literal-formula parity only; no publisher, collision or gameplay proof.
const Geometry = preload("res://scripts/buildings/MasonryWallGeometry.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_MASONRY_GEOMETRY_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var cases: Dictionary = {"thin_wall": Vector3(0.30, 3.10, 8.0), "tiny_minima": Vector3(0.01, 0.01, 0.01), "monumental": Vector3(18.0, 42.0, 64.0), "mixed_axes": Vector3(0.01, 1.25, 24.0), "below_inset_cap": Vector3(0.50, 2.0, 0.52), "above_inset_cap": Vector3(0.54, 2.0, 0.56)}
	var checks: Dictionary = {}
	var rows: Array = []
	for name: String in cases:
		var size: Vector3 = cases[name]
		var before: PackedByteArray = var_to_bytes(size)
		# Deliberately retain the old publisher's literal operation order.
		var expected: Vector3 = size
		expected.x = maxf(0.02, size.x - minf(0.16, size.x * 0.30))
		expected.z = maxf(0.02, size.z - minf(0.16, size.z * 0.30))
		var actual: Vector3 = Geometry.bed_size(size)
		var swapped: Vector3 = Vector3(size.z, size.y, size.x)
		var swapped_before: PackedByteArray = var_to_bytes(swapped)
		var swapped_result: Vector3 = Geometry.bed_size(swapped)
		checks[name + ":literal_exact"] = actual == expected and var_to_bytes(actual) == var_to_bytes(expected)
		checks[name + ":finite_positive"] = actual.is_finite() and actual.x > 0.0 and actual.y > 0.0 and actual.z > 0.0
		checks[name + ":height_unchanged"] = actual.y == size.y
		checks[name + ":axis_swap_exact"] = swapped_result == Vector3(actual.z, actual.y, actual.x)
		checks[name + ":caller_unchanged"] = before == var_to_bytes(size) and swapped_before == var_to_bytes(swapped)
		if name == "tiny_minima": checks["tiny_minima_exact"] = actual == Vector3(0.02, size.y, 0.02)
		rows.append({"case": name, "input": [size.x, size.y, size.z], "expected": [expected.x, expected.y, expected.z], "actual": [actual.x, actual.y, actual.z]})
	var passed: bool = checks.values().all(func(value): return value == true)
	var report: Dictionary = {"passed": passed, "checks": checks, "cases": rows, "evidenceLevel": "synthetic_literal_formula_contract", "doesNotProve": "No actual publisher wiring, rendered geometry, physics or gameplay acceptance."}
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)
