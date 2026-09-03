extends SceneTree

## Captured failed caller -> civic preparation ONLY. No compound generation,
## whole Composer, physical proof, furniture, scene or gameplay acceptance.
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Infill = preload("res://scripts/buildings/CivicHouseInfillRecipe.gd")
const Restore = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Interior = preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const Placement = preload("res://scripts/buildings/BoundaryInfillPlacement.gd")
const EXPECTED := {"ready": false, "reason": "column_work_limit_exceeded", "testedColumns": 264,
	"testedCandidates": 792, "sourceObstacleCount": 3729, "relevantObstacleCount": 416,
	"workUpperBound": 15943182, "nextColumnWork": 60032}
const EAST := "urban_civic_house_east"
var output := ""
var input_directory := ""
var deadline := 0
var checks: Dictionary = {}
var evidence: Dictionary = {}
var callbacks := 0
var stopped := false
var after_false := 0
var last_usec := 0
var max_gap_usec := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output = OS.get_environment("CITADEL_CIVIC_REPLAY_REPORT")
	input_directory = OS.get_environment("CITADEL_CIVIC_REPLAY_INPUT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):
		quit(2)
		return
	deadline = Time.get_ticks_msec() + 30000
	var worker := Thread.new()
	if worker.start(_work) != OK:
		_write_json(output, {"passed": false, "diagnosticCompleted": false, "recipePassed": false, "reason": "worker_start_failed"})
		quit(2)
		return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	var saved := _write_json(output, report)
	print("Civic infill replay diagnostic completed=", report.diagnosticCompleted, " checks=", checks.size(), " reproduced=", report.passed, " recipePassed=false")
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var hashes := _source_hashes()
	_replay(hashes)
	_check("deadline", Time.get_ticks_msec() < deadline and not stopped)
	_check("continuation_terminal", after_false == 0)
	_check("sources_unchanged", hashes == _source_hashes())
	var passed: bool = checks.values().all(func(value): return value == true)
	return {"schema": "citadel-civic-infill-replay/v1", "passed": passed,
		"diagnosticCompleted": evidence.has("replayResult"), "recipePassed": false,
		"expectedFailureReproduced": checks.get("exact_work_limit_receipt", false),
		"checks": checks, "evidence": evidence, "sourceHashes": hashes,
		"elapsedUsec": Time.get_ticks_usec() - started, "callbacks": callbacks, "maxCallbackGapUsec": max_gap_usec,
		"internalDeadlineSeconds": 30,
		"scope": "Exact captured failed caller plus ordinary civic environment/producer replay. Diagnostic success means the historical failure was reproduced, never successful Recipe, Site, physical proof or gameplay."}

func _replay(hashes: Dictionary) -> void:
	_check("absolute_existing_input_directory", input_directory.is_absolute_path() and DirAccess.dir_exists_absolute(input_directory))
	if not checks.absolute_existing_input_directory: return
	var caller_path := input_directory.path_join("caller-blueprint.bin")
	var input_path := input_directory.path_join("input.bin")
	var caller_read := _read_typed(caller_path)
	var input_read := _read_typed(input_path)
	var failure_read := _read_typed(input_directory.path_join("failure.bin"))
	_check("typed_inputs_read", caller_read.ready and input_read.ready and failure_read.ready)
	if not checks.typed_inputs_read: return
	var caller: Dictionary = caller_read.value
	var inputs: Dictionary = input_read.value
	var captured_failure: Dictionary = failure_read.value
	var capture_report := _read_json(input_directory.path_join("report.json"))
	var launch := _read_json(input_directory.path_join("launch.json"))
	var receipt: Dictionary = capture_report.get("receipt", {})
	_check("capture_receipt_hash_binding", receipt.get("callerBlueprintCaptured", false) and receipt.get("callerBlueprintSha256") == caller_read.sha256 and receipt.get("inputSha256") == input_read.sha256 and receipt.get("failureSha256") == failure_read.sha256)
	_check("captured_recipe_failed", captured_failure.get("ready") == false and receipt.get("recipePassed") == false)
	var captured_civic: Dictionary = captured_failure.get("civicQuarterFailure", {})
	_check("capture_exact_recipe08_failure", captured_civic.get("house") == EAST and _same_failure(captured_civic.get("detail", {})))
	var mismatches: Array = []
	var bound := 0
	var recorded_hashes: Dictionary = launch.get("sourceHashes", {})
	for path: String in recorded_hashes:
		if not path.begins_with("scripts/") or path.begins_with("scripts/testing/") or not path.ends_with(".gd"): continue
		bound += 1
		if hashes.get("res://" + path) != recorded_hashes[path]: mismatches.append(path)
	_check("capture_production_sources_bound", bound > 0 and mismatches.is_empty())
	evidence.inputBinding = {"directory": input_directory, "callerSha256": caller_read.sha256,
		"inputSha256": input_read.sha256, "failureSha256": failure_read.sha256,
		"captureCompleted": capture_report.get("captureCompleted", capture_report.get("diagnosticCompleted", false)),
		"capturedRecipePassed": receipt.get("recipePassed"), "productionSourceCount": bound, "sourceMismatches": mismatches}
	if not checks.capture_receipt_hash_binding or not checks.captured_recipe_failed or not checks.capture_exact_recipe08_failure or not checks.capture_production_sources_bound: return
	_check("caller_shape", caller.get("parts") is Array and caller.get("rooms") is Array and caller.get("recipe") is Dictionary and inputs.get("candidate") is Dictionary and inputs.get("context") is Dictionary)
	if not checks.caller_shape: return
	var seed: int = inputs.candidate.get("recipeSeed", -1)
	_check("candidate_context_identity", seed == caller.get("seed") and seed == 541151883 and inputs.candidate.get("siteId") == inputs.context.get("siteKey") and caller.recipe.get("context", {}).get("siteKey") == inputs.context.get("siteKey"))
	_check("caller_pre_civic_emission", caller.parts.all(func(row): return row is Dictionary and not String(row.get("id", "")).begins_with("urban_civic_house_") and row.get("id") != "urban_civic_quarter_paving"))
	if not checks.candidate_context_identity or not checks.caller_pre_civic_emission: return
	var caller_bytes := var_to_bytes(caller)
	var input_bytes := var_to_bytes(inputs)
	var source = Restore.copy_blueprint(caller)
	_check("restored_snapshot_typed_exact", caller_bytes == var_to_bytes(source.snapshot()))
	if not checks.restored_snapshot_typed_exact: return
	var grammar: Dictionary = source.recipe.get("castleGrammar", {})
	var base_y := float(source.recipe.get("foundationHeight", 0.62))
	var courtyard_depth := float(grammar.get("courtyardDepth", 84.0))
	var keep_depth := float(grammar.get("keepDepth", 28.0))
	var keep_center_z := courtyard_depth * float(grammar.get("keepOffset", {}).get("z", 0.14))
	var keep_front_z := keep_center_z - keep_depth * 0.5
	var front_z := -courtyard_depth * 0.5
	var variation := float(seed % 19) / 100.0 - 0.09
	var layout: Dictionary = Urban.sample_urban_layout(seed, grammar, front_z, keep_front_z, base_y)
	_check("sampled_layout_matches_captured", var_to_bytes(layout) == var_to_bytes(source.recipe.get("urbanPoc", {})))
	if not checks.sampled_layout_matches_captured: return
	var preview: Dictionary = Urban._civic_infill_environment(source, grammar, front_z, keep_front_z, base_y, variation, layout, _continue)
	_check("environment_prepared", preview.get("ready", false))
	_check("preview_preserves_caller", caller_bytes == var_to_bytes(source.snapshot()))
	if not checks.environment_prepared: return
	var environment = preview.blueprint
	var environment_before := var_to_bytes(environment.snapshot())
	var result: Dictionary = Urban.add_civic_quarter(source, front_z, keep_front_z, base_y, variation, layout, environment, _continue)
	evidence.replayResult = result
	_check("exact_work_limit_receipt", result.get("ready") == false and result.get("house") == EAST and result.get("reason") == "civic_infill_search_failed" and _same_failure(result.get("detail", {})))
	_check("failure_no_partial_output", not result.has("specs") and not result.has("receipts"))
	_check("failed_replay_preserves_caller", caller_bytes == var_to_bytes(source.snapshot()))
	_check("environment_preserved", environment_before == var_to_bytes(environment.snapshot()))
	# Obtain design inputs through the ordinary standalone producer. No copied
	# house dimensions, guessed paving bounds, removed obstacles or new sampler.
	var standalone = Restore.copy_blueprint(caller)
	var part_start: int = standalone.parts.size()
	var room_start: int = standalone.rooms.size()
	var standalone_result: Dictionary = Urban.add_civic_quarter(standalone, front_z, keep_front_z, base_y, variation, layout)
	_check("standalone_design_emitted", standalone_result.get("ready", false))
	if not checks.standalone_design_emitted: return
	var east = Blueprint.new("captured-civic-east-input", seed, "masonry")
	for part in standalone.parts.slice(part_start):
		if String(part.id).begins_with(EAST + "_"): east.parts.append(part)
	for room: Dictionary in standalone.rooms.slice(room_start):
		if String(room.id).begins_with(EAST + "_"): east.rooms.append(room)
	var geometry: Dictionary = Infill._house_geometry(east)
	var paving_parts: Array = standalone.parts.slice(part_start).filter(func(part): return part.id == "urban_civic_quarter_paving")
	_check("east_and_paving_produced", geometry.get("ready", false) and paving_parts.size() == 1)
	if not checks.east_and_paving_produced: return
	var paving_box: AABB = standalone.transformed_part_bounds(paving_parts[0])
	var paving := Rect2(Vector2(paving_box.position.x, paving_box.position.z), Vector2(paving_box.size.x, paving_box.size.z))
	var domain: Dictionary = Infill._domain(environment, paving)
	var authoritative: Dictionary = Infill._obstacles(environment, base_y)
	_check("domain_and_obstacles_ready", domain.get("ready", false) and authoritative.get("ready", false))
	if not checks.domain_and_obstacles_ready: return
	var named: Array = []
	for part in environment.parts:
		if Infill.compatible_underlay(part, base_y): continue
		named.append({"id": part.id, "origin": "part", "kind": part.kind, "semantic": part.semantic,
			"collision": part.collision_enabled, "bounds": environment.transformed_part_bounds(part)})
	for room: Dictionary in environment.rooms:
		if room.get("role", "") != "courtyard" and room.get("bounds") is AABB:
			named.append({"id": room.id, "origin": "room", "bounds": room.bounds})
		for access: Dictionary in room.get("accesses", []):
			named.append({"id": access.get("id", ""), "ownerRoomId": room.id, "origin": "access", "bounds": Interior.access_reservation(access)})
	_check("ordered_named_bounds_exact", var_to_bytes(named.map(func(row): return row.bounds)) == var_to_bytes(authoritative.boxes))
	_check("exact_obstacle_count", named.size() == EXPECTED.sourceObstacleCount)
	var direct_inputs_before := var_to_bytes([geometry.bounds, domain.bounds, authoritative.boxes, named])
	var direct_started := Time.get_ticks_usec()
	var direct: Dictionary = Placement.fit_columns(geometry.bounds, domain.bounds, authoritative.boxes, Infill.CLEARANCE,
		func() -> bool: return _continue("direct_fit_columns"))
	_check("direct_solver_exact_expected_failure", _same_failure(direct))
	_check("direct_solver_exact_live_detail", var_to_bytes(direct) == var_to_bytes(result.get("detail", {})))
	_check("direct_solver_inputs_unchanged", direct_inputs_before == var_to_bytes([geometry.bounds, domain.bounds, authoritative.boxes, named]))
	evidence.directSolver = {"result": direct, "elapsedUsec": Time.get_ticks_usec() - direct_started}
	# Read-only diagnostic of the CURRENT production prefilter. The direct
	# solve above always receives ALL originals, never this filtered inventory.
	var relevant: Array = []
	var moving: AABB = geometry.bounds
	var allowed: Rect2 = domain.bounds
	var low := float(allowed.position.x)
	var x_high := minf(float(allowed.end.x), low + float(allowed.size.x))
	var z_high := minf(float(allowed.end.y), float(allowed.position.y) + float(allowed.size.y))
	for i: int in range(named.size()):
		var box: AABB = named[i].bounds
		if not Placement._axis_overlap(moving, box, 1, 0.0): continue
		if float(box.position.x) - Infill.CLEARANCE >= x_high or Placement._upper(box, 0) + Infill.CLEARANCE <= low: continue
		if float(box.position.z) - Infill.CLEARANCE >= z_high or Placement._upper(box, 2) + Infill.CLEARANCE <= float(allowed.position.y): continue
		var row: Dictionary = named[i].duplicate()
		row["originalIndex"] = i
		relevant.append(row)
	_check("relevant_obstacles_exact_count", relevant.size() == EXPECTED.relevantObstacleCount and relevant.size() == int(direct.get("relevantObstacleCount", -1)))
	_check("relevant_inventory_preserves_originals", direct_inputs_before == var_to_bytes([geometry.bounds, domain.bounds, authoritative.boxes, named]))
	var relevant_path := output.get_base_dir().path_join("relevant-obstacles.json")
	_check("relevant_inventory_saved", _write_json(relevant_path, {"count": relevant.size(), "originalCount": named.size(), "rows": relevant,
		"scope": "Same conservative Y/domain-XZ production prefilter; original ordering retained via originalIndex. Diagnostic only, no obstacles removed from the direct solver input."}))
	evidence.relevantObstacles = {"path": relevant_path, "count": relevant.size(), "originalCount": named.size()}
	var payload := {"inputBinding": evidence.inputBinding, "seed": seed, "context": inputs.context,
		"grammar": grammar, "baseY": base_y, "variation": variation, "layout": layout,
		"frontZ": front_z, "keepFrontZ": keep_front_z, "paving": paving, "domain": domain.bounds,
		"clearance": Infill.CLEARANCE, "eastBlueprint": east.snapshot(), "eastEnvelope": geometry.bounds,
		"orderedObstacles": named, "relevantObstacles": relevant, "directSolverResult": direct,
		"observedFailure": result, "scope": "Captured caller geometry; real standalone East design and full exact ordered civic environment, no full Recipe success."}
	var typed_path := output.get_base_dir().path_join("replay-inputs.bin")
	_check("typed_replay_inputs_saved", _write_typed(typed_path, payload))
	_check("named_geometry_json_saved", _write_json(output.get_base_dir().path_join("replay-inputs.json"), payload))
	evidence.replayInputs = {"path": typed_path, "sha256": FileAccess.get_sha256(typed_path),
		"obstacleCount": named.size(), "eastPartCount": east.parts.size(), "eastEnvelope": geometry.bounds,
		"paving": paving, "domain": domain.bounds, "clearance": Infill.CLEARANCE}
	_check("frozen_inputs_immutable", caller_bytes == var_to_bytes(caller) and input_bytes == var_to_bytes(inputs))
	_check("input_files_unchanged", FileAccess.get_sha256(caller_path) == caller_read.sha256 and FileAccess.get_sha256(input_path) == input_read.sha256)

func _same_failure(value: Dictionary) -> bool:
	for key: String in EXPECTED:
		if value.get(key) != EXPECTED[key]: return false
	return true

func _continue(_stage: String) -> bool:
	if stopped:
		after_false += 1
		return false
	var now := Time.get_ticks_usec()
	if last_usec > 0: max_gap_usec = maxi(max_gap_usec, now - last_usec)
	last_usec = now
	callbacks += 1
	stopped = Time.get_ticks_msec() >= deadline
	return not stopped

func _check(label: String, value: bool) -> void:
	checks[label] = value

func _read_typed(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ready": false}
	var value: Variant = file.get_var(false)
	var valid: bool = file.get_error() == OK and value is Dictionary
	file.close()
	return {"ready": valid, "value": value, "sha256": FileAccess.get_sha256(path)}

func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return value if value is Dictionary else {}

func _write_typed(path: String, value: Dictionary) -> bool:
	if FileAccess.file_exists(path): return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_var(value, false)
	file.flush()
	var valid: bool = file.get_error() == OK
	file.close()
	return valid

func _write_json(path: String, value: Dictionary) -> bool:
	if FileAccess.file_exists(path): return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(_json(value), "  "))
	file.flush()
	var valid: bool = file.get_error() == OK
	file.close()
	return valid

func _source_hashes() -> Dictionary:
	var result: Dictionary = {}
	_hash_directory("res://scripts", result)
	return result

func _hash_directory(path: String, result: Dictionary) -> void:
	for name: String in DirAccess.get_files_at(path):
		if name.ends_with(".gd"): result[path.path_join(name)] = FileAccess.get_sha256(path.path_join(name))
	for name: String in DirAccess.get_directories_at(path):
		_hash_directory(path.path_join(name), result)

func _json(value: Variant) -> Variant:
	if value is Vector3: return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector2 or value is Vector2i: return {"x": value.x, "y": value.y}
	if value is AABB or value is Rect2: return {"position": _json(value.position), "size": _json(value.size), "end": _json(value.end)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value: result.append(_json(item))
		return result
	return value
