extends SceneTree
## Baseline acquisition only: full public phase output and fresh complete
## physical reports. Private unreturned local proof objects are not captured.
const Capture = preload("res://scripts/testing/buildings/CitadelFacadePhaseReplayCapture.gd")
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Facade = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")
const SOURCE := "res://scripts/buildings/CitadelFacadeCompletionRecipe.gd"
const SHIM := "res://scripts/testing/buildings/CitadelFacadePhaseReplayCapture.gd"
const ARTIFACTS := ["opening-input.bin", "opening-expected.bin", "lower-input.bin", "lower-expected.bin",
	"facade-expected.bin", "opening-physical.bin", "lower-physical.bin"]
var state = Diagnostic.Progress.new()
var output := ""
var input_path := ""
var input_sha := ""
var mirror := ""

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output = OS.get_environment("CITADEL_FACADE_PHASE_REPORT")
	input_path = OS.get_environment("CITADEL_FACADE_PHASE_INPUT")
	input_sha = OS.get_environment("CITADEL_FACADE_PHASE_INPUT_SHA256")
	mirror = OS.get_environment("CITADEL_FACADE_PHASE_MIRROR")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not input_path.begins_with("res://") \
			or input_path != input_path.simplify_path() or not mirror.begins_with("res://artifacts/citadel-runtime-integration/") \
			or mirror != mirror.simplify_path() or mirror.get_file() != "Facade.gd" \
			or not RegEx.create_from_string("^[a-f0-9]{64}$").search(input_sha): quit(2); return
	state.started = Time.get_ticks_msec(); state.begin_phase("facade_replay", 90000)
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
	var checks := {"inputPinned": FileAccess.get_sha256(input_path) == input_sha}
	var report := {"passed": false, "complete": false, "checks": checks, "inputPath": input_path, "inputSha256": input_sha,
		"scope": "Offline unchanged-baseline public phase outputs and independent full physical reports. No private unreturned proof capture, source acceptance, performance acceptance or gameplay acceptance."}
	var expected := FileAccess.get_file_as_string(SOURCE).replace("\r\n", "\n")
	for name: String in ["OpeningHeadBandRecipe", "LowerFacadeBearingRecipe"]:
		var dependency := 'preload("res://scripts/buildings/' + name + '.gd")'
		if expected.count(dependency) != 1: return report
		expected = expected.replace(dependency, 'preload("' + SHIM + '")')
	var ignored := mirror.get_base_dir().path_join(".gdignore")
	checks.exactInterception = expected == FileAccess.get_file_as_string(mirror).replace("\r\n", "\n")
	checks.hiddenMirror = FileAccess.file_exists(ignored) and FileAccess.get_file_as_string(ignored).is_empty()
	var source_hashes := {}
	for path: String in [SOURCE, SHIM, get_script().resource_path, mirror, ignored, input_path]: source_hashes[path] = FileAccess.get_sha256(path)
	report["sourceHashes"] = source_hashes
	if not checks.values().all(func(value): return value == true): return report
	var facade = load(mirror)
	checks.mirrorCompiled = facade is Script and facade.can_instantiate()
	if not checks.mirrorCompiled: return report
	var input := Capture.read_path(input_path)
	checks.typedInputComplete = input.get("blueprint") is Dictionary and input.get("policy") is Dictionary
	if not checks.typedInputComplete: return report
	var frozen_input := var_to_bytes(input)
	var blueprint = Copy.copy_blueprint(input.blueprint)
	checks.entrySnapshotExact = var_to_bytes(blueprint.snapshot()) == var_to_bytes(input.blueprint)
	if not checks.entrySnapshotExact: return report
	var original_parts: Array = blueprint.parts.duplicate()
	Capture.receipts.clear()
	var result: Dictionary = facade.prepare(blueprint, input.policy, state.checkpoint)
	report["phaseReceipts"] = Capture.receipts.duplicate(true)
	checks.facadeReady = result.get("ready") == true and result.get("exhausted") == true
	checks.callerInputUnchanged = frozen_input == var_to_bytes(input) and var_to_bytes(blueprint.snapshot()) == var_to_bytes(input.blueprint) and original_parts == blueprint.parts
	checks.bothPhasesCaptured = Capture.receipts.keys() == ["opening", "lower"]
	if not checks.values().all(func(value): return value == true): report["failure"] = result; return report
	checks.facadeOutputSavedExactly = Capture.write_value("facade-expected.bin", result)
	var opening_input := Capture.read_value("opening-input.bin")
	var opening := Capture.read_value("opening-expected.bin")
	var lower_input := Capture.read_value("lower-input.bin")
	var lower := Capture.read_value("lower-expected.bin")
	checks.openingSourceExact = var_to_bytes(opening_input.blueprint) == var_to_bytes(input.blueprint)
	checks.actualStagePolicy = opening_input.policy.keys().size() == 3 and opening_input.policy.get("requiredHeadroom") == Facade.REQUIRED_HEADROOM \
		and var_to_bytes(opening_input.policy.get("furnitureParts")) == var_to_bytes(input.policy.get("furnitureParts")) \
		and var_to_bytes(opening_input.policy.get("reservedVolumes")) == var_to_bytes(input.policy.get("reservedVolumes"))
	checks.phaseInputsBound = var_to_bytes(opening.candidateSnapshot) == var_to_bytes(lower_input.blueprint) and var_to_bytes(opening_input.policy) == var_to_bytes(lower_input.policy)
	checks.facadeRetainsPublicOutputs = var_to_bytes(result.opening) == var_to_bytes(Facade._without_snapshot(opening)) \
		and var_to_bytes(result.lower) == var_to_bytes(Facade._without_snapshot(lower)) and var_to_bytes(result.afterSnapshot) == var_to_bytes(lower.afterSnapshot)
	if not checks.values().all(func(value): return value == true): return report
	for phase: String in ["opening", "lower"]:
		var snapshot: Dictionary = opening.candidateSnapshot if phase == "opening" else lower.afterSnapshot
		var frozen := var_to_bytes(snapshot)
		var proof = Copy.copy_blueprint(snapshot)
		checks[phase + "ProofInputExact"] = var_to_bytes(proof.snapshot()) == frozen
		if not checks[phase + "ProofInputExact"]: return report
		Copy.clear_caches(proof)
		if not state.begin_phase(phase + "_independent_physical"): return report
		var physical: Dictionary = proof.validate_physical_integrity_cancellable(state.checkpoint)
		checks[phase + "PhysicalComplete"] = not physical.get("cancelled", false) and physical.get("checkedPartCount") == snapshot.parts.size() \
			and physical.get("checks") is Array and physical.checks.map(func(row): return row.partId) == snapshot.parts.map(func(part): return part.id)
		checks[phase + "ProofCallerUnchanged"] = frozen == var_to_bytes(snapshot)
		checks[phase + "PhysicalSavedExactly"] = Capture.write_value(phase + "-physical.bin", physical)
		# Intermediate structural failures are retained; later structural stages
		# have not run, so this diagnostic must not require an all-valid source.
		if not checks.values().all(func(value): return value == true): return report
	checks.sourcesUnchanged = source_hashes.keys().all(func(path): return source_hashes[path] == FileAccess.get_sha256(path))
	checks.deadline = state.checkpoint("facade_phase_capture_completed")
	var artifacts := {}
	for name: String in ARTIFACTS: artifacts[name] = FileAccess.get_sha256(Capture.artifact_path(name))
	report["artifactSha256"] = artifacts
	report["counts"] = {"openingHouses": opening.houseProposals.size(), "lowerAccepted": lower.accepted.size(), "lowerRejected": lower.rejected.size(),
		"openingParts": opening.candidateSnapshot.parts.size(), "lowerParts": lower.afterSnapshot.parts.size()}
	report.complete = artifacts.values().all(func(value): return String(value).length() == 64)
	report.passed = report.complete and checks.values().all(func(value): return value == true)
	return report
