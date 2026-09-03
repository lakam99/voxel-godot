extends SceneTree

## Actual producer subset plus explicitly synthetic blockers; never full-source acceptance.
const Infill = preload("res://scripts/buildings/CivicHouseInfillRecipe.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Sampler = preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Site = preload("res://scripts/world/CitadelSitePreparation.gd")
const Interior = preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const FurniturePlan = preload("res://scripts/buildings/FurnishingPlan.gd")
const FurniturePart = preload("res://scripts/buildings/FurnishingPart.gd")
const Boundary = preload("res://scripts/buildings/BoundaryInfillPlacement.gd")
const BASELINE := "res://artifacts/citadel-runtime-integration/candidate-civic-wall-03/subset-541151883.bin"
const BASELINE_SHA := "ff54c31dadef2b5d50fa2b0a4b01f22d549744525a94724e129d802140c3edf3"
const SEED := 541151883
const FEASIBILITY_INPUT := "res://artifacts/citadel-runtime-integration/civic-house-infill-02/placement-environment.bin"
const FEASIBILITY_SHA := "fb6e16d7ef5afd851f97b74b19db7abc2dcd612ca3ffb9483ade01d1b52707a0"
const MAX_X_ENDPOINTS := 512
const MAX_FIRST_POSES := 8
var checks: Dictionary = {}
var evidence: Dictionary = {}
var deadline: int
var worker: Thread
var callback_count := 0
var reject_at := -1
var rejected := false
var after_false := 0
var output_path := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("CITADEL_CIVIC_INFILL_OUTPUT")
	output_path = output
	if not output.is_absolute_path() or FileAccess.file_exists(output):
		quit(2)
		return
	deadline = Time.get_ticks_msec() + 30000
	worker = Thread.new()
	if worker.start(_work) != OK:
		quit(2)
		return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "  "))
	file.flush()
	var saved: bool = file.get_error() == OK
	file.close()
	print("Civic infill subset checks=", checks.size(), " passed=", report.passed)
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var hashes := _hashes()
	if OS.get_environment("CITADEL_CIVIC_INFILL_FEASIBILITY_ONLY") == "1":
		_feasibility()
	else:
		_exercise()
	_check("deadline", Time.get_ticks_msec() < deadline)
	_check("sources_unchanged", hashes == _hashes())
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks, "evidence": evidence,
		"sourceHashes": hashes, "elapsedUsec": Time.get_ticks_usec() - started, "baselineSha256": BASELINE_SHA,
		"evidenceLevel": "actual candidate B producer subset and synthetic negative controls",
		"limitations": "No compound courtyard placement, keep/tower construction, full recipe, shop/structural completion, terminal physical proof, terrain, scene publication or gameplay. Actual street/landmark/terrace and future-independent producers, roof frames and ordinary furnishing planner are included when initial placement succeeds. House bounds include all producer parts and access volumes; this is conservative external source AABB clearance, not same-house interior or exact rendered-solid intersection."}

func _feasibility() -> void:
	_check("frozen_environment_hash", FileAccess.get_sha256(FEASIBILITY_INPUT) == FEASIBILITY_SHA)
	if not checks.frozen_environment_hash: return
	var file := FileAccess.open(FEASIBILITY_INPUT, FileAccess.READ)
	if file == null:
		_check("frozen_environment_read", false)
		return
	var raw: Variant = file.get_var(false)
	var valid: bool = file.get_error() == OK and raw is Dictionary
	file.close()
	_check("frozen_environment_read", valid)
	if not valid: return
	var original_bytes := var_to_bytes(raw)
	var original = Copy.copy_blueprint(raw.originalCivicProducer)
	var environment = Copy.copy_blueprint(raw.environment)
	var names: Array[String] = ["urban_civic_house_east", "urban_civic_house_wall"]
	var houses: Dictionary = {}
	for name: String in names: houses[name] = _house_bounds(original, name)
	var allowed: Rect2 = raw.domain.bounds
	var verified_domain: Dictionary = Infill._domain(environment, raw.paving)
	_check("same_frozen_paving_curtain_domain", verified_domain.get("ready", false) and verified_domain.bounds == allowed)
	var named: Array = raw.namedObstacles
	var boxes: Array = named.map(func(row): return row.bounds)
	var current: Dictionary = Infill._obstacles(environment, 0.62)
	var independently_rebuilt: Array = _independent_obstacles(environment, true).map(func(row): return row.bounds)
	_check("frozen_obstacles_match_recorded_geometry", var_to_bytes(independently_rebuilt) == var_to_bytes(boxes))
	var policy_audit := {"currentCollectorReady": current.get("ready", false), "currentCollectorReason": current.get("reason", ""),
		"frozenCount": boxes.size(), "addedCurrentPolicyObstacles": 0}
	if current.get("ready", false):
		# Retain every frozen obstacle and multiplicity. Only add newly classified
		# blockers; stricter current underlay policy cannot make this probe easier.
		var remaining: Dictionary = {}
		for box: AABB in boxes:
			var key := var_to_bytes(box).hex_encode()
			remaining[key] = int(remaining.get(key, 0)) + 1
		for box: AABB in current.boxes:
			var key := var_to_bytes(box).hex_encode()
			if int(remaining.get(key, 0)) > 0: remaining[key] -= 1
			else:
				boxes.append(box)
				policy_audit.addedCurrentPolicyObstacles += 1
	_check("all_frozen_obstacles_retained", var_to_bytes(boxes.slice(0, named.size())) == var_to_bytes(named.map(func(row): return row.bounds)))
	var added_details: Array = []
	var all_named: Array = named.duplicate()
	for part in environment.parts:
		var formerly_detail: bool = not part.collision_enabled and (part.kind == "ground_patch" or String(part.semantic).contains("wear") or String(part.semantic).contains("compaction"))
		if not formerly_detail or Infill.compatible_underlay(part, 0.62): continue
		var detail := {"id": part.id, "kind": part.kind, "semantic": part.semantic, "collision": part.collision_enabled,
			"bounds": environment.transformed_part_bounds(part), "origin": "part"}
		added_details.append(detail)
		all_named.append(detail)
	_check("added_details_exact_current_boxes", var_to_bytes(all_named.map(func(row): return row.bounds)) == var_to_bytes(boxes))
	policy_audit["addedDetails"] = added_details
	if not checks.same_frozen_paving_curtain_domain or not checks.frozen_obstacles_match_recorded_geometry: return
	var groups: Array = []
	for prefix: String in ["urban_row_02_right", "urban_civic_shed", "urban_civic_storage", "urban_perimeter_east_00"]:
		var aggregate := AABB()
		var count := 0
		for part in environment.parts:
			if not String(part.id).begins_with(prefix + "_"): continue
			var box: AABB = environment.transformed_part_bounds(part)
			aggregate = box if count == 0 else aggregate.merge(box)
			count += 1
		groups.append({"producerPrefix": prefix, "partCount": count, "completePartEnvelope": aggregate})
	var orders: Array = []
	var east_box: AABB = houses[names[0]].bounds
	var right_x := minf(float(allowed.end.x), float(allowed.position.x) + float(allowed.size.x)) - float(east_box.size.x)
	var right_box := AABB(east_box.position + Vector3(right_x - float(east_box.position.x), 0, 0), east_box.size)
	var right_diagnostic: Dictionary = _column_union(right_box, all_named)
	for order: Array in [names, [names[1], names[0]]]:
		var order_deadline := mini(deadline - 1000, Time.get_ticks_msec() + 13000)
		orders.append(_search_order(order, houses, allowed, boxes, order_deadline))
	_check("both_orders_examined", orders.size() == 2)
	_check("all_returned_poses_independently_validated", orders.all(func(order): return order.invalidReturnedPoses == 0))
	_check("frozen_payload_immutable", original_bytes == var_to_bytes(raw))
	evidence.feasibility = {"input": FEASIBILITY_INPUT, "inputSha256": FEASIBILITY_SHA, "domain": allowed, "paving": raw.paving,
		"houses": houses, "completeProducerExtents": groups, "obstacleCount": boxes.size(), "obstaclePolicyAudit": policy_audit, "orders": orders,
		"eastRightEndpoint": right_diagnostic,
		"anyTwoHouseCandidate": orders.any(func(order): return order.found), "siteAccepted": false,
		"searchPolicy": "Every unique geometric X endpoint when inventory <=512; larger inventory is explicit cap, not subsampling. First scan all first-house columns, then up to 8 feasible first poses with every second-house endpoint. Nearest-Z fixed-X result per call, both orders, 13 seconds per order. All existing obstacles retained.",
		"limitations": "Bounded endpoint diagnostic, not complete 2D feasibility or accepted source. Shifted frozen envelopes only: a found candidate requires actual producer rebuild and terminal validation. No-fit only concerns enumerated endpoint/nearest-Z results; time, endpoint and first-pose caps remain explicit."}

func _column_union(moving: AABB, named: Array) -> Dictionary:
	var intervals: Array = []
	var curtain: Array = []
	for row: Dictionary in named:
		var box: AABB = row.bounds
		if float(moving.position.x) >= _upper(box, 0) + Infill.CLEARANCE or _upper(moving, 0) <= float(box.position.x) - Infill.CLEARANCE: continue
		if float(moving.position.y) >= _upper(box, 1) or _upper(moving, 1) <= float(box.position.y): continue
		intervals.append({"low": float(box.position.z) - Infill.CLEARANCE, "high": _upper(box, 2) + Infill.CLEARANCE, "id": row.id})
		if String(row.id).begins_with("castle_right_wall"):
			curtain.append(row)
	intervals.sort_custom(func(a: Dictionary, b: Dictionary): return a.low < b.low if a.low != b.low else a.high < b.high)
	var merged: Array = []
	for row: Dictionary in intervals:
		if merged.is_empty() or row.low > merged[-1].high:
			merged.append({"low": row.low, "high": row.high, "count": 1, "lowOwner": row.id, "highOwner": row.id})
		else:
			merged[-1].count += 1
			if row.high > merged[-1].high:
				merged[-1].high = row.high
				merged[-1].highOwner = row.id
	return {"bounds": moving, "matchingCount": intervals.size(), "mergedZIntervals": merged, "curtainBlockers": curtain}

func _search_order(order: Array, houses: Dictionary, domain: Rect2, obstacles: Array, stop_msec: int) -> Dictionary:
	var first: AABB = houses[order[0]].bounds
	var second: AABB = houses[order[1]].bounds
	var endpoints: Dictionary = _x_endpoints(first, domain, obstacles)
	var trials: Array = []
	var first_count := 0
	var calls := 0
	var invalid := 0
	var found: Dictionary = {}
	var feasible: Array = []
	var started := Time.get_ticks_usec()
	for x: float in endpoints.selected:
		if Time.get_ticks_msec() >= stop_msec: break
		var moved := AABB(first.position + Vector3(x - float(first.position.x), 0, 0), first.size)
		var result: Dictionary = Boundary.fit(moved, domain, obstacles, Infill.CLEARANCE, func(): return Time.get_ticks_msec() < stop_msec)
		calls += 1
		var trial := {"firstX": x, "firstResult": result, "secondCalls": 0, "secondEndpointCount": 0, "secondFailures": {}}
		trials.append(trial)
		if not result.get("ready", false): continue
		var placed: AABB = result.placedBounds
		if not _pose_clear(placed, domain, obstacles):
			invalid += 1
			continue
		first_count += 1
		feasible.append(trial)
	var paired_first_count := 0
	for trial: Dictionary in feasible:
		if Time.get_ticks_msec() >= stop_msec or paired_first_count >= MAX_FIRST_POSES: break
		paired_first_count += 1
		var placed: AABB = trial.firstResult.placedBounds
		var with_first: Array = obstacles.duplicate()
		with_first.append(placed)
		var next: Dictionary = _x_endpoints(second, domain, with_first)
		trial.secondEndpointCount = next.totalCount
		for next_x: float in next.selected:
			if Time.get_ticks_msec() >= stop_msec: break
			var second_input := AABB(second.position + Vector3(next_x - float(second.position.x), 0, 0), second.size)
			var result_second: Dictionary = Boundary.fit(second_input, domain, with_first, Infill.CLEARANCE, func(): return Time.get_ticks_msec() < stop_msec)
			calls += 1
			trial.secondCalls += 1
			if not result_second.get("ready", false):
				var reason: String = result_second.get("reason", "unknown")
				trial.secondFailures[reason] = int(trial.secondFailures.get(reason, 0)) + 1
				continue
			var placed_second: AABB = result_second.placedBounds
			if not _pose_clear(placed_second, domain, with_first):
				invalid += 1
				continue
			found = {"firstId": order[0], "firstBounds": placed, "firstTranslation": placed.position - first.position,
				"secondId": order[1], "secondBounds": placed_second, "secondTranslation": placed_second.position - second.position}
			break
		if not found.is_empty(): break
	return {"order": order, "found": not found.is_empty(), "candidate": found, "firstEndpointInventory": endpoints,
		"firstFeasiblePoseCount": first_count, "solverCalls": calls, "trials": trials, "invalidReturnedPoses": invalid,
		"firstColumnsTested": trials.size(), "allFirstEndpointsTested": trials.size() == endpoints.totalCount,
		"timeCapReached": Time.get_ticks_msec() >= stop_msec, "firstPoseCapReached": found.is_empty() and paired_first_count >= MAX_FIRST_POSES and paired_first_count < feasible.size(),
		"elapsedUsec": Time.get_ticks_usec() - started}

func _pose_clear(box: AABB, domain: Rect2, obstacles: Array) -> bool:
	if not _inside(box, domain): return false
	for other: AABB in obstacles:
		if _conflict(box, other, Infill.CLEARANCE): return false
	return true

func _x_endpoints(moving: AABB, domain: Rect2, obstacles: Array) -> Dictionary:
	var low := float(domain.position.x)
	var high := minf(float(domain.end.x), low + float(domain.size.x)) - float(moving.size.x)
	var values: Dictionary = {}
	var origin := clampf(float(moving.position.x), low, high)
	for x: float in [low, high, origin]: values[x] = true
	for box: AABB in obstacles:
		if float(moving.position.y) >= _upper(box, 1) or _upper(moving, 1) <= float(box.position.y): continue
		for x: float in [float(box.position.x) - Infill.CLEARANCE - float(moving.size.x), _upper(box, 0) + Infill.CLEARANCE]:
			if x >= low and x <= high: values[x] = true
	var ordered: Array = values.keys()
	ordered.sort()
	var selected: Array[float] = []
	for x: float in [origin, low, high]:
		if not selected.has(x): selected.append(x)
	if ordered.size() > MAX_X_ENDPOINTS:
		return {"totalCount": ordered.size(), "selectedCount": 0, "subsampled": false, "endpointCapReached": true, "selected": []}
	for x: float in ordered:
		if not selected.has(x): selected.append(x)
	return {"totalCount": ordered.size(), "selectedCount": selected.size(), "subsampled": false, "endpointCapReached": false, "selected": selected}

func _exercise() -> void:
	_check("baseline_hash", FileAccess.get_sha256(BASELINE) == BASELINE_SHA)
	if not checks.baseline_hash: return
	var file := FileAccess.open(BASELINE, FileAccess.READ)
	if file == null:
		_check("baseline_read", false)
		return
	var frozen: Variant = file.get_var(false)
	var read_ok: bool = file.get_error() == OK and frozen is Dictionary
	file.close()
	_check("baseline_read", read_ok)
	if not read_ok: return
	var candidate: Dictionary = Field.candidate_for_region("atlas-30895044", Vector2i(-1, 0))
	_check("actual_candidate_seed", candidate.get("recipeSeed") == SEED)
	var raw := {"biome": "forest", "siteKey": candidate.siteId, "citadelScale": Site.SCALE}
	var context: Dictionary = raw.duplicate(true)
	context["settlementTier"] = "city"
	context["style"] = "masonry"
	var compound: Dictionary = Sampler.sample_compound(SEED, "castle", context)
	_check("sampled_compound_exact_diagnostic03", var_to_bytes(compound) == var_to_bytes(frozen.compound))
	if not checks.sampled_compound_exact_diagnostic03: return
	var grammar: Dictionary = compound.castleGrammar
	var members: Array = compound.members
	var courtyard: Dictionary = Castle.member_recipe(members, "courtyard")
	var gatehouse: Dictionary = Castle.member_recipe(members, "gatehouse")
	var towers: Array = Castle.member_recipes(members, "tower")
	var width := float(grammar.get("courtyardWidth", courtyard.get("width", 46.0)))
	var depth := float(grammar.get("courtyardDepth", courtyard.get("depth", 42.0)))
	var span := float(grammar.get("towerSpan", (towers[0] as Dictionary).get("width", 6.4) if not towers.is_empty() else 6.4))
	var height := float(grammar.get("wallHeight", float(gatehouse.get("floorHeight", 3.6)) * 1.70))
	var tower_height := float(grammar.get("towerHeightBase", float((towers[0] as Dictionary).get("floorHeight", 3.6)) * 3.4 if not towers.is_empty() else 12.4))
	var specs: Array = Castle.tower_specs_for_grammar(SEED, width, depth, clampi(int(grammar.get("towerCount", 4)), 4, 8), span, tower_height, float(grammar.get("towerHeightVariation", 0.16)), int(grammar.get("towerPhase", 0)))
	var north := Castle.tower_span_for_role(specs, "northeast", span)
	var south := Castle.tower_span_for_role(specs, "southwest", span)
	var variation := float(SEED % 19) / 100.0 - 0.09
	var material := String((grammar.get("citadelMasonry", {}) as Dictionary).get("fortification", "fired_brick"))
	var source = Blueprint.new("civic-infill-actual-subset", SEED, "masonry")
	source.set_recipe({"castleGrammar": grammar.duplicate(true), "foundationHeight": 0.62})
	Castle.add_curtain_z_segment(source, "castle_right_wall", width * 0.5, -depth * 0.5 + north * 0.5, depth * 0.5 - south * 0.5, height, 0.62, variation, material)
	var wall: Dictionary = _part(source, "castle_right_wall_wall").snapshot()
	var archived_wall: Array = frozen.blueprint.parts.filter(func(row): return row.id == "castle_right_wall_wall")
	_check("curtain_record_exact_diagnostic03", archived_wall.size() == 1 and var_to_bytes(wall) == var_to_bytes(archived_wall[0]))
	_courtyard_base(source, compound, width, depth, span, variation)
	var compose_depth := float(grammar.get("courtyardDepth", 84.0))
	var keep_front := compose_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14)) - float(grammar.get("keepDepth", 28.0)) * 0.5
	var front := -compose_depth * 0.5
	var layout: Dictionary = Urban.sample_urban_layout(SEED, grammar, front, keep_front, 0.62)
	_standalone_records(frozen, grammar, front, keep_front, variation, layout, raw, context)
	source.recipe["urbanPoc"] = layout
	_check("manifest_reset", Urban.reset_street_house_structural_manifest(source).ready)
	var street: Dictionary = Urban.add_street_sequence(source, front, keep_front, 0.62, variation, layout)
	_check("actual_street_producer", street.get("ready", false))
	if not street.get("ready", false):
		evidence.streetFailure = street
		return
	Urban.add_civic_landmark(source, Vector3(-14.0, 0.0, keep_front - 4.0), 2.62, variation)
	Urban.add_terraced_edge(source, Vector3(17.5, 0.0, keep_front - 9.0), 0.62, variation)
	var original := var_to_bytes(source.snapshot())
	var preview: Dictionary = Urban._civic_infill_environment(source, grammar, front, keep_front, 0.62, variation, layout)
	_check("actual_environment_ready", preview.get("ready", false))
	_check("environment_preview_preserves_source", original == var_to_bytes(source.snapshot()))
	if not preview.get("ready", false):
		evidence.previewFailure = preview
		return
	var environment = preview.blueprint
	var environment_before := var_to_bytes(environment.snapshot())
	var result: Dictionary = Urban.add_civic_quarter(source, front, keep_front, 0.62, variation, layout, environment, _budget)
	_check("actual_infill_ready", result.get("ready", false))
	_check("infill_environment_immutable", environment_before == var_to_bytes(environment.snapshot()))
	evidence.rawContext = raw
	evidence.builderContext = context
	evidence.actualResult = result
	if not result.get("ready", false):
		evidence.placementFailureGeometry = _failure_geometry(environment, result, grammar, front, keep_front, variation, layout)
		return
	var infill: Dictionary = result.infill
	_check("two_actual_houses", infill.specs.size() == 2 and infill.receipts.size() == 2)
	_roof_shape_controls(source, infill, frozen.blueprint, variation)
	var paving: AABB = source.transformed_part_bounds(_part(source, "urban_civic_quarter_paving"))
	var domain := Rect2(Vector2(paving.position.x, paving.position.z), Vector2(paving.size.x, paving.size.z))
	var curtain: AABB = source.transformed_part_bounds(_part(source, "castle_right_wall_wall"))
	var placed: Array[AABB] = []
	var blockers: Array = _independent_obstacles(environment)
	for spec: Dictionary in infill.specs:
		var actual: Dictionary = _house_bounds(source, spec.id)
		var box: AABB = actual.bounds
		_check(spec.id + "_all_parts_and_accesses", actual.partCount > 0 and actual.accessCount > 0 and actual.hasRoof and actual.hasFoundation)
		_check(spec.id + "_inside_paving", _inside(box, domain))
		_check(spec.id + "_inside_finite_curtain", _upper(box, 0) <= float(curtain.position.x) - Infill.CLEARANCE and float(box.position.z) >= float(curtain.position.z) + Infill.CLEARANCE and _upper(box, 2) <= _upper(curtain, 2) - Infill.CLEARANCE)
		var conflicts: Array = []
		for obstacle: Dictionary in blockers:
			if _conflict(box, obstacle.bounds, Infill.CLEARANCE): conflicts.append(obstacle.id)
		_check(spec.id + "_all_environment_parts_and_access_clear", conflicts.is_empty())
		evidence[spec.id] = {"geometry": actual, "conflicts": conflicts}
		for prior: AABB in placed: _check(spec.id + "_sibling_clear", not _conflict(box, prior, Infill.CLEARANCE))
		placed.append(box)
	var producer := func(target, spec: Dictionary): Urban._add_civic_house(target, spec, 0.62, variation)
	_prepare_guards(environment, infill.specs, producer, domain)
	callback_count = 0
	reject_at = -1
	var repeat: Dictionary = Infill.prepare(environment, infill.specs, producer, domain, 0.62, _controlled)
	var full_count := callback_count
	_check("feasible_resolved_specs_unchanged", repeat.get("ready", false) and repeat.receipts.all(func(row): return row.translation == Vector3.ZERO))
	_check("feasible_specs_typed_exact", repeat.get("ready", false) and var_to_bytes(repeat.specs) == var_to_bytes(infill.specs))
	var missing = Copy.copy_blueprint(environment.snapshot())
	missing.parts = missing.parts.filter(func(part): return part.semantic != "castle_curtain_wall")
	var no_wall: Dictionary = Infill.prepare(missing, infill.specs, producer, domain, 0.62, _budget)
	_check("missing_wall_explicit", not no_wall.get("ready", false) and no_wall.get("reason") == "missing_or_empty_civic_enclosure")
	_check("missing_wall_no_partial", not no_wall.has("specs") and not no_wall.has("receipts"))
	for kind: String in ["noncolliding_prop", "room_access"]:
		var blocked = Copy.copy_blueprint(environment.snapshot())
		var obstruction := AABB(Vector3(domain.position.x - 1.0, 0.0, domain.position.y - 1.0), Vector3(domain.size.x + 2.0, 30.0, domain.size.y + 2.0))
		if kind == "noncolliding_prop":
			var prop = blocked.add_part({"id": "synthetic-domain-filling-prop", "kind": "decor", "material": "timber_board", "position": obstruction.get_center(), "size": obstruction.size, "collision": false, "semantic": "synthetic_occupied_prop"})
			_check("noncolliding_prop_not_underlay", not Infill.compatible_underlay(prop, 0.62))
		else:
			var access := {"id": "synthetic-required-access", "position": Vector3(obstruction.get_center().x, obstruction.position.y, obstruction.get_center().z), "size": Vector3.ONE, "furnishingSize": obstruction.size}
			_check("access_bottom_y_and_furnishing_size_authority", Interior.access_reservation(access) == obstruction)
			blocked.rooms.append({"id": "synthetic-domain-access", "role": "courtyard", "accesses": [access]})
		var frozen_blocked := var_to_bytes(blocked.snapshot())
		var denied: Dictionary = Infill.prepare(blocked, infill.specs, producer, domain, 0.62, _budget)
		_check(kind + "_no_fit", not denied.get("ready", false) and _reason(denied, "no_clear_endpoint_column"))
		_check(kind + "_no_partial", not denied.has("specs") and not denied.has("receipts"))
		_check(kind + "_immutable", frozen_blocked == var_to_bytes(blocked.snapshot()))
		evidence[kind] = denied
	for occurrence: int in [1, 2, full_count]:
		callback_count = 0
		reject_at = occurrence
		rejected = false
		after_false = 0
		var cancelled: Dictionary = Infill.prepare(environment, infill.specs, producer, domain, 0.62, _controlled)
		var label := "cancel_%d" % occurrence
		_check(label + "_reached", rejected and callback_count == occurrence)
		_check(label + "_explicit", not cancelled.get("ready", false) and _reason(cancelled, "cancelled"))
		_check(label + "_no_partial", not cancelled.has("specs") and not cancelled.has("receipts"))
		_check(label + "_terminal", after_false == 0)
		evidence[label] = cancelled
	_check("controls_preserve_environment", environment_before == var_to_bytes(environment.snapshot()))
	evidence.fullContinuationCount = full_count
	evidence.environmentPartCount = environment.parts.size()
	_terminal(source, infill, grammar, front, keep_front, variation, layout)

func _courtyard_base(source, compound: Dictionary, width: float, depth: float, tower_span: float, variation: float) -> void:
	var grammar: Dictionary = compound.castleGrammar
	var keep_recipe: Dictionary = Castle.member_recipe(compound.members, "keep")
	# Exact build_from_compound keep inputs. Construct privately ONLY to obtain
	# the actual forecourt exclusion; keep geometry remains omitted from subset.
	var keep_width := minf(float(grammar.get("keepWidth", float(keep_recipe.get("width", 26.0)) * 0.52)), width - tower_span * 2.50)
	var keep_depth := minf(float(grammar.get("keepDepth", float(keep_recipe.get("depth", 24.0)) * 0.48)), depth - tower_span * 2.50)
	var keep_height := float(grammar.get("keepHeight", float(keep_recipe.get("floorHeight", 3.7)) * float(maxi(3, int(keep_recipe.get("floorCount", 4))))))
	var reference_height := clampf(float(keep_recipe.get("floorHeight", 3.70)), 3.20, 4.20)
	var storeys := clampi(roundi(keep_height / reference_height), 3, 24)
	var floor_height := keep_height / float(storeys)
	var foundation_height := 0.62
	var keep_foundation := foundation_height + Castle.citadel_keep_terrace_elevation(grammar)
	var keep_center := Vector3(0, 0, depth * float(grammar.get("keepOffset", {}).get("z", 0.14)))
	var material := String(grammar.get("citadelMasonry", {}).get("fortification", "fired_brick"))
	var keep = Blueprint.new("civic-base-exclusion-producer", SEED, "masonry")
	Castle.add_keep(keep, keep_center, keep_width, keep_depth, keep_height, storeys, floor_height, keep_foundation, variation, material, grammar.get("palaceGrammar", {}))
	var reserved: Array[Dictionary] = Castle.keep_entry_transition_exclusions(keep)
	var residences: Array[Dictionary] = []
	var before: int = source.parts.size()
	Castle.add_courtyard_foundation_and_paving(source, residences, width, depth, foundation_height, variation, reserved)
	var produced: Array = source.parts.slice(before)
	var foundations: Array = produced.filter(func(part): return part.semantic == "castle_courtyard_foundation")
	var pavings: Array = produced.filter(func(part): return part.semantic == "castle_courtyard_paving")
	_check("actual_segmented_base_both_families", not foundations.is_empty() and not pavings.is_empty())
	_check("actual_keep_entry_exclusions_present", not reserved.is_empty())
	_check("actual_segments_compatible", produced.all(func(part): return Infill.compatible_underlay(part, foundation_height)))
	var before_records := var_to_bytes(produced.map(func(part): return part.snapshot()))
	for original in [foundations[0], pavings[0]]:
		for mutation: String in ["forged_prefix", "missing_egress", "wrong_height"]:
			var single = Copy.copy_blueprint({"id": "synthetic-underlay-guard", "seed": SEED, "style": "masonry", "recipe": {}, "rooms": [], "parts": [original.snapshot()]})
			var part = single.parts[0]
			match mutation:
				"forged_prefix": part.id += "_forged"
				"missing_egress": part.recipe.erase("egressCarved")
				"wrong_height": part.size.y += 0.1
			var frozen := _guard_snapshot(single)
			var label := "segment_" + String(original.semantic) + "_" + mutation
			_check(label + "_not_underlay", not Infill.compatible_underlay(part, foundation_height))
			var obstacles: Dictionary = Infill._obstacles(single, foundation_height)
			_check(label + "_retained_obstacle", obstacles.get("ready", false) and obstacles.boxes.size() == 1 and obstacles.boxes[0] == single.transformed_part_bounds(part))
			_check(label + "_immutable", frozen == _guard_snapshot(single))
	_check("actual_base_records_unchanged_by_guards", before_records == var_to_bytes(produced.map(func(part): return part.snapshot())))
	var carved = Blueprint.new("synthetic-carve-producer-control", SEED, "masonry")
	var hole := Rect2(-1, -2, 2, 4)
	var synthetic_exclusions: Array[Dictionary] = [{"kind": "synthetic_test_corridor", "rect": hole}]
	var exclusions_before := var_to_bytes(synthetic_exclusions)
	Castle.add_courtyard_foundation_and_paving(carved, residences, 10.0, 12.0, foundation_height, variation, synthetic_exclusions)
	var areas := {"castle_courtyard_foundation": 0.0, "castle_courtyard_paving": 0.0}
	var clear := true
	var canonical := true
	var counts := {"castle_courtyard_foundation": 0, "castle_courtyard_paving": 0}
	for part in carved.parts:
		var bounds: AABB = carved.transformed_part_bounds(part)
		var rect := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
		clear = clear and not rect.intersects(hole)
		areas[part.semantic] += float(rect.size.x) * float(rect.size.y)
		counts[part.semantic] += 1
		canonical = canonical and Infill.compatible_underlay(part, foundation_height)
	_check("synthetic_carve_real_producer_four_segments_each", counts.castle_courtyard_foundation == 4 and counts.castle_courtyard_paving == 4)
	_check("synthetic_carve_hole_preserved", clear)
	_check("synthetic_carve_root_area", absf(areas.castle_courtyard_foundation - (10.0 * 12.0 - 8.0)) < 0.0001)
	_check("synthetic_carve_paving_area", absf(areas.castle_courtyard_paving - ((10.0 - 0.82) * (12.0 - 0.82) - 8.0)) < 0.0001)
	_check("synthetic_carve_all_segments_compatible", canonical)
	_check("synthetic_carve_inputs_unchanged", exclusions_before == var_to_bytes(synthetic_exclusions))
	evidence.segmentedCourtyard = {"producer": "CastleCompoundBlueprintBuilder.add_courtyard_foundation_and_paving",
		"courtyardWidth": width, "courtyardDepth": depth, "foundationHeight": foundation_height,
		"foundationCount": foundations.size(), "pavingCount": pavings.size(), "keepEntryExclusions": reserved,
		"records": produced.map(func(part): return part.snapshot()),
		"qualification": "Actual producer with sampled compound dimensions and actual keep-entry forecourt exclusions. Residence list deliberately empty: no solved courtyard residences/egress cuts, terraces, district streets, towers or keep collision obstacles. NOT exact full-castle segment inventory or full-source acceptance."}

func _standalone_records(frozen: Dictionary, grammar: Dictionary, front: float, keep_front: float, variation: float, layout: Dictionary, raw: Dictionary, context: Dictionary) -> void:
	_check("standalone_archive_context_exact", var_to_bytes(raw) == var_to_bytes(frozen.rawContext) and var_to_bytes(context) == var_to_bytes(frozen.builderContext))
	if not checks.standalone_archive_context_exact: return
	# Frozen curtain inputs remain present as in diagnostic03; regenerate ALL
	# civic producer records with default optional arguments, not six samples.
	var initial := {"id": frozen.blueprint.id, "seed": SEED, "style": frozen.blueprint.style,
		"recipe": {"castleGrammar": grammar.duplicate(true), "foundationHeight": 0.62, "urbanPoc": layout.duplicate(true)},
		"rooms": [], "parts": frozen.blueprint.parts.filter(func(row): return String(row.id).begins_with("castle_right_wall"))}
	var standalone = Copy.copy_blueprint(initial)
	_check("standalone_manifest_ready", Urban.reset_street_house_structural_manifest(standalone).ready)
	var receipt: Dictionary = Urban.add_civic_quarter(standalone, front, keep_front, 0.62, variation, layout)
	_check("standalone_default_ready", receipt.get("ready", false))
	var expected: Array = frozen.blueprint.parts.filter(func(row): return not String(row.id).begins_with("castle_right_wall"))
	var actual: Array = standalone.part_snapshots().filter(func(row): return not String(row.id).begins_with("castle_right_wall"))
	var mismatches: Array = []
	for i: int in range(maxi(expected.size(), actual.size())):
		if i >= expected.size() or i >= actual.size():
			mismatches.append({"index": i, "reason": "record_count"})
		elif var_to_bytes(expected[i]) != var_to_bytes(actual[i]):
			var fields: Array = []
			for key: Variant in expected[i]:
				if not actual[i].has(key) or var_to_bytes(expected[i][key]) != var_to_bytes(actual[i][key]): fields.append(key)
			mismatches.append({"index": i, "expectedId": expected[i].id, "actualId": actual[i].id, "fields": fields})
	# The corrected street span moves the commons; its paving already derives
	# from that actual footprint. Keep the archive intact and authorize only
	# the independently rebuilt paving position/depth, not other design changes.
	var expected_current: Array=expected.duplicate(true)
	var commons = Copy.copy_blueprint(initial)
	var commons_start: int=commons.parts.size()
	var commons_receipt: Dictionary=Urban.add_civic_commons(commons,front,keep_front,0.62,variation,layout)
	var commons_parts: Array=commons.parts.slice(commons_start)
	var measured := AABB()
	for i in range(commons_parts.size()):
		var bounds: AABB=commons.transformed_part_bounds(commons_parts[i])
		measured=bounds if i==0 else measured.merge(bounds)
	var north := keep_front+8.0
	var south := minf(keep_front-24.0,measured.position.z-0.25)
	var expected_pavings := 0
	for record: Dictionary in expected_current:
		if record.id!="urban_civic_quarter_paving": continue
		expected_pavings+=1
		record.position=Vector3(43.0,0.62+0.18,(north+south)*0.5)
		record.size=Vector3(48.0,0.08,north-south)
	_check("standalone_paving_derived_from_actual_commons",commons_receipt.ready and commons_parts.size()==14 and expected_pavings==1)
	_check("standalone_civic_exact_except_recipe_derived_paving",var_to_bytes(expected_current)==var_to_bytes(actual))
	_check("standalone_all_rooms_typed_exact", var_to_bytes(frozen.blueprint.rooms) == var_to_bytes(standalone.rooms))
	evidence.standaloneCompatibility = {"expectedCount": expected.size(), "actualCount": actual.size(), "mismatches": mismatches, "archiveSha256": BASELINE_SHA,
		"archiveWholeRecordEqualityObservation":var_to_bytes(expected)==var_to_bytes(actual),"measuredCommonsBounds":measured,"derivedPavingNorth":north,"derivedPavingSouth":south}

func _guard_snapshot(source, furniture: Variant = null) -> PackedByteArray:
	var parts: Array = source.parts.map(func(part): return null if part == null else part.snapshot())
	var identities: Array = source.parts.map(func(part): return 0 if part == null else part.get_instance_id())
	var furnishing_values: Variant = furniture
	if furniture is FurnishingPlan:
		furnishing_values = [furniture.id, furniture.seed, furniture.source_blueprint_id, furniture.egress_diagnostics,
			furniture.protected_access_reservations, furniture.parts.map(func(part): return null if part == null else part.snapshot()),
			furniture.parts.map(func(part): return 0 if part == null else part.get_instance_id())]
	return var_to_bytes([source.id, source.seed, source.style, source.recipe, source.rooms, parts, identities, furnishing_values])

func _guard_receipt(label: String, result: Dictionary, expected_reason: String) -> void:
	_check(label + "_structured_failure", result.get("ready") == false and result.get("reason") == expected_reason)
	_check(label + "_no_partial", not result.has("specs") and not result.has("receipts") and not result.has("houses"))
	evidence[label] = result

func _prepare_guards(environment, specs: Array, producer: Callable, domain: Rect2) -> void:
	for rejected_call in [1,2]:
		var calls := {"count":0}
		var rejecting_producer := func(target, spec: Dictionary) -> bool:
			calls.count+=1
			producer.call(target,spec)
			return calls.count!=rejected_call
		var before := _guard_snapshot(environment)
		var inputs_before := var_to_bytes(specs)
		var denied := Infill.prepare(environment,specs,rejecting_producer,domain,0.62,_budget)
		var label := "producer_failure_%d" % rejected_call
		_check(label+"_propagates",not denied.get("ready",true) and denied.get("reason")=="civic_house_producer_failed" and denied.get("phase")==("preview" if rejected_call==1 else "rebuild"))
		_check(label+"_no_further_calls",calls.count==rejected_call)
		_check(label+"_source_and_specs_immutable",before==_guard_snapshot(environment) and inputs_before==var_to_bytes(specs))
	for mutation: String in ["empty_specs", "duplicate_specs", "missing_roof_rise", "nan_roof_rise", "infinite_roof_rise", "low_roof_rise", "high_roof_rise", "wrong_roof_rise_type", "null_part", "malformed_foreign_room"]:
		var changed = Copy.copy_blueprint(environment.snapshot())
		var inputs: Array = specs.duplicate(true)
		match mutation:
			"empty_specs": inputs.clear()
			"duplicate_specs": inputs.append(inputs[0].duplicate(true))
			"missing_roof_rise": inputs[0].erase("roofRise")
			"nan_roof_rise": inputs[0].roofRise = NAN
			"infinite_roof_rise": inputs[0].roofRise = INF
			"low_roof_rise": inputs[0].roofRise = 3.199
			"high_roof_rise": inputs[0].roofRise = 4.8
			"wrong_roof_rise_type": inputs[0].roofRise = "3.5"
			"null_part": changed.parts.append(null)
			"malformed_foreign_room": changed.rooms.append({"id": "synthetic-malformed-foreign-room", "role": "storage", "bounds": "not_an_aabb", "accesses": []})
		var before := _guard_snapshot(changed)
		var input_before := var_to_bytes(inputs)
		var denied: Dictionary = Infill.prepare(changed, inputs, producer, domain, 0.62, _budget)
		var label := "guard_prepare_" + mutation
		_guard_receipt(label, denied, "invalid_civic_infill_input")
		_check(label + "_immutable", before == _guard_snapshot(changed) and input_before == var_to_bytes(inputs))

func _terminal_guards(source, plan: Dictionary, furniture) -> void:
	var reasons := {"wrong_furnishing_container": "invalid_composed_civic_input", "null_furnishing": "invalid_civic_furnishing",
		"null_part": "invalid_composed_civic_input", "malformed_foreign_room": "invalid_composed_civic_input",
		"missing_paving": "invalid_composed_civic_paving", "moved_paving": "civic_paving_changed",
		"malformed_urban": "invalid_civic_tree_collection", "malformed_root": "invalid_civic_root"}
	for mutation: String in reasons:
		var changed = Copy.copy_blueprint(source.snapshot())
		var changed_furniture: Variant = _copy_furniture(furniture)
		match mutation:
			"wrong_furnishing_container": changed_furniture = {"parts": [], "protected_access_reservations": []}
			"null_furnishing": changed_furniture.parts.append(null)
			"null_part": changed.parts.append(null)
			"malformed_foreign_room": changed.rooms.append({"id": "synthetic-terminal-malformed-room", "role": "storage", "bounds": AABB(Vector3.ZERO, Vector3(-1, 1, 1)), "accesses": []})
			"missing_paving": changed.parts = changed.parts.filter(func(part): return part.id != "urban_civic_quarter_paving")
			"moved_paving": _part(changed, "urban_civic_quarter_paving").position.x += 0.125
			"malformed_urban": changed.recipe.urbanPoc = []
			"malformed_root": changed.recipe.urbanPoc.treePlacements = [{"id": "synthetic-malformed-root-tree", "position": Vector3(200, 0, 200), "canopyRadius": 1.0, "rootButtressFootprints": [{"start": "not_a_vector", "end": Vector3.ZERO, "radiusStart": 0.5, "radiusEnd": 0.5}]}]
		var before := _guard_snapshot(changed, changed_furniture)
		var plan_before := var_to_bytes(plan)
		var denied: Dictionary = Infill.validate_composed(changed, plan, changed_furniture, 0.62, _budget)
		var label := "guard_terminal_" + mutation
		_guard_receipt(label, denied, reasons[mutation])
		_check(label + "_immutable", before == _guard_snapshot(changed, changed_furniture) and plan_before == var_to_bytes(plan))

func _roof_shape_controls(source, infill: Dictionary, frozen_blueprint: Dictionary, variation: float) -> void:
	var rows: Array = []
	for spec: Dictionary in infill.specs:
		var receipts: Array = infill.receipts.filter(func(row): return row.id == spec.id)
		_check(String(spec.id) + "_design_receipt_unique", receipts.size() == 1)
		if receipts.size() != 1: continue
		var original_spec: Dictionary = spec.duplicate(true)
		original_spec.center = receipts[0].originalCenter
		# Exercise omitted optional argument semantics at the ORIGINAL pose.
		# The frozen 03 records are an independent pre-change shape oracle.
		original_spec.erase("roofRise")
		var original = Blueprint.new("civic-roof-original-control", SEED, "masonry")
		Urban._add_civic_house(original, original_spec, 0.62, variation)
		var sampled: float = 3.2 + fmod(absf(float(original_spec.center.x + original_spec.center.z)), 1.6)
		_check(String(spec.id) + "_roof_rise_original_formula", spec.has("roofRise") and spec.roofRise == sampled)
		for suffix: String in ["_roof_left", "_roof_right", "_chimney"]:
			var id: String = spec.id + suffix
			var old_part = _part(original, id)
			var new_part = _part(source, id)
			var archived: Array = frozen_blueprint.parts.filter(func(row): return row.id == id)
			_check(id + "_shape_members_present", old_part != null and new_part != null and archived.size() == 1)
			if old_part == null or new_part == null or archived.size() != 1: continue
			var old_shape: Array = [old_part.kind, old_part.material_id, old_part.size, old_part.rotation, old_part.position.y, old_part.semantic]
			var new_shape: Array = [new_part.kind, new_part.material_id, new_part.size, new_part.rotation, new_part.position.y, new_part.semantic]
			var archived_shape: Array = [archived[0].kind, archived[0].material, archived[0].size, archived[0].rotation, archived[0].position.y, archived[0].semantic]
			_check(id + "_legacy_original_shape_exact", var_to_bytes(old_shape) == var_to_bytes(archived_shape))
			_check(id + "_resolved_dimensions_rotation_height_exact", var_to_bytes(new_shape) == var_to_bytes(old_shape))
			# Exact dimensions/angles retain roof slope and chimney proportions;
			# absolute XZ translation rounding is independently checked by infill.
			rows.append({"id": id, "originalSize": old_part.size, "resolvedSize": new_part.size,
				"originalRotation": old_part.rotation, "resolvedRotation": new_part.rotation,
				"originalY": old_part.position.y, "resolvedY": new_part.position.y})
	evidence.roofShapeControls = rows

func _failure_geometry(environment, failure: Dictionary, grammar: Dictionary, front: float, keep_front: float, variation: float, layout: Dictionary) -> Dictionary:
	var original = Blueprint.new("civic-original-producer-subset", SEED, "masonry")
	original.set_recipe({"castleGrammar": grammar.duplicate(true), "foundationHeight": 0.62, "urbanPoc": layout.duplicate(true)})
	# Null environment deliberately invokes the unchanged standalone producer,
	# not a second placement attempt. No hand-authored house dimensions here.
	var produced: Dictionary = Urban.add_civic_quarter(original, front, keep_front, 0.62, variation, layout)
	if not produced.get("ready", false): return {"ready": false, "reason": "original_producer_failed", "detail": produced}
	var prefix: String = failure.get("house", "urban_civic_house_east")
	var geometry: Dictionary = _house_bounds(original, prefix)
	var moving: AABB = geometry.bounds
	var paving_box: AABB = original.transformed_part_bounds(_part(original, "urban_civic_quarter_paving"))
	var paving := Rect2(Vector2(paving_box.position.x, paving_box.position.z), Vector2(paving_box.size.x, paving_box.size.z))
	var domain: Dictionary = Infill._domain(environment, paving)
	if not domain.get("ready", false): return {"ready": false, "reason": "diagnostic_domain_failed", "detail": domain}
	var allowed: Rect2 = domain.bounds
	var walls: Array = []
	var expected_low := paving.position
	var expected_high := paving.end
	for part in environment.parts:
		if part.semantic != "castle_curtain_wall": continue
		var box: AABB = environment.transformed_part_bounds(part)
		walls.append({"part": part.snapshot(), "bounds": box})
		if box.size.z > box.size.x and part.position.x > 0.0:
			expected_high.x = minf(expected_high.x, box.position.x - Infill.CLEARANCE)
			expected_low.y = maxf(expected_low.y, box.position.z + Infill.CLEARANCE)
			expected_high.y = minf(expected_high.y, box.end.z - Infill.CLEARANCE)
		elif box.size.x > box.size.z:
			if part.position.z < 0.0: expected_low.y = maxf(expected_low.y, box.end.z + Infill.CLEARANCE)
			else: expected_high.y = minf(expected_high.y, box.position.z - Infill.CLEARANCE)
	_check("failure_domain_matches_actual_walls", allowed == Rect2(expected_low, expected_high - expected_low) and not walls.is_empty())
	var x_min := float(allowed.position.x)
	var x_max := minf(float(allowed.end.x), x_min + float(allowed.size.x)) - float(moving.size.x)
	var ideal_x := clampf(float(moving.position.x), x_min, x_max)
	var translation_x := float(Vector3(ideal_x - float(moving.position.x), 0, 0).x)
	var fixed := AABB(moving.position + Vector3(translation_x, 0, 0), moving.size)
	var steps := 0
	while steps < Boundary.MAX_ENDPOINT_STEPS and (float(fixed.position.x) < x_min or _upper(fixed, 0) > x_max + float(moving.size.x)):
		var direction := 1.0 if float(fixed.position.x) < x_min else -1.0
		translation_x = Boundary._next_translation(float(moving.position.x), float(fixed.position.x), translation_x, direction)
		fixed = AABB(moving.position + Vector3(translation_x, 0, 0), moving.size)
		steps += 1
	var intervals: Array[Dictionary] = []
	var named: Array = _independent_obstacles(environment)
	var authoritative: Dictionary = Infill._obstacles(environment, 0.62)
	var independent_boxes: Array = named.map(func(row): return row.bounds)
	_check("failure_named_obstacles_exact_membership_order", authoritative.get("ready", false) and var_to_bytes(authoritative.boxes) == var_to_bytes(independent_boxes))
	for obstacle: Dictionary in named:
		var box: AABB = obstacle.bounds
		var x_overlap: bool = float(fixed.position.x) < _upper(box, 0) + Infill.CLEARANCE and _upper(fixed, 0) > float(box.position.x) - Infill.CLEARANCE
		var y_overlap: bool = float(fixed.position.y) < _upper(box, 1) and _upper(fixed, 1) > float(box.position.y)
		if not x_overlap or not y_overlap: continue
		intervals.append({"id": obstacle.id, "bounds": box, "origin": obstacle.get("origin", ""), "semantic": obstacle.get("semantic", ""), "collision": obstacle.get("collision"),
			"xOverlapWithClearance": x_overlap, "yOverlap": y_overlap,
			"low": float(box.position.z) - Infill.CLEARANCE, "high": _upper(box, 2) + Infill.CLEARANCE})
	intervals.sort_custom(func(a: Dictionary, b: Dictionary): return a.low < b.low if a.low != b.low else a.high < b.high)
	var merged: Array = []
	for interval: Dictionary in intervals:
		if merged.is_empty() or interval.low > merged[-1].high:
			merged.append({"low": interval.low, "high": interval.high, "blockerIds": [interval.id]})
		else:
			merged[-1].high = maxf(merged[-1].high, interval.high)
			merged[-1].blockerIds.append(interval.id)
	var windows: Array = []
	var cursor := float(allowed.position.y)
	var end_z := minf(float(allowed.end.y), float(allowed.position.y) + float(allowed.size.y))
	for interval: Dictionary in merged:
		if interval.high <= cursor: continue
		if interval.low >= end_z: break
		if interval.low > cursor: windows.append({"low": cursor, "high": minf(interval.low, end_z), "length": minf(interval.low, end_z) - cursor})
		cursor = maxf(cursor, interval.high)
	if cursor < end_z: windows.append({"low": cursor, "high": end_z, "length": end_z - cursor})
	var path := output_path.get_base_dir().path_join("placement-environment.bin")
	var file := FileAccess.open(path, FileAccess.WRITE)
	var saved := false
	if file != null:
		file.store_var({"environment": environment.snapshot(), "originalCivicProducer": original.snapshot(), "geometry": geometry, "paving": paving, "domain": domain, "fixedEnvelope": fixed, "namedObstacles": named}, false)
		file.flush()
		saved = file.get_error() == OK
		file.close()
	_check("failure_typed_environment_saved", saved)
	return {"ready": saved, "house": prefix, "originalHouseGeometry": geometry, "paving": paving, "allowed": allowed, "walls": walls,
		"clampX": {"minimum": x_min, "maximum": x_max, "ideal": ideal_x, "translation": translation_x, "endpointSteps": steps, "fixedEnvelope": fixed},
		"namedBlockers": intervals, "mergedZIntervals": merged, "freeZWindows": windows, "requiredHouseDepth": moving.size.z,
		"anyGeometricWindowLongEnough": windows.any(func(row): return row.length >= float(moving.size.z)),
		"typedEnvironment": path, "typedEnvironmentSha256": FileAccess.get_sha256(path) if saved else "",
		"scope": "Independent named obstacle/interval inventory at the solver's fixed X; no search relaxation or new accepted placement. X endpoint adjustment delegates only the frozen pure helper's stored-float step."}

func _terminal(source, plan: Dictionary, grammar: Dictionary, front: float, keep_front: float, variation: float, layout: Dictionary) -> void:
	# Add independent producers in their ordinary post-civic order. This is a
	# separate copy, not reuse of the planning preview or a second live authority.
	var prepared: Dictionary = Urban._civic_infill_environment(source, grammar, front, keep_front, 0.62, variation, layout, _budget)
	_check("terminal_actual_independent_producers", prepared.get("ready", false))
	if not prepared.get("ready", false):
		evidence.terminalProducerFailure = prepared
		return
	var terminal = prepared.blueprint
	var sites: Array = Urban.select_open_paving_tree_sites(terminal, SEED, _budget)
	if not sites.is_empty():
		var tree_records: Array = Urban.build_tree_placement_records(sites, SEED, _budget)
		_check("terminal_selected_tree_records_complete", tree_records.size() == sites.size())
		terminal.recipe.urbanPoc["treePlacements"] = tree_records
		terminal.recipe["landscapeTrees"] = tree_records
	var roofs: Dictionary = Urban.add_roof_frames(terminal)
	_check("terminal_real_roof_frames", roofs.get("ready", false))
	evidence.roofFrameResult = roofs
	if not roofs.get("ready", false): return
	var prepared_furniture: Dictionary = Urban.prepare_furnishings(terminal, SEED)
	_check("terminal_real_furnishings", prepared_furniture.get("ready", false))
	if not prepared_furniture.get("ready", false):
		evidence.furnishingFailure = prepared_furniture
		return
	var furniture = prepared_furniture.furnishingPlan
	_check("terminal_nonempty_real_furnishings", not furniture.parts.is_empty())
	var source_before := var_to_bytes(terminal.snapshot())
	var furniture_before := var_to_bytes([furniture.snapshot(), furniture.protected_access_reservations])
	var plan_before := var_to_bytes(plan)
	callback_count = 0
	reject_at = -1
	rejected = false
	after_false = 0
	var result: Dictionary = Infill.validate_composed(terminal, plan, furniture, 0.62, _controlled)
	var terminal_count := callback_count
	_check("terminal_composed_subset_ready", result.get("ready", false))
	_check("terminal_validation_immutable", source_before == var_to_bytes(terminal.snapshot()) and furniture_before == var_to_bytes([furniture.snapshot(), furniture.protected_access_reservations]) and plan_before == var_to_bytes(plan))
	evidence.terminalResult = result
	evidence.terminalSourcePartCount = terminal.parts.size()
	evidence.terminalFurnitureCount = furniture.parts.size()
	evidence.terminalTreeCount = terminal.recipe.get("urbanPoc", {}).get("treePlacements", []).size()
	# Preserve a failed positive intact. It cannot authorize negative controls
	# whose rejection might merely repeat the pre-existing positive failure.
	if not result.get("ready", false): return
	_terminal_guards(terminal, plan, furniture)
	_check("terminal_both_houses_checked", result.houses.size() == 2)
	for row: Dictionary in result.houses:
		_check(String(row.house) + "_terminal_frame_members_retained", row.partCount > int(evidence[String(row.house)].geometry.partCount))
	var target: AABB = result.houses[0].bounds
	var point := target.get_center()
	for mutation: String in ["foreign_prop", "foreign_furniture", "foreign_access", "protected_access", "tree_canopy", "tree_root"]:
		var changed = Copy.copy_blueprint(terminal.snapshot())
		var changed_furniture = _copy_furniture(furniture)
		match mutation:
			"foreign_prop":
				changed.add_part({"id": "synthetic-late-foreign-prop", "kind": "decor", "position": point, "size": Vector3.ONE, "collision": false, "semantic": "synthetic_occupied_prop"})
			"foreign_furniture":
				# Direct append is deliberate fault injection, not a producer or
				# FurnishingPlan.add_part access-filter acceptance claim.
				changed_furniture.parts.append(FurniturePart.new({"id": "synthetic-late-foreign-furniture", "roomId": "synthetic-other-owner", "archetype": "crate", "position": point, "occupiedSize": Vector3.ONE, "collision": false}))
			"foreign_access":
				changed.rooms.append({"id": "synthetic-late-access-room", "role": "courtyard", "accesses": [{"id": "synthetic-late-access", "position": point, "size": Vector3.ONE, "furnishingSize": Vector3(2, 2, 2)}]})
			"protected_access":
				changed_furniture.protected_access_reservations.append(AABB(point, Vector3.ONE))
			"tree_canopy", "tree_root":
				var tree := {"id": "synthetic-late-tree", "position": point, "canopyRadius": 1.0, "rootButtressFootprints": []}
				if mutation == "tree_root":
					tree.position = point + Vector3(100, 0, 100)
					tree.rootButtressFootprints = [{"start": point, "end": point + Vector3.RIGHT, "radiusStart": 0.5, "radiusEnd": 0.25}]
				var trees: Array = changed.recipe.get("urbanPoc", {}).get("treePlacements", []).duplicate(true)
				trees.append(tree)
				changed.recipe.urbanPoc["treePlacements"] = trees
				changed.recipe["landscapeTrees"] = trees
		var changed_before := var_to_bytes([changed.snapshot(), changed_furniture.snapshot(), changed_furniture.protected_access_reservations])
		var denied: Dictionary = Infill.validate_composed(changed, plan, changed_furniture, 0.62, _budget)
		var reason := "composed_civic_tree_overlap" if mutation.begins_with("tree_") else "composed_civic_clearance_failed"
		_check("late_" + mutation + "_rejected", not denied.get("ready", false) and denied.get("reason") == reason)
		_check("late_" + mutation + "_no_partial", not denied.has("houses"))
		_check("late_" + mutation + "_immutable", changed_before == var_to_bytes([changed.snapshot(), changed_furniture.snapshot(), changed_furniture.protected_access_reservations]))
		evidence["late_" + mutation] = denied
	for occurrence: int in [1, 2, terminal_count]:
		callback_count = 0
		reject_at = occurrence
		rejected = false
		after_false = 0
		var cancelled: Dictionary = Infill.validate_composed(terminal, plan, furniture, 0.62, _controlled)
		_check("terminal_cancel_%d" % occurrence, rejected and callback_count == occurrence and after_false == 0 and cancelled.get("reason") == "cancelled" and not cancelled.get("ready", false) and not cancelled.has("houses"))
	_check("terminal_baseline_preserved_after_negatives", source_before == var_to_bytes(terminal.snapshot()) and furniture_before == var_to_bytes([furniture.snapshot(), furniture.protected_access_reservations]) and plan_before == var_to_bytes(plan))

func _copy_furniture(source):
	var copy = FurniturePlan.new(source.id, source.seed, source.source_blueprint_id)
	copy.egress_diagnostics = source.egress_diagnostics.duplicate(true)
	copy.protected_access_reservations = source.protected_access_reservations.duplicate()
	for part in source.parts: copy.parts.append(FurniturePart.new(part.snapshot()))
	return copy

func _part(source, id: String):
	for part in source.parts:
		if part.id == id: return part
	return null

func _house_bounds(source, prefix: String) -> Dictionary:
	var box := AABB()
	var count := 0
	var accesses := 0
	var roof := false
	var foundation := false
	for part in source.parts:
		if not String(part.id).begins_with(prefix + "_"): continue
		var bounds: AABB = source.transformed_part_bounds(part)
		box = bounds if count == 0 else box.merge(bounds)
		count += 1
		roof = roof or part.kind == "roof"
		foundation = foundation or part.semantic == "citadel_urban_house_foundation"
	for room: Dictionary in source.rooms:
		if not String(room.get("id", "")).begins_with(prefix + "_"): continue
		for access: Dictionary in room.get("accesses", []):
			box = box.merge(Interior.access_reservation(access))
			accesses += 1
	return {"bounds": box, "partCount": count, "accessCount": accesses, "hasRoof": roof, "hasFoundation": foundation}

func _independent_obstacles(source, historical_detail_policy: bool = false) -> Array:
	var boxes: Array = []
	for part in source.parts:
		# Historical mode ONLY reconstructs the frozen 02 inventory for byte
		# verification. Actual controls use exact producer underlay policy and
		# independently enumerate geometry, preserving all threshold details.
		if historical_detail_policy:
			var detail: bool = not part.collision_enabled and (part.kind == "ground_patch" or String(part.semantic).contains("wear") or String(part.semantic).contains("compaction"))
			if detail: continue
		elif Infill.compatible_underlay(part, 0.62): continue
		boxes.append({"id": part.id, "bounds": source.transformed_part_bounds(part), "origin": "part", "semantic": part.semantic, "collision": part.collision_enabled})
	for room: Dictionary in source.rooms:
		if room.get("role", "") != "courtyard" and room.get("bounds") is AABB: boxes.append({"id": room.id, "bounds": room.bounds, "origin": "room"})
		for access: Dictionary in room.get("accesses", []): boxes.append({"id": access.get("id", "access"), "bounds": Interior.access_reservation(access), "origin": "access"})
	return boxes

func _upper(box: AABB, axis: int) -> float:
	return maxf(float(box.end[axis]), float(box.position[axis]) + float(box.size[axis]))

func _inside(box: AABB, rect: Rect2) -> bool:
	return box.position.x >= rect.position.x and box.position.z >= rect.position.y and _upper(box, 0) <= minf(rect.end.x, float(rect.position.x) + float(rect.size.x)) and _upper(box, 2) <= minf(rect.end.y, float(rect.position.y) + float(rect.size.y))

func _conflict(a: AABB, b: AABB, spacing: float) -> bool:
	for axis: int in range(3):
		var extra := 0.0 if axis == 1 else spacing
		if _upper(a, axis) <= float(b.position[axis]) - extra or float(a.position[axis]) >= _upper(b, axis) + extra: return false
	return true

func _controlled(_stage: String) -> bool:
	if rejected: after_false += 1
	callback_count += 1
	if callback_count == reject_at:
		rejected = true
		return false
	return Time.get_ticks_msec() < deadline

func _budget(_stage: String) -> bool:
	return Time.get_ticks_msec() < deadline

func _reason(result: Dictionary, value: String) -> bool:
	return result.get("reason") == value or (result.get("detail") is Dictionary and _reason(result.detail, value))

func _check(name: String, value: bool) -> void:
	checks[name] = value

func _hashes() -> Dictionary:
	var hashes: Dictionary = {}
	for folder: String in ["res://scripts/buildings", "res://scripts/world"]:
		for name: String in DirAccess.get_files_at(folder):
			if name.ends_with(".gd"): hashes[folder.path_join(name)] = FileAccess.get_sha256(folder.path_join(name))
	hashes[get_script().resource_path] = FileAccess.get_sha256(get_script().resource_path)
	return hashes

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
