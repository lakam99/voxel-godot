extends SceneTree

## Source/service contracts using the actual street-house and roof-frame producer.
## No publisher, scene, physics, actor or navigation acceptance. Main runs later.
## VOXEL_CHIMNEY_BEARING_REPORT: fresh absolute JSON, existing parent directory.
## Optional VOXEL_CHIMNEY_REVIEWED_BASELINE: immutable reviewed.bin. All source
## chimneys are examined; frozen readiness is reported SEPARATELY from test PASS.
## VOXEL_CHIMNEY_FULL_CANDIDATE=1 additionally applies ALL viable proposals to a
## private reviewed-source copy and checks full physical/furniture regression.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Recipe = preload("res://scripts/buildings/ChimneyBearingRecipe.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const REVIEWED_SHA := "e43b972eface80bbcbc015ef55ac0c21a5cb99083dcfa9aabbb5a407f9832038"
var _checks: Array = []
var _frozen: Dictionary = {"requested": false}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_CHIMNEY_BEARING_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	for index in range(16): _positive(_fixture(index), "producer_%02d" % index)
	for mode in ["missing_chimney", "missing_gable", "duplicate_gable", "missing_root", "fake_root", "cached_support_only", "nonfinite", "huge_finite", "intent_conflict", "tilted_chimney", "unequal_gables", "narrow_gable", "roof_intrusion", "frame_intrusion", "furniture", "access", "invalid_furniture", "extra_upstream"]:
		_negative(mode)
	_lateral_controls()
	_frozen_control()
	var passed: bool = not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var report := {"fixture": "CitadelChimneyBearingContract", "passed": passed, "checks": _checks,
		"frozen": _frozen, "evidenceLevel": "actual_producer_source_service_contract",
		"doesNotProve": "No published overlap, engineering load capacity, live visual preservation, accessibility, NPC or navigation acceptance. Frozen proposed bearings can remain blocked despite synthetic contract PASS."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("Chimney bearing source contract: %s (%d checks); frozen all ready=%s" % ["PASS" if passed else "FAIL", _checks.size(), str(_frozen.get("allReady", false))])
	quit(2 if error != OK else (0 if passed else 1))

func _fixture(index := 0) -> Dictionary:
	var b := Blueprint.new("actual_chimney_producer_contract", 101 + index, "timber")
	var prefix := "producer_%02d" % index
	Urban.add_street_house(b, prefix, Vector3(13.17 + index * 0.13, 0, -17.6),
		7.4 + float(index % 4) * 0.9, 8.0 + float(index % 3), 6.2 if index % 2 == 0 else 9.3,
		-1.0 if index < 8 else 1.0, 0.62 + float(index % 3) * 1.8, "painted_brick_cream", float(index % 5) * 0.013)
	var frame: Dictionary = Urban.add_roof_frames(b)
	_check(prefix + ":actual_roof_frame_constructed", frame.get("ready", false), _brief(frame))
	var ids := _producer_ids(prefix)
	ids["b"] = b
	ids["furniture"] = []
	return ids

func _producer_ids(prefix: String) -> Dictionary:
	# Explicit producer grammar roles belong to this caller, not to the recipe.
	return {"chimney": prefix + "_chimney", "gables": [prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"],
		"upstream": [prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"]}

func _call(fixture: Dictionary, apply := false) -> Dictionary:
	if apply: return Recipe.apply(fixture.b, fixture.chimney, fixture.gables, fixture.upstream, fixture.furniture)
	return Recipe.plan(fixture.b, fixture.chimney, fixture.gables, fixture.upstream, fixture.furniture)

func _positive(fixture: Dictionary, label: String) -> void:
	var b = fixture.b
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var input_before := var_to_bytes([fixture.gables, fixture.upstream, fixture.furniture])
	var proposal := _call(fixture)
	_check(label + ":plan_readonly", var_to_bytes(before) == var_to_bytes(b.snapshot()) and input_before == var_to_bytes([fixture.gables, fixture.upstream, fixture.furniture]))
	_check(label + ":ready", proposal.ready, _brief(proposal))
	if not proposal.ready: return
	var repeat := _call(fixture)
	_check(label + ":repeat_exact", var_to_bytes(repeat) == var_to_bytes(proposal))
	b.parts.reverse()
	fixture.gables.reverse()
	fixture.upstream.reverse()
	var reversed := _call(fixture)
	_check(label + ":order_stable", var_to_bytes(reversed) == var_to_bytes(proposal))
	b.parts.reverse()
	fixture.gables.reverse()
	fixture.upstream.reverse()
	var result := _call(fixture, true)
	_check(label + ":apply_matches_plan", result.ready and var_to_bytes(result) == var_to_bytes(proposal))
	if not result.ready: return
	var expected: Dictionary = before.duplicate(true)
	for record in expected.parts:
		if record.id == fixture.chimney: record.recipe = proposal.chimneyRecipe.duplicate(true)
	expected.parts.append(proposal.bearerRecord.duplicate(true))
	_check(label + ":all_geometry_roofs_rooms_contents_preserved", var_to_bytes(expected) == var_to_bytes(b.snapshot()))
	var same_objects := true
	for index in range(aliases.size()): same_objects = same_objects and is_same(aliases[index], b.parts[index])
	_check(label + ":original_part_objects_preserved", same_objects)
	var chimney = _find(b, fixture.chimney)
	var bearer = _find(b, result.partIds[0])
	_check(label + ":mandatory_two_wall_seats_and_chimney_seat", bearer.recipe.physicalRequiredSeatFacts.size() == 2 and chimney.recipe.physicalRequiredSeatFacts.size() == 1 and chimney.recipe.physicalRequiredSeatPartIds == result.partIds)
	_check(label + ":no_published_fake_root_or_cache", not bearer.recipe.has("physicalRoot") and not bearer.recipe.has("physicalSupportPartIds") and not bearer.recipe.has("physicalSupportCoverage"))
	var applied_before := var_to_bytes(b.snapshot())
	var repeated_apply := _call(fixture, true)
	_check(label + ":repeat_rejects_without_mutation", not repeated_apply.ready and applied_before == var_to_bytes(b.snapshot()))
	if label == "producer_00": _seat_controls(b, result, fixture)

func _seat_controls(source, proposal: Dictionary, fixture: Dictionary) -> void:
	var ids: Array = proposal.sourceClosureIds + proposal.partIds + [fixture.chimney]
	for mode in ["intact", "remove_first_gable", "remove_second_gable", "remove_root", "move_chimney_patch", "move_bearer_patch", "no_bearer_collision"]:
		var staged := Blueprint.new("isolated_actual_chimney_seats", 101, "timber")
		for id in ids:
			if mode == "remove_first_gable" and id == fixture.gables[0]: continue
			if mode == "remove_second_gable" and id == fixture.gables[1]: continue
			if mode == "remove_root" and proposal.rootIds.has(id): continue
			var original = _find(source, id)
			var copy = staged.add_part(original.snapshot())
			copy.physical_intent = original.physical_intent
			for key in Recipe.CACHE_KEYS: copy.recipe.erase(key)
		if mode == "move_chimney_patch": _find(staged, fixture.chimney).recipe.physicalRequiredSeatFacts[0].localPatchCenter.y += 0.5
		if mode == "move_bearer_patch": _find(staged, proposal.partIds[0]).recipe.physicalRequiredSeatFacts[0].localPatchCenter.z += 1.0
		if mode == "no_bearer_collision": _find(staged, proposal.partIds[0]).collision_enabled = false
		var validation: Dictionary = staged.validate_physical_integrity()
		_check("isolated_fresh_seat_validation:" + mode, validation.passed == (mode == "intact"), validation.violations)

func _lateral_controls() -> void:
	for obstruction_side in [-1.0, 1.0]:
		var fixture := _fixture(30 + int(obstruction_side))
		var centered := _call(fixture)
		_check("lateral_control_center_ready_%d" % int(obstruction_side), centered.get("ready", false) and absf(float(centered.get("bearingOffsetX", INF))) <= 0.000001, _brief(centered))
		if not centered.get("ready", false): continue
		var chimney = _find(fixture.b, fixture.chimney)
		_add_lateral_blocker(fixture.b, chimney, centered, obstruction_side, "lateral_visual_blocker")
		var before := var_to_bytes(fixture.b.snapshot())
		var shifted := _call(fixture)
		var repeat := _call(fixture)
		fixture.b.parts.reverse(); fixture.gables.reverse(); fixture.upstream.reverse()
		var reversed := _call(fixture)
		fixture.b.parts.reverse(); fixture.gables.reverse(); fixture.upstream.reverse()
		_check("lateral_control_plan_ready_%d" % int(obstruction_side), shifted.get("ready", false), _brief(shifted))
		_check("lateral_control_ranked_away_%d" % int(obstruction_side), shifted.get("bearingMode", "") == "two_gable" and signf(float(shifted.get("bearingOffsetX", 0.0))) == -obstruction_side and absf(float(shifted.get("bearingOffsetX", 0.0))) > 0.12 and absf(float(shifted.get("bearingOffsetX", 0.0))) < 0.20, _brief(shifted))
		_check("lateral_control_deterministic_order_%d" % int(obstruction_side), var_to_bytes(shifted) == var_to_bytes(repeat) and var_to_bytes(shifted) == var_to_bytes(reversed) and before == var_to_bytes(fixture.b.snapshot()))
		if shifted.get("ready", false):
			var applied := _call(fixture, true)
			var bearer = _find(fixture.b, shifted.partIds[0])
			var resolved: Dictionary = fixture.b.validate_physical_integrity()
			var relevant_ids: Array = shifted.sourceClosureIds + shifted.partIds + [fixture.chimney]
			var relevant_pass := relevant_ids.all(func(id):
				var matches: Array = resolved.checks.filter(func(check): return check.partId == id)
				return matches.size() == 1 and matches[0].passed)
			_check("lateral_control_apply_and_seats_%d" % int(obstruction_side), var_to_bytes(applied) == var_to_bytes(shifted) and relevant_pass and bearer != null and bearer.recipe.physicalRequiredSeatFacts.all(func(fact): return fixture.b.has_rooted_bearer_seat(bearer, fact)), resolved.violations)
	var blocked := _fixture(40)
	var centered := _call(blocked)
	if centered.get("ready", false):
		var chimney = _find(blocked.b, blocked.chimney)
		_add_lateral_blocker(blocked.b, chimney, centered, -1.0, "left_visual_blocker")
		_add_lateral_blocker(blocked.b, chimney, centered, 1.0, "right_visual_blocker")
		var before := var_to_bytes(blocked.b.snapshot())
		var rejected := _call(blocked, true)
		_check("lateral_control_no_valid_offset_rejects_atomically", not rejected.get("ready", false) and rejected.get("reason") == "no_clear_bearing_candidate" and before == var_to_bytes(blocked.b.snapshot()), _brief(rejected))
	else:
		_check("lateral_control_no_valid_offset_fixture_ready", false, _brief(centered))

func _add_lateral_blocker(b, chimney, centered: Dictionary, side: float, id: String) -> void:
	var bounds: AABB = centered.bearerBounds
	b.add_part({"id": id, "kind": "sign", "material": "painted_decor", "collision": false,
		"position": Vector3(chimney.position.x + side * (chimney.size.x * 0.5 - 0.074), bounds.get_center().y, chimney.position.z),
		"size": Vector3(0.12, bounds.size.y * 0.75, minf(0.5, bounds.size.z * 0.5)),
		"semantic": "lateral_visual_obstruction"})

func _negative(mode: String) -> void:
	var fixture := _fixture()
	var b = fixture.b
	var chimney = _find(b, fixture.chimney)
	var gable = _find(b, fixture.gables[0])
	var proposal := _call(fixture)
	if not proposal.ready:
		_check("negative_requires_positive_fixture:" + mode, false, _brief(proposal))
		return
	match mode:
		"missing_chimney": fixture.chimney = "absent"
		"missing_gable": b.parts.erase(gable)
		"duplicate_gable": fixture.gables[1] = fixture.gables[0]
		"missing_root": b.parts.erase(_find(b, fixture.upstream[0]))
		"fake_root": gable.recipe["physicalRoot"] = true
		"cached_support_only":
			var root = _find(b, fixture.upstream[0])
			root.position.y -= 5.0
			gable.recipe["physicalSupportPartIds"] = [root.id]
		"nonfinite": chimney.position.x = NAN
		"huge_finite": chimney.position.x = 1.0e30
		"intent_conflict":
			chimney.physical_intent = "structural_mass"
			chimney.recipe["physicalIntent"] = "facade_attachment"
		"tilted_chimney": chimney.rotation.z = 0.1
		"unequal_gables": gable.position.y += 0.25
		"narrow_gable":
			# A single unusable gable is now a valid fallback case. The negative
			# requires both producer-owned bearing choices to be too narrow.
			for gable_id in fixture.gables:
				_find(b, gable_id).size.z = 0.06
		"roof_intrusion", "frame_intrusion":
			var blocker = b.add_part(proposal.bearerRecord)
			blocker.id = "intrusion_control"
			blocker.kind = "roof" if mode == "roof_intrusion" else "beam"
			blocker.recipe = {}
			blocker.collision_enabled = false
		"furniture": fixture.furniture.append({"id": "furnishing:protected", "bounds": proposal.bearerBounds})
		"access": b.rooms[0].accesses.append({"id": "protected_access", "position": proposal.bearerBounds.get_center(), "size": proposal.bearerBounds.size})
		"invalid_furniture": fixture.furniture.append({"id": "invalid", "bounds": AABB(Vector3(NAN, 0, 0), Vector3.ONE)})
		"extra_upstream":
			b.add_part({"id": "foreign_root", "kind": "foundation", "collision": true, "position": Vector3(70, 0.5, 70), "size": Vector3(2, 1, 2)})
			fixture.upstream.append("foreign_root")
	var before := var_to_bytes(b.snapshot())
	var inputs := var_to_bytes([fixture.gables, fixture.upstream, fixture.furniture])
	var rejected := _call(fixture, true)
	_check("atomic_rejection:" + mode, not rejected.ready and not String(rejected.reason).is_empty() and before == var_to_bytes(b.snapshot()) and inputs == var_to_bytes([fixture.gables, fixture.upstream, fixture.furniture]), _brief(rejected))

func _frozen_control() -> void:
	var path := OS.get_environment("VOXEL_CHIMNEY_REVIEWED_BASELINE").strip_edges().simplify_path()
	if path.is_empty():
		if OS.get_environment("VOXEL_CHIMNEY_FULL_CANDIDATE") == "1": _check("full_candidate_requires_reviewed_baseline", false)
		return
	_frozen = {"requested": true, "allReady": false, "proposals": []}
	if not path.is_absolute_path() or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != REVIEWED_SHA:
		_check("reviewed_snapshot_hash", false)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_check("reviewed_snapshot_open", false)
		return
	if file.get_length() > 128 * 1024 * 1024:
		file.close()
		_check("reviewed_snapshot_bounded", false)
		return
	var envelope: Variant = file.get_var(false)
	var read_ok := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not read_ok or not envelope is Dictionary or not envelope.get("sourceSnapshot") is Dictionary or not envelope.get("furnitureSnapshot") is Dictionary or not envelope.get("protectedReservations") is Array:
		_check("reviewed_snapshot_schema", false)
		return
	var snapshot: Dictionary = envelope.sourceSnapshot
	var b := Blueprint.new(snapshot.id, snapshot.seed, snapshot.style)
	b.recipe = snapshot.recipe.duplicate(true)
	b.rooms = snapshot.rooms.duplicate(true)
	for record in snapshot.parts:
		var copy = b.add_part(record)
		copy.physical_intent = record.physicalIntent
	var furniture: Array = []
	for record in envelope.furnitureSnapshot.parts:
		var size: Vector3 = record.occupiedSize
		var pose := Transform3D(Basis.from_euler(record.rotation), record.position)
		furniture.append({"id": "furnishing:" + String(record.id), "bounds": pose * AABB(Vector3(-size.x * 0.5, 0, -size.z * 0.5), size)})
	for index in range(envelope.protectedReservations.size()): furniture.append({"id": "furnishing_access:%d" % index, "bounds": envelope.protectedReservations[index]})
	var before := var_to_bytes(b.snapshot())
	var originals := var_to_bytes([envelope.furnitureSnapshot, envelope.protectedReservations])
	var chimneys: Array = b.parts.filter(func(part): return part.semantic == "citadel_urban_chimney")
	chimneys.sort_custom(func(a, c): return a.id < c.id)
	var ready_count := 0
	for chimney in chimneys:
		# This contract consumes the actual producer's declared ID suffix map;
		# no seed/house exception exists in the recipe or frozen coverage list.
		var fixture := _producer_ids(String(chimney.id).trim_suffix("_chimney"))
		fixture["b"] = b
		fixture["furniture"] = furniture
		var result := _call(fixture)
		if result.ready: ready_count += 1
		var row := _brief(result)
		row["chimneyId"] = chimney.id
		_frozen.proposals.append(row)
	_check("reviewed_all_16_producer_chimneys_examined", chimneys.size() == 16 and _frozen.proposals.size() == chimneys.size())
	_check("reviewed_source_furniture_and_archive_unchanged", before == var_to_bytes(b.snapshot()) and originals == var_to_bytes([envelope.furnitureSnapshot, envelope.protectedReservations]) and FileAccess.get_sha256(path) == REVIEWED_SHA)
	_frozen["readyCount"] = ready_count
	_frozen["chimneyCount"] = chimneys.size()
	_frozen["furnitureObstacleCount"] = furniture.size()
	_frozen["allReady"] = ready_count == chimneys.size() and not chimneys.is_empty()
	_frozen["scope"] = "Read-only proposals against reviewed source and protected furniture, not a visual/physical acceptance of the complete candidate. Blocked proposals remain explicitly blocked."
	if OS.get_environment("VOXEL_CHIMNEY_FULL_CANDIDATE") == "1":
		_full_candidate_control(b, envelope, furniture)
		_check("reviewed_archive_unchanged_after_full_candidate", FileAccess.get_sha256(path) == REVIEWED_SHA)

func _full_candidate_control(original, envelope: Dictionary, furniture: Array) -> void:
	var check_start := _checks.size()
	var original_snapshot: Dictionary = original.snapshot()
	var protected_before := var_to_bytes([envelope.furnitureSnapshot, envelope.protectedReservations, furniture])
	var candidate = _copy_source(original_snapshot)
	var expected: Dictionary = original_snapshot.duplicate(true)
	var expected_records: Dictionary = {}
	for record in expected.parts: expected_records[record.id] = record
	var constructed: Array = []
	var new_ids: Array = []
	var blocked: Array = []
	var result_summary := {"requested": true, "passed": false,
		"scope": "Incremental full reviewed source: apply every viable chimney bearing; retain each blocked chimney unchanged. This is NOT all-chimney readiness or live acceptance."}
	_frozen["fullCandidate"] = result_summary
	for proposal in _frozen.proposals:
		var id: String = proposal.chimneyId
		if not proposal.ready:
			blocked.append({"chimneyId": id, "reason": proposal.reason, "partId": proposal.get("partId", "")})
			continue
		var fixture := _producer_ids(id.trim_suffix("_chimney"))
		fixture["b"] = candidate
		fixture["furniture"] = furniture
		var applied := _call(fixture, true)
		_check("full_candidate_viable_proposal_applied:" + id, applied.ready, _brief(applied))
		if not applied.ready:
			result_summary["applicationFailure"] = _brief(applied)
			return
		constructed.append(id)
		new_ids.append_array(applied.partIds)
		expected_records[id].recipe = applied.chimneyRecipe.duplicate(true)
		expected.parts.append(applied.bearerRecord.duplicate(true))
	_check("full_candidate_known_reviewed_scope_11_constructed_5_blocked", constructed.size() == 11 and blocked.size() == 5 and constructed.size() + blocked.size() == 16)
	_check("full_candidate_exact_source_changes_only", var_to_bytes(expected) == var_to_bytes(candidate.snapshot()))
	for row in blocked:
		_check("full_candidate_blocked_record_exact:" + row.chimneyId, var_to_bytes(_find(candidate, row.chimneyId).snapshot()) == var_to_bytes(_find(original, row.chimneyId).snapshot()))
	result_summary["constructedChimneyIds"] = constructed
	result_summary["newPartIds"] = new_ids
	result_summary["unchangedBlocked"] = blocked
	# Independently rebuild real furniture on private copies, not merely compare
	# an untouched input array. The immutable reviewed furniture is the oracle.
	if not envelope.get("fixture") is Dictionary or not (envelope.fixture.get("furnitureSeed") is int or envelope.fixture.get("furnitureSeed") is float):
		_check("full_candidate_furniture_seed_present", false)
		return
	var furnishing_seed := int(envelope.fixture.furnitureSeed)
	var before_furniture = Furniture.build(_copy_source(original_snapshot), furnishing_seed)
	var after_furniture = Furniture.build(_copy_source(candidate.snapshot()), furnishing_seed)
	var furniture_exact: bool = before_furniture != null and after_furniture != null and not before_furniture.parts.is_empty() and var_to_bytes(before_furniture.snapshot()) == var_to_bytes(envelope.furnitureSnapshot) and var_to_bytes(after_furniture.snapshot()) == var_to_bytes(envelope.furnitureSnapshot)
	var reservations_exact: bool = before_furniture != null and after_furniture != null and var_to_bytes(before_furniture.protected_access_reservations) == var_to_bytes(envelope.protectedReservations) and var_to_bytes(after_furniture.protected_access_reservations) == var_to_bytes(envelope.protectedReservations)
	_check("full_candidate_regenerated_furniture_exact", furniture_exact)
	_check("full_candidate_regenerated_protected_access_exact", reservations_exact)
	result_summary["regeneratedFurnitureExact"] = furniture_exact
	result_summary["regeneratedProtectedAccessExact"] = reservations_exact
	# Fresh physical authority on each complete private source. Clear resolved
	# caches, retaining actual source geometry and required joint declarations.
	var baseline = _copy_source(original_snapshot)
	for b in [baseline, candidate]:
		for part in b.parts:
			for key in Recipe.CACHE_KEYS: part.recipe.erase(key)
		if not _full_validation_bounded(b):
			_check("full_candidate_validation_bounds", false)
			result_summary["reason"] = "full_source_validation_budget"
			return
	var before_physical: Dictionary = baseline.validate_physical_integrity()
	var after_physical: Dictionary = candidate.validate_physical_integrity()
	var added: Array = after_physical.violations.filter(func(value): return not before_physical.violations.has(value))
	var removed: Array = before_physical.violations.filter(func(value): return not after_physical.violations.has(value))
	_check("full_candidate_no_added_physical_failures", added.is_empty(), added)
	for id in constructed + new_ids:
		var checks: Array = after_physical.checks.filter(func(check): return check.partId == id)
		_check("full_candidate_constructed_chimney_or_bearer_passes:" + id, checks.size() == 1 and bool(checks[0].passed))
	result_summary["physicalBeforeFailureCount"] = before_physical.violations.size()
	result_summary["physicalAfterFailureCount"] = after_physical.violations.size()
	result_summary["addedViolations"] = added
	result_summary["removedViolations"] = removed
	result_summary["remainingChimneyViolations"] = after_physical.violations.filter(func(value): return String(value).contains("_chimney"))
	result_summary["wholePhysicalGatePassed"] = after_physical.passed
	_check("full_candidate_original_and_protected_inputs_unchanged", var_to_bytes(original_snapshot) == var_to_bytes(original.snapshot()) and protected_before == var_to_bytes([envelope.furnitureSnapshot, envelope.protectedReservations, furniture]))
	result_summary["passed"] = _checks.slice(check_start).all(func(check): return bool(check.passed))

func _copy_source(snapshot: Dictionary):
	var b := Blueprint.new(snapshot.id, snapshot.seed, snapshot.style)
	b.recipe = snapshot.recipe.duplicate(true)
	b.rooms = snapshot.rooms.duplicate(true)
	for record in snapshot.parts:
		var part = b.add_part(record)
		part.physical_intent = record.physicalIntent
		part.size = record.size
	return b

func _full_validation_bounded(b) -> bool:
	# Whole-candidate test budget, not the recipe's small closure budget. Bounds
	# are checked before either full validation; no engine-side integer overflow.
	if b.parts.size() > Recipe.MAX_SOURCE + 16: return false
	var cells := 0.0
	for part in b.parts:
		if not b.has_finite_positive_bounds(part): return false
		var bounds: AABB = b.transformed_part_bounds(part).grow(Blueprint.PHYSICAL_CONTACT_MARGIN * sqrt(3.0))
		if not Recipe._bounds_valid(bounds): return false
		var nx := floorf(bounds.end.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) - floorf(bounds.position.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) + 1.0
		var nz := floorf(bounds.end.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) - floorf(bounds.position.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) + 1.0
		if nx < 1 or nz < 1 or nx > 4096 or nz > 4096: return false
		cells += nx * nz
		if cells > 1000000: return false
	return true

func _find(b, id: String):
	for part in b.parts:
		if part.id == id: return part
	return null

func _check(label: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": label, "passed": passed, "detail": detail})

static func _brief(result: Dictionary) -> Dictionary:
	var brief: Dictionary = {}
	for key in ["ready", "reason", "partId", "partIds", "sourceClosureIds", "rootIds", "validationGridCells", "furnitureObstacleCount"]:
		if result.has(key): brief[key] = result[key]
	if result.has("physical"): brief["physical"] = result.physical
	return brief

static func _json(value: Variant) -> Variant:
	if value is Vector3: return [_json(value.x), _json(value.y), _json(value.z)]
	if value is Vector2: return [_json(value.x), _json(value.y)]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is float and not is_finite(value): return str(value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
