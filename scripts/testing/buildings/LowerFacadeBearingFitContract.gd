extends "res://scripts/testing/buildings/LowerFacadeBearingRecipeContract.gd"

## Synthetic shortened-sill contracts only; inherited SceneTree/fixture/probe.
## No source archive, production scene, publication, navigation or engine spawn.
## Fresh absolute .json output: VOXEL_LOWER_FACADE_FIT_REPORT.
## Expected RED until the recipe implements bounded, admitted body shortening.

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_LOWER_FACADE_FIT_REPORT")
	if not _fit_fresh_path(path):
		quit(2)
		return
	var baseline_fixture: Dictionary = _fixture()
	var baseline: Dictionary = _probe("synthetic_full_clear", baseline_fixture)
	_checks["synthetic_full_clear_ready"] = baseline.get("ready", false)
	if baseline.get("ready", false):
		_fit_geometry("synthetic_full_clear", baseline_fixture, baseline, baseline, false)
		for mode: String in ["right_furniture", "left_furniture", "two_ends", "foreign_end", "tiny_overlap"]:
			var fixture: Dictionary = _fit_fixture(mode)
			var label: String = "synthetic_fit_" + mode
			_fit_blocked_precondition(label, fixture, baseline)
			var result: Dictionary = _probe(label, fixture)
			_checks[label + "_ready"] = result.get("ready", false)
			if result.get("ready", false): _fit_geometry(label, fixture, result, baseline, true)
			if mode == "two_ends":
				# One shortened assembly gets the inherited destructive-copy
				# controls: removing either corbel or its independent masonry
				# seat must invalidate the body and unchanged panel obligations.
				if result.get("ready", false): _removal_controls(result)
				var reversed: Dictionary = fixture.duplicate(true)
				reversed.policy.furnitureParts.reverse()
				reversed.policy.reservedVolumes.reverse()
				var reverse_result: Dictionary = _probe("synthetic_fit_reversed_protected_order", reversed)
				_checks["synthetic_fit_reversed_protected_order_ready"] = reverse_result.get("ready", false)
				_checks["synthetic_fit_reversed_protected_order_exact_additions"] = result.get("ready", false) and reverse_result.get("ready", false) and var_to_bytes(result.get("additions")) == var_to_bytes(reverse_result.get("additions"))
				if reverse_result.get("ready", false): _fit_geometry("synthetic_fit_reversed_protected_order", reversed, reverse_result, baseline, true)
			if mode == "tiny_overlap":
				var full: Array = Recipe.Connection._bounds(Part.new(baseline.additions[0]))
				var blocker: AABB = fixture.policy.reservedVolumes[0]
				var intrusion: float = full[5] - float(blocker.position.z)
				_checks["synthetic_tiny_overlap_is_positive_not_contact"] = intrusion > 0.0 and intrusion < 0.000001
				if result.get("ready", false):
					var fitted: Array = Recipe.Connection._bounds(Part.new(result.additions[0]))
					_checks["synthetic_tiny_overlap_represented_end_really_clear"] = fitted[5] <= float(blocker.position.z) and fitted[5] < full[5]
		for mode: String in ["center_blocked", "narrow_strip"]:
			var fixture: Dictionary = _fit_fixture(mode)
			var label: String = "synthetic_fit_" + mode
			_fit_blocked_precondition(label, fixture, baseline)
			if mode == "narrow_strip":
				var left: AABB = Recipe.Copy.Frame.furnishing_bounds(fixture.policy.furnitureParts[0]).bounds
				var right: AABB = Recipe.Copy.Frame.furnishing_bounds(fixture.policy.furnitureParts[1]).bounds
				var half_patch: float = minf(0.06, fixture.snapshot.parts[2].size.z * 0.5 - 0.06)
				_checks["synthetic_narrow_strip_contains_entire_central_patch"] = float(left.end.z) < -half_patch and float(right.position.z) > half_patch
				_checks["synthetic_narrow_strip_cannot_hold_two_finite_corbels"] = float(right.position.z) - float(left.end.z) < 4.0 * float(Recipe.HALF.z)
			var rejected: Dictionary = _probe(label, fixture)
			_checks[label + "_rejects_without_candidate"] = rejected.get("ready") == false and not rejected.has("afterSnapshot") and not rejected.has("additions") and rejected.get("reason") is String and not rejected.reason.is_empty()
		var distant: Dictionary = _fixture()
		distant.policy.furnitureParts.append(_fit_furniture("synthetic_distant", 4.0, 4.6))
		var full_again: Dictionary = _probe("synthetic_full_path_preserved", distant)
		_checks["synthetic_full_path_preserves_successful_output"] = full_again.get("ready", false) and not full_again.has("bodyFit") and var_to_bytes(full_again.get("additions")) == var_to_bytes(baseline.additions) and var_to_bytes(full_again.get("panel")) == var_to_bytes(baseline.panel) and var_to_bytes(full_again.get("afterSnapshot")) == var_to_bytes(baseline.afterSnapshot)
	_fit_finish(path)

func _fit_fixture(mode: String) -> Dictionary:
	var fixture: Dictionary = _fixture()
	match mode:
		"right_furniture": fixture.policy.furnitureParts.append(_fit_furniture("synthetic_right", 0.6, 1.2))
		"left_furniture": fixture.policy.furnitureParts.append(_fit_furniture("synthetic_left", -1.2, -0.6))
		"two_ends":
			fixture.policy.furnitureParts.append(_fit_furniture("synthetic_right", 0.6, 1.2))
			fixture.policy.furnitureParts.append(_fit_furniture("synthetic_left", -1.2, -0.6))
			fixture.policy.reservedVolumes.append(AABB(Vector3(10, 0, 10), Vector3.ONE))
			fixture.policy.reservedVolumes.append(AABB(Vector3(12, 0, 12), Vector3.ONE))
		"foreign_end": fixture.snapshot.parts.append(_record("synthetic_foreign_end", "wall", Vector3(0, 2.35, 0.9), Vector3(0.5, 0.25, 0.6)))
		"tiny_overlap":
			# Exact float32 predecessor of 1.0, independent of recipe rounding.
			var encoded := PackedByteArray()
			encoded.resize(4)
			encoded.encode_float(0, 1.0)
			encoded.encode_u32(0, encoded.decode_u32(0) - 1)
			fixture.policy.reservedVolumes.append(AABB(Vector3(-0.25, 2.2, encoded.decode_float(0)), Vector3(0.5, 0.29, 0.2)))
		"center_blocked": fixture.policy.furnitureParts.append(_fit_furniture("synthetic_center", -0.12, 0.12))
		"narrow_strip":
			fixture.policy.furnitureParts.append(_fit_furniture("synthetic_narrow_left", -1.2, -0.1))
			fixture.policy.furnitureParts.append(_fit_furniture("synthetic_narrow_right", 0.1, 1.2))
	return fixture

func _fit_furniture(id: String, low_z: float, high_z: float) -> Dictionary:
	# Furniture position is the FLOOR origin. Its top is below panel bottom
	# 2.5, while its volume overlaps the original sill (bottom about 2.26).
	return {"id": id, "position": Vector3(0, 2.2, (low_z + high_z) * 0.5),
		"size": Vector3(0.5, 0.29, high_z - low_z), "rotation": Vector3.ZERO,
		"recipe": {"syntheticKeepContents": ["unchanged"]}}

func _fit_blocked_precondition(label: String, fixture: Dictionary, baseline: Dictionary) -> void:
	var frozen: PackedByteArray = var_to_bytes(fixture)
	var input: Dictionary = Recipe._read(fixture.snapshot, fixture.panelId, fixture.policy)
	_checks[label + "_valid_input_schema"] = input.get("ready", false)
	if input.get("ready", false):
		var admission: Dictionary = Recipe._admit(Part.new(baseline.additions[0]), input.obstacles, input.volumes)
		_checks[label + "_full_body_actually_blocked"] = admission.get("ready") == false and admission.get("reason") in ["protected_volume_blocked", "foreign_solid_blocked"]
		_results[label + "_original_full_body_admission"] = admission
	_checks[label + "_precondition_input_immutable"] = var_to_bytes(fixture) == frozen

func _fit_geometry(label: String, fixture: Dictionary, result: Dictionary, baseline: Dictionary, shortened: bool) -> void:
	var panel = Part.new(fixture.snapshot.parts[2])
	var full = Part.new(baseline.additions[0])
	var additions: Array = result.get("additions", [])
	_checks[label + "_three_pieces"] = additions.size() == 3
	if additions.size() != 3: return
	var body = Part.new(additions[0])
	var bb: Array = Recipe.Connection._bounds(body)
	var fb: Array = Recipe.Connection._bounds(full)
	var pb: Array = Recipe.Connection._bounds(panel)
	_checks[label + "_only_new_body_z_may_change"] = body.position.x == full.position.x and body.position.y == full.position.y and body.size.x == full.size.x and body.size.y == full.size.y and body.rotation == full.rotation and body.material_id == full.material_id and body.collision_enabled and body.id == full.id
	_checks[label + "_contiguous_inward_body_exact_top"] = bb[2] >= fb[2] and bb[5] <= fb[5] and bb[2] < bb[5] and bb[4] == pb[1] and (body.size.z < full.size.z if shortened else body.size.z == full.size.z)
	_checks[label + "_panel_geometry_unchanged"] = var_to_bytes(Recipe.Aperture._geometry(Part.new(result.panel))) == var_to_bytes(Recipe.Aperture._geometry(panel))
	var facts: Array = result.panel.recipe.get("physicalRequiredSeatFacts", [])
	var expected_fact: Dictionary = {"seatId": body.id, "loadDirection": "world_down", "seatFace": "max_y",
		"localPatchCenter": Vector3(0, -panel.size.y * 0.5, 0),
		"localPatchHalfExtents": Vector2(minf(0.06, panel.size.x * 0.5 - 0.06), minf(0.06, panel.size.z * 0.5 - 0.06))}
	_checks[label + "_original_patch_not_moved_or_shrunk"] = facts.size() == 1 and var_to_bytes(facts[0]) == var_to_bytes(expected_fact)
	var patch: Vector2 = expected_fact.localPatchHalfExtents
	_checks[label + "_entire_original_patch_supported"] = bb[0] <= float(panel.position.x) - float(patch.x) and bb[3] >= float(panel.position.x) + float(patch.x) and bb[2] <= float(panel.position.z) - float(patch.y) and bb[5] >= float(panel.position.z) + float(patch.y)
	var root: Dictionary = result.get("independentSeatCheck", {})
	_checks[label + "_two_finite_independently_rooted_corbels"] = result.get("joints", []).size() == 2 and _finite_sockets(result) and root.get("partId") == "synthetic_stone" and root.get("passed", false) and root.get("reachesGroundRoot", false) and additions[1].id != additions[2].id and result.joints.all(func(j): return j.seatId == "synthetic_stone")
	_checks[label + "_four_physical_checks_and_bounded_work"] = result.get("checks", []).size() == 4 and result.checks.all(func(c): return c.get("passed", false)) and result.get("proofGridWork", {}).get("ready", false) and int(result.get("work", {}).get("satPairs", -1)) >= 0 and int(result.work.satPairs) <= Recipe.Connection.MAX_SAT_WORK
	# Normal admission for ALL three parts: the only solid exemption is the
	# declared masonry socket seat for each corbel, whose finite overlap is
	# checked above. No exemptions for furniture or foreign end blockers.
	var input: Dictionary = Recipe._read(fixture.snapshot, fixture.panelId, fixture.policy)
	var admitted: bool = input.get("ready", false)
	var exact_clear := true
	if admitted:
		for index in range(3):
			var piece = Part.new(additions[index])
			var obstacles: Array = input.obstacles if index == 0 else input.obstacles.filter(func(o): return o.id != "synthetic_stone")
			admitted = admitted and Recipe._admit(piece, obstacles, input.volumes).get("ready", false)
			# Strict double arithmetic over actual float32 center/size; no epsilon.
			exact_clear = exact_clear and piece.rotation == Vector3.ZERO
			var bounds: Array = Recipe.Connection._bounds(piece)
			for volume: Dictionary in input.volumes:
				var box: AABB = volume.bounds
				var separated: bool = bounds[3] <= float(box.position.x) or float(box.end.x) <= bounds[0] or bounds[4] <= float(box.position.y) or float(box.end.y) <= bounds[1] or bounds[5] <= float(box.position.z) or float(box.end.z) <= bounds[2]
				exact_clear = exact_clear and separated
	_checks[label + "_normal_admission_all_three"] = admitted
	_checks[label + "_no_positive_protected_overlap_waived"] = exact_clear
	var after: Dictionary = result.get("afterSnapshot", {})
	_checks[label + "_rooms_and_aperture_declarations_exact"] = var_to_bytes(after.get("rooms")) == var_to_bytes(fixture.snapshot.rooms) and var_to_bytes(after.get("recipe")) == var_to_bytes(fixture.snapshot.recipe)
	var by_id: Dictionary = {}
	for record: Dictionary in after.get("parts", []): by_id[record.id] = record
	var preserved: bool = by_id.size() == fixture.snapshot.parts.size() + 3 and after.get("parts", []).size() == by_id.size()
	for record: Dictionary in fixture.snapshot.parts:
		var expected: Dictionary = result.panel if record.id == panel.id else record
		preserved = preserved and var_to_bytes(by_id.get(record.id)) == var_to_bytes(expected)
	for record: Dictionary in additions: preserved = preserved and var_to_bytes(by_id.get(record.id)) == var_to_bytes(record)
	_checks[label + "_only_declared_additions_no_blockers_moved_or_shrunk"] = preserved
	var part_objects: Dictionary = {}
	for id: String in by_id: part_objects[id] = Part.new(by_id[id])
	_checks[label + "_original_aperture_binding_valid"] = after.get("recipe", {}).get("facadeApertures", {}).size() == 1 and Recipe.Aperture.validate(after.recipe.facadeApertures.synthetic_upper, part_objects)

func _fit_fresh_path(path: String) -> bool:
	return path.is_absolute_path() and path.get_extension() == "json" and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path) and DirAccess.dir_exists_absolute(path.get_base_dir())

func _fit_finish(path: String) -> void:
	var passed: bool = not _checks.is_empty() and _checks.values().all(func(value): return value == true)
	var report: Dictionary = {"passed": passed, "checks": _checks, "results": _results,
		"evidenceLevel": "synthetic_lower_facade_shortened_sill_contract_only",
		"limitations": "Synthetic represented geometry and source-contract checks only. No real source candidate, published visuals/collision, gate-zero, gameplay, NPC/navigation, performance or engineering-capacity acceptance. Expected rejections are named controls, not accepted fits."}
	var bytes: PackedByteArray = JSON.stringify(report, "\t").to_utf8_buffer()
	if not _fit_fresh_path(path):
		quit(2)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_position() == bytes.size()
	file.close()
	var hash := HashingContext.new()
	written = written and hash.start(HashingContext.HASH_SHA256) == OK
	if written:
		written = hash.update(bytes) == OK
		if written: written = FileAccess.get_sha256(path) == hash.finish().hex_encode()
	quit(0 if passed and written else 1)
