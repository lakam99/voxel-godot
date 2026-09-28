extends SceneTree

## Source/service contract only. Calls Visual._prepare_frozen_recipe ONCE.
## No scene instance, publisher run, physics frames, headed run or navigation.
## VOXEL_TERMINAL_HOUSEHOLD_RESERVATION_REPORT: fresh absolute JSON path.
## VOXEL_ROOF_INTEGRATION_BASELINE: immutable RAW frozen source envelope.
## Unready preparation is not acceptance: passed=false, with its exact blocker;
## no-fit is reported separately from incomplete/resource-limited searches.
const Visual = preload("res://scripts/testing/buildings/CitadelMarketRecipeVisual.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Batch = preload("res://scripts/buildings/HouseholdLayoutBatchRecipe.gd")
const Layout = preload("res://scripts/buildings/RigidHouseholdLayoutRecipe.gd")
var _checks: Array = []
var _pairs: Array = []
var _membership: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("VOXEL_TERMINAL_HOUSEHOLD_RESERVATION_REPORT").strip_edges().simplify_path()
	var path := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE").strip_edges().simplify_path()
	if not output.is_absolute_path() or output.get_extension().to_lower() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()) or not path.is_absolute_path() or not FileAccess.file_exists(path):
		quit(2)
		return
	var digest := FileAccess.get_sha256(path)
	if digest != Visual.FROZEN_SHA:
		printerr("Reservation contract requires Visual's unchanged frozen baseline")
		quit(2)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		quit(2)
		return
	if file.get_length() > 128 * 1024 * 1024:
		file.close()
		quit(2)
		return
	var envelope: Variant = file.get_var(false)
	var read_ok := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not read_ok or not envelope is Dictionary or not envelope.get("output") is Dictionary or not envelope.output.get("sourceSnapshot") is Dictionary:
		quit(2)
		return
	var source: Dictionary = envelope.output.sourceSnapshot
	if not source.get("parts") is Array or source.parts.size() > Layout.MAX_PARTS:
		quit(2)
		return
	var fixture: Script = Visual
	if not fixture.has_method("_prepare_frozen_recipe") or not fixture.has_method("_prepare_terminal_frames"):
		quit(2)
		return
	var raw = _copy(source)
	var variation := float(int(raw.seed) % 19) / 100.0 - 0.09
	var scratch := Blueprint.new("terminal_producer_membership_only", raw.seed, raw.style)
	Urban.add_terminal_shop_row(scratch, Vector3.ZERO, variation)
	var producer_ids: Array = scratch.parts.map(func(part): return part.id)
	var present := producer_ids.all(func(id): return raw.physical_parts_by_id.has(id))
	_check("raw_complete_actual_producer_membership", present and not producer_ids.is_empty())
	# This is the sole full preparation/search call. Do not rerun on a failure
	# or synthesize successful placement by bypassing production frame checks.
	var prepared: Dictionary = fixture.call("_prepare_frozen_recipe", path, true)
	var ready: bool = prepared.get("ready", false)
	_check("preparation_ready_for_final_reservation_proof", ready, _brief(prepared))
	if ready:
		_check_ready(prepared, producer_ids)
	if present:
		_box_controls(raw, producer_ids)
		_invalid_reservations(raw, variation, fixture)
	_check("immutable_baseline_unchanged", digest == FileAccess.get_sha256(path))
	var passed: bool = not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var chain := _reason_chain(prepared)
	var outcome := "ready" if ready else ("no_fit" if chain.has("no_recipe_placement") else "blocked")
	var report := {"fixture": "TerminalHouseholdReservationContract", "passed": passed,
		"preparationReady": ready, "preparationOutcome": outcome, "preparationCalls": 1,
		"reservationProofComplete": ready and passed, "preparation": _brief(prepared), "reasonChain": chain,
		"baselinePath": path, "baselineSha256": digest, "checks": _checks, "membership": _membership, "reservationPairs": _pairs,
		"evidenceLevel": "actual_frozen_recipe_source_service_reservation_contract",
		"doesNotProve": "Unready preparation proves no successful layout. Bounded no-fit is not global impossibility. No published-mesh clearance, rendered visuals, live access, physics, gameplay or navigation acceptance."}
	var output_file := FileAccess.open(output, FileAccess.WRITE)
	if output_file == null:
		quit(2)
		return
	output_file.store_string(JSON.stringify(_json(report), "\t"))
	output_file.flush()
	var error := output_file.get_error()
	output_file.close()
	print("Terminal reservations: %s; preparation=%s (%d checks)" % ["PASS" if passed else "NOT ACCEPTED", outcome, _checks.size()])
	quit(2 if error != OK else (0 if passed else 1))

func _check_ready(prepared: Dictionary, producer_ids: Array) -> void:
	if not prepared.has("blueprint") or not prepared.get("plans") is Array or prepared.plans.size() != 3 or not prepared.get("terminals") is Dictionary:
		_check("ready_result_complete", false)
		return
	var b = prepared.blueprint
	var terminals: Dictionary = prepared.terminals
	var layout: Variant = terminals.get("elevation", {}).get("publicPavingPlan")
	if not layout is Dictionary or not layout.get("ready", false) or not terminals.get("allIds") is Array or not terminals.get("setups") is Array:
		_check("ready_terminal_layout_complete", false)
		return
	for key in ["footprint", "circulationFootprint", "approach"]:
		if not _valid_rect(layout.get(key)):
			_check("valid_terminal_rectangle:" + key, false)
			return
	_check("all_three_market_reservations_forwarded", layout.get("priorHouseholdReservationCount", -1) == prepared.plans.size() * 2)
	var parts: Dictionary = {}
	for part in b.parts:
		if parts.has(part.id):
			_check("unique_final_source_ids", false)
			return
		parts[part.id] = part
	var expected: Array = producer_ids.duplicate()
	for setup in terminals.setups:
		if not setup is Dictionary or not setup.get("construction") is Dictionary or not setup.construction.get("ready", false) or not setup.construction.get("partIds") is Array:
			_check("complete_terminal_frame_construction", false)
			return
		expected.append_array(setup.construction.partIds)
	_check("exact_final_terminal_membership", _unique_set_equal(expected, terminals.allIds))
	# A future complete-before-layout transaction may legitimately include its
	# new frame IDs here. Require every producer record, uniqueness and no foreign
	# IDs; the actual COMPLETE final geometry must still fit the reserved envelope.
	_check("layout_contains_complete_original_producer", _layout_members_valid(producer_ids, expected, layout.get("memberIds", [])))
	var footprint := Rect2()
	var first := true
	var omitted: Array = []
	for id in expected:
		if not parts.has(id):
			_check("every_terminal_record_present", false, id)
			return
		var part = parts[id]
		# Match shared-layout groundwear policy ONLY for geometric coverage.
		# It remains in exact producer/transaction membership, never discarded.
		if Layout._surface_detail(part):
			omitted.append(id)
			continue
		var bounds: AABB = b.transformed_part_bounds(part)
		var rect := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
		_check("complete_member_within_planned_footprint:" + id, _valid_rect(rect) and _contains(layout.footprint, rect))
		footprint = rect if first else footprint.merge(rect)
		first = false
	_membership = {"producerCount": producer_ids.size(), "completeCount": expected.size(), "groundwearExcludedFromFootprintOnly": omitted, "actualFootprint": footprint}
	_check("nonempty_complete_terminal_footprint", not first and _valid_rect(footprint))
	if first: return
	var terminal_rectangles := {"actualCompleteFootprint": footprint, "plannedFootprint": layout.footprint,
		"circulationFootprint": layout.circulationFootprint, "approach": layout.approach}
	for index in range(prepared.plans.size()):
		var market: Variant = prepared.plans[index]
		if not market is Dictionary:
			_check("valid_market_reservations:%d" % index, false)
			continue
		for key in ["approach", "circulationFootprint"]:
			if not _valid_rect(market.get(key)):
				_check("valid_market_reservation:%d:%s" % [index, key], false)
				continue
			for terminal_key in terminal_rectangles:
				var overlap := _intrusion(terminal_rectangles[terminal_key], market[key])
				var record := {"marketIndex": index, "marketReservation": key, "terminalRegion": terminal_key, "positiveAreaOverlap": overlap}
				_pairs.append(record)
				_check("no_intrusion:%s:market%d:%s" % [terminal_key, index, key], not overlap, record)

func _invalid_reservations(raw, variation: float, fixture: Script) -> void:
	# These malformed fourth arguments are rejected before placement search.
	# Each invocation gets a private copy of the ACTUAL raw source (not Visual's
	# already-framed product); no request here asks for a successful layout.
	var basis_rect := Rect2(Vector2.ZERO, Vector2.ONE)
	var excessive: Array = []
	for index in range(Batch.MAX_HOUSEHOLDS + 1):
		excessive.append({"approach": basis_rect, "circulationFootprint": basis_rect})
	var modes: Array = [
		{"id": "non_dictionary", "value": [null], "reason": "invalid_household_reservation"},
		{"id": "missing_fields", "value": [{}], "reason": "invalid_household_reservation"},
		{"id": "wrong_approach_type", "value": [{"approach": AABB(), "circulationFootprint": basis_rect}], "reason": "invalid_household_reservation"},
		{"id": "wrong_circulation_type", "value": [{"approach": basis_rect, "circulationFootprint": "bad"}], "reason": "invalid_household_reservation"},
		{"id": "nonfinite_approach", "value": [{"approach": Rect2(Vector2(NAN, 0), Vector2.ONE), "circulationFootprint": basis_rect}], "reason": "invalid_reserved_footprint"},
		{"id": "nonfinite_circulation", "value": [{"approach": basis_rect, "circulationFootprint": Rect2(Vector2.ZERO, Vector2(INF, 1))}], "reason": "invalid_reserved_footprint"},
		{"id": "zero_area", "value": [{"approach": Rect2(), "circulationFootprint": basis_rect}], "reason": "invalid_reserved_footprint"},
		{"id": "negative_extent", "value": [{"approach": basis_rect, "circulationFootprint": Rect2(Vector2.ZERO, Vector2(-1, 1))}], "reason": "invalid_reserved_footprint"},
		{"id": "excessive_count", "value": excessive, "reason": "household_reservation_limit"}
	]
	var raw_before := var_to_bytes(raw.snapshot())
	for mode in modes:
		var b = _copy(raw.snapshot())
		var before := var_to_bytes(b.snapshot())
		var aliases: Array = b.parts.duplicate()
		var recipes: Array = b.parts.map(func(part): return part.recipe)
		var index_keys := var_to_bytes(b.physical_parts_by_id.keys())
		var arguments_before := var_to_bytes(mode.value)
		var result: Dictionary = fixture.call("_prepare_terminal_frames", b, variation, [], mode.value)
		var atomic: bool = before == var_to_bytes(b.snapshot()) and b.parts.size() == aliases.size() and index_keys == var_to_bytes(b.physical_parts_by_id.keys()) and arguments_before == var_to_bytes(mode.value)
		for index in range(mini(b.parts.size(), aliases.size())):
			atomic = atomic and is_same(b.parts[index], aliases[index]) and is_same(b.parts[index].recipe, recipes[index]) and is_same(b.physical_parts_by_id.get(aliases[index].id), aliases[index])
		var reasons := _reason_chain(result)
		_check("invalid_fourth_argument_atomic:" + mode.id, not result.get("ready", false) and reasons.has(mode.reason) and atomic, _brief(result))
	_check("raw_source_unchanged_by_all_negative_controls", raw_before == var_to_bytes(raw.snapshot()))

func _box_controls(raw, ids: Array) -> void:
	var footprint := Rect2()
	var first := true
	for id in ids:
		var part = raw.physical_parts_by_id[id]
		if Layout._surface_detail(part): continue
		var bounds: AABB = raw.transformed_part_bounds(part)
		var rect := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
		footprint = rect if first else footprint.merge(rect)
		first = false
	if first:
		_check("independent_box_controls_have_actual_geometry", false)
		return
	var inner := Rect2(footprint.position + footprint.size * 0.25, footprint.size * 0.5)
	var touching := Rect2(Vector2(footprint.end.x, footprint.position.y), footprint.size)
	var crossing := Rect2(footprint.position + Vector2(footprint.size.x * 0.75, 0), footprint.size)
	_check("independent_boxes_reject_contained_intrusion", _intrusion(footprint, inner))
	_check("independent_boxes_reject_partial_intrusion", _intrusion(footprint, crossing))
	_check("independent_boxes_allow_zero_area_boundary_contact", not _intrusion(footprint, touching))

static func _valid_rect(value: Variant) -> bool:
	return value is Rect2 and value.position.is_finite() and value.size.is_finite() and value.end.is_finite() and value.size.x > 0.0 and value.size.y > 0.0

static func _intrusion(a: Rect2, b: Rect2) -> bool:
	# Independent interval arithmetic: no production predicate or samples.
	return minf(a.end.x, b.end.x) > maxf(a.position.x, b.position.x) and minf(a.end.y, b.end.y) > maxf(a.position.y, b.position.y)

static func _contains(outer: Rect2, inner: Rect2) -> bool:
	return inner.position.x >= outer.position.x and inner.position.y >= outer.position.y and inner.end.x <= outer.end.x and inner.end.y <= outer.end.y

static func _unique_set_equal(a: Array, b: Array) -> bool:
	var seen: Dictionary = {}
	for id in a:
		if not id is String or seen.has(id): return false
		seen[id] = true
	if a.size() != b.size(): return false
	for id in b:
		if not seen.has(id): return false
		seen.erase(id)
	return seen.is_empty()

static func _layout_members_valid(producer: Array, complete: Array, planned: Variant) -> bool:
	if not planned is Array: return false
	var seen: Dictionary = {}
	for id in planned:
		if not id is String or seen.has(id) or not complete.has(id): return false
		seen[id] = true
	return producer.all(func(id): return seen.has(id))

static func _copy(source: Dictionary):
	var b := Blueprint.new(source.id, source.seed, source.style)
	b.recipe = source.recipe.duplicate(true)
	b.rooms = source.rooms.duplicate(true)
	for record in source.parts:
		var part = b.add_part(record)
		part.physical_intent = record.get("physicalIntent", "")
		b.physical_parts_by_id[part.id] = part
	return b

static func _brief(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in ["ready", "reason", "partId", "visitedCandidates", "workUpperBound", "completedBeforeFailure"]:
		if value.has(key): result[key] = value[key]
	result["reasonChain"] = _reason_chain(value)
	return result

static func _reason_chain(value: Dictionary, depth := 0) -> Array:
	var result: Array = []
	if value.has("reason") and not String(value.reason).is_empty(): result.append(String(value.reason))
	if depth >= 8: return result
	for key in ["terminals", "layout", "plan", "detail", "lastFailure", "goods", "closure", "frame"]:
		if value.get(key) is Dictionary: result.append_array(_reason_chain(value[key], depth + 1))
	return result

func _check(name: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": name, "passed": passed, "detail": detail})

static func _json(value: Variant) -> Variant:
	if value is Vector2: return [value.x, value.y]
	if value is Rect2: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
