extends "res://scripts/testing/buildings/TerminalQuarterTurnFrameContract.gd"

## Reuses only synthetic asymmetric foundations / actual producer fixture and
## inspection helpers. Overrides the run: old cross-API geometry parity is NOT
## appropriate now that explicit mode derives rails from actual cloth planes.
## Source contract, not renderer/GPU, full scene contact or access acceptance.


func _run() -> void:
	var path := OS.get_environment("VOXEL_TERMINAL_CLOTH_BEARING_REPORT")
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var legacy := _fixture(0, true)
	var legacy_results: Array = []
	for prefix in legacy.prefixes:
		legacy_results.append(Frame.add_frame(legacy.b, prefix, legacy.supportId))
	var positives: Array = []
	var controls: Array = []
	if legacy_results.all(func(result): return result.ready):
		for quarter in range(4):
			# Actual source first; a declared synthetic thickness variation then
			# proves this is plane-derived, not a memorised penetration correction.
			for thickness_extra in [0.0, 0.01]:
				positives.append(_cloth_positive(quarter, thickness_extra, legacy))
		for mode in ["missing_all", "missing_edge", "missing_middle", "inconsistent_pitch", "inconsistent_thickness", "hidden_cloth", "wrong_kind", "nonfinite_cloth", "short_full_span", "cloth_too_narrow", "cloth_too_low_for_header", "missing_support", "moved_support", "late_socket_failure"]:
			controls.append(_cloth_negative(mode))
	var compatibility := _legacy_compatibility()
	var report := {"evidenceLevel": "actual_producer_source_cloth_bearing_with_synthetic_world_supports",
		"positiveCases": positives, "negativeCases": controls, "legacyCompatibility": compatibility,
		"legacyReferenceResults": legacy_results, "elapsedMsec": Time.get_ticks_msec() - started,
		"passed": positives.size() == 8 and controls.size() == 14 and positives.all(func(row): return row.passed) and controls.all(func(row): return row.passed) and compatibility.passed,
		"proof": "Independent transformed rail corners in actual cloth frame; upper face parallel and tangent to underside; both prior rail centerline endpoint projections retained; all closure+11 source parts and mandatory joints revalidated; ancestor removal/movement must break frame.",
		"parityScope": "Direct add_frame keeps zero-turn legacy geometry and no cloth dependency. add_frame_on_support deliberately differs in rails/braces and their joint coordinates. Old direct-vs-explicit snapshot parity assertions are obsolete; no changes made to those other contract files.",
		"limitations": "Finite source-box geometry and production physical validator only. Does not certify actual publisher/GPU surfaces, other cloth/header/sign contacts, foreign overlaps, furniture clearance, public approach, NPCs or live gameplay. Author launched no engine."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if written and report.passed else 2)


func _cloth_positive(quarter: int, thickness_extra: float, legacy: Dictionary) -> Dictionary:
	var fixture := _fixture(quarter)
	var b = fixture.b
	for part in b.parts:
		if part.semantic == "citadel_terminal_shop_awning":
			part.size.y += thickness_extra
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var recipe_digests: Array = recipes.map(func(recipe): return _digest(recipe))
	var results := _build_all(fixture)
	var checks := {"all_three_bays_ready": results.size() == 3 and results.all(func(result): return result.ready),
		"original_object_aliases_preserved": range(aliases.size()).all(func(i): return is_same(aliases[i], b.parts[i])),
		"original_recipe_aliases_untouched": range(recipes.size()).all(func(i): return _digest(recipes[i]) == recipe_digests[i])}
	var proofs: Array = []
	var dependencies: Array = []
	if checks.all_three_bays_ready:
		var changed: Array = []
		for prefix in fixture.prefixes:
			for suffix in MEMBERS: changed.append(prefix + suffix)
		checks["all_cloth_goods_supports_and_nonframe_records_exact"] = _unchanged(before, b.snapshot(), changed)
		checks["parent_recipe_aliases_and_intents_preserved"] = fixture.parentIds.all(func(id): return _digest(_record(before, id)) == _digest(_find(b, id).snapshot()) and is_same(_find(b, id).recipe, recipes[aliases.find(_find(b, id))]))
		checks["exact_world_closure_plus_11_pass"] = results.all(func(result): return result.expectedPartCount == fixture.parentIds.size() + 11 and result.stagedPhysical.checks.size() == result.expectedPartCount and result.stagedPhysical.checks.all(func(check): return check.passed))
		for i in range(results.size()):
			var result: Dictionary = results[i]
			var prefix: String = fixture.prefixes[i]
			if result.get("clothBearing", []).size() != 2:
				proofs.append({"passed": false, "reason": "missing_two_rail_proofs", "prefix": prefix})
				continue
			for bearing in result.clothBearing:
				var rail = _find(b, bearing.railId)
				var cloth = _find(b, bearing.clothId)
				var reference_rail = _find(legacy.b, rail.id)
				proofs.append(_independent_corners(b, rail, cloth, legacy.b, reference_rail, quarter))
			proofs.append(_all_joints(fixture, prefix, result.partIds))
			dependencies.append_array(_dependency_breaks(fixture, prefix, result.partIds))
		checks["independent_full_corner_span_and_joint_proofs"] = proofs.size() == 9 and proofs.all(func(proof): return proof.passed)
		checks["actual_support_dependencies_required"] = dependencies.size() == 12 and dependencies.all(func(row): return row.passed)
	return {"quarterTurn": quarter, "syntheticThicknessAddition": thickness_extra,
		"checks": checks, "railAndJointProofs": proofs, "dependencyBreaks": dependencies,
		"results": results, "passed": checks.values().all(func(value): return value)}


func _independent_corners(b, rail, cloth, legacy_b, legacy_rail, quarter: int) -> Dictionary:
	if rail == null or cloth == null or legacy_rail == null:
		return {"passed": false, "reason": "missing_geometry"}
	var cloth_transform: Transform3D = b.part_transform(cloth)
	var relative: Transform3D = cloth_transform.affine_inverse() * b.part_transform(rail)
	var legacy_relative: Transform3D = cloth_transform.affine_inverse() * _rigid(quarter) * legacy_b.part_transform(legacy_rail)
	# Preserve prior full centerline span, not a new tip chosen to miss cloth.
	var old_start: Vector3 = legacy_relative * Vector3(0, -legacy_rail.size.y * 0.5, 0)
	var old_end: Vector3 = legacy_relative * Vector3(0, legacy_rail.size.y * 0.5, 0)
	var expected_min := minf(old_start.z, old_end.z)
	var expected_max := maxf(old_start.z, old_end.z)
	var min_z := INF
	var max_z := -INF
	var max_y := -INF
	var corners: Array = []
	var contained := true
	var bearing_face := true
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var point: Vector3 = relative * (rail.size * Vector3(x, y, z))
				var gap: float = point.y + cloth.size.y * 0.5
				contained = contained and absf(point.x) <= cloth.size.x * 0.5 + GEOMETRY_EPS and absf(point.z) <= cloth.size.z * 0.5 + GEOMETRY_EPS and gap <= GEOMETRY_EPS
				if z > 0.0: bearing_face = bearing_face and absf(gap) <= GEOMETRY_EPS
				min_z = minf(min_z, point.z)
				max_z = maxf(max_z, point.z)
				max_y = maxf(max_y, point.y)
				corners.append({"clothLocal": point, "undersideNormalGap": gap, "upperFace": z > 0.0})
	var parallel := relative.basis.z.distance_to(Vector3.UP) <= BASIS_EPS and relative.basis.y.distance_to(Vector3.FORWARD) <= BASIS_EPS
	var span := absf(min_z - expected_min) <= GEOMETRY_EPS and absf(max_z - expected_max) <= GEOMETRY_EPS
	return {"railId": rail.id, "clothId": cloth.id, "corners": corners, "parallel": parallel,
		"retainedFullLongitudinalSpan": span, "priorEndpointSpan": Vector2(expected_min, expected_max),
		"actualCornerSpan": Vector2(min_z, max_z), "maximumUndersideProtrusion": max_y + cloth.size.y * 0.5,
		"passed": contained and bearing_face and parallel and span}


func _all_joints(fixture: Dictionary, prefix: String, additions: Array) -> Dictionary:
	var b = Blueprint.new("cloth_joint_revalidation", 418, "stone")
	var ids: Array = fixture.parentIds + MEMBERS.map(func(suffix): return prefix + suffix) + additions
	for id in ids:
		var original = _find(fixture.b, id)
		var part = b.add_part(original.snapshot())
		part.physical_intent = original.physical_intent
		Frame._clean_caches(part)
	var work: Dictionary = Frame._validation_work(b)
	if not work.ready: return {"passed": false, "reason": work.reason}
	var physical: Dictionary = b.validate_physical_integrity()
	var facts: Array = []
	for part in b.parts:
		for fact in part.recipe.get("physicalRequiredSeatFacts", []):
			facts.append({"id": part.id, "seatId": fact.seatId, "passed": b.has_rooted_bearer_seat(part, fact)})
		for fact in part.recipe.get("physicalRequiredAnchorFacts", []):
			facts.append({"id": part.id, "anchorId": fact.anchorId,
				"passed": Frame._socket_inside_member(part, fact) and b.has_rooted_attachment_socket(part, fact)})
	return {"prefix": prefix, "facts": facts, "physical": physical,
		"passed": physical.checks.size() == ids.size() and physical.violations.is_empty() and physical.checks.all(func(check): return check.passed) and not facts.is_empty() and facts.all(func(fact): return fact.passed)}


func _cloth_negative(mode: String) -> Dictionary:
	var fixture := _fixture(2)
	var b = fixture.b
	var prefix: String = fixture.prefixes[0]
	var cloth: Array = b.parts.filter(func(part): return part.semantic == "citadel_terminal_shop_awning" and String(part.id).begins_with(prefix + "_"))
	cloth.sort_custom(func(a, c): return a.id < c.id)
	match mode:
		"missing_all":
			for part in cloth: b.parts.erase(part)
		"missing_edge": b.parts.erase(cloth[0])
		"missing_middle": b.parts.erase(cloth[cloth.size() / 2])
		"inconsistent_pitch": cloth[0].rotation.x += 0.1
		"inconsistent_thickness": cloth[0].size.y *= 1.5
		"hidden_cloth": cloth[0].recipe["visual"] = false
		"wrong_kind": cloth[0].kind = "beam"
		"nonfinite_cloth": cloth[0].position.y = NAN
		"short_full_span":
			for part in cloth: part.size.z *= 0.5
		"cloth_too_narrow":
			for part in cloth: part.size.x *= 0.2
		"cloth_too_low_for_header":
			for part in cloth: part.position.y -= 1.0
		"missing_support": b.parts.erase(_find(b, fixture.supportId))
		"moved_support": _find(b, fixture.supportId).position.x += 100.0
		"late_socket_failure": _find(b, prefix + "_sign_arm").size.y = 0.02
	var before := _digest(b.snapshot())
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var recipe_digests: Array = recipes.map(func(recipe): return _digest(recipe))
	var result: Dictionary = Frame.add_frame_on_support(b, prefix, fixture.supportId, fixture.upstreamIds)
	var late: bool = mode != "late_socket_failure" or result.get("reason") in ["staged_frame_has_invalid_load_path", "staged_socket_outside_attachment", "staged_anchor_invalid"]
	return {"mode": mode, "result": result, "passed": not result.ready and late and _digest(b.snapshot()) == before and range(aliases.size()).all(func(i): return is_same(b.parts[i], aliases[i]) and is_same(b.parts[i].recipe, recipes[i]) and _digest(recipes[i]) == recipe_digests[i])}


func _legacy_compatibility() -> Dictionary:
	var fixture := _fixture(0, true)
	var b = fixture.b
	var prefix: String = fixture.prefixes[0]
	# Legacy never depended on cloth: keep that API behaviour explicitly.
	for part in b.parts.duplicate():
		if part.semantic == "citadel_terminal_shop_awning": b.parts.erase(part)
	var result: Dictionary = Frame.add_frame(b, prefix, fixture.supportId)
	var geometry: Array = []
	if result.ready:
		var header = _find(b, prefix + "_lintel")
		for side in [-1, 1]:
			var post = _find(b, prefix + "_jamb_%d" % side)
			var rail = _find(b, prefix + "_awning_rail_%d" % side)
			var transform: Transform3D = b.part_transform(rail)
			var start: Vector3 = transform * Vector3(0, -rail.size.y * 0.5, 0)
			var end: Vector3 = transform * Vector3(0, rail.size.y * 0.5, 0)
			# Frozen legacy public geometry contract, NOT new rail construction.
			var expected_start := Vector3(post.position.x, header.position.y, header.position.z + 0.055)
			var expected_end := Vector3(post.position.x, header.position.y - 0.24, header.position.z - 1.53)
			geometry.append({"railId": rail.id, "passed": start.distance_to(expected_start) <= GEOMETRY_EPS and end.distance_to(expected_end) <= GEOMETRY_EPS})
	return {"result": result, "geometry": geometry, "passed": result.ready and geometry.size() == 2 and geometry.all(func(row): return row.passed),
		"scope": "Legacy direct geometry retained, including its known cloth-protrusion limitation. No assertion of direct/explicit snapshot parity."}
