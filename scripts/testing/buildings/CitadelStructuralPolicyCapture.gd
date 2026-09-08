extends SceneTree
## Byte-checked single dependency interception of production composition.
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const SOURCE := "res://scripts/buildings/CitadelUrbanPocComposer.gd"
const STUB := "res://scripts/testing/buildings/CitadelStructuralPolicyCaptureStub.gd"
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-21/input.bin"
const INPUT_SHA := "bbf8e2e3ece371e6fb0f7447563bfe89438d3dc47ba44206b3c632354f6c565e"
var state = Diagnostic.Progress.new()
var output := ""
var mirror := ""
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output = OS.get_environment("CITADEL_POLICY_CAPTURE_REPORT")
	mirror = OS.get_environment("CITADEL_POLICY_CAPTURE_MIRROR")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not mirror.begins_with("res://artifacts/citadel-runtime-integration/"): quit(2); return
	state.started = Time.get_ticks_msec(); state.begin_phase("capture", 90000)
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
	var original := FileAccess.get_file_as_string(SOURCE).replace("\r\n", "\n")
	var expected := original.replace("class_name CitadelUrbanPocComposer\n", "").replace('preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")', 'preload("' + STUB + '")')
	var hashes := {SOURCE: FileAccess.get_sha256(SOURCE), STUB: FileAccess.get_sha256(STUB), mirror: FileAccess.get_sha256(mirror)}
	var checks := {"pinned": FileAccess.get_sha256(INPUT) == INPUT_SHA, "exact_interception": expected == FileAccess.get_file_as_string(mirror).replace("\r\n", "\n")}
	var report := {"passed": false, "checks": checks, "sourceHashes": hashes, "scope": "Exact pre-structural producer source and actual immutable furnishing/protected-obstacle policy. Deliberately cancelled; not recipe or gameplay acceptance."}
	if not checks.values().all(func(value): return value == true): return report
	var file := FileAccess.open(INPUT, FileAccess.READ)
	if file == null: return report
	var input: Dictionary = file.get_var(false); file.close()
	var built: Dictionary = Diagnostic.Builder.build_with_diagnostics(input.candidate.recipeSeed, input.context, state.checkpoint)
	if built.get("blueprint") == null: return report
	var composer = load(mirror)
	var result: Dictionary = composer.compose_prepared(built.blueprint, input.candidate.recipeSeed, state.checkpoint)
	checks.deliberately_cancelled = not result.get("ready", true) and result.get("reason") == "cancelled"
	var capture := output.get_base_dir().path_join("input.bin")
	checks.capture_exists = FileAccess.file_exists(capture)
	if not checks.capture_exists: return report
	file = FileAccess.open(capture, FileAccess.READ)
	if file == null: return report
	var value: Dictionary = file.get_var(false); file.close()
	checks.policy_complete = value.get("policy", {}).get("furnitureParts") is Array and value.policy.get("reservedVolumes") is Array and value.policy.get("protectedObstacles") is Array
	checks.source_matches_caller = var_to_bytes(value.blueprint) == var_to_bytes(built.blueprint.snapshot())
	checks.sources_unchanged = hashes.keys().all(func(path): return hashes[path] == FileAccess.get_sha256(path)) and FileAccess.get_sha256(INPUT) == INPUT_SHA
	checks.deadline = state.checkpoint("policy_capture_completed")
	report["captureSha256"] = FileAccess.get_sha256(capture)
	report["counts"] = {"parts": value.blueprint.parts.size(), "furniture": value.policy.furnitureParts.size(), "reservations": value.policy.reservedVolumes.size()}
	report["lookupMismatchExamples"] = value.lookupMismatchExamples
	report["validationCacheActive"] = value.validationCacheActive
	report.passed = checks.values().all(func(value): return value == true)
	return report
