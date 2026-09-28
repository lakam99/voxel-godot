extends SceneTree

## Source contract ONLY: actual former build -> compose_prepared versus prepare.
## No publisher, scene, NPC, physical acceptance gate, or mocked generation.
## Run headless with --script res://scripts/testing/buildings/CitadelRecipePreparationContract.gd.
## VOXEL_CITADEL_RECIPE_PREPARATION_REPORT must name a fresh absolute JSON path
## in an existing directory. Use the existing scene watchdog with a 900s timeout:
## synchronous production calls cannot be interrupted by this script's budget.
const Builder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Composer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const PREPARATION_PATH := "res://scripts/buildings/CitadelRecipePreparation.gd"
const SEED := 237207443
const CONTEXT := {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25}
const MAX_PARTS := 20000
const MAX_CONTAINER := 100000
const MAX_VALUES := 48000000
const MAX_DEPTH := 64
const MAX_ELAPSED_USEC := 870000000

var report_path := ""
var started_usec := 0
var values_compared := 0
var checks: Dictionary = {}
var errors: Array[String] = []
var report := {
	"schema": "citadel-recipe-preparation-contract/v1",
	"evidenceLevel": "source_artifact_contract",
	"seed": SEED, "context": CONTEXT,
	"passed": false, "complete": false, "fullArtifactsCompared": false,
	"nullBuildCoverage": "not_exercised",
	"zeroScaleCoverage": "not_exercised: zero is valid no-override, not a rejection control; no validator-only API exists, so parity requires two additional full build attempts",
	"boundsCoverage": "Derived bounds/manifest deferred. Worker uses an explicit generous test envelope through its unchanged validator.",
	"doesNotProve": "No visual, physics, navigation, NPC, performance, or live gameplay acceptance. Matching failure handoffs do not prove successful artifact preparation.",
	"comparison": "Exact typed Variant values and container order; full production snapshots, plus furnishing access reservations. No JSON normalization, numeric tolerance, field filtering, or count-only parity.",
	"budgetScope": "Five production sequences: former, shared, actual fixture static entry, two valid worker runs; fixed invalid-scale controls add no builds. External watchdog must bound synchronous generation."
}


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> bool:
	checks[label] = condition
	if not condition and errors.size() < 16:
		errors.append(label)
	return condition


func _budget_ok() -> bool:
	return Time.get_ticks_usec() - started_usec <= MAX_ELAPSED_USEC


func _difference(path: String, reason: String) -> bool:
	if errors.size() < 16:
		errors.append(path.left(256) + ": " + reason)
	return false


func _exact(expected: Variant, actual: Variant, path: String, depth: int = 0) -> bool:
	values_compared += 1
	if depth > MAX_DEPTH or values_compared > MAX_VALUES:
		return _difference(path, "comparison_budget_exceeded")
	if values_compared % 4096 == 0 and not _budget_ok():
		return _difference(path, "elapsed_budget_exceeded")
	if typeof(expected) != typeof(actual):
		return _difference(path, "Variant_type_changed")
	if expected is Dictionary:
		if expected.size() > MAX_CONTAINER or actual.size() > MAX_CONTAINER:
			return _difference(path, "dictionary_limit_exceeded")
		if expected.size() != actual.size():
			return _difference(path, "dictionary_membership_changed")
		# Do not sort away insertion-order regressions in generated records.
		if not _exact(expected.keys(), actual.keys(), path + ".keys", depth + 1):
			return false
		for key: Variant in expected:
			if not _exact(expected[key], actual[key], path + "." + str(key).left(96), depth + 1):
				return false
		return true
	if expected is Array:
		if expected.size() > MAX_CONTAINER or actual.size() > MAX_CONTAINER:
			return _difference(path, "array_limit_exceeded")
		if expected.size() != actual.size():
			return _difference(path, "array_membership_changed")
		if expected.get_typed_builtin() != actual.get_typed_builtin() or expected.get_typed_class_name() != actual.get_typed_class_name() or expected.get_typed_script() != actual.get_typed_script():
			return _difference(path, "array_element_type_changed")
		for index in range(expected.size()):
			if not _exact(expected[index], actual[index], "%s[%d]" % [path, index], depth + 1):
				return false
		return true
	if typeof(expected) in [TYPE_OBJECT, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL]:
		return _difference(path, "unsupported_non_snapshot_value")
	if typeof(expected) in [TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY]:
		if expected.size() > MAX_CONTAINER or actual.size() > MAX_CONTAINER:
			return _difference(path, "packed_array_limit_exceeded")
	if expected is String and (expected.length() > 262144 or actual.length() > 262144):
		return _difference(path, "string_limit_exceeded")
	# Preserve numeric types and exact float bits, including embedded vectors,
	# transforms, AABBs, and packed-array element order. Never round or stringify.
	return true if var_to_bytes(expected) == var_to_bytes(actual) else _difference(path, "exact_value_changed")


func _snapshot(artifact: Variant, label: String, furniture: bool = false) -> Variant:
	if not _check(label + ".snapshot_api", artifact is Object and artifact.has_method("snapshot")):
		return null
	var parts: Variant = artifact.get("parts")
	if not _check(label + ".bounded_parts", parts is Array and parts.size() <= MAX_PARTS):
		return null
	for part: Variant in parts:
		if not _check(label + ".part_snapshot_api", part is Object and part.has_method("snapshot")):
			return null
	var snapshot: Variant = artifact.call("snapshot")
	if not _check(label + ".snapshot_complete", snapshot is Dictionary and snapshot.get("parts") is Array and snapshot.parts.size() == parts.size()):
		return null
	if furniture:
		if not _check(label + ".reservations_api", artifact.has_method("access_reservations_snapshot")):
			return null
		# FurnishingPlan.snapshot() intentionally omits these authoritative AABBs.
		snapshot["accessReservations"] = artifact.call("access_reservations_snapshot")
		if not _check(label + ".reservations_type", snapshot.accessReservations is Array):
			return null
	return snapshot


func _freeze_handoff(handoff: Dictionary, label: String) -> Dictionary:
	var frozen: Dictionary = handoff.duplicate(true)
	for key: String in ["blueprint", "furnishingPlan"]:
		if handoff.get(key) != null:
			frozen[key] = _snapshot(handoff[key], label + "." + key, key == "furnishingPlan")
	return frozen


func _compare_handoff(expected: Dictionary, actual: Variant, label: String) -> bool:
	if not _check(label + ".dictionary", actual is Dictionary):
		return false
	var frozen := _freeze_handoff(actual, label)
	# Exact membership includes every old diagnostic/preservation field. There
	# is no manifest extension in this extraction checkpoint.
	_check(label + ".keys_exact", _exact(expected.keys(), frozen.keys(), label + ".keys"))
	var passed := true
	for key: Variant in expected:
		var matches: bool = frozen.has(key) and _exact(expected[key], frozen[key], label + "." + str(key))
		_check(label + "." + str(key) + ".exact", matches)
		passed = matches and passed
	return passed and checks[label + ".keys_exact"]


func _assert_no_payload(result: Dictionary, label: String, worker: bool = false) -> void:
	_check(label + ".not_ready", result.get("ready") == false)
	if worker:
		_check(label + ".no_payload", result.get("blueprint") == null and result.get("furnishingPlan") == null and result.get("interiorProgram") == {})
	else:
		_check(label + ".no_payload", not result.has("blueprint") and not result.has("furnishingPlan") and not result.has("interiorProgram"))


func _invalid_scale_controls(preparation: Variant) -> void:
	var cases: Array = [
		{"label": "string", "scale": "1.25"}, {"label": "bool", "scale": true},
		{"label": "null", "scale": null}, {"label": "nan", "scale": NAN},
		{"label": "positive_infinity", "scale": INF}, {"label": "negative_infinity", "scale": -INF},
		{"label": "negative", "scale": -1.0},
		{"label": "above_six", "scale": 6.01}
	]
	for entry: Dictionary in cases:
		var context := CONTEXT.duplicate(true)
		context["citadelScale"] = entry.scale
		var frozen := context.duplicate(true)
		var label := "invalid_scale." + String(entry.label)
		var result: Variant = preparation.call("prepare", SEED, context)
		if _check(label + ".dictionary", result is Dictionary):
			_check(label + ".exact_rejection", _exact({"ready": false, "reason": "invalid_citadel_scale"}, result, label))
			_assert_no_payload(result, label)
		_check(label + ".context_unchanged", _exact(frozen, context, label + ".context"))


func _run_worker(job: Variant, context: Dictionary, label: String) -> Dictionary:
	var thread := Thread.new()
	var frozen := context.duplicate(true)
	print("Citadel preparation contract: ", label)
	if not _check(label + ".thread_started", thread.start(Callable(job, "run").bind(SEED, context)) == OK):
		return {}
	# Await actual OS-thread completion; never execute run() on the main thread.
	# The external watchdog owns termination if a production call stalls.
	while thread.is_alive():
		await process_frame
	thread.wait_to_finish()
	_check(label + ".context_unchanged", _exact(frozen, context, label + ".context"))
	_check(label + ".within_budget", _budget_ok())
	var result: Dictionary = job.result_snapshot()
	for key: String in ["buildDiagnostics", "envelopeValidation"]:
		# _exact visits every nested value and rejects Objects/RIDs/Callables/
		# Signals, including dictionary keys. A top-level erase is insufficient.
		_check(label + "." + key + ".data_only", result.get(key) is Dictionary and _exact(result[key], result[key], label + "." + key + ".data_only"))
	return result


func _worker_expected(prepared: Dictionary, context: Dictionary, envelope: Dictionary) -> Dictionary:
	var diagnostics := prepared.duplicate(true)
	for key: String in ["blueprint", "furnishingPlan", "interiorProgram"]:
		diagnostics.erase(key)
	var available: bool = prepared.get("blueprint") != null and envelope.get("passed") == true
	return {
		"finished": true, "ready": available and prepared.get("furnishingPlan") != null,
		"blueprint": prepared.get("blueprint") if available else null,
		"furnishingPlan": prepared.get("furnishingPlan") if available else null,
		"interiorProgram": prepared.get("interiorProgram", {}) if available else {},
		"buildDiagnostics": diagnostics, "envelopeValidation": envelope,
		"recipeContextSignature": context.recipeContextSignature,
		"failureReason": "blueprint_envelope_exceeded" if envelope.get("passed") != true else "" if available else prepared.get("reason", "blueprint_build_failed")
	}


func _compare_worker(expected: Dictionary, actual: Dictionary, label: String) -> bool:
	# Expected payloads are already immutable source snapshots, not object refs.
	var frozen := _freeze_handoff(actual, label)
	return _check(label + ".full_snapshot_exact", _exact(expected, frozen, label))


func _source_manifest(directory: String = "res://scripts") -> Array:
	var entries: Array = []
	var dir := DirAccess.open(directory)
	if dir == null:
		_check("source_directory_available", false)
		return entries
	var directories := dir.get_directories()
	directories.sort()
	for child in directories:
		entries.append_array(_source_manifest(directory.path_join(child)))
	var files := dir.get_files()
	files.sort()
	for file in files:
		if file.ends_with(".gd"):
			var path := directory.path_join(file)
			entries.append([path, FileAccess.get_sha256(path)])
	return entries


func _reference_identity() -> Dictionary:
	return {"schema": "citadel-source-reference/v1", "seed": SEED,
		"context": CONTEXT.duplicate(true), "engine": Engine.get_version_info(),
		"sourceManifest": _source_manifest()}


func _load_reference(path: String, expected_hash: String) -> Dictionary:
	if not _check("reference.hash_matches", path.is_absolute_path() and expected_hash.length() == 64 and FileAccess.get_sha256(path) == expected_hash):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if not _check("reference.readable", file != null):
		return {}
	if not _check("reference.size_bounded", file.get_length() <= 134217728):
		file.close()
		return {}
	var artifact: Variant = file.get_var(false)
	var read_ok := file.get_error() == OK
	file.close()
	if not _check("reference.complete_dictionary", read_ok and artifact is Dictionary and artifact.has("identity") and artifact.has("handoff")):
		return {}
	if not _check("reference.identity_exact", _exact(_reference_identity(), artifact.identity, "reference.identity")):
		return {}
	report["referenceSha256"] = expected_hash
	return artifact.handoff


func _run() -> void:
	started_usec = Time.get_ticks_usec()
	report_path = OS.get_environment("VOXEL_CITADEL_RECIPE_PREPARATION_REPORT")
	var phase := OS.get_environment("VOXEL_CITADEL_RECIPE_PREPARATION_PHASE")
	report["phase"] = phase
	report["budgetScope"] = "Reference and fixture: one full source build per process, 450s external cap. Worker: same-job valid-invalid-valid, two full builds, 900s cap."
	if not report_path.is_absolute_path() or FileAccess.file_exists(report_path) or not DirAccess.dir_exists_absolute(report_path.get_base_dir()):
		printerr("Set a fresh absolute report path in an existing directory.")
		quit(2)
		return
	if not _check("headless_only", DisplayServer.get_name() == "headless") or not _check("valid_phase", phase in ["reference", "fixture", "worker"]):
		_finish()
		return
	var reference_path := OS.get_environment("VOXEL_CITADEL_RECIPE_REFERENCE")
	var identity := _reference_identity()
	if phase == "reference":
		print("Citadel preparation: independent former sequence, seed=", SEED)
		var context := CONTEXT.duplicate(true)
		var former: Dictionary = Composer.compose_prepared(Builder.build(SEED, context), SEED)
		if not _check("reference.ready", former.get("ready") == true):
			report["referenceFailure"] = String(former.get("reason", "reference_build_failed"))
			_finish()
			return
		var frozen := _freeze_handoff(former, "reference")
		_check("reference.context_unchanged", _exact(CONTEXT, context, "reference.context"))
		_check("reference.data_only", _exact(frozen, frozen, "reference.data_only"))
		_check("reference.sources_unchanged", _exact(identity, _reference_identity(), "reference.sources"))
		if not _check("reference.fresh_destination", reference_path.is_absolute_path() and not FileAccess.file_exists(reference_path) and not FileAccess.file_exists(reference_path + ".pending")):
			_finish()
			return
		var artifact := {"identity": identity, "handoff": frozen}
		var bytes := var_to_bytes(artifact)
		_check("reference.binary_roundtrip_exact", _exact(artifact, bytes_to_var(bytes), "reference.roundtrip"))
		_check("reference.binary_size_bounded", bytes.size() <= 134217728)
		if checks.values().any(func(value): return value != true):
			_finish()
			return
		var file := FileAccess.open(reference_path + ".pending", FileAccess.WRITE)
		if not _check("reference.writable", file != null):
			_finish()
			return
		file.store_var(artifact, false)
		file.flush()
		var write_ok := file.get_error() == OK
		file.close()
		_check("reference.written", write_ok)
		if not write_ok:
			_finish()
			return
		_check("reference.finalized", DirAccess.rename_absolute(reference_path + ".pending", reference_path) == OK)
		report["referenceSha256"] = FileAccess.get_sha256(reference_path)
		report["referenceSnapshotComplete"] = true
		report["coverage"] = "independent source reference only; not equivalence acceptance"
		report["partCount"] = former.blueprint.parts.size()
		report["furnishingCount"] = former.furnishingPlan.parts.size()
		report["complete"] = true
		_finish()
		return
	var expected := _load_reference(reference_path, OS.get_environment("VOXEL_CITADEL_RECIPE_REFERENCE_SHA256"))
	if not _check("reference.successful_payload", expected.get("ready") == true and expected.get("blueprint") is Dictionary and expected.get("furnishingPlan") is Dictionary):
		_finish()
		return
	var preparation = load(PREPARATION_PATH)
	_invalid_scale_controls(preparation)
	if phase == "fixture":
		print("Citadel preparation: actual fixture -> shared API")
		var fixture = load("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")
		var actual: Variant = fixture.call("_generate_citadel", SEED, CONTEXT.citadelScale)
		report["fullArtifactsCompared"] = _compare_handoff(expected, actual, "fixture_api")
		report["coverage"] = "full artifact equality through actual fixture consumer and shared API"
	else:
		var job = load("res://scripts/buildings/CitadelBlueprintBuildJob.gd").new()
		var worker_context := CONTEXT.duplicate(true)
		worker_context.merge({"cellSize": 1.35, "blueprintEnvelopeRadiusCells": 256, "recipeContextSignature": "contract.valid.first"})
		var reference_blueprint = load("res://scripts/buildings/CitadelShopRecipe.gd").copy_source(expected.blueprint)
		var envelope: Dictionary = job.validate_blueprint_envelope(reference_blueprint, worker_context)
		_check("worker.fixture_envelope_admitted", envelope.get("passed") == true)
		var first: Dictionary = await _run_worker(job, worker_context, "worker.valid_first")
		var first_matches := _compare_worker(_worker_expected(expected, worker_context, envelope), first, "worker.valid_first")
		var invalid_context := worker_context.duplicate(true)
		invalid_context["citadelScale"] = -1.0
		invalid_context["recipeContextSignature"] = "contract.invalid"
		var invalid: Dictionary = await _run_worker(job, invalid_context, "worker.invalid")
		_compare_worker(_worker_expected({"ready": false, "reason": "invalid_citadel_scale"}, invalid_context, {"passed": true, "reason": "blueprint_unavailable"}), invalid, "worker.invalid")
		_assert_no_payload(invalid, "worker.invalid", true)
		worker_context["recipeContextSignature"] = "contract.valid.second"
		var second: Dictionary = await _run_worker(job, worker_context, "worker.valid_second")
		var second_matches := _compare_worker(_worker_expected(expected, worker_context, envelope), second, "worker.valid_second")
		var first_context := worker_context.duplicate(true)
		first_context["recipeContextSignature"] = "contract.valid.first"
		_compare_worker(_worker_expected(expected, first_context, envelope), first, "worker.retained_first")
		report["fullArtifactsCompared"] = first_matches and second_matches
		report["workerReuseCoverage"] = "same-process same-job valid -> invalid -> valid; retained first snapshot compared"
		report["coverage"] = "full source equality through real worker and shared API; completed-run reuse only"
	_check("stage.sources_unchanged", _exact(identity, _reference_identity(), "stage.sources"))
	report["complete"] = true
	_finish()

func _finish() -> void:
	_check("elapsed_budget", _budget_ok())
	report["checks"] = checks
	report["errors"] = errors
	report["valuesCompared"] = values_compared
	report["elapsedUsec"] = Time.get_ticks_usec() - started_usec
	var evidence_complete: bool = report.get("referenceSnapshotComplete", false) if report.get("phase") == "reference" else report.fullArtifactsCompared
	report["passed"] = report.complete and evidence_complete and checks.values().all(func(value): return value == true)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		printerr("Cannot write preparation contract report: ", report_path)
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	print("Citadel recipe source parity passed=", report.passed, " fullArtifactsCompared=", report.fullArtifactsCompared, " report=", report_path)
	quit(0 if report.passed and written else 2)
