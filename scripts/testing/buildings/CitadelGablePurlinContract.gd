extends SceneTree

## SYNTHETIC source/geometry contract only. No scene, physics or visual acceptance.
## The builder/validator are production dependencies, never overridden here.
## VOXEL_GABLE_PURLIN_REPORT: writable JSON path (parent directory must exist).
## Append -- --positive-only for the first prototype; that does NOT run negatives.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Frame = preload("res://scripts/buildings/GablePurlinFrameBuilder.gd")
const InteriorProgram = preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const FurnishingPlanScript = preload("res://scripts/buildings/FurnishingPlan.gd")
const FRAME_ID := "house_gable_contract"
const PANEL_IDS := ["house_roof_left", "house_roof_right"]
const BEARER_IDS := ["house_upper_shell_side_-1", "house_upper_shell_side_1"]
const ROLES := ["gable_roof_panel", "gable_roof_purlin", "gable_roof_post"]

var _report_path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_report_path = OS.get_environment("VOXEL_GABLE_PURLIN_REPORT").strip_edges()
	if _report_path.is_empty():
		push_error("Set VOXEL_GABLE_PURLIN_REPORT for this synthetic contract")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var positive := _positive()
	var report := {
		"evidenceLevel": "synthetic_source_geometry_contract", "passed": false,
		"status": "positive_complete", "positive": positive, "negativeControls": [],
		"negativeControlsRun": false, "builder": "GablePurlinFrameBuilder.add_frame",
		"validator": "BuildingBlueprint.validate_physical_integrity",
		"fixture": {"prefix": "house", "center": Vector3(-7.321948, 0.0, -34.82368),
			"width": 8.648304, "depth": 9.45, "wallHeight": 6.2, "streetSide": 1.0,
			"groundY": 0.62, "material": "plaster_cream", "variation": 0.05},
		"doesNotProve": "Whole-house physical validity (known facade failures remain), rendered contact, published collision, gameplay/navigation, full-castle furniture, or engineering safety. Furniture coverage is original household records plus the real window-interior furnishing program."
	}
	# Publish the positive prototype before any negative experiment. A failure
	# here stops the suite instead of letting unrelated baseline failures count.
	if not bool(positive.get("passed", false)):
		report["status"] = "positive_failed"
		report["elapsedMsec"] = Time.get_ticks_msec() - started
		quit(1 if _write_report(report) else 2)
		return
	if OS.get_cmdline_user_args().has("--positive-only"):
		report["passed"] = true
		report["status"] = "positive_only_passed"
		report["elapsedMsec"] = Time.get_ticks_msec() - started
		quit(0 if _write_report(report) else 2)
		return
	if not _write_report(report):
		quit(2)
		return
	var cases: Array[Dictionary] = []
	for category in ["purlin", "post", "bearer"]:
		for mutation in ["missing", "moved", "duplicate_declaration", "duplicate_id"]:
			# A post has one named bearer, so the bearer duplicate-declaration
			# control duplicates its required seat rather than a nonexistent list.
			cases.append({"id": mutation + "_" + category, "mutation": mutation, "category": category})
	for category in ["panel", "purlin", "post"]:
		for mutation in ["missing_joint", "joint_outside_body", "visual_detail_bypass"]:
			cases.append({"id": mutation + "_" + category, "mutation": mutation, "category": category})
	for mutation in ["unrooted_support", "cyclic_support", "same_com_side", "malformed_member_array", "malformed_member_id", "malformed_joint_facts", "malformed_joint_vector", "nonfinite_joint"]:
		cases.append({"id": mutation, "mutation": mutation, "category": "panel"})
	cases.append({"id": "failed_mandatory_bearer_seat_with_incidental_root", "mutation": "failed_bearer_seat", "category": "bearer"})
	for mutation in ["malformed_resolver_supports", "additional_required_support"]:
		cases.append({"id": mutation, "mutation": mutation, "category": "post"})
	for mutation in ["thin_bearer", "nonfinite_panel_position", "nonfinite_panel_size", "unsupported_panel_joint", "malformed_panel_id", "wrong_panel_kind", "wrong_bearer_kind", "existing_roof_assembly"]:
		cases.append({"id": "builder_atomic_reject_" + mutation, "mutation": mutation, "category": "builder"})
	var all_passed := true
	for definition in cases:
		# Write the next case ID before invoking production validation, so an
		# input-handling error or stalled dependency leaves actionable evidence.
		report["activeCase"] = definition["id"]
		if not _write_report(report):
			quit(2)
			return
		var outcome := _builder_negative(definition) if definition["category"] == "builder" else _negative(definition)
		report["negativeControls"].append(outcome)
		all_passed = all_passed and bool(outcome.get("passed", false))
		report["status"] = "negative_controls_running"
		if not _write_report(report):
			quit(2)
			return
	report["negativeControlsRun"] = true
	report["activeCase"] = ""
	report["passed"] = all_passed
	report["status"] = "passed" if all_passed else "failed"
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	print("SYNTHETIC gable purlin contract: ", report["status"], " report=", _report_path)
	quit((0 if all_passed else 1) if _write_report(report) else 2)


func _house():
	var blueprint = Blueprint.new("synthetic_gable_house", 208159, "timber")
	Urban.add_street_house(blueprint, "house", Vector3(-7.321948, 0.0, -34.82368), 8.648304, 9.45, 6.2, 1.0, 0.62, "plaster_cream", 0.05)
	return blueprint


func _framed() -> Dictionary:
	var blueprint = _house()
	var outcome: Dictionary = Frame.add_frame(blueprint, PANEL_IDS.duplicate(), BEARER_IDS.duplicate(), FRAME_ID)
	return {"blueprint": blueprint, "builder": outcome}


func _positive() -> Dictionary:
	var baseline = _house()
	var repaired = _house()
	var original_geometry := _geometry(baseline)
	var original_rooms: Array = baseline.rooms.duplicate(true)
	var original_household := _household(baseline)
	# Capture original records before either physical validation or furnishing
	# services can populate their own derived recipe data.
	var build: Dictionary = Frame.add_frame(repaired, PANEL_IDS.duplicate(), BEARER_IDS.duplicate(), FRAME_ID)
	var repaired_geometry := _geometry(repaired)
	var geometry_unchanged := true
	for part_id in original_geometry:
		geometry_unchanged = geometry_unchanged and repaired_geometry.has(part_id) and _digest(original_geometry[part_id]) == _digest(repaired_geometry.get(part_id, {}))
	var added_ids: Array[String] = []
	for part in repaired.parts:
		if not original_geometry.has(String(part.id)):
			added_ids.append(String(part.id))
	var rooms_unchanged := _digest(original_rooms) == _digest(repaired.rooms)
	var household_unchanged := _digest(original_household) == _digest(_household(repaired))
	var before_furniture := _window_furniture(baseline)
	var after_furniture := _window_furniture(repaired)
	var before: Dictionary = baseline.validate_physical_integrity()
	var after: Dictionary = repaired.validate_physical_integrity()
	var old_failed := _failed_ids(before)
	var new_failed := _failed_ids(after)
	var added_failed: Array[String] = []
	for part_id in new_failed:
		if not old_failed.has(part_id):
			added_failed.append(part_id)
	var scope := _frame_ids(repaired)
	var frame_checks := _checks_for(after, scope)
	var schema := _schema_checks(repaired)
	var checks := {
		"builder_ready": bool(build.get("ready", false)),
		"original_geometry_and_render_recipe_unchanged": geometry_unchanged,
		"rooms_unchanged": rooms_unchanged,
		"original_household_furniture_unchanged": household_unchanged and not original_household.is_empty(),
		# This house's exterior windows can be outside the interior-program
		# bounds, yielding zero window props. Nonvacuous furniture preservation
		# is established separately by the original household records above.
		"window_furnishing_program_unchanged": _digest(before_furniture) == _digest(after_furniture),
		"baseline_both_roofs_fail": PANEL_IDS.all(func(part_id) -> bool: return old_failed.has(String(part_id))),
		"repaired_roofs_pass": PANEL_IDS.all(func(part_id) -> bool: return _part_passed(after, String(part_id))),
		"all_frame_checks_pass": frame_checks.size() == scope.size() and scope.size() > 2 and frame_checks.all(func(check: Dictionary) -> bool: return bool(check.get("passed", false))),
		"no_added_failed_ids": added_failed.is_empty(),
		"unique_part_ids": repaired_geometry.size() == repaired.parts.size(),
		"builder_part_ids_match_additions": _same_ids(build.get("partIds", []) as Array, added_ids),
		"frame_schema": bool(schema.get("passed", false))
	}
	var passed := checks.values().all(func(value) -> bool: return bool(value))
	print("SYNTHETIC gable positive prototype: ", "PASS" if passed else "FAIL")
	return {"passed": passed, "checks": checks, "builder": build, "schema": schema,
		"baselineFailedIds": old_failed, "repairedFailedIds": new_failed, "addedFailedIds": added_failed,
		"baselineRoofChecks": _checks_for(before, PANEL_IDS), "frameChecks": frame_checks,
		"baselineViolations": before.get("violations", []), "repairedViolations": after.get("violations", []),
		"addedPartIds": added_ids, "frameParts": _snapshots_for(repaired, scope),
		"originalGeometryDigest": _digest(original_geometry), "originalRoomCount": original_rooms.size(),
		"originalHouseholdCount": original_household.size(), "beforeFurniture": before_furniture, "afterFurniture": after_furniture}


func _negative(definition: Dictionary) -> Dictionary:
	# Each mutation gets a newly generated house/frame, not a clone carrying
	# validate_physical_integrity's resolved support grids or root flags.
	var fixture := _framed()
	var blueprint = fixture["blueprint"]
	var outcome: Dictionary = fixture["builder"]
	if not bool(outcome.get("ready", false)):
		return {"id": definition["id"], "passed": false, "setupFailure": "builder_not_ready", "builder": outcome}
	var scope := _frame_ids(blueprint)
	var category := String(definition["category"])
	var mutation := String(definition["mutation"])
	var candidates := _category_parts(blueprint, category)
	if candidates.is_empty():
		return {"id": definition["id"], "passed": false, "setupFailure": "missing_category_" + category}
	var target = candidates[0]
	var target_id := String(target.id)
	var before: Dictionary = target.snapshot()
	var expected_failed_id := target_id
	var details: Dictionary = {}
	var setup_ok := true
	if mutation in ["missing", "moved", "duplicate_declaration", "duplicate_id"]:
		var owner = _dependent(blueprint, category, target_id)
		if owner == null:
			return {"id": definition["id"], "passed": false, "setupFailure": "missing_dependent", "targetId": target_id}
		expected_failed_id = String(owner.id)
		match mutation:
			"missing":
				blueprint.parts.erase(target)
			"moved":
				target.position += Vector3(30.0, 0.0, 0.0)
			"duplicate_id":
				setup_ok = candidates.size() >= 2
				if setup_ok:
					target.id = candidates[1].id
			"duplicate_declaration":
				var key := "physicalRequiredPurlinPartIds" if category == "purlin" else "physicalRequiredPostPartIds" if category == "post" else "physicalRequiredSeatPartIds"
				owner.recipe[key] = [target_id, target_id]
	elif mutation == "visual_detail_bypass":
		target.physical_intent = "visual_detail"
		target.recipe["physicalIntent"] = "visual_detail"
		target.collision_enabled = false
	elif mutation in ["malformed_resolver_supports", "additional_required_support"]:
		target.recipe["physicalRequiredSupportPartIds"] = "not_an_array" if mutation == "malformed_resolver_supports" else ["missing_required_support"]
	elif mutation == "malformed_member_array":
		target.recipe["physicalRequiredPurlinPartIds"] = "not_an_array"
	elif mutation == "malformed_member_id":
		var ids: Array = target.recipe.get("physicalRequiredPurlinPartIds", []) as Array
		setup_ok = ids.size() == 2
		if setup_ok:
			ids[0] = 17
	elif mutation == "malformed_joint_facts":
		target.recipe["physicalRequiredSeatFacts"] = [42]
	elif mutation in ["malformed_joint_vector", "nonfinite_joint"]:
		var facts: Array = target.recipe.get("physicalRequiredSeatFacts", []) as Array
		setup_ok = not facts.is_empty()
		if setup_ok:
			facts[0]["localOverlapCenter"] = "not_a_vector" if mutation == "malformed_joint_vector" else Vector3(NAN, 0.0, 0.0)
	elif mutation == "failed_bearer_seat":
		var owner = _dependent(blueprint, "bearer", target_id)
		setup_ok = owner != null
		if owner != null:
			expected_failed_id = String(owner.id)
		# Retain the complete real house below the gable. The generic ANY-edge
		# chain can still find a foundation, but this mandatory seat is absent.
		target.recipe["physicalRequiredSeatPartIds"] = ["missing_mandatory_gable_seat"]
		target.recipe["physicalRequiredSeatFacts"] = [{"seatId": "missing_mandatory_gable_seat",
			"loadDirection": "world_down", "seatFace": "max_y",
			"localPatchCenter": Vector3(0.0, -target.size.y * 0.5, 0.0), "localPatchHalfExtents": Vector2(0.08, 0.06)}]
	elif mutation == "missing_joint" or mutation == "joint_outside_body":
		var facts: Array = target.recipe.get("physicalRequiredSeatFacts", []) as Array
		setup_ok = not facts.is_empty()
		if setup_ok and mutation == "missing_joint":
			facts.remove_at(0)
		elif setup_ok:
			var fact: Dictionary = facts[0]
			var key := "localOverlapCenter" if fact.has("localOverlapCenter") else "localPatchCenter"
			setup_ok = fact.has(key)
			if setup_ok:
				var point: Vector3 = fact[key]
				point.x = target.size.x + 1.0
				fact[key] = point
	elif mutation in ["unrooted_support", "cyclic_support"]:
		# Keep real frame geometry and its actual gable bearers; remove the
		# rooted house underneath. No resolved support IDs are injected.
		blueprint.parts = blueprint.parts.filter(func(part) -> bool: return scope.has(String(part.id)) or BEARER_IDS.has(String(part.id)))
		for bearer_id in BEARER_IDS:
			var bearer = _find(blueprint, bearer_id)
			setup_ok = setup_ok and bearer != null
			if bearer == null:
				continue
			if mutation == "cyclic_support":
				var twin_id := String(bearer_id) + "_cycle_twin"
				blueprint.add_part({"id": twin_id, "kind": "beam", "position": bearer.position,
					"size": bearer.size, "rotation": bearer.rotation, "collision": true,
					"recipe": {"physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": [bearer_id],
						"physicalRequiredSeatFacts": [_cycle_joint(String(bearer_id))]}})
				bearer.recipe["physicalRequiredSeatPartIds"] = [twin_id]
				bearer.recipe["physicalRequiredSeatFacts"] = [_cycle_joint(twin_id)]
		expected_failed_id = PANEL_IDS[0]
	elif mutation == "same_com_side":
		details = _put_purlins_on_same_side(blueprint, target)
		setup_ok = bool(details.get("prepared", false))
	var result: Dictionary = blueprint.validate_physical_integrity()
	if mutation in ["unrooted_support", "cyclic_support"]:
		var roots := 0
		for part in blueprint.parts:
			roots += int(bool(part.recipe.get("physicalRoot", false)))
		details["rootCount"] = roots
		setup_ok = setup_ok and roots == 0
		if mutation == "cyclic_support":
			for bearer_id in BEARER_IDS:
				var bearer = _find(blueprint, bearer_id)
				var twin = _find(blueprint, String(bearer_id) + "_cycle_twin")
				var geometry: Dictionary = blueprint.housed_overlap_diagnostics(bearer, twin, _cycle_joint(String(twin.id)))
				details[bearer_id] = geometry
				setup_ok = setup_ok and bool(geometry.get("insideBearer", false)) and bool(geometry.get("insideSeat", false)) and not blueprint.has_rooted_support_chain(bearer, {})
	elif mutation == "failed_bearer_seat":
		var incidental_root: bool = blueprint.has_rooted_support_chain(target, {})
		var bearer_failed := _failed_ids(result).has(target_id)
		details = {"bearerStillHasIncidentalRoot": incidental_root, "bearerOwnCheckFails": bearer_failed}
		setup_ok = setup_ok and incidental_root and bearer_failed
	elif mutation == "same_com_side" and setup_ok:
		# This control must retain valid physical joints; a disconnected frame
		# cannot establish that the center-of-mass balance rule was enforced.
		var valid_seats := _all_frame_seats_valid(blueprint)
		details["allPhysicalSeatsStillValid"] = valid_seats
		setup_ok = setup_ok and valid_seats
	var failed_ids := _failed_ids(result)
	var passed := setup_ok and failed_ids.has(expected_failed_id) and not bool(result.get("passed", true))
	if mutation in ["malformed_resolver_supports", "additional_required_support"]:
		var purlin = _dependent(blueprint, "post", target_id)
		var panel = _dependent(blueprint, "purlin", purlin.id)
		passed = passed and failed_ids.has(String(purlin.id)) and failed_ids.has(String(panel.id))
		details["dependentPurlinRejected"] = failed_ids.has(String(purlin.id))
		details["dependentPanelRejected"] = failed_ids.has(String(panel.id))
	print("SYNTHETIC gable negative ", definition["id"], ": ", "PASS" if passed else "FAIL")
	return {"id": definition["id"], "passed": passed, "setupPassed": setup_ok,
		"builder": outcome, "targetId": target_id, "targetBefore": before,
		"expectedFailedPartId": expected_failed_id, "failedPartIds": failed_ids,
		"frameChecks": _checks_for(result, scope), "violations": result.get("violations", []), "diagnostics": details}


func _builder_negative(definition: Dictionary) -> Dictionary:
	var blueprint = _house()
	var panel_ids: Array = PANEL_IDS.duplicate()
	var mutation := String(definition["mutation"])
	var panel = _find(blueprint, PANEL_IDS[0])
	match mutation:
		"thin_bearer":
			_find(blueprint, BEARER_IDS[0]).size.z = 0.08
		"nonfinite_panel_position":
			panel.position.x = NAN
		"nonfinite_panel_size":
			panel.size.y = INF
		"unsupported_panel_joint":
			# Finite, valid part dimensions, but too thin for the declared joint.
			panel.size.y = 0.03
		"malformed_panel_id":
			panel_ids[0] = {"invalid": "id"}
		"wrong_panel_kind":
			panel.kind = "wall"
		"wrong_bearer_kind":
			_find(blueprint, BEARER_IDS[0]).kind = "roof"
		"existing_roof_assembly":
			panel.recipe["physicalAssemblyRole"] = "roof_sloped_span"
	# Snapshot the already-corrupted INPUT: failure must leave even that input
	# completely unchanged, including recipes, rooms and part order/count.
	var before := _digest(blueprint.snapshot())
	var outcome: Dictionary = Frame.add_frame(blueprint, panel_ids, BEARER_IDS.duplicate(), FRAME_ID)
	var unchanged := before == _digest(blueprint.snapshot())
	var passed := not bool(outcome.get("ready", true)) and not String(outcome.get("reason", "")).is_empty() and unchanged
	print("SYNTHETIC gable builder ", mutation, ": ", "PASS" if passed else "FAIL")
	return {"id": definition["id"], "passed": passed, "builder": outcome,
		"inputSnapshotUnchanged": unchanged, "inputDigest": before, "expectedReady": false}


func _put_purlins_on_same_side(blueprint, panel) -> Dictionary:
	var ids: Array = panel.recipe.get("physicalRequiredPurlinPartIds", []) as Array
	if ids.size() != 2:
		return {"prepared": false, "reason": "requires_two_purlins"}
	var first = _find(blueprint, String(ids[0]))
	var second = _find(blueprint, String(ids[1]))
	if first == null or second == null:
		return {"prepared": false, "reason": "missing_purlin"}
	var transform: Transform3D = blueprint.part_transform(panel)
	var first_local: Vector3 = transform.affine_inverse() * first.position
	var second_local: Vector3 = transform.affine_inverse() * second.position
	var first_offset: float = first.position.x - panel.position.x
	var second_offset: float = second.position.x - panel.position.x
	if first_offset * second_offset >= 0.0 or absf(second_offset) < 0.1 or absf(transform.basis.x.x) < 0.1:
		return {"prepared": false, "reason": "positive_did_not_straddle_com"}
	# Move one purlin halfway toward the other's positive/negative COM side.
	# Move its posts horizontally and resize upward from the existing bearing
	# plane; keep joint facts consistent so only balance is invalidated.
	# Match the production validator's world-X COM comparison. Local-X of a
	# purlin center is also affected by its depth below the sloping panel.
	var desired_world_x: float = panel.position.x + second_offset * 0.5
	var local_shift := Vector3((desired_world_x - first.position.x) / transform.basis.x.x, 0.0, 0.0)
	var shift: Vector3 = transform.basis * local_shift
	first.position += shift
	var post_ids: Array = first.recipe.get("physicalRequiredPostPartIds", []) as Array
	if post_ids.size() != 2:
		return {"prepared": false, "reason": "requires_two_posts"}
	for post_id in post_ids:
		var post = _find(blueprint, String(post_id))
		if post == null or not post.rotation.is_equal_approx(Vector3.ZERO) or post.size.y + shift.y <= 0.2:
			return {"prepared": false, "reason": "unsupported_post_transform"}
		post.position += Vector3(shift.x, shift.y * 0.5, shift.z)
		post.size.y += shift.y
		for value in post.recipe.get("physicalRequiredSeatFacts", []) as Array:
			var fact: Dictionary = value
			if fact.has("localPatchCenter"):
				var center: Vector3 = fact["localPatchCenter"]
				center.y = -post.size.y * 0.5
				fact["localPatchCenter"] = center
	for value in panel.recipe.get("physicalRequiredSeatFacts", []) as Array:
		var fact: Dictionary = value
		if String(fact.get("seatId", "")) == String(first.id) and fact.has("localOverlapCenter"):
			fact["localOverlapCenter"] = (fact["localOverlapCenter"] as Vector3) + local_shift
	var new_local: Vector3 = transform.affine_inverse() * first.position
	var new_offset: float = first.position.x - panel.position.x
	return {"prepared": new_offset * second_offset > 0.0 and absf(new_offset) > 0.05,
		"originalWorldXOffsetsFromCOM": [first_offset, second_offset],
		"mutatedWorldXOffsetsFromCOM": [new_offset, second_offset],
		"originalLocalX": [first_local.x, second_local.x], "mutatedLocalX": [new_local.x, second_local.x], "worldShift": shift}


func _schema_checks(blueprint) -> Dictionary:
	var checks: Dictionary = {}
	for part_id in _frame_ids(blueprint):
		var part = _find(blueprint, part_id)
		var role := String(part.recipe.get("physicalAssemblyRole", ""))
		var seats: Array = part.recipe.get("physicalRequiredSeatPartIds", []) as Array
		var facts: Array = part.recipe.get("physicalRequiredSeatFacts", []) as Array
		var declared: Array = []
		match role:
			"gable_roof_panel":
				declared = part.recipe.get("physicalRequiredPurlinPartIds", []) as Array
			"gable_roof_purlin":
				declared = part.recipe.get("physicalRequiredPostPartIds", []) as Array
			"gable_roof_post":
				declared = [String(part.recipe.get("physicalRequiredGableBearerId", ""))]
		var fact_ids: Array = []
		for fact in facts:
			fact_ids.append(String(fact.get("seatId", "")))
		var expected_count := 1 if role == "gable_roof_post" else 2
		checks[part_id] = ROLES.has(role) and String(part.recipe.get("physicalGableFrameId", "")) == FRAME_ID and declared.size() == expected_count and _same_ids(declared, seats) and _same_ids(seats, fact_ids)
	return {"passed": not checks.is_empty() and checks.values().all(func(value) -> bool: return bool(value)), "checks": checks}


func _cycle_joint(seat_id: String) -> Dictionary:
	return {"seatId": seat_id, "contactMode": "housed_overlap", "localSpanAxis": "x",
		"localOverlapCenter": Vector3.ZERO, "localOverlapHalfExtents": Vector3(0.07, 0.05, 0.07),
		"minimumLongitudinalEmbedment": 0.14, "minimumVerticalOverlap": 0.10}


func _all_frame_seats_valid(blueprint) -> bool:
	for part_id in _frame_ids(blueprint):
		var part = _find(blueprint, part_id)
		var facts: Array = part.recipe.get("physicalRequiredSeatFacts", []) as Array
		if facts.is_empty():
			return false
		for fact in facts:
			if not blueprint.has_rooted_bearer_seat(part, fact as Dictionary):
				return false
	return true


func _dependent(blueprint, category: String, target_id: String):
	var key := "physicalRequiredPurlinPartIds" if category == "purlin" else "physicalRequiredPostPartIds" if category == "post" else "physicalRequiredSeatPartIds"
	for part_id in _frame_ids(blueprint):
		var part = _find(blueprint, part_id)
		if (part.recipe.get(key, []) as Array).has(target_id):
			return part
	return null


func _category_parts(blueprint, category: String) -> Array:
	var result: Array = []
	for part in blueprint.parts:
		if (category == "bearer" and BEARER_IDS.has(String(part.id))) or (category != "bearer" and String(part.recipe.get("physicalAssemblyRole", "")) == "gable_roof_" + category and String(part.recipe.get("physicalGableFrameId", "")) == FRAME_ID):
			result.append(part)
	return result


func _frame_ids(blueprint) -> Array[String]:
	var result: Array[String] = []
	for part in blueprint.parts:
		if PANEL_IDS.has(String(part.id)) or String(part.recipe.get("physicalGableFrameId", "")) == FRAME_ID:
			result.append(String(part.id))
	return result


func _find(blueprint, part_id: String):
	for part in blueprint.parts:
		if String(part.id) == part_id:
			return part
	return null


func _geometry(blueprint) -> Dictionary:
	var result: Dictionary = {}
	for part in blueprint.parts:
		var record: Dictionary = part.snapshot()
		record.erase("physicalIntent")
		var render_recipe: Dictionary = record.get("recipe", {})
		for key in render_recipe.keys():
			if String(key).begins_with("physical"):
				render_recipe.erase(key)
		result[String(part.id)] = record
	return result


func _household(blueprint) -> Array:
	var result: Array = []
	for part in blueprint.parts:
		if String(part.semantic).begins_with("citadel_household_"):
			result.append(part.snapshot())
	return result


func _window_furniture(blueprint) -> Dictionary:
	# Small production furnishing path without constructing a castle or invoking
	# residence/navigation planning. These are real FurnishingPart records.
	var plan = FurnishingPlanScript.new("synthetic_house_windows", 208159, blueprint.id)
	InteriorProgram.apply_to_plan(blueprint, plan)
	return {"partCount": plan.parts.size(), "snapshot": plan.snapshot(), "reservations": plan.access_reservations_snapshot()}


func _snapshots_for(blueprint, ids: Array) -> Array:
	var result: Array = []
	for part in blueprint.parts:
		if ids.has(String(part.id)):
			result.append(part.snapshot())
	return result


func _failed_ids(validation: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for check in validation.get("checks", []):
		if not bool(check.get("passed", false)):
			result.append(String(check.get("partId", "")))
	return result


func _checks_for(validation: Dictionary, ids: Array) -> Array:
	return (validation.get("checks", []) as Array).filter(func(check: Dictionary) -> bool: return ids.has(String(check.get("partId", ""))))


func _part_passed(validation: Dictionary, part_id: String) -> bool:
	var checks := _checks_for(validation, [part_id])
	return checks.size() == 1 and bool(checks[0].get("passed", false))


func _same_ids(first: Array, second: Array) -> bool:
	var unique: Dictionary = {}
	for value in first:
		unique[String(value)] = true
	return not first.is_empty() and not unique.has("") and unique.size() == first.size() and first.size() == second.size() and first.all(func(value) -> bool: return second.count(value) == 1)


func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()


func _write_report(report: Dictionary) -> bool:
	var output := FileAccess.open(_report_path, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write synthetic gable report: %s (error %s)" % [_report_path, FileAccess.get_open_error()])
		return false
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	return true
