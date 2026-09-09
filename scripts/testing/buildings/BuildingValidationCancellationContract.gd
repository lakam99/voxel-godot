extends SceneTree

## SOURCE/SERVICE CONTRACT ONLY: small synthetic fixtures, real blueprint proofs.
## No production substitution, physics, navigation or headed acceptance.
## Cancelled private proofs are discarded; recipe-fact rollback is NOT promised.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const BOUNDARIES := ["entry", "resolve", "grid", "support_resolution", "validation", "frame", "final"]
const REQUIRED_STAGES := [
	"physical_validation_started", "physical_resolve_schema", "physical_resolve_classification",
	"physical_resolve_roots", "physical_grid_part", "physical_grid_cells", "physical_resolve_support",
	"physical_validation_part", "physical_frame_context", "physical_frame_part",
	"physical_dependencies_started", "physical_validation_completed",
]
const SOURCES := [
	"res://scripts/buildings/BuildingBlueprint.gd",
	"res://scripts/buildings/BuildingPart.gd",
	"res://scripts/buildings/GablePurlinFrameValidator.gd",
	"res://scripts/buildings/MandatoryPhysicalDependencyValidator.gd",
	"res://scripts/testing/buildings/BuildingValidationCancellationContract.gd",
]

class Observed extends "res://scripts/buildings/BuildingBlueprint.gd":
	var resolve_calls := 0
	var index_calls := 0
	func resolve_physical_contracts() -> void:
		resolve_calls += 1
		super.resolve_physical_contracts()
	func index_structural_support_candidates() -> void:
		index_calls += 1
		super.index_structural_support_candidates()

var _checks: Dictionary = {}
var _cases: Array = []
var _traces: Dictionary = {}
var _stage_map: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("BUILDING_CANCELLATION_REPORT")
	var parsed = JSON.parse_string(OS.get_environment("BUILDING_CANCELLATION_STAGES"))
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()) or not parsed is Dictionary:
		quit(2)
		return
	_stage_map = parsed
	for boundary in BOUNDARIES:
		if not _stage_map.get(boundary) is String or String(_stage_map[boundary]).is_empty():
			push_error("Missing exact callback stage for boundary: " + boundary)
			quit(2)
			return
	var started := Time.get_ticks_usec()
	var hashes := _source_hashes()
	for fixture in ["ordinary", "wide_grid", "empty", "invalid_frame", "missing_dependency"]:
		_parity(fixture)
	_legacy_smoke()
	for fixture in ["ordinary", "wide_grid", "invalid_frame"]:
		var trace: Array = _traces[fixture]
		# First and last occurrence of EVERY observed stage, including late loops
		# after successful partial work. Stage-map coverage below cannot pass vacuously.
		var selected: Dictionary = {}
		for stage in trace:
			selected[trace.find(stage)] = true
			selected[trace.rfind(stage)] = true
		var indices: Array = selected.keys()
		indices.sort()
		for index in indices:
			_cancel_at(fixture, trace, int(index), false)
		# Also enter with populated old indexes; cancellation must clear them.
		if not trace.is_empty():
			_cancel_at(fixture, trace, 0, true)
	for boundary in BOUNDARIES:
		var expected := String(_stage_map[boundary])
		var exercised := false
		for result in _cases:
			if result.stage == expected and result.get("cancelled", false):
				exercised = true
		_checks["boundary_" + boundary + "_actually_cancelled"] = exercised
	for stage in REQUIRED_STAGES:
		_checks["confirmed_stage_" + stage + "_actually_cancelled"] = _cases.any(func(result): return result.stage == stage and result.cancelled)
	_checks["source_bytes_unchanged_during_run"] = hashes == _source_hashes()
	_checks["all_source_hashes_present"] = hashes.values().all(func(value): return String(value).length() == 64)
	var passed := not _checks.is_empty() and _checks.values().all(func(value): return value == true)
	var report := {
		"schema": "building_validation_cancellation_contract/v1", "complete": true,
		"passed": passed, "checks": _checks, "cases": _cases, "callbackTraces": _traces,
		"stageMap": _stage_map, "sourceSha256": hashes, "engine": Engine.get_version_info(),
		"elapsedUsec": Time.get_ticks_usec() - started, "evidenceLevel": "source_service_contract_only",
		"doesNotProve": [
			"No rollback of physical intent or recipe proof facts; cancelled private blueprints are discarded, never reused.",
			"Small hand-authored real-blueprint fixtures, not a frozen actual-Citadel old/new differential.",
			"Parity compares current public entry points, not independently frozen pre-change production code.",
			"Frame fixture is deliberately invalid; no successful full gable assembly proof is claimed.",
			"No latency guarantee within an individual callback interval, async worker or queue acceptance.",
			"No renderer, gameplay, terrain, publication, save, protected navigation or headed acceptance; NPC baseline deferred."
		]
	}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var write_ok := file.get_error() == OK
	file.close()
	print("BUILDING VALIDATION CANCELLATION: ", "PASS" if passed else "FAIL", " checks=", _checks.size(), " cases=", _cases.size())
	quit((0 if passed else 1) if write_ok else 2)

func _parity(kind: String) -> void:
	var legacy = _fixture(kind, Observed.new())
	var empty = _fixture(kind, Observed.new())
	var continuing = _fixture(kind, Blueprint.new())
	var base_legacy = _fixture(kind, Blueprint.new())
	var base_empty = _fixture(kind, Blueprint.new())
	_checks[kind + "_identical_fresh_inputs"] = var_to_bytes(legacy.snapshot()) == var_to_bytes(empty.snapshot()) and var_to_bytes(legacy.snapshot()) == var_to_bytes(continuing.snapshot())
	var trace: Array = []
	var keep_going := func(stage: String) -> bool:
		trace.append(stage)
		return true
	var old_report: Dictionary = legacy.validate_physical_integrity()
	var empty_report: Dictionary = empty.validate_physical_integrity_cancellable(Callable())
	var true_report: Dictionary = continuing.validate_physical_integrity_cancellable(keep_going)
	var base_report: Dictionary = base_legacy.validate_physical_integrity()
	var base_empty_report: Dictionary = base_empty.validate_physical_integrity_cancellable(Callable())
	_checks[kind + "_base_entry_points_full_report_bytes_exact"] = var_to_bytes(base_report) == var_to_bytes(base_empty_report) and var_to_bytes(base_report) == var_to_bytes(true_report)
	_checks[kind + "_base_entry_points_post_snapshot_bytes_exact"] = var_to_bytes(base_legacy.snapshot()) == var_to_bytes(base_empty.snapshot()) and var_to_bytes(base_legacy.snapshot()) == var_to_bytes(continuing.snapshot())
	_checks[kind + "_base_matches_observed_subclass"] = var_to_bytes(base_report) == var_to_bytes(old_report) and var_to_bytes(base_legacy.snapshot()) == var_to_bytes(legacy.snapshot())
	_checks[kind + "_base_owned_cache_released"] = _cache_clean(base_legacy) and _cache_clean(base_empty)
	_checks[kind + "_full_report_bytes_exact"] = var_to_bytes(old_report) == var_to_bytes(empty_report) and var_to_bytes(old_report) == var_to_bytes(true_report)
	_checks[kind + "_post_snapshot_bytes_exact"] = var_to_bytes(legacy.snapshot()) == var_to_bytes(empty.snapshot()) and var_to_bytes(legacy.snapshot()) == var_to_bytes(continuing.snapshot())
	_checks[kind + "_legacy_and_empty_call_virtual_resolve_and_index"] = legacy.resolve_calls == 1 and empty.resolve_calls == 1 and legacy.index_calls == 1 and empty.index_calls == 1
	_checks[kind + "_success_keeps_legacy_report_shape"] = not old_report.has("cancelled") and old_report.keys().size() == 4
	_checks[kind + "_all_entry_points_release_owned_cache"] = _cache_clean(legacy) and _cache_clean(empty) and _cache_clean(continuing)
	_checks[kind + "_expected_validation_outcome"] = bool(old_report.get("passed", false)) == (kind in ["ordinary", "wide_grid", "empty"])
	if kind == "wide_grid":
		_checks["wide_grid_reaches_repeated_64_cell_checkpoints"] = trace.count("physical_grid_cells") >= 2
	_checks[kind + "_callback_trace_nonempty"] = not trace.is_empty()
	_checks[kind + "_entry_and_final_bound_trace"] = not trace.is_empty() and trace.front() == "physical_validation_started" and trace.back() == "physical_validation_completed"
	_traces[kind] = trace
	# Retained report/snapshot values from a success must not be mutated by another pass.
	var retained := var_to_bytes([old_report, legacy.snapshot()])
	var unrelated = _fixture(kind, Blueprint.new())
	unrelated.validate_physical_integrity()
	_checks[kind + "_independent_proof_does_not_mutate_success"] = retained == var_to_bytes([old_report, legacy.snapshot()])

func _cancel_at(kind: String, expected_trace: Array, stop_index: int, prepopulated: bool) -> void:
	var proof = _fixture(kind, Blueprint.new())
	var label := "%s_%d%s" % [kind, stop_index, "_prepopulated" if prepopulated else ""]
	if prepopulated:
		proof.resolve_physical_contracts()
		_checks[label + "_starts_with_real_indexes"] = not proof.physical_parts_by_id.is_empty() and not proof.structural_support_grid.is_empty()
	var trace: Array = []
	var state := {"falseCount": 0, "afterFalseCount": 0}
	var continuation := func(stage: String) -> bool:
		if int(state.falseCount) > 0:
			state.afterFalseCount += 1
		trace.append(stage)
		# Return true again after the first false to catch non-terminal rejection.
		if trace.size() - 1 == stop_index:
			state.falseCount += 1
			return false
		return true
	var report: Dictionary = proof.validate_physical_integrity_cancellable(continuation)
	var cancelled: bool = report.get("passed") == false and report.get("cancelled") == true
	_checks[label + "_cancellation_sentinel"] = cancelled and report.get("checkedPartCount") == 0 and report.get("checks") == [] and report.get("violations") == ["physical_validation_cancelled"]
	_checks[label + "_no_extra_partial_payload"] = report.size() == 5
	_checks[label + "_first_false_terminal"] = state.falseCount == 1 and state.afterFalseCount == 0 and trace == expected_trace.slice(0, stop_index + 1)
	_checks[label + "_owned_cache_cleared"] = _cache_clean(proof)
	_checks[label + "_all_indexes_cleared"] = proof.physical_parts_by_id.is_empty() and proof.structural_support_grid.is_empty() and proof.invalid_gable_part_ids.is_empty()
	var reference: WeakRef = weakref(proof)
	# Do not validate or compare a cancelled proof's mutable recipe facts again.
	proof = null
	_checks[label + "_private_proof_discarded"] = reference.get_ref() == null
	_cases.append({"fixture": kind, "stopIndex": stop_index, "stage": expected_trace[stop_index], "prepopulated": prepopulated, "cancelled": cancelled, "trace": trace})

func _legacy_smoke() -> void:
	var observed = _fixture("ordinary", Observed.new())
	var plain = _fixture("ordinary", Blueprint.new())
	# Statements intentionally consume no return value: preserve public void APIs.
	observed.resolve_physical_contracts()
	plain.resolve_physical_contracts()
	_checks["public_void_resolve_override_and_nested_index_called"] = observed.resolve_calls == 1 and observed.index_calls == 1
	_checks["public_void_resolve_snapshot_exact"] = var_to_bytes(observed.snapshot()) == var_to_bytes(plain.snapshot())
	var expected: Array = observed.structural_candidates_near(Vector3(-4, 1, -4))
	observed.structural_support_grid.clear()
	observed.index_structural_support_candidates()
	_checks["public_void_index_override_callable"] = observed.index_calls == 2 and not expected.is_empty() and observed.structural_candidates_near(Vector3(-4, 1, -4)) == expected
	_checks["public_void_resolve_index_cache_clean"] = _cache_clean(observed) and _cache_clean(plain)

func _fixture(kind: String, blueprint):
	blueprint.id = "validation_cancellation_" + kind
	blueprint.seed = 1492
	if kind == "empty": return blueprint
	blueprint.add_part({"id": "root", "kind": "foundation", "position": Vector3(-4, 0.5, -4), "size": Vector3(12, 1, 12)})
	if kind == "wide_grid": blueprint.parts[0].size = Vector3(36, 1, 36)
	blueprint.add_part({"id": "floor", "kind": "floor", "position": Vector3(-4, 1.1, -4), "size": Vector3(4, 0.2, 4)})
	blueprint.add_part({"id": "mass", "kind": "beam", "position": Vector3(-4, 1.7, -4), "size": Vector3(1, 1, 1)})
	blueprint.add_part({"id": "trim", "kind": "beam", "position": Vector3(-4, 1.7, -4), "size": Vector3(0.2, 0.4, 0.2), "rotation": Vector3(0.2, 0.4, 0.1), "collision": false})
	if kind == "invalid_frame":
		blueprint.add_part({"id": "invalid_frame_post", "kind": "beam", "position": Vector3(-4, 2.7, -4), "size": Vector3.ONE, "physicalIntent": "structural_mass", "recipe": {"physicalGableFrameId": "incomplete_frame", "physicalAssemblyRole": "gable_roof_post"}})
	if kind == "missing_dependency":
		blueprint.parts[2].recipe["physicalTransformDependencyMissing"] = true
	blueprint.parts.append(null)
	return blueprint

func _cache_clean(blueprint) -> bool:
	return not blueprint._validation_cache_active and blueprint._validation_transforms.is_empty() and blueprint._validation_inverses.is_empty() and blueprint._validation_bounds.is_empty() and blueprint._validation_neighbors.is_empty() and blueprint._validation_columns.is_empty()

func _source_hashes() -> Dictionary:
	var result: Dictionary = {}
	for path in SOURCES:
		result[path] = FileAccess.get_sha256(path)
	return result
