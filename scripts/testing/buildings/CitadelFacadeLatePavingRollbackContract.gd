extends "res://scripts/testing/buildings/CitadelFacadeRecipeContract.gd"

## Frozen actual-source failure after a successful private paving/frame commit.
## No regeneration, rendering, gameplay or navigation acceptance.
func _run() -> void:
	var output := OS.get_environment("VOXEL_LATE_PAVING_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var report := _late_rollback()
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report["evidenceLevel"] = "frozen_actual_source_late_private_batch_rollback"
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if report.get("passed", false) and written else 2)

func _bound_input(env: String, limit: int) -> Dictionary:
	var path := OS.get_environment(env)
	var sha := OS.get_environment(env + "_SHA256")
	if not path.is_absolute_path() or sha.length() != 64 or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != sha: return {"ready": false, "reason": "input_binding"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ready": false, "reason": "input_open"}
	var count := file.get_length()
	if count <= 0 or count > limit:
		file.close()
		return {"ready": false, "reason": "input_size"}
	var bytes := file.get_buffer(count)
	var complete := file.get_error() == OK and bytes.size() == count
	file.close()
	return {"ready": complete and FileAccess.get_sha256(path) == sha, "bytes": bytes, "path": path, "sha": sha}

func _late_rollback() -> Dictionary:
	var binary := _bound_input("VOXEL_LATE_PAVING_SOURCE", 33554432)
	var main := _bound_input("VOXEL_LATE_PAVING_MAIN", 67108864)
	if not binary.ready or not main.ready: return {"passed": false, "reason": "invalid_bound_inputs"}
	var decoded: Variant = bytes_to_var(binary.bytes)
	var json: Variant = JSON.parse_string(main.bytes.get_string_from_utf8())
	if not decoded is Dictionary or not json is Dictionary: return {"passed": false, "reason": "invalid_encoding"}
	var archive: Dictionary = decoded
	var evidence: Dictionary = json
	if not evidence.get("passed", false) or evidence.get("candidateArtifact", {}).get("sha256") != binary.sha or not archive.get("mainShardPassed", false) or archive.get("contractIdentity") != _contract_identity(): return {"passed": false, "reason": "main_pairing"}
	if _digest(archive.beforeSnapshot) != archive.sourceDigest or _digest(archive.afterSnapshot) != archive.outputDigest: return {"passed": false, "reason": "source_digest"}
	var retained_foot_ids: Array = []
	for part in archive.afterSnapshot.parts:
		if part.recipe.has("pavingFootingJoints"): retained_foot_ids.append_array(part.recipe.pavingFootingJoints.footPartIds)
	var limit := 0
	for index in range(evidence.wholeCitadel.batch.calls.size()):
		var call: Dictionary = evidence.wholeCitadel.batch.calls[index]
		if call.ready and call.partIds.any(func(id): return retained_foot_ids.has(id)):
			limit = index + 1
			break
	if limit <= 0 or limit >= Recipe.MAX_BATCH_CALLS: return {"passed": false, "reason": "no_prior_paving_commit_in_main"}
	var b = Recipe.copy_blueprint(archive.beforeSnapshot)
	var aliases: Array = b.parts.duplicate()
	var before := var_to_bytes(b.snapshot())
	var policy := {"furnitureParts": archive.furnitureSnapshot.parts, "reservedVolumes": archive.protectedReservations, "maxBatchCalls": limit}
	var policy_before := var_to_bytes(policy)
	var result: Dictionary = Recipe.compose_bottom_bays(b, policy)
	var successful: Array = result.get("calls", []).filter(func(call): return call.ready and call.partIds.any(func(id): return retained_foot_ids.has(id)))
	var checks := {"late_budget_rejection": not result.ready and result.get("reason") == "batch_work_limit_exceeded",
		"real_paving_frame_previously_succeeded": not successful.is_empty() and result.get("lastProgress", {}).get("localSuccessfulCalls", 0) >= 1,
		"all_caller_records_and_joints_unchanged": before == var_to_bytes(b.snapshot()),
		"caller_aliases_and_order": b.parts.size() == aliases.size() and range(aliases.size()).all(func(index): return b.parts[index] == aliases[index]),
		"furniture_policy_exact": policy_before == var_to_bytes(policy),
		"bound_inputs_unchanged": FileAccess.get_sha256(binary.path) == binary.sha and FileAccess.get_sha256(main.path) == main.sha}
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks, "derivedMaxBatchCalls": limit,
		"sourceSha256": binary.sha, "mainReportSha256": main.sha, "successfulPrivateCalls": successful,
		"lastProgress": result.get("lastProgress", {}), "doesNotProve": "Not visual, live generator, publication, gameplay, runtime-performance or zero-gate acceptance."}
