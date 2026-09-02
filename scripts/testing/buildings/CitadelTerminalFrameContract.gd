extends SceneTree

## Unwired source/service contract only; no composer, scene or publication calls.
## VOXEL_TERMINAL_FRAME_REPORT: new absolute JSON path in an existing directory.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const BUILDER := "res://scripts/buildings/TerminalShopFrameBuilder.gd"
const BASELINE := "res://artifacts/citadel-visual-reset/roof-prototype-freeze-01/prototype.bin"
const SHA := "7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5"
const PREFIXES := ["urban_terminal_00", "urban_terminal_01", "urban_terminal_02"]
const SUPPORT := "urban_market_plaza_retaining"
const MEMBERS := ["_jamb_-1", "_jamb_1", "_lintel", "_bracket_-1", "_bracket_1"]
const ADDITIONS := ["_awning_rail_-1", "_awning_rail_1", "_sign_mount_base", "_sign_mount", "_sign_mount_top"]
var _path := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var started := Time.get_ticks_msec()
	_path = OS.get_environment("VOXEL_TERMINAL_FRAME_REPORT").strip_edges().simplify_path()
	var report := {"evidenceLevel": "source_service_contract_with_mutation_controls", "passed": false,
		"baselinePath": BASELINE, "baselineSha256": SHA, "builder": BUILDER, "checks": {},
		"doesNotProve": "Rendered payload/contact, live physics, navigation, gameplay, general seeds or whole-citadel physical acceptance. Original physical failures remain diagnostic."}
	# Refuse existing destinations, including aliases to immutable evidence.
	if not _path.is_absolute_path() or _path.get_extension().to_lower() != "json" or FileAccess.file_exists(_path):
		_path = ""
		_finish(report, "require_new_absolute_json_report_path")
		return
	if FileAccess.get_sha256(BASELINE) != SHA:
		_finish(report, "baseline_sha_mismatch_or_missing")
		return
	var file := FileAccess.open(BASELINE, FileAccess.READ)
	if file == null:
		_finish(report, "baseline_open_failed")
		return
	var envelope = file.get_var(false) # Never deserialize objects or regenerate input.
	var valid_read := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not valid_read or not envelope is Dictionary or not envelope.get("output") is Dictionary:
		_finish(report, "invalid_baseline_envelope")
		return
	var frozen: Dictionary = envelope.output
	if not frozen.get("sourceSnapshot") is Dictionary or not frozen.get("fixture") is Dictionary:
		_finish(report, "invalid_baseline_output")
		return
	if not ResourceLoader.exists(BUILDER):
		_finish(report, "builder_not_available")
		return
	var builder = load(BUILDER)
	if builder == null or not builder.has_method("add_frame"):
		_finish(report, "builder_api_missing")
		return
	var source: Dictionary = frozen.sourceSnapshot
	var before = _copy(source)
	var after = _copy(source)
	var success_aliases := _capture_aliases(after)
	var foundation = _find(after, SUPPORT)
	var foundation_before := _digest(foundation.snapshot()) if foundation != null else ""
	var checks: Dictionary = report.checks
	checks["baseline_roundtrip_exact"] = _digest(before.snapshot()) == _digest(source)
	var setups: Array = []
	var declared: Array = []
	for prefix in PREFIXES:
		var setup: Dictionary = builder.add_frame(after, prefix, SUPPORT)
		setups.append({"prefix": prefix, "result": setup})
		declared.append_array(setup.get("partIds", []))
	report["setups"] = setups
	checks["all_three_setups_ready"] = setups.size() == 3 and setups.all(func(s): return bool(s.result.get("ready", false)))
	checks["successful_commit_preserves_original_aliases"] = _aliases_preserved(after, success_aliases)
	checks["successful_commit_preserves_foundation_identity_and_snapshot"] = foundation != null and is_same(_find(after, SUPPORT), foundation) and _digest(foundation.snapshot()) == foundation_before
	var candidate: Dictionary = after.snapshot() # Before derived physical caches.
	var old_ids: Array = source.parts.map(func(p): return String(p.id))
	var new_ids: Array = candidate.parts.map(func(p): return String(p.id))
	checks["unique_source_and_output_ids"] = not old_ids.has("") and not new_ids.has("") and _unique(old_ids) and _unique(new_ids)
	checks["original_part_order_preserved"] = new_ids.filter(func(id): return old_ids.has(id)) == old_ids
	var source_header := source.duplicate(true)
	var candidate_header := candidate.duplicate(true)
	source_header.erase("parts")
	candidate_header.erase("parts")
	checks["rooms_recipe_and_blueprint_identity_exact"] = _digest(source_header) == _digest(candidate_header)
	var unexpected: Array = []
	var changed: Array = []
	var targets: Array = []
	var allowed_additions: Array = []
	for prefix in PREFIXES:
		for suffix in MEMBERS: targets.append(prefix + suffix)
		targets.append(prefix + "_sign_arm")
		for suffix in ["_awning_rail_-1", "_awning_rail_1", "_sign_mount_base", "_sign_mount", "_sign_mount_top"]: allowed_additions.append(prefix + suffix)
	for original in source.parts:
		var current = _find(after, String(original.id))
		if current == null or not _allowed_change(original, current.snapshot(), targets): unexpected.append(original.id)
		if current != null and _digest(original) != _digest(current.snapshot()): changed.append(original.id)
	var added: Array = new_ids.filter(func(id): return not old_ids.has(id))
	checks["only_permitted_original_changes"] = unexpected.is_empty()
	checks["exact_fifteen_declared_additions"] = declared == allowed_additions and added == allowed_additions
	checks["all_15_members_and_three_sign_arms_present"] = targets.size() == 18 and targets.all(func(id): return old_ids.has(id) and new_ids.has(id))
	report.merge({"changedPartIds": changed, "addedPartIds": added, "unexpectedChangeIds": unexpected})
	print("terminal frame: whole-blueprint physical before/after")
	var previous: Dictionary = before.validate_physical_integrity()
	var current: Dictionary = after.validate_physical_integrity()
	report["beforePhysical"] = previous
	report["afterPhysical"] = current
	report["addedViolations"] = current.violations.filter(func(v): return not previous.violations.has(v))
	report["removedViolations"] = previous.violations.filter(func(v): return not current.violations.has(v))
	checks["integrated_roofs_253_baseline"] = previous.violations.size() == 253
	checks["no_added_physical_violations"] = report.addedViolations.is_empty()
	checks["all_frame_and_sign_checks_pass"] = (targets + added).all(func(id): return _part_passes(current, id))
	print("terminal frame: actual furnishing planner on independent copies")
	var furniture_before = Furniture.build(_copy(source), int(frozen.fixture.furnitureSeed))
	var furniture_after = Furniture.build(_copy(candidate), int(frozen.fixture.furnitureSeed))
	checks["actual_planner_nonempty"] = furniture_before != null and furniture_after != null and not furniture_before.parts.is_empty()
	report["reservationCount"] = 0 if furniture_before == null else furniture_before.protected_access_reservations.size()
	report["reservationLimitation"] = "This fixture has empty reservations; equality does not prove occupied-reservation coverage."
	checks["actual_furniture_snapshot_parity"] = furniture_before != null and furniture_after != null and _digest(furniture_before.snapshot()) == _digest(furniture_after.snapshot())
	checks["actual_reservation_parity"] = furniture_before != null and furniture_after != null and _digest(furniture_before.protected_access_reservations) == _digest(furniture_after.protected_access_reservations)
	var controls: Array = []
	# Positive checks gate mutation evidence: pre-existing failures cannot pass it.
	if checks.all_three_setups_ready and checks.all_frame_and_sign_checks_pass:
		for prefix in PREFIXES:
			for target in [prefix + "_jamb_-1", prefix + "_jamb_1", SUPPORT, prefix + "_lintel", prefix + "_sign_mount"]:
				for mode in ["remove", "move", "unroot"]:
					controls.append(_negative(candidate, prefix, target, mode))
	report["negativeControls"] = controls
	checks["all_45_member_specific_controls_pass"] = controls.size() == 45 and controls.all(func(c): return bool(c.passed))
	var mount_controls: Array = []
	var upstream_controls: Array = []
	if checks.all_three_setups_ready and checks.all_frame_and_sign_checks_pass:
		for prefix in PREFIXES:
			for suffix in ["_sign_mount_base", "_sign_mount_top"]:
				for mode in ["remove", "move", "unroot"]:
					mount_controls.append(_negative(candidate, prefix, prefix + suffix, mode))
			for suffix in ["_jamb_-1", "_jamb_1", "_lintel", "_sign_mount_base", "_sign_mount", "_sign_mount_top"]:
				var mode := "failed_mandatory_seat_with_alternate" if suffix == "_sign_mount_base" else "failed_mandatory_seat"
				upstream_controls.append(_negative(candidate, prefix, prefix + suffix, mode))
	report["signMountNegativeControls"] = mount_controls
	report["mandatoryUpstreamNegativeControls"] = upstream_controls
	report["mandatoryUpstreamLimitation"] = "Synthetic post-construction source validation only, not live destruction/publication behavior. The three corrected base cases add a real alternate foundation before positive prechecks; original precondition-invalid cases are preserved in terminal-frame-contract-03 and dependency-terminal-after-01."
	checks["all_18_base_top_sign_mount_controls_pass"] = mount_controls.size() == 18 and mount_controls.all(func(c): return bool(c.passed))
	var input_controls: Array = []
	var input_positives: Array = []
	for prefix in PREFIXES:
		var focused := _focused(source, prefix)
		var positive = _copy(focused)
		var aliases := _capture_aliases(positive)
		var setup: Dictionary = builder.add_frame(positive, prefix, SUPPORT)
		var positive_snapshot: Dictionary = positive.snapshot()
		var aliases_ok := _aliases_preserved(positive, aliases)
		var physical: Dictionary = positive.validate_physical_integrity()
		var positive_ok := bool(setup.get("ready", false)) and _complete_frame_chain(positive, physical, prefix)
		# Compare before validation: derived physical caches are not source data.
		var exact_output := _digest(positive_snapshot) == _digest(_focused(candidate, prefix))
		input_positives.append({"prefix": prefix, "passed": positive_ok and exact_output and aliases_ok, "ready": setup.get("ready", false), "exactWholeBlueprintOutput": exact_output, "originalAliasesPreserved": aliases_ok})
		if not positive_ok or not exact_output or not aliases_ok: continue
		var required: Array = [SUPPORT, prefix + "_sign_arm"]
		for suffix in MEMBERS: required.append(prefix + suffix)
		# Fixed 72-case input matrix per bay; every call uses a fresh small copy.
		for target_id in required:
			for mode in ["remove", "duplicate", "wrong_kind", "nonfinite_position", "external_dependency"]:
				input_controls.append(_input_negative(focused, builder, prefix, target_id, mode))
			if target_id != SUPPORT:
				input_controls.append(_input_negative(focused, builder, prefix, target_id, "wrong_material"))
		for suffix in ADDITIONS:
			input_controls.append(_input_negative(focused, builder, prefix, prefix + suffix, "occupied_output_id"))
		for mode in ["nonfinite_size", "nonfinite_rotation", "zero_size", "rotate", "move"]:
			input_controls.append(_input_negative(focused, builder, prefix, prefix + "_lintel", mode))
		for suffix in ["_sign_arm", "_jamb_-1"]:
			input_controls.append(_input_negative(focused, builder, prefix, prefix + suffix, "move"))
		input_controls.append(_input_negative(focused, builder, prefix, SUPPORT, "unroot"))
		input_controls.append(_input_negative(focused, builder, prefix, SUPPORT, "forged_elevated_foundation"))
		for mode in ["forged_root_flag", "forged_root_intent", "duplicate_unrelated"]:
			input_controls.append(_input_negative(focused, builder, prefix, prefix + "_lintel", mode))
		input_controls.append(_input_negative(focused, builder, prefix, prefix + "_sign_arm", "late_socket_failure"))
		input_controls.append(_input_negative(positive_snapshot, builder, prefix, "", "already_built"))
		for suffix in ["_sign_arm", "_bracket_-1", "_bracket_1"]:
			for mode in ["intent_visual_detail", "intent_portal", "recipe_intent_visual_detail", "recipe_intent_portal"]:
				input_controls.append(_input_negative(focused, builder, prefix, prefix + suffix, mode))
	report["builderPositivePrechecks"] = input_positives
	report["builderInputNegativeControls"] = input_controls
	checks["all_three_builder_positive_prechecks_pass"] = input_positives.size() == 3 and input_positives.all(func(c): return bool(c.passed))
	checks["all_216_builder_inputs_rejected_atomically"] = input_controls.size() == 216 and input_controls.all(func(c): return bool(c.passed))
	checks["baseline_file_unchanged"] = FileAccess.get_sha256(BASELINE) == SHA
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	# Preserve every original gate. Scope the additional runtime-closure probe
	# separately, without turning its known failures into successful controls.
	report["constructionChecksPassed"] = checks.values().all(func(value): return bool(value))
	report["postconstructionDiagnosticChecks"] = {"all_18_mandatory_upstream_controls_pass": upstream_controls.size() == 18 and upstream_controls.all(func(c): return bool(c.passed))}
	report["postconstructionDiagnosticsPassed"] = report.postconstructionDiagnosticChecks.values().all(func(value): return bool(value))
	report["passed"] = report.constructionChecksPassed and report.postconstructionDiagnosticsPassed
	_finish(report, "passed" if report.passed else "contract_failed")

func _allowed_change(old: Dictionary, current: Dictionary, targets: Array) -> bool:
	if not targets.has(String(old.id)): return _digest(old) == _digest(current)
	var a := old.duplicate(true)
	var b := current.duplicate(true)
	if String(old.id).ends_with("_sign_arm"):
		# Additive required-anchor recipe only; no material/render/intent changes.
		for key in ["physicalRequiredAnchorPartIds", "physicalRequiredAnchorFacts"]:
			if not a.recipe.has(key): b.recipe.erase(key)
	else:
		var bracket := "_bracket_" in String(old.id)
		var recipe_keys := ["physicalRequiredAnchorPartIds", "physicalRequiredAnchorFacts", "preserveBearingFaces"] if bracket else ["physicalIntent", "physicalRequiredSeatPartIds", "physicalRequiredSeatFacts", "preserveBearingFaces"]
		if bracket and bool(current.collision): return false
		if not bracket and (not bool(current.collision) or current.physicalIntent != "structural_mass"): return false
		if current.recipe.get("preserveBearingFaces") != true: return false
		for record in [a, b]:
			if not bracket:
				record.erase("physicalIntent")
				record.erase("collision")
			for key in recipe_keys: record.recipe.erase(key)
			if bracket:
				for key in ["position", "rotation", "size"]: record.erase(key)
	return _digest(a) == _digest(b)

func _negative(source: Dictionary, prefix: String, target_id: String, mode: String) -> Dictionary:
	# Reduced synthetic fixture retains complete, unmodified source records for
	# this bay and its actual declared retaining support. Whole-citadel parity
	# is tested above; repeating unrelated 4,000-part roofs is not needed here.
	var focused := _focused(source, prefix)
	var blueprint = _copy(focused) # Never reuse inferred roots or lookup caches.
	var alternate_record: Dictionary = {}
	if mode == "failed_mandatory_seat_with_alternate":
		# Explicit synthetic fixture correction: the original base cases lacked
		# an incidental route. Supply a real column, not a forced root/cache flag.
		var base = _find(blueprint, target_id)
		if base == null:
			return {"passed": false, "reason": "alternate_fixture_base_missing"}
		var height: float = base.position.y - base.size.y * 0.5
		if height <= 0.0:
			return {"passed": false, "reason": "alternate_fixture_height_invalid"}
		alternate_record = {"id": prefix + "_synthetic_alternate_foundation", "kind": "foundation", "material": "stone_foundation",
			"position": Vector3(base.position.x, height * 0.5, base.position.z), "size": Vector3(base.size.x, height, base.size.z),
			"collision": true, "semantic": "synthetic_alternate_support", "recipe": {}}
		blueprint.add_part(alternate_record)
	var positive: Dictionary = blueprint.validate_physical_integrity()
	var target = _find(blueprint, target_id)
	var header := prefix + "_lintel"
	var jambs := [prefix + "_jamb_-1", prefix + "_jamb_1"]
	var expected: Array = [header]
	if target_id == SUPPORT: expected = jambs
	elif target_id == prefix + "_sign_mount": expected = [prefix + "_sign_arm"]
	elif target_id == prefix + "_sign_mount_base": expected = [prefix + "_sign_mount"]
	elif target_id == prefix + "_sign_mount_top": expected = [prefix + "_sign_arm"]
	# A header cannot support its own jambs. Its removal must instead reject
	# both rails which explicitly bear on it, plus show the required header absent.
	elif target_id == header and mode == "remove": expected = [prefix + "_awning_rail_-1", prefix + "_awning_rail_1"]
	elif target_id in jambs and mode != "remove": expected = [target_id, header]
	if mode in ["failed_mandatory_seat", "failed_mandatory_seat_with_alternate"]:
		expected = [target_id]
		for part in blueprint.parts:
			if (part.recipe.get("physicalRequiredSeatPartIds", []) as Array).has(target_id) or (part.recipe.get("physicalRequiredAnchorPartIds", []) as Array).has(target_id):
				expected.append(String(part.id))
	var record := {"prefix": prefix, "targetId": target_id, "mutation": mode, "expectedFailedIds": expected, "passed": false}
	if target == null: return record
	# Include every tested dependent (rails, brackets, base and top included),
	# not just the old five-member subset. Missing/duplicate checks cannot pass.
	var focus_ids: Array = _frame_ids(prefix) + [target_id] + expected
	record["positiveChecks"] = positive.checks.filter(func(c): return focus_ids.has(String(c.partId)))
	record["positivePrecheckPassed"] = focus_ids.all(func(id): return _part_passes(positive, id))
	if not record.positivePrecheckPassed:
		record["reason"] = "reduced_fixture_positive_failed"
		return record
	if not alternate_record.is_empty():
		var column = _find(blueprint, alternate_record.id)
		var mount = _find(blueprint, prefix + "_sign_mount")
		var alternate_ok: bool = _part_passes(positive, column.id) and blueprint.is_grounded_structural_root(column) and (target.recipe.get("physicalSupportPartIds", []) as Array).has(column.id)
		var mount_clear: bool = mount != null and not (mount.recipe.get("physicalSupportPartIds", []) as Array).has(column.id) and not blueprint.transformed_parts_overlap(mount, column, blueprint.PHYSICAL_CONTACT_MARGIN)
		record["addedSyntheticColumn"] = alternate_record
		record["alternateSupportPrecheckPassed"] = alternate_ok
		record["dependentDoesNotDirectlyTouchAlternate"] = mount_clear
		if not alternate_ok or not mount_clear:
			record["reason"] = "alternate_support_precondition_failed"
			return record
	record["targetBefore"] = target.snapshot()
	match mode:
		"remove": blueprint.parts.erase(target)
		"move": target.position += Vector3(0, 1000, 0)
		"unroot":
			# Withdraw collision-backed structural eligibility in place, not a
			# forged resolved-cache edit. Keep the member structural so it fails.
			target.collision_enabled = false
			target.physical_intent = "structural_mass"
			target.recipe["physicalIntent"] = "structural_mass"
			target.recipe.erase("physicalRoot")
		"failed_mandatory_seat", "failed_mandatory_seat_with_alternate":
			# Retain actual geometry and incidental rooting; invalidate a declared
			# upstream joint, never a cached resolver result.
			var facts: Array = target.recipe.get("physicalRequiredSeatFacts", []).duplicate(true)
			var seats: Array = target.recipe.get("physicalRequiredSeatPartIds", []).duplicate(true)
			if facts.is_empty() or seats.is_empty() or expected.size() < 2:
				record["reason"] = "missing_mandatory_joint_or_dependent"
				return record
			var absent := prefix + "_absent_mandatory_seat"
			if _find(blueprint, absent) != null: return record
			var seat_index := seats.find(String(facts[0].seatId))
			if seat_index < 0: return record
			seats[seat_index] = absent
			facts[0]["seatId"] = absent
			target.recipe["physicalRequiredSeatPartIds"] = seats
			target.recipe["physicalRequiredSeatFacts"] = facts
	record["targetAfter"] = {} if mode == "remove" else target.snapshot()
	var physical: Dictionary = blueprint.validate_physical_integrity()
	var failed: Array = physical.checks.filter(func(c): return not bool(c.passed)).map(func(c): return String(c.partId))
	record["affectedChecks"] = physical.checks.filter(func(c): return expected.has(String(c.partId)))
	record["passed"] = expected.all(func(id): return failed.has(id))
	if mode == "remove": record["passed"] = record.passed and _find(blueprint, target_id) == null
	if mode in ["failed_mandatory_seat", "failed_mandatory_seat_with_alternate"]:
		record["upstreamOwnCheckFails"] = failed.has(target_id)
		record["upstreamStillIncidentallyRooted"] = blueprint.has_rooted_support_chain(target, {})
		record["passed"] = record.passed and record.upstreamOwnCheckFails and record.upstreamStillIncidentallyRooted
	# An unrelated failed part (or an absent check) never satisfies the control.
	print("terminal frame control: ", prefix, " ", mode, " ", target_id, " = ", record.passed)
	return record

func _input_negative(source: Dictionary, builder, prefix: String, target_id: String, mode: String) -> Dictionary:
	# Synthetic source/API contract only. Snapshot AFTER arranging invalid input,
	# BEFORE calling the builder; never resolve this source to test atomicity.
	var blueprint = _copy(source)
	var target = _find(blueprint, target_id)
	var record := {"prefix": prefix, "targetId": target_id, "mutation": mode, "passed": false}
	if target == null and mode not in ["occupied_output_id", "already_built"]:
		record["reason"] = "mutation_target_missing"
		return record
	match mode:
		"remove": blueprint.parts.erase(target)
		"duplicate": blueprint.add_part(target.snapshot())
		"wrong_kind": target.kind = "window"
		"wrong_material": target.material_id = "stone_foundation"
		"intent_visual_detail": target.physical_intent = "visual_detail"
		"intent_portal": target.physical_intent = "portal"
		"recipe_intent_visual_detail": target.recipe["physicalIntent"] = "visual_detail"
		"recipe_intent_portal": target.recipe["physicalIntent"] = "portal"
		"external_dependency":
			# Includes the supplied foundation; external obligations must not be
			# silently overwritten even when incidental physical rooting exists.
			target.recipe["physicalRequiredSupportPartIds"] = [prefix + "_external_required_support"]
		"forged_root_flag": target.recipe["physicalRoot"] = true
		"forged_root_intent":
			target.physical_intent = "structural_root"
			target.recipe["physicalIntent"] = "structural_root"
		"forged_elevated_foundation":
			# Translate the complete bay: all relative joints remain compatible.
			# Only the foundation's real blueprint-y=0 grounding is withdrawn.
			for part in blueprint.parts: part.position.y += 10.0
			target.recipe["physicalRoot"] = true
			target.physical_intent = "structural_root"
			target.recipe["physicalIntent"] = "structural_root"
		"late_socket_failure":
			# Finite, positive timber beam; source seats and frame orientation
			# still fit. The generated sign socket no longer fits its own body.
			target.size.y = 0.02
		"duplicate_unrelated":
			var unrelated: Dictionary = target.snapshot()
			unrelated["id"] = prefix + "_unrelated_duplicate"
			blueprint.add_part(unrelated)
			blueprint.add_part(unrelated)
		"nonfinite_position": target.position.x = INF
		"nonfinite_size": target.size.y = INF
		"nonfinite_rotation": target.rotation.z = NAN
		"zero_size": target.size.y = 0.0
		"rotate": target.rotation.z = 0.25
		"move": target.position += Vector3(0, 1000, 0)
		"unroot":
			target.collision_enabled = false
			target.physical_intent = "structural_mass"
			target.recipe["physicalIntent"] = "structural_mass"
			target.recipe.erase("physicalRoot")
		"occupied_output_id":
			if target != null: return record
			var occupied: Dictionary = _find(blueprint, prefix + "_lintel").snapshot()
			occupied["id"] = target_id
			blueprint.add_part(occupied)
		"already_built": pass
		_:
			record["reason"] = "unknown_mutation"
			return record
	var before := _digest(blueprint.snapshot())
	var aliases := _capture_aliases(blueprint)
	var result: Dictionary = builder.add_frame(blueprint, prefix, SUPPORT)
	var after := _digest(blueprint.snapshot())
	var aliases_ok := _aliases_preserved(blueprint, aliases)
	var retry: Dictionary = builder.add_frame(blueprint, prefix, SUPPORT)
	var retried := _digest(blueprint.snapshot())
	aliases_ok = aliases_ok and _aliases_preserved(blueprint, aliases)
	record.merge({"builder": result, "retryBuilder": retry, "beforeSha256": before, "afterSha256": after,
		"retrySha256": retried, "snapshotPreserved": before == after and before == retried, "originalAliasesPreserved": aliases_ok})
	record["passed"] = result.get("ready") == false and retry.get("ready") == false and not String(result.get("reason", "")).is_empty() and not String(retry.get("reason", "")).is_empty() and record.snapshotPreserved and aliases_ok
	print("terminal builder input control: ", prefix, " ", mode, " ", target_id, " = ", record.passed)
	return record

func _capture_aliases(blueprint) -> Dictionary:
	return {"array": blueprint.parts, "parts": blueprint.parts.duplicate(),
		"recipes": blueprint.parts.map(func(part): return part.recipe),
		"recipeDigests": blueprint.parts.map(func(part): return _digest(part.recipe))}

func _aliases_preserved(blueprint, aliases: Dictionary) -> bool:
	if not is_same(blueprint.parts, aliases.array) or blueprint.parts.size() < aliases.parts.size(): return false
	for index in range(aliases.parts.size()):
		if not is_same(blueprint.parts[index], aliases.parts[index]): return false
		# Success may replace a member's recipe, but must not mutate a caller's
		# retained old recipe alias. Failure must preserve the whole snapshot too.
		if _digest(aliases.recipes[index]) != aliases.recipeDigests[index]: return false
	return true

func _focused(source: Dictionary, prefix: String) -> Dictionary:
	var result := source.duplicate(true)
	result.parts = result.parts.filter(func(part): return part.id == SUPPORT or String(part.id).begins_with(prefix + "_"))
	return result

func _frame_ids(prefix: String) -> Array:
	var ids: Array = [prefix + "_sign_arm"]
	for suffix in MEMBERS + ADDITIONS: ids.append(prefix + suffix)
	return ids

func _complete_frame_chain(blueprint, physical: Dictionary, prefix: String) -> bool:
	var ids: Array = _frame_ids(prefix) + [SUPPORT]
	if ids.size() != 12 or not ids.all(func(id): return _part_passes(physical, id)): return false
	var seats := {
		"_jamb_-1": [SUPPORT], "_jamb_1": [SUPPORT],
		"_lintel": [prefix + "_jamb_-1", prefix + "_jamb_1"],
		"_awning_rail_-1": [prefix + "_lintel"], "_awning_rail_1": [prefix + "_lintel"],
		"_sign_mount_base": [prefix + "_lintel"], "_sign_mount": [prefix + "_sign_mount_base"],
		"_sign_mount_top": [prefix + "_sign_mount"]}
	var anchors := {
		"_bracket_-1": [prefix + "_jamb_-1", prefix + "_awning_rail_-1"],
		"_bracket_1": [prefix + "_jamb_1", prefix + "_awning_rail_1"],
		"_sign_arm": [prefix + "_sign_mount_top"]}
	for id in ids:
		if not blueprint.has_finite_positive_bounds(_find(blueprint, id)): return false
	for suffix in seats:
		var part = _find(blueprint, prefix + suffix)
		var facts: Array = part.recipe.get("physicalRequiredSeatFacts", [])
		if part.recipe.get("physicalRequiredSeatPartIds") != seats[suffix] or facts.size() != seats[suffix].size(): return false
		if facts.map(func(fact): return String(fact.get("seatId", ""))) != seats[suffix]: return false
		if not facts.all(func(fact): return blueprint.has_rooted_bearer_seat(part, fact)): return false
	for suffix in anchors:
		var part = _find(blueprint, prefix + suffix)
		var facts: Array = part.recipe.get("physicalRequiredAnchorFacts", [])
		if part.recipe.get("physicalRequiredAnchorPartIds") != anchors[suffix] or facts.size() != anchors[suffix].size(): return false
		if facts.map(func(fact): return String(fact.get("anchorId", ""))) != anchors[suffix]: return false
		if not facts.all(func(fact): return blueprint.has_rooted_attachment_socket(part, fact)): return false
	return true

func _copy(source: Dictionary):
	var result = Blueprint.new(source.id, source.seed, source.style)
	result.recipe = source.recipe.duplicate(true)
	result.rooms = source.rooms.duplicate(true)
	for part in source.parts: result.add_part(part)
	return result

func _find(blueprint, id: String):
	for part in blueprint.parts:
		if part.id == id: return part
	return null

func _part_passes(physical: Dictionary, id: String) -> bool:
	var matches: Array = physical.checks.filter(func(c): return String(c.partId) == id)
	return matches.size() == 1 and bool(matches[0].passed)

func _unique(ids: Array) -> bool:
	var seen: Dictionary = {}
	for id in ids: seen[id] = true
	return seen.size() == ids.size()

func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort_custom(func(a, b): return var_to_bytes(a).hex_encode() < var_to_bytes(b).hex_encode())
		for key in keys: result[key] = _canonical(value[key])
		return result
	if value is Array: return value.map(func(item): return _canonical(item))
	return value

func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(_canonical(value)))
	return context.finish().hex_encode()

func _finish(report: Dictionary, status: String) -> void:
	report["status"] = status
	print("VOXEL_TERMINAL_FRAME_REPORT ", _path, " status=", status)
	var output := FileAccess.open(_path, FileAccess.WRITE) if not _path.is_empty() else null
	if output == null:
		push_error("Terminal frame report unavailable: " + status)
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.flush()
	var error := output.get_error()
	output.close()
	quit(2 if error != OK else (0 if report.passed else 1))
