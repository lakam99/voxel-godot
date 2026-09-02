extends SceneTree

const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Recipe = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")

func _initialize() -> void:
	var report := {"checks": {}, "evidence": {}, "scope": "Artifact-bound recipe-composition parity only; no publication, rendering, navigation, or gameplay claim."}
	var source := _read_bound("VOXEL_FACADE_COMPLETION_INPUT", "VOXEL_FACADE_COMPLETION_INPUT_SHA")
	var expected := _read_bound("VOXEL_FACADE_COMPLETION_EXPECTED", "VOXEL_FACADE_COMPLETION_EXPECTED_SHA")
	report.checks["bound_inputs_read"] = source.ready and expected.ready
	if source.ready and expected.ready:
		var raw: Dictionary = source.value
		var expected_raw: Dictionary = expected.value
		var expected_gate_text := OS.get_environment("VOXEL_FACADE_COMPLETION_EXPECTED_GATE")
		var expected_gate := int(expected_gate_text) if expected_gate_text.is_valid_int() else -1
		var before_bytes := var_to_bytes(raw)
		var blueprint = Copy.copy_blueprint(raw.afterSnapshot)
		var result := Recipe.prepare(blueprint, {"furnitureParts": raw.furnitureSnapshot.parts, "reservedVolumes": raw.protectedReservations})
		report.checks["recipe_ready"] = result.get("ready", false) and result.get("exhausted", false)
		report.checks["source_immutable"] = before_bytes == var_to_bytes(raw)
		report.checks["exact_accepted_snapshot"] = result.get("ready", false) and var_to_bytes(result.afterSnapshot) == var_to_bytes(expected_raw.afterSnapshot)
		report.checks["furniture_preserved"] = var_to_bytes(raw.furnitureSnapshot) == var_to_bytes(expected_raw.furnitureSnapshot)
		report.checks["reservations_preserved"] = var_to_bytes(raw.protectedReservations) == var_to_bytes(expected_raw.protectedReservations)
		report.checks["exact_recorded_partition"] = result.get("ready", false) and expected_raw.get("facadeCompletion") is Dictionary \
			and var_to_bytes(result.lower.accepted) == var_to_bytes(expected_raw.facadeCompletion.lower.accepted) \
			and var_to_bytes(result.lower.rejected) == var_to_bytes(expected_raw.facadeCompletion.lower.rejected) \
			and var_to_bytes(result.lower.remainingUnsupportedPanelIds) == var_to_bytes(expected_raw.facadeCompletion.lower.remainingUnsupportedPanelIds)
		if result.get("ready", false):
			var before = Copy.copy_blueprint(raw.afterSnapshot)
			var after = Copy.copy_blueprint(result.afterSnapshot)
			Copy.clear_caches(before)
			Copy.clear_caches(after)
			var before_grid := Copy.validation_grid_work(before)
			var after_grid := Copy.validation_grid_work(after)
			report.checks["validation_work_bounded"] = before_grid.ready and after_grid.ready
			if before_grid.ready and after_grid.ready:
				var before_physical: Dictionary = before.validate_physical_integrity()
				var after_physical: Dictionary = after.validate_physical_integrity()
				report.checks["expected_gate_delta"] = expected_gate >= 0 and before_physical.violations.size() == 170 and after_physical.violations.size() == expected_gate
				report.checks["no_added_failures"] = after_physical.violations.all(func(id): return before_physical.violations.has(id))
				report.evidence = {"beforeFailureCount": before_physical.violations.size(), "afterFailureCount": after_physical.violations.size(),
					"opening": result.opening, "lower": result.lower}
		else:
			report["failure"] = result
	var passed: bool = report.checks.values().all(func(value): return value == true)
	report["passed"] = passed
	_write_report(report)
	quit(0 if passed else 1)

func _read_bound(path_name: String, sha_name: String) -> Dictionary:
	var path := OS.get_environment(path_name)
	var sha := OS.get_environment(sha_name).to_lower()
	if not path.is_absolute_path() or sha.length() != 64 or FileAccess.get_sha256(path) != sha:
		return {"ready": false, "reason": "invalid_binding", "pathVariable": path_name}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > 32 * 1024 * 1024:
		return {"ready": false, "reason": "invalid_bound_file", "pathVariable": path_name}
	var bytes := file.get_buffer(file.get_length())
	var complete := file.get_error() == OK
	file.close()
	var value: Variant = bytes_to_var(bytes) if complete else null
	if not value is Dictionary or var_to_bytes(value) != bytes:
		return {"ready": false, "reason": "noncanonical_bound_value", "pathVariable": path_name}
	return {"ready": true, "value": value}

func _write_report(report: Dictionary) -> void:
	var path := OS.get_environment("VOXEL_FACADE_COMPLETION_REPORT")
	if not path.is_absolute_path():
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.close()

func _json(value: Variant) -> Variant:
	if value is Vector2: return {"x": value.x, "y": value.y}
	if value is Vector3: return {"x": value.x, "y": value.y, "z": value.z}
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key: Variant in value: result[String(key)] = _json(value[key])
		return result
	if value is Array:
		var result := []
		for item: Variant in value: result.append(_json(item))
		return result
	return value
