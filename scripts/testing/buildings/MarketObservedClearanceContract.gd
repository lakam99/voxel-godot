extends SceneTree

## Pure synthetic observer controls ONLY: no actor, input, scene publication,
## physics frames, screenshots or navigation. Does not prove a live walk.
## VOXEL_MARKET_OBSERVED_CLEARANCE_REPORT must name a fresh absolute JSON file.
const Observer = preload("res://scripts/testing/buildings/CitadelMarketLocalWalkWitness.gd")
var _checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_MARKET_OBSERVED_CLEARANCE_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	_geometry_controls()
	_invalid_controls()
	_budget_and_copy_controls()
	var passed: bool = not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var report := {"fixture": "MarketObservedClearanceContract", "passed": passed, "checks": _checks,
		"evidenceLevel": "pure_synthetic_actual_segment_observer_contract",
		"doesNotProve": "No actual motion was observed here. Main must supply the frozen source/furniture obstacle snapshot to the real-physics witness; empty-default calls are not clearance proof. No production gameplay or NPC/navigation acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("Observed clearance synthetic contract: %s (%d checks)" % ["PASS" if passed else "FAIL", _checks.size()])
	quit(2 if error != OK else (0 if passed else 1))

func _geometry_controls() -> void:
	_check("unchanged_required_envelope", Observer.CLEARANCE_RADIUS == 0.32 and Observer.CLEARANCE_HEIGHT == 1.72 and Observer.CLEARANCE_GROUND_SKIN == 0.02)
	var origin := Vector3.ZERO
	var corner := Vector3(0, 0, 2)
	var end := Vector3(2, 0, 2)
	var obstacle := _box("corner_cut_blocker", Vector3(0.9, 0.4, 0.9), Vector3(0.2, 0.8, 0.2))
	_check("ideal_first_leg_clear", Observer.observe_clearance_segment(origin, corner, [obstacle]).ready)
	_check("ideal_second_leg_clear", Observer.observe_clearance_segment(corner, end, [obstacle]).ready)
	var cut := Observer.observe_clearance_segment(origin, end, [obstacle], 7)
	_check("actual_corner_cut_rejected", not cut.ready and cut.reason == "observed_clearance_blocked" and not cut.clearanceProof)
	_check("actual_failure_identifies_source_and_segment", cut.get("partId") == obstacle.id and cut.get("previousFeet") == origin and cut.get("currentFeet") == end and cut.get("obstacleBounds") == obstacle.bounds and cut.get("segmentIndex") == 7 and cut.get("obstacleTests") == 1)
	var expected := AABB(Vector3(-0.32, 0.02, -0.32), Vector3(2.64, 1.70, 2.64))
	_check("conservative_full_body_sweep", cut.get("sweptBounds") is AABB and cut.sweptBounds.is_equal_approx(expected))
	var ground := _box("actual_ground", Vector3(-4, -0.5, -4), Vector3(8, 0.5, 8))
	var skin := _box("thin_wear", Vector3(-4, 0.005, -4), Vector3(8, 0.010, 8))
	var clear := Observer.observe_clearance_segment(origin, end, [ground, skin])
	_check("ground_and_groundskin_clear", clear.ready and clear.obstacleTests == 2 and clear.clearanceChecked)
	var tall := _box("thin_wear", Vector3(-0.1, 0.03, -0.1), Vector3(0.2, 0.8, 0.2))
	tall["semantic"] = "ground_wear"
	var blocked := Observer.observe_clearance_segment(origin, origin, [tall])
	_check("tall_wear_not_name_exempt_even_while_stopped", not blocked.ready and blocked.get("partId") == "thin_wear")
	var high := _box("overhead", Vector3(-0.1, 2.0, -0.1), Vector3(0.2, 0.15, 0.2))
	_check("overhead_clear_before_vertical_motion", Observer.observe_clearance_segment(origin, origin, [high]).ready)
	_check("actual_vertical_motion_included", not Observer.observe_clearance_segment(origin, Vector3(0, 0.5, 0), [high]).ready)
	var harmless := _box("off_path", Vector3(10, 1, 10), Vector3.ONE)
	var ordered := Observer.observe_clearance_segment(origin, end, [harmless, obstacle, tall])
	_check("deterministic_first_intersection_and_count", not ordered.ready and ordered.get("partId") == obstacle.id and ordered.get("obstacleTests") == 2 and var_to_bytes(ordered) == var_to_bytes(Observer.observe_clearance_segment(origin, end, [harmless, obstacle, tall])))
	var empty := Observer.observe_clearance_segment(origin, end, [])
	_check("legacy_empty_is_explicitly_not_proof", empty.ready and not empty.clearanceProof and not empty.clearanceChecked and empty.obstacleTests == 0 and empty.scope == "no_obstacles_no_clearance_proof")
	var prepared := Observer.prepare_observed_clearance([harmless])
	_check("preparation_alone_is_not_clearance_proof", prepared.ready and not prepared.clearanceProof and not prepared.clearanceChecked)

func _invalid_controls() -> void:
	var good := _box("valid", Vector3(5, 0, 5), Vector3.ONE)
	var cases: Array = [null, {}, [null], [{}], [{"id": "missing_bounds"}],
		[{"id": 3, "bounds": good.bounds}], [{"id": "", "bounds": good.bounds}],
		[{"id": "x".repeat(257), "bounds": good.bounds}],
		[{"id": "wrong_bounds", "bounds": Vector3.ONE}],
		[{"id": "rect_not_aabb", "bounds": Rect2(Vector2.ZERO, Vector2.ONE)}], [good, good.duplicate(true)]]
	for axis in range(3):
		for component in [0.0, -1.0, NAN, INF]:
			var size := Vector3.ONE
			size[axis] = component
			cases.append([_box("invalid_size", Vector3.ZERO, size)])
		for component in [NAN, INF, -INF, 1.0e30]:
			var position := Vector3.ZERO
			position[axis] = component
			cases.append([_box("invalid_position", position, Vector3.ONE)])
	cases.append([_box("end_exceeds_bound", Vector3(999999, 0, 0), Vector3(2, 1, 1))])
	for index in range(cases.size()):
		var source: Variant = cases[index]
		var before := var_to_bytes(source)
		var result := Observer.observe_clearance_segment(Vector3.ZERO, Vector3.ONE, source)
		_check("malformed_obstacles:%d" % index, not result.ready and not result.clearanceProof and result.obstacleTests == 0 and not String(result.reason).is_empty() and before == var_to_bytes(source))
	var overlap := _box("would_intersect_first", Vector3.ZERO, Vector3.ONE)
	var late_invalid := Observer.observe_clearance_segment(Vector3.ZERO, Vector3.ONE, [overlap, {"id": "bad"}])
	_check("validate_all_records_before_any_intersection", not late_invalid.ready and late_invalid.reason == "invalid_clearance_obstacle" and late_invalid.obstacleTests == 0 and late_invalid.get("obstacleIndex") == 1)
	var bad_points: Array = [null, Vector2.ZERO, "origin", Vector3(NAN, 0, 0), Vector3(0, INF, 0), Vector3(0, 0, -INF), Vector3(1.0e30, 0, 0)]
	for index in range(bad_points.size()):
		for before_invalid in [true, false]:
			var result := Observer.observe_clearance_segment(bad_points[index] if before_invalid else Vector3.ZERO, Vector3.ZERO if before_invalid else bad_points[index], [good])
			_check("malformed_actual_feet:%d:%s" % [index, str(before_invalid)], not result.ready and result.reason == "invalid_observed_feet" and not result.clearanceProof and result.obstacleTests == 0)

func _budget_and_copy_controls() -> void:
	_check("fixed_budgets", Observer.MAX_CLEARANCE_OBSTACLES == 4096 and Observer.MAX_CLEARANCE_SEGMENTS == 8192)
	var boxes: Array = []
	for index in range(4096): boxes.append(_box("bounded_%d" % index, Vector3(10 + index * 2, 0, 10), Vector3.ONE))
	var before := var_to_bytes(boxes)
	var result := Observer.observe_clearance_segment(Vector3.ZERO, Vector3.ONE, boxes, 8191)
	_check("maximum_obstacles_and_last_segment_accepted", result.ready and result.obstacleTests == 4096 and result.segmentIndex == 8191 and before == var_to_bytes(boxes))
	boxes.append(_box("excess", Vector3(10, 0, 10), Vector3.ONE))
	var excess := Observer.observe_clearance_segment(Vector3.ZERO, Vector3.ONE, boxes)
	_check("excess_obstacles_fail_before_tests", not excess.ready and excess.reason == "invalid_or_excessive_clearance_obstacles" and excess.obstacleTests == 0)
	for index in [-1, 8192]:
		var limit := Observer.observe_clearance_segment(Vector3.ZERO, Vector3.ONE, [boxes[0]], index)
		_check("segment_limit:%d" % index, not limit.ready and limit.reason == "observed_clearance_segment_limit" and limit.obstacleTests == 0)
	var source: Array = [_box("original", Vector3(10, 0, 10), Vector3.ONE)]
	var source_before := var_to_bytes(source)
	var prepared := Observer.prepare_observed_clearance(source)
	_check("preparation_preserves_input", prepared.ready and source_before == var_to_bytes(source))
	if not prepared.ready: return
	_check("private_array_and_record_copies", not is_same(prepared.obstacles, source) and not is_same(prepared.obstacles[0], source[0]))
	source[0].id = "changed"
	source[0].bounds = AABB(Vector3.ZERO, Vector3.ONE)
	source.append({})
	_check("caller_mutation_cannot_change_frozen_copy", prepared.obstacles.size() == 1 and prepared.obstacles[0].id == "original" and prepared.obstacles[0].bounds == AABB(Vector3(10, 0, 10), Vector3.ONE))
	_check("frozen_copy_still_clear", Observer.observe_clearance_segment(Vector3.ZERO, Vector3.ONE, prepared.obstacles).ready)

func _check(label: String, passed: bool) -> void:
	_checks.append({"name": label, "passed": passed})

static func _box(id: String, position: Vector3, size: Vector3) -> Dictionary:
	return {"id": id, "bounds": AABB(position, size)}
