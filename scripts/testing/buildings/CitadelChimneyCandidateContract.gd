extends SceneTree

## SHA-bound binary current-candidate measurement. Applies the existing chimney
## recipe sequentially to failed actual chimney records on a private copy.
## No scene, publisher, physics, rendering, NPC, navigation or gameplay claim.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Recipe = preload("res://scripts/buildings/ChimneyBearingRecipe.gd")
const MAX_INPUT_BYTES := 128 * 1024 * 1024
const MAX_SELECTED := 16
const MAX_WHOLE_CELLS := 1000000.0

var _checks: Dictionary = {}
var _rows: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var report_path: String = OS.get_environment("VOXEL_CHIMNEY_CANDIDATE_REPORT").strip_edges().simplify_path()
	var output_path: String = OS.get_environment("VOXEL_CHIMNEY_CANDIDATE_OUTPUT").strip_edges().simplify_path()
	var input_path: String = OS.get_environment("VOXEL_CHIMNEY_CANDIDATE_INPUT").strip_edges().simplify_path()
	var input_sha: String = OS.get_environment("VOXEL_CHIMNEY_CANDIDATE_SHA").strip_edges().to_lower()
	var expected_before_text := OS.get_environment("VOXEL_CHIMNEY_EXPECTED_BEFORE")
	var expected_selected_text := OS.get_environment("VOXEL_CHIMNEY_EXPECTED_SELECTED")
	var expected_before := 57 if expected_before_text.is_empty() else int(expected_before_text)
	var expected_selected := 14 if expected_selected_text.is_empty() else int(expected_selected_text)
	if not _fresh_file(report_path, "json") or not _fresh_file(output_path) or input_path == report_path or input_path == output_path or report_path == output_path or not input_path.is_absolute_path() or not FileAccess.file_exists(input_path) or input_sha.length() != 64 or input_sha.hex_decode().size() != 32 or FileAccess.get_sha256(input_path) != input_sha or expected_before < 1 or expected_before > 10000 or expected_selected < 1 or expected_selected > MAX_SELECTED:
		quit(2)
		return
	var raw_read: Dictionary = _read_binary(input_path)
	if not raw_read.get("ready", false):
		quit(2)
		return
	var raw: Dictionary = raw_read.value
	if not _archive_schema(raw):
		quit(2)
		return
	var frozen_raw: PackedByteArray = var_to_bytes(raw)
	var frozen_furniture: PackedByteArray = var_to_bytes(raw.furnitureSnapshot)
	var frozen_reservations: PackedByteArray = var_to_bytes(raw.protectedReservations)
	var policy_read: Dictionary = _policy(raw)
	if not policy_read.get("ready", false):
		quit(2)
		return
	var obstacles: Array = policy_read.obstacles
	_checks["all_152_furnishings_plus_reservations_bound"] = raw.furnitureSnapshot.parts.size() == 152 and obstacles.size() == 152 + raw.protectedReservations.size()
	var source = _copy_source(raw.afterSnapshot)
	if source == null:
		quit(2)
		return
	var baseline = _validation_copy(raw.afterSnapshot)
	if baseline == null or not _whole_validation_bounded(baseline):
		quit(2)
		return
	var before_physical: Dictionary = baseline.validate_physical_integrity()
	var before_failed: Array = _failed_ids(before_physical)
	_checks["current_candidate_has_expected_physical_failures"] = before_failed.size() == expected_before
	var actual_failed: Array = []
	for part in source.parts:
		if before_failed.has(part.id) and part.kind == "wall" and part.semantic == "citadel_urban_chimney": actual_failed.append(part.id)
	actual_failed.sort()
	var omitted: Array = actual_failed.slice(MAX_SELECTED) if actual_failed.size() > MAX_SELECTED else []
	var selected: Array = actual_failed.slice(0, mini(MAX_SELECTED, actual_failed.size()))
	_checks["selected_only_failed_actual_chimneys"] = selected.size() <= MAX_SELECTED and selected.all(func(id):
		var part = _find(source, id)
		return before_failed.has(id) and part != null and part.kind == "wall" and part.semantic == "citadel_urban_chimney")
	_checks["exact_expected_failed_actual_chimneys_selected"] = actual_failed.size() == expected_selected and selected.size() == expected_selected and omitted.is_empty()
	_checks["selected_sorted_unique"] = selected == _sorted_unique(selected)
	_checks["source_has_selected_failed_chimneys"] = not selected.is_empty()
	_malformed_controls(raw.afterSnapshot, selected, obstacles)
	var staged = source
	var accepted: Array = []
	var rejected: Array = []
	var expected_part_count: int = staged.parts.size()
	for chimney_id: String in selected:
		var ids: Dictionary = _producer_ids(chimney_id)
		var before_step: PackedByteArray = var_to_bytes(staged.snapshot())
		var inputs_before: PackedByteArray = var_to_bytes([ids, obstacles])
		var proposal: Dictionary = Recipe.plan(staged, chimney_id, ids.gables, ids.upstream, obstacles)
		var repeat: Dictionary = Recipe.plan(staged, chimney_id, ids.gables, ids.upstream, obstacles)
		var row: Dictionary = {"chimneyId": chimney_id, "ready": proposal.get("ready", false),
			"reason": proposal.get("reason", ""), "stagedPartCountBefore": staged.parts.size(),
			"repeatExact": var_to_bytes(proposal) == var_to_bytes(repeat),
			"planImmutable": before_step == var_to_bytes(staged.snapshot()) and inputs_before == var_to_bytes([ids, obstacles])}
		if not proposal.get("ready", false):
			row["evidence"] = _brief(proposal)
			rejected.append(row.duplicate(true))
			_rows.append(row)
			continue
		var applied: Dictionary = Recipe.apply(staged, chimney_id, ids.gables, ids.upstream, obstacles)
		expected_part_count += 1
		row["applyMatchesPlan"] = applied.get("ready", false) and var_to_bytes(applied) == var_to_bytes(proposal)
		row["stagedPartCountAfter"] = staged.parts.size()
		row["exactOnePartAdded"] = staged.parts.size() == expected_part_count
		var before_repeat: PackedByteArray = var_to_bytes(staged.snapshot())
		var second: Dictionary = Recipe.plan(staged, chimney_id, ids.gables, ids.upstream, obstacles)
		row["appliedStateRejectsRepeatAtomically"] = not second.get("ready", false) and second.get("reason") in ["incompatible_chimney", "chimney_bearing_already_present"] and before_repeat == var_to_bytes(staged.snapshot())
		row["repeatAfterApplyReason"] = second.get("reason", "")
		row["proposal"] = proposal
		accepted.append(row.duplicate(true))
		_rows.append(row)
	_checks["every_plan_repeat_exact"] = _rows.size() == selected.size() and _rows.all(func(row): return row.repeatExact)
	_checks["every_plan_input_immutable"] = _rows.all(func(row): return row.planImmutable)
	_checks["accepted_applied_sequentially"] = accepted.all(func(row): return row.applyMatchesPlan and row.exactOnePartAdded and row.appliedStateRejectsRepeatAtomically)
	var partition_ids: Array = accepted.map(func(row): return row.chimneyId) + rejected.map(func(row): return row.chimneyId)
	_checks["explicit_accepted_rejected_partition"] = partition_ids.size() == selected.size() and _sorted_unique(partition_ids) == selected
	_checks["rejections_keep_exact_reason_and_source"] = rejected.all(func(row): return row.reason is String and not row.reason.is_empty() and row.evidence.get("reason") == row.reason and row.planImmutable)
	var candidate_snapshot: Dictionary = staged.snapshot()
	_checks["snapshot_rooms_preserved"] = var_to_bytes(candidate_snapshot.rooms) == var_to_bytes(raw.afterSnapshot.rooms)
	_checks["snapshot_top_recipe_preserved"] = var_to_bytes(candidate_snapshot.recipe) == var_to_bytes(raw.afterSnapshot.recipe)
	_checks["original_parts_changed_only_by_recipe_apply"] = _exact_recipe_changes(raw.afterSnapshot, candidate_snapshot, accepted)
	var candidate_validation = _validation_copy(candidate_snapshot)
	if candidate_validation == null or not _whole_validation_bounded(candidate_validation):
		_checks["whole_candidate_validation_bounded"] = false
	else:
		_checks["whole_candidate_validation_bounded"] = true
	var after_physical: Dictionary = candidate_validation.validate_physical_integrity() if _checks["whole_candidate_validation_bounded"] else {"checks": [], "violations": []}
	var after_failed: Array = _failed_ids(after_physical)
	var added_failed: Array = after_failed.filter(func(id): return not before_failed.has(id))
	var removed_failed: Array = before_failed.filter(func(id): return not after_failed.has(id))
	var added_violations: Array = after_physical.violations.filter(func(value): return not before_physical.violations.has(value))
	var accepted_part_ids: Array = []
	for row: Dictionary in accepted:
		accepted_part_ids.append(row.chimneyId)
		accepted_part_ids.append_array(row.proposal.partIds)
	_checks["every_accepted_chimney_and_bearer_passes_once"] = accepted_part_ids.size() == accepted.size() * 2 and accepted_part_ids.all(func(id):
		var matches: Array = after_physical.get("checks", []).filter(func(check): return check.get("partId") == id)
		return matches.size() == 1 and matches[0].get("passed") == true)
	_checks["whole_candidate_no_added_failure_ids"] = added_failed.is_empty()
	_checks["whole_candidate_no_added_violations"] = added_violations.is_empty()
	_checks["whole_candidate_lower_failure_count"] = after_failed.size() < before_failed.size()
	_checks["at_least_one_recipe_acceptance"] = not accepted.is_empty()
	_checks["raw_and_bound_input_immutable"] = var_to_bytes(raw) == frozen_raw and FileAccess.get_sha256(input_path) == input_sha
	_checks["furniture_and_reservations_immutable"] = var_to_bytes(raw.furnitureSnapshot) == frozen_furniture and var_to_bytes(raw.protectedReservations) == frozen_reservations
	var candidate_ready: bool = not _checks.is_empty() and _checks.values().all(func(value): return value == true)
	var output_written := false
	var output_sha := ""
	if candidate_ready:
		var candidate: Dictionary = raw.duplicate(true)
		candidate.afterSnapshot = candidate_snapshot
		var history: Array = candidate.get("candidateHistory", []).duplicate(true)
		history.append({"kind": "chimney_bearing_candidate", "inputSha256": input_sha,
			"selectedChimneyIds": selected.duplicate(), "accepted": accepted.duplicate(true), "rejected": rejected.duplicate(true),
			"beforeFailureCount": before_failed.size(), "afterFailureCount": after_failed.size(),
			"removedFailureIds": removed_failed.duplicate(), "addedFailureIds": added_failed.duplicate(),
			"scope": "Sequential source-only chimney bearing candidate; not publication or visual/gameplay acceptance."})
		candidate["candidateHistory"] = history
		_checks["candidate_preserves_all_raw_fields"] = _archive_preserved(raw, candidate)
		_checks["candidate_furniture_reservations_exact"] = var_to_bytes(candidate.furnitureSnapshot) == var_to_bytes(raw.furnitureSnapshot) and var_to_bytes(candidate.protectedReservations) == var_to_bytes(raw.protectedReservations)
		_checks["candidate_history_appended_once"] = history.size() == raw.get("candidateHistory", []).size() + 1 and var_to_bytes(history.slice(0, history.size() - 1)) == var_to_bytes(raw.get("candidateHistory", []))
		candidate_ready = _checks.values().all(func(value): return value == true)
		if candidate_ready:
			var encoded: PackedByteArray = var_to_bytes(candidate)
			output_written = _write_bytes(output_path, encoded)
			if output_written: output_sha = FileAccess.get_sha256(output_path)
	var report: Dictionary = {"passed": candidate_ready and output_written, "candidateReady": candidate_ready,
		"checks": _checks, "input": input_path, "inputSha256": input_sha, "output": output_path if output_written else "",
		"outputSha256": output_sha, "selectedChimneyIds": selected, "omittedFailedChimneyIds": omitted,
		"accepted": accepted, "rejected": rejected, "beforeFailureCount": before_failed.size(),
		"afterFailureCount": after_failed.size(), "beforeFailedIds": before_failed, "afterFailedIds": after_failed,
		"removedFailureIds": removed_failed, "addedFailureIds": added_failed, "addedViolations": added_violations,
		"evidenceLevel": "sha_bound_binary_current_candidate_source_contract",
		"limitations": "Source records, recipe seats, protected furniture/access volumes and whole physical checks only. No published mesh/collision, rendering, engineering load capacity, live visuals, gameplay, NPC/navigation or performance acceptance. Rejected and omitted chimneys remain unresolved."}
	var report_written: bool = _write_bytes(report_path, JSON.stringify(_json(report), "\t").to_utf8_buffer())
	quit(0 if report.passed and report_written else (1 if report_written else 2))

func _producer_ids(chimney_id: String) -> Dictionary:
	var prefix: String = chimney_id.trim_suffix("_chimney")
	return {"gables": [prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"],
		"upstream": [prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"]}

func _policy(raw: Dictionary) -> Dictionary:
	var obstacles: Array = []
	var seen: Dictionary = {}
	for record: Variant in raw.furnitureSnapshot.parts:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or seen.has("furnishing:" + record.id) or not record.get("position") is Vector3 or not record.get("rotation") is Vector3 or not record.get("occupiedSize") is Vector3 or not record.position.is_finite() or not record.rotation.is_finite(): return {"ready": false, "reason": "invalid_furniture_record"}
		var bounds: AABB = Transform3D(Basis.from_euler(record.rotation), record.position) * AABB(Vector3(-record.occupiedSize.x * 0.5, 0, -record.occupiedSize.z * 0.5), record.occupiedSize)
		if not Recipe._bounds_valid(bounds): return {"ready": false, "reason": "invalid_furniture_bounds"}
		var id: String = "furnishing:" + record.id
		seen[id] = true
		obstacles.append({"id": id, "bounds": bounds})
	for index in range(raw.protectedReservations.size()):
		var bounds: Variant = raw.protectedReservations[index]
		var id: String = "furnishing_access:%d" % index
		if not bounds is AABB or not Recipe._bounds_valid(bounds) or seen.has(id): return {"ready": false, "reason": "invalid_protected_reservation"}
		seen[id] = true
		obstacles.append({"id": id, "bounds": bounds})
	return {"ready": true, "obstacles": obstacles}

func _malformed_controls(snapshot: Dictionary, selected: Array, obstacles: Array) -> void:
	var b = _copy_source(snapshot)
	var source_before: PackedByteArray = var_to_bytes(b.snapshot())
	var inputs_before: PackedByteArray = var_to_bytes([selected, obstacles])
	var results: Array = [Recipe.plan(b, "", [], [], obstacles)]
	if not selected.is_empty():
		var ids: Dictionary = _producer_ids(selected[0])
		results.append(Recipe.plan(b, selected[0], [ids.gables[0], ids.gables[0]], ids.upstream, obstacles))
		var invalid_obstacles: Array = obstacles.duplicate(true)
		invalid_obstacles.append({"id": "malformed", "bounds": AABB(Vector3(NAN, 0, 0), Vector3.ONE)})
		results.append(Recipe.plan(b, selected[0], ids.gables, ids.upstream, invalid_obstacles))
	_checks["malformed_controls_reject_atomically"] = results.size() >= 1 and results.all(func(result): return not result.get("ready", false) and result.get("reason") is String and not result.reason.is_empty()) and source_before == var_to_bytes(b.snapshot()) and inputs_before == var_to_bytes([selected, obstacles])

func _exact_recipe_changes(before: Dictionary, after: Dictionary, accepted: Array) -> bool:
	if after.parts.size() != before.parts.size() + accepted.size(): return false
	var before_by_id: Dictionary = {}
	var after_by_id: Dictionary = {}
	for record: Dictionary in before.parts: before_by_id[record.id] = record
	for record: Dictionary in after.parts:
		if after_by_id.has(record.id): return false
		after_by_id[record.id] = record
	var accepted_by_id: Dictionary = {}
	for row: Dictionary in accepted: accepted_by_id[row.chimneyId] = row.proposal
	for id: String in before_by_id:
		var expected: Dictionary = before_by_id[id].duplicate(true)
		if accepted_by_id.has(id): expected.recipe = accepted_by_id[id].chimneyRecipe.duplicate(true)
		if var_to_bytes(after_by_id.get(id)) != var_to_bytes(expected): return false
	for row: Dictionary in accepted:
		if row.proposal.partIds.size() != 1 or var_to_bytes(after_by_id.get(row.proposal.partIds[0])) != var_to_bytes(row.proposal.bearerRecord): return false
	return true

func _archive_preserved(raw: Dictionary, candidate: Dictionary) -> bool:
	if candidate.keys().size() != raw.keys().size() + (0 if raw.has("candidateHistory") else 1): return false
	for key: Variant in raw:
		if key in ["afterSnapshot", "candidateHistory"]: continue
		if not candidate.has(key) or var_to_bytes(candidate[key]) != var_to_bytes(raw[key]): return false
	return true

func _read_binary(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ready": false, "reason": "input_open_failed"}
	var length: int = file.get_length()
	if length <= 0 or length > MAX_INPUT_BYTES:
		file.close()
		return {"ready": false, "reason": "input_size_limit"}
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	var value: Variant = bytes_to_var(bytes)
	if not complete or not value is Dictionary or var_to_bytes(value) != bytes: return {"ready": false, "reason": "noncanonical_binary_input"}
	return {"ready": true, "value": value}

func _archive_schema(raw: Dictionary) -> bool:
	if not raw.get("afterSnapshot") is Dictionary or not raw.get("furnitureSnapshot") is Dictionary or not raw.furnitureSnapshot.get("parts") is Array or not raw.get("protectedReservations") is Array: return false
	var snapshot: Dictionary = raw.afterSnapshot
	if not snapshot.get("id") is String or not snapshot.get("seed") is int or not snapshot.get("style") is String or not snapshot.get("parts") is Array or not snapshot.get("rooms") is Array or not snapshot.get("recipe") is Dictionary: return false
	if snapshot.parts.is_empty() or snapshot.parts.size() > Recipe.MAX_SOURCE or snapshot.rooms.size() > Recipe.MAX_OBSTACLES or raw.furnitureSnapshot.parts.size() + raw.protectedReservations.size() > Recipe.MAX_OBSTACLES: return false
	return not raw.has("candidateHistory") or raw.candidateHistory is Array

func _copy_source(snapshot: Dictionary):
	var b := Blueprint.new(snapshot.id, snapshot.seed, snapshot.style)
	b.recipe = snapshot.recipe.duplicate(true)
	b.rooms = snapshot.rooms.duplicate(true)
	for record: Variant in snapshot.parts:
		if not record is Dictionary or not record.get("physicalIntent") is String or not record.get("size") is Vector3: return null
		var part = b.add_part(record)
		part.physical_intent = record.physicalIntent
		part.size = record.size
	return b

func _validation_copy(snapshot: Dictionary):
	var b = _copy_source(snapshot)
	if b == null: return null
	for part in b.parts:
		for key: String in Recipe.CACHE_KEYS: part.recipe.erase(key)
	return b

func _whole_validation_bounded(b) -> bool:
	if b == null or b.parts.size() > Recipe.MAX_SOURCE + MAX_SELECTED: return false
	var cells := 0.0
	for part in b.parts:
		if not b.has_finite_positive_bounds(part): return false
		var bounds: AABB = b.transformed_part_bounds(part).grow(Blueprint.PHYSICAL_CONTACT_MARGIN * sqrt(3.0))
		if not Recipe._bounds_valid(bounds): return false
		var nx: float = floorf(bounds.end.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) - floorf(bounds.position.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) + 1.0
		var nz: float = floorf(bounds.end.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) - floorf(bounds.position.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) + 1.0
		if nx < 1.0 or nz < 1.0 or nx > Recipe.MAX_GRID_CELLS or nz > Recipe.MAX_GRID_CELLS: return false
		cells += nx * nz
		if cells > MAX_WHOLE_CELLS: return false
	return true

func _failed_ids(report: Dictionary) -> Array:
	var ids: Array = []
	for check: Variant in report.get("checks", []):
		if check is Dictionary and check.get("partId") is String and check.get("passed") == false and not ids.has(check.partId): ids.append(check.partId)
	ids.sort()
	return ids

func _sorted_unique(values: Array) -> Array:
	var result: Array = []
	for value: Variant in values:
		if value is String and not result.has(value): result.append(value)
	result.sort()
	return result

func _find(b, id: String):
	for part in b.parts:
		if part.id == id: return part
	return null

func _brief(result: Dictionary) -> Dictionary:
	var brief: Dictionary = {}
	for key: String in ["ready", "reason", "partId", "partIds", "sourceClosureIds", "rootIds", "validationGridCells", "furnitureObstacleCount"]:
		if result.has(key): brief[key] = result[key]
	return brief

func _fresh_file(path: String, extension := "") -> bool:
	return path.is_absolute_path() and (extension.is_empty() or path.get_extension().to_lower() == extension) and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path) and DirAccess.dir_exists_absolute(path.get_base_dir())

func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	if not _fresh_file(path): return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_position() == bytes.size()
	file.close()
	if not written: return false
	var hash := HashingContext.new()
	if hash.start(HashingContext.HASH_SHA256) != OK or hash.update(bytes) != OK: return false
	return FileAccess.get_sha256(path) == hash.finish().hex_encode()

func _json(value: Variant) -> Variant:
	if value is Vector3: return [_json(value.x), _json(value.y), _json(value.z)]
	if value is Vector2: return [_json(value.x), _json(value.y)]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is float and not is_finite(value): return str(value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
