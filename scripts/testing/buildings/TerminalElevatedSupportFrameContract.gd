extends SceneTree

## Source/service contract: actual terminal producer on explicitly synthetic
## support stacks. Not the frozen elevation recipe, row-clearance or navigation.
## VOXEL_TERMINAL_ELEVATED_FRAME_REPORT: new absolute JSON, existing directory.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Frame = preload("res://scripts/buildings/TerminalShopFrameBuilder.gd")
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const PREFIXES := ["urban_terminal_00", "urban_terminal_01", "urban_terminal_02"]
const MEMBERS := ["_lintel", "_sign_arm", "_jamb_-1", "_jamb_1", "_bracket_-1", "_bracket_1"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_TERMINAL_ELEVATED_FRAME_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		push_error("Require a new VOXEL_TERMINAL_ELEVATED_FRAME_REPORT path")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var positives: Array = []
	for prefix in PREFIXES:
		positives.append(_positive(prefix, 1, false))
		positives.append(_positive(prefix, 2, true))
	var controls: Array = []
	for mode in ["missing_support", "missing_ancestor", "duplicate_ancestor", "support_repeated", "invalid_id_type", "oversized", "duplicate_source", "unrelated_root", "cyclic_obligations", "parent_no_collision", "parent_moved", "support_moved", "forged_root_flag", "forged_root_intent", "forged_cached_path", "property_visual", "recipe_visual", "intent_conflict", "frame_intent_conflict", "root_off_zero", "invalid_required_array", "invalid_fact_record", "invalid_fact_vector", "missing_mandatory_dependency", "unsupported_mandatory_field", "huge_finite_bounds", "nonfinite_bounds", "late_socket_failure"]:
		controls.append(_negative(mode))
	var parity := _direct_parity()
	var report := {"evidenceLevel": "actual_terminal_producer_with_synthetic_explicit_support_closure", "positiveCases": positives,
		"inputControls": controls, "directApiParity": parity, "elapsedMsec": Time.get_ticks_msec() - started,
		"passed": positives.all(func(row): return row.passed) and controls.all(func(row): return row.passed) and parity.passed,
		"limitations": "Source physical load paths and preservation only. Synthetic stacks reproduce ground top .62 and elevated top 4.22, not actual frozen support selection. Caller must elevate the complete row and prove customer access, occlusion and published clearances separately. No engine launch performed by author; existing direct-ground regression remains separate."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	print("Terminal elevated support source contract passed=", report.passed)
	quit(0 if written and report.passed else 2)

func _fixture(levels := 1, required := false, direct := false) -> Dictionary:
	var b = Blueprint.new("terminal_explicit_support_contract", 418, "stone")
	var root_height := 4.22 if direct else 0.62
	b.add_part({"id": "ground", "kind": "foundation", "material": "stone_foundation", "collision": true,
		"position": Vector3(0, root_height * 0.5, 0), "size": Vector3(24, root_height, 12),
		"physicalIntent": "structural_mass", "recipe": {"physicalIntent": "structural_mass", "preserveBearingFaces": true, "fixtureAuthority": "synthetic_ground"}})
	var closure: Array = ["ground"]
	if not direct:
		var height: float = 3.6 / float(levels)
		for level in range(levels):
			var id := "support_%d" % level
			var recipe := {"physicalIntent": "structural_mass", "fixtureAuthority": "synthetic_terrace"}
			if required:
				recipe["physicalRequiredSeatPartIds"] = [closure.back()]
				recipe["physicalRequiredSeatFacts"] = [Seats.world_down_seat_fact(closure.back(), Vector3(0, -height * 0.5, 0), Vector2(0.2, 0.2))]
			b.add_part({"id": id, "kind": "foundation", "material": "stone_foundation", "collision": true,
				"position": Vector3(0, 0.62 + height * (float(level) + 0.5), 0), "size": Vector3(20, height, 10),
				"physicalIntent": "structural_mass", "recipe": recipe})
			closure.append(id)
	# Real production grammar, not copied beam/awning/member construction.
	Urban.add_terminal_shop_row(b, Vector3(0, 4.22, 0), 0.05)
	return {"b": b, "supportId": closure.back(), "upstreamIds": closure.slice(0, closure.size() - 1), "closureIds": closure}

func _positive(prefix: String, levels: int, required: bool) -> Dictionary:
	var fixture := _fixture(levels, required)
	var b = fixture.b
	# Constructor/roundtrip trap: one authoritative field empty, recipe explicit.
	_find(b, "ground").physical_intent = ""
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var recipe_aliases: Array = b.parts.map(func(part): return part.recipe)
	var recipe_digests: Array = recipe_aliases.map(func(recipe): return _digest(recipe))
	var result: Dictionary = Frame.add_frame_on_support(b, prefix, fixture.supportId, fixture.upstreamIds)
	var row := {"prefix": prefix, "levels": levels, "requiredSeats": required, "result": result, "passed": false}
	if not result.ready:
		row["failureAtomic"] = _digest(before) == _digest(b.snapshot())
		return row
	var checks := {"complete_closure_before": result.sourceClosurePhysicalBefore.checks.size() == fixture.closureIds.size() and result.sourceClosurePhysicalBefore.checks.all(func(check): return check.passed),
		"exact_staged_count": result.expectedPartCount == fixture.closureIds.size() + 6 + 5 and result.stagedPhysical.checks.size() == result.expectedPartCount,
		"all_staged_parts_pass": result.stagedPhysical.checks.all(func(check): return check.passed),
		"parents_and_all_nonframe_content_exact": _unchanged_except_frame(before, b.snapshot(), prefix, result.partIds),
		"parent_property_intent_preserved": _find(b, "ground").physical_intent == "",
		"object_aliases_preserved": range(aliases.size()).all(func(i): return is_same(b.parts[i], aliases[i])),
		"original_recipe_aliases_unchanged": range(recipe_aliases.size()).all(func(i): return _digest(recipe_aliases[i]) == recipe_digests[i])}
	var breaks: Array = []
	for id in fixture.closureIds:
		for mode in ["remove", "move"]:
			var broken = _copy(b.snapshot())
			var target = _find(broken, id)
			if mode == "remove": broken.parts.erase(target)
			else: target.position.x += 100.0
			for part in broken.parts: Frame._clean_caches(part)
			var work: Dictionary = Frame._validation_work(broken)
			var physical: Dictionary = broken.validate_physical_integrity() if work.ready else {}
			var failed: Array = physical.get("checks", []).filter(func(check): return not check.passed).map(func(check): return check.partId)
			var frame_ids: Array = MEMBERS.map(func(suffix): return prefix + suffix) + result.partIds
			breaks.append({"target": id, "mode": mode, "passed": work.ready and frame_ids.all(func(frame_id): return failed.has(frame_id)), "failedFrameIds": frame_ids.filter(func(frame_id): return failed.has(frame_id))})
	checks["each_parent_removal_or_movement_breaks_selected_frame"] = breaks.all(func(control): return control.passed)
	var reordered = _copy(before)
	var upstream: Array = fixture.upstreamIds.duplicate()
	upstream.reverse()
	var repeat: Dictionary = Frame.add_frame_on_support(reordered, prefix, fixture.supportId, upstream)
	checks["ancestor_order_does_not_change_committed_frame"] = repeat.ready and _digest(reordered.snapshot()) == _digest(b.snapshot())
	row["checks"] = checks
	row["dependencyBreaks"] = breaks
	row["passed"] = checks.values().all(func(value): return bool(value))
	return row

func _negative(mode: String) -> Dictionary:
	var fixture := _fixture()
	var b = fixture.b
	var upstream: Array = fixture.upstreamIds.duplicate()
	var root = _find(b, "ground")
	var support = _find(b, fixture.supportId)
	match mode:
		"missing_support": b.parts.erase(support)
		"missing_ancestor": upstream = []
		"duplicate_ancestor": upstream.append("ground")
		"support_repeated": upstream.append(fixture.supportId)
		"invalid_id_type": upstream = [42]
		"oversized":
			for i in range(Frame.MAX_SUPPORT_CLOSURE): upstream.append("absent_%d" % i)
		"duplicate_source": b.add_part(root.snapshot())
		"unrelated_root":
			var record: Dictionary = root.snapshot()
			record.id = "unrelated_ground"
			record.position.x += 100.0
			b.add_part(record)
			upstream.append(record.id)
		"cyclic_obligations":
			root.recipe["physicalRequiredSeatPartIds"] = [support.id]
			support.recipe["physicalRequiredSeatPartIds"] = [root.id]
		"parent_no_collision": root.collision_enabled = false
		"parent_moved": root.position.x += 100.0
		"support_moved": support.position.x += 100.0
		"forged_root_flag": support.recipe["physicalRoot"] = true
		"forged_root_intent":
			support.physical_intent = "structural_root"
			support.recipe.physicalIntent = "structural_root"
		"forged_cached_path":
			root.position.x += 100.0
			support.recipe["physicalSupportPartIds"] = [root.id]
			support.recipe["physicalSupportCoverage"] = [{"supported": true, "supportPartId": root.id}]
		"property_visual": root.physical_intent = "visual_detail"
		"recipe_visual": root.recipe.physicalIntent = "visual_detail"
		"intent_conflict": root.physical_intent = "structural_root"
		"frame_intent_conflict": _find(b, PREFIXES[0] + "_lintel").recipe["physicalIntent"] = "visual_detail"
		"root_off_zero": root.position.y += 0.03
		"invalid_required_array": support.recipe["physicalRequiredSupportPartIds"] = {}
		"invalid_fact_record":
			support.recipe["physicalRequiredSeatPartIds"] = [root.id]
			support.recipe["physicalRequiredSeatFacts"] = ["invalid"]
		"invalid_fact_vector":
			support.recipe["physicalRequiredSeatPartIds"] = [root.id]
			support.recipe["physicalRequiredSeatFacts"] = [{"seatId": root.id, "loadDirection": "world_down", "seatFace": "max_y", "localPatchCenter": "invalid", "localPatchHalfExtents": Vector2.ONE}]
		"missing_mandatory_dependency": support.recipe["physicalRequiredSupportPartIds"] = ["not_supplied"]
		"unsupported_mandatory_field": support.recipe["physicalRequiredAnchorPartIds"] = [root.id]
		"huge_finite_bounds": support.size.x = 1.0e12
		"nonfinite_bounds": support.size.x = NAN
		"late_socket_failure": _find(b, PREFIXES[0] + "_sign_arm").size.y = 0.02
	var before := _digest(b.snapshot())
	var aliases: Array = b.parts.duplicate()
	var result: Dictionary = Frame.add_frame_on_support(b, PREFIXES[0], fixture.supportId, upstream)
	return {"mode": mode, "result": result, "passed": not result.ready and not String(result.get("reason", "")).is_empty() and _digest(b.snapshot()) == before and range(aliases.size()).all(func(i): return is_same(aliases[i], b.parts[i]))}

func _direct_parity() -> Dictionary:
	var fixture := _fixture(1, false, true)
	var original: Dictionary = fixture.b.snapshot()
	var legacy = _copy(original)
	var explicit = _copy(original)
	var a: Dictionary = Frame.add_frame(legacy, PREFIXES[0], fixture.supportId)
	var c: Dictionary = Frame.add_frame_on_support(explicit, PREFIXES[0], fixture.supportId, [])
	var elevated := _fixture()
	var before := _digest(elevated.b.snapshot())
	var rejected: Dictionary = Frame.add_frame(elevated.b, PREFIXES[0], elevated.supportId)
	return {"legacy": a, "explicit": c, "legacyElevatedRejection": rejected,
		"passed": a.ready and c.ready and c.expectedPartCount == 12 and _digest(legacy.snapshot()) == _digest(explicit.snapshot()) and not rejected.ready and _digest(elevated.b.snapshot()) == before}

func _unchanged_except_frame(before: Dictionary, after: Dictionary, prefix: String, additions: Array) -> bool:
	if after.parts.size() != before.parts.size() + 5: return false
	var a := before.duplicate(true)
	var c := after.duplicate(true)
	a.erase("parts")
	c.erase("parts")
	if _digest(a) != _digest(c): return false
	var members: Array = MEMBERS.map(func(suffix): return prefix + suffix)
	for i in range(before.parts.size()):
		if before.parts[i].id != after.parts[i].id: return false
		if not members.has(before.parts[i].id) and _digest(before.parts[i]) != _digest(after.parts[i]): return false
	return after.parts.slice(before.parts.size()).all(func(part): return additions.has(part.id))

func _copy(snapshot: Dictionary):
	var b = Blueprint.new(snapshot.id, snapshot.seed, snapshot.style)
	b.set_recipe(snapshot.recipe)
	b.set_room_records(snapshot.rooms)
	for record in snapshot.parts:
		var part = b.add_part(record)
		part.physical_intent = record.physicalIntent
		b.physical_parts_by_id[part.id] = part
	return b

func _find(b, id: String):
	for part in b.parts:
		if part.id == id: return part
	return null

func _digest(value: Variant) -> String:
	return var_to_bytes(value).hex_encode().sha256_text()
