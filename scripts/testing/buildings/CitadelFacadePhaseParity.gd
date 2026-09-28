extends SceneTree
## One exact typed phase differential against frozen unchanged-baseline output.
## This proves source/service parity and rollback, never live gameplay.
const Capture = preload("res://scripts/testing/buildings/CitadelFacadePhaseReplayCapture.gd")
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Opening = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const Lower = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const Facade = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")
var state = Diagnostic.Progress.new()
var output := ""
var baseline := ""
var bindings: Dictionary = {}

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output = OS.get_environment("CITADEL_FACADE_PHASE_REPORT")
	baseline = OS.get_environment("CITADEL_FACADE_PARITY_BASELINE")
	var raw: Variant = JSON.parse_string(OS.get_environment("CITADEL_FACADE_PARITY_BINDINGS"))
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not baseline.begins_with("res://artifacts/citadel-runtime-integration/") \
			or baseline != baseline.simplify_path() or not raw is Dictionary: quit(2); return
	bindings = raw
	state.started = Time.get_ticks_msec(); state.begin_phase("phase_parity", 90000)
	var worker := Thread.new()
	if worker.start(_work) != OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	state.finish(); report["progress"] = state.snapshot(true)
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK; file.close(); quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var checks := {}
	var report := {"passed": false, "complete": false, "checks": checks, "baselineDirectory": baseline,
		"artifactSha256": bindings, "phaseCallElapsedUsec": {}, "scope": "Exact typed source/service phase differential, fresh full physical reports and cancellation rollback. No full-source, headed, gameplay or throughput acceptance."}
	var artifacts := {}
	for name: String in ["opening-input.bin", "opening-expected.bin", "lower-input.bin", "lower-expected.bin", "facade-expected.bin", "opening-physical.bin", "lower-physical.bin"]:
		checks[name + "Pinned"] = bindings.get(name) is String and FileAccess.get_sha256(baseline.path_join(name)) == bindings[name]
		if not checks[name + "Pinned"]: return report
		artifacts[name] = Capture.read_path(baseline.path_join(name))
		if artifacts[name].is_empty(): return report
	var frozen_artifacts := var_to_bytes(artifacts)
	var results := {}
	for phase: String in ["opening", "lower"]:
		var input: Dictionary = artifacts[phase + "-input.bin"]
		var frozen_input := var_to_bytes(input)
		var caller = Copy.copy_blueprint(input.blueprint) if phase == "opening" else null
		var original_parts: Array = caller.parts.duplicate() if phase == "opening" else []
		if phase == "opening":
			checks.openingCallerExact = var_to_bytes(caller.snapshot()) == var_to_bytes(input.blueprint)
		else:
			checks.lowerConsumesExactOpening = var_to_bytes(input.blueprint) == var_to_bytes(results.opening.candidateSnapshot)
		if not checks.values().all(func(value): return value == true): return report
		if not state.begin_phase(phase + "_candidate"): return report
		var started := Time.get_ticks_usec()
		var result: Dictionary = Opening.prepare_all_first_rows(caller, input.policy, state.checkpoint) if phase == "opening" \
			else Lower.prepare_all_bottom_rows(input.blueprint, input.policy, state.checkpoint)
		report.phaseCallElapsedUsec[phase] = Time.get_ticks_usec() - started
		checks[phase + "InputUnchanged"] = frozen_input == var_to_bytes(input)
		if phase == "opening": checks.openingCallerUnchanged = original_parts == caller.parts and var_to_bytes(caller.snapshot()) == var_to_bytes(input.blueprint)
		checks[phase + "ActualSaved"] = Capture.write_value(phase + "-actual.bin", result)
		checks[phase + "OutputExact"] = var_to_bytes(result) == var_to_bytes(artifacts[phase + "-expected.bin"])
		if not checks[phase + "OutputExact"]:
			report["firstDifference"] = _first_difference(artifacts[phase + "-expected.bin"], result, phase)
			return report
		results[phase] = result
		if not checks.values().all(func(value): return value == true): return report
	# The original orchestrator only removes snapshots and combines these fields.
	# Compare that exact public envelope without running both phases a second time.
	var facade := {"ready": true, "exhausted": true, "fullyResolved": results.lower.get("fullyResolved", false), "afterSnapshot": results.lower.afterSnapshot,
		"opening": Facade._without_snapshot(results.opening), "lower": Facade._without_snapshot(results.lower),
		"scope": "Private generated-facade recipe result; caller has not committed or published it."}
	checks.facadeEnvelopeExact = var_to_bytes(facade) == var_to_bytes(artifacts["facade-expected.bin"])
	if not checks.facadeEnvelopeExact: report["firstDifference"] = _first_difference(artifacts["facade-expected.bin"], facade, "facade"); return report
	for phase: String in ["opening", "lower"]:
		var snapshot: Dictionary = results.opening.candidateSnapshot if phase == "opening" else results.lower.afterSnapshot
		var frozen := var_to_bytes(snapshot)
		var proof = Copy.copy_blueprint(snapshot)
		checks[phase + "PhysicalInputExact"] = var_to_bytes(proof.snapshot()) == frozen
		if not checks[phase + "PhysicalInputExact"]: return report
		Copy.clear_caches(proof)
		if not state.begin_phase(phase + "_independent_physical"): return report
		var physical: Dictionary = proof.validate_physical_integrity_cancellable(state.checkpoint)
		checks[phase + "PhysicalSaved"] = Capture.write_value(phase + "-physical-actual.bin", physical)
		checks[phase + "PhysicalExact"] = var_to_bytes(physical) == var_to_bytes(artifacts[phase + "-physical.bin"])
		checks[phase + "PhysicalCallerUnchanged"] = frozen == var_to_bytes(snapshot)
		if not checks[phase + "PhysicalExact"]: report["firstDifference"] = _first_difference(artifacts[phase + "-physical.bin"], physical, phase + "Physical"); return report
		if not checks.values().all(func(value): return value == true): return report
	# These boundaries fire after substantive proposal proofs but before the
	# owning batch accepts the private house or four-record panel delta.
	for phase: String in ["opening", "lower"]:
		var input: Dictionary = artifacts[phase + "-input.bin"]
		var frozen := var_to_bytes(input)
		var caller = Copy.copy_blueprint(input.blueprint) if phase == "opening" else null
		var original_parts: Array = caller.parts.duplicate() if phase == "opening" else []
		var stop := "opening_head_house_completed:" if phase == "opening" else "lower_facade_panel_completed:"
		var continuation := func(label): return state.checkpoint(label) and not String(label).begins_with(stop)
		if not state.begin_phase(phase + "_precommit_cancellation"): return report
		var cancelled: Dictionary = Opening.prepare_all_first_rows(caller, input.policy, continuation) if phase == "opening" \
			else Lower.prepare_all_bottom_rows(input.blueprint, input.policy, continuation)
		checks[phase + "CancelledBeforeCommit"] = cancelled.get("ready") == false and cancelled.get("reason") == "cancelled" \
			and not cancelled.has("candidateSnapshot") and not cancelled.has("afterSnapshot") and frozen == var_to_bytes(input)
		if phase == "opening": checks.openingCancelledCallerUnchanged = original_parts == caller.parts and var_to_bytes(caller.snapshot()) == var_to_bytes(input.blueprint)
		if not checks.values().all(func(value): return value == true): return report
	checks.allBaselineValuesUnchanged = frozen_artifacts == var_to_bytes(artifacts)
	checks.baselineFilesUnchanged = bindings.keys().all(func(name): return FileAccess.get_sha256(baseline.path_join(name)) == bindings[name])
	checks.deadline = state.checkpoint("facade_parity_completed")
	report.complete = true
	report.passed = checks.values().all(func(value): return value == true)
	return report

func _first_difference(expected: Variant, actual: Variant, path: String) -> String:
	if typeof(expected) != typeof(actual): return path + ": type"
	if expected is Dictionary:
		if var_to_bytes(expected.keys()) != var_to_bytes(actual.keys()): return path + ": ordered keys"
		for key: Variant in expected:
			if var_to_bytes(expected[key]) != var_to_bytes(actual[key]): return _first_difference(expected[key], actual[key], path + "." + str(key))
	elif expected is Array:
		if expected.size() != actual.size(): return path + ": array size"
		for index in range(expected.size()):
			if var_to_bytes(expected[index]) != var_to_bytes(actual[index]): return _first_difference(expected[index], actual[index], path + "[" + str(index) + "]")
	return path + ": represented value or container type"
