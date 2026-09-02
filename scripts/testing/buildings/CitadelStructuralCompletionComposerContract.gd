extends SceneTree

## Fresh ordinary-composer source gate. No archive reconstruction, publication,
## rendering, gameplay, NPC or navigation admission is exercised.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Interior = preload("res://scripts/buildings/BuildingInteriorProgram.gd")
var _worker: Thread
var _frames := 0
var _progress_records: Array[Dictionary] = []
var _compose_stage_started_msec: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var report_path := OS.get_environment("VOXEL_STRUCTURAL_COMPOSER_REPORT").simplify_path()
	var progress_path := OS.get_environment("VOXEL_STRUCTURAL_COMPOSER_PROGRESS").simplify_path()
	if not report_path.is_absolute_path() or not progress_path.is_absolute_path() or report_path.to_lower() == progress_path.to_lower() \
			or FileAccess.file_exists(report_path) or FileAccess.file_exists(progress_path) \
			or not DirAccess.dir_exists_absolute(report_path.get_base_dir()) or not DirAccess.dir_exists_absolute(progress_path.get_base_dir()):
		quit(2); return
	var seed := int(OS.get_environment("VOXEL_STRUCTURAL_COMPOSER_SEED"))
	if seed == 0: seed = 208159
	var total_started_msec := Time.get_ticks_msec()
	if not _write_progress(progress_path, "worker_started", 0, 0, seed, false):
		quit(2); return
	_worker = Thread.new()
	if _worker.start(_prepare.bind(seed, progress_path, total_started_msec)) != OK:
		quit(2); return
	while _worker.is_alive():
		await process_frame
		_frames += 1
	var report: Dictionary = _worker.wait_to_finish()
	_worker = null
	report["mainLoopFrames"] = _frames
	report["workerJoined"] = true
	report["passed"] = report.get("passed", false) and _frames > 0
	var output := FileAccess.open(report_path, FileAccess.WRITE)
	if output == null:
		quit(2); return
	output.store_string(JSON.stringify(_json(report), "\t"))
	output.close()
	quit(0 if report.passed else 1)

func _prepare(seed: int, progress_path: String, total_started_msec: int) -> Dictionary:
	var stage_started_msec := Time.get_ticks_msec()
	if not _write_progress(progress_path, "castle_build_started", 0, stage_started_msec - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:castle_build_started"}
	var source = Castle.build(seed, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	if not _write_progress(progress_path, "castle_build_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:castle_build_completed"}
	if source == null: return {"passed": false, "reason": "castle_build_failed"}
	var original_objects: Dictionary = {}
	for part in source.parts: original_objects[part.id] = part
	stage_started_msec = Time.get_ticks_msec()
	if not _write_progress(progress_path, "compose_prepared_started", 0, stage_started_msec - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:compose_prepared_started"}
	var prepared: Dictionary = Urban.compose_prepared(source, seed, _compose_progress.bind(progress_path, total_started_msec, seed))
	if not _write_progress(progress_path, "compose_prepared_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:compose_prepared_completed"}
	if not prepared.get("ready", false):
		return {"passed": false, "reason": prepared.get("reason", "composer_failed"),
			"structuralCompletionFailure": prepared.get("structuralCompletionFailure", {})}
	var blueprint = prepared.blueprint
	var completion: Dictionary = prepared.get("structuralCompletion", {})
	var manifest := Manifest.read(blueprint)
	stage_started_msec = Time.get_ticks_msec()
	if not _write_progress(progress_path, "copy_started", 0, stage_started_msec - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:copy_started"}
	var proof = Copy.copy_blueprint(blueprint.snapshot())
	Copy.clear_caches(proof)
	if not _write_progress(progress_path, "copy_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:copy_completed"}
	stage_started_msec = Time.get_ticks_msec()
	if not _write_progress(progress_path, "validation_grid_started", 0, stage_started_msec - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:validation_grid_started"}
	var grid := Copy.validation_grid_work(proof)
	if not _write_progress(progress_path, "validation_grid_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:validation_grid_completed"}
	stage_started_msec = Time.get_ticks_msec()
	if not _write_progress(progress_path, "physical_validation_started", 0, stage_started_msec - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:physical_validation_started"}
	var physical: Dictionary = proof.validate_physical_integrity() if grid.ready else {"checks": [], "violations": ["validation_work_limit"]}
	if not _write_progress(progress_path, "physical_validation_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:physical_validation_completed"}
	var failed_ids: Array = Copy.failed_ids(physical)
	stage_started_msec = Time.get_ticks_msec()
	if not _write_progress(progress_path, "interior_audit_started", 0, stage_started_msec - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:interior_audit_started"}
	var window_audit: Dictionary = Interior.audit_plan(blueprint, prepared.furnishingPlan)
	if not _write_progress(progress_path, "interior_audit_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:interior_audit_completed"}
	stage_started_msec = Time.get_ticks_msec()
	if not _write_progress(progress_path, "final_report_assembly_started", 0, stage_started_msec - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:final_report_assembly_started"}
	var window_count := 0
	var declared_urban_windows := 0
	var declared_window_bindings_valid := true
	for part in blueprint.parts:
		if part == null or String(part.kind) != "window": continue
		window_count += 1
		if String(part.recipe.get("semantic", "")) not in ["citadel_urban_window", "citadel_household_projecting_bay"]: continue
		declared_urban_windows += 1
		if Interior.room_for_window(blueprint.rooms, part.position, part.recipe.get("roomId", ""), part.recipe.get("interiorInwardDirection", Vector3.ZERO), part.recipe.get("interiorWallOffset", 0.0)).is_empty():
			declared_window_bindings_valid = false
	var retained_identity := true
	for part in blueprint.parts:
		if original_objects.has(part.id) and not is_same(original_objects[part.id], part): retained_identity = false
	var anchors_complete: bool = bool(manifest.get("ready", false))
	if anchors_complete:
		for record: Dictionary in manifest.records:
			for id: String in record.signAnchorIds:
				var part = blueprint.find_part(id)
				if part == null or not part.collision_enabled or part.rotation != Vector3.ZERO \
						or part.physical_intent not in ["structural_mass", "structural_root"]:
					anchors_complete = false
	var stage_kinds: Array = completion.get("stages", []).map(func(stage): return stage.kind)
	var checks := {
		"ordinary_composer_ready_same_authority": is_same(blueprint, source),
		"completion_gate_zero_and_ordered": completion.get("ready", false) and completion.get("finalFailureCount") == 0 \
			and stage_kinds == ["chimney", "bracket_first", "sign", "party_wall", "bracket_retry", "threshold"],
		"one_complete_commit_with_append_only_parts": completion.get("commit", {}).get("ready", false) \
			and completion.commit.existingPartCount > 0 and completion.commit.addedPartCount > 0,
		"fresh_whole_validation_zero": grid.ready and physical.violations.is_empty() and failed_ids.is_empty(),
		"manifest_and_facade_metadata_retained": manifest.get("ready", false) and blueprint.recipe.get("facadeApertures") is Dictionary,
		"all_declared_sign_anchors_materialized": anchors_complete,
		"retained_preexisting_part_objects": retained_identity,
		"window_interior_program_complete": window_count == 77 and window_audit.get("passed", false) \
			and window_audit.get("apertureCount") == window_count and window_audit.get("publishedWindowCount") == window_count \
			and window_audit.get("nonInteriorWindowCount") == 0 and (window_audit.get("violations", []) as Array).is_empty(),
		"urban_windows_have_valid_declared_room_wall_bindings": declared_urban_windows > 0 and declared_window_bindings_valid,
		"formerly_unclaimed_window_has_recipe_pair": prepared.furnishingPlan.parts.any(func(part): return part != null and String(part.id) == "interior_window_urban_row_03_left_window_02_-1_plant") \
			and prepared.furnishingPlan.parts.any(func(part): return part != null and String(part.id) == "interior_window_urban_row_03_left_window_02_-1_candle"),
		"furniture_and_reservations_preserved_byte_exact": prepared.furnishingPlan.parts.size() == 154 \
			and prepared.furnishingPlan.protected_access_reservations is Array \
			and prepared.get("furnishingPreservation", {}).get("ready", false) \
			and prepared.furnishingPreservation.get("furnitureBytesExact", false) \
			and prepared.furnishingPreservation.get("reservationBytesExact", false)}
	var report := {"passed": checks.values().all(func(value): return value == true), "checks": checks, "seed": seed,
		"partCount": blueprint.parts.size(), "furnitureCount": prepared.furnishingPlan.parts.size(), "windowCount": window_count,
		"windowInteriorProgram": window_audit,
		"reservationCount": prepared.furnishingPlan.protected_access_reservations.size(), "failedIds": failed_ids,
		"completion": completion,
		"scope": "Fresh ordinary procedural composer and source structural gate only; no publication, rendering, gameplay, NPC/navigation, performance or headed claim."}
	if not _write_progress(progress_path, "final_report_assembly_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, true):
		return {"passed": false, "reason": "progress_write_failed:final_report_assembly_completed"}
	return report


func _write_progress(path: String, stage: String, completed_stage_elapsed_msec: int, total_elapsed_msec: int, seed: int, worker_complete: bool) -> bool:
	var record := {"schema": "citadel_structural_composer_progress/v1", "currentStage": stage, "completedStageElapsedMs": completed_stage_elapsed_msec, "totalElapsedMs": total_elapsed_msec, "seed": seed, "workerComplete": worker_complete}
	_progress_records.append(record)
	if _progress_records.size() > 48:
		return false
	var exists := FileAccess.file_exists(path)
	var output := FileAccess.open(path, FileAccess.READ_WRITE if exists else FileAccess.WRITE)
	if output == null:
		return false
	if exists:
		output.seek_end()
	output.store_line(JSON.stringify(record))
	output.flush()
	output.close()
	return true


func _compose_progress(stage: String, path: String, total_started_msec: int, seed: int) -> bool:
	var now := Time.get_ticks_msec()
	var completed_stage_elapsed_msec := 0
	var stage_key := ""
	if stage.ends_with("_started"):
		stage_key = stage.trim_suffix("_started")
		if _compose_stage_started_msec.has(stage_key):
			return false
		_compose_stage_started_msec[stage_key] = now
	elif stage.ends_with("_completed"):
		stage_key = stage.trim_suffix("_completed")
		if not _compose_stage_started_msec.has(stage_key):
			return false
		completed_stage_elapsed_msec = now - int(_compose_stage_started_msec[stage_key])
	else:
		return false
	return _write_progress(path, stage, completed_stage_elapsed_msec, now - total_started_msec, seed, false)

func _json(value: Variant) -> Variant:
	if value is Vector2: return [value.x, value.y]
	if value is Vector3: return [value.x, value.y, value.z]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key: Variant in value: result[String(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value

func _finalize() -> void:
	if _worker != null and _worker.is_started(): _worker.wait_to_finish()
