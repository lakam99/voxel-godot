extends SceneTree

## SHA-bound source-only rigid household-sign candidate.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Recipe = preload("res://scripts/buildings/HouseholdSignMountRecipe.gd")
const DoorGeometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_BYTES := 32 * 1024 * 1024
var checks: Dictionary = {}
var control_evidence: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var report_path := OS.get_environment("VOXEL_SIGN_CURRENT_REPORT").simplify_path()
	var output_path := OS.get_environment("VOXEL_SIGN_CURRENT_OUTPUT").simplify_path()
	var input_path := OS.get_environment("VOXEL_SIGN_CURRENT_INPUT").simplify_path()
	var input_sha := OS.get_environment("VOXEL_SIGN_CURRENT_SHA").to_lower()
	var expected_before := int(OS.get_environment("VOXEL_SIGN_EXPECTED_BEFORE"))
	var expected_selected := int(OS.get_environment("VOXEL_SIGN_EXPECTED_SELECTED"))
	if not _fresh(report_path, "json") or not _fresh(output_path) or not input_path.is_absolute_path() or input_sha.length() != 64 or input_sha.hex_decode().size() != 32 or FileAccess.get_sha256(input_path) != input_sha or expected_before < 1 or expected_selected < 1 or expected_selected > 32:
		quit(2); return
	var read := _read(input_path)
	if not read.ready: quit(2); return
	var raw: Dictionary = read.value
	if not raw.get("afterSnapshot") is Dictionary or not raw.get("furnitureSnapshot") is Dictionary or not raw.furnitureSnapshot.get("parts") is Array or raw.furnitureSnapshot.parts.size() != 152 or not raw.get("protectedReservations") is Array:
		quit(2); return
	var frozen := var_to_bytes(raw)
	var b = Copy.copy_blueprint(raw.afterSnapshot)
	var baseline = Copy.copy_blueprint(raw.afterSnapshot)
	Copy.clear_caches(baseline)
	var baseline_grid := Copy.validation_grid_work(baseline)
	if not baseline_grid.ready: quit(2); return
	var before: Dictionary = baseline.validate_physical_integrity()
	var before_ids: Array = Copy.failed_ids(before)
	checks["expected_before_failure_count"] = before_ids.size() == expected_before
	var membership := Copy.street_house_memberships(b)
	checks["producer_membership_ready"] = membership.ready
	var owner_by_member: Dictionary = {}
	if membership.ready:
		for house: Dictionary in membership.houses:
			for id: String in house.memberIds: owner_by_member[id] = house
	var selected: Array = before_ids.filter(func(id):
		var part = b.find_part(id)
		return part != null and part.kind == "beam" and part.semantic == "citadel_household_sign" and String(id).ends_with("_sign_arm") and not part.collision_enabled)
	selected.sort()
	checks["exact_expected_failed_sign_arms_selected"] = selected.size() == expected_selected
	checks["every_selected_has_exact_producer"] = selected.all(func(id): return owner_by_member.has(id))
	var protected := _protected(raw, b, membership.get("houses", []))
	if not protected.ready: quit(2); return
	checks["all_furniture_reservations_and_door_sweeps_bound"] = protected.furnitureCount == 152 and protected.reservationCount == raw.protectedReservations.size() and protected.doorCount == membership.get("houses", []).size()
	_focused_controls()
	var staged = Copy.copy_blueprint(raw.afterSnapshot)
	var staged_grid := Copy.validation_grid_work(staged)
	if not staged_grid.ready: quit(2); return
	var proof = Copy.copy_blueprint(raw.afterSnapshot)
	Copy.clear_caches(proof)
	var proof_grid := Copy.validation_grid_work(proof)
	if not proof_grid.ready: quit(2); return
	proof.validate_physical_integrity()
	var rows: Array = []
	var accepted: Array = []
	var rejected: Array = []
	for id: String in selected:
		var house: Dictionary = owner_by_member[id]
		var raw_arm = staged.find_part(id)
		var raw_board = staged.find_part(house.prefix + "_hanging_sign")
		var arm = proof.find_part(id)
		var board = proof.find_part(house.prefix + "_hanging_sign")
		var door = proof.find_part(house.doorId)
		var facades: Array = house.memberIds.map(func(member_id): return proof.find_part(member_id)).filter(func(part):
			return part != null and part.collision_enabled and part.rotation == Vector3.ZERO and part.physical_intent in ["structural_mass", "structural_root"] and proof.has_rooted_support_chain(part, {}))
		var before_step := var_to_bytes(proof.snapshot())
		var raw_before_step := var_to_bytes(staged.snapshot())
		var relative_before: Vector3 = raw_board.position - raw_arm.position if raw_board != null else Vector3.INF
		var plan: Dictionary = Recipe.plan(proof, arm, board, door, facades, protected.bounds)
		var repeat: Dictionary = Recipe.plan(proof, arm, board, door, facades, protected.bounds)
		var row := {"id": id, "ready": plan.get("ready", false), "reason": plan.get("reason", ""),
			"deterministic": var_to_bytes(plan) == var_to_bytes(repeat), "planImmutable": before_step == var_to_bytes(proof.snapshot()) and raw_before_step == var_to_bytes(staged.snapshot()), "plan": plan}
		if plan.get("ready", false):
			var applied: Dictionary = Recipe.apply(proof, id, board.id, door.id, facades.map(func(part): return part.id), protected.bounds)
			row["applyMatchesPlan"] = applied.get("ready", false) and var_to_bytes(applied) == var_to_bytes(plan)
			var clean_plan := _clean_plan(plan, raw_arm.snapshot(), raw_board.snapshot())
			row.plan = clean_plan
			raw_arm.position = clean_plan.armRecord.position
			raw_arm.recipe["physicalRequiredAnchorPartIds"] = clean_plan.armRecord.recipe.physicalRequiredAnchorPartIds.duplicate(true)
			raw_arm.recipe["physicalRequiredAnchorFacts"] = clean_plan.armRecord.recipe.physicalRequiredAnchorFacts.duplicate(true)
			raw_board.position = clean_plan.boardRecord.position
			var moved_arm = staged.find_part(id)
			var moved_board = staged.find_part(raw_board.id)
			row["rigidRelativePoseExact"] = moved_board.position - moved_arm.position == relative_before
			row["finiteRootedSocket"] = proof.has_rooted_attachment_socket(proof.find_part(id), plan.anchorFact)
			row["armAndBoardTranslateTogether"] = moved_board.position - moved_arm.position == relative_before
			accepted.append(row)
		else:
			rejected.append(row)
		rows.append(row)
	checks["plans_deterministic_and_immutable"] = rows.all(func(row): return row.deterministic and row.planImmutable)
	checks["all_selected_accept_with_rigid_finite_socket"] = accepted.size() == selected.size() and rejected.is_empty() and accepted.all(func(row): return row.applyMatchesPlan and row.rigidRelativePoseExact and row.finiteRootedSocket and row.armAndBoardTranslateTogether)
	var candidate_snapshot: Dictionary = staged.snapshot()
	checks["exact_candidate_changes"] = _exact_changes(raw.afterSnapshot, candidate_snapshot, accepted)
	checks["rooms_top_recipe_exact"] = var_to_bytes(candidate_snapshot.rooms) == var_to_bytes(raw.afterSnapshot.rooms) and var_to_bytes(candidate_snapshot.recipe) == var_to_bytes(raw.afterSnapshot.recipe)
	var after_b = Copy.copy_blueprint(candidate_snapshot)
	Copy.clear_caches(after_b)
	var after_grid := Copy.validation_grid_work(after_b)
	checks["whole_validation_bounded"] = after_grid.ready
	var after: Dictionary = after_b.validate_physical_integrity() if after_grid.ready else {"checks": [], "violations": []}
	var after_ids: Array = Copy.failed_ids(after)
	var added_ids: Array = after_ids.filter(func(id): return not before_ids.has(id))
	var added_violations: Array = after.violations.filter(func(value): return not before.violations.has(value))
	checks["whole_gate_exact_delta_no_added"] = after_ids.size() == before_ids.size() - selected.size() and added_ids.is_empty() and added_violations.is_empty()
	checks["every_sign_arm_passes_once"] = selected.all(func(id):
		var matches: Array = after.checks.filter(func(check): return check.partId == id)
		return matches.size() == 1 and matches[0].passed)
	checks["bound_input_immutable"] = frozen == var_to_bytes(raw) and FileAccess.get_sha256(input_path) == input_sha
	var ready: bool = checks.values().all(func(value): return value == true)
	var output_sha := ""
	if ready:
		var candidate: Dictionary = raw.duplicate(true)
		candidate.afterSnapshot = candidate_snapshot
		var history: Array = candidate.get("candidateHistory", []).duplicate(true)
		history.append({"kind": "household_sign_mount_candidate", "inputSha256": input_sha,
			"selectedIds": selected, "beforeFailureCount": before_ids.size(), "afterFailureCount": after_ids.size(),
			"scope": "Source-only rigid two-part sign assembly and finite same-house facade socket."})
		candidate["candidateHistory"] = history
		checks["archive_contents_exact"] = var_to_bytes(candidate.furnitureSnapshot) == var_to_bytes(raw.furnitureSnapshot) and var_to_bytes(candidate.protectedReservations) == var_to_bytes(raw.protectedReservations) and _archive_exact(raw, candidate)
		ready = checks.values().all(func(value): return value == true)
		if ready and _write(output_path, var_to_bytes(candidate)): output_sha = FileAccess.get_sha256(output_path)
		else: ready = false
	var report := {"passed": ready, "checks": checks, "inputSha256": input_sha, "outputSha256": output_sha,
		"beforeFailureCount": before_ids.size(), "afterFailureCount": after_ids.size(), "selectedIds": selected,
		"accepted": accepted, "rejected": rejected, "addedFailureIds": added_ids, "addedViolations": added_violations, "controlEvidence": control_evidence,
		"limitations": "Source-only sign assembly/socket contract. No published geometry, rendering, appearance, gameplay, NPC/navigation or engineering acceptance."}
	var report_ok := _write(report_path, JSON.stringify(_json(report), "\t").to_utf8_buffer())
	quit(0 if ready and report_ok else (1 if report_ok else 2))

func _clean_plan(plan: Dictionary, arm_record: Dictionary, board_record: Dictionary) -> Dictionary:
	var clean: Dictionary = plan.duplicate(true)
	arm_record.position = plan.armRecord.position
	arm_record.recipe["physicalRequiredAnchorPartIds"] = plan.armRecord.recipe.physicalRequiredAnchorPartIds.duplicate(true)
	arm_record.recipe["physicalRequiredAnchorFacts"] = plan.armRecord.recipe.physicalRequiredAnchorFacts.duplicate(true)
	board_record.position = plan.boardRecord.position
	clean.armRecord = arm_record
	clean.boardRecord = board_record
	return clean

func _focused_controls() -> void:
	var b := Blueprint.new("household_sign_mount_controls", 77, "masonry")
	var prefix := "control_house"
	var anchor_ids := [prefix + "_anchor_a", prefix + "_anchor_b"]
	var anchors: Array = []
	for index in range(2):
		var anchor = b.add_part({"id": anchor_ids[index], "kind": "wall", "material": "stone_foundation",
			"position": Vector3(0, 1.6, -0.72 + float(index) * 1.44), "size": Vector3(0.30, 3.2, 0.62),
			"collision": true, "physicalIntent": "structural_root", "semantic": "control_anchor",
			"recipe": {"physicalIntent": "structural_root", "physicalRoot": true}})
		anchor.physical_intent = "structural_root"
		anchors.append(anchor)
	var door = b.add_part({"id": prefix + "_door", "kind": "door", "material": "painted_door",
		"position": Vector3(0.4, 1.2, 5.0), "size": Vector3(0.14, 2.4, 1.2), "collision": true,
		"semantic": "citadel_urban_door"})
	var arm = b.add_part({"id": prefix + "_sign_arm", "kind": "beam", "material": "timber_beam",
		"position": Vector3(0.62, 2.72, -0.10), "size": Vector3(0.12, 0.12, 1.05),
		"collision": false, "semantic": "citadel_household_sign", "physicalIntent": "facade_attachment"})
	var board = b.add_part({"id": prefix + "_hanging_sign", "kind": "sign", "material": "painted_decor",
		"position": arm.position + Vector3(0.02, -0.42, 0.42), "size": Vector3(0.12, 0.72, 0.62),
		"collision": false, "semantic": "citadel_household_sign", "physicalIntent": "visual_detail"})
	b.resolve_physical_contracts()
	var a = anchors[0]
	var c = anchors[1]
	control_evidence["anchors"] = [a.snapshot(), c.snapshot()]
	control_evidence["anchorValidity"] = [a is Part, b.has_finite_positive_bounds(a), a.id.begins_with(prefix + "_"), a.collision_enabled, a.rotation == Vector3.ZERO, a.physical_intent, b.has_rooted_support_chain(a, {})]
	var only_a: Dictionary = Recipe.plan(b, arm, board, door, [a], [])
	var only_c: Dictionary = Recipe.plan(b, arm, board, door, [c], [])
	var both: Dictionary = Recipe.plan(b, arm, board, door, [c, a], [])
	control_evidence["onlyA"] = only_a
	control_evidence["onlyB"] = only_c
	control_evidence["both"] = both
	var winner := ""
	if only_a.get("ready", false) and only_c.get("ready", false):
		var a_length: float = (only_a.delta as Vector3).length()
		var c_length: float = (only_c.delta as Vector3).length()
		winner = a.id if a_length < c_length or a_length == c_length and a.id < c.id else c.id
	checks["control_full_translation_winner_and_order_independent"] = not winner.is_empty() and both.get("ready", false) and both.anchorId == winner and var_to_bytes(both) == var_to_bytes(Recipe.plan(b, arm, board, door, [a, c], []))
	if winner.is_empty():
		checks["control_unselected_collision_backed_member_blocks"] = false
		return
	var blocked = Copy.copy_blueprint(b.snapshot())
	var winning_plan: Dictionary = only_a if winner == a.id else only_c
	var target_position: Vector3 = winning_plan.armRecord.position
	var blocker = blocked.add_part({"id": prefix + "_unselected_structural_blocker", "kind": "beam", "material": "stone_foundation",
		"position": Vector3(target_position.x, target_position.y * 0.5, target_position.z),
		"size": Vector3(0.20, target_position.y + 0.20, 0.20), "collision": true,
		"physicalIntent": "structural_root", "semantic": "control_blocker",
		"recipe": {"physicalIntent": "structural_root", "physicalRoot": true}})
	blocker.physical_intent = "structural_root"
	blocked.resolve_physical_contracts()
	var blocked_result: Dictionary = Recipe.plan(blocked, _part(blocked, arm.id), _part(blocked, board.id), _part(blocked, door.id), [_part(blocked, winner)], [])
	control_evidence["blocked"] = blocked_result
	checks["control_unselected_collision_backed_member_blocks"] = not blocked_result.get("ready", false) and blocked_result.get("reason") == "no_clear_rooted_structural_socket"

func _part(b, id: String):
	for part in b.parts:
		if part.id == id: return part
	return null

func _protected(raw: Dictionary, b, houses: Array) -> Dictionary:
	var bounds: Array = []
	for record: Dictionary in raw.furnitureSnapshot.parts:
		if not record.get("position") is Vector3 or not record.get("rotation") is Vector3 or not record.get("occupiedSize") is Vector3: return {"ready": false}
		bounds.append(Transform3D(Basis.from_euler(record.rotation), record.position) * AABB(Vector3(-record.occupiedSize.x * 0.5, 0, -record.occupiedSize.z * 0.5), record.occupiedSize))
	for value in raw.protectedReservations:
		if not value is AABB: return {"ready": false}
		bounds.append(value)
	for house: Dictionary in houses:
		var door = b.find_part(house.doorId)
		if door == null: return {"ready": false}
		var sweep: Array = DoorGeometry.ordinary_sweep_bounds(door.size, Transform3D(Basis.from_euler(door.rotation), door.position), float(door.recipe.get("openSwing", DoorGeometry.DEFAULT_OPEN_SWING)))
		if sweep.is_empty(): return {"ready": false}
		bounds.append_array(sweep)
	return {"ready": true, "bounds": bounds, "furnitureCount": raw.furnitureSnapshot.parts.size(), "reservationCount": raw.protectedReservations.size(), "doorCount": houses.size()}

func _exact_changes(before: Dictionary, after: Dictionary, accepted: Array) -> bool:
	if before.parts.size() != after.parts.size(): return false
	var by_id: Dictionary = {}
	for row: Dictionary in accepted: by_id[row.id] = row.plan
	for index in range(before.parts.size()):
		var expected: Dictionary = before.parts[index].duplicate(true)
		var id: String = expected.id
		if by_id.has(id):
			expected = by_id[id].armRecord.duplicate(true)
		elif id.ends_with("_hanging_sign") and by_id.has(id.trim_suffix("_hanging_sign") + "_sign_arm"):
			expected = by_id[id.trim_suffix("_hanging_sign") + "_sign_arm"].boardRecord.duplicate(true)
		if var_to_bytes(expected) != var_to_bytes(after.parts[index]): return false
	return true

func _archive_exact(raw: Dictionary, candidate: Dictionary) -> bool:
	for key: Variant in raw:
		if key in ["afterSnapshot", "candidateHistory"]: continue
		if not candidate.has(key) or var_to_bytes(candidate[key]) != var_to_bytes(raw[key]): return false
	return true

func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ready": false}
	var length := file.get_length()
	if length <= 0 or length > MAX_BYTES: file.close(); return {"ready": false}
	var bytes := file.get_buffer(length); var ok := bytes.size() == length and file.get_error() == OK
	file.close(); var value: Variant = bytes_to_var(bytes)
	return {"ready": ok and value is Dictionary and var_to_bytes(value) == bytes, "value": value}

func _fresh(path: String, extension := "") -> bool:
	return path.is_absolute_path() and (extension.is_empty() or path.get_extension().to_lower() == extension) and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path) and DirAccess.dir_exists_absolute(path.get_base_dir())

func _write(path: String, bytes: PackedByteArray) -> bool:
	if not _fresh(path): return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_buffer(bytes); file.flush(); var ok := file.get_error() == OK and file.get_position() == bytes.size(); file.close()
	return ok

func _json(value: Variant) -> Variant:
	if value is Vector3: return [value.x, value.y, value.z]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
