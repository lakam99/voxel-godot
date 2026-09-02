extends SceneTree

## SHA-bound source-only candidate. It declares finite housed overlap between
## failed bottom facade panels and already rooted masonry from another producer.
## It never adds, moves, removes, recolours, or disables visible geometry.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Recipe = preload("res://scripts/buildings/MasonryPartyWallBearingRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_BYTES := 32 * 1024 * 1024
var checks: Dictionary = {}
var evidence: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var report_path := OS.get_environment("VOXEL_PARTY_WALL_REPORT").simplify_path()
	var output_path := OS.get_environment("VOXEL_PARTY_WALL_OUTPUT").simplify_path()
	var input_path := OS.get_environment("VOXEL_PARTY_WALL_INPUT").simplify_path()
	var input_sha := OS.get_environment("VOXEL_PARTY_WALL_SHA").to_lower()
	var expected_output_sha := OS.get_environment("VOXEL_PARTY_WALL_EXPECTED_OUTPUT_SHA").to_lower()
	var expected_before_text := OS.get_environment("VOXEL_PARTY_WALL_EXPECTED_BEFORE")
	var expected_after_text := OS.get_environment("VOXEL_PARTY_WALL_EXPECTED_AFTER")
	var expected_before := 9 if expected_before_text.is_empty() else int(expected_before_text)
	var expected_after := 2 if expected_after_text.is_empty() else int(expected_after_text)
	var exact_oracle_supplied := not expected_output_sha.is_empty()
	if not _fresh(report_path, "json") or not _fresh(output_path) or not input_path.is_absolute_path() or input_sha.length() != 64 or input_sha.hex_decode().size() != 32 or (exact_oracle_supplied and (expected_output_sha.length() != 64 or expected_output_sha.hex_decode().size() != 32)) or FileAccess.get_sha256(input_path) != input_sha or expected_before < 1 or expected_after < 0 or expected_after >= expected_before:
		quit(2); return
	var read := _read(input_path)
	if not read.ready: quit(2); return
	var raw: Dictionary = read.value
	if not _archive_schema(raw): quit(2); return
	var frozen := var_to_bytes(raw)
	var baseline = Copy.copy_blueprint(raw.afterSnapshot)
	Copy.clear_caches(baseline)
	var grid := Copy.validation_grid_work(baseline)
	if not grid.ready: quit(2); return
	var before: Dictionary = baseline.validate_physical_integrity()
	var before_ids: Array = Copy.failed_ids(before)
	checks["expected_before_failure_count"] = before_ids.size() == expected_before
	var declarations: Variant = raw.afterSnapshot.recipe.get("facadeApertures")
	var eligible: Array = []
	if declarations is Dictionary:
		for key: String in declarations:
			var declaration: Variant = declarations[key]
			if not declaration is Dictionary or not declaration.get("partIds") is Array: continue
			var failed_declared: Array = declaration.partIds.filter(func(id): return before_ids.has(id))
			if failed_declared.size() >= 2: eligible.append({"key": key, "failedIds": failed_declared})
	eligible.sort_custom(func(a, b): return a.key < b.key)
	checks["one_failed_multi_panel_declaration_selected_generically"] = eligible.size() == 1
	if eligible.size() != 1:
		_finish(report_path, false, {"beforeFailureIds": before_ids, "eligible": eligible}); return
	var declaration_key: String = eligible[0].key
	var source = Copy.copy_blueprint(raw.afterSnapshot)
	var declared_ids: Array = declarations[declaration_key].partIds
	var junction_seats: Array = source.parts.filter(func(part):
		if part == null or part.semantic != "castle_keep_forecourt_pavilion" or declared_ids.has(part.id): return false
		var seat_bounds: AABB = source.transformed_part_bounds(part)
		return eligible[0].failedIds.any(func(id):
			var target = source.find_part(id)
			return target != null and seat_bounds.intersects(source.transformed_part_bounds(target))))
	junction_seats.sort_custom(func(a, b): return a.id < b.id)
	checks["one_explicit_forecourt_masonry_junction_seat"] = junction_seats.size() == 1 and Recipe.declare_party_wall_seat(junction_seats[0], true)
	_target_obligation_controls(source, eligible[0].failedIds)
	var source_before := var_to_bytes(source.snapshot())
	var plan: Dictionary = Recipe.plan(source, declaration_key)
	checks["plan_ready_immutable"] = plan.get("ready", false) and source_before == var_to_bytes(source.snapshot())
	var target_ids: Array = plan.get("targetIds", [])
	checks["exact_three_bottom_targets"] = target_ids.size() == 3 and target_ids.all(func(id): return before_ids.has(id))
	checks["all_changes_have_finite_declared_masonry_facts"] = plan.get("changes", []).size() == target_ids.size() and plan.get("changes", []).all(func(row):
		var target = source.find_part(row.partId)
		var seat = source.find_part(row.seatId)
		var fact: Dictionary = row.fact
		return target != null and seat != null and row.seatRootIds is Array and not row.seatRootIds.is_empty() and fact.get("seatId") == seat.id and fact.get("contactMode") == "housed_overlap" and fact.get("localOverlapCenter") is Vector3 and fact.get("localOverlapHalfExtents") is Vector3 and (fact.localOverlapCenter as Vector3).is_finite() and (fact.localOverlapHalfExtents as Vector3).is_finite() and (fact.localOverlapHalfExtents as Vector3).x > 0.0 and (fact.localOverlapHalfExtents as Vector3).y > 0.0 and (fact.localOverlapHalfExtents as Vector3).z > 0.0)
	_atomic_commit_control(source, plan)
	var applied: Dictionary = Recipe.apply_plan(source, plan)
	checks["bounded_atomic_commit_matches_plan"] = applied.get("ready", false) and var_to_bytes(applied) == var_to_bytes(plan)
	var candidate_snapshot: Dictionary = source.snapshot()
	checks["exact_recipe_only_changes"] = _exact_changes(raw.afterSnapshot, candidate_snapshot, plan.get("changes", []), junction_seats)
	checks["rooms_and_top_recipe_exact"] = var_to_bytes(candidate_snapshot.rooms) == var_to_bytes(raw.afterSnapshot.rooms) and var_to_bytes(candidate_snapshot.recipe) == var_to_bytes(raw.afterSnapshot.recipe)
	var after_b = Copy.copy_blueprint(candidate_snapshot)
	Copy.clear_caches(after_b)
	grid = Copy.validation_grid_work(after_b)
	checks["candidate_validation_bounded"] = grid.ready
	var after: Dictionary = after_b.validate_physical_integrity() if grid.ready else {"checks": [], "violations": []}
	var after_ids: Array = Copy.failed_ids(after)
	var passed_by_id: Dictionary = {}
	for check: Dictionary in after.checks:
		if check.passed: passed_by_id[check.partId] = true
	checks["every_reported_root_witness_passes_collision_backed"] = plan.get("changes", []).all(func(row): return row.seatRootIds.all(func(root_id):
		var root = after_b.find_part(root_id)
		return passed_by_id.has(root_id) and root != null and root.collision_enabled and root.physical_intent == "structural_root" and bool(root.recipe.get("physicalRoot", false))))
	var added_ids: Array = after_ids.filter(func(id): return not before_ids.has(id))
	var removed_ids: Array = before_ids.filter(func(id): return not after_ids.has(id))
	var added_violations: Array = after.violations.filter(func(value): return not before.violations.has(value))
	checks["whole_gate_matches_expected_without_added_failure"] = before_ids.size() == expected_before and after_ids.size() == expected_after and removed_ids.size() == expected_before - expected_after and added_ids.is_empty() and added_violations.is_empty()
	checks["all_declared_facade_failures_cleared"] = eligible[0].failedIds.all(func(id): return not after_ids.has(id))
	checks["only_expected_nonfacade_failures_remain"] = after_ids.all(func(id):
		var part = after_b.find_part(id)
		return part != null and (part.semantic == "citadel_urban_chimney" or String(id).contains("door_bracket")))
	_destructive_controls(after_b, plan.get("changes", []))
	checks["bound_input_and_archives_immutable"] = frozen == var_to_bytes(raw) and FileAccess.get_sha256(input_path) == input_sha and raw.furnitureSnapshot.parts.size() == 152
	var ready: bool = checks.values().all(func(value): return value == true)
	var output_sha := ""
	if ready:
		var candidate: Dictionary = raw.duplicate(true)
		candidate.afterSnapshot = candidate_snapshot
		var history: Array = candidate.get("candidateHistory", []).duplicate(true)
		history.append({"kind": "masonry_party_wall_bearing_candidate", "inputSha256": input_sha,
			"declarationKey": declaration_key, "targetIds": target_ids, "changes": plan.changes,
			"beforeFailureCount": before_ids.size(), "afterFailureCount": after_ids.size(),
			"scope": "Source-only finite housed masonry overlap; zero visible geometry changes."})
		candidate["candidateHistory"] = history
		checks["archive_preserved_history_appended_once"] = _archive_exact(raw, candidate)
		ready = checks.values().all(func(value): return value == true)
		if ready and _write(output_path, var_to_bytes(candidate)): output_sha = FileAccess.get_sha256(output_path)
		else: ready = false
	checks["deterministic_output_matches_supplied_oracle"] = output_sha.length() == 64 and (not exact_oracle_supplied or output_sha == expected_output_sha)
	ready = ready and checks["deterministic_output_matches_supplied_oracle"]
	var report := {"passed": ready, "checks": checks, "inputSha256": input_sha, "outputSha256": output_sha,
		"declarationKey": declaration_key, "plan": plan, "beforeFailureCount": before_ids.size(), "afterFailureCount": after_ids.size(),
		"beforeFailureIds": before_ids, "afterFailureIds": after_ids, "removedFailureIds": removed_ids,
		"addedFailureIds": added_ids, "addedViolations": added_violations, "controlEvidence": evidence,
		"limitations": "Source-only recipe/support proof. No mesh publication, rendering, appearance, gameplay, NPC/navigation, engineering capacity, or headed acceptance."}
	var report_ok := _write(report_path, JSON.stringify(_json(report), "\t").to_utf8_buffer())
	quit(0 if ready and report_ok else (1 if report_ok else 2))

func _destructive_controls(validated, changes: Array) -> void:
	var all_pass := true
	var rows: Array = []
	for change: Dictionary in changes:
		var target = validated.find_part(change.partId)
		var seat = validated.find_part(change.seatId)
		var prior_collision: bool = seat.collision_enabled
		seat.collision_enabled = false
		var rejected: bool = not validated.has_rooted_bearer_seat(target, change.fact)
		seat.collision_enabled = prior_collision
		all_pass = all_pass and rejected
		rows.append({"targetId": change.partId, "seatId": change.seatId, "seatCollisionDisabledRejectsTarget": rejected})
	evidence["seatRemovalRows"] = rows
	checks["disabling_each_declared_seat_invalidates_its_target"] = all_pass and rows.size() == changes.size()

func _atomic_commit_control(source, plan: Dictionary) -> void:
	var tampered: Dictionary = plan.duplicate(true)
	tampered.changes.append({"partId": "missing_party_wall_target", "recipe": {}})
	var before := var_to_bytes(source.snapshot())
	var rejected: Dictionary = Recipe.apply_plan(source, tampered)
	checks["malformed_multi_target_commit_rejects_without_partial_mutation"] = not rejected.get("ready", false) and rejected.get("reason") == "party_wall_plan_target_missing" and before == var_to_bytes(source.snapshot())

func _target_obligation_controls(source, failed_ids: Array) -> void:
	var target = source.find_part(failed_ids[0]) if not failed_ids.is_empty() else null
	var keys := ["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts",
		"physicalRequiredSupportPartIds", "physicalSupportCoverage",
		"physicalRequiredAnchorPartIds", "physicalRequiredAnchorFacts",
		"physicalRequiredAssemblyBearingBlockIds", "physicalRequiredRoofFramePartIds",
		"physicalRequiredRoofFramePostIds", "physicalRequiredCoverageByZIndex",
		"physicalRequiredCoverageByXIndex", "physicalRequiredPostPartIds",
		"physicalRequiredPurlinPartIds", "physicalRequiredGableBearerId"]
	var rows: Array = []
	var all_reject := target != null
	if target != null:
		for key: String in keys:
			var clone = Part.new(target.snapshot())
			clone.physical_intent = "structural_mass"
			clone.recipe[key] = "occupied" if key == "physicalRequiredGableBearerId" else ({"occupied": true} if key in ["physicalRequiredCoverageByZIndex", "physicalRequiredCoverageByXIndex"] else ["occupied"])
			var frozen := var_to_bytes(clone.snapshot())
			var rejected := not Recipe._target_valid(clone)
			all_reject = all_reject and rejected and frozen == var_to_bytes(clone.snapshot())
			rows.append({"key": key, "rejected": rejected})
		var assembly = Part.new(target.snapshot())
		assembly.physical_intent = "structural_mass"
		assembly.recipe["physicalAssemblyRole"] = "occupied_role"
		var frozen_assembly := var_to_bytes(assembly.snapshot())
		var assembly_rejected := not Recipe._target_valid(assembly)
		all_reject = all_reject and assembly_rejected and frozen_assembly == var_to_bytes(assembly.snapshot())
		rows.append({"key": "physicalAssemblyRole", "rejected": assembly_rejected})
	evidence["existingObligationRows"] = rows
	checks["every_existing_load_obligation_rejects_atomically"] = all_reject and rows.size() == keys.size() + 1

func _exact_changes(before: Dictionary, after: Dictionary, changes: Array, junction_seats: Array) -> bool:
	if before.parts.size() != after.parts.size(): return false
	var changed: Dictionary = {}
	for row: Dictionary in changes: changed[row.partId] = row.recipe
	var junction_ids: Array = junction_seats.map(func(part): return part.id)
	var after_by_id: Dictionary = {}
	for record: Dictionary in after.parts:
		if after_by_id.has(record.id): return false
		after_by_id[record.id] = record
	for record: Dictionary in before.parts:
		var expected: Dictionary = record.duplicate(true)
		if changed.has(record.id): expected.recipe = changed[record.id].duplicate(true)
		if junction_ids.has(record.id): expected.recipe["physicalPartyWallBearingModes"] = ["terminal_joint", "embedded_panel"]
		if not after_by_id.has(record.id) or var_to_bytes(after_by_id[record.id]) != var_to_bytes(expected): return false
	return true

func _archive_schema(raw: Dictionary) -> bool:
	return raw.get("afterSnapshot") is Dictionary and raw.afterSnapshot.get("parts") is Array and raw.afterSnapshot.get("rooms") is Array and raw.afterSnapshot.get("recipe") is Dictionary and raw.get("furnitureSnapshot") is Dictionary and raw.furnitureSnapshot.get("parts") is Array and raw.get("protectedReservations") is Array and (not raw.has("candidateHistory") or raw.candidateHistory is Array)

func _archive_exact(raw: Dictionary, candidate: Dictionary) -> bool:
	if candidate.keys().size() != raw.keys().size() + (0 if raw.has("candidateHistory") else 1): return false
	for key: Variant in raw:
		if key in ["afterSnapshot", "candidateHistory"]: continue
		if not candidate.has(key) or var_to_bytes(candidate[key]) != var_to_bytes(raw[key]): return false
	var history: Array = candidate.candidateHistory
	var old: Array = raw.get("candidateHistory", [])
	return history.size() == old.size() + 1 and var_to_bytes(history.slice(0, history.size() - 1)) == var_to_bytes(old)

func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > MAX_BYTES: return {"ready": false}
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var value = bytes_to_var(bytes)
	return {"ready": value is Dictionary and var_to_bytes(value) == bytes, "value": value}

func _fresh(path: String, extension := "") -> bool:
	return path.is_absolute_path() and not path.is_empty() and not FileAccess.file_exists(path) and (extension.is_empty() or path.get_extension() == extension)

func _write(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_buffer(bytes)
	var ok := file.get_error() == OK
	file.close()
	return ok and FileAccess.get_sha256(path).length() == 64

func _json(value: Variant) -> Variant:
	if value is Vector3: return {"x": value.x, "y": value.y, "z": value.z}
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var out := {}
		for key in value: out[String(key)] = _json(value[key])
		return out
	if value is Array:
		var out := []
		for item in value: out.append(_json(item))
		return out
	return value

func _finish(path: String, passed: bool, detail: Dictionary) -> void:
	_write(path, JSON.stringify(_json({"passed": passed, "checks": checks, "detail": detail}), "\t").to_utf8_buffer())
	quit(1)
