extends SceneTree
## Source-only historical actual compound replay. No full Source or runtime run.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const COMPOUND := "res://artifacts/citadel-runtime-integration/compound-cancellation-baseline-01/baseline.bin"
var output := ""
var checks: Dictionary = {}
var rows: Array = []
var counts: Dictionary = {}
var stopped := false
var after_false := 0
var reject_stage := ""
var reject_occurrence := 1
var observed_blueprint: Variant = null
var rejection_snapshot: Dictionary = {}
var last_tick := 0
var max_gap := 0
var report := {"schema": "citadel-landscape-cancellation/v1", "passed": false, "complete": false,
	"evidenceLevel": "historical_actual_compound_source_contract", "doesNotProve": "No full Source rebuild, headed/NPC/navigation/visual/runtime acceptance."}

func _initialize() -> void: call_deferred("_run")
func _check(name: String, value: bool) -> bool:
	checks[name] = value
	if not value: print("CONTRACT FAILURE ", name)
	return value
func _read(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() > 134217728: return null
	var value: Variant = f.get_var(false)
	if f.get_error() != OK or f.get_position() != f.get_length(): return null
	return value
func _bound(values: Dictionary) -> bool:
	for path: String in values:
		if FileAccess.get_sha256(path) != values[path]: return false
	return true
func _binary(path: String, value: Variant) -> bool:
	if FileAccess.file_exists(path): return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null: return false
	f.store_var(value, false); f.flush()
	return f.get_error() == OK
func _run() -> void:
	output = OS.get_environment("LANDSCAPE_OUTPUT")
	report.phase = OS.get_environment("LANDSCAPE_PHASE")
	var launch: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("launch.json")))
	if not _check("dependencies_before", _bound(launch.dependencies)) or not _check("archives_before", _bound(launch.archives)):
		_finish(); return
	if report.phase == "baseline": _baseline(launch)
	else: _current(launch)
	_check("dependencies_after", _bound(launch.dependencies))
	_check("archives_after", _bound(launch.archives))
	_finish()
func _baseline(launch: Dictionary) -> void:
	if not _check("compound_hash", FileAccess.get_sha256(COMPOUND) == launch.compoundSha256): return
	var compound: Variant = _read(COMPOUND)
	if not _check("typed_actual_compound", compound is Dictionary and compound.seed == 1298433643 and compound.blueprint.parts.size() == 5204): return
	var original := var_to_bytes(compound)
	var b = Copy.copy_blueprint(compound.blueprint)
	var capture = load(output.path_join("CaptureComposer.gd"))
	var old = load(output.path_join("FrozenComposer.gd"))
	print("LANDSCAPE original prefix capture started")
	var started := Time.get_ticks_usec()
	var captured: Dictionary = capture.compose_prepared(b, int(compound.seed))
	if not _check("capture_ready", captured.get("ready") == true and captured.get("houseInput") is Dictionary and captured.get("houseOutput") is Dictionary and captured.get("treeInput") is Dictionary): return
	_check("tree_input_is_exact_stop", var_to_bytes(b.snapshot()) == var_to_bytes(captured.treeInput))
	var tree_before := var_to_bytes(b.snapshot())
	var sites: Array = old.select_open_paving_tree_sites(b, int(compound.seed))
	var sites_before := var_to_bytes(sites)
	var records: Array = old.build_tree_placement_records(sites, int(compound.seed))
	_check("tree_source_unchanged", tree_before == var_to_bytes(b.snapshot()))
	_check("selected_sites_unchanged", sites_before == var_to_bytes(sites))
	_check("nonempty_sites_and_records", not sites.is_empty() and records.size() == sites.size() and records[0] is Dictionary)
	_check("historical_compound_unchanged", original == var_to_bytes(compound))
	_check("dependencies_before_freeze", _bound(launch.dependencies))
	if false not in checks.values():
		var frozen := {"schema": "citadel-landscape-baseline/v1", "engine": Engine.get_version_info(), "revision": launch.revision,
			"compoundSha256": launch.compoundSha256, "seed": compound.seed, "context": compound.context,
			"dependencies": launch.dependencies, "gitHashes": launch.gitHashes, "houseInput": captured.houseInput,
			"houseOutput": captured.houseOutput, "treeInput": captured.treeInput, "sites": sites, "records": records}
		_check("baseline_saved_once", _binary(output.path_join("baseline.bin"), frozen))
		report.baselineSha256 = FileAccess.get_sha256(output.path_join("baseline.bin"))
	report.elapsedUsec = Time.get_ticks_usec() - started
	report.houseInputParts = captured.houseInput.blueprint.parts.size()
	report.houseOutputParts = captured.houseOutput.parts.size()
	report.treeInputParts = captured.treeInput.parts.size()
	report.siteCount = sites.size()
	report.recordCount = records.size()
func _checkpoint(stage: String) -> bool:
	var now := Time.get_ticks_usec()
	var gap := now - last_tick
	last_tick = now
	max_gap = maxi(max_gap, gap)
	if stopped: after_false += 1
	counts[stage] = int(counts.get(stage, 0)) + 1
	var permitted: bool = not stopped and not (stage == reject_stage and counts[stage] == reject_occurrence)
	if not permitted and not stopped:
		stopped = true
		if observed_blueprint != null: rejection_snapshot = observed_blueprint.snapshot()
	if not rows.is_empty() and rows[-1].stage == stage and permitted:
		rows[-1].count += 1
		rows[-1].lastUsec = now
		rows[-1].maxGapUsec = maxi(rows[-1].maxGapUsec, gap)
	else:
		rows.append({"stage": stage, "count": 1, "firstUsec": now, "lastUsec": now, "maxGapUsec": gap, "permitted": permitted})
	return permitted
func _reset_trace(stage: String = "", occurrence: int = 1) -> void:
	rows = []; counts = {}; stopped = false; after_false = 0; reject_stage = stage; reject_occurrence = occurrence
	observed_blueprint = null; rejection_snapshot = {}; max_gap = 0; last_tick = Time.get_ticks_usec()
func _trace() -> Dictionary:
	return {"rows": rows.duplicate(true), "counts": counts.duplicate(true), "maxGapUsec": max_gap, "afterFalse": after_false, "stopped": stopped}
func _invoke(api, target: String, mode: String, frozen: Dictionary, b, sites: Array) -> Variant:
	var h: Dictionary = frozen.houseInput
	var continuation := Callable(self, "_checkpoint") if mode == "true" else Callable()
	if target == "houses":
		if mode == "omitted": api.add_perimeter_neighborhoods(b, h.grammar, h.keepFrontZ, h.baseY, h.variation)
		else: api.add_perimeter_neighborhoods(b, h.grammar, h.keepFrontZ, h.baseY, h.variation, continuation)
		return b.snapshot()
	if target == "sites":
		if mode == "omitted": return api.select_open_paving_tree_sites(b, int(frozen.seed))
		return api.select_open_paving_tree_sites(b, int(frozen.seed), continuation)
	if mode == "omitted": return api.build_tree_placement_records(sites, int(frozen.seed))
	return api.build_tree_placement_records(sites, int(frozen.seed), continuation)
func _current(launch: Dictionary) -> void:
	var composer := "res://scripts/buildings/CitadelUrbanPocComposer.gd"
	if not _check("composer_before", FileAccess.get_sha256(composer) == launch.currentComposerSha256): return
	var baseline_path := OS.get_environment("LANDSCAPE_BASELINE").path_join("baseline.bin")
	if not _check("baseline_hash", FileAccess.get_sha256(baseline_path) == launch.baselineSha256): return
	var frozen: Variant = _read(baseline_path)
	if not _check("baseline_typed", frozen is Dictionary and frozen.schema == "citadel-landscape-baseline/v1"): return
	_check("baseline_dependencies", frozen.dependencies == launch.dependencies and _bound(frozen.dependencies))
	_check("engine_exact", frozen.engine == Engine.get_version_info())
	var frozen_before := var_to_bytes(frozen)
	var api = load(composer)
	var started := Time.get_ticks_usec()
	if report.phase == "parity":
		var mode := OS.get_environment("LANDSCAPE_MODE")
		report.mode = mode; report.targets = {}
		for target: String in ["houses", "sites", "records"]:
			var source: Dictionary = frozen.houseInput.blueprint if target == "houses" else frozen.treeInput
			var b = Copy.copy_blueprint(source)
			var sites: Array = frozen.sites.duplicate(true)
			_reset_trace()
			seed(831241); var expected_random := randf(); seed(831241)
			var result: Variant = _invoke(api, target, mode, frozen, b, sites)
			_check(target + "_global_rng_unchanged", randf() == expected_random)
			var expected: Variant = frozen.houseOutput if target == "houses" else (frozen.sites if target == "sites" else frozen.records)
			_check(target + "_full_typed_exact", var_to_bytes(result) == var_to_bytes(expected))
			_check(target + "_input_contract", (target == "houses" or var_to_bytes(b.snapshot()) == var_to_bytes(source)) and var_to_bytes(sites) == var_to_bytes(frozen.sites))
			_check(target + "_callbacks", (not counts.is_empty() if mode == "true" else counts.is_empty()) and not stopped)
			_check(target + "_result_saved", _binary(output.path_join(target + ".bin"), result))
			report.targets[target] = _trace()
	else:
		report.cases = {}
		for spec: Array in [["houses", "landscape_perimeter_house", 1], ["houses", "landscape_perimeter_house", 2],
			["sites", "landscape_tree_selection_started", 1], ["sites", "landscape_tree_candidate", 1], ["sites", "landscape_tree_candidate", 2],
			["sites", "landscape_tree_sort_started", 1], ["sites", "landscape_tree_spacing", 2], ["sites", "landscape_tree_selection_completed", 1],
			["records", "landscape_tree_records_started", 1], ["records", "landscape_tree_recipe", 1], ["records", "landscape_tree_recipe", 2], ["records", "landscape_tree_records_completed", 1]]:
			_cancel_case(api, frozen, spec)
		_empty_controls(api, frozen)
	_check("frozen_input_immutable", var_to_bytes(frozen) == frozen_before)
	_check("composer_after", FileAccess.get_sha256(composer) == launch.currentComposerSha256)
	report.currentComposerSha256 = launch.currentComposerSha256
	report.elapsedUsec = Time.get_ticks_usec() - started
func _cancel_case(api, frozen: Dictionary, spec: Array) -> void:
	var target: String = spec[0]
	var key := "%s_%d" % [spec[1], spec[2]]
	var source: Dictionary = frozen.houseInput.blueprint if target == "houses" else frozen.treeInput
	var b = Copy.copy_blueprint(source)
	var sites: Array = frozen.sites.duplicate(true)
	_reset_trace(spec[1], spec[2]); observed_blueprint = b
	var result: Variant = _invoke(api, target, "true", frozen, b, sites)
	_check(key + "_reject_reached", stopped and counts.get(spec[1], 0) == spec[2])
	_check(key + "_no_later_callback", after_false == 0 and not rows.is_empty() and rows[-1].permitted == false)
	_check(key + "_no_mutation_after_false", var_to_bytes(b.snapshot()) == var_to_bytes(rejection_snapshot))
	_check(key + "_caller_sites_immutable", var_to_bytes(sites) == var_to_bytes(frozen.sites))
	if target == "houses":
		_check(key + "_prefix_provenance", var_to_bytes(result.parts) == var_to_bytes(frozen.houseOutput.parts.slice(0, result.parts.size())))
		_check(key + "_partial_or_entry", result.parts.size() == source.parts.size() if spec[2] == 1 else (result.parts.size() > source.parts.size() and result.parts.size() < frozen.houseOutput.parts.size()))
	else:
		_check(key + "_empty_cancel_result", result is Array and result.is_empty())
		_check(key + "_blueprint_immutable", var_to_bytes(b.snapshot()) == var_to_bytes(source))
	_check(key + "_evidence_saved", _binary(output.path_join(key + ".bin"), {"result": result, "atRejection": rejection_snapshot}))
	report.cases[key] = _trace()
func _empty_controls(api, frozen: Dictionary) -> void:
	var old = load(output.path_join("FrozenComposer.gd"))
	var empty = Copy.copy_blueprint(frozen.treeInput)
	empty.parts.clear()
	var before := var_to_bytes(empty.snapshot())
	var expected: Array = old.select_open_paving_tree_sites(empty, int(frozen.seed))
	_check("legitimate_empty_old", expected.is_empty())
	for mode: String in ["omitted", "empty", "true"]:
		_reset_trace()
		var result: Variant = _invoke(api, "sites", mode, frozen, empty, [])
		_check("legitimate_empty_" + mode, var_to_bytes(result) == var_to_bytes(expected) and not stopped)
		if mode == "true": _check("legitimate_empty_completes", counts.get("landscape_tree_selection_completed", 0) == 1)
	_reset_trace("landscape_tree_selection_completed", 1)
	var cancelled: Variant = _invoke(api, "sites", "true", frozen, empty, [])
	_check("empty_cancel_distinguished_by_callback", cancelled.is_empty() and stopped and after_false == 0)
	_check("empty_input_immutable", var_to_bytes(empty.snapshot()) == before)
	report.cases.empty_cancel = _trace()
func _finish() -> void:
	report.checks = checks
	report.complete = true
	report.passed = not checks.is_empty() and false not in checks.values()
	var f := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "\t")); f.close()
	var summary := {"passed": report.passed, "complete": true, "phase": report.phase, "checks": checks.size(), "elapsedUsec": report.get("elapsedUsec", 0)}
	var sf := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	sf.store_string(JSON.stringify(summary, "\t")); sf.close()
	print("LANDSCAPE RESULT ", JSON.stringify(summary))
	quit(0 if report.passed else 1)
