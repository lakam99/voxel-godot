extends SceneTree

const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Recipe = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")

func _initialize() -> void:
	var report := {"checks": {}, "evidence": {}, "scope": "SHA-bound current facade recipe fixed point only; no publication, rendering, navigation, or gameplay claim."}
	var binding := _read_bound(OS.get_environment("VOXEL_FACADE_CURRENT_INPUT"), OS.get_environment("VOXEL_FACADE_CURRENT_SHA"))
	report.checks["bound_input_read"] = binding.ready
	if binding.ready:
		var raw: Dictionary = binding.value
		var source_bytes := var_to_bytes(raw)
		var result := Recipe.prepare(Copy.copy_blueprint(raw.afterSnapshot), {
			"furnitureParts": raw.furnitureSnapshot.parts,
			"reservedVolumes": raw.protectedReservations})
		report.checks["recipe_exhausted"] = result.get("ready", false) and result.get("exhausted", false)
		report.checks["source_immutable"] = source_bytes == var_to_bytes(raw)
		if result.get("ready", false):
			var before = Copy.copy_blueprint(raw.afterSnapshot)
			var after = Copy.copy_blueprint(result.afterSnapshot)
			Copy.clear_caches(before); Copy.clear_caches(after)
			var before_grid := Copy.validation_grid_work(before)
			var after_grid := Copy.validation_grid_work(after)
			report.checks["validation_work_bounded"] = before_grid.ready and after_grid.ready
			if before_grid.ready and after_grid.ready:
				var before_physical: Dictionary = before.validate_physical_integrity()
				var after_physical: Dictionary = after.validate_physical_integrity()
				var before_ids: Array = Copy.failed_ids(before_physical)
				var after_ids: Array = Copy.failed_ids(after_physical)
				var lower: Dictionary = result.lower
				var opening_additions := 0
				for proposal: Dictionary in result.opening.houseProposals:
					opening_additions += 1 + proposal.get("connectionIds", []).size()
				var expected_parts: int = raw.afterSnapshot.parts.size() + opening_additions + lower.accepted.size() * 3
				report.checks["current_gate_42"] = before_physical.violations.size() == 170 and after_physical.violations.size() == 42
				report.checks["no_added_failure_ids"] = after_ids.all(func(id): return before_ids.has(id))
				report.checks["exact_addition_count"] = result.afterSnapshot.parts.size() == expected_parts
				report.checks["exact_contents"] = raw.furnitureSnapshot.parts.size() == 152 and var_to_bytes(raw.furnitureSnapshot) == var_to_bytes(binding.value.furnitureSnapshot) and var_to_bytes(raw.protectedReservations) == var_to_bytes(binding.value.protectedReservations)
				report.checks["explicit_exhaustion_partition"] = lower.accepted.size() == 23 and lower.rejected.size() == 4 and lower.remainingUnsupportedPanelIds.size() == 3 and not result.fullyResolved
				report.evidence = {"beforeFailureCount": before_physical.violations.size(), "afterFailureCount": after_physical.violations.size(),
					"acceptedPanelIds": lower.accepted, "rejected": lower.rejected,
					"remainingUnsupportedPanelIds": lower.remainingUnsupportedPanelIds,
					"sourcePartCount": raw.afterSnapshot.parts.size(), "openingAddedPartCount": opening_additions,
					"candidatePartCount": result.afterSnapshot.parts.size(), "expectedPartCount": expected_parts,
					"furnitureCount": raw.furnitureSnapshot.parts.size(), "reservationCount": raw.protectedReservations.size()}
			var all_before_write: bool = report.checks.values().all(func(value): return value == true)
			report.checks["candidate_written"] = _write_candidate(raw, result, report.evidence) if all_before_write else false
		else:
			report["failure"] = result
	var passed: bool = report.checks.values().all(func(value): return value == true)
	report["passed"] = passed
	_write_json(OS.get_environment("VOXEL_FACADE_CURRENT_REPORT"), report)
	quit(0 if passed else 1)

func _write_candidate(raw: Dictionary, result: Dictionary, evidence: Dictionary) -> bool:
	var path := OS.get_environment("VOXEL_FACADE_CURRENT_OUTPUT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()): return false
	var candidate := raw.duplicate(true)
	candidate.afterSnapshot = result.afterSnapshot
	candidate["facadeCompletion"] = {"opening": result.opening, "lower": result.lower, "evidence": evidence}
	var bytes := var_to_bytes(candidate)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_buffer(bytes); file.flush()
	var written := file.get_error() == OK and file.get_position() == bytes.size()
	file.close()
	return written and FileAccess.file_exists(path)

func _read_bound(path: String, sha: String) -> Dictionary:
	if not path.is_absolute_path() or sha.length() != 64 or FileAccess.get_sha256(path) != sha.to_lower(): return {"ready": false}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > 32 * 1024 * 1024: return {"ready": false}
	var bytes := file.get_buffer(file.get_length())
	var complete := file.get_error() == OK
	file.close()
	var value: Variant = bytes_to_var(bytes) if complete else null
	return {"ready": value is Dictionary and var_to_bytes(value) == bytes, "value": value}

func _write_json(path: String, value: Dictionary) -> void:
	if not path.is_absolute_path(): return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify(_json(value), "\t")); file.close()

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
