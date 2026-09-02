extends SceneTree

## Frozen-source and synthetic guard contract only; no publication or gameplay proof.
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Recipe = preload("res://scripts/buildings/DoorHoodBracketMountRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
var _checks: Dictionary = {}
var _plans: Array = []
var _calls := 0
var _immutable := true
var _path := ""

func _initialize() -> void:
	call_deferred("_run")

func _state(b, inputs: Array) -> PackedByteArray:
	var records: Array = []
	for value in inputs:
		records.append(value.snapshot() if value is Part else value)
	return var_to_bytes([b.snapshot(), records])

func _prepare(b, bracket, door, hood, panels: Array) -> Dictionary:
	var inputs: Array = [bracket, door, hood] + panels
	var before := _state(b, inputs)
	var result: Dictionary = Recipe.prepare(b, bracket, door, hood, panels)
	_immutable = _immutable and before == _state(b, inputs)
	_calls += 1
	return result

func _reject(name: String, b, bracket, door, hood, panels: Array) -> void:
	var result := _prepare(b, bracket, door, hood, panels)
	_checks[name] = result.get("ready") == false and not String(result.get("reason", "")).is_empty() and not result.has("part") and not result.has("pierId")

func _run() -> void:
	_path = OS.get_environment("VOXEL_DOOR_BRACKET_GUARD_REPORT")
	if not _path.is_absolute_path() or _path.get_extension() != "json" or FileAccess.file_exists(_path) or not DirAccess.dir_exists_absolute(_path.get_base_dir()):
		quit(2)
		return
	var source: Dictionary = Plan.read_input("candidate")
	_checks["frozen_whole09_bound"] = not source.is_empty() and source.get("afterSnapshot") is Dictionary
	if not _checks.frozen_whole09_bound:
		_finish()
		return
	var source_bytes := var_to_bytes(source)
	var b = Copy.copy_blueprint(source.afterSnapshot)
	_checks["exact_source_copy"] = var_to_bytes(b.snapshot()) == var_to_bytes(source.afterSnapshot)
	var by_id: Dictionary = {}
	for part in b.parts: by_id[part.id] = part
	var first: Array = []
	var count := 0
	for bracket in b.parts:
		if not "_door_bracket_" in String(bracket.id): continue
		count += 1
		var prefix: String = bracket.id.split("_door_bracket_")[0]
		var door = by_id.get(prefix + "_door")
		var hood = by_id.get(prefix + "_door_hood")
		var panels: Array = b.parts.filter(func(p): return p.semantic == "citadel_urban_facade" and p.id.begins_with(prefix + "_"))
		var result := _prepare(b, bracket, door, hood, panels)
		_checks["ready:" + bracket.id] = result.get("ready") == true and result.get("exactPierContact") == true and result.get("exactHoodContact") == true
		var reversed := panels.duplicate()
		reversed.reverse()
		var sorted := panels.duplicate()
		sorted.sort_custom(func(a, c): return a.id < c.id)
		var permuted: Array = []
		for parity in [1, 0]:
			for index in range(parity, panels.size(), 2): permuted.append(panels[index])
		var identical := true
		for order in [reversed, sorted, permuted]:
			identical = var_to_bytes(_prepare(b, bracket, door, hood, order)) == var_to_bytes(result) and identical
		_checks["order_bytes:" + bracket.id] = identical
		if result.get("ready") == true:
			_plans.append(result)
			if first.is_empty(): first = [bracket, door, hood, by_id[result.pierId]]
	_checks["exactly_32_plans"] = count == 32 and _plans.size() == 32
	if not first.is_empty(): _guards(b, first)
	_checks["synthetic_controls_exercised"] = not first.is_empty()
	_checks["frozen_input_immutable"] = source_bytes == var_to_bytes(source)
	_finish()

func _guards(b, original: Array) -> void:
	var seed_parts: Array = original.map(func(p): return p.snapshot())
	for slot in range(4):
		for mode in ["missing", "malformed", "nonfinite", "zero_size", "foreign"]:
			var parts: Array = seed_parts.map(func(record): return Part.new(record))
			match mode:
				"missing": parts[slot] = null
				"malformed": parts[slot] = {"id": "not_a_part"}
				"nonfinite": parts[slot].position.x = NAN
				"zero_size": parts[slot].size.y = 0.0
				"foreign": parts[slot].id = "foreign_" + parts[slot].id
			_reject("guard:%d:%s" % [slot, mode], b, parts[0], parts[1], parts[2], [parts[3]])
	var bracket = Part.new(seed_parts[0])
	var door = Part.new(seed_parts[1])
	var hood = Part.new(seed_parts[2])
	var pier = Part.new(seed_parts[3])
	_checks["synthetic_unique_pier_positive"] = _prepare(b, bracket, door, hood, [pier]).get("ready") == true
	_reject("empty_panels", b, bracket, door, hood, [])
	var bad_door = Part.new(seed_parts[1])
	bad_door.semantic = "not_a_door"
	_reject("door_semantic", b, bracket, bad_door, hood, [pier])
	var bad_panel = Part.new(seed_parts[3])
	bad_panel.semantic = "not_a_facade"
	_reject("panel_semantic", b, bracket, door, hood, [pier, bad_panel])
	var foreign = Part.new(seed_parts[3])
	foreign.id = "foreign_" + pier.id
	_reject("foreign_after_valid", b, bracket, door, hood, [pier, foreign])
	var duplicate = Part.new(seed_parts[3])
	duplicate.id += "_duplicate"
	_reject("nearest_duplicate", b, bracket, door, hood, [pier, duplicate])
	_reject("nearest_duplicate_reversed", b, bracket, door, hood, [duplicate, pier])
	var farther = Part.new(seed_parts[3])
	farther.id += "_farther"
	farther.position.z += signf(bracket.position.z - door.position.z) * 2.0
	var farther_twin = Part.new(farther.snapshot())
	farther_twin.id += "_twin"
	var expected := _prepare(b, bracket, door, hood, [pier])
	var basis := Basis.from_euler(bracket.rotation)
	var old_rear: Vector3 = bracket.position - basis.y * bracket.size.y * 0.5
	var new_rear: Vector3 = expected.part.position - basis.y * bracket.size.y * 0.5
	var old_height_pier = Part.new(seed_parts[3])
	old_height_pier.size.y = 0.02
	old_height_pier.position.y = old_rear.y
	var final_height_pier = Part.new(seed_parts[3])
	final_height_pier.id += "_final_height"
	final_height_pier.size.y = 0.02
	final_height_pier.position.y = new_rear.y
	_reject("old_height_pier_not_reused", b, bracket, door, hood, [old_height_pier])
	var at_final_height := _prepare(b, bracket, door, hood, [old_height_pier, final_height_pier])
	_checks["final_height_pier_selected"] = absf(new_rear.y - old_rear.y) > 0.02 and at_final_height.get("ready") == true and at_final_height.get("pierId") == final_height_pier.id
	var cross_slope = Part.new(seed_parts[2])
	cross_slope.rotation.x = 0.1
	_reject("unsupported_cross_slope", b, bracket, door, cross_slope, [pier])
	var different_plane = Part.new(seed_parts[3])
	different_plane.position.x += 0.1
	_reject("inconsistent_facade_plane", b, bracket, door, hood, [pier, different_plane])
	for order in [[farther, farther_twin, pier], [farther_twin, farther, pier], [pier, farther, farther_twin]]:
		_checks["farther_tie_order_%d" % _calls] = var_to_bytes(_prepare(b, bracket, door, hood, order)) == var_to_bytes(expected) and expected.get("ready") == true

func _finish() -> void:
	_checks["all_call_inputs_immutable"] = _immutable
	var passed: bool = not _checks.is_empty() and _checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": _checks, "plans": _plans, "prepareCalls": _calls, "candidateBinding": Plan.INPUTS.candidate, "evidenceScope": "frozen_source_and_synthetic_prepare_guards_only", "doesNotProve": "No physical validator, rooted support, published geometry, visual, clearance, NPC or gameplay acceptance."}
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if passed and written else 1)
