extends "res://scripts/testing/buildings/CitadelFacadeRecipeContract.gd"

## Synthetic dispatch rejection injection + real Frame proof on acceptance.
## This proves planner retry/fatal behavior, never live gameplay acceptance.
var candidate_calls := 0
var mode := ""
var checks: Array = []
var callback_rows: Array = []

func _run() -> void:
	var path := OS.get_environment("VOXEL_CUT_CANDIDATE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	for selected_mode in ["retry", "fatal", "cap"]:
		mode = selected_mode
		candidate_calls = 0
		callback_rows = []
		var b = _producer_support_stack(false)
		# Widen only this synthetic panel so the native planner derives more
		# than one legal normal centre; no accepted result is manufactured.
		b.find_part("panel").size.x = 0.48
		var support = b.parts.filter(func(part): return part.semantic == "castle_courtyard_paving")[0]
		var top: float = Recipe.Frame._bounds(support).end.y
		b.add_part({"id": "synthetic_finish", "kind": "foundation", "material": "cobblestone", "collision": false,
			"position": Vector3(0, top + 0.05, 0), "size": Vector3(2, 0.1, 4), "recipe": {"pavingFamily": "civic_setts"}})
		# A retained central detail supplies extra configuration-space edges
		# without occupying either end post, knee or the upper sill.
		b.add_part({"id": "synthetic_normal_partition", "kind": "detail", "material": "timber_beam", "collision": false,
			"position": Vector3(-b.find_part("panel").size.x * 0.25, top + 0.5, 0), "size": Vector3(0.02, 0.02, 0.02)})
		var before := var_to_bytes(b.snapshot())
		var callback := _validate_candidate.bind(b)
		var result: Dictionary = Recipe._supported_broad_region(b, [b.find_part("panel")], Vector3.RIGHT, [], true, callback)
		var expected: bool = result.ready and candidate_calls >= 2 if mode == "retry" else not result.ready and candidate_calls == 1 and result.get("reason") == ("extension_total_foot_limit" if mode == "cap" else "stale_prior_declaration")
		var row := {"mode": mode, "passed": expected and before == var_to_bytes(b.snapshot()), "calls": candidate_calls, "reason": result.get("reason", ""), "sourceUnchanged": before == var_to_bytes(b.snapshot()), "callbackRows": callback_rows.duplicate(true)}
		if result.ready:
			var prepared = result.preparedTrial
			var frame: Dictionary = result.preparedFrame
			var replay: Dictionary = Recipe._replay_batch_paving(prepared, frame.pavingFinishPartIds)
			row["realFrameAndPavingPassed"] = frame.ready and frame.stagedPhysical.passed and replay.ready
			row.passed = row.passed and row.realFrameAndPavingPassed
		checks.append(row)
	var passed := checks.size() == 3 and checks.all(func(row): return row.passed)
	var report := {"passed": passed, "checks": checks, "elapsedMsec": Time.get_ticks_msec() - started,
		"evidenceLevel": "synthetic_dispatch_fault_injection_and_actual_Frame_service",
		"doesNotProve": "No generated seed placement, runtime publication, visual or gameplay acceptance.",
		"recipeSha256": FileAccess.get_sha256("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)

func _validate_candidate(section: Dictionary, b) -> Dictionary:
	candidate_calls += 1
	if mode != "retry" or candidate_calls == 1:
		var rejection := {"ready": false, "fatal": mode != "retry", "reason": "existing_source_geometry_blocked" if mode == "retry" else ("extension_total_foot_limit" if mode == "cap" else "stale_prior_declaration")}
		callback_rows.append(rejection.duplicate(true))
		return rejection
	var result: Dictionary = Recipe._prepare_cut_bay_candidate(section, b, ["panel"], Vector3.RIGHT, {"reservedVolumes": []}, [])
	callback_rows.append({"ready": result.ready, "reason": result.get("reason", ""), "realFrameCalled": true})
	return result
