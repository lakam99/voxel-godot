extends SceneTree

## Synthetic contracts plus optional SHA-bound single-panel or bounded batch probe.
## A source no-fit is RED (exit 1), never converted into an acceptance control.
const Recipe = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
var _checks: Dictionary = {}
var _results: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_LOWER_FACADE_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var fixture: Dictionary = _fixture()
	var good: Dictionary = _probe("synthetic_rooted_bottom_bearing", fixture)
	_checks["synthetic_positive_ready"] = good.get("ready", false)
	if good.get("ready", false):
		_checks["three_added_pieces_four_physical_checks"] = good.additions.size() == 3 and good.checks.size() == 4 and good.checks.all(func(c): return c.passed)
		_checks["unchanged_panel_geometry"] = Recipe.Aperture._geometry(Part.new(good.panel)) == Recipe.Aperture._geometry(Part.new(fixture.snapshot.parts[-1]))
		_checks["unchanged_rooms_and_recipe"] = var_to_bytes(good.afterSnapshot.rooms) == var_to_bytes(fixture.snapshot.rooms) and var_to_bytes(good.afterSnapshot.recipe) == var_to_bytes(fixture.snapshot.recipe)
		_checks["exact_panel_bottom_sill_top"] = Recipe.Connection._bounds(Part.new(good.additions[0]))[4] == Recipe.Connection._bounds(Part.new(good.panel))[1]
		_checks["two_real_core_sockets"] = _finite_sockets(good)
		_checks["complete_proof_grid_checked"] = good.get("proofGridWork", {}).get("ready", false)
		_checks["independent_seat_structural_intent"] = good.independentSeatCheck.intent in ["structural_mass", "structural_root"]
		_removal_controls(good)
		var by_id: Dictionary = {}
		for record: Dictionary in good.afterSnapshot.parts: by_id[record.id] = Part.new(record)
		_checks["unchanged_declaration_still_valid"] = Recipe.Aperture.validate(good.afterSnapshot.recipe.facadeApertures.synthetic_upper, by_id)
		var reversed: Dictionary = _fixture()
		reversed.snapshot.parts.reverse()
		var reverse_result: Dictionary = _probe("reversed_source", reversed)
		_checks["reversed_same_construction"] = reverse_result.get("ready", false) and var_to_bytes(reverse_result.get("additions")) == var_to_bytes(good.additions)
	_canonical_minimum_controls()
	_intent_controls()
	_portcullis_controls()
	for mode: String in ["missing_declaration", "stale_declaration", "prior_obligation", "missing_root", "moved_root", "rotated_seat", "thin_seat", "foreign_solid", "furniture", "aperture", "window", "door_sweep", "unsupported_door", "invalid_access", "duplicate_part", "nonfinite", "not_bottom", "too_narrow"]:
		var bad: Dictionary = _fixture()
		match mode:
			"missing_declaration": bad.snapshot.recipe.erase("facadeApertures")
			"stale_declaration": bad.snapshot.recipe.facadeApertures.synthetic_upper.wallDomain.size.z += 0.1
			"prior_obligation": bad.snapshot.parts[-1].recipe["physicalRequiredAnchorFacts"] = [{}]
			"missing_root":
				bad.snapshot.parts.remove_at(0)
				bad.snapshot.parts[0].recipe["physicalRoot"] = true
			"moved_root": bad.snapshot.parts[0].position.x = 20.0
			"rotated_seat": bad.snapshot.parts[1].rotation.y = 0.2
			"thin_seat": bad.snapshot.parts[1].size.x = 0.02
			"foreign_solid": bad.snapshot.parts.append(_record("synthetic_blocker", "wall", Vector3(-0.3, 2.38, 0), Vector3(0.1, 0.4, 2.2)))
			"furniture": bad.policy.furnitureParts.append({"id": "synthetic_chest", "position": Vector3(0, 2.2, 0), "size": Vector3(0.5, 0.5, 0.5), "rotation": Vector3.ZERO, "recipe": {}})
			"aperture":
				bad.snapshot.recipe.facadeApertures.synthetic_upper.openings[0].fullVolume = AABB(Vector3(-0.15, 2.2, -0.3), Vector3(0.3, 1, 0.6))
				_reseal(bad)
			"window": bad.snapshot.parts.append(_record("synthetic_window", "window", Vector3(0, 2.38, 0), Vector3(0.1, 0.2, 0.2), false))
			"door_sweep": bad.snapshot.parts.append(_record("synthetic_swing", "door", Vector3(0.65, 2.38, 0), Vector3(1.0, 1, 0.1), false))
			"unsupported_door":
				var door: Dictionary = _record("synthetic_raise", "door", Vector3(20, 2, 0), Vector3(1, 2, 0.1), false)
				door.recipe["doorMotion"] = "raise"
				bad.snapshot.parts.append(door)
			"invalid_access": bad.snapshot.rooms.append({"bounds": AABB(Vector3.ZERO, Vector3.ONE), "accesses": [{"position": Vector3.ZERO, "size": Vector3.ONE, "furnishingSize": Vector3.ZERO}]})
			"duplicate_part": bad.snapshot.parts.append(bad.snapshot.parts[0].duplicate(true))
			"nonfinite": bad.snapshot.parts[1].position.x = INF
			"not_bottom":
				var lower: Dictionary = _record("synthetic_lower_panel", "wall", Vector3(0, 2.0, 3), Vector3(0.3, 0.5, 1))
				lower.semantic = "citadel_urban_facade"
				bad.snapshot.parts.append(lower)
				bad.snapshot.recipe.facadeApertures.synthetic_upper.partIds.append(lower.id)
				_reseal(bad)
			"too_narrow":
				bad.snapshot.parts[-1].size.z = 0.12
				_reseal(bad)
		var rejected: Dictionary = _probe(mode, bad)
		_checks[mode + "_rejects_atomically"] = not rejected.get("ready", false) and not rejected.has("afterSnapshot") and not rejected.has("additions")
	var source: Dictionary = _source_probe()
	var passed: bool = _checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": _checks, "results": _results, "sourceProbe": source,
		"evidenceLevel": "synthetic_and_optional_single_panel_source_only",
		"limitations": "No engine scene, rendering, engineering capacity, navigation or gameplay proof. Ordinary doors use shared outward exact published quarter-sweep bounds; recognized raised portcullises use shared moving and stationary bounds. Unknown presentation/motion combinations fail closed. One masonry seat supplies both corbels; no mixed-seat search or promise that every bottom panel fits."}
	var bytes: PackedByteArray = JSON.stringify(report, "\t").to_utf8_buffer()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_position() == bytes.size()
	file.close()
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	written = written and FileAccess.get_sha256(path) == hash.finish().hex_encode()
	quit(0 if passed and written else 1)

func _portcullis_controls() -> void:
	for nearby: bool in [false, true]:
		var fixture: Dictionary = _fixture()
		var door: Dictionary = _record("synthetic_portcullis", "door", Vector3(0 if nearby else 20, 1, 0), Vector3(1, 1, 0.1))
		door.recipe["doorPresentation"] = "portcullis"
		door.recipe["doorMotion"] = "raise"
		if not nearby: door.rotation.y = 0.37
		fixture.snapshot.parts.append(door)
		var result: Dictionary = _probe("known_portcullis_near_" + str(nearby), fixture)
		if nearby:
			_checks["raised_path_blocks_bearing"] = not result.get("ready", false) and result.get("reason") == "protected_volume_blocked" and String(result.get("blockingPartId", "")).begins_with("door_sweep:" + door.id + ":") and not result.has("afterSnapshot")
			var closed: Array = Recipe.Door.portcullis_closed_primitives(door.size, Transform3D(Basis.IDENTITY, door.position))
			var bottom: float = Recipe.Connection._bounds(Part.new(fixture.snapshot.parts[2]))[1] - Recipe.HEIGHT
			_checks["raised_negative_closed_geometry_below_sill"] = closed.all(func(piece): return piece.bounds.end.y < bottom)
		else:
			_checks["recognized_distant_raised_door_allows_fit"] = result.get("ready", false)
		var protected: Dictionary = Recipe._protected(fixture.snapshot, fixture.policy, fixture.snapshot.parts.map(func(record): return Part.new(record)))
		var expected: Array = Recipe.Door.portcullis_sweep_bounds(door.size, Transform3D(Basis.from_euler(door.rotation), door.position))
		_checks["actual_transform_shared_sweep_exact_" + str(nearby)] = protected.ready and var_to_bytes(protected.volumes.map(func(volume): return volume.bounds)) == var_to_bytes(expected)
	for combination: Array in [["portcullis", "swing"], ["unknown", "raise"], ["portcullis", "unknown"]]:
		var fixture: Dictionary = _fixture()
		var door: Dictionary = _record("synthetic_unknown_door", "door", Vector3(20, 1, 0), Vector3(1, 1, 0.1))
		door.recipe["doorPresentation"] = combination[0]
		door.recipe["doorMotion"] = combination[1]
		fixture.snapshot.parts.append(door)
		var result: Dictionary = _probe("unknown_door_" + combination[0] + "_" + combination[1], fixture)
		_checks["unknown_combo_rejected_" + str(combination)] = not result.get("ready", false) and result.get("reason") == "unsupported_door_sweep:" + door.id and not result.has("afterSnapshot")

func _intent_controls() -> void:
	for mode: String in ["recipe_only_override", "conflicting_override", "empty_override", "nonstring_override", "portal_seat", "walkable_seat", "portal_panel"]:
		var fixture: Dictionary = _fixture()
		var record: Dictionary = fixture.snapshot.parts[-1] if mode == "portal_panel" else fixture.snapshot.parts[1]
		match mode:
			"recipe_only_override": record.recipe["physicalIntent"] = "structural_mass"
			"conflicting_override":
				record.physicalIntent = "portal"
				record.recipe["physicalIntent"] = "structural_mass"
			"empty_override":
				record.physicalIntent = "structural_mass"
				record.recipe["physicalIntent"] = ""
			"nonstring_override": record.recipe["physicalIntent"] = 7
			"portal_seat", "portal_panel":
				record.physicalIntent = "portal"
				record.recipe["physicalIntent"] = "portal"
			"walkable_seat":
				record.physicalIntent = "walkable_surface"
				record.recipe["physicalIntent"] = "walkable_surface"
		var result: Dictionary = _probe(mode, fixture)
		_checks[mode + "_rejected"] = not result.get("ready", false) and not result.has("afterSnapshot")
		if mode in ["recipe_only_override", "conflicting_override", "empty_override"]:
			_checks[mode + "_exact_conflict_reason"] = result.get("reason") == "conflicting_physical_intent" and result.get("partId") == record.id
	for explicit_recipe: bool in [false, true]:
		var fixture: Dictionary = _fixture()
		for record: Dictionary in fixture.snapshot.parts:
			record.physicalIntent = "structural_mass"
			if explicit_recipe: record.recipe["physicalIntent"] = "structural_mass"
		var result: Dictionary = _probe("consistent_intent_" + str(explicit_recipe), fixture)
		_checks["consistent_intent_accepted_" + str(explicit_recipe)] = result.get("ready", false)
		if result.get("ready", false):
			_checks["panel_intent_preserved_" + str(explicit_recipe)] = result.panel.physicalIntent == fixture.snapshot.parts[-1].physicalIntent and result.panel.recipe.get("physicalIntent") == fixture.snapshot.parts[-1].recipe.get("physicalIntent")

func _removal_controls(good: Dictionary) -> void:
	var frozen: PackedByteArray = var_to_bytes(good)
	var body_id: String = good.additions[0].id
	var removed_ids: Array = [good.additions[1].id, good.additions[2].id, good.joints[0].seatId]
	for removed_id: String in removed_ids:
		var snapshot: Dictionary = good.afterSnapshot.duplicate(true)
		snapshot.parts = snapshot.parts.filter(func(record): return record.id != removed_id)
		var b = Recipe.Copy.copy_blueprint(snapshot)
		Recipe.Copy.clear_caches(b)
		var grid: Dictionary = Recipe.Copy.validation_grid_work(b)
		_checks["removal_grid_" + removed_id] = grid.ready
		if not grid.ready: continue
		var physical: Dictionary = b.validate_physical_integrity()
		var body_checks: Array = physical.checks.filter(func(check): return check.partId == body_id)
		var panel_checks: Array = physical.checks.filter(func(check): return check.partId == good.panelId)
		_checks["removal_invalidates_body_" + removed_id] = body_checks.size() == 1 and not body_checks[0].passed
		_checks["removal_invalidates_panel_" + removed_id] = panel_checks.size() == 1 and not panel_checks[0].passed
		_results["remove_" + removed_id] = {"removedId": removed_id, "bodyChecks": body_checks, "panelChecks": panel_checks, "failedIds": Recipe.Copy.failed_ids(physical)}
	_checks["removal_controls_leave_proposal_immutable"] = var_to_bytes(good) == frozen

func _canonical_minimum_controls() -> void:
	# Independent IEEE-754 predecessor: even one float32 step below the native
	# minimum must reject. Mutate RAW records so Part cannot sanitise the test.
	var encoded := PackedByteArray()
	encoded.resize(4)
	encoded.encode_float(0, 0.02)
	var minimum: float = encoded.decode_float(0)
	encoded.encode_u32(0, encoded.decode_u32(0) - 1)
	var predecessor: float = encoded.decode_float(0)
	_checks["minimum_control_distinct_predecessor"] = predecessor < minimum
	for axis in range(3):
		for value: float in [minimum, predecessor, 0.01, 0.0, -0.02]:
			var fixture: Dictionary = _fixture()
			var record: Dictionary = _record("synthetic_minimum_probe", "wall", Vector3(30, 30, 30), Vector3.ONE, false)
			var size := Vector3.ONE
			size[axis] = value
			record.size = size
			fixture.snapshot.parts.append(record)
			var frozen: PackedByteArray = var_to_bytes(fixture)
			var result: Dictionary = Recipe._read(fixture.snapshot, fixture.panelId, fixture.policy)
			var label: String = "canonical_minimum_axis_%d_value_%.12f" % [axis, value]
			_checks[label + "_immutable"] = var_to_bytes(fixture) == frozen
			if value == minimum:
				_checks[label + "_accepted_exactly"] = result.get("ready", false)
			else:
				_checks[label + "_rejected_with_size_evidence"] = not result.get("ready", false) and result.get("reason") == "degenerate_part" and result.get("partId") == record.id and result.get("sourceSize") == size and result.get("canonicalSize") == Part.new(record).size and not result.has("afterSnapshot")
			_results[label] = {"inputSize": size, "ready": result.get("ready", false), "reason": result.get("reason", ""), "canonicalSize": result.get("canonicalSize", size)}

func _fixture() -> Dictionary:
	var b := Blueprint.new("synthetic_lower_bearing", 17, "timber")
	b.add_part(_record("synthetic_foundation", "foundation", Vector3(-0.6, 0.25, 0), Vector3(1, 0.5, 3)))
	b.add_part(_record("synthetic_stone", "wall", Vector3(-0.6, 1.5, 0), Vector3(0.5, 2, 2.5)))
	var panel = b.add_part(_record("synthetic_upper_panel", "wall", Vector3(0, 3, 0), Vector3(0.3, 1, 2)))
	panel.semantic = "citadel_urban_facade"
	var declaration := {"producerPrefix": "synthetic_upper", "semantic": panel.semantic,
		"wallDomain": AABB(Vector3(-0.15, 2.5, -1), Vector3(0.3, 1, 4)),
		"openings": [{"id": "synthetic_opening", "input": {"centerY": 3.0, "height": 1.0, "centerZ": 2.5, "width": 1.0}, "fullVolume": AABB(Vector3(-0.15, 2.5, 2), Vector3(0.3, 1, 1))}]}
	b.recipe["facadeApertures"] = {"synthetic_upper": Recipe.Aperture.seal(declaration, [panel])}
	return {"snapshot": b.snapshot(), "panelId": panel.id, "policy": {"furnitureParts": [], "reservedVolumes": []}}

func _record(id: String, kind: String, position: Vector3, size: Vector3, collision: bool = true) -> Dictionary:
	return Part.new({"id": id, "kind": kind, "position": position, "size": size, "collision": collision, "material": "stone_foundation", "recipe": {}}).snapshot()

func _reseal(fixture: Dictionary) -> void:
	var declaration: Dictionary = fixture.snapshot.recipe.facadeApertures.synthetic_upper
	var parts: Array = []
	for id: String in declaration.partIds:
		for record: Dictionary in fixture.snapshot.parts:
			if record.id == id: parts.append(Part.new(record))
	declaration.erase("sourceBinding")
	fixture.snapshot.recipe.facadeApertures.synthetic_upper = Recipe.Aperture.seal(declaration, parts)

func _probe(name: String, fixture: Dictionary) -> Dictionary:
	var frozen: PackedByteArray = var_to_bytes(fixture)
	var result: Dictionary = Recipe.prepare(fixture.snapshot, fixture.panelId, fixture.policy)
	_checks[name + "_immutable"] = var_to_bytes(fixture) == frozen
	var repeat: Dictionary = Recipe.prepare(fixture.snapshot, fixture.panelId, fixture.policy)
	_checks[name + "_deterministic"] = var_to_bytes(result) == var_to_bytes(repeat) and var_to_bytes(fixture) == frozen
	var summary: Dictionary = result.duplicate(true)
	summary.erase("afterSnapshot")
	_results[name] = summary
	return result

func _finite_sockets(result: Dictionary) -> bool:
	if result.joints.size() != 2: return false
	for joint: Dictionary in result.joints:
		if not joint.socket.is_finite() or joint.actualOverlap.size() != 6: return false
		for axis in range(3):
			if float(joint.socket[axis]) - Recipe.HALF[axis] < joint.coreBounds[axis] or float(joint.socket[axis]) + Recipe.HALF[axis] > joint.coreBounds[axis + 3]: return false
			if joint.actualOverlap[axis] >= joint.actualOverlap[axis + 3]: return false
	return true

func _source_probe() -> Dictionary:
	var path: String = OS.get_environment("VOXEL_LOWER_FACADE_INPUT")
	var sha: String = OS.get_environment("VOXEL_LOWER_FACADE_INPUT_SHA256").to_lower()
	var panel: String = OS.get_environment("VOXEL_LOWER_FACADE_PANEL_ID")
	var batch: bool = OS.get_environment("VOXEL_LOWER_FACADE_BATCH") == "1"
	if path.is_empty() and sha.is_empty() and panel.is_empty() and not batch: return {"requested": false}
	_checks["source_bound_input"] = false
	if not path.is_absolute_path() or sha.length() != 64 or sha.hex_decode().size() != 32 or (panel.is_empty() and not batch) or FileAccess.get_sha256(path) != sha: return {"ready": false, "reason": "invalid_source_binding"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ready": false, "reason": "source_open_failed"}
	var length: int = file.get_length()
	if length <= 0 or length > 32 * 1024 * 1024:
		file.close()
		return {"ready": false, "reason": "source_size_limit"}
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	var raw: Variant = bytes_to_var(bytes)
	if not complete or not raw is Dictionary or var_to_bytes(raw) != bytes or FileAccess.get_sha256(path) != sha: return {"ready": false, "reason": "source_read_failed"}
	if not raw.get("afterSnapshot") is Dictionary or not raw.get("furnitureSnapshot") is Dictionary or not raw.furnitureSnapshot.get("parts") is Array or not raw.get("protectedReservations") is Array: return {"ready": false, "reason": "source_archive_schema"}
	_checks["source_bound_input"] = true
	var before: PackedByteArray = var_to_bytes(raw)
	var policy := {"furnitureParts": raw.furnitureSnapshot.parts, "reservedVolumes": raw.protectedReservations}
	var selection: Dictionary = _select_bottom_panels(raw.afterSnapshot) if batch else {}
	var result: Dictionary
	if batch:
		result = Recipe.prepare_batch(raw.afterSnapshot, selection.get("selected", []), policy) if selection.get("ready", false) else selection
	else:
		result = Recipe.prepare(raw.afterSnapshot, panel, policy)
	_checks["source_immutable"] = before == var_to_bytes(raw) and FileAccess.get_sha256(path) == sha
	_checks["actual_source_panel_ready"] = result.get("ready", false)
	if OS.get_environment("VOXEL_LOWER_FACADE_VALIDATE_WORLD") == "1" and result.get("ready", false):
		result["wholeWorldMeasurement"] = _measure_whole_world(raw, result, sha)
	result.erase("afterSnapshot")
	return {"requested": true, "input": path, "sha256": sha, "panelId": panel, "selection": selection, "result": result}

func _select_bottom_panels(snapshot: Dictionary) -> Dictionary:
	# Test selection only: failures and exact declaration geometry select the
	# cohort. The recipe must independently validate every selected request.
	var blueprint = Recipe.Copy.copy_blueprint(snapshot)
	Recipe.Copy.clear_caches(blueprint)
	var grid := Recipe.Copy.validation_grid_work(blueprint)
	if not grid.ready: return grid
	var report: Dictionary = blueprint.validate_physical_integrity()
	var failed: Array = Recipe.Copy.failed_ids(report)
	var by_id := {}
	for part in blueprint.parts: by_id[part.id] = part
	var eligible: Array = []
	for declaration: Dictionary in snapshot.recipe.get("facadeApertures", {}).values():
		if not Recipe.Aperture.validate(declaration, by_id): return {"ready": false, "reason": "invalid_selection_declaration"}
		var bottom := INF
		for id: String in declaration.partIds: bottom = minf(bottom, Recipe.Connection._bounds(by_id[id])[1])
		for id: String in declaration.partIds:
			var part = by_id[id]
			if failed.has(id) and not Recipe._has_obligation(part.recipe) and Recipe.Connection._bounds(part)[1] == bottom:
				eligible.append(id)
	eligible.sort()
	var offset_text := OS.get_environment("VOXEL_LOWER_FACADE_BATCH_OFFSET")
	if not offset_text.is_empty() and (not offset_text.is_valid_int() or int(offset_text) < 0): return {"ready": false, "reason": "invalid_batch_offset"}
	var offset := int(offset_text)
	return {"ready": true, "eligible": eligible, "offset": offset, "selected": eligible.slice(offset, offset + Recipe.MAX_BATCH_PANELS),
		"beforeFailureCount": report.violations.size(), "remainingViolations": report.violations,
		"remainingChecks": report.checks.filter(func(check): return not check.passed)}

func _measure_whole_world(raw: Dictionary, proposal: Dictionary, source_sha: String) -> Dictionary:
	var before = Recipe.Copy.copy_blueprint(raw.afterSnapshot)
	var after = Recipe.Copy.copy_blueprint(proposal.afterSnapshot)
	Recipe.Copy.clear_caches(before)
	Recipe.Copy.clear_caches(after)
	var before_grid := Recipe.Copy.validation_grid_work(before)
	var after_grid := Recipe.Copy.validation_grid_work(after)
	_checks["whole_validation_work_bounded"] = before_grid.ready and after_grid.ready
	if not before_grid.ready or not after_grid.ready: return {"ready": false, "reason": "whole_validation_grid_limit"}
	var before_report: Dictionary = before.validate_physical_integrity()
	var after_report: Dictionary = after.validate_physical_integrity()
	var removed: Array = before_report.violations.filter(func(value): return not after_report.violations.has(value))
	var added: Array = after_report.violations.filter(func(value): return not before_report.violations.has(value))
	_checks["whole_gate_reduces_without_new_failures"] = not removed.is_empty() and added.is_empty() and after_report.violations.size() < before_report.violations.size()
	_checks["whole_rooms_and_recipe_unchanged"] = var_to_bytes(raw.afterSnapshot.rooms) == var_to_bytes(proposal.afterSnapshot.rooms) and var_to_bytes(raw.afterSnapshot.recipe) == var_to_bytes(proposal.afterSnapshot.recipe)
	var output := OS.get_environment("VOXEL_LOWER_FACADE_CANDIDATE_OUTPUT")
	var evidence := {"ready": true, "beforeCount": before_report.violations.size(), "afterCount": after_report.violations.size(), "removed": removed, "added": added,
		"furnitureCount": raw.furnitureSnapshot.parts.size(), "sourceSha256": source_sha, "scope": "Full source physical-gate measurement only, not publication, rendered clearance, visual or gameplay acceptance."}
	_checks["candidate_output_written"] = false
	if not _checks.whole_gate_reduces_without_new_failures or not output.is_absolute_path() or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()): return evidence
	var candidate: Dictionary = raw.duplicate(true)
	candidate.afterSnapshot = proposal.afterSnapshot
	var summary: Dictionary = proposal.duplicate(true)
	summary.erase("afterSnapshot")
	var history: Array = raw.get("lowerBearingProposals", []).duplicate(true)
	var additions: Array = summary.get("accepted", [summary])
	history.append_array(additions)
	candidate["lowerBearingProposals"] = history
	candidate["lowerBearingLastRejected"] = summary.get("rejected", [])
	candidate["lowerBearingInputSha256"] = source_sha
	_checks["candidate_furniture_and_reservations_exact"] = var_to_bytes(candidate.furnitureSnapshot) == var_to_bytes(raw.furnitureSnapshot) and var_to_bytes(candidate.protectedReservations) == var_to_bytes(raw.protectedReservations)
	var encoded := var_to_bytes(candidate)
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: return evidence
	file.store_buffer(encoded)
	file.flush()
	_checks["candidate_output_written"] = file.get_error() == OK and file.get_position() == encoded.size()
	file.close()
	evidence["candidatePath"] = output
	evidence["candidateSha256"] = FileAccess.get_sha256(output)
	return evidence
