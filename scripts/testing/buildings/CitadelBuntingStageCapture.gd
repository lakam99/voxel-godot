extends "res://scripts/testing/buildings/CitadelOpeningHeadPolicyReplay.gd"
const SOURCE := "res://scripts/buildings/CitadelStructuralCompletionRecipe.gd"
const STUB := "res://scripts/testing/buildings/CitadelBuntingStageCaptureStub.gd"
func _run() -> void:
	var output := OS.get_environment("CITADEL_ORDERED_OPENING_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	state.started = Time.get_ticks_msec(); state.begin_phase("capture_setup", 300000)
	var worker := Thread.new()
	if worker.start(_work) != OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	report.checks.final_deadline = state.checkpoint("capture_worker_returned")
	state.finish(); report["progress"] = state.snapshot(true)
	report.passed = report.passed and report.checks.final_deadline
	var encoded := JSON.stringify(report, "  ", true, true)
	if not state.checkpoint("capture_report_encoded"):
		report.passed = false; report.checks.final_deadline = false
		encoded = JSON.stringify(report, "  ", true, true)
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(encoded); file.flush()
	var saved := file.get_error() == OK; file.close(); quit(0 if saved and report.passed else 1)
func _work() -> Dictionary:
	state.begin_phase("structural_to_bunting_capture", 300000)
	var mirror := OS.get_environment("CITADEL_BUNTING_CAPTURE_MIRROR")
	var original := FileAccess.get_file_as_string(SOURCE).replace("\r\n", "\n")
	var dependency := 'preload("res://scripts/buildings/CitadelBuntingAnchorRecipe.gd")'
	var expected := original.replace(dependency, 'preload("' + STUB + '")')
	var checks := {"pinned": FileAccess.get_sha256(_input_path()) == _input_sha(),
		"exact_interception": mirror.begins_with("res://artifacts/citadel-runtime-integration/") and original.count(dependency) == 1 and expected == FileAccess.get_file_as_string(mirror).replace("\r\n", "\n")}
	var report := {"passed": false, "checks": checks, "scope": "Pinned pre-structural source through real structural stages to exact whole bunting proposal input. Deliberate dependency interception/cancellation; no complete recipe, publication or gameplay acceptance."}
	if not checks.values().all(func(value): return value == true): return report
	var file := FileAccess.open(_input_path(), FileAccess.READ)
	if file == null: return report
	var input: Dictionary = file.get_var(false); file.close()
	var source = Heads.Copy.copy_blueprint(input.blueprint)
	var frozen := var_to_bytes(source.snapshot()); var policy_bytes := var_to_bytes(input.policy)
	var structural = load(mirror)
	var result: Dictionary = structural.prepare(source, input.policy, state.checkpoint)
	checks.deliberately_cancelled = not result.get("ready", true) and result.get("reason") == "cancelled"
	var capture := OS.get_environment("CITADEL_ORDERED_OPENING_REPORT").get_base_dir().path_join("input.bin")
	checks.capture_exists = FileAccess.file_exists(capture)
	if checks.capture_exists:
		file = FileAccess.open(capture, FileAccess.READ)
		if file == null: return report
		var value: Dictionary = file.get_var(false); file.close()
		checks.whole_selection = value.assemblies.size() > 0 and value.assemblies.any(func(a): return a.ropeId == "urban_bunting_rope_02")
		report["assemblies"] = value.assemblies
		report["partCount"] = value.blueprint.parts.size()
		report["protectedCount"] = value.protected.size()
		report["captureSha256"] = FileAccess.get_sha256(capture)
	checks.source_immutable = frozen == var_to_bytes(source.snapshot()) and policy_bytes == var_to_bytes(input.policy) and FileAccess.get_sha256(_input_path()) == _input_sha()
	checks.mirror_unchanged = expected == FileAccess.get_file_as_string(mirror).replace("\r\n", "\n")
	checks.deadline = state.checkpoint("bunting_capture_completed")
	report.passed = checks.values().all(func(value): return value == true)
	return report
