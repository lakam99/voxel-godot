extends SceneTree
## Single saved lower-phase input, instrumented diagnostic mirror only.
const Capture = preload("res://scripts/testing/buildings/CitadelFacadePhaseReplayCapture.gd")
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Timing = preload("res://scripts/testing/buildings/CitadelLowerPhaseTimingMeter.gd")
var state = Diagnostic.Progress.new()
var output: String = ""
var baseline: String = ""
var bindings: Dictionary = {}
var lower_script: Script
var main_thread_id: int = 0

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output = OS.get_environment("CITADEL_FACADE_PHASE_REPORT")
	baseline = OS.get_environment("CITADEL_LOWER_TIMING_BASELINE")
	var mirror: String = OS.get_environment("CITADEL_LOWER_TIMING_MIRROR")
	var mirror_sha: String = OS.get_environment("CITADEL_LOWER_TIMING_MIRROR_SHA256")
	var raw: Variant = JSON.parse_string(OS.get_environment("CITADEL_LOWER_TIMING_BINDINGS"))
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not baseline.begins_with("res://artifacts/citadel-runtime-integration/") \
			or baseline != baseline.simplify_path() or not raw is Dictionary \
			or not mirror.begins_with("res://artifacts/citadel-runtime-integration/") or mirror != mirror.simplify_path() \
			or mirror.get_file() != "Lower.gd" or FileAccess.get_sha256(mirror) != mirror_sha: quit(2); return
	bindings = raw
	lower_script = load(mirror)
	if lower_script == null or lower_script.get_script_constant_map().get("TIMING_MIRROR_SCHEMA") != "citadel-lower-timing-mirror/v1": quit(2); return
	state.started = Time.get_ticks_msec(); state.begin_phase("lower_timing_setup",60000)
	main_thread_id = OS.get_thread_caller_id()
	var worker: Thread = Thread.new()
	if worker.start(_work) != OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	state.finish(); report["progress"] = state.snapshot(true)
	report["mirrorPath"] = mirror; report["mirrorSha256"] = mirror_sha
	var file: FileAccess = FileAccess.open(output,FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report,"  ",true,true)); file.flush()
	var saved: bool = file.get_error()==OK
	file.close(); quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var checks: Dictionary = {}
	var report: Dictionary = {"schema":"citadel-lower-phase-diagnostic/v1","passed":false,"complete":false,
		"checks":checks,"baselineDirectory":baseline,"artifactSha256":bindings,
		"scope":"One instrumented replay of the saved exact lower input and policy; full typed lower output and fresh independent physical report compared with the frozen baseline. No opening phase, full source build, cancellation replay, native rebuild, gameplay or performance acceptance."}
	var artifacts: Dictionary = {}
	for name: String in ["lower-input.bin","lower-expected.bin","lower-physical.bin"]:
		checks[name+"Pinned"] = bindings.get(name) is String and FileAccess.get_sha256(baseline.path_join(name))==bindings[name]
		if not checks[name+"Pinned"]: return report
		artifacts[name] = Capture.read_path(baseline.path_join(name))
		if artifacts[name].is_empty(): return report
	var frozen_artifacts: PackedByteArray = var_to_bytes(artifacts)
	var input: Dictionary = artifacts["lower-input.bin"]
	checks.inputSchema = input.get("blueprint") is Dictionary and input.get("policy") is Dictionary
	if not checks.inputSchema: return report
	var frozen_input: PackedByteArray = var_to_bytes(input)
	if not state.begin_phase("lower_instrumented"): return report
	Timing.reset()
	var started: int = Time.get_ticks_usec()
	var result: Dictionary = lower_script.prepare_all_bottom_rows(input.blueprint,input.policy,state.checkpoint)
	report["phaseCallElapsedUsec"] = Time.get_ticks_usec()-started
	var timing: Dictionary = Timing.finish()
	report["timing"] = timing
	checks.inputUnchanged = frozen_input==var_to_bytes(input)
	checks.outputSaved = Capture.write_value("lower-actual.bin",result)
	checks.outputExact = var_to_bytes(result)==var_to_bytes(artifacts["lower-expected.bin"])
	checks.timingBalanced = timing.valid and int(timing.instrumentedCallUsec)<=int(report.phaseCallElapsedUsec) \
		and int(timing.workerThreadId)!=main_thread_id
	checks.physicalCallInventory = int(timing.counters.get("physicalValidationCalls",0))==67 \
		and int(timing.rows.get("assembly_support_index",{}).get("calls",0))==64
	checks.originalBaseValidationPathRetained = int(timing.rows.get("physical_validation_base",{}).get("calls",0))==3 \
		and int(timing.rows.get("physical_validation_assembly",{}).get("calls",0))==64
	checks.completionInventory = result.get("ready",false) and result.get("accepted",[]).size()==64 \
		and result.get("rejected",[]).is_empty() and result.get("afterSnapshot",{}).get("parts",[]).size()==4562
	if not checks.outputExact:
		report["firstDifference"] = _first_difference(artifacts["lower-expected.bin"],result,"lower")
		return report
	if not checks.values().all(func(value): return value==true): return report
	# Use the original base class and independent cache-cleared validation.
	var snapshot: Dictionary = result.afterSnapshot
	var frozen_snapshot: PackedByteArray = var_to_bytes(snapshot)
	var proof = Copy.copy_blueprint(snapshot)
	checks.physicalInputExact = var_to_bytes(proof.snapshot())==frozen_snapshot
	if not checks.physicalInputExact: return report
	Copy.clear_caches(proof)
	if not state.begin_phase("lower_independent_physical"): return report
	started = Time.get_ticks_usec()
	var physical: Dictionary = proof.validate_physical_integrity_cancellable(state.checkpoint)
	report["independentPhysicalElapsedUsec"] = Time.get_ticks_usec()-started
	checks.physicalSaved = Capture.write_value("lower-physical-actual.bin",physical)
	checks.physicalExact = var_to_bytes(physical)==var_to_bytes(artifacts["lower-physical.bin"])
	checks.physicalCallerUnchanged = frozen_snapshot==var_to_bytes(snapshot)
	if not checks.physicalExact:
		report["firstDifference"] = _first_difference(artifacts["lower-physical.bin"],physical,"lowerPhysical")
		return report
	checks.allBaselineValuesUnchanged = frozen_artifacts==var_to_bytes(artifacts)
	checks.baselineFilesUnchanged = bindings.keys().all(func(name): return FileAccess.get_sha256(baseline.path_join(name))==bindings[name])
	checks.deadline = state.checkpoint("lower_timing_completed")
	report.complete = true; report.passed = checks.values().all(func(value): return value==true)
	return report

func _first_difference(expected: Variant, actual: Variant, value_path: String) -> String:
	if typeof(expected)!=typeof(actual): return value_path+": type"
	if expected is Dictionary:
		if var_to_bytes(expected.keys())!=var_to_bytes(actual.keys()): return value_path+": ordered keys"
		for key: Variant in expected:
			if var_to_bytes(expected[key])!=var_to_bytes(actual[key]):
				return _first_difference(expected[key],actual[key],value_path+"."+str(key))
	elif expected is Array:
		if expected.size()!=actual.size(): return value_path+": array size"
		for index in range(expected.size()):
			if var_to_bytes(expected[index])!=var_to_bytes(actual[index]):
				return _first_difference(expected[index],actual[index],value_path+"["+str(index)+"]")
	return value_path+": represented value or container type"
