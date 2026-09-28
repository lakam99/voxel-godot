extends SceneTree

## SHA-bound current accumulated candidate; source-only position experiment.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Mount = preload("res://scripts/buildings/DoorHoodBracketMountRecipe.gd")
const MAX_BYTES := 32 * 1024 * 1024
var checks: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var report_path := OS.get_environment("VOXEL_DOOR_BRACKET_CURRENT_REPORT").simplify_path()
	var output_path := OS.get_environment("VOXEL_DOOR_BRACKET_CURRENT_OUTPUT").simplify_path()
	var input_path := OS.get_environment("VOXEL_DOOR_BRACKET_CURRENT_INPUT").simplify_path()
	var input_sha := OS.get_environment("VOXEL_DOOR_BRACKET_CURRENT_SHA").to_lower()
	var expected_before_text := OS.get_environment("VOXEL_DOOR_BRACKET_EXPECTED_BEFORE")
	var expected_selected_text := OS.get_environment("VOXEL_DOOR_BRACKET_EXPECTED_SELECTED")
	var expected_before := 46 if expected_before_text.is_empty() else int(expected_before_text)
	var expected_selected := 16 if expected_selected_text.is_empty() else int(expected_selected_text)
	if not _fresh(report_path, "json") or not _fresh(output_path) or not input_path.is_absolute_path() or input_sha.length() != 64 or input_sha.hex_decode().size() != 32 or FileAccess.get_sha256(input_path) != input_sha:
		quit(2); return
	if expected_before < 1 or expected_before > 10000 or expected_selected < 1 or expected_selected > 64: quit(2); return
	var read := _read(input_path)
	if not read.ready: quit(2); return
	var raw: Dictionary = read.value
	if not raw.get("afterSnapshot") is Dictionary or not raw.get("furnitureSnapshot") is Dictionary or not raw.furnitureSnapshot.get("parts") is Array or raw.furnitureSnapshot.parts.size() != 152 or not raw.get("protectedReservations") is Array:
		quit(2); return
	var frozen := var_to_bytes(raw)
	var b = Copy.copy_blueprint(raw.afterSnapshot)
	var before_b = Copy.copy_blueprint(raw.afterSnapshot)
	Copy.clear_caches(before_b)
	var before_grid := Copy.validation_grid_work(before_b)
	if not before_grid.ready: quit(2); return
	var before: Dictionary = before_b.validate_physical_integrity()
	var before_ids: Array = Copy.failed_ids(before)
	checks["current_candidate_has_expected_failures"] = before_ids.size() == expected_before
	var selected: Array = before_ids.filter(func(id):
		var part = b.find_part(id)
		return part != null and part.kind == "beam" and part.semantic == "citadel_urban_door_joinery" and String(id).contains("_door_bracket_") and not part.collision_enabled)
	selected.sort()
	checks["exact_expected_failed_brackets_selected"] = selected.size() == expected_selected
	var membership := Copy.street_house_memberships(b)
	checks["producer_membership_ready"] = membership.ready
	var owner_by_member: Dictionary = {}
	if membership.ready:
		for house: Dictionary in membership.houses:
			for id: String in house.memberIds: owner_by_member[id] = house
	checks["every_selected_has_one_producer"] = selected.all(func(id): return owner_by_member.has(id))
	var rows: Array = []
	var accepted: Array = []
	var rejected: Array = []
	for id: String in selected:
		var house: Dictionary = owner_by_member.get(id, {})
		var target = b.find_part(id)
		var door = b.find_part(house.get("doorId", ""))
		var hood = b.find_part(house.get("prefix", "") + "_door_hood")
		var panels: Array = house.get("facadeIds", []).map(func(panel_id): return b.find_part(panel_id))
		var step_before := var_to_bytes(b.snapshot())
		var plan: Dictionary = Mount.prepare(b, target, door, hood, panels)
		var repeat: Dictionary = Mount.prepare(b, target, door, hood, panels)
		var row := {"id": id, "ready": plan.get("ready", false), "reason": plan.get("reason", ""), "plan": plan,
			"deterministic": var_to_bytes(plan) == var_to_bytes(repeat), "planImmutable": step_before == var_to_bytes(b.snapshot())}
		var pier_rooted: bool = plan.get("ready", false) and before_b.has_rooted_support_chain(before_b.find_part(plan.get("pierId", "")), {})
		row["selectedPierRooted"] = pier_rooted
		if plan.get("ready", false) and pier_rooted:
			var original: Dictionary = target.snapshot()
			target.position = plan.part.position
			row["positionOnly"] = _position_only(original, target.snapshot())
			row["exactPierContact"] = plan.get("exactPierContact") == true
			row["exactHoodContact"] = plan.get("exactHoodContact") == true
			accepted.append(row)
		else:
			if plan.get("ready", false):
				row.ready = false
				row.reason = "selected_pier_not_rooted"
			rejected.append(row)
		rows.append(row)
	checks["all_plans_deterministic_immutable"] = rows.all(func(row): return row.deterministic and row.planImmutable)
	checks["accepted_position_only_exact_contacts"] = not accepted.is_empty() and accepted.all(func(row): return row.positionOnly and row.exactPierContact and row.exactHoodContact)
	checks["explicit_partition"] = accepted.size() + rejected.size() == selected.size()
	var candidate_snapshot: Dictionary = b.snapshot()
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
	checks["whole_gate_lower_no_added"] = after_ids.size() < before_ids.size() and added_ids.is_empty() and added_violations.is_empty()
	checks["accepted_each_passes_once"] = accepted.all(func(row):
		var matches: Array = after.checks.filter(func(check): return check.partId == row.id)
		return matches.size() == 1 and matches[0].passed)
	checks["bound_input_immutable"] = frozen == var_to_bytes(raw) and FileAccess.get_sha256(input_path) == input_sha
	var ready: bool = not checks.is_empty() and checks.values().all(func(value): return value == true)
	var output_sha := ""
	if ready:
		var candidate: Dictionary = raw.duplicate(true)
		candidate.afterSnapshot = candidate_snapshot
		var history: Array = candidate.get("candidateHistory", []).duplicate(true)
		history.append({"kind": "door_bracket_current_candidate", "inputSha256": input_sha, "selectedIds": selected,
			"acceptedIds": accepted.map(func(row): return row.id), "rejected": rejected.map(func(row): return {"id": row.id, "reason": row.reason}),
			"beforeFailureCount": before_ids.size(), "afterFailureCount": after_ids.size(), "scope": "Source-only bracket position recipe."})
		candidate["candidateHistory"] = history
		checks["archive_contents_exact"] = var_to_bytes(candidate.furnitureSnapshot) == var_to_bytes(raw.furnitureSnapshot) and var_to_bytes(candidate.protectedReservations) == var_to_bytes(raw.protectedReservations) and _archive_exact(raw, candidate)
		ready = checks.values().all(func(value): return value == true)
		if ready and _write(output_path, var_to_bytes(candidate)): output_sha = FileAccess.get_sha256(output_path)
		else: ready = false
	var report := {"passed": ready, "checks": checks, "inputSha256": input_sha, "outputSha256": output_sha,
		"beforeFailureCount": before_ids.size(), "afterFailureCount": after_ids.size(), "selectedIds": selected,
		"accepted": accepted, "rejected": rejected, "addedFailureIds": added_ids, "addedViolations": added_violations,
		"limitations": "Source-only noncolliding presentation joinery. No furniture, doorway-sweep, published-contact, appearance, live gameplay, NPC/navigation or engineering acceptance."}
	var report_ok := _write(report_path, JSON.stringify(_json(report), "\t").to_utf8_buffer())
	quit(0 if ready and report_ok else (1 if report_ok else 2))

func _position_only(before: Dictionary, after: Dictionary) -> bool:
	var expected := before.duplicate(true); expected.position = after.position
	return before.position != after.position and var_to_bytes(expected) == var_to_bytes(after)

func _exact_changes(before: Dictionary, after: Dictionary, accepted: Array) -> bool:
	if before.parts.size() != after.parts.size(): return false
	var accepted_ids: Array = accepted.map(func(row): return row.id)
	for index in range(before.parts.size()):
		var expected: Dictionary = before.parts[index].duplicate(true)
		if accepted_ids.has(expected.id):
			var row: Dictionary = accepted.filter(func(value): return value.id == expected.id)[0]
			expected.position = row.plan.part.position
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
	if value is Vector2: return [value.x, value.y]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
