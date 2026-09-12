extends SceneTree
## Byte-checked single dependency interception of production composition.
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const SOURCE := "res://scripts/buildings/CitadelUrbanPocComposer.gd"
const STUB := "res://scripts/testing/buildings/CitadelStructuralPolicyCaptureStub.gd"
const MAX_INPUT_BYTES := 4 * 1024 * 1024
const MAX_CAPTURE_BYTES := 64 * 1024 * 1024
var state = Diagnostic.Progress.new()
var output := ""
var mirror := ""
var input_path := ""
var input_sha := ""
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output = OS.get_environment("CITADEL_POLICY_CAPTURE_REPORT")
	mirror = OS.get_environment("CITADEL_POLICY_CAPTURE_MIRROR")
	input_path = OS.get_environment("CITADEL_POLICY_CAPTURE_INPUT")
	input_sha = OS.get_environment("CITADEL_POLICY_CAPTURE_INPUT_SHA256")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not mirror.begins_with("res://artifacts/citadel-runtime-integration/") \
			or mirror != mirror.simplify_path() or mirror.get_file() != "Composer.gd" \
			or not input_path.begins_with("res://") or input_path != input_path.simplify_path() \
			or not RegEx.create_from_string("^[a-f0-9]{64}$").search(input_sha): quit(2); return
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
	var ignored := mirror.get_base_dir().path_join(".gdignore")
	var hashes := {SOURCE: FileAccess.get_sha256(SOURCE), STUB: FileAccess.get_sha256(STUB), mirror: FileAccess.get_sha256(mirror),
		ignored: FileAccess.get_sha256(ignored), input_path: FileAccess.get_sha256(input_path)}
	var checks := {"pinned": hashes[input_path] == input_sha,
		"exact_interception": expected == FileAccess.get_file_as_string(mirror).replace("\r\n", "\n"),
		"mirror_excluded_from_import": FileAccess.file_exists(ignored) and FileAccess.get_file_as_string(ignored).is_empty()}
	var report := {"passed": false, "checks": checks, "sourceHashes": hashes, "inputPath": input_path, "inputSha256": input_sha,
		"scope": "Exact pre-structural producer source and actual immutable furnishing/protected-obstacle policy. Deliberately cancelled; not recipe or gameplay acceptance."}
	if not checks.values().all(func(value): return value == true): return report
	# Dynamic mirrors are not compiled by the fixture's --check-only pass.
	# Load this exact script before paying for any procedural preparation.
	var composer = load(mirror)
	checks.mirror_compiled = composer is Script and composer.can_instantiate()
	if not checks.mirror_compiled: return report
	var file := FileAccess.open(input_path, FileAccess.READ)
	if file == null: return report
	checks.input_bounded = file.get_length() > 0 and file.get_length() <= MAX_INPUT_BYTES
	if not checks.input_bounded: file.close(); return report
	var raw: Variant = file.get_var(false)
	checks.input_decoded = raw is Dictionary and file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not checks.input_decoded: return report
	var input: Dictionary = raw
	checks.input_schema = _valid_input(input)
	if not checks.input_schema: return report
	var frozen_input := var_to_bytes(input)
	report["candidate"] = input.candidate.duplicate(true)
	report["context"] = input.context.duplicate(true)
	var built: Dictionary = Diagnostic.Builder.build_with_diagnostics(input.candidate.recipeSeed, input.context.duplicate(true), state.checkpoint)
	if built.get("blueprint") == null: return report
	var result: Dictionary = composer.compose_prepared(built.blueprint, input.candidate.recipeSeed, state.checkpoint)
	checks.input_unchanged = frozen_input == var_to_bytes(input)
	checks.deliberately_cancelled = not result.get("ready", true) and result.get("reason") == "cancelled"
	var capture := output.get_base_dir().path_join("input.bin")
	checks.capture_exists = FileAccess.file_exists(capture)
	if not checks.capture_exists: return report
	file = FileAccess.open(capture, FileAccess.READ)
	if file == null: return report
	checks.capture_bounded = file.get_length() > 0 and file.get_length() <= MAX_CAPTURE_BYTES
	if not checks.capture_bounded: file.close(); return report
	var captured: Variant = file.get_var(false)
	checks.capture_decoded = captured is Dictionary and file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not checks.capture_decoded: return report
	var value: Dictionary = captured
	checks.policy_complete = value.get("policy") is Dictionary and value.policy.get("furnitureParts") is Array \
		and value.policy.get("reservedVolumes") is Array and value.policy.get("protectedObstacles") is Array
	if not checks.policy_complete or not value.get("blueprint") is Dictionary: return report
	checks.source_matches_caller = var_to_bytes(value.blueprint) == var_to_bytes(built.blueprint.snapshot())
	checks.sources_unchanged = hashes.keys().all(func(path): return hashes[path] == FileAccess.get_sha256(path)) and FileAccess.get_sha256(input_path) == input_sha
	checks.deadline = state.checkpoint("policy_capture_completed")
	report["captureSha256"] = FileAccess.get_sha256(capture)
	report["counts"] = {"parts": value.blueprint.parts.size(), "furniture": value.policy.furnitureParts.size(), "reservations": value.policy.reservedVolumes.size()}
	report["lookupMismatchExamples"] = value.lookupMismatchExamples
	report["validationCacheActive"] = value.validationCacheActive
	report.passed = checks.values().all(func(value): return value == true)
	return report

func _valid_input(input: Dictionary) -> bool:
	if not input.get("worldSeed") is String or input.worldSeed.is_empty() or not input.get("candidate") is Dictionary \
			or not input.get("context") is Dictionary: return false
	var candidate: Dictionary = input.candidate
	var context: Dictionary = input.context
	if not candidate.get("region") is Vector2i or not candidate.get("recipeSeed") is int \
			or candidate != Diagnostic.Field.candidate_for_region(input.worldSeed, candidate.region): return false
	var scale: Variant = context.get("citadelScale")
	return context.get("biome") is String and not context.biome.is_empty() and context.get("siteKey") == candidate.siteId \
		and (scale is float or scale is int) and is_finite(float(scale)) and float(scale) > 0.0 and float(scale) <= 6.0
