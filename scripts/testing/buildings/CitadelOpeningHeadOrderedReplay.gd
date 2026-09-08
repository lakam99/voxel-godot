extends SceneTree
## Frozen current producer; ordered geometry/bearing proof with synthetic empty
## furniture policy. No furniture-clearance, complete recipe or gameplay claim.
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const Heads = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate21-opening-producer-02/input.bin"
const SHA := "36ba4b715af39c9fad9cffcd7953c5f591afba1881daee61cedc6addf242bd80"
var state = Diagnostic.Progress.new()
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_ORDERED_OPENING_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	state.started = Time.get_ticks_msec(); state.begin_phase("ordered_heads", 90000)
	var worker := Thread.new()
	if worker.start(_work) != OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	state.finish(); report["progress"] = state.snapshot(true)
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK; file.close(); quit(0 if saved and report.passed else 1)
func _work() -> Dictionary:
	var input_path := _input_path()
	var checks := {"pinned": FileAccess.get_sha256(input_path) == _input_sha()}
	var report := {"passed": false, "checks": checks, "scope": _scope()}
	if not checks.pinned: return report
	var file := FileAccess.open(input_path, FileAccess.READ)
	if file == null: return report
	var input: Dictionary = file.get_var(false); file.close()
	var b = Heads.Copy.copy_blueprint(input.blueprint)
	var before := var_to_bytes(b.snapshot())
	var policy := _policy(input)
	var frozen_policy := var_to_bytes(policy)
	var result := Heads.prepare_all_first_rows(b, policy, state.checkpoint)
	checks.ordered_ready = result.get("ready", false)
	checks.source_immutable = before == var_to_bytes(b.snapshot()) and FileAccess.get_sha256(input_path) == _input_sha()
	checks.policy_immutable = frozen_policy == var_to_bytes(policy)
	result.erase("candidateSnapshot")
	report["result"] = result
	checks.deadline = state.checkpoint("ordered_replay_completed")
	report.passed = checks.values().all(func(value): return value == true)
	return report

func _input_path() -> String: return INPUT
func _input_sha() -> String: return SHA
func _policy(_input: Dictionary) -> Dictionary: return {"furnitureParts": [], "reservedVolumes": [], "requiredHeadroom": 1.72}
func _scope() -> String: return "Frozen current producer, actual ordered opening-head staging with synthetic empty furniture policy; no furniture clearance or candidate/gameplay acceptance."
