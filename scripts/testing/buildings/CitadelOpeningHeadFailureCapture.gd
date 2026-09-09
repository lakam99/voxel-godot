extends SceneTree
## Intentional pre-structural cancellation, then one-house geometry diagnosis.
## Empty furniture policy is synthetic and cannot establish recipe acceptance.
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const Heads = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-21/input.bin"
const INPUT_SHA := "bbf8e2e3ece371e6fb0f7447563bfe89438d3dc47ba44206b3c632354f6c565e"
const FAILURE := "res://artifacts/citadel-runtime-integration/candidate-recipe-21/failure.bin"
const FAILURE_SHA := "f494841a1155ba601c2498ee08608802c185871d5651ac3435a22126d7ccb300"
var state = Diagnostic.Progress.new()
var captured := false
var after_false := 0
var output := ""

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output = OS.get_environment("CITADEL_OPENING_FAILURE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	state.started = Time.get_ticks_msec(); state.begin_phase("capture", 90000)
	var worker := Thread.new()
	if worker.start(_work) != OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	state.finish(); report["progress"] = state.snapshot(true)
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK
	file.close(); quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var checks := {"pinned": FileAccess.get_sha256(INPUT) == INPUT_SHA and FileAccess.get_sha256(FAILURE) == FAILURE_SHA}
	var report := {"passed": false, "checks": checks, "scope": "Actual pre-structural source and direct failed-house geometry replay with synthetic empty furnishing policy. No full recipe or gameplay acceptance."}
	if not checks.pinned: return report
	var input := _read(INPUT)
	var failed: Dictionary = _read(FAILURE).structuralCompletionFailure.detail.detail
	var built: Dictionary = Diagnostic.Builder.build_with_diagnostics(input.candidate.recipeSeed, input.context, _gate)
	if built.get("blueprint") == null: return report
	var source = built.blueprint
	var result: Dictionary = Diagnostic.Urban.compose_prepared(source, input.candidate.recipeSeed, _gate)
	checks.exact_boundary = captured and after_false == 0 and not result.get("ready", true)
	if not checks.exact_boundary: return report
	var snapshot: Dictionary = source.snapshot()
	var before := var_to_bytes(snapshot)
	var file := FileAccess.open(output.get_base_dir().path_join("input.bin"), FileAccess.WRITE)
	if file == null: return report
	file.store_var({"blueprint": snapshot, "failedHouse": failed.failedHouse}, false); file.flush()
	checks.capture_written = file.get_error() == OK; file.close()
	if not state.begin_phase("single_house_geometry", 20000): return report
	var membership := Heads.Copy.street_house_memberships(source)
	if not membership.ready: return report
	var matches: Array = membership.houses.filter(func(house): return house.prefix == failed.failedHouse)
	checks.unique_house = matches.size() == 1
	if not checks.unique_house: return report
	var policy := {"furnitureParts": [], "reservedVolumes": [], "requiredHeadroom": 1.72}
	var proposal := Heads.prepare_first(source, matches[0].memberIds, policy, state.checkpoint)
	if _expect_house_ready():
		checks.house_ready = proposal.get("ready", false)
		checks.producer_apertures_clear = _all_apertures_clear(source)
	else:
		checks.exact_reason = not proposal.get("ready", true) and proposal.get("reason") == failed.reason
		checks.geometry_captured = proposal.get("geometryConflict", {}).has("partId")
	checks.immutable = before == var_to_bytes(source.snapshot()) and FileAccess.get_sha256(INPUT) == INPUT_SHA and FileAccess.get_sha256(FAILURE) == FAILURE_SHA
	report["failure"] = proposal
	report["expectHouseReady"] = _expect_house_ready()
	report["captureSha256"] = FileAccess.get_sha256(output.get_base_dir().path_join("input.bin"))
	checks.deadline = state.checkpoint("single_house_geometry_completed")
	report.passed = checks.values().all(func(value): return value == true)
	return report

func _expect_house_ready() -> bool: return false

func _all_apertures_clear(source) -> bool:
	for declaration: Dictionary in source.recipe.facadeApertures.values():
		for id: String in declaration.partIds:
			var part = source.find_part(id)
			if part == null: return false
			var bounds: AABB = source.transformed_part_bounds(part)
			for opening: Dictionary in declaration.openings:
				if bounds.intersects(opening.fullVolume): return false
	return true

func _gate(stage: String) -> bool:
	if captured: after_false += 1; return false
	if not state.checkpoint(stage): return false
	if stage == "structural_completion_prepare_started": captured = true; return false
	return true
func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var value: Dictionary = file.get_var(false); file.close(); return value
