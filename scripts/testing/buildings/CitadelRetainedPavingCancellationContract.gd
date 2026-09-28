extends SceneTree

## Historical actual adapter/helper source contract, NOT a full Source or live run.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Shops = preload("res://scripts/buildings/CitadelShopRecipe.gd")
var output := ""
var checks: Dictionary = {}
var callback_rows: Array = []
var callback_count := 0
var callback_started := 0
var previous_usec := 0
var false_usec := 0
var after_false := 0
var stage_hits := 0
var target_stage := ""
var arm_stage := ""
var armed := false
var occurrence := 1
var proof_phase := "none"
var max_gap_usec := 0
var trace_overflow := false
var report := {"schema": "retained-paving-cancellation/v1", "complete": false, "passed": false,
	"evidenceLevel": "historical_actual_adapter_source_contract", "doesNotProve": "No fresh full Source, live, headed, NPC, navigation, visual or runtime performance acceptance."}

func _initialize() -> void: call_deferred("_run")

func _check(name: String, condition: bool) -> bool:
	checks[name] = condition
	if not condition: print("CONTRACT FAILURE ", name)
	return condition

func _read(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() > 134217728: return null
	var value: Variant = f.get_var(false)
	if f.get_error() != OK or f.get_position() != f.get_length(): return null
	return value

func _binary(path: String, value: Variant) -> bool:
	if FileAccess.file_exists(path): return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null: return false
	f.store_var(value, false); f.flush()
	return f.get_error() == OK

func _bound(bindings: Dictionary) -> bool:
	for path: String in bindings:
		if FileAccess.get_sha256(path) != bindings[path]: return false
	return true

func _run() -> void:
	output = OS.get_environment("RETAINED_CANCEL_OUTPUT")
	report.phase = OS.get_environment("RETAINED_CANCEL_PHASE")
	var launch: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("launch.json")))
	if not _check("dependencies_before", _bound(launch.dependencies)) or not _check("archives_before", _bound(launch.archives)):
		_finish(); return
	if report.phase == "baseline":
		_baseline(launch)
	else:
		_current(launch)
	_check("dependencies_after", _bound(launch.dependencies))
	_check("archives_after", _bound(launch.archives))
	_finish()

func _baseline(launch: Dictionary) -> void:
	var prefix := "res://artifacts/citadel-runtime-integration/"
	for relative: String in launch.historical:
		if not _check("historical_hash_" + relative, FileAccess.get_sha256(prefix + relative) == launch.historical[relative]): return
	var shop: Variant = _read(prefix + "actual-site-shop-02/result.bin")
	var before_snapshot: Variant = _read(prefix + "paving-source-diagnosis-01/pre-urban.bin")
	if not _check("historical_typed_shapes", shop is Dictionary and shop.get("blueprint") is Dictionary and before_snapshot is Dictionary): return
	var b = Copy.copy_blueprint(shop.blueprint)
	var before = Copy.copy_blueprint(before_snapshot)
	var ids := {}
	var retired: Array = []
	for part in b.parts: ids[part.id] = true
	for part in before.parts:
		if not ids.has(part.id) and before.is_grounded_structural_root(part): retired.append(part.snapshot())
	var old = load(output.path_join("FrozenCitadelUrbanPocComposer.gd"))
	var capture = load(output.path_join("CaptureOldRetainedInput.gd"))
	print("RETAINED reconstruct historical furnishing reservations")
	var furnishing_result: Dictionary = old.prepare_furnishings(b, 1298433643)
	if not _check("furnishings_ready", furnishing_result.get("furnishingPlan") != null): return
	var furnishings = furnishing_result.furnishingPlan
	var obstacles: Dictionary = Shops.furnishing_obstacles(furnishings.snapshot(), furnishings.protected_access_reservations)
	if not _check("obstacles_ready", obstacles.get("obstacles") is Array): return
	var helper_input: Dictionary = capture.prepare_retained_paving(b, retired, obstacles.obstacles)
	if not _check("captured_old_helper_arguments", helper_input.get("targets") is Array and helper_input.get("voids") is Array): return
	var input := {"blueprint": b.snapshot(), "retired": retired, "furnishingObstacles": obstacles.obstacles,
		"targets": helper_input.targets, "voids": helper_input.voids,
		"furnishingSnapshot": furnishings.snapshot(), "protectedAccessReservations": furnishings.protected_access_reservations}
	var original := var_to_bytes(input)
	print("RETAINED old bound adapter/helper started")
	var started := Time.get_ticks_usec()
	var result: Dictionary = old.prepare_retained_paving(b, retired, obstacles.obstacles)
	report.elapsedUsec = Time.get_ticks_usec() - started
	if not _check("old_adapter_helper_success", result.get("ready") == true and result.get("afterSnapshot") is Dictionary): return
	_check("blueprint_input_unchanged", var_to_bytes(b.snapshot()) == var_to_bytes(input.blueprint))
	_check("all_input_values_unchanged", var_to_bytes(input) == original)
	_check("historical_three_targets", result.get("selectedIds", []).size() == 3)
	_check("dependencies_before_freeze", _bound(launch.dependencies))
	if false not in checks.values():
		var evidence := {"schema": "retained-paving-baseline/v1", "engine": Engine.get_version_info(),
			"revision": launch.revision, "historical": launch.historical, "dependencies": launch.dependencies,
			"gitHashes": launch.gitHashes, "input": input, "result": result,
			"outputPolicy": "Original full frozen composer directly returns full frozen helper result; no duplicate old physical proof needed."}
		_check("baseline_saved_once", _binary(output.path_join("baseline.bin"), evidence))
		report.baselineSha256 = FileAccess.get_sha256(output.path_join("baseline.bin"))
		report.inputSha256 = original.hex_encode().sha256_text()
		report.partCount = b.parts.size()
		report.retiredCount = retired.size()
		report.targetCount = helper_input.targets.size()
		report.voidCount = helper_input.voids.size()

func _callback(stage: String) -> bool:
	var now := Time.get_ticks_usec()
	var gap := now - previous_usec
	max_gap_usec = maxi(max_gap_usec, gap)
	if false_usec != 0: after_false += 1
	if stage == "retained_initial_proof": proof_phase = "initial"
	elif stage == "retained_final_proof": proof_phase = "final"
	if stage == arm_stage: armed = true
	if armed and stage == target_stage: stage_hits += 1
	var permitted := not (armed and stage == target_stage and stage_hits >= occurrence)
	if not permitted and false_usec == 0: false_usec = now
	callback_count += 1
	var previous: Dictionary = callback_rows.back() if not callback_rows.is_empty() else {}
	if not previous.is_empty() and previous.stage == stage and previous.proofPhase == proof_phase and previous.continued == permitted:
		previous.count += 1
		previous.lastTimestampUsec = now
		previous.maxGapUsec = maxi(previous.maxGapUsec, gap)
		previous.totalGapUsec += gap
	else:
		if callback_rows.size() >= 100000:
			trace_overflow = true
			return false
		callback_rows.append({"stage": stage, "proofPhase": proof_phase, "count": 1, "firstIndex": callback_count - 1,
			"firstTimestampUsec": now, "lastTimestampUsec": now, "firstElapsedUsec": now - callback_started,
			"firstGapUsec": gap, "maxGapUsec": gap, "totalGapUsec": gap, "continued": permitted})
	previous_usec = now
	return permitted

func _invoke(api, target: String, mode: String, b, input: Dictionary) -> Dictionary:
	if target == "adapter":
		if mode == "omitted": return api.prepare_retained_paving(b, input.retired, input.furnishingObstacles)
		if mode == "empty": return api.prepare_retained_paving(b, input.retired, input.furnishingObstacles, Callable())
		return api.prepare_retained_paving(b, input.retired, input.furnishingObstacles, _callback)
	if mode == "omitted": return api.prepare(b, input.retired, input.targets, input.voids)
	if mode == "empty": return api.prepare(b, input.retired, input.targets, input.voids, Callable())
	return api.prepare(b, input.retired, input.targets, input.voids, _callback)

func _current(launch: Dictionary) -> void:
	var baseline_path := OS.get_environment("RETAINED_CANCEL_BASELINE").path_join("baseline.bin")
	if not _check("baseline_hash", FileAccess.get_sha256(baseline_path) == launch.baselineSha256): return
	var baseline: Variant = _read(baseline_path)
	if not _check("baseline_identity", baseline is Dictionary and baseline.schema == "retained-paving-baseline/v1"
		and baseline.engine == Engine.get_version_info() and baseline.revision == launch.revision
		and baseline.gitHashes == launch.gitHashes and baseline.dependencies == launch.dependencies
		and baseline.historical == launch.historical): return
	if not _check("current_sources_before", _bound(launch.currentSources)): return
	var input: Dictionary = baseline.input.duplicate(true)
	var input_bytes := var_to_bytes(input)
	var b = Copy.copy_blueprint(input.blueprint)
	var blueprint_bytes := var_to_bytes(b.snapshot())
	var part_objects: Array = b.parts.duplicate()
	var target := OS.get_environment("RETAINED_CANCEL_TARGET")
	var mode := OS.get_environment("RETAINED_CANCEL_MODE")
	var api = load("res://scripts/buildings/CitadelUrbanPocComposer.gd" if target == "adapter" else "res://scripts/buildings/RetainedSurfaceBearingRecipe.gd")
	report.target = target
	report.mode = mode
	seed(0x42cb123)
	var expected_random := randi()
	seed(0x42cb123)
	callback_started = Time.get_ticks_usec()
	previous_usec = callback_started
	var result: Dictionary
	if report.phase == "success":
		result = _invoke(api, target, mode, b, input)
		var returned := Time.get_ticks_usec()
		_check("successful_result", result.get("ready") == true and result.get("afterSnapshot") is Dictionary)
		_check("complete_typed_result_exact", var_to_bytes(result) == var_to_bytes(baseline.result))
		_check("complete_result_saved", _binary(output.path_join("result.bin"), result))
		report.resultSha256 = FileAccess.get_sha256(output.path_join("result.bin"))
		if mode == "true":
			_check("observed_both_physical_proofs", callback_rows.any(func(row): return row.proofPhase == "initial" and row.stage == "physical_resolve_support")
				and callback_rows.any(func(row): return row.proofPhase == "final" and row.stage == "physical_resolve_support"))
			_check("terminal_finalize_observed", not callback_rows.is_empty() and callback_rows.back().stage == "retained_finalize")
		_timings(returned)
	elif report.phase == "cancellation":
		target_stage = OS.get_environment("RETAINED_CANCEL_STAGE")
		arm_stage = OS.get_environment("RETAINED_CANCEL_ARM_STAGE")
		armed = arm_stage.is_empty()
		occurrence = maxi(1, int(OS.get_environment("RETAINED_CANCEL_OCCURRENCE")))
		result = _invoke(api, target, "true", b, input)
		var returned := Time.get_ticks_usec()
		_check("cancel_exact_result", var_to_bytes(result) == var_to_bytes({"ready": false, "reason": "cancelled"}))
		_check("no_after_snapshot", not result.has("afterSnapshot"))
		_check("rejection_reached", false_usec != 0 and stage_hits == occurrence)
		_check("no_later_callbacks", after_false == 0 and not callback_rows.is_empty() and callback_rows.back().continued == false)
		report.cancelStage = target_stage
		report.armStage = arm_stage
		report.cancelOccurrence = occurrence
		report.result = result
		_timings(returned)
	elif report.phase == "synthetic":
		_synthetic()
	else:
		_check("known_phase", false)
	_check("global_rng_unchanged", randi() == expected_random)
	_check("all_input_values_unchanged", input_bytes == var_to_bytes(input))
	_check("blueprint_input_unchanged", blueprint_bytes == var_to_bytes(b.snapshot()))
	_check("original_part_objects_unchanged", part_objects == b.parts)
	_check("bounded_trace", not trace_overflow)
	_check("current_sources_after", _bound(launch.currentSources))
	_check("baseline_still_immutable", FileAccess.get_sha256(baseline_path) == launch.baselineSha256)

func _timings(returned: int) -> void:
	report.callbackCount = callback_count
	report.callbackGroups = callback_rows.duplicate(true)
	report.coalescingPolicy = "Consecutive identical stage/proofPhase/continued values retain count, first/last timestamps, first/max/summed gaps. The terminal false record is never merged with true records. Maximum 100000 groups, overflow fails the contract."
	report.maxInterCallbackGapUsec = max_gap_usec
	report.elapsedUsec = returned - callback_started
	report.falseToReturnUsec = returned - false_usec if false_usec != 0 else 0
	report.lastCallbackToReturnUsec = returned - previous_usec
	var counted := 0
	for row: Dictionary in callback_rows: counted += int(row.count)
	_check("coalesced_count_exact", counted == callback_count)

func _synthetic() -> void:
	var synthetic_started := Time.get_ticks_usec()
	var blueprint = load("res://scripts/buildings/BuildingBlueprint.gd")
	var old = load(output.path_join("FrozenRetainedSurfaceBearingRecipe.gd"))
	var current = load("res://scripts/buildings/RetainedSurfaceBearingRecipe.gd")
	var b = blueprint.new("retained-cancellation-synthetic", 123, "stone")
	b.add_part({"id": "surface", "kind": "foundation", "position": Vector3(0, 0.7, 0), "size": Vector3(2, 0.2, 2), "semantic": "castle_courtyard_paving"})
	var retired: Array = [{"id": "old", "kind": "foundation", "position": Vector3(0, 0.5, 0), "rotation": Vector3.ZERO, "size": Vector3(2, 1, 2), "collision": true, "recipe": {}}]
	var before := var_to_bytes(b.snapshot())
	var originals := var_to_bytes(retired)
	var expected: Dictionary = old.prepare(b, retired, ["surface"], [])
	_check("synthetic_old_real_support", expected.get("ready") == true and expected.get("emitted", []).size() == 1)
	for mode in ["omitted", "empty", "true"]:
		var actual := _invoke(current, "helper", mode, b, {"retired": retired, "targets": ["surface"], "voids": []})
		_check("synthetic_%s_exact" % mode, var_to_bytes(actual) == var_to_bytes(expected))
	var voids := [AABB(Vector3(-2, -1, -2), Vector3(4, 3, 4))]
	var old_fail: Dictionary = old.prepare(b, retired, ["surface"], voids)
	_check("ordinary_failure_not_cancel", old_fail.get("ready") == false and old_fail.get("reason") == "no_retired_bearing_volume" and not old_fail.has("afterSnapshot"))
	for mode in ["omitted", "empty", "true"]:
		var actual := _invoke(current, "helper", mode, b, {"retired": retired, "targets": ["surface"], "voids": voids})
		_check("ordinary_failure_%s_exact" % mode, var_to_bytes(actual) == var_to_bytes(old_fail))
	var old_adapter = load(output.path_join("FrozenCitadelUrbanPocComposer.gd"))
	var adapter = load("res://scripts/buildings/CitadelUrbanPocComposer.gd")
	var old_bad: Dictionary = old_adapter.prepare_retained_paving(b, retired, [{}])
	var bad: Dictionary = adapter.prepare_retained_paving(b, retired, [{}], _callback)
	_check("adapter_ordinary_failure_exact", var_to_bytes(old_bad) == var_to_bytes(bad) and bad.get("reason") == "invalid_retained_paving_furnishing" and not bad.has("afterSnapshot"))
	_check("synthetic_blueprint_unchanged", before == var_to_bytes(b.snapshot()))
	_check("synthetic_retired_unchanged", originals == var_to_bytes(retired))
	_timings(Time.get_ticks_usec())
	var supported = Copy.copy_blueprint(expected.afterSnapshot)
	var noop: Dictionary = old.prepare(supported, retired, ["surface"], [])
	_check("noop_old_success", noop.get("ready") == true and noop.get("unchanged") == true)
	for mode in ["omitted", "empty", "true"]:
		var actual := _invoke(current, "helper", mode, supported, {"retired": retired, "targets": ["surface"], "voids": []})
		_check("noop_%s_complete_exact" % mode, var_to_bytes(actual) == var_to_bytes(noop))
	_small_cancel(current, b, retired, "staged_addition", "physical_resolve_support", "retained_final_proof")
	_small_cancel(current, supported, retired, "noop_finalize", "retained_finalize", "")
	# Capture each adapter no-op path with the same ordinary source records.
	var old_noop_adapter: Dictionary = old_adapter.prepare_retained_paving(supported, retired, [])
	_check("noop_adapter_old_success", old_noop_adapter.get("ready") == true and old_noop_adapter.get("unchanged") == true)
	for mode in ["omitted", "empty"]:
		var actual := _invoke(adapter, "adapter", mode, supported, {"retired": retired, "furnishingObstacles": []})
		_check("noop_adapter_%s_exact" % mode, var_to_bytes(actual) == var_to_bytes(old_noop_adapter))
	var noop_adapter_true: Dictionary = adapter.prepare_retained_paving(supported, retired, [], func(_stage: String) -> bool: return true)
	_check("noop_adapter_true_exact", var_to_bytes(noop_adapter_true) == var_to_bytes(old_noop_adapter))
	_small_cancel(adapter, supported, retired, "adapter_noop_finalize", "retained_finalize", "", "adapter")
	report.elapsedUsec = Time.get_ticks_usec() - synthetic_started

func _small_cancel(api, b, retired: Array, label: String, stop_stage: String, arm: String, target: String = "helper") -> void:
	callback_rows = []
	callback_count = 0
	false_usec = 0
	after_false = 0
	stage_hits = 0
	max_gap_usec = 0
	proof_phase = "none"
	target_stage = stop_stage
	arm_stage = arm
	armed = arm.is_empty()
	occurrence = 1
	callback_started = Time.get_ticks_usec()
	previous_usec = callback_started
	var original := var_to_bytes(b.snapshot())
	var result := _invoke(api, target, "true", b, {"retired": retired, "targets": ["surface"], "voids": [], "furnishingObstacles": []})
	var returned := Time.get_ticks_usec()
	_check(label + "_exact_cancel", var_to_bytes(result) == var_to_bytes({"ready": false, "reason": "cancelled"}) and not result.has("afterSnapshot"))
	_check(label + "_reached_no_later_callbacks", false_usec != 0 and after_false == 0 and stage_hits == 1)
	_check(label + "_source_unchanged", original == var_to_bytes(b.snapshot()))
	var counted := 0
	for row: Dictionary in callback_rows: counted += int(row.count)
	_check(label + "_coalesced_count_exact", counted == callback_count)
	if label == "staged_addition":
		_check(label + "_fragment_then_final_proof", callback_rows.any(func(row): return row.stage == "retained_fragment")
			and callback_rows.any(func(row): return row.stage == "retained_final_proof"))
	else:
		_check(label + "_noop_branch", not callback_rows.any(func(row): return row.stage == "retained_final_proof"))
	if not report.has("syntheticCancellationTraces"): report.syntheticCancellationTraces = {}
	report.syntheticCancellationTraces[label] = {"callbackCount": callback_count, "callbackGroups": callback_rows.duplicate(true),
		"falseToReturnUsec": returned - false_usec, "maxInterCallbackGapUsec": max_gap_usec}

func _finish() -> void:
	report.checks = checks
	report.complete = true
	report.passed = not checks.is_empty() and false not in checks.values()
	var f := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "\t")); f.close()
	var summary := {"phase": report.phase, "passed": report.passed, "complete": true, "checks": checks.size(), "elapsedUsec": report.get("elapsedUsec", 0),
		"callbackCount": report.get("callbackCount", 0), "callbackGroupCount": (report.get("callbackGroups", []) as Array).size(),
		"maxInterCallbackGapUsec": report.get("maxInterCallbackGapUsec", 0), "falseToReturnUsec": report.get("falseToReturnUsec", 0)}
	var sf := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	sf.store_string(JSON.stringify(summary, "\t")); sf.close()
	print("RETAINED RESULT ", JSON.stringify(summary))
	quit(0 if report.passed else 1)
