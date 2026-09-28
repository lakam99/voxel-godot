extends SceneTree

## Synthetic source/service contract for the unwired exterior-bay recipe.
## No frozen-source regeneration, renderer, scene, NPC or navigation calls.
## VOXEL_FACADE_BEARING_REPORT: NEW absolute JSON path, existing directory.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Builder = preload("res://scripts/buildings/FacadeBearingFrameBuilder.gd")
var _path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var started := Time.get_ticks_msec()
	_path = OS.get_environment("VOXEL_FACADE_BEARING_REPORT").strip_edges().simplify_path()
	var report := {"passed": false, "evidenceLevel": "synthetic_source_service_contract",
		"scope": "Continuous solid bottom-row bearing bays on existing grounded masonry; not opening headers or whole facades.",
		"limitations": ["Does not repair or reclassify the frozen 253 failures, including 163 upper-facade failures.",
			"Does not create roots where actual frontage lacks a grounded foundation seat.",
			"Source bounds are conservative obstruction checks, not published mesh intersections.",
			"No structural engineering capacity, renderer, physics, visual, furniture-planner, access traversal or navigation acceptance."],
		"positiveCases": [], "brokenLoadPathCases": [], "rejectedInputs": [], "foundationAuthorityCases": []}
	if not _path.is_absolute_path() or _path.get_extension().to_lower() != "json" or FileAccess.file_exists(_path) or not DirAccess.dir_exists_absolute(_path.get_base_dir()):
		_path = ""
		_finish(report, "require_new_absolute_json_report_path_in_existing_directory")
		return
	var representative: Dictionary = {}
	for outward in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		for span in [2.4, 4.2]:
			var fixture := _fixture(outward, span)
			var row := _positive(fixture)
			report.positiveCases.append(row)
			if outward == Vector3.RIGHT and span == 2.4 and row.passed:
				representative = {"snapshot": row.output, "setup": row.setup}
	if not representative.is_empty():
		var setup: Dictionary = representative.setup
		var snapshot: Dictionary = representative.snapshot
		var targets: Array = setup.foundationIds + setup.postIds + [setup.sillId]
		for id in setup.partIds:
			var part = _copy(snapshot).find_part(id)
			if part.material_id == "stone_foundation": targets.append(id)
		for id in targets:
			for mode in ["remove", "move"]:
				report.brokenLoadPathCases.append(_broken(snapshot, setup, id, mode))
		var foot_id: String = setup.partIds.filter(func(id): return String(id).contains("_foot_"))[0]
		report.brokenLoadPathCases.append(_broken(snapshot, setup, foot_id, "invalid_seat_with_incidental_ground_contact"))
		report.brokenLoadPathCases.append(_broken(snapshot, setup, foot_id, "cyclic_required_seat"))
		report.brokenLoadPathCases.append(_broken(snapshot, setup, setup.foundationIds[0], "unroot"))
		var knee_id: String = setup.partIds.filter(func(id): return String(id).contains("_knee_"))[0]
		report.brokenLoadPathCases.append(_broken(snapshot, setup, knee_id, "outside_socket"))
	for mode in ["no_foundation", "elevated_foundation", "forged_elevated_root", "paving_root", "panel_gap", "opening_access",
		"interior_room", "explicit_reservation", "furniture", "noncolliding_wear", "malformed_access", "malformed_furniture",
		"missing_reservations", "negative_size", "nonfinite_position", "zero_clearance", "oversized_span", "validation_work_limit",
		"foundation_property_visual_detail", "foundation_recipe_visual_detail", "foundation_both_visual_detail",
		"foundation_visual_property_structural_recipe", "foundation_conflicting_structural_intents"]:
		report.rejectedInputs.append(_rejected(mode))
	for intent in ["", "structural_mass", "structural_root"]:
		var fixture := _fixture(Vector3.RIGHT, 2.4)
		var root = fixture.blueprint.find_part("foundation")
		root.physical_intent = intent
		root.recipe.physicalIntent = intent
		root.recipe.physicalRoot = true # Geometrically genuine; cache must be recomputed.
		var cache_copy = Blueprint.BuildingPartScript.new(root.snapshot())
		Builder._clean_derived(cache_copy)
		var row := _positive(fixture)
		row["declaredFoundationIntent"] = intent
		row.checks["cache_clearing_preserves_both_intent_fields"] = cache_copy.physical_intent == intent and cache_copy.recipe.physicalIntent == intent and not cache_copy.recipe.has("physicalRoot")
		row.passed = row.checks.values().all(func(value): return bool(value))
		report.foundationAuthorityCases.append(row)
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report["passed"] = report.positiveCases.size() == 8 and report.positiveCases.all(func(row): return row.passed) and report.brokenLoadPathCases.size() == 16 and report.brokenLoadPathCases.all(func(row): return row.passed) and report.rejectedInputs.size() == 23 and report.rejectedInputs.all(func(row): return row.passed) and report.foundationAuthorityCases.size() == 3 and report.foundationAuthorityCases.all(func(row): return row.passed)
	_finish(report, "passed" if report.passed else "contract_failed")


func _positive(fixture: Dictionary) -> Dictionary:
	var b = fixture.blueprint
	var source: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var policy_digest := _digest(fixture.policy)
	var baseline: Dictionary = _copy(source).validate_physical_integrity()
	var result: Dictionary = Builder.add_frame(b, fixture.members, fixture.policy)
	var output: Dictionary = b.snapshot() # Capture before validator-derived caches.
	var checks := {"ready": bool(result.get("ready", false)), "input_policy_unchanged": policy_digest == _digest(fixture.policy),
		"original_object_identity_retained": _aliases(b, aliases), "baseline_members_fail": fixture.members.all(func(id): return not _passes(baseline, id)),
		"existing_geometry_materials_roof_furniture_openings_preserved": _preserved(source, output, fixture.members)}
	var row := {"passed": false, "outward": fixture.policy.outward, "span": fixture.span, "checks": checks, "setup": result, "output": output}
	if not checks.ready: return row
	var validated = _copy(output)
	var physical: Dictionary = validated.validate_physical_integrity()
	# Also validate the actual emitted objects: a snapshot roundtrip alone can
	# hide conflicting fields because BuildingPart prefers recipe intent.
	var emitted_physical: Dictionary = b.validate_physical_integrity()
	var staged_roots: Array = result.stagedPhysical.checks.filter(func(check): return bool(check.physicalRoot)).map(func(check): return check.partId)
	var emitted_roots: Array = emitted_physical.checks.filter(func(check): return bool(check.physicalRoot)).map(func(check): return check.partId)
	staged_roots.sort()
	emitted_roots.sort()
	checks["actual_emitted_source_validates_same_ground_roots"] = emitted_physical.passed and staged_roots == emitted_roots and result.foundationIds.all(func(id): return _passes(emitted_physical, id))
	checks["seven_real_added_members"] = result.partIds.size() == 7 and output.parts.size() == source.parts.size() + 7
	checks["all_members_and_frame_pass_production_validator"] = physical.passed and (fixture.members + result.partIds).all(func(id): return _passes(physical, id))
	checks["both_posts_mandatory_for_sill"] = validated.find_part(result.sillId).recipe.physicalRequiredSeatPartIds == result.postIds
	checks["only_existing_foundations_are_roots"] = validated.parts.filter(func(part): return bool(part.recipe.get("physicalRoot", false))).map(func(part): return part.id) == result.foundationIds
	var seat_count := 0
	var socket_count := 0
	var joints_ok := true
	for id in fixture.members + result.partIds:
		var part = validated.find_part(id)
		for fact in part.recipe.get("physicalRequiredSeatFacts", []):
			seat_count += 1
			joints_ok = joints_ok and fact.get("loadDirection") == "world_down" and validated.has_rooted_bearer_seat(part, fact)
		for fact in part.recipe.get("physicalRequiredAnchorFacts", []):
			socket_count += 1
			joints_ok = joints_ok and _child_socket_contains(part, fact) and validated.has_rooted_attachment_socket(part, fact)
	checks["eight_finite_gravity_patches_four_contained_sockets"] = joints_ok and seat_count == 8 and socket_count == 4
	row["physical"] = physical
	row["emittedPhysical"] = emitted_physical
	row["passed"] = checks.values().all(func(value): return bool(value))
	return row


func _broken(snapshot: Dictionary, setup: Dictionary, target: String, mode: String) -> Dictionary:
	var b = _copy(snapshot)
	var part = b.find_part(target)
	if part == null: return {"passed": false, "target": target, "mode": mode, "reason": "missing_control_target"}
	match mode:
		"remove": b.parts.erase(part)
		"move": part.position.x += 2.0
		"unroot": part.position.y += 0.30
		"invalid_seat_with_incidental_ground_contact":
			part.recipe.physicalRequiredSeatFacts[0].localPatchCenter.x += 1.0
		"cyclic_required_seat":
			part.recipe.physicalRequiredSeatPartIds = [setup.postIds[0]]
			part.recipe.physicalRequiredSeatFacts[0].seatId = setup.postIds[0]
		"outside_socket":
			part.recipe.physicalRequiredAnchorFacts[0].localMountCenter.x = part.size.x
	# Recompute only on this private copy, removing derived root shortcuts first.
	_clear_derived(b)
	var physical: Dictionary = b.validate_physical_integrity()
	var failed: Array = physical.checks.filter(func(check): return not check.passed).map(func(check): return check.partId)
	var passed: bool = not physical.passed and setup.memberIds.all(func(id): return not _passes(physical, id))
	if mode == "outside_socket":
		passed = not _child_socket_contains(part, part.recipe.physicalRequiredAnchorFacts[0]) and not _passes(physical, target)
	return {"passed": passed, "target": target, "mode": mode, "failedPartIds": failed, "violations": physical.violations}


func _rejected(mode: String) -> Dictionary:
	var fixture := _fixture(Vector3.RIGHT, 6.0 if mode == "oversized_span" else 2.4)
	var b = fixture.blueprint
	var policy: Dictionary = fixture.policy
	var root = b.find_part("foundation")
	var panel = b.find_part(fixture.members[1])
	var blocked := AABB(Vector3(-0.15, 0.60, -1.15), Vector3(0.40, 1.20, 0.30))
	match mode:
		"no_foundation": policy.foundationPartIds = []
		"elevated_foundation": root.position.y += 0.25
		"forged_elevated_root":
			root.position.y += 0.25
			root.recipe.physicalRoot = true
			root.physical_intent = "structural_root"
		"paving_root": root.material_id = "cobblestone"
		"panel_gap": panel.position.z += 0.20
		"opening_access": b.rooms[0].accesses = [{"position": blocked.get_center(), "size": blocked.size}]
		"interior_room": b.rooms[0].bounds = blocked
		"explicit_reservation": policy.reservedVolumes = [blocked]
		"furniture": policy.furnitureParts.append({"id": "reserved_bench", "position": blocked.get_center(), "size": blocked.size, "collision": false})
		"noncolliding_wear": b.add_part({"id": "wear_obstacle", "kind": "detail", "position": blocked.get_center(), "size": blocked.size, "collision": false, "semantic": "ground_wear", "physicalIntent": "visual_detail"})
		"malformed_access": b.rooms[0].accesses = [{}]
		"malformed_furniture": policy.furnitureParts.append({"position": Vector3.ZERO, "size": Vector3(-1, 1, 1)})
		"missing_reservations": policy.erase("reservedVolumes")
		"negative_size": panel.size.x = -0.3
		"nonfinite_position": panel.position.x = NAN
		"zero_clearance": policy.clearance = 0.0
		"validation_work_limit": root.size = Vector3(1000, 0.4, 1000)
		"foundation_property_visual_detail": root.physical_intent = "visual_detail"
		"foundation_recipe_visual_detail": root.recipe.physicalIntent = "visual_detail"
		"foundation_both_visual_detail":
			root.physical_intent = "visual_detail"
			root.recipe.physicalIntent = "visual_detail"
		"foundation_visual_property_structural_recipe":
			root.physical_intent = "visual_detail"
			root.recipe.physicalIntent = "structural_mass"
		"foundation_conflicting_structural_intents": root.recipe.physicalIntent = "structural_root"
	var before: Dictionary = b.snapshot()
	var policy_before := _digest(policy)
	var aliases: Array = b.parts.duplicate()
	var result: Dictionary = Builder.add_frame(b, fixture.members, policy)
	var expected_reason := "staged_validation_work_limit_exceeded" if mode == "validation_work_limit" else ""
	if mode.begins_with("foundation_"):
		expected_reason = "conflicting_foundation_intents" if mode == "foundation_conflicting_structural_intents" else "incompatible_foundation_intent"
	return {"passed": not bool(result.get("ready", false)) and (expected_reason.is_empty() or result.get("reason") == expected_reason) and _digest(before) == _digest(b.snapshot()) and policy_before == _digest(policy) and _aliases(b, aliases),
		"mode": mode, "result": result}


func _fixture(outward: Vector3, span: float) -> Dictionary:
	var b = Blueprint.new("synthetic_exterior_bay", 19, "timber")
	b.recipe = {"fixture": "synthetic", "untouchedRecipe": [1, 2, 3]}
	b.add_part(_record("foundation", "foundation", "stone_foundation", Vector3(0, 0.2, 0), Vector3(1.4, 0.4, span + 1), outward, true))
	var members: Array = []
	for index in range(2):
		var id := "panel_%d" % index
		members.append(id)
		var panel = b.add_part(_record(id, "wall", "painted_brick_cream", Vector3(0, 2.7, (index - 0.5) * span * 0.5), Vector3(0.3, 0.6, span * 0.5), outward, true))
		panel.recipe["unchangedFacadeVariation"] = {"openingOwner": "synthetic", "palette": 3}
	b.add_part(_record("roof_unchanged", "roof", "timber_beam", Vector3(-1, 3.8, 0), Vector3(3, 0.2, span + 1), outward, false))
	b.add_part(_record("bench_unchanged", "furniture", "timber_beam", Vector3(-1.3, 0.8, 0), Vector3(0.6, 0.6, 1.0), outward, false))
	var interior := _volume(Vector3(-2.2, 1.8, 0), Vector3(4, 3, span + 1), outward)
	var access := _volume(Vector3(0, 1.6, span * 0.5 + 0.7), Vector3(2, 2.5, 0.8), outward)
	b.set_room_records([{"id": "room", "role": "home", "bounds": interior, "accesses": [{"position": access.get_center(), "size": access.size}]},
		{"id": "courtyard", "role": "courtyard", "bounds": AABB(Vector3(-10, 0, -10), Vector3(20, 6, 20)), "accesses": []}])
	_index(b)
	return {"blueprint": b, "members": members, "span": span,
		"policy": {"outward": outward, "foundationPartIds": ["foundation"], "reservedVolumes": [],
			"furnitureParts": [b.find_part("bench_unchanged").snapshot()], "clearance": 0.01}}


func _record(id: String, kind: String, material: String, center: Vector3, size: Vector3, outward: Vector3, collision: bool) -> Dictionary:
	var volume := _volume(center, size, outward)
	return {"id": id, "kind": kind, "material": material, "position": volume.get_center(), "size": volume.size,
		"collision": collision, "physicalIntent": "structural_mass" if collision else "visual_detail"}


func _volume(center: Vector3, size: Vector3, outward: Vector3) -> AABB:
	var span_direction := Vector3.BACK if outward.x != 0 else Vector3.RIGHT
	var world_center := outward * center.x + Vector3.UP * center.y + span_direction * center.z
	var world_size := outward.abs() * size.x + Vector3.UP * size.y + span_direction * size.z
	return AABB(world_center - world_size * 0.5, world_size)


func _copy(snapshot: Dictionary):
	var b = Blueprint.new(snapshot.id, snapshot.seed, snapshot.style)
	b.set_recipe(snapshot.recipe)
	b.set_room_records(snapshot.rooms)
	for record in snapshot.parts: b.add_part(record)
	_index(b) # add_part deliberately does not populate find_part's index.
	return b


func _index(b) -> void:
	b.physical_parts_by_id.clear()
	for part in b.parts: b.physical_parts_by_id[part.id] = part


func _clear_derived(b) -> void:
	for part in b.parts:
		for key in ["physicalRoot", "physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]:
			part.recipe.erase(key)


func _preserved(before: Dictionary, after: Dictionary, members: Array) -> bool:
	var a := before.duplicate(true)
	var c := after.duplicate(true)
	a.erase("parts")
	c.erase("parts")
	if _digest(a) != _digest(c) or after.parts.size() < before.parts.size(): return false
	for index in range(before.parts.size()):
		var original: Dictionary = before.parts[index].duplicate(true)
		var current: Dictionary = after.parts[index].duplicate(true)
		if members.has(original.id):
			for record in [original, current]:
				record.erase("physicalIntent")
				for key in record.recipe.keys():
					if String(key).begins_with("physical"): record.recipe.erase(key)
		if _digest(original) != _digest(current): return false
	return true


func _aliases(b, originals: Array) -> bool:
	if b.parts.size() < originals.size(): return false
	for index in range(originals.size()):
		if not is_same(b.parts[index], originals[index]): return false
	return true


func _passes(report: Dictionary, id: String) -> bool:
	var matches: Array = report.checks.filter(func(check): return check.partId == id)
	return matches.size() == 1 and bool(matches[0].passed)


func _child_socket_contains(part, fact: Dictionary) -> bool:
	for x in [-1, 1]:
		for y in [-1, 1]:
			for z in [-1, 1]:
				var corner: Vector3 = fact.localMountCenter + fact.localMountHalfExtents * Vector3(x, y, z)
				for axis in range(3):
					if absf(corner[axis]) > part.size[axis] * 0.5: return false
	return true


func _digest(value: Variant) -> String:
	return var_to_bytes(value).hex_encode().sha256_text()


func _finish(report: Dictionary, reason: String) -> void:
	report["reason"] = reason
	if not _path.is_empty():
		var file := FileAccess.open(_path, FileAccess.WRITE)
		if file == null:
			report.passed = false
			report.reason = "report_open_failed"
		else:
			file.store_string(JSON.stringify(report, "\t"))
			file.flush()
			if file.get_error() != OK: report.passed = false
			file.close()
	print("Facade bearing source contract: ", report.reason)
	quit(0 if report.passed else 2)
