extends "res://scripts/testing/buildings/TerminalQuarterTurnFrameContract.gd"

## Source-only description -> private complete-row staging -> rigid transform ->
## actual-world support binding. No production planner, renderer or navigation.

func _run() -> void:
	var path := OS.get_environment("VOXEL_TERMINAL_FRAME_DESCRIPTION_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var positives: Array = []
	for quarter in range(4):
		for refresh in [false, true]:
			for variation in [-0.03, 0.05]: positives.append(_description_positive(quarter, refresh, variation))
	var description_controls: Array = []
	for mode in ["missing_member", "missing_cloth", "forged_root", "intent_conflict", "existing_joint", "mixed_yaw", "nonfinite", "huge_geometry"]:
		description_controls.append(_description_negative(mode))
	var binding_controls: Array = []
	for mode in ["missing_support", "missing_root", "moved_support", "duplicate_ancestor", "missing_member", "moved_member", "mixed_yaw", "forged_root_description", "forged_root_source", "duplicate_records", "invalid_post_ids", "invalid_size", "missing_internal_joint", "foreign_internal_joint", "invalid_joint_vector", "premature_post_binding", "late_socket_failure"]:
		binding_controls.append(_binding_negative(mode))
	var parity := _explicit_parity()
	var report := {"evidenceLevel": "actual_producer_source_description_binding_contract_synthetic_foundations",
		"positiveCases": positives, "descriptionControls": description_controls, "bindingControls": binding_controls,
		"explicitConvenienceParity": parity, "elapsedMsec": Time.get_ticks_msec() - started,
		"passed": positives.all(func(row): return row.passed) and description_controls.all(func(row): return row.passed) and binding_controls.all(func(row): return row.passed) and parity.passed,
		"scope": "Description succeeds without any support record and makes no ready/root claim. All complete-row geometry, cloth, furniture, internal joints, parent records and aliases preserved at binding; only the two post-seat keys may be added. Both original-pose and refreshed-pose description schemas exercised.",
		"limitations": "No real layout selection, published mesh, full-world physical gate, public approach, NPC or headed acceptance. Direct legacy API has deliberately different rails and is not compared for geometry parity."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if written and report.passed else 2)


func _source_fixture(variation: float) -> Dictionary:
	var fixture := _fixture(0)
	var b = fixture.b
	# Reuse the existing asymmetric world support fixture, not a fake support
	# for description. Regenerate row variation with its real owning producer.
	b.parts = b.parts.filter(func(part): return fixture.parentIds.has(part.id))
	Urban.add_terminal_shop_row(b, PIVOT, variation)
	fixture.memberIds = []
	fixture.prefixes = []
	for part in b.parts:
		if fixture.parentIds.has(part.id): continue
		fixture.memberIds.append(part.id)
		if part.semantic == "citadel_terminal_shop_frame" and String(part.id).ends_with("_lintel"):
			fixture.prefixes.append(String(part.id).trim_suffix("_lintel"))
	fixture.prefixes.sort()
	return fixture


func _describe_without_support(fixture: Dictionary) -> Dictionary:
	var source = Blueprint.new("unsupported_description_source", 418, "stone")
	for part in fixture.b.parts:
		if not fixture.parentIds.has(part.id): source.parts.append(part)
	var before := _digest(source.snapshot())
	var descriptions: Array = []
	for prefix in fixture.prefixes: descriptions.append(Frame.describe_frame(source, prefix))
	var valid: bool = descriptions.size() == 3 and descriptions.all(func(d): return d.get("described", false) and not d.has("ready") and not d.has("sourceRootIds") and d.records.size() == 11 and d.partIds.size() == 5 and d.memberIds.size() == 11 and d.postIds.size() == 2)
	return {"descriptions": descriptions, "passed": valid and before == _digest(source.snapshot())}


func _stage(fixture: Dictionary, descriptions: Array, quarter: int, refresh: bool) -> void:
	var b = fixture.b
	var records: Dictionary = {}
	for d in descriptions:
		for record in d.records: records[record.id] = record
		fixture.memberIds.append_array(d.partIds)
	var prior: Array = b.parts.duplicate()
	b.parts.clear()
	for part in prior:
		if records.has(part.id):
			var copy = b.add_part(records[part.id])
			copy.physical_intent = records[part.id].physicalIntent
		else: b.parts.append(part)
	for d in descriptions:
		for id in d.partIds:
			var copy = b.add_part(records[id])
			copy.physical_intent = records[id].physicalIntent
	var delta := _rigid(quarter)
	for part in b.parts:
		if not fixture.memberIds.has(part.id): continue
		if quarter != 0:
			var transform: Transform3D = delta * b.part_transform(part)
			part.position = transform.origin
			part.rotation = transform.basis.get_euler()
	if refresh:
		for d in descriptions:
			d.records = d.memberIds.map(func(id): return _find(b, id).snapshot())
			d.clothRecords = d.clothIds.map(func(id): return _find(b, id).snapshot())


func _description_positive(quarter: int, refresh: bool, variation: float) -> Dictionary:
	var fixture := _source_fixture(variation)
	var input_before := _digest(fixture.b.snapshot())
	var described := _describe_without_support(fixture)
	if not described.passed:
		return {"passed": false, "quarter": quarter, "descriptions": described.descriptions}
	var pure: bool = input_before == _digest(fixture.b.snapshot())
	_stage(fixture, described.descriptions, quarter, refresh)
	var b = fixture.b
	var before: Dictionary = b.snapshot()
	var description_before := _digest(described.descriptions)
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var recipe_digests: Array = recipes.map(func(recipe): return _digest(recipe))
	var posts: Array = []
	var results: Array = []
	for d in described.descriptions:
		posts.append_array(d.postIds)
		results.append(Frame.bind_described_frame_on_support(b, d, fixture.supportId, fixture.upstreamIds))
	var all_ready: bool = results.size() == 3 and results.all(func(result): return result.ready)
	var checks := {"description_pure_and_support_independent": pure,
		"all_bays_bound": all_ready,
		"all_planned_records_exact_except_post_seat_keys": _binding_only(before, b.snapshot(), posts),
		"descriptions_unchanged_by_binding": description_before == _digest(described.descriptions),
		"all_part_aliases_preserved": range(aliases.size()).all(func(i): return is_same(b.parts[i], aliases[i])),
		"old_recipe_aliases_unmodified": range(recipes.size()).all(func(i): return _digest(recipes[i]) == recipe_digests[i]),
		"nonpost_recipe_aliases_identical": range(aliases.size()).all(func(i): return posts.has(aliases[i].id) or is_same(b.parts[i].recipe, recipes[i]))}
	var breaks: Array = []
	if all_ready:
		checks["closure_plus_11_world_validation"] = results.all(func(result): return result.expectedPartCount == fixture.parentIds.size() + 11 and result.stagedPhysical.checks.size() == result.expectedPartCount and result.stagedPhysical.checks.all(func(check): return check.passed))
		for i in range(results.size()): breaks.append_array(_dependency_breaks(fixture, fixture.prefixes[i], results[i].partIds))
		checks["real_support_dependencies"] = breaks.size() == 12 and breaks.all(func(row): return row.passed)
	return {"quarterTurn": quarter, "refreshedDescriptionRecords": refresh, "variation": variation,
		"stagedRowParts": fixture.memberIds.size(), "checks": checks, "results": results,
		"dependencyBreaks": breaks, "passed": checks.values().all(func(value): return value)}


func _binding_only(before: Dictionary, after: Dictionary, posts: Array) -> bool:
	var allowed := after.duplicate(true)
	for part in allowed.parts:
		if not posts.has(part.id): continue
		part.recipe.erase("physicalRequiredSeatPartIds")
		part.recipe.erase("physicalRequiredSeatFacts")
	return _digest(before) == _digest(allowed)


func _description_negative(mode: String) -> Dictionary:
	var fixture := _source_fixture(0.05)
	var b = fixture.b
	var prefix: String = fixture.prefixes[0]
	var header = _find(b, prefix + "_lintel")
	match mode:
		"missing_member": b.parts.erase(header)
		"missing_cloth": b.parts = b.parts.filter(func(part): return not (String(part.id).begins_with(prefix + "_") and part.semantic == "citadel_terminal_shop_awning"))
		"forged_root": header.recipe["physicalRoot"] = true
		"intent_conflict": header.physical_intent = "visual_detail"
		"existing_joint": header.recipe["physicalRequiredSeatPartIds"] = [fixture.supportId]
		"mixed_yaw": _find(b, prefix + "_jamb_1").rotation.y = PI * 0.5
		"nonfinite": header.position.x = NAN
		"huge_geometry": header.size.x = 1.0e12
	var before := _digest(b.snapshot())
	var aliases: Array = b.parts.duplicate()
	var result: Dictionary = Frame.describe_frame(b, prefix)
	return {"mode": mode, "result": result, "passed": not result.get("described", false) and not result.has("ready") and before == _digest(b.snapshot()) and range(aliases.size()).all(func(i): return is_same(aliases[i], b.parts[i]))}


func _binding_negative(mode: String) -> Dictionary:
	var fixture := _source_fixture(0.05)
	var prepared := _describe_without_support(fixture)
	if not prepared.passed: return {"mode": mode, "passed": false, "reason": "description_setup_failed"}
	_stage(fixture, prepared.descriptions, 2, true)
	var b = fixture.b
	var d: Dictionary = prepared.descriptions[0]
	var prefix: String = d.prefix
	var upstream: Array = fixture.upstreamIds.duplicate()
	match mode:
		"missing_support": b.parts.erase(_find(b, fixture.supportId))
		"missing_root": b.parts.erase(_find(b, fixture.parentIds[0]))
		"moved_support": _find(b, fixture.supportId).position.x += 100.0
		"duplicate_ancestor": upstream.append(upstream[0])
		"missing_member": b.parts.erase(_find(b, d.partIds[0]))
		"moved_member": _find(b, d.partIds[0]).position.x += 0.5
		"mixed_yaw": _find(b, prefix + "_jamb_1").rotation.y += PI * 0.5
		"forged_root_description": d.records[0].recipe["physicalRoot"] = true
		"forged_root_source": _find(b, d.partIds[0]).recipe["physicalRoot"] = true
		"duplicate_records": d.records[1] = d.records[0].duplicate(true)
		"invalid_post_ids": d.postIds = [d.memberIds[0], d.memberIds[1]]
		"invalid_size": d.records[0].size.x = -1.0
		"missing_internal_joint": d.records[0].recipe.erase("physicalRequiredSeatFacts")
		"foreign_internal_joint": d.records[0].recipe.physicalRequiredSeatPartIds = [fixture.supportId]
		"invalid_joint_vector": d.records[0].recipe.physicalRequiredSeatFacts[0].localOverlapCenter = "invalid"
		"premature_post_binding":
			var post = _find(b, d.postIds[0])
			post.recipe["physicalRequiredSeatPartIds"] = [fixture.supportId]
			d.records = d.memberIds.map(func(id): return _find(b, id).snapshot())
		"late_socket_failure":
			_find(b, prefix + "_sign_arm").size.y = 0.02
			d.records = d.memberIds.map(func(id): return _find(b, id).snapshot())
	var before := _digest(b.snapshot())
	var description_before := _digest(d)
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var result: Dictionary = Frame.bind_described_frame_on_support(b, d, fixture.supportId, upstream)
	var late: bool = mode != "late_socket_failure" or result.get("reason") in ["staged_frame_has_invalid_load_path", "staged_socket_outside_attachment", "staged_anchor_invalid"]
	return {"mode": mode, "result": result, "passed": not result.ready and late and before == _digest(b.snapshot()) and description_before == _digest(d) and range(aliases.size()).all(func(i): return is_same(b.parts[i], aliases[i]) and is_same(b.parts[i].recipe, recipes[i]))}


func _explicit_parity() -> Dictionary:
	var staged := _source_fixture(0.05)
	var convenient := _source_fixture(0.05)
	var prepared := _describe_without_support(staged)
	if not prepared.passed: return {"passed": false, "reason": "description_setup_failed"}
	_stage(staged, prepared.descriptions, 0, false)
	var results: Array = []
	for i in range(staged.prefixes.size()):
		results.append(Frame.bind_described_frame_on_support(staged.b, prepared.descriptions[i], staged.supportId, staged.upstreamIds))
		results.append(Frame.add_frame_on_support(convenient.b, convenient.prefixes[i], convenient.supportId, convenient.upstreamIds))
	return {"passed": results.all(func(result): return result.ready) and _digest(staged.b.snapshot()) == _digest(convenient.b.snapshot()), "results": results}
