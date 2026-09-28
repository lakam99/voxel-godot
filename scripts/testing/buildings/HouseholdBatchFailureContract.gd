extends SceneTree

## Callback/unit failure propagation plus synthetic-geometry source-service
## placement through the real Batch -> Layout path. Neither is gameplay proof.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Batch = preload("res://scripts/buildings/HouseholdLayoutBatchRecipe.gd")
const Layout = preload("res://scripts/buildings/RigidHouseholdLayoutRecipe.gd")
const Furnishing = preload("res://scripts/buildings/FurnishingPlan.gd")
const Shops = preload("res://scripts/buildings/CitadelShopRecipe.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_HOUSEHOLD_BATCH_FAILURE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path):
		quit(2)
		return
	var b = Blueprint.new("synthetic_batch", 1, "timber")
	for id in ["a", "b"]:
		b.add_part({"id": id, "position": Vector3.ZERO, "size": Vector3.ONE, "kind": "beam"})
	var before := var_to_bytes(b.snapshot())
	var groups: Array = [{"memberIds": ["a"], "front": Vector3.FORWARD}, {"memberIds": ["b"], "front": Vector3.FORWARD}]
	var checks: Array = []
	for reason in ["work_limit_exceeded", "candidate_limit_exceeded", "invalid_room_bounds", "unknown_failure"]:
		var calls := [0]
		var callback := func(_source, _ids, _front, _reservations):
			calls[0] += 1
			return {"ready": false, "reason": reason if calls[0] == 1 else "no_recipe_placement"}
		var result: Dictionary = Batch.plan(b, groups, callback)
		checks.append({"name": reason + "_retained_without_retry", "passed": not result.ready and result.reason == reason and calls[0] == 1 and result.plannerCalls == 1 and not result.has("households")})
	var calls := [0]
	var incomplete_after_no_fit := func(_source, _ids, _front, _reservations):
		calls[0] += 1
		return {"ready": false, "reason": "no_recipe_placement" if calls[0] == 1 else "work_limit_exceeded"}
	var incomplete: Dictionary = Batch.plan(b, groups, incomplete_after_no_fit)
	checks.append({"name": "later_incomplete_stops_and_preserves_reason", "passed": incomplete.reason == "work_limit_exceeded" and calls[0] == 2 and incomplete.orderAttempts == 2 and incomplete.plannerCalls == 2})
	var malformed: Dictionary = Batch.plan(b, groups, func(_s, _i, _f, _r): return {"ready": true})
	checks.append({"name": "malformed_ready_is_not_no_fit", "passed": not malformed.ready and malformed.reason == "invalid_ready_planner_result" and malformed.plannerCalls == 1})
	var no_fit: Dictionary = Batch.plan(b, groups, func(_s, _i, _f, _r): return {"ready": false, "reason": "no_recipe_placement"})
	checks.append({"name": "completed_no_fit_orders_are_bounded", "passed": no_fit.reason == "bounded_order_search_exhausted" and no_fit.plannerCalls == 4 and no_fit.orderAttempts == 4 and no_fit.maximumPlannerCalls == 128})
	checks.append({"name": "all_failures_preserve_source", "passed": before == var_to_bytes(b.snapshot())})
	var fixed: Array[Rect2] = [Rect2(10, 12, 3, 4)]
	var fixed_bytes := var_to_bytes(fixed)
	var seen_fixed := [true, 0]
	var fixed_callback := func(_s, _i, _f, reservations):
		seen_fixed[0] = seen_fixed[0] and reservations.has(fixed[0])
		seen_fixed[1] += 1
		return {"ready": false, "reason": "no_recipe_placement"}
	var fixed_result: Dictionary = Batch.plan(b, groups, fixed_callback, fixed)
	checks.append({"name": "fixed_furniture_retained_for_every_order", "passed": not fixed_result.ready and seen_fixed[0] and seen_fixed[1] == 4 and var_to_bytes(fixed) == fixed_bytes})
	var invalid_fixed: Array[Rect2] = [Rect2(0, 0, 0, 1)]
	var invalid_reservations: Dictionary = Batch.plan(b, groups, fixed_callback, invalid_fixed)
	checks.append({"name": "invalid_fixed_reservation_rejected", "passed": not invalid_reservations.ready and invalid_reservations.reason == "invalid_fixed_reservations" and seen_fixed[1] == 4})
	var geometry := _real_geometry_reservation_case()
	var spatial_budget := _spatial_index_budget_case()
	var passed: bool = checks.all(func(row): return row.passed) and bool(geometry.get("passed", false)) and bool(spatial_budget.get("passed", false))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify({"passed": passed, "checks": checks, "callbackEvidenceLevel": "synthetic_callback_unit_contract", "geometryReservation": geometry, "spatialIndexBudget": spatial_budget, "evidenceLevel": "synthetic_unit_and_geometry_source_service_contract", "doesNotProve": "Geometry case uses real placement services on synthetic paving/household/furniture volumes. No generated-citadel acceptance, publication, visuals, live physics, navigation or gameplay."}, "\t"))
	file.close()
	quit(0 if passed else 1)


func _spatial_index_budget_case() -> Dictionary:
	var influence := Rect2(-8.0, -8.0, 16.0, 16.0)
	var huge := Rect2(-1.0e20, -1.0e20, 2.0e20, 2.0e20)
	var huge_rectangles: Array[Rect2] = [huge]
	var exact_meter := {"used":0, "remaining":Layout.MAX_WORK}
	var exact := Layout._spatial_index(huge_rectangles, influence, exact_meter)
	var constrained_meter := {"used":0, "remaining":4}
	var constrained := Layout._spatial_index(huge_rectangles, influence, constrained_meter)
	var query_meter := {"used":0, "remaining":1}
	var query := Layout._spatial_candidates(exact, influence, query_meter)
	var checks := {
		"huge_source_is_clipped_to_bounded_influence": exact.get("ready", false) and (exact.get("cells", {}) as Dictionary).size() <= 25 and int(exact_meter.used) <= Layout.MAX_WORK,
		"index_allocation_is_preflight_rejected_by_work_budget": not constrained.get("ready", true) and constrained.get("reason") == "work_limit_exceeded" and constrained_meter.get("exhausted", false),
		"cell_lookup_and_candidate_collection_are_metered": query.is_empty() and query_meter.get("exhausted", false) and int(query_meter.used) > int(query_meter.remaining)}
	return {"passed":checks.values().all(func(value):return bool(value)), "checks":checks,
		"exactMeter":exact_meter, "constrainedMeter":constrained_meter, "queryMeter":query_meter}


func _geometry_source(with_alternate: bool):
	var source = Blueprint.new("synthetic_fixed_furnishing_geometry", 1, "timber")
	source.add_part({"id": "paving_primary", "kind": "foundation", "material": "cobblestone", "position": Vector3(0, -0.2, 0), "size": Vector3(8, 0.4, 8), "collision": true, "semantic": "synthetic_public_paving"})
	if with_alternate:
		source.add_part({"id": "paving_alternate", "kind": "foundation", "material": "cobblestone", "position": Vector3(12, -0.2, 0), "size": Vector3(8, 0.4, 8), "collision": true, "semantic": "synthetic_public_paving"})
	# Multiple members, including contents and seating: all travel as one group.
	source.add_part({"id": "household_counter", "kind": "beam", "material": "timber_board", "position": Vector3(0, 0.5, 0), "size": Vector3.ONE, "collision": true, "semantic": "synthetic_household"})
	source.add_part({"id": "household_goods", "kind": "crate", "material": "timber_board", "position": Vector3(0, 1.2, 0), "size": Vector3(0.4, 0.4, 0.4), "collision": false, "semantic": "synthetic_household"})
	source.add_part({"id": "household_bench", "kind": "beam", "material": "timber_board", "position": Vector3(1, 0.25, 0), "size": Vector3(0.5, 0.5, 0.5), "collision": true, "semantic": "synthetic_household"})
	return source


func _real_geometry_reservation_case() -> Dictionary:
	var row := {"passed": false, "evidenceLevel": "synthetic_geometry_real_source_service", "checks": {}}
	var source = _geometry_source(false)
	var expanded = _geometry_source(true)
	var source_bytes := var_to_bytes(source.snapshot())
	var expanded_bytes := var_to_bytes(expanded.snapshot())
	var ids: Array = source.parts.filter(func(part): return part.semantic == "synthetic_household").map(func(part): return part.id)
	var groups: Array = [{"memberIds": ids, "front": Vector3.FORWARD}]
	var groups_bytes := var_to_bytes(groups)
	var furnishing = Furnishing.new("synthetic_fixed_furniture", 1, source.id)
	# An intentionally large synthetic occupied furnishing volume covers the
	# only original paving. It is NOT inserted as a BuildingPart obstacle: the
	# production furniture-to-fixed-reservation path must supply the exclusion.
	var primary = source.parts.filter(func(part): return part.semantic == "synthetic_public_paving")[0]
	var bounds: AABB = source.transformed_part_bounds(primary)
	var item = furnishing.add_part({"id": "synthetic_occupied_storage", "archetype": "shelf", "position": Vector3(primary.position.x, bounds.end.y, primary.position.z), "rotation": Vector3.ZERO, "occupiedSize": Vector3(bounds.size.x, 1.0, bounds.size.z), "collision": true})
	if item == null:
		row["reason"] = "synthetic_furnishing_setup_failed"
		return row
	var furniture_bytes := var_to_bytes(furnishing.snapshot())
	var access_bytes := var_to_bytes(furnishing.protected_access_reservations)
	var derived: Dictionary = Shops.furnishing_obstacles(furnishing.snapshot(), furnishing.protected_access_reservations)
	if not derived.ready:
		row["reason"] = "actual_furnishing_obstacle_conversion_failed"
		row["detail"] = derived
		return row
	var fixed: Array[Rect2] = []
	for obstacle in derived.obstacles:
		var occupied: AABB = obstacle.bounds
		fixed.append(Rect2(Vector2(occupied.position.x, occupied.position.z), Vector2(occupied.size.x, occupied.size.z)))
	var fixed_bytes := var_to_bytes(fixed)
	row.checks["actual_furniture_projection_covers_primary"] = fixed.size() == 1 and fixed[0] == Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
	var trace: Array = []
	# Policy adapter only: every returned result is the real Layout.plan result.
	# No authored transform, canned success, or mocked planner acceptance.
	var planner := func(scratch, member_ids, front, reservations):
		var paving_ids: Array = scratch.parts.filter(func(part): return part.semantic == "synthetic_public_paving").map(func(part): return part.id)
		var policy := {"pavingPartIds": paving_ids, "front": front, "reservedFootprints": reservations, "searchRadius": 20.0, "clearance": 0.1, "circulation": 0.8, "approachLength": 1.5, "approachWidth": 1.0, "approachHeight": 2.0, "gridStep": 0.5}
		var before := var_to_bytes(scratch.snapshot())
		var policy_before := var_to_bytes(policy)
		var result: Dictionary = Layout.plan(scratch, member_ids, policy)
		trace.append({"ready": result.ready, "reason": result.get("reason", ""), "supportId": result.get("supportId", ""), "fixedCount": reservations.size(), "sourceUnchanged": before == var_to_bytes(scratch.snapshot()), "policyUnchanged": policy_before == var_to_bytes(policy), "workUpperBound": result.get("workUpperBound", 0)})
		return result
	var clear: Dictionary = Batch.plan(source, groups, planner)
	var blocked: Dictionary = Batch.plan(source, groups, planner, fixed)
	var expanded_clear: Dictionary = Batch.plan(expanded, groups, planner)
	var relocated: Dictionary = Batch.plan(expanded, groups, planner, fixed)
	row["withoutReservation"] = clear
	row["withReservationOnlyPrimary"] = blocked
	row["expandedWithoutReservation"] = expanded_clear
	row["expandedWithReservation"] = relocated
	row["plannerTrace"] = trace
	row["furnitureDerivedReservations"] = fixed
	row.checks["otherwise_placeable_on_primary"] = clear.ready and clear.households.size() == 1 and clear.households[0].supportId == primary.id
	row.checks["furniture_blocks_all_primary_candidates"] = not blocked.ready and blocked.get("reason") == "bounded_order_search_exhausted" and blocked.get("lastFailure", {}).get("reason") == "no_recipe_placement" and not blocked.has("households") and blocked.plannerCalls == 2
	row.checks["expanded_baseline_still_uses_primary"] = expanded_clear.ready and expanded_clear.households[0].supportId == primary.id
	row.checks["real_recipe_relocates_to_unreserved_paving"] = relocated.ready and relocated.households.size() == 1 and relocated.households[0].supportId != primary.id
	if relocated.ready:
		var decision: Dictionary = relocated.households[0]
		var support = expanded.parts.filter(func(part): return part.id == decision.supportId)[0]
		var support_bounds: AABB = expanded.transformed_part_bounds(support)
		var allowed := Rect2(Vector2(support_bounds.position.x, support_bounds.position.z), Vector2(support_bounds.size.x, support_bounds.size.z)).grow(-0.1)
		row.checks["whole_footprint_circulation_and_approach_avoid_furniture"] = fixed.all(func(rect): return not rect.intersects(decision.footprint) and not rect.intersects(decision.circulationFootprint) and not rect.intersects(decision.approach))
		row.checks["circulation_and_approach_supported_same_paving"] = allowed.encloses(decision.circulationFootprint) and allowed.encloses(decision.approach)
		var retained: Array = decision.memberIds.duplicate()
		var expected: Array = ids.duplicate()
		retained.sort()
		expected.sort()
		row.checks["complete_household_members_retained"] = retained == expected and retained.size() == 3
		row.checks["selected_pose_actually_changes"] = expanded_clear.ready and decision.transform != expanded_clear.households[0].transform
	row.checks["real_layout_calls_pure_and_bounded"] = trace.size() == clear.plannerCalls + blocked.plannerCalls + expanded_clear.plannerCalls + relocated.plannerCalls and trace.all(func(call): return call.sourceUnchanged and call.policyUnchanged and call.workUpperBound <= Layout.MAX_WORK)
	row.checks["all_source_and_furniture_bytes_unchanged"] = source_bytes == var_to_bytes(source.snapshot()) and expanded_bytes == var_to_bytes(expanded.snapshot()) and furniture_bytes == var_to_bytes(furnishing.snapshot()) and access_bytes == var_to_bytes(furnishing.protected_access_reservations) and fixed_bytes == var_to_bytes(fixed) and groups_bytes == var_to_bytes(groups)
	row["passed"] = row.checks.values().all(func(value): return bool(value))
	return row
