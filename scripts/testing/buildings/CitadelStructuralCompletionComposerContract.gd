extends SceneTree

## Fresh ordinary-composer source gate. No archive reconstruction, publication,
## rendering, gameplay, NPC or navigation admission is exercised.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Interior = preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const Layout = preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const UrbanFurniture = preload("res://scripts/buildings/CitadelUrbanHomeFurnishingPlanner.gd")
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
	var original_ids: Array[String] = []
	for part in source.parts:
		if part != null: original_ids.append(String(part.id))
	stage_started_msec = Time.get_ticks_msec()
	if not _write_progress(progress_path, "compose_prepared_started", 0, stage_started_msec - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:compose_prepared_started"}
	var prepared: Dictionary = Urban.compose_prepared(source, seed, _compose_progress.bind(progress_path, total_started_msec, seed))
	if not _write_progress(progress_path, "compose_prepared_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, false):
		return {"passed": false, "reason": "progress_write_failed:compose_prepared_completed"}
	if not prepared.get("ready", false):
		return {"passed": false, "reason": prepared.get("reason", "composer_failed"),
			"structuralCompletionFailure": prepared.get("structuralCompletionFailure", {}),
			"shopFailure": prepared.get("shopFailure", {}),
			"civicClearanceFailure": prepared.get("civicClearanceFailure", {})}
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
	# Recomposition may replace records owned by generated districts.  The stable
	# contract is that every source ID which remains in the result appears once,
	# and that retained IDs keep their relative order.  Generated home contents
	# are validated below through their room declarations instead of authorship
	# prefixes or object identity.
	var final_counts := {}
	var final_indices := {}
	for index in range(blueprint.parts.size()):
		var current_part = blueprint.parts[index]
		if current_part == null: continue
		var current_id := String(current_part.id)
		final_counts[current_id] = int(final_counts.get(current_id, 0)) + 1
		if not final_indices.has(current_id): final_indices[current_id] = index
	var retained_source_ids: Array[String] = []
	var retained_source_ids_unique_and_ordered := true
	var previous_index := -1
	for original_id in original_ids:
		if not final_indices.has(original_id): continue
		retained_source_ids.append(original_id)
		var final_index := int(final_indices[original_id])
		retained_source_ids_unique_and_ordered = retained_source_ids_unique_and_ordered \
			and int(final_counts.get(original_id, 0)) == 1 and final_index > previous_index
		previous_index = final_index
	var home_audit := _audit_urban_homes(blueprint, prepared.furnishingPlan)
	var urban_window_ornaments := 0
	for furnishing_part in prepared.furnishingPlan.parts:
		if furnishing_part == null: continue
		var bound_window_id := String(furnishing_part.recipe.get("interiorProgramWindowId", ""))
		if bound_window_id.is_empty(): continue
		var bound_window = blueprint.find_part(bound_window_id)
		if bound_window != null and String(bound_window.semantic) in ["citadel_urban_window", "citadel_household_projecting_bay"]:
			urban_window_ornaments += 1
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
			and stage_kinds == ["chimney", "bracket_first", "sign", "party_wall", "bracket_retry", "bunting", "threshold"],
		"one_complete_commit_with_append_only_parts": completion.get("commit", {}).get("ready", false) \
			and completion.commit.existingPartCount > 0 and completion.commit.addedPartCount > 0,
		"fresh_whole_validation_zero": grid.ready and physical.violations.is_empty() and failed_ids.is_empty(),
		"manifest_and_facade_metadata_retained": manifest.get("ready", false) and blueprint.recipe.get("facadeApertures") is Dictionary,
		"all_declared_sign_anchors_materialized": anchors_complete,
		"retained_source_ids_unique_and_ordered": not retained_source_ids.is_empty() and retained_source_ids_unique_and_ordered,
		"interior_window_program_complete_for_every_bound_window": window_count > 0 \
			and window_audit.get("apertureCount") == window_count - window_audit.get("nonInteriorWindowCount", 0) \
			and window_audit.get("publishedWindowCount") == window_audit.get("apertureCount") \
			and (window_audit.get("violations", []) as Array).is_empty(),
		"urban_windows_have_valid_declared_room_wall_bindings": declared_urban_windows > 0 and declared_window_bindings_valid,
		"generated_urban_homes_have_room_owned_livable_furniture": home_audit.get("ready", false),
		"urban_clear_view_windows_have_no_ornaments": urban_window_ornaments == 0,
		"furniture_and_reservations_preserved_byte_exact": not prepared.furnishingPlan.parts.is_empty() \
			and prepared.furnishingPlan.protected_access_reservations is Array \
			and prepared.get("furnishingPreservation", {}).get("ready", false) \
			and prepared.furnishingPreservation.get("furnitureBytesExact", false) \
			and prepared.furnishingPreservation.get("reservationBytesExact", false)}
	var report := {"passed": checks.values().all(func(value): return value == true), "checks": checks, "seed": seed,
		"partCount": blueprint.parts.size(), "furnitureCount": prepared.furnishingPlan.parts.size(), "windowCount": window_count,
		"windowInteriorProgram": window_audit,
		"urbanHomeAudit": home_audit, "urbanWindowOrnamentCount": urban_window_ornaments,
		"retainedSourcePartCount": retained_source_ids.size(),
		"reservationCount": prepared.furnishingPlan.protected_access_reservations.size(), "failedIds": failed_ids,
		"completion": completion,
		"scope": "Fresh ordinary procedural composer and source structural gate only; no publication, rendering, gameplay, NPC/navigation, performance or headed claim."}
	if not _write_progress(progress_path, "final_report_assembly_completed", Time.get_ticks_msec() - stage_started_msec, Time.get_ticks_msec() - total_started_msec, seed, true):
		return {"passed": false, "reason": "progress_write_failed:final_report_assembly_completed"}
	return report


func _audit_urban_homes(blueprint, plan) -> Dictionary:
	var homes: Array = blueprint.recipe.get("citadelUrbanHomes", []) as Array
	if homes.is_empty() or plan == null:
		return {"ready": false, "reason": "missing_generated_homes_or_plan"}
	var rooms := {}
	for room_value in blueprint.rooms:
		if room_value is Dictionary:
			rooms[String((room_value as Dictionary).get("id", ""))] = room_value
	var seen := {}
	var results: Array = []
	var valid := true
	var counted_parts := 0
	for home_value in homes:
		if not home_value is Dictionary:
			valid = false
			continue
		var home: Dictionary = home_value as Dictionary
		var home_id := String(home.get("id", ""))
		var room_id := String(home.get("roomId", ""))
		if home_id.is_empty() or seen.has(home_id) or not rooms.has(room_id):
			valid = false
			continue
		seen[home_id] = true
		var room: Dictionary = rooms[room_id] as Dictionary
		var room_bounds: AABB = room.get("bounds", AABB()) as AABB
		var street_side := signf(float(home.get("streetSide", 0.0)))
		var counts := {}
		var part_count := 0
		var contained := true
		var facade_clear := not is_zero_approx(street_side)
		for part in plan.parts:
			if part == null or String(part.recipe.get("citadelUrbanHomeId", "")) != home_id: continue
			part_count += 1
			counts[String(part.archetype)] = int(counts.get(String(part.archetype), 0)) + 1
			contained = contained and String(part.room_id) == room_id
			var bounds := Layout.horizontal_bounds(part.position, part.occupied_size, part.rotation)
			contained = contained and bounds.position.x >= room_bounds.position.x - 0.015 and bounds.end.x <= room_bounds.end.x + 0.015 \
				and bounds.position.z >= room_bounds.position.z - 0.015 and bounds.end.z <= room_bounds.end.z + 0.015
			facade_clear = facade_clear and (bounds.end.x <= room_bounds.end.x - UrbanFurniture.STREET_FACADE_FURNITURE_CLEARANCE + 0.015 if street_side > 0.0 \
				else bounds.position.x >= room_bounds.position.x + UrbanFurniture.STREET_FACADE_FURNITURE_CLEARANCE - 0.015)
		var required := ["bed", "table", "chair", "hearth"]
		var passed := part_count > 0 and contained and facade_clear and required.all(func(archetype): return int(counts.get(archetype, 0)) > 0)
		results.append({"id": home_id, "roomId": room_id, "partCount": part_count, "archetypes": counts, "contained": contained, "streetFacadeClear": facade_clear, "passed": passed})
		counted_parts += part_count
		valid = valid and passed
	var urban_owned_parts := 0
	for part in plan.parts:
		if part != null and String(part.recipe.get("castleResidenceFamily", "")) == "urban_home": urban_owned_parts += 1
	return {"ready": valid and seen.size() == homes.size() and results.size() == homes.size() and urban_owned_parts == counted_parts,
		"generatedHomeCount": homes.size(), "ownedPartCount": urban_owned_parts, "homes": results}


func _write_progress(path: String, stage: String, completed_stage_elapsed_msec: int, total_elapsed_msec: int, seed: int, worker_complete: bool) -> bool:
	var record := {"schema": "citadel_structural_composer_progress/v1", "currentStage": stage, "completedStageElapsedMs": completed_stage_elapsed_msec, "totalElapsedMs": total_elapsed_msec, "seed": seed, "workerComplete": worker_complete}
	_progress_records.append(record)
	if _progress_records.size() > 2048:
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
		# Repeated procedural producers legitimately reuse one phase name for
		# independently sampled houses.  Each start replaces only that phase's
		# timing origin; it is not a duplicate command.
		_compose_stage_started_msec[stage_key] = now
	elif stage.ends_with("_completed"):
		stage_key = stage.trim_suffix("_completed")
		if not _compose_stage_started_msec.has(stage_key):
			return true
		completed_stage_elapsed_msec = now - int(_compose_stage_started_msec[stage_key])
	else:
		# Granular producer observations (candidate, preview, recipe, spacing)
		# are cancellation checkpoints, not phase boundaries.  The composer may
		# add them without invalidating this runner's bounded phase timeline.
		return true
	_write_progress(path, stage, completed_stage_elapsed_msec, now - total_started_msec, seed, false)
	# This callback observes a full composition contract.  Cancellation behavior
	# has its own runner; telemetry persistence must never alter production work.
	return true

func _json(value: Variant) -> Variant:
	if value is Vector2: return [value.x, value.y]
	if value is Vector3: return [value.x, value.y, value.z]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Object:
		return {"objectClass": value.get_class(), "instanceId": value.get_instance_id()}
	if value is Callable:
		return {"callable": true}
	if value is Dictionary:
		var result := {}
		for key: Variant in value: result[String(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value

func _finalize() -> void:
	if _worker != null and _worker.is_started(): _worker.wait_to_finish()
