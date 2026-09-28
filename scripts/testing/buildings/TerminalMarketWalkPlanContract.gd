extends SceneTree

## Source/unit itinerary contract with real BuildingPart records. No actor,
## scene publication, physics frames, headed launch or navigation invocation.
## VOXEL_TERMINAL_MARKET_WALK_PLAN_REPORT: fresh absolute JSON output.
## Optional VOXEL_TERMINAL_MARKET_WALK_PLAN_FROZEN=1 requests exactly ONE current
## Visual._prepare_frozen_recipe call using VOXEL_ROOF_INTEGRATION_BASELINE.
## An unready frozen preparation/itinerary is explicitly NOT acceptance.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Walk = preload("res://scripts/testing/buildings/CitadelMarketWalkPlan.gd")
const Observer = preload("res://scripts/testing/buildings/CitadelMarketLocalWalkWitness.gd")
const Visual = preload("res://scripts/testing/buildings/CitadelMarketRecipeVisual.gd")
var _checks: Array = []
var _frozen: Dictionary = {"requested": false, "preparationCalls": 0}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_TERMINAL_MARKET_WALK_PLAN_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var script: Script = Walk
	if not script.has_method("extend_to_terminal_fronts"):
		_check("extension_api_present", false)
	else:
		for quarter in range(4):
			for floor_y in [0.5, 2.125]:
				_positive(_fixture(quarter, floor_y), "cardinal_%d_height_%s" % [quarter, str(floor_y)])
		var furnished := _fixture()
		furnished.furniture.append({"id": "furnishing:off_path", "bounds": AABB(furnished.pose * Vector3(8, furnished.floorY, 8), Vector3.ONE)})
		_positive(furnished, "furniture_observer_assignment")
		for mode in ["visual_noncollider", "incoming_visual_noncollider", "furniture", "missing_public_support", "noncolliding_support",
			"market_not_ready", "terminals_not_ready", "empty_waypoints", "missing_counter", "mixed_height", "noncardinal", "vertical_front",
			"bad_furniture_type", "missing_furniture_bounds", "nonfinite_furniture", "mixed_waypoint_height", "empty_setups", "duplicate_setups",
			"missing_elevation", "malformed_layout", "invalid_approach", "too_many_waypoints",
			"displaced_approach", "rotated_counter", "tall_wear"]:
			_negative(mode)
		if OS.get_environment("VOXEL_TERMINAL_MARKET_WALK_PLAN_FROZEN") == "1":
			_frozen_control()
	var passed: bool = not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var report := {"fixture": "TerminalMarketWalkPlanContract", "passed": passed, "checks": _checks, "frozen": _frozen,
		"evidenceLevel": "synthetic_real_building_parts_source_itinerary_contract",
		"doesNotProve": "A ready source itinerary is not a successful walk: no actor, input, physical frames, rendered captures, production access or NPC/navigation acceptance. Source preparation may independently remain blocked."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("Terminal/market walk source contract: %s (%d checks)" % ["PASS" if passed else "FAIL", _checks.size()])
	quit(2 if error != OK else (0 if passed else 1))

func _fixture(quarter := 0, floor_y := 0.5) -> Dictionary:
	var turn := Basis.IDENTITY
	match quarter:
		1: turn = Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
		2: turn = Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3(0, 0, -1))
		3: turn = Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(-1, 0, 0))
	var pose := Transform3D(turn, Vector3(13, 0, 7))
	var b := Blueprint.new("synthetic_terminal_walk_source", 101, "timber")
	b.recipe = {"preserve": ["original_source"]}
	b.add_part({"id": "public_surface", "kind": "foundation", "material": "worn_cobble",
		"semantic": "citadel_market_plaza", "collision": true,
		"position": pose.origin + Vector3(0, floor_y - 0.25, 0), "size": Vector3(40, 0.5, 40)})
	var setups: Array = []
	for index in range(3):
		var prefix := "source_bay_%d" % index
		setups.append({"prefix": prefix})
		b.add_part({"id": prefix + "_counter", "kind": "decor", "material": "timber_board",
			"semantic": "citadel_terminal_shop", "collision": false,
			"position": pose * Vector3(float(index - 1) * 3, floor_y + 0.76, 0),
			"size": Vector3(2, 0.16, 0.8), "rotation": turn.get_euler()})
	var start: Vector3 = pose * Vector3(-6, floor_y, -6)
	var market := {"ready": true, "start": start, "standingY": floor_y, "waypoints": []}
	for index in range(3):
		market.waypoints.append({"id": "market_%d_front" % index, "position": pose * Vector3(-6 + index, floor_y, -6 + index),
			"standingY": floor_y, "capture": true, "faceDirection": turn * Vector3.BACK, "preserve": [index]})
	var local_approach := AABB(Vector3(-5, floor_y, -3), Vector3(10, 0.1, 2.5))
	var approach_bounds: AABB = pose * local_approach
	# Exercise the same quarter-turn Euler round trip as actual source records;
	# tiny cardinal representation error is handled by the current owner.
	var terminals := {"ready": true, "front": Basis.from_euler(turn.get_euler()) * Vector3.FORWARD, "setups": setups,
		"elevation": {"publicPavingPlan": {"ready": true, "standingY": floor_y,
			"approach": Rect2(Vector2(approach_bounds.position.x, approach_bounds.position.z), Vector2(approach_bounds.size.x, approach_bounds.size.z))}}}
	for part in b.parts: b.physical_parts_by_id[part.id] = part
	return {"b": b, "market": market, "terminals": terminals, "furniture": [], "pose": pose, "floorY": floor_y}

func _positive(fixture: Dictionary, label: String) -> void:
	var result := _call_preserving(fixture, label)
	_check(label + ":ready", result.get("ready", false), _brief(result))
	if not result.get("ready", false): return
	_check_extension(fixture.b, fixture.market, fixture.terminals, result, label)
	_check_observer_assignment(fixture.b, fixture.terminals.setups, fixture.furniture, result, label)
	var repeated := _call_preserving(fixture, label + ":repeat")
	_check(label + ":deterministic", var_to_bytes(result) == var_to_bytes(repeated))

func _check_extension(b, market: Dictionary, terminals: Dictionary, result: Dictionary, label: String) -> void:
	if not result.get("waypoints") is Array or result.waypoints.size() > 32:
		_check(label + ":bounded_waypoints", false)
		return
	var prefix_preserved: bool = result.get("start") == market.start and result.get("standingY") == market.standingY and result.waypoints.size() > market.waypoints.size()
	if prefix_preserved:
		prefix_preserved = var_to_bytes(result.waypoints.slice(0, market.waypoints.size())) == var_to_bytes(market.waypoints)
	_check(label + ":same_start_and_exact_market_prefix", prefix_preserved)
	var terminal_captures: Array = []
	var waypoint_ids: Dictionary = {}
	var valid := true
	var length := 0.0
	var previous: Vector3 = market.start
	for index in range(result.waypoints.size()):
		var point: Dictionary = result.waypoints[index]
		valid = valid and point.get("position") is Vector3 and point.position.is_finite() and point.position.y == market.standingY and point.get("standingY") == market.standingY and not waypoint_ids.has(point.id)
		waypoint_ids[point.id] = true
		length += previous.distance_to(point.position)
		previous = point.position
		if index >= market.waypoints.size() and point.get("capture", true): terminal_captures.append(point)
	_check(label + ":finite_level_unique_waypoints", valid)
	_check(label + ":distance_is_continuous_complete_trace", result.get("distance") == length)
	_check(label + ":three_terminal_captures", terminal_captures.size() == 3)
	if terminal_captures.size() != 3: return
	var approach: Rect2 = terminals.elevation.publicPavingPlan.approach
	for index in range(terminals.setups.size()):
		var setup: Dictionary = terminals.setups[index]
		var counter = b.find_part(setup.prefix + "_counter")
		var point: Dictionary = terminal_captures[index]
		var front := Vector3(roundf(terminals.front.x), 0, roundf(terminals.front.z))
		var radial: Vector3 = point.position - Vector3(counter.position.x, market.standingY, counter.position.z)
		var outward: float = radial.dot(front)
		# Independently project the four reserved-frontage corners. Its inner
		# edge can lie farther out than the actual counter's front edge.
		var inner := INF
		for corner in [approach.position, approach.end, Vector2(approach.position.x, approach.end.y), Vector2(approach.end.x, approach.position.y)]:
			inner = minf(inner, Vector3(corner.x, 0, corner.y).dot(front))
		var expected: float = maxf(counter.size.z * 0.5, inner - counter.position.dot(front)) + Walk.RADIUS + 0.10
		# Arithmetic comparison only, not a changed production contact margin.
		var correct: bool = point.id == setup.prefix + "_front" and point.faceDirection.is_equal_approx(-front) and absf(outward - expected) < 0.00001 and (radial - front * outward).length() < 0.00001
		_check(label + ":own_counter_front:%d" % index, correct)
		_check(label + ":capture_capsule_inside_reserved_frontage:%d" % index, _capsule_inside(approach, point.position))
	for point in result.waypoints.slice(market.waypoints.size()):
		if String(point.id).ends_with("_aisle"):
			_check(label + ":aisle_capsule_inside_reserved_frontage:" + point.id, _capsule_inside(approach, point.position))

func _capsule_inside(rect: Rect2, point: Vector3) -> bool:
	return point.x - Walk.RADIUS >= rect.position.x and point.x + Walk.RADIUS <= rect.end.x and point.z - Walk.RADIUS >= rect.position.y and point.z + Walk.RADIUS <= rect.end.y

func _check_observer_assignment(b, setups: Array, furniture: Array, result: Dictionary, label: String) -> void:
	var obstacles: Variant = result.get("observationObstacles")
	var prepared := Observer.prepare_observed_clearance(obstacles)
	_check(label + ":observer_assignment_valid", prepared.ready and prepared.get("obstacleCount", 0) > 0)
	if not prepared.ready: return
	var ids: Dictionary = {}
	for obstacle in obstacles: ids[obstacle.id] = obstacle.bounds
	# The noncolliding counters must reach the live observer, not merely the
	# preflight. Compare exact source bounds, not copied production predicates.
	for setup in setups:
		var part = b.find_part(String(setup.prefix) + "_counter")
		_check(label + ":observer_counter:" + setup.prefix, part != null and ids.get(part.id) == b.transformed_part_bounds(part))
	for obstacle in furniture:
		_check(label + ":observer_furniture:" + obstacle.id, ids.get(obstacle.id) == obstacle.bounds)
	var previous: Vector3 = result.start
	for index in range(result.waypoints.size()):
		var current: Vector3 = result.waypoints[index].position
		var observed := Observer.observe_clearance_segment(previous, current, obstacles, index)
		_check(label + ":ideal_segment_observer_compatibility:%d" % index, observed.ready)
		previous = current
	# This only assigns/tests the snapshot. No actual-motion claim here.

func _negative(mode: String) -> void:
	var fixture := _fixture()
	var expected_reason := ""
	var expected_blocker := ""
	var end: Vector3 = fixture.market.waypoints.back().position
	var approach: Rect2 = fixture.terminals.elevation.publicPavingPlan.approach
	var front: Vector3 = fixture.terminals.front
	var first_counter = fixture.b.find_part(fixture.terminals.setups[0].prefix + "_counter")
	var tangent := Vector3(front.z, 0, -front.x)
	# Current connector stays on the incoming aisle until first-counter tangent
	# alignment, then turns normally into the reserved frontage.
	var connection: Vector3 = end + tangent * (first_counter.position - end).dot(tangent)
	var blocker_at: Vector3 = end.lerp(connection, 0.5) + Vector3(0, Walk.HEIGHT * 0.5, 0)
	match mode:
		"visual_noncollider", "incoming_visual_noncollider":
			if mode == "incoming_visual_noncollider":
				blocker_at = fixture.market.waypoints[0].position.lerp(fixture.market.waypoints[1].position, 0.5) + Vector3(0, Walk.HEIGHT * 0.5, 0)
			fixture.b.add_part({"id": "visible_noncollider", "kind": "decor", "collision": false,
				"semantic": "visible_fixture_obstacle", "position": blocker_at, "size": Vector3(0.3, 1, 0.3)})
			expected_reason = "diagnostic_aisle_blocked"
			expected_blocker = "visible_noncollider"
		"furniture":
			fixture.furniture.append({"id": "furnishing:chair", "bounds": AABB(blocker_at - Vector3.ONE * 0.25, Vector3.ONE * 0.5)})
			expected_reason = "diagnostic_aisle_blocked"
			expected_blocker = "furnishing:chair"
		"missing_public_support":
			fixture.b.find_part("public_surface").semantic = "ordinary_foundation_not_public"
			expected_reason = "diagnostic_aisle_lacks_public_paving"
		"noncolliding_support":
			fixture.b.find_part("public_surface").collision_enabled = false
			expected_reason = "diagnostic_aisle_lacks_public_paving"
		"market_not_ready": fixture.market = {"ready": false}
		"terminals_not_ready": fixture.terminals = {"ready": false}
		"empty_waypoints": fixture.market.waypoints.clear()
		"missing_counter":
			var id: String = fixture.terminals.setups[0].prefix + "_counter"
			fixture.b.parts.erase(fixture.b.find_part(id))
			fixture.b.physical_parts_by_id.erase(id)
			expected_reason = "terminal_walk_missing_counter"
		"mixed_height": fixture.terminals.elevation.publicPavingPlan.standingY += 0.25
		"noncardinal": fixture.terminals.front = Vector3(0.6, 0, -0.8)
		"vertical_front": fixture.terminals.front = Vector3.UP
		"bad_furniture_type": fixture.furniture.append(null)
		"missing_furniture_bounds": fixture.furniture.append({"id": "missing_bounds"})
		"nonfinite_furniture": fixture.furniture.append({"id": "invalid_bounds", "bounds": AABB(Vector3(NAN, 0, 0), Vector3.ONE)})
		"mixed_waypoint_height": fixture.market.waypoints.back().position.y += 0.25
		"empty_setups": fixture.terminals.setups.clear()
		"duplicate_setups": fixture.terminals.setups.append(fixture.terminals.setups[0].duplicate(true))
		"missing_elevation": fixture.terminals.erase("elevation")
		"malformed_layout": fixture.terminals.elevation.publicPavingPlan = "invalid"
		"invalid_approach": fixture.terminals.elevation.publicPavingPlan.approach = Rect2()
		"too_many_waypoints": fixture.market.waypoints.resize(33)
		"displaced_approach":
			fixture.terminals.elevation.publicPavingPlan.approach.position.x += approach.size.x
			expected_reason = "terminal_target_outside_reserved_frontage"
		"rotated_counter":
			fixture.b.find_part(fixture.terminals.setups[0].prefix + "_counter").rotation.y += PI * 0.5
			expected_reason = "terminal_counter_orientation_mismatch"
		"tall_wear":
			fixture.b.add_part({"id": "tall_ground_wear", "kind": "ground_patch", "collision": false,
				"semantic": "market_wear", "position": blocker_at, "size": Vector3(0.3, 1, 0.3)})
			expected_reason = "diagnostic_aisle_blocked"
			expected_blocker = "tall_ground_wear"
	var result := _call_preserving(fixture, "negative:" + mode)
	var rejected: bool = result.get("ready") == false and result.get("reason") is String and not String(result.reason).is_empty()
	if not expected_reason.is_empty(): rejected = rejected and result.get("reason") == expected_reason
	if not expected_blocker.is_empty(): rejected = rejected and result.get("partId") == expected_blocker
	_check("reject:" + mode, rejected, _brief(result))

func _call_preserving(fixture: Dictionary, label: String) -> Dictionary:
	var b = fixture.b
	var before := var_to_bytes(b.snapshot())
	var inputs := var_to_bytes([fixture.market, fixture.terminals, fixture.furniture])
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var result: Variant = Walk.extend_to_terminal_fronts(b, fixture.market, fixture.terminals, fixture.furniture)
	var preserved: bool = before == var_to_bytes(b.snapshot()) and inputs == var_to_bytes([fixture.market, fixture.terminals, fixture.furniture]) and b.parts.size() == aliases.size()
	for index in range(mini(b.parts.size(), aliases.size())):
		preserved = preserved and is_same(b.parts[index], aliases[index]) and is_same(b.parts[index].recipe, recipes[index])
	_check(label + ":no_source_or_input_mutation", preserved)
	_check(label + ":structured_result", result is Dictionary and result.get("ready") is bool)
	return result if result is Dictionary else {"contractInvalidReturn": true}

func _frozen_control() -> void:
	_frozen = {"requested": true, "preparationCalls": 0, "preparationReady": false, "itineraryReady": false}
	var path := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE").strip_edges().simplify_path()
	if not path.is_absolute_path() or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != Visual.FROZEN_SHA:
		_check("frozen_baseline_required", false)
		return
	var digest := FileAccess.get_sha256(path)
	var fixture: Script = Visual
	if not fixture.has_method("_prepare_frozen_recipe"):
		_check("frozen_preparation_api", false)
		return
	_frozen.preparationCalls = 1
	var prepared: Dictionary = fixture.call("_prepare_frozen_recipe", path, true)
	_frozen.preparationReady = prepared.get("ready", false)
	_frozen["preparation"] = _brief(prepared)
	_check("frozen_current_preparation_ready", prepared.get("ready", false), _brief(prepared))
	# Current Visual already calls the extension: consume that result, never
	# launch another preparation or replace a blocked itinerary with a search.
	if prepared.get("ready", false):
		var walk: Dictionary = prepared.get("localWalkPlan", {})
		_frozen.itineraryReady = walk.get("ready", false)
		_frozen["itinerary"] = _brief(walk)
		_check("frozen_continuous_itinerary_ready", walk.get("ready", false), _brief(walk))
		if walk.get("ready", false):
			_check_observer_assignment(prepared.blueprint, prepared.terminals.setups, [], walk, "frozen")
			var captures: Array = walk.waypoints.filter(func(point): return bool(point.get("capture", true)))
			_check("frozen_six_market_plus_terminal_captures", captures.size() == 6)
			for setup in prepared.terminals.setups:
				var selected: Array = captures.filter(func(point): return point.id == String(setup.prefix) + "_front")
				_check("frozen_counter_capture:" + setup.prefix, selected.size() == 1)
	_check("frozen_archive_unchanged", FileAccess.get_sha256(path) == digest)
	_frozen["baselineSha256"] = digest

func _check(label: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": label, "passed": passed, "detail": detail})

static func _brief(result: Dictionary) -> Dictionary:
	var compact: Dictionary = {}
	for key in ["ready", "reason", "segment", "partId", "distance", "scope"]:
		if result.has(key): compact[key] = result[key]
	if result.get("waypoints") is Array: compact["waypointCount"] = result.waypoints.size()
	for key in ["terminals", "layout", "plan", "localWalkPlan"]:
		if result.get(key) is Dictionary: compact[key] = _brief(result[key])
	return compact

static func _json(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
