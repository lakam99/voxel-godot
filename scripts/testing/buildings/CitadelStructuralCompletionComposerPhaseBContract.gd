extends SceneTree

## Phase B: verify the exact Phase-A pair against current source/engine, then
## reconstruct and independently run the complete post-commit acceptance gate.
const Codec := preload("res://scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd")
const Copy := preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Manifest := preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Interior := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const FurnishingPlan := preload("res://scripts/buildings/FurnishingPlan.gd")
const FurnishingPart := preload("res://scripts/buildings/FurnishingPart.gd")
const WindowInventory := preload("res://scripts/testing/buildings/CitadelWindowProgramInventory.gd")

const MAX_PHASE_A_REPORT_BYTES := 8 * 1024 * 1024
var _worker: Thread
var _frames := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var output_path := OS.get_environment("VOXEL_STRUCTURAL_PHASE_B_REPORT").simplify_path()
	var output_temp := OS.get_environment("VOXEL_STRUCTURAL_PHASE_B_REPORT_TEMP").simplify_path()
	if not output_path.is_absolute_path() or not output_temp.is_absolute_path() or output_path.get_base_dir() != output_temp.get_base_dir() \
			or FileAccess.file_exists(output_path) or FileAccess.file_exists(output_temp):
		quit(2)
		return
	_worker = Thread.new()
	if _worker.start(_validate) != OK:
		quit(2)
		return
	while _worker.is_alive():
		await process_frame
		_frames += 1
	var report: Dictionary = _worker.wait_to_finish()
	_worker = null
	report["mainLoopFrames"] = _frames
	report["workerJoined"] = true
	report["passed"] = bool(report.get("passed", false)) and _frames > 0
	var report_bytes := JSON.stringify(_json(report), "\t").to_utf8_buffer()
	var write := Codec.write_atomic_fresh(output_path, output_temp, report_bytes)
	if not write.ready:
		quit(2)
		return
	quit(0 if report.passed else 1)


func _validate() -> Dictionary:
	var phase_a_report_path := OS.get_environment("VOXEL_STRUCTURAL_PHASE_A_REPORT").simplify_path()
	var checkpoint_path := OS.get_environment("VOXEL_STRUCTURAL_CHECKPOINT").simplify_path()
	var expected_report_sha := OS.get_environment("VOXEL_STRUCTURAL_PHASE_A_REPORT_SHA256")
	var expected_checkpoint_sha := OS.get_environment("VOXEL_STRUCTURAL_CHECKPOINT_SHA256")
	var seed := int(OS.get_environment("VOXEL_STRUCTURAL_COMPOSER_SEED"))
	var run_id := OS.get_environment("VOXEL_STRUCTURAL_RUN_ID")
	if not phase_a_report_path.is_absolute_path() or not checkpoint_path.is_absolute_path() or seed == 0 \
			or not FileAccess.file_exists(phase_a_report_path) or not FileAccess.file_exists(checkpoint_path):
		return _fail_report("phase_b_input_missing")
	var report_bytes := FileAccess.get_file_as_bytes(phase_a_report_path)
	if report_bytes.is_empty() or report_bytes.size() > MAX_PHASE_A_REPORT_BYTES or Codec.sha256_bytes(report_bytes) != expected_report_sha:
		return _fail_report("phase_a_report_outer_sha_mismatch")
	var parsed: Variant = JSON.parse_string(report_bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		return _fail_report("phase_a_report_parse_failed")
	var phase_a_report: Dictionary = parsed
	var checkpoint_bytes := FileAccess.get_file_as_bytes(checkpoint_path)
	if checkpoint_bytes.is_empty() or checkpoint_bytes.size() > Codec.MAX_CHECKPOINT_BYTES or Codec.sha256_bytes(checkpoint_bytes) != expected_checkpoint_sha:
		return _fail_report("checkpoint_outer_sha_mismatch")
	var fingerprint := Codec.source_fingerprint()
	var engine := Codec.engine_identity()
	if not fingerprint.ready or not engine.ready:
		return _fail_report("phase_b_environment_identity_failed")
	var report_binding := Codec.phase_a_report_matches_checkpoint(phase_a_report, expected_report_sha,
		expected_checkpoint_sha, checkpoint_bytes.size(), seed, fingerprint, engine)
	if not report_binding.ready:
		return _fail_report(String(report_binding.reason), {"detail": report_binding})
	var decoded := Codec.decode_payload(checkpoint_bytes, expected_checkpoint_sha, seed)
	if not decoded.ready:
		return _fail_report(String(decoded.reason), {"detail": decoded})
	var checkpoint: Dictionary = decoded.payload
	var pair_binding := {
		"runId": String(checkpoint.runId) == run_id and String(phase_a_report.get("runId", "")) == run_id,
		"core": phase_a_report.get("phaseACore", {}) is Dictionary \
			and Codec.phase_a_cores_equal(phase_a_report.phaseACore, checkpoint.phaseACore),
		"coreSha": String(phase_a_report.get("phaseACoreSha256", "")) == String(checkpoint.phaseACoreSha256),
		"fingerprint": Codec.fingerprints_equal(checkpoint.payload.sourceFingerprint, fingerprint),
		"engine": Codec.engines_equal(checkpoint.payload.engineIdentity, engine)}
	if not pair_binding.values().all(func(value): return value == true):
		return _fail_report("phase_a_pair_binding_mismatch", {"detail": pair_binding})
	var snapshot: Dictionary = checkpoint.payload.blueprintSnapshot
	var furnishing_snapshot: Dictionary = checkpoint.payload.furnishingSnapshot
	var reservations: Array = checkpoint.payload.furnishingReservations
	# Reconstruction begins only after every outer, environment, core, section,
	# count and pair binding above has passed.
	var blueprint = Copy.copy_blueprint(snapshot)
	if Codec.hash_variant(blueprint.snapshot()) != String(checkpoint.payload.sectionHashes.blueprintSnapshot):
		return _fail_report("blueprint_reconstruction_mismatch")
	Copy.clear_caches(blueprint)
	var plan = FurnishingPlan.new(String(furnishing_snapshot.get("id", "")), int(furnishing_snapshot.get("seed", 0)), String(furnishing_snapshot.get("sourceBlueprintId", "")))
	for record in furnishing_snapshot.parts:
		plan.parts.append(FurnishingPart.new(record))
	plan.protected_access_reservations = reservations.duplicate(true)
	plan.egress_diagnostics = (furnishing_snapshot.get("egressDiagnostics", {}) as Dictionary).duplicate(true)
	if Codec.hash_variant(plan.snapshot()) != String(checkpoint.payload.sectionHashes.furnishingSnapshot) \
			or Codec.hash_variant(plan.protected_access_reservations) != String(checkpoint.payload.sectionHashes.reservations):
		return _fail_report("furnishing_reconstruction_mismatch")
	var grid := Copy.validation_grid_work(blueprint)
	var physical: Dictionary = blueprint.validate_physical_integrity() if grid.ready else {"checks": [], "violations": ["validation_work_limit"]}
	var failed_ids: Array = Copy.failed_ids(physical)
	var manifest := Manifest.read(blueprint)
	var window_verification := inspect_window_program(blueprint, plan)
	if not window_verification.ready:
		return _fail_report("window_program_inventory_failed", {"detail": window_verification})
	var window_inventory: Dictionary = window_verification.inventory
	var window_audit: Dictionary = window_verification.audit
	var window_count := 0
	var declared_urban_windows := 0
	var declared_window_bindings_valid := true
	for part in blueprint.parts:
		if part == null or String(part.kind) != "window":
			continue
		window_count += 1
		if String(part.recipe.get("semantic", "")) not in ["citadel_urban_window", "citadel_household_projecting_bay"]:
			continue
		declared_urban_windows += 1
		if Interior.room_for_window(blueprint.rooms, part.position, part.recipe.get("roomId", ""), part.recipe.get("interiorInwardDirection", Vector3.ZERO), part.recipe.get("interiorWallOffset", 0.0)).is_empty():
			declared_window_bindings_valid = false
	var anchors_complete: bool = bool(manifest.get("ready", false))
	if anchors_complete:
		for record: Dictionary in manifest.records:
			for id: String in record.signAnchorIds:
				var anchor = blueprint.find_part(id)
				if anchor == null or not anchor.collision_enabled or anchor.rotation != Vector3.ZERO \
						or anchor.physical_intent not in ["structural_mass", "structural_root"]:
					anchors_complete = false
	var assertions: Dictionary = checkpoint.payload.phaseAAssertions
	var completion: Dictionary = assertions.completion
	var same_process: Dictionary = assertions.sameProcess
	var checks := {
		"ordinary_composer_ready_same_authority": bool(same_process.get("identicalSourceObject", false)),
		"completion_gate_zero_and_ordered": bool(completion.get("ready", false)) and int(completion.get("finalFailureCount", -1)) == 0 \
			and completion.get("stageKinds", []) == ["chimney", "bracket_first", "sign", "party_wall", "bracket_retry", "threshold"],
		"one_complete_commit_with_append_only_parts": bool(completion.get("commitReady", false)) \
			and int(completion.get("commitExistingPartCount", -1)) > 0 and int(completion.get("commitAddedPartCount", -1)) > 0 \
			and bool(same_process.get("precomposeIdsUnique", false)) and int(same_process.get("precomposePartCount", 0)) > 0 \
			and bool(same_process.get("structuralBaselineObservedExactlyOnce", false)) \
			and bool(same_process.get("structuralBaselineIdsUnique", false)) and bool(same_process.get("finalIdsUnique", false)) \
			and int(same_process.get("structuralBaselineCount", -1)) == int(same_process.get("commitExistingPartCount", -2)) \
			and int(same_process.get("commitExistingPartCount", -1)) == int(completion.get("commitExistingPartCount", -2)) \
			and int(same_process.get("commitAddedPartCount", -1)) == int(completion.get("commitAddedPartCount", -2)) \
			and int(same_process.get("postCommitPartCount", 0)) > 0 \
			and bool(same_process.get("postCommitSuffixBound", false)) \
			and int(same_process.get("finalPartCount", -1)) == int(same_process.get("commitExistingPartCount", -1)) \
				+ int(same_process.get("commitAddedPartCount", -1)) + int(same_process.get("postCommitPartCount", -1)),
		"fresh_whole_validation_zero": grid.ready and physical.violations.is_empty() and failed_ids.is_empty(),
		"manifest_and_facade_metadata_retained": manifest.get("ready", false) and blueprint.recipe.get("facadeApertures") is Dictionary,
		"all_declared_sign_anchors_materialized": anchors_complete,
		"retained_preexisting_part_objects": bool(same_process.get("retainedPreexistingPartObjects", false)),
		"window_interior_program_complete": window_inventory.get("ready", false) and window_count > 0 \
			and window_count == window_inventory.get("windowCount", -1) and window_audit.get("passed", false) \
			and window_audit.get("apertureCount") == window_count and window_audit.get("publishedWindowCount") == window_count \
			and window_audit.get("nonInteriorWindowCount") == 0 and (window_audit.get("violations", []) as Array).is_empty() \
			and window_verification.planUnchanged,
		"urban_windows_have_valid_declared_room_wall_bindings": declared_urban_windows > 0 and declared_window_bindings_valid,
		"every_declared_window_has_exact_recipe_pair": window_inventory.get("ready", false) \
			and window_inventory.get("programPartCount", -1) == 2 * window_count,
		"furniture_and_reservations_preserved_byte_exact": plan.parts.size() == int(checkpoint.payload.counts.furniture) \
			and bool(completion.get("furnishingPreservationReady", false)) and bool(completion.get("furnitureBytesExact", false)) \
			and bool(completion.get("reservationBytesExact", false))}
	return {"schema": "citadel_structural_composer_phase_b_report/v1", "revision": Codec.REVISION,
		"passed": checks.values().all(func(value): return value == true), "checks": checks, "seed": seed, "runId": run_id,
		"phaseAReportSha256": expected_report_sha, "checkpointSha256": expected_checkpoint_sha,
		"phaseACoreSha256": checkpoint.phaseACoreSha256, "sourceFingerprint": fingerprint, "engineIdentity": engine,
		"partCount": blueprint.parts.size(), "furnitureCount": plan.parts.size(), "reservationCount": reservations.size(),
		"windowCount": window_count, "failedIds": failed_ids, "physicalViolations": physical.violations,
		"windowInteriorProgram": window_audit, "windowProgramInventory": window_inventory, "completion": completion,
		"scope": "SHA-bound fresh post-commit procedural structural gate only; no publication, rendering, gameplay, NPC/navigation, performance or headed claim."}


static func inspect_window_program(blueprint, plan) -> Dictionary:
	var inventory := WindowInventory.inspect(blueprint, plan)
	if not inventory.ready:
		return {"ready": false, "inventory": inventory, "auditPerformed": false}
	# Reject invalid identities/types BEFORE any mutating audit or typed reader.
	var audit_blueprint = Copy.copy_blueprint(blueprint.snapshot())
	var plan_before := Codec.hash_variant(plan.snapshot())
	var audit := Interior.audit_plan(audit_blueprint, plan)
	var derived_inventory := WindowInventory.inspect(audit_blueprint, plan)
	if not derived_inventory.ready or not derived_inventory.get("apertureCachePresent", false) \
			or derived_inventory.windowIds != inventory.windowIds:
		return {"ready": false, "inventory": inventory, "derivedInventory": derived_inventory, "auditPerformed": true}
	return {"ready": true, "inventory": inventory, "derivedInventory": derived_inventory, "audit": audit, "auditPerformed": true,
		"planUnchanged": plan_before == Codec.hash_variant(plan.snapshot())}


func _fail_report(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["schema"] = "citadel_structural_composer_phase_b_report/v1"
	result["revision"] = Codec.REVISION
	result["passed"] = false
	result["reason"] = reason
	return result


func _json(value: Variant) -> Variant:
	if value is Vector2: return [value.x, value.y]
	if value is Vector3: return [value.x, value.y, value.z]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key in value: result[String(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value


func _finalize() -> void:
	if _worker != null and _worker.is_started():
		_worker.wait_to_finish()
