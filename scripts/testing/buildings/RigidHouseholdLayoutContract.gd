extends SceneTree

## Synthetic recipe-planner contract only: no frozen citadel, scene, publisher,
## physics, NPC, or gameplay acceptance. Public plan cases plus one explicitly
## labeled synthetic represented-endpoint helper regression.
## VOXEL_RIGID_HOUSEHOLD_LAYOUT_REPORT: new absolute JSON file; parent exists.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const PLANNER := "res://scripts/buildings/RigidHouseholdLayoutRecipe.gd"
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Batch = preload("res://scripts/buildings/HouseholdLayoutBatchRecipe.gd")
const EPS := 0.0001
var _planner
var _rows: Array = []
var _path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_path = OS.get_environment("VOXEL_RIGID_HOUSEHOLD_LAYOUT_REPORT").strip_edges().simplify_path()
	if not _path.is_absolute_path() or _path.get_extension().to_lower() != "json" or FileAccess.file_exists(_path):
		push_error("Set VOXEL_RIGID_HOUSEHOLD_LAYOUT_REPORT to a new absolute JSON path")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	if not ResourceLoader.exists(PLANNER):
		_finish(started, "planner_not_available")
		return
	_planner = load(PLANNER)
	if _planner == null or not _planner.has_method("plan"):
		_finish(started, "planner_api_not_available")
		return
	var several := _fixture("several_pavings")
	_paving(several, "small", Vector2.ZERO, Vector2(2.0, 2.0))
	_paving(several, "roomy", Vector2(10.0, 0.0), Vector2(16.0, 12.0))
	_part(several.blueprint, "fixed_wall", "wall", Vector3(3.0, 3.0, 0.0), Vector3(0.6, 4.0, 8.0))
	_exercise("several_pavings_with_wall", several, true, "roomy")

	var tiny := _fixture("tiny")
	_paving(tiny, "small", Vector2.ZERO, Vector2(2.0, 2.0))
	_exercise("household_does_not_fit", tiny, false)

	var rotation := _fixture("rotation")
	_paving(rotation, "long_strip", Vector2.ZERO, Vector2(14.0, 5.5))
	var rotated := _exercise("quarter_turn_required_for_supported_front", rotation, true)
	var turn_ok := false
	if bool(rotated.get("ready", false)) and rotated.get("transform") is Transform3D:
		var front: Vector3 = (rotated.transform as Transform3D).basis * Vector3.FORWARD
		turn_ok = absf(front.x) > 1.0 - EPS and absf(front.z) < EPS
	_rows.append({"id": "rotation_is_geometry_required", "passed": turn_ok,
		"reason": "The strip fits the entire household and approach along X, not along Z; neither turn sign is prescribed."})

	var no_approach := _fixture("unsupported_front")
	_paving(no_approach, "short_slab", Vector2.ZERO, Vector2(6.0, 6.0))
	_exercise("body_fits_but_complete_approach_does_not", no_approach, false)

	for kind in ["wall", "door", "stair_tread"]:
		var blocked := _fixture("blocked_" + kind)
		_paving(blocked, "paving", Vector2.ZERO, Vector2(12.0, 12.0))
		_part(blocked.blueprint, "fixed_obstruction", kind, Vector3(0.0, 2.0, 0.0), Vector3(14.0, 2.0, 14.0))
		_exercise("reject_" + kind + "_occupied_paving", blocked, false)

	var decor := _fixture("visible_obstruction")
	_paving(decor, "paving", Vector2.ZERO, Vector2(12.0, 12.0))
	_part(decor.blueprint, "fixed_furniture", "decor", Vector3(0.0, 2.0, 0.0), Vector3(14.0, 2.0, 14.0), false)
	_exercise("noncolliding_visible_static_part_is_not_free_space", decor, false)

	var reserved := _fixture("reserved")
	_paving(reserved, "paving", Vector2.ZERO, Vector2(12.0, 12.0))
	reserved.policy.reservedFootprints.append(Rect2(-Vector2.ONE * 7.0, Vector2.ONE * 14.0))
	_exercise("reserved_footprint_rejects_placement", reserved, false)

	for role in ["shop", "courtyard"]:
		var room := _fixture("room_" + role)
		_paving(room, "paving", Vector2.ZERO, Vector2(12.0, 12.0))
		room.blueprint.rooms.append({"id": "room", "role": role,
			"bounds": AABB(Vector3(-7.0, 1.0, -7.0), Vector3(14.0, 4.0, 14.0))})
		_exercise("room_role_" + role, room, role == "courtyard")

	var distant := _fixture("distant")
	_paving(distant, "remote", Vector2(80.0, 0.0), Vector2(12.0, 12.0))
	_exercise("support_outside_search_radius", distant, false)
	_reordering_cases()
	_nearest_first_precision_cases()
	_critic_counterexamples()
	_ecology_counterexamples()
	_batch_counterexamples()
	_stored_pose_containment_cases()
	_reconstructed_endpoint_helper_case()
	_finish(started, "contract_complete")

func _batch_counterexamples() -> void:
	var fixture := _fixture("batch")
	_paving(fixture, "paving", Vector2.ZERO, Vector2(32, 24))
	var other := _fixture("second")
	var second_ids: Array = []
	for part in other.blueprint.parts:
		var record: Dictionary = part.snapshot()
		record.id = "second_" + String(record.id)
		record.position += Vector3(4, 0, 0)
		var added = fixture.blueprint.add_part(record)
		fixture.blueprint.physical_parts_by_id[added.id] = added
		second_ids.append(added.id)
	var groups: Array = [{"memberIds": fixture.members, "front": Vector3.FORWARD},
		{"memberIds": second_ids, "front": Vector3.BACK}]
	var original := _digest(fixture.blueprint.snapshot())
	var baseline := Batch.plan(fixture.blueprint, groups, _batch_single)
	_rows.append({"id": "batch_complete_with_exact_inputs", "passed": baseline.get("ready", false) and baseline.households.size() == 2 and original == _digest(fixture.blueprint.snapshot())})
	var reversed: Array = groups.duplicate(true)
	reversed.reverse()
	for group in reversed:
		group.memberIds.reverse()
	fixture.blueprint.parts.reverse()
	var replay := Batch.plan(fixture.blueprint, reversed, _batch_single)
	_rows.append({"id": "batch_order_independence", "passed": _digest(_batch_decision(baseline)) == _digest(_batch_decision(replay))})
	fixture.blueprint.parts.reverse()
	var duplicate: Array = groups.duplicate(true)
	duplicate[1].memberIds.append(fixture.members[0])
	var bad := Batch.plan(fixture.blueprint, duplicate, _batch_single)
	_rows.append({"id": "batch_shared_member_rejected", "passed": not bad.ready and bad.reason == "missing_duplicate_or_shared_member" and original == _digest(fixture.blueprint.snapshot())})
	fixture.blueprint.physical_parts_by_id[second_ids[0]].size = Vector3(80, 2, 80)
	var impossible_original := _digest(fixture.blueprint.snapshot())
	var impossible := Batch.plan(fixture.blueprint, groups, _batch_single)
	_rows.append({"id": "batch_no_partial_layout_or_source_mutation", "passed": not impossible.ready and not impossible.has("households") and impossible_original == _digest(fixture.blueprint.snapshot()), "result": impossible})
	var separation := false
	if baseline.get("ready", false):
		var first: Dictionary = baseline.households[0]
		var second: Dictionary = baseline.households[1]
		separation = not first.circulationFootprint.intersects(second.circulationFootprint) and not first.approach.intersects(second.circulationFootprint) and not second.approach.intersects(first.circulationFootprint)
	_rows.append({"id": "batch_preserves_both_household_clearance_envelopes", "passed": separation})

func _batch_single(b, ids: Array, front: Vector3, reservations: Array[Rect2]) -> Dictionary:
	return _planner.plan(b, ids, {"pavingPartIds": ["paving"], "front": front, "reservedFootprints": reservations})

func _batch_decision(result: Dictionary) -> Array:
	var rows: Array = []
	for household in result.get("households", []):
		rows.append(_decision(household))
	return rows

func _ecology_counterexamples() -> void:
	var good_tree := {"position": Vector3(40, 1, 40), "canopyRadius": 2.0,
		"rootButtressFootprints": [{"start": Vector3(40, 1, 40), "end": Vector3(41, 1, 40), "radiusStart": 0.2, "radiusEnd": 0.1}]}
	var cases: Array = [{"id": "valid_ecology_control", "trees": [good_tree], "ready": true}]
	cases.append({"id": "ecology_collection_type", "trees": {}, "ready": false})
	for value in [{}, "invalid"]:
		cases.append({"id": "ecology_tree_record_%d" % cases.size(), "trees": [value], "ready": false})
	for key in ["position", "canopyRadius", "rootButtressFootprints"]:
		var tree := good_tree.duplicate(true)
		tree[key] = Vector3(NAN, 1, 1) if key == "position" else (-1.0 if key == "canopyRadius" else {})
		cases.append({"id": "ecology_invalid_" + key, "trees": [tree], "ready": false})
	for key in ["start", "end", "radiusStart", "radiusEnd"]:
		var tree := good_tree.duplicate(true)
		tree.rootButtressFootprints[0][key] = Vector3(INF, 1, 1) if key in ["start", "end"] else -0.1
		cases.append({"id": "ecology_invalid_root_" + key, "trees": [tree], "ready": false})
	for row in cases:
		var fixture := _fixture(row.id)
		_paving(fixture, "paving", Vector2.ZERO, Vector2(14, 14))
		fixture.blueprint.physical_parts_by_id.paving.recipe["topSurfaceMaterial"] = "cobblestone"
		fixture.blueprint.physical_parts_by_id.paving.semantic = "castle_courtyard_paving"
		fixture.blueprint.recipe["urbanPoc"] = {"treePlacements": row.trees}
		var before := _digest(fixture.blueprint.snapshot())
		var result: Dictionary = Urban.plan_household_on_paving(fixture.blueprint, fixture.members, Vector3.FORWARD)
		_rows.append({"id": row.id, "passed": bool(result.ready) == bool(row.ready) and before == _digest(fixture.blueprint.snapshot()),
			"result": result, "sourceExact": before == _digest(fixture.blueprint.snapshot()), "evidenceLevel": "synthetic_recipe_adapter"})
	var terrace := _fixture("decorative_top_is_not_public_paving")
	_paving(terrace, "terrace", Vector2.ZERO, Vector2(14, 14))
	var terrace_part = terrace.blueprint.physical_parts_by_id.terrace
	terrace_part.semantic = "castle_inhabited_terrace_block"
	terrace_part.recipe["topSurfaceMaterial"] = "cobblestone"
	var before := _digest(terrace.blueprint.snapshot())
	var rejected: Dictionary = Urban.plan_household_on_paving(terrace.blueprint, terrace.members, Vector3.FORWARD)
	_rows.append({"id": "decorative_top_is_not_public_paving", "passed": not rejected.ready and before == _digest(terrace.blueprint.snapshot()),
		"result": rejected, "evidenceLevel": "synthetic_recipe_adapter"})


func _critic_counterexamples() -> void:
	# Append-only coverage: preserve the existing cases and use only plan().
	var narrow := _fixture("circulation_support")
	_paving(narrow, "strip", Vector2.ZERO, Vector2(14.0, 3.8))
	_expect_failure("whole_circulation_must_fit_same_paving", narrow, "no_recipe_placement")

	for reservation_kind in ["tree", "room", "access"]:
		var rear := _fixture("rear_" + reservation_kind)
		_paving(rear, "paving", Vector2.ZERO, Vector2(14.0, 14.0))
		# Keep the household near its source. The band misses its body and
		# north-facing approach, but cuts the rear 0.8m circulation envelope.
		rear.policy.searchRadius = 0.1
		rear.policy.gridStep = 0.05
		var band := Rect2(-5.0, 1.75, 10.0, 0.7)
		if reservation_kind == "tree":
			rear.policy.reservedFootprints = [band]
		elif reservation_kind == "room":
			rear.blueprint.rooms = [{"id": "rear_interior", "role": "shop",
				"bounds": AABB(Vector3(-5.0, 1.0, 1.75), Vector3(10.0, 3.0, 0.7))}]
		else:
			rear.blueprint.rooms = [{"id": "courtyard_with_access", "role": "courtyard",
				"bounds": AABB(Vector3(30, 1, 30), Vector3(2, 3, 2)),
				"accesses": [{"position": Vector3(0.0, 2.0, 2.1), "size": Vector3(10.0, 2.0, 0.7)}]}]
		_expect_failure("rear_circulation_rejects_" + reservation_kind, rear, "no_recipe_placement")

	var low := _short_household_fixture("short_clear_approach")
	_exercise("short_household_supported_approach_control", low, true)
	# Bottom = support + 1.5m; above the entire 1m household. The beam is
	# beyond the body's 0.8m circulation, so only approach headroom rejects it.
	_part(low.blueprint, "overhead_approach_beam", "beam", Vector3(0.0, 2.6, -4.0), Vector3(5.0, 0.2, 1.0))
	_expect_failure("approach_headroom_independent_of_one_metre_household", low, "no_recipe_placement")

	var invalid_accesses: Array = [{},
		{"position": Vector3(NAN, 2, 0), "size": Vector3.ONE},
		{"position": Vector3(0, 2, 0), "size": Vector3(1, NAN, 1)},
		{"position": Vector3(0, 2, 0), "size": Vector3(1, 2, -1)}]
	for index in range(invalid_accesses.size()):
		var invalid := _fixture("malformed_access_%d" % index)
		_paving(invalid, "paving", Vector2.ZERO, Vector2(14, 14))
		invalid.blueprint.rooms = [{"id": "room", "role": "courtyard",
			"bounds": AABB(Vector3(30, 1, 30), Vector3(2, 3, 2)), "accesses": [invalid_accesses[index]]}]
		_expect_failure("malformed_access_%d" % index, invalid, "invalid_room_access")
	for dimension in [NAN, -1.0]:
		var invalid := _fixture("invalid_part_size")
		_paving(invalid, "paving", Vector2.ZERO, Vector2(14, 14))
		invalid.blueprint.physical_parts_by_id["goods"].size.y = dimension
		_expect_failure("source_size_nan" if is_nan(dimension) else "source_size_negative", invalid, "invalid_or_duplicate_part")

	for semantic in ["traffic_wear", "soil_compaction"]:
		var wear := _fixture("solid_" + semantic)
		_paving(wear, "paving", Vector2.ZERO, Vector2(12, 12))
		var blocker = _part(wear.blueprint, "solid_obstruction", "decor", Vector3(0, 2, 0), Vector3(14, 2, 14))
		blocker.semantic = semantic
		_expect_failure("colliding_" + semantic + "_is_an_obstacle", wear, "no_recipe_placement")

	var tiny_step := _fixture("tiny_grid")
	_paving(tiny_step, "paving", Vector2.ZERO, Vector2(12, 12))
	tiny_step.policy.gridStep = 1e-300
	_expect_failure("tiny_grid_is_explicit_candidate_exhaustion", tiny_step, "candidate_limit_exceeded")
	_budget_counterexamples()


func _short_household_fixture(label: String) -> Dictionary:
	var fixture := _fixture(label)
	# Preserve all seven household records, reducing only this synthetic
	# fixture's vertical geometry to exactly 1m above its standing datum.
	for id in fixture.members:
		var part = fixture.blueprint.physical_parts_by_id[id]
		part.position.y = 1.0 + (part.position.y - 1.0) / 2.06
		part.size.y /= 2.06
	_paving(fixture, "front_strip", Vector2(0.0, -1.55), Vector2(5.0, 8.5))
	fixture.policy.searchRadius = 0.1
	fixture.policy.gridStep = 0.05
	return fixture


func _budget_counterexamples() -> void:
	# Deliberately exceed declared API budgets without large geometry or a
	# timing assertion. These must report exhaustion, never geometric no-fit.
	for collection in ["members", "rooms", "accesses", "reservations"]:
		var fixture := _fixture("oversized_" + collection)
		_paving(fixture, "paving", Vector2.ZERO, Vector2(12, 12))
		var values: Array = []
		for index in range(4097):
			match collection:
				"members": values.append("member_%d" % index)
				"rooms": values.append({"id": "room_%d" % index, "role": "courtyard", "bounds": AABB(Vector3(30, 1, 30), Vector3(2, 3, 2))})
				"accesses": values.append({"position": Vector3(30, 2, 30), "size": Vector3.ONE})
				"reservations": values.append(Rect2(30, 30, 2, 2))
		match collection:
			"members": fixture.members = values
			"rooms": fixture.blueprint.rooms = values
			"accesses": fixture.blueprint.rooms = [{"id": "room", "role": "courtyard", "bounds": AABB(Vector3(30, 1, 30), Vector3(2, 3, 2)), "accesses": values}]
			"reservations": fixture.policy.reservedFootprints = values
		_expect_failure("explicit_" + collection + "_collection_limit", fixture, "collection_limit_exceeded")
	var work := _fixture("bounded_work")
	_paving(work, "paving", Vector2.ZERO, Vector2(12, 12))
	# Early intersection must short-circuit, not charge every unused record.
	for index in range(2000):
		work.policy.reservedFootprints.append(Rect2(-7.0, -7.0, 14.0, 14.0))
	_expect_failure("early_intersection_does_not_charge_unused_reservations", work, "no_recipe_placement")
	var late := _fixture("late_work_exhaustion")
	# Establish a valid farther candidate first. Nearer paving then exhausts
	# comparisons behind a long nonintersecting prefix and final blocker,
	# independent of the planner's nearest-first grid traversal order.
	_paving(late, "a_far", Vector2(20, 0), Vector2(12, 12))
	_paving(late, "b_near", Vector2.ZERO, Vector2(12, 12))
	late.policy.gridStep = 0.05
	for index in range(4000):
		late.policy.reservedFootprints.append(Rect2(5.8, 5.8, 0.05, 0.05))
	late.policy.reservedFootprints.append(Rect2(-5.75, -5.75, 11.5, 11.5))
	_expect_failure("explicit_work_exhaustion_after_valid_candidate", late, "work_limit_exceeded")
	var row: Dictionary = _rows.back()
	row.checks["earlierValidCandidateNotReturned"] = int(row.result.get("eligibleImprovements", 0)) > 0 and not row.result.has("transform")
	row.checks["stopsOnFirstExhaustingCheck"] = int(row.result.get("workUpperBound", 0)) == 5000001
	row.passed = bool(row.passed) and row.checks.earlierValidCandidateNotReturned and row.checks.stopsOnFirstExhaustingCheck


func _expect_failure(label: String, fixture: Dictionary, expected_reason: String) -> void:
	var result := _exercise(label, fixture, false)
	var row: Dictionary = _rows.back()
	row.checks["exactFailureReason"] = String(result.get("reason", "")) == expected_reason
	row["expectedReason"] = expected_reason
	row["passed"] = bool(row.passed) and bool(row.checks.exactFailureReason)


func _fixture(label: String) -> Dictionary:
	var b = Blueprint.new("synthetic_layout_" + label, 101, "timber")
	b.recipe = {"fixtureOnly": true, "nestedPreservationMarker": {"goods": ["pot", "basket"], "storage": true}}
	var ids: Array = []
	# Whole household includes asymmetric storage, seating and goods. All are
	# real source records; the planner must never prune or move any of them.
	ids.append(_part(b, "canopy", "decor", Vector3(0.0, 3.0, 0.0), Vector3(3.0, 0.12, 2.0), false).id)
	ids.append(_part(b, "post", "beam", Vector3(-1.35, 2.0, 0.0), Vector3(0.2, 2.0, 0.2)).id)
	ids.append(_part(b, "counter", "decor", Vector3(0.0, 1.75, 0.0), Vector3(2.0, 0.2, 0.7), false).id)
	ids.append(_part(b, "goods", "pottery", Vector3(0.55, 2.04, 0.0), Vector3(0.3, 0.38, 0.3), false).id)
	ids.append(_part(b, "storage", "crate", Vector3(-1.2, 1.35, 1.3), Vector3(0.6, 0.7, 0.6), false).id)
	ids.append(_part(b, "bench", "decor", Vector3(0.25, 1.38, -1.5), Vector3(2.0, 0.16, 0.5), false).id)
	ids.append(_part(b, "bench_leg", "beam", Vector3(-0.5, 1.18, -1.5), Vector3(0.15, 0.36, 0.4), false).id)
	return {"blueprint": b, "members": ids, "policy": {"pavingPartIds": [], "reservedFootprints": [],
		"front": Vector3.FORWARD, "searchRadius": 25.0, "clearance": 0.1, "circulation": 0.8,
		"approachLength": 3.8, "approachWidth": 1.8, "gridStep": 0.25}}


func _part(b, id: String, kind: String, position: Vector3, size: Vector3, collision := true):
	var part = b.add_part({"id": id, "kind": kind, "material": "timber_board", "position": position,
		"size": size, "collision": collision, "semantic": "synthetic_layout_" + kind,
		"recipe": {"visual": true, "fixtureTag": id, "contents": ["preserve", id]}})
	b.physical_parts_by_id[id] = part
	return part


func _paving(fixture: Dictionary, id: String, center: Vector2, size: Vector2) -> void:
	var part = _part(fixture.blueprint, id, "foundation", Vector3(center.x, 0.5, center.y), Vector3(size.x, 1.0, size.y))
	part.material_id = "cobblestone"
	fixture.policy.pavingPartIds.append(id)


func _exercise(label: String, fixture: Dictionary, expect_ready: bool, expected_support := "") -> Dictionary:
	var b = fixture.blueprint
	var snapshot := _digest(b.snapshot())
	var policy := _digest(fixture.policy)
	var members := _digest(fixture.members)
	var aliases: Array = b.parts.duplicate()
	var index: Dictionary = b.physical_parts_by_id.duplicate()
	var result: Dictionary = _planner.plan(b, fixture.members, fixture.policy)
	var unchanged: bool = snapshot == _digest(b.snapshot()) and policy == _digest(fixture.policy) and members == _digest(fixture.members)
	var same_objects: bool = aliases == b.parts and index == b.physical_parts_by_id
	var ready: bool = bool(result.get("ready", false))
	var checks := {"expectedReadiness": ready == expect_ready, "sourceAndInputsExact": unchanged,
		"allFurnitureAndOtherPartsRetained": aliases.size() == b.parts.size() and unchanged,
		"partObjectsAndLookupIndexUnchanged": same_objects,
		"failureHasReason": ready or not String(result.get("reason", "")).is_empty()}
	var geometry: Dictionary = {}
	if ready:
		geometry = _inspect_ready(fixture, result)
		checks["returnedGeometryConsistent"] = bool(geometry.passed)
		checks["expectedSupport"] = expected_support.is_empty() or String(result.get("supportId", "")) == expected_support
	_rows.append({"id": label, "passed": checks.values().all(func(value): return bool(value)),
		"checks": checks, "result": result, "geometry": geometry,
		"memberIds": fixture.members.duplicate(), "sourcePartCount": b.parts.size(), "sourceDigest": snapshot})
	return result


func _inspect_ready(fixture: Dictionary, result: Dictionary) -> Dictionary:
	if not result.get("transform") is Transform3D or not result.get("footprint") is Rect2 or not result.get("approach") is Rect2:
		return {"passed": false, "reason": "missing_transform_or_rectangles"}
	var b = fixture.blueprint
	var transform: Transform3D = result.transform
	var support = b.physical_parts_by_id.get(String(result.get("supportId", "")))
	if support == null or not fixture.policy.pavingPartIds.has(support.id):
		return {"passed": false, "reason": "support_not_in_policy"}
	var first := true
	var moved := AABB()
	for id in fixture.members:
		var part = b.physical_parts_by_id[id]
		var local_to_world: Transform3D = transform * Transform3D(Basis.from_euler(part.rotation), part.position)
		for x in [-0.5, 0.5]:
			for y in [-0.5, 0.5]:
				for z in [-0.5, 0.5]:
					var point: Vector3 = local_to_world * (part.size * Vector3(x, y, z))
					moved = AABB(point, Vector3.ZERO) if first else moved.expand(point)
					first = false
	var actual := Rect2(Vector2(moved.position.x, moved.position.z), Vector2(moved.size.x, moved.size.z))
	var footprint: Rect2 = result.footprint
	var approach: Rect2 = result.approach
	var floor_y: float = support.position.y + support.size.y * 0.5
	# API requires the entire approach on the SAME selected paving, not a
	# union that could conceal an unsupported seam or change of elevation.
	var support_rect := Rect2(Vector2(support.position.x - support.size.x * 0.5, support.position.z - support.size.z * 0.5), Vector2(support.size.x, support.size.z))
	var surfaces: Array = [support_rect.grow(-float(fixture.policy.clearance))]
	var front: Vector3 = transform.basis * (fixture.policy.front as Vector3)
	var front_xz := Vector2(front.x, front.z)
	var checks := {"properRigidBasis": transform.basis.is_equal_approx(transform.basis.orthonormalized()) and absf(transform.basis.determinant() - 1.0) <= EPS,
		"footprintMatchesAllTransformedMembers": actual.position.is_equal_approx(footprint.position) and actual.size.is_equal_approx(footprint.size),
		"householdBottomOnSupport": absf(moved.position.y - floor_y) <= EPS,
		"completeFootprintOnSelectedPaving": _rect_covered(footprint, surfaces),
		"completeApproachOnSameSelectedPaving": _rect_covered(approach, surfaces),
		"approachFacesDeclaredFront": (approach.get_center() - footprint.get_center()).dot(front_xz) > 0.0,
		"approachHasPolicyDimensions": absf(approach.get_area() - float(fixture.policy.approachLength) * float(fixture.policy.approachWidth)) <= EPS}
	return {"passed": checks.values().all(func(value): return bool(value)), "checks": checks, "derivedFootprint": actual}


func _rect_covered(rect: Rect2, surfaces: Array) -> bool:
	if not rect.position.is_finite() or not rect.size.is_finite() or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return false
	# Exact rectangular partition check, not sparse center/edge sampling.
	var xs: Array = [rect.position.x, rect.end.x]
	var zs: Array = [rect.position.y, rect.end.y]
	for surface in surfaces:
		for value in [surface.position.x, surface.end.x]:
			if value > rect.position.x and value < rect.end.x:
				xs.append(value)
		for value in [surface.position.y, surface.end.y]:
			if value > rect.position.y and value < rect.end.y:
				zs.append(value)
	xs.sort()
	zs.sort()
	for x in range(xs.size() - 1):
		for z in range(zs.size() - 1):
			if float(xs[x + 1]) - float(xs[x]) <= EPS or float(zs[z + 1]) - float(zs[z]) <= EPS:
				continue
			var point := Vector2((float(xs[x]) + float(xs[x + 1])) * 0.5, (float(zs[z]) + float(zs[z + 1])) * 0.5)
			if not surfaces.any(func(surface: Rect2): return surface.has_point(point)):
				return false
	return true


func _reordering_cases() -> void:
	var fixture := _fixture("reordering")
	_paving(fixture, "west", Vector2(-10.0, 0.0), Vector2(14.0, 12.0))
	_paving(fixture, "east", Vector2(10.0, 0.0), Vector2(14.0, 12.0))
	fixture.policy.reservedFootprints = [Rect2(60.0, 60.0, 2.0, 2.0), Rect2(-60.0, -60.0, 2.0, 2.0)]
	fixture.blueprint.rooms = [{"id": "far_one", "role": "shop", "bounds": AABB(Vector3(70, 1, 70), Vector3(2, 3, 2))},
		{"id": "far_two", "role": "shop", "bounds": AABB(Vector3(-70, 1, -70), Vector3(2, 3, 2))}]
	var baseline := _exercise("determinism_baseline", fixture, true)
	var repeated := _exercise("determinism_repeat", fixture, true)
	fixture.blueprint.parts.reverse()
	fixture.blueprint.rooms.reverse()
	fixture.policy.pavingPartIds.reverse()
	fixture.policy.reservedFootprints.reverse()
	fixture.members.reverse()
	var reordered := _exercise("determinism_all_input_orders_reversed", fixture, true)
	_rows.append({"id": "decision_determinism", "passed": _digest(_decision(baseline)) == _digest(_decision(repeated)) and _digest(_decision(baseline)) == _digest(_decision(reordered)),
		"comparison": "Exact public placement decision only; excludes telemetry whose work count may legitimately differ.",
		"baseline": _decision(baseline), "repeated": _decision(repeated), "reordered": _decision(reordered)})


func _decision(result: Dictionary) -> Dictionary:
	return {"ready": result.get("ready", false), "reason": result.get("reason", ""),
		"transform": result.get("transform"), "supportId": result.get("supportId"),
		"footprint": result.get("footprint"), "approach": result.get("approach")}


func _nearest_first_precision_cases() -> void:
	# Public plan() versus an unpruned exhaustive oracle on intentionally small,
	# empty single-paving fixtures. No private planner helper or alternate planner
	# flag is used. Keep the production 0.25 lattice and preference order exactly.
	var case_index := 0
	for elevation in [0.0, 0.3, -0.3, 1.3, 1024.3]:
		for symmetric_z in [false, true]:
			for origin in [Vector2.ZERO, Vector2(0.3, -0.3), Vector2(-0.3, 0.3)]:
				var fixture := _precision_fixture(origin, elevation, symmetric_z)
				var expected := _precision_exhaustive(fixture)
				var actual := _exercise("nearest_precision_%02d" % case_index, fixture, true)
				var row: Dictionary = _rows.back()
				row.checks["exhaustiveEnumerationHasPlacement"] = bool(expected.get("ready", false))
				row.checks["exactRankAndTieDecisionMatchesExhaustive"] = _digest(_precision_decision(actual)) == _digest(_precision_decision(expected))
				row.checks["quarterTurnPreferenceUnchanged"] = int(actual.get("quarterTurn", -1)) == 0
				row.checks["quarterMetreLatticeUnchanged"] = fixture.policy.gridStep == 0.25
				row.checks["withinUnchangedBudgets"] = int(actual.get("visitedCandidates", 500001)) <= 500000 and int(actual.get("workUpperBound", 5000001)) <= 5000000
				# The nearest-first walk visits +0.125 first. At elevation 0.3 the
				# OLD scalar row bound exceeds the vector rank and discards -0.125,
				# although it is an exact rank tie with preferred smaller grid X.
				if origin == Vector2.ZERO and elevation == 0.3 and not symmetric_z:
					row.checks["preferredNegativeXSurvivesElevationRounding"] = actual.get("layoutCenter") == Vector2(-0.125, 0.0)
					var dy: float = Vector3(0, elevation, 0).y
					row["oldScalarBoundWitness"] = 0.125 * 0.125 + dy * dy
					row["vectorRankWitness"] = Vector3(0.125, elevation, 0).length_squared()
				row["exhaustiveDecision"] = _precision_decision(expected)
				row["enumeratedGridCandidates"] = expected.get("enumeratedGridCandidates", 0)
				row["exhaustiveLegalCandidates"] = expected.get("legalCandidates", 0)
				row["precisionFixture"] = {"origin": origin, "elevation": elevation, "symmetricZ": symmetric_z}
				row.passed = row.checks.values().all(func(value): return bool(value))
				case_index += 1
	_rows.append({"id": "nearest_precision_exhaustive_matrix_complete", "passed": case_index == 30})


func _precision_fixture(origin: Vector2, elevation: float, symmetric_z: bool) -> Dictionary:
	var b = Blueprint.new("synthetic_nearest_precision", 101, "timber")
	var body = _part(b, "household", "decor", Vector3(origin.x, 0.5, origin.y), Vector3(0.5, 1.0, 0.5), false)
	var fixture := {"blueprint": b, "members": [body.id], "policy": {"pavingPartIds": [],
		"reservedFootprints": [], "front": Vector3.FORWARD, "searchRadius": 8.0,
		"clearance": 0.125, "circulation": 0.125, "approachLength": 0.25,
		"approachWidth": 0.25, "approachHeight": 2.0, "gridStep": 0.25}}
	# At zero origin, X centres straddle zero at +/-0.125. Z either includes
	# zero exactly or straddles it too. Nonbinary origins exercise coordinate
	# rounding separately from nonbinary standing-height/rank rounding.
	_paving(fixture, "paving", origin + Vector2(0, 0.0 if symmetric_z else 0.125), Vector2(6, 6))
	var paving = b.physical_parts_by_id.paving
	paving.position.y = elevation - 0.125
	paving.size.y = 0.25
	return fixture


func _precision_exhaustive(fixture: Dictionary) -> Dictionary:
	# Deliberately narrow independent oracle: ONE axis-aligned square member and
	# ONE empty rectangular paving, no rooms/reservations/other obstacles. It
	# enumerates every lattice cell in ordinary X/Z order for every orientation,
	# tests geometry BEFORE ranking, then reduces all legal candidates by the
	# documented lexicographic preference. No row bounds or nearest-first walk.
	var b = fixture.blueprint
	if b.parts.size() != 2 or fixture.members.size() != 1 or fixture.policy.pavingPartIds.size() != 1 or not b.rooms.is_empty() or not fixture.policy.reservedFootprints.is_empty():
		return {"ready": false, "reason": "unsupported_precision_oracle_fixture"}
	var body = b.physical_parts_by_id[fixture.members[0]]
	var paving = b.physical_parts_by_id[fixture.policy.pavingPartIds[0]]
	if body.rotation != Vector3.ZERO or paving.rotation != Vector3.ZERO or body.size.x != body.size.z or fixture.policy.front != Vector3.FORWARD:
		return {"ready": false, "reason": "unsupported_precision_oracle_shape"}
	# Axis-aligned corner construction retains the source Vector3 arithmetic
	# used to represent the bounds, without calling any planner geometry helper.
	var body_bounds := AABB(body.position - body.size * 0.5, Vector3.ZERO).expand(body.position + body.size * 0.5)
	var paving_bounds := AABB(paving.position - paving.size * 0.5, Vector3.ZERO).expand(paving.position + paving.size * 0.5)
	var pivot := Vector3(body_bounds.get_center().x, body_bounds.position.y, body_bounds.get_center().z)
	var old_center := Vector2(pivot.x, pivot.z)
	var floor_y: float = paving_bounds.end.y
	var allowed := Rect2(Vector2(paving_bounds.position.x, paving_bounds.position.z), Vector2(paving_bounds.size.x, paving_bounds.size.z)).grow(-float(fixture.policy.clearance))
	var size := Vector2(body_bounds.size.x, body_bounds.size.z)
	var half := size * 0.5
	var radius: float = fixture.policy.searchRadius
	var step: float = fixture.policy.gridStep
	var minimum := (allowed.position + half).max(old_center - Vector2.ONE * radius)
	var maximum := (allowed.end - half).min(old_center + Vector2.ONE * radius)
	var nx := int(floorf((maximum.x - minimum.x) / step) + 1.0)
	var nz := int(floorf((maximum.y - minimum.y) / step) + 1.0)
	if nx <= 0 or nz <= 0 or nx * nz * 4 > 10000:
		return {"ready": false, "reason": "precision_oracle_grid_bound"}
	var legal: Array = []
	var enumerated := 0
	var headings: Array[Vector2] = [Vector2.UP, Vector2.LEFT, Vector2.DOWN, Vector2.RIGHT]
	for quarter in range(4):
		var heading: Vector2 = headings[quarter]
		for ix in range(nx):
			for iz in range(nz):
				enumerated += 1
				var center := minimum + Vector2(ix, iz) * step
				if center.distance_squared_to(old_center) > radius * radius:
					continue
				var area := Rect2(center - half, size)
				var corridor_size := Vector2(fixture.policy.approachLength, fixture.policy.approachWidth) if heading.x != 0 else Vector2(fixture.policy.approachWidth, fixture.policy.approachLength)
				var edge := area.get_center() + heading * (size.x * 0.5 if heading.x != 0 else size.y * 0.5)
				var approach := Rect2(edge + heading * float(fixture.policy.approachLength) * 0.5 - corridor_size * 0.5, corridor_size)
				var circulation := area.grow(float(fixture.policy.circulation))
				if not allowed.encloses(circulation) or not allowed.encloses(approach):
					continue
				var target := Vector3(center.x, floor_y, center.y)
				legal.append({"ready": true, "supportId": paving.id, "quarterTurn": quarter,
					"layoutCenter": center, "standingY": floor_y, "distanceSquared": target.distance_squared_to(pivot),
					"footprint": area, "approach": approach, "circulationFootprint": circulation})
	var best: Dictionary = {}
	for candidate in legal:
		if best.is_empty() or _precision_lexicographic_less(candidate, best):
			best = candidate
	best["enumeratedGridCandidates"] = enumerated
	best["legalCandidates"] = legal.size()
	return best


func _precision_lexicographic_less(candidate: Dictionary, best: Dictionary) -> bool:
	var a: Array = [candidate.distanceSquared, candidate.supportId, candidate.quarterTurn, candidate.layoutCenter.x, candidate.layoutCenter.y]
	var b: Array = [best.distanceSquared, best.supportId, best.quarterTurn, best.layoutCenter.x, best.layoutCenter.y]
	for index in range(a.size()):
		if a[index] != b[index]:
			return a[index] < b[index]
	return false


func _precision_decision(result: Dictionary) -> Dictionary:
	return {"ready": result.get("ready", false), "supportId": result.get("supportId"),
		"quarterTurn": result.get("quarterTurn"), "layoutCenter": result.get("layoutCenter"),
		"standingY": result.get("standingY"), "distanceSquared": result.get("distanceSquared"),
		"footprint": result.get("footprint"), "approach": result.get("approach"),
		"circulationFootprint": result.get("circulationFootprint")}


func _reconstructed_endpoint_helper_case() -> void:
	# Synthetic helper regression, NOT a public plan() winner or placement claim.
	# These are already-stored poses. The production finalist uses this SAME
	# endpoint helper; Blueprint independently supplies the containment oracle.
	var b = Blueprint.new("synthetic_reconstructed_endpoint_helper", 101, "timber")
	var a = _part(b, "angled", "decor", Vector3(0.959, 2, 0), Vector3(19.13, 0.25, 7.3), false)
	a.rotation = Vector3(0, 2.1, -0.4)
	_part(b, "left_extent", "decor", Vector3(-6.625, 2, 0), Vector3(1, 0.25, 1), false)
	var before := _digest(b.snapshot())
	var old_min := Vector2(INF, INF)
	var old_max := Vector2(-INF, -INF)
	var corrected_min := Vector2(INF, INF)
	var corrected_max := Vector2(-INF, -INF)
	var a_expanded := AABB()
	var a_actual_max := -INF
	for part in b.parts:
		var stored: Transform3D = b.part_transform(part)
		var expanded: AABB = _planner._bounds(stored, part.size)
		var endpoints: Array[Vector2] = _planner._represented_part_endpoints(stored, part.size, expanded)
		corrected_min = corrected_min.min(endpoints[0])
		corrected_max = corrected_max.max(endpoints[1])
		old_min = old_min.min(Vector2(expanded.position.x, expanded.position.z))
		old_max = old_max.max(Vector2(expanded.end.x, expanded.end.z))
		# Deliberately retain the prior corner+expanded-end accumulation as the
		# negative control. No reconstructed Blueprint end is added to this path.
		for x in [-1.0, 1.0]:
			for y in [-1.0, 1.0]:
				for z in [-1.0, 1.0]:
					var corner: Vector3 = stored * (part.size * Vector3(x, y, z) * 0.5)
					old_min = old_min.min(Vector2(corner.x, corner.z))
					old_max = old_max.max(Vector2(corner.x, corner.z))
					if part == a: a_actual_max = maxf(a_actual_max, corner.x)
		if part == a: a_expanded = expanded
	var old_rect: Rect2 = _planner._represented_rect(old_min, old_max)
	var corrected: Rect2 = _planner._represented_rect(corrected_min, corrected_max)
	var a_blueprint: AABB = b.transformed_part_bounds(a)
	var contains_all := true
	for part in b.parts:
		var bounds: AABB = b.transformed_part_bounds(part)
		contains_all = contains_all and _stored_rect_contains(corrected, Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.end.x, bounds.end.z))
	var checks := {"exactActualMaximumReproduced": a_actual_max == 8.581955909729004,
		"exactExpandedEndReproduced": a_expanded.end.x == 8.581954956054688,
		"exactBlueprintEndReproduced": a_blueprint.end.x == 8.58195686340332,
		"exactOldAggregateEndReproduced": old_rect.end.x == 8.581955909729004,
		"oldCornerOnlyMaximumMissesBlueprintEnd": old_rect.end.x < a_blueprint.end.x,
		"correctedHelperIncludesBlueprintEnd": corrected_max.x >= a_blueprint.end.x,
		"correctedRectContainsEveryBlueprintBoundsExactly": contains_all,
		"sourceUnchanged": before == _digest(b.snapshot())}
	_rows.append({"id": "reconstructed_per_part_endpoint_synthetic_helper", "evidenceLevel": "synthetic_private_geometry_helper_regression",
		"passed": checks.values().all(func(value): return bool(value)), "checks": checks,
		"inputs": b.parts.map(func(part): return {"id": part.id, "position": part.position, "size": part.size, "rotation": part.rotation}),
		"actualCornerMaxX": a_actual_max, "expandedBounds": a_expanded, "blueprintBounds": a_blueprint,
		"oldAggregate": old_rect, "correctedAggregate": corrected,
		"doesNotProve": "Direct private helper isolation, not a public planner placement, scene publication, physics or live acceptance. Public stored-pose contracts remain separate and strict."})


func _stored_pose_containment_cases() -> void:
	# Independent of the planner's ideal rotated AABB and its private helpers.
	# Exercise nonbinary source positions, asymmetric/tilted cloth and the Euler
	# fields actually stored by callers. Existing approximate checks stay intact.
	var cases := 0
	for origin in [Vector3(0.3, 0, -0.7), Vector3(23.173, 0.3, -17.619), Vector3(-31.413, 1.125, 26.287)]:
		for source_quarter in range(4):
			for strip_along_x in [true, false]:
				var fixture := _stored_pose_fixture(origin, source_quarter, strip_along_x)
				var label := "stored_pose_%02d" % cases
				var baseline := _exercise(label, fixture, true, "pose_paving")
				var repeated: Dictionary = _planner.plan(fixture.blueprint, fixture.members, fixture.policy)
				var before := _digest(fixture.blueprint.snapshot())
				fixture.blueprint.parts.reverse()
				fixture.members.reverse()
				var reversed_before := _digest(fixture.blueprint.snapshot())
				var reordered: Dictionary = _planner.plan(fixture.blueprint, fixture.members, fixture.policy)
				var reversed_preserved: bool = reversed_before == _digest(fixture.blueprint.snapshot())
				fixture.blueprint.parts.reverse()
				fixture.members.reverse()
				var check := _stored_pose_inspection(fixture, baseline)
				var reverse_check := _stored_pose_inspection(fixture, reordered)
				var deterministic: bool = _digest(_stored_pose_decision(baseline)) == _digest(_stored_pose_decision(repeated)) and _digest(_stored_pose_decision(baseline)) == _digest(_stored_pose_decision(reordered))
				_rows.append({"id": label + "_exact_stored_record_containment", "passed": bool(check.passed) and bool(reverse_check.passed) and deterministic and reversed_preserved and before == _digest(fixture.blueprint.snapshot()),
					"origin": origin, "sourceQuarter": source_quarter, "stripAlongX": strip_along_x,
					"inspection": check, "reversedInspection": reverse_check, "exactDecisionDeterminism": deterministic,
					"sourcePreserved": reversed_preserved and before == _digest(fixture.blueprint.snapshot()),
					"comparison": "Inclusive scalar comparisons, no epsilon; private actual stored records, not ideal transform bounds. Decision excludes work/time telemetry and caller member-ID ordering."})
				cases += 1
	_rows.append({"id": "stored_pose_matrix_complete", "passed": cases == 24, "caseCount": cases})


func _stored_pose_fixture(origin: Vector3, quarter: int, strip_along_x: bool) -> Dictionary:
	var b = Blueprint.new("synthetic_stored_pose", 101, "timber")
	var turn := Basis.IDENTITY
	match quarter:
		1: turn = Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
		2: turn = Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3(0, 0, -1))
		3: turn = Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(-1, 0, 0))
	var source_pose := Transform3D(turn, origin)
	var ids: Array = []
	var specs: Array = [
		{"id": "asymmetric_body", "kind": "decor", "position": Vector3(-0.217, 1.63, 0.139), "size": Vector3(3.173, 1.26, 2.317), "rotation": Vector3.ZERO},
		{"id": "offset_storage", "kind": "decor", "position": Vector3(-1.437, 1.39, -0.863), "size": Vector3(0.617, 0.78, 0.913), "rotation": Vector3(0, 0.173, 0)},
		{"id": "last_cloth", "kind": "decor", "position": Vector3(0.437, 2.713, 0.463), "size": Vector3(4.113, 0.043, 2.017), "rotation": Vector3(-0.163, 0.071, 0.019)}]
	for spec in specs:
		var pose: Transform3D = source_pose * Transform3D(Basis.from_euler(spec.rotation), spec.position)
		var part = _part(b, spec.id, spec.kind, pose.origin, spec.size, false)
		part.rotation = pose.basis.get_euler()
		ids.append(part.id)
	var fixture := {"blueprint": b, "members": ids, "policy": {"pavingPartIds": [], "reservedFootprints": [],
		"front": turn * Vector3.FORWARD, "searchRadius": 12.0, "clearance": 0.1, "circulation": 0.8,
		"approachLength": 3.8, "approachWidth": 1.8, "gridStep": 0.25}}
	_paving(fixture, "pose_paving", Vector2(origin.x + 0.137, origin.z - 0.219), Vector2(18, 7) if strip_along_x else Vector2(7, 18))
	# Finite reservations outside this support still exercise the fixed-source
	# contract without inventing a forced answer or changing the search budget.
	fixture.policy.reservedFootprints = [Rect2(Vector2(origin.x + 12, origin.z + 12), Vector2(1.17, 2.31))]
	return fixture


func _stored_pose_inspection(fixture: Dictionary, result: Dictionary) -> Dictionary:
	if not result.get("ready", false) or not result.get("transform") is Transform3D or not result.get("footprint") is Rect2 or not result.get("circulationFootprint") is Rect2 or not result.get("approach") is Rect2:
		return {"passed": false, "reason": "stored_pose_requires_ready_rectangles"}
	var b = fixture.blueprint
	var staged = Blueprint.new("private_stored_pose_observation", 101, "timber")
	var footprint: Rect2 = result.footprint
	var circulation: Rect2 = result.circulationFootprint
	var approach: Rect2 = result.approach
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var corners: Array[Vector2] = []
	var misses: Array = []
	var bounds_contained := true
	for id in fixture.members:
		var source = b.physical_parts_by_id[id]
		var posed: Transform3D = result.transform * Transform3D(Basis.from_euler(source.rotation), source.position)
		var copy = staged.add_part(source.snapshot())
		copy.physical_intent = source.physical_intent
		copy.position = posed.origin
		copy.rotation = posed.basis.get_euler()
		# Use actual BuildingBlueprint source-bound semantics independently of
		# Layout._bounds/_xz, and also compare every raw transformed corner.
		var bounds: AABB = staged.transformed_part_bounds(copy)
		bounds_contained = bounds_contained and _stored_rect_contains(footprint, Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.end.x, bounds.end.z))
		var stored := Transform3D(Basis.from_euler(copy.rotation), copy.position)
		for x in [-1.0, 1.0]:
			for y in [-1.0, 1.0]:
				for z in [-1.0, 1.0]:
					var world: Vector3 = stored * (copy.size * Vector3(x, y, z) * 0.5)
					var xz := Vector2(world.x, world.z)
					corners.append(xz)
					minimum = minimum.min(xz)
					maximum = maximum.max(xz)
					if not _stored_rect_contains(footprint, xz, xz) and misses.size() < 8:
						misses.append({"partId": id, "corner": xz})
	var support = b.physical_parts_by_id[result.supportId]
	var support_bounds: AABB = b.transformed_part_bounds(support)
	var allowed := Rect2(Vector2(support_bounds.position.x, support_bounds.position.z), Vector2(support_bounds.size.x, support_bounds.size.z)).grow(-float(fixture.policy.clearance))
	var checks := {"everyStoredCornerInsideReportedFootprintExactly": misses.is_empty(),
		"everyBlueprintStoredBoundsInsideReportedFootprintExactly": bounds_contained,
		"reportedCirculationContainsStoredFootprintExactly": _stored_rect_contains(circulation, minimum, maximum),
		"footprintOnSameSupportExactly": _stored_rect_contains(allowed, footprint.position, footprint.end),
		"circulationOnSameSupportExactly": _stored_rect_contains(allowed, circulation.position, circulation.end),
		"approachOnSameSupportExactly": _stored_rect_contains(allowed, approach.position, approach.end),
		"unchangedGridAndBudgets": fixture.policy.gridStep == 0.25 and int(result.get("visitedCandidates", 500001)) <= 500000 and int(result.get("workUpperBound", 5000001)) <= 5000000}
	for rect in [footprint, circulation, approach]:
		for reservation in fixture.policy.reservedFootprints:
			checks["reservationSeparation_%d" % checks.size()] = not (rect.position.x < reservation.end.x and reservation.position.x < rect.end.x and rect.position.y < reservation.end.y and reservation.position.y < rect.end.y)
	# Negative controls move each actual extreme inward by ONE represented
	# float32 step. No EPS, rounded equality or sparse sample may hide it.
	for axis in range(2):
		for lower in [true, false]:
			var inner_min := minimum
			var inner_max := maximum
			if lower: inner_min[axis] = _stored_next_float(minimum[axis], true)
			else: inner_max[axis] = _stored_next_float(maximum[axis], false)
			var catches := false
			for corner in corners:
				catches = catches or corner.x < inner_min.x or corner.y < inner_min.y or corner.x > inner_max.x or corner.y > inner_max.y
			checks["oneFloatStepEscapeDetected_%d_%s" % [axis, str(lower)]] = catches
	return {"passed": checks.values().all(func(value): return bool(value)), "checks": checks,
		"storedMinimum": minimum, "storedMaximum": maximum, "reportedFootprint": footprint, "misses": misses, "cornerCount": corners.size()}


func _stored_rect_contains(rect: Rect2, minimum: Vector2, maximum: Vector2) -> bool:
	return minimum.x >= rect.position.x and minimum.y >= rect.position.y and maximum.x <= rect.end.x and maximum.y <= rect.end.y


func _stored_next_float(value: float, toward_positive: bool) -> float:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	var bits := bytes.decode_u32(0)
	if value == 0.0:
		bits = 1 if toward_positive else 0x80000001
	else:
		bits += 1 if (value > 0.0) == toward_positive else -1
	bytes.encode_u32(0, bits)
	return bytes.decode_float(0)


func _stored_pose_decision(result: Dictionary) -> Dictionary:
	var decision := _precision_decision(result)
	decision["transform"] = result.get("transform")
	return decision


func _digest(value: Variant) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()


func _json(value: Variant) -> Variant:
	if value is Transform3D:
		return {"origin": _json(value.origin), "basis": [_json(value.basis.x), _json(value.basis.y), _json(value.basis.z)]}
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return [value.x, value.y]
	if value is Rect2 or value is AABB:
		return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _json(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json(item))
	return value


func _finish(started: int, status: String) -> void:
	var passed := status == "contract_complete" and not _rows.is_empty() and _rows.all(func(row): return bool(row.passed))
	var report := {"evidenceLevel": "synthetic_generic_recipe_planner_contract", "status": status, "passed": passed,
		"planner": PLANNER, "caseCount": _rows.size(), "cases": _rows, "elapsedMsec": Time.get_ticks_msec() - started,
		"doesNotProve": "No frozen-candidate acceptance, production integration, publisher meshes/materials, live physics, doors, actors, NPC navigation, or gameplay. Public fixtures invoke the real planner; the separately labeled reconstructed-endpoint case invokes private geometry helpers only. Support checks cover synthetic axis-aligned paving rectangles; no performance or universal packing claim."}
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot create synthetic layout report")
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("VOXEL_RIGID_HOUSEHOLD_LAYOUT_REPORT ", _path, " status=", status)
	quit(2 if error != OK else (0 if passed else 1))
