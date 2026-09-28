extends SceneTree

## Phase A: run the ordinary composer once and preserve facts that require the
## live object graph. The emitted checkpoint is transport, not gate acceptance.
const Castle := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Codec := preload("res://scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd")

var _worker: Thread
var _frames := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var report_path := OS.get_environment("VOXEL_STRUCTURAL_PHASE_A_REPORT").simplify_path()
	var report_temp_path := OS.get_environment("VOXEL_STRUCTURAL_PHASE_A_REPORT_TEMP").simplify_path()
	var checkpoint_path := OS.get_environment("VOXEL_STRUCTURAL_CHECKPOINT").simplify_path()
	var checkpoint_temp_path := OS.get_environment("VOXEL_STRUCTURAL_CHECKPOINT_TEMP").simplify_path()
	var paths := [report_path, report_temp_path, checkpoint_path, checkpoint_temp_path]
	var distinct_paths: Dictionary = {}
	for path in paths:
		distinct_paths[String(path).to_lower()] = true
	if paths.any(func(path): return not path.is_absolute_path() or FileAccess.file_exists(path)) or distinct_paths.size() != paths.size() \
			or paths.any(func(path): return path.get_base_dir() != report_path.get_base_dir()):
		quit(2)
		return
	var seed := int(OS.get_environment("VOXEL_STRUCTURAL_COMPOSER_SEED"))
	if seed == 0:
		seed = 208159
	var run_id := OS.get_environment("VOXEL_STRUCTURAL_RUN_ID")
	_worker = Thread.new()
	if _worker.start(_prepare.bind(run_id, seed, checkpoint_path, checkpoint_temp_path)) != OK:
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
	var report_bytes := JSON.stringify(report, "\t").to_utf8_buffer()
	var write := Codec.write_atomic_fresh(report_path, report_temp_path, report_bytes)
	if not write.ready:
		quit(2)
		return
	quit(0 if report.passed else 1)


func _prepare(run_id: String, seed: int, checkpoint_path: String, checkpoint_temp_path: String) -> Dictionary:
	var fingerprint := Codec.source_fingerprint()
	var engine := Codec.engine_identity()
	if not fingerprint.ready or not engine.ready:
		return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
			"passed": false, "reason": "environment_identity_failed", "sourceFingerprint": fingerprint, "engineIdentity": engine}
	var source = Castle.build(seed, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	if source == null:
		return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed, "passed": false, "reason": "castle_build_failed"}
	var precompose_ids: Dictionary = {}
	if source.parts.is_empty():
		return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
			"passed": false, "reason": "precompose_source_inventory_empty"}
	for part in source.parts:
		if part == null or String(part.id).is_empty() or precompose_ids.has(String(part.id)):
			return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
				"passed": false, "reason": "precompose_source_inventory_invalid"}
		precompose_ids[String(part.id)] = true
	var precompose_count: int = source.parts.size()
	var source_snapshot: Dictionary = source.snapshot()
	var source_snapshot_sha := Codec.hash_variant(source_snapshot)
	var source_recipe_sha := Codec.hash_variant(source.recipe)
	var baseline_state := {"observed": 0, "ready": false, "ids": [], "objects": []}
	var prepared: Dictionary = Urban.compose_prepared(source, seed, _capture_structural_baseline.bind(source, baseline_state))
	if not prepared.get("ready", false):
		return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
			"runId": run_id, "sourceFingerprint": fingerprint, "engineIdentity": engine,
			"passed": false, "reason": prepared.get("reason", "composer_failed"),
			"structuralCompletionFailure": prepared.get("structuralCompletionFailure", {})}
	var blueprint = prepared.blueprint
	var completion: Dictionary = prepared.get("structuralCompletion", {})
	var stage_kinds: Array = completion.get("stages", []).map(func(stage): return String(stage.kind))
	var final_ids: Dictionary = {}
	for part in blueprint.parts:
		if part == null or String(part.id).is_empty() or final_ids.has(String(part.id)):
			return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
				"passed": false, "reason": "final_source_inventory_invalid"}
		final_ids[String(part.id)] = true
	var completion_facts := {"ready": bool(completion.get("ready", false)),
		"finalFailureCount": int(completion.get("finalFailureCount", -1)), "stageKinds": stage_kinds,
		"commitReady": bool(completion.get("commit", {}).get("ready", false)),
		"commitExistingPartCount": int(completion.get("commit", {}).get("existingPartCount", -1)),
		"commitAddedPartCount": int(completion.get("commit", {}).get("addedPartCount", -1)),
		"furnishingPreservationReady": bool(prepared.get("furnishingPreservation", {}).get("ready", false)),
		"furnitureBytesExact": bool(prepared.get("furnishingPreservation", {}).get("furnitureBytesExact", false)),
		"reservationBytesExact": bool(prepared.get("furnishingPreservation", {}).get("reservationBytesExact", false))}
	var baseline_ids: Array = baseline_state.ids as Array
	var baseline_objects: Array = baseline_state.objects as Array
	var baseline_preserved: bool = bool(baseline_state.ready) and int(baseline_state.observed) == 1 \
		and baseline_ids.size() == completion_facts.commitExistingPartCount and baseline_objects.size() == baseline_ids.size()
	if baseline_preserved:
		for index in range(baseline_ids.size()):
			if index >= blueprint.parts.size() or String(blueprint.parts[index].id) != String(baseline_ids[index]) \
					or not is_same(blueprint.parts[index], baseline_objects[index]):
				baseline_preserved = false
				break
	var committed_end: int = completion_facts.commitExistingPartCount + completion_facts.commitAddedPartCount
	var perimeter: Dictionary = prepared.get("perimeterAlleyBearing", {})
	var expected_suffix_ids: Array = perimeter.get("bearingIds", []) as Array
	var actual_suffix_ids: Array = []
	var suffix_semantics_valid: bool = committed_end >= 0 and committed_end <= blueprint.parts.size()
	if suffix_semantics_valid:
		for index in range(committed_end, blueprint.parts.size()):
			var suffix_part = blueprint.parts[index]
			actual_suffix_ids.append(String(suffix_part.id))
			if String(suffix_part.semantic) != "citadel_perimeter_alley_outer_bearing":
				suffix_semantics_valid = false
	var suffix_bound: bool = bool(perimeter.get("ready", false)) and int(perimeter.get("count", -1)) == actual_suffix_ids.size() \
		and expected_suffix_ids == actual_suffix_ids and suffix_semantics_valid \
		and blueprint.parts.size() == completion_facts.commitExistingPartCount + completion_facts.commitAddedPartCount + actual_suffix_ids.size()
	var same_process_facts := {"identicalSourceObject": is_same(blueprint, source),
		"precomposeIdsUnique": precompose_ids.size() == precompose_count, "precomposePartCount": precompose_count,
		"structuralBaselineObservedExactlyOnce": int(baseline_state.observed) == 1, "structuralBaselineCount": baseline_ids.size(),
		"structuralBaselineIdsUnique": bool(baseline_state.ready), "retainedPreexistingPartObjects": baseline_preserved,
		"finalIdsUnique": final_ids.size() == blueprint.parts.size(), "commitExistingPartCount": completion_facts.commitExistingPartCount,
		"commitAddedPartCount": completion_facts.commitAddedPartCount, "postCommitPartCount": actual_suffix_ids.size(),
		"postCommitSuffixBound": suffix_bound, "finalPartCount": blueprint.parts.size()}
	var phase_a_checks := {
		"ordinary_composer_ready_same_authority": same_process_facts.identicalSourceObject,
		"completion_gate_zero_and_ordered": completion_facts.ready and completion_facts.finalFailureCount == 0 \
			and stage_kinds == ["chimney", "bracket_first", "sign", "party_wall", "bracket_retry", "threshold"],
		"one_complete_commit_with_append_only_parts": completion_facts.commitReady \
			and completion_facts.commitExistingPartCount == baseline_ids.size() and completion_facts.commitAddedPartCount > 0 \
			and suffix_bound and final_ids.size() == blueprint.parts.size() and int(baseline_state.observed) == 1,
		"retained_preexisting_part_objects": baseline_preserved,
		"furniture_and_reservations_preserved_byte_exact": completion_facts.furnishingPreservationReady \
			and completion_facts.furnitureBytesExact and completion_facts.reservationBytesExact}
	if not phase_a_checks.values().all(func(value): return value == true):
		return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
			"passed": false, "reason": "phase_a_same_process_checks_failed", "checks": phase_a_checks}
	var furnishing_snapshot: Dictionary = prepared.furnishingPlan.snapshot()
	var reservations: Array = prepared.furnishingPlan.protected_access_reservations.duplicate(true)
	var checkpoint := Codec.make_payload(run_id, seed, source_snapshot_sha, source_recipe_sha, blueprint.snapshot(),
		furnishing_snapshot, reservations, completion_facts, same_process_facts, fingerprint, engine)
	var encoded := Codec.encode_payload(checkpoint)
	if not encoded.ready:
		return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
			"passed": false, "reason": encoded.get("reason", "checkpoint_encode_failed"),
			"detail": encoded.get("detail", {}).duplicate(true)}
	var checkpoint_write := Codec.write_atomic_fresh(checkpoint_path, checkpoint_temp_path, encoded.bytes)
	if not checkpoint_write.ready:
		return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
			"passed": false, "reason": checkpoint_write.get("reason", "checkpoint_write_failed")}
	var report := {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "seed": seed,
		"runId": run_id, "passed": true, "checks": phase_a_checks,
		"phaseACore": checkpoint.phaseACore, "phaseACoreSha256": checkpoint.phaseACoreSha256,
		"checkpointSchema": Codec.SCHEMA, "checkpointSha256": encoded.sha256, "checkpointSize": encoded.size,
		"sourceFingerprint": fingerprint, "engineIdentity": engine,
		"counts": checkpoint.payload.counts, "sectionHashes": checkpoint.payload.sectionHashes,
		"scope": "Phase A same-process composer and immutable checkpoint only; no post-commit physical, interior, rendering, gameplay, NPC/navigation or headed acceptance."}
	return report


func _capture_structural_baseline(stage: String, source, state: Dictionary) -> bool:
	if stage != "structural_completion_prepare_started":
		return true
	state.observed = int(state.get("observed", 0)) + 1
	if state.observed != 1 or source == null or source.parts.is_empty():
		return false
	var seen: Dictionary = {}
	var ids: Array = []
	var objects: Array = []
	for part in source.parts:
		var id := String(part.id) if part != null else ""
		if id.is_empty() or seen.has(id):
			return false
		seen[id] = true
		ids.append(id)
		objects.append(part)
	state.ids = ids
	state.objects = objects
	state.ready = seen.size() == source.parts.size()
	return bool(state.ready)


func _finalize() -> void:
	if _worker != null and _worker.is_started():
		_worker.wait_to_finish()
