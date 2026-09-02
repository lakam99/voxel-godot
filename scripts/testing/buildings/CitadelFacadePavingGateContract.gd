extends SceneTree

## Full physical gate on immutable before/after recipe snapshots. No renderer,
## gameplay, navigation or high-level composer acceptance.
const Recipe = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("VOXEL_FACADE_PAVING_GATE_REPORT")
	var input := OS.get_environment("VOXEL_FACADE_PAVING_CANDIDATE")
	var sha := OS.get_environment("VOXEL_FACADE_PAVING_CANDIDATE_SHA256")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()) or not input.is_absolute_path() or sha.length() != 64 or FileAccess.get_sha256(input) != sha:
		quit(2)
		return
	var file := FileAccess.open(input, FileAccess.READ)
	if file == null or file.get_length() > 33554432:
		quit(2)
		return
	var value: Variant = bytes_to_var(file.get_buffer(file.get_length()))
	file.close()
	if not value is Dictionary or value.get("schemaVersion") != 1 or value.get("provenance") != "successful_complete_facade_paving_assembly_contract" or value.get("sourceContractPassed") != true:
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var rows: Dictionary = {}
	for stage in ["before", "after"]:
		var snapshot: Dictionary = value[stage + "Snapshot"]
		var expected: String = value.sourceDigest if stage == "before" else value.afterDigest
		if _digest(snapshot) != expected:
			quit(2)
			return
		var b = Recipe.copy_blueprint(snapshot)
		var work: Dictionary = Recipe.validation_grid_work(b)
		if not work.ready:
			quit(2)
			return
		Recipe.clear_caches(b)
		var physical: Dictionary = b.validate_physical_integrity()
		rows[stage] = {"failedIds": Recipe.failed_ids(physical), "physical": physical}
	var new_failures: Array = rows.after.failedIds.filter(func(id): return not rows.before.failedIds.has(id))
	var resolved: Array = rows.before.failedIds.filter(func(id): return not rows.after.failedIds.has(id))
	var selected_clear: bool = (value.memberIds + value.partIds).all(func(id): return not rows.after.failedIds.has(id))
	var unchanged: bool = FileAccess.get_sha256(input) == sha
	var passed: bool = unchanged and selected_clear and new_failures.is_empty() and not resolved.is_empty()
	var report := {"passed": passed, "gateZero": rows.after.failedIds.is_empty(), "beforeCount": rows.before.failedIds.size(), "afterCount": rows.after.failedIds.size(),
		"resolvedIds": resolved, "newFailures": new_failures, "selectedAndAddedPass": selected_clear,
		"beforePhysical": rows.before.physical, "afterPhysical": rows.after.physical,
		"input": input, "sha256": sha, "inputUnchanged": unchanged, "elapsedMsec": Time.get_ticks_msec() - started,
		"evidenceLevel": "full_frozen_recipe_physical_gate",
		"doesNotProve": "No rendering, collision-backed traversal, high-level composer integration, new-seed generation or gate-zero claim unless gateZero is explicitly true."}
	var out := FileAccess.open(output, FileAccess.WRITE)
	if out == null:
		quit(2)
		return
	out.store_string(JSON.stringify(report, "\t"))
	out.flush()
	var written: bool = out.get_error() == OK
	out.close()
	quit(0 if passed and written else 2)

func _digest(value: Variant) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()
