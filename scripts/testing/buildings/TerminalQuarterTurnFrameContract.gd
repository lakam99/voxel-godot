extends SceneTree

## Actual terminal producer, synthetic asymmetric WORLD support, source only.
## No frozen placement, renderer, customer access, or engine launch by author.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Frame = preload("res://scripts/buildings/TerminalShopFrameBuilder.gd")
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const MEMBERS := ["_lintel", "_sign_arm", "_jamb_-1", "_jamb_1", "_bracket_-1", "_bracket_1"]
const PIVOT := Vector3(2.0, 4.22, -1.0)
const GEOMETRY_EPS := 0.00003
const BASIS_EPS := 0.00001


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_TERMINAL_QUARTER_FRAME_REPORT")
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var reference := _fixture(0)
	var reference_results := _build_all(reference)
	var positives: Array = []
	var controls: Array = []
	if reference_results.all(func(result): return result.ready):
		for quarter in range(4):
			positives.append(_positive(quarter, reference))
			for mode in ["missing_support", "moved_support", "missing_root", "moved_root", "mixed_post", "mixed_sign", "mixed_brace", "nonquarter", "tilted", "nonfinite", "late_socket_failure"]:
				controls.append(_negative(quarter, mode))
	var direct := _direct_contract()
	var report := {"evidenceLevel": "source_contract_actual_producer_synthetic_world_foundations",
		"referenceResults": reference_results, "quarterCases": positives, "negativeCases": controls,
		"directGroundContract": direct, "elapsedMsec": Time.get_ticks_msec() - started,
		"passed": positives.size() == 4 and controls.size() == 44 and positives.all(func(row): return row.passed) and controls.all(func(row): return row.passed) and direct.passed,
		"expectationMethod": "Zero-turn public assembly rigidly transformed by independent coordinate permutation, all corners and joint volumes checked. Foundations never transformed. No copied frame grammar or builder orientation helper in expected geometry.",
		"numericPolicy": {"geometryTolerance": GEOMETRY_EPS, "basisTolerance": BASIS_EPS, "unmodifiedRecords": "exact snapshot bytes"},
		"limitations": "World-space structural source validation only. Caller must transform complete row before per-bay calls and separately prove real support selection, all furniture/cloth clearance and public approach. No headed or navigation acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if written and report.passed else 2)


func _fixture(quarter: int, direct := false) -> Dictionary:
	var b = Blueprint.new("quarter_turn_terminal_source_contract", 418, "stone")
	# Asymmetric, off-origin parents deliberately do NOT follow the row rotation.
	var root_height := 4.22 if direct else 0.62
	b.add_part({"id": "world_root", "kind": "foundation", "material": "stone_foundation",
		"position": Vector3(3, root_height * 0.5, -2), "size": Vector3(42, root_height, 38),
		"collision": true, "recipe": {"physicalIntent": "structural_mass", "authority": "synthetic_actual_world_root"}})
	# Trap constructor precedence: clearing caches must not overwrite this field.
	b.parts[0].physical_intent = ""
	var parents: Array = ["world_root"]
	if not direct:
		b.add_part({"id": "world_terrace", "kind": "foundation", "material": "stone_foundation",
			"position": Vector3(1, 2.42, -1), "size": Vector3(34, 3.6, 30), "collision": true,
			"recipe": {"physicalIntent": "structural_mass", "authority": "synthetic_actual_world_terrace",
				"physicalRequiredSeatPartIds": ["world_root"],
				"physicalRequiredSeatFacts": [Seats.world_down_seat_fact("world_root", Vector3(0, -1.8, 0), Vector2(0.2, 0.3))]}})
		parents.append("world_terrace")
	var start: int = b.parts.size()
	Urban.add_terminal_shop_row(b, PIVOT, 0.05)
	var ids: Array = []
	var prefixes: Array = []
	var rigid := _rigid(quarter)
	for part in b.parts.slice(start):
		ids.append(part.id)
		if part.semantic == "citadel_terminal_shop_frame" and String(part.id).ends_with("_lintel"):
			prefixes.append(String(part.id).trim_suffix("_lintel"))
		# ALL actual producer parts, including cloth/goods/wear, before assembly.
		if quarter != 0:
			var transformed: Transform3D = rigid * b.part_transform(part)
			part.position = transformed.origin
			part.rotation = transformed.basis.get_euler()
	for part in b.parts:
		b.physical_parts_by_id[part.id] = part
	prefixes.sort()
	return {"b": b, "memberIds": ids, "prefixes": prefixes, "parentIds": parents,
		"supportId": parents.back(), "upstreamIds": parents.slice(0, parents.size() - 1)}


func _build_all(fixture: Dictionary) -> Array:
	var results: Array = []
	for prefix in fixture.prefixes:
		results.append(Frame.add_frame_on_support(fixture.b, prefix, fixture.supportId, fixture.upstreamIds))
	return results


func _positive(quarter: int, reference: Dictionary) -> Dictionary:
	var fixture := _fixture(quarter)
	var b = fixture.b
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var recipe_digests: Array = recipes.map(func(recipe): return _digest(recipe))
	var results := _build_all(fixture)
	var checks := {"all_bays_ready": results.size() == 3 and results.all(func(result): return result.ready),
		"complete_producer_members_retained": fixture.memberIds.all(func(id): return _find(b, id) != null),
		"original_objects_retained": range(aliases.size()).all(func(i): return is_same(b.parts[i], aliases[i])),
		"old_recipe_aliases_untouched": range(recipes.size()).all(func(i): return _digest(recipes[i]) == recipe_digests[i])}
	var differences: Array = []
	var joint_differences: Array = []
	var dependency_breaks: Array = []
	if checks.all_bays_ready:
		checks["staged_exact_closure_plus_11"] = results.all(func(result): return result.expectedPartCount == fixture.parentIds.size() + 11 and result.stagedPhysical.checks.size() == result.expectedPartCount and result.stagedPhysical.checks.all(func(check): return check.passed))
		checks["world_closure_valid_before_assembly"] = results.all(func(result): return result.sourceClosurePhysicalBefore.checks.size() == fixture.parentIds.size() and result.sourceClosurePhysicalBefore.checks.all(func(check): return check.passed))
		var changed: Array = []
		for prefix in fixture.prefixes:
			for suffix in MEMBERS: changed.append(prefix + suffix)
		checks["all_nonframe_source_exact"] = _unchanged(before, b.snapshot(), changed)
		checks["parent_record_and_alias_authority_exact"] = fixture.parentIds.all(func(id): return _digest(_record(before, id)) == _digest(_find(b, id).snapshot()) and is_same(_find(b, id).recipe, recipes[aliases.find(_find(b, id))]))
		var rigid := _rigid(quarter)
		for expected in reference.b.parts:
			var actual = _find(b, expected.id)
			if actual == null:
				differences.append({"id": expected.id, "reason": "missing"})
				continue
			if fixture.parentIds.has(expected.id):
				if _digest(actual.snapshot()) != _digest(expected.snapshot()):
					differences.append({"id": expected.id, "reason": "parent_world_pose_or_record_changed"})
				continue
			var expected_transform: Transform3D = rigid * reference.b.part_transform(expected)
			var actual_transform: Transform3D = b.part_transform(actual)
			var geometry_ok: bool = actual.size.distance_to(expected.size) <= GEOMETRY_EPS and actual.position.distance_to(expected_transform.origin) <= GEOMETRY_EPS and _basis_close(actual_transform.basis, expected_transform.basis)
			for corner in _corners(expected.size):
				geometry_ok = geometry_ok and (actual_transform * corner).distance_to(expected_transform * corner) <= GEOMETRY_EPS
			var fields_ok: bool = actual.kind == expected.kind and actual.material_id == expected.material_id and actual.semantic == expected.semantic and actual.collision_enabled == expected.collision_enabled and actual.physical_intent == expected.physical_intent
			if not geometry_ok or not fields_ok or not _near(actual.recipe, expected.recipe):
				differences.append({"id": actual.id, "geometry": geometry_ok, "fields": fields_ok, "recipe": _near(actual.recipe, expected.recipe)})
			# Check local facts AND world volume corners; quarter-turning a local
			# socket a second time would violate this even if part centers match.
			for key in ["physicalRequiredSeatFacts", "physicalRequiredAnchorFacts"]:
				var expected_facts: Array = expected.recipe.get(key, [])
				var actual_facts: Array = actual.recipe.get(key, [])
				if expected_facts.size() != actual_facts.size():
					joint_differences.append({"id": actual.id, "key": key, "reason": "fact_count"})
					continue
				for i in range(expected_facts.size()):
					if not _joint_geometry(actual_transform, actual_facts[i], expected_transform, expected_facts[i]):
						joint_differences.append({"id": actual.id, "key": key, "fact": i})
		checks["all_geometry_rigid_equivariant_and_fields_preserved"] = differences.is_empty() and b.parts.size() == reference.b.parts.size()
		checks["local_joint_axes_and_world_socket_volumes_equivariant"] = joint_differences.is_empty()
		for i in range(fixture.prefixes.size()):
			dependency_breaks.append_array(_dependency_breaks(fixture, fixture.prefixes[i], results[i].partIds))
		checks["real_world_parents_required_after_commit"] = dependency_breaks.all(func(row): return row.passed)
	return {"quarterTurn": quarter, "checks": checks, "geometryDifferences": differences,
		"jointDifferences": joint_differences, "dependencyBreaks": dependency_breaks,
		"assemblyResults": results, "passed": checks.values().all(func(value): return value)}


func _negative(quarter: int, mode: String) -> Dictionary:
	var fixture := _fixture(quarter)
	var b = fixture.b
	var prefix: String = fixture.prefixes[0]
	var different := _rigid((quarter + 1) % 4).basis
	match mode:
		"missing_support": b.parts.erase(_find(b, fixture.supportId))
		"moved_support": _find(b, fixture.supportId).position.x += 100.0
		"missing_root": b.parts.erase(_find(b, "world_root"))
		"moved_root": _find(b, "world_root").position.x += 100.0
		"mixed_post": _find(b, prefix + "_jamb_1").rotation = different.get_euler()
		"mixed_sign": _find(b, prefix + "_sign_arm").rotation = different.get_euler()
		"mixed_brace":
			var brace = _find(b, prefix + "_bracket_1")
			brace.rotation = (Basis(Vector3.UP, PI * 0.5) * b.part_transform(brace).basis).get_euler()
		"nonquarter": _find(b, prefix + "_lintel").rotation = Vector3(0.0, float(quarter) * PI * 0.5 + 0.12, 0.0)
		"tilted": _find(b, prefix + "_lintel").rotation.x += 0.1
		"nonfinite": _find(b, prefix + "_jamb_1").rotation.y = NAN
		"late_socket_failure": _find(b, prefix + "_sign_arm").size.y = 0.02
	var before := _digest(b.snapshot())
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var recipe_digests: Array = recipes.map(func(recipe): return _digest(recipe))
	var result: Dictionary = Frame.add_frame_on_support(b, prefix, fixture.supportId, fixture.upstreamIds)
	var late_reached: bool = mode != "late_socket_failure" or result.get("reason") in ["staged_frame_has_invalid_load_path", "staged_socket_outside_attachment", "staged_anchor_invalid"]
	return {"quarterTurn": quarter, "mode": mode, "result": result,
		"passed": not result.ready and late_reached and _digest(b.snapshot()) == before and range(aliases.size()).all(func(i): return is_same(b.parts[i], aliases[i]) and is_same(b.parts[i].recipe, recipes[i]) and _digest(recipes[i]) == recipe_digests[i])}


func _dependency_breaks(fixture: Dictionary, prefix: String, additions: Array) -> Array:
	# Additions come from the public assembly result, not another grammar.
	var ids: Array = MEMBERS.map(func(suffix): return prefix + suffix) + additions
	var rows: Array = []
	for parent in fixture.parentIds:
		for mode in ["remove", "move"]:
			var b = Blueprint.new("quarter_dependency_break", 418, "stone")
			for id in fixture.parentIds + ids:
				if mode == "remove" and id == parent: continue
				var original = _find(fixture.b, id)
				var part = b.add_part(original.snapshot())
				part.physical_intent = original.physical_intent
				if mode == "move" and id == parent: part.position.x += 100.0
				Frame._clean_caches(part)
			var work: Dictionary = Frame._validation_work(b)
			var physical: Dictionary = b.validate_physical_integrity() if work.ready else {}
			var failed: Array = physical.get("checks", []).filter(func(check): return not check.passed).map(func(check): return check.partId)
			rows.append({"prefix": prefix, "parentId": parent, "mode": mode,
				"failedFrameIds": ids.filter(func(id): return failed.has(id)),
				"passed": work.ready and ids.size() == 11 and ids.all(func(id): return failed.has(id))})
	return rows


func _direct_contract() -> Dictionary:
	var direct := _fixture(0, true)
	var explicit := _fixture(0, true)
	var a: Dictionary = Frame.add_frame(direct.b, direct.prefixes[0], direct.supportId)
	var c: Dictionary = Frame.add_frame_on_support(explicit.b, explicit.prefixes[0], explicit.supportId, [])
	var rejections: Array = []
	for quarter in [1, 2, 3]:
		var fixture := _fixture(quarter, true)
		var before := _digest(fixture.b.snapshot())
		var result: Dictionary = Frame.add_frame(fixture.b, fixture.prefixes[0], fixture.supportId)
		rejections.append({"quarterTurn": quarter, "result": result,
			"passed": not result.ready and _digest(fixture.b.snapshot()) == before})
	return {"zeroTurnDirect": a, "zeroTurnExplicit": c, "legacyRotationRejections": rejections,
		"passed": a.ready and c.ready and _digest(direct.b.snapshot()) == _digest(explicit.b.snapshot()) and rejections.all(func(row): return row.passed)}


func _rigid(quarter: int) -> Transform3D:
	# Independent coordinate permutation, not Frame._frame_orientation.
	var right := _quarter_vector(Vector3.RIGHT, quarter)
	var back := _quarter_vector(Vector3.BACK, quarter)
	var basis := Basis(right, Vector3.UP, back)
	return Transform3D(basis, PIVOT - basis * PIVOT)


func _quarter_vector(v: Vector3, quarter: int) -> Vector3:
	match quarter:
		1: return Vector3(v.z, v.y, -v.x)
		2: return Vector3(-v.x, v.y, -v.z)
		3: return Vector3(-v.z, v.y, v.x)
	return v


func _corners(size: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]: result.append(size * Vector3(x, y, z))
	return result


func _joint_geometry(actual: Transform3D, a: Dictionary, expected: Transform3D, e: Dictionary) -> bool:
	if not _near(a, e): return false
	var center_key := "localMountCenter" if e.has("localMountCenter") else ("localOverlapCenter" if e.has("localOverlapCenter") else "localPatchCenter")
	var half_key := "localMountHalfExtents" if e.has("localMountHalfExtents") else ("localOverlapHalfExtents" if e.has("localOverlapHalfExtents") else "localPatchHalfExtents")
	var ah: Variant = a[half_key]
	var eh: Variant = e[half_key]
	var actual_half: Vector3 = Vector3(ah.x, 0.0, ah.y) if ah is Vector2 else ah
	var expected_half: Vector3 = Vector3(eh.x, 0.0, eh.y) if eh is Vector2 else eh
	var ac: Vector3 = a[center_key]
	var ec: Vector3 = e[center_key]
	var signs := _corners(Vector3.ONE * 2.0)
	for sign in signs:
		if (actual * (ac + sign * actual_half)).distance_to(expected * (ec + sign * expected_half)) > GEOMETRY_EPS:
			return false
	return true


func _near(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b): return false
	if a is Vector3 or a is Vector2: return a.distance_to(b) <= GEOMETRY_EPS
	if a is float: return is_finite(a) and is_finite(b) and absf(a - b) <= GEOMETRY_EPS
	if a is Dictionary:
		if a.size() != b.size(): return false
		for key in a:
			if not b.has(key) or not _near(a[key], b[key]): return false
		return true
	if a is Array:
		if a.size() != b.size(): return false
		for i in range(a.size()):
			if not _near(a[i], b[i]): return false
		return true
	return a == b


func _basis_close(a: Basis, b: Basis) -> bool:
	return a.is_finite() and a.x.distance_to(b.x) <= BASIS_EPS and a.y.distance_to(b.y) <= BASIS_EPS and a.z.distance_to(b.z) <= BASIS_EPS


func _unchanged(before: Dictionary, after: Dictionary, changed: Array) -> bool:
	var a := before.duplicate(true)
	var c := after.duplicate(true)
	a.erase("parts")
	c.erase("parts")
	if _digest(a) != _digest(c) or after.parts.size() != before.parts.size() + 15: return false
	for i in range(before.parts.size()):
		if before.parts[i].id != after.parts[i].id: return false
		if not changed.has(before.parts[i].id) and _digest(before.parts[i]) != _digest(after.parts[i]): return false
	return true


func _record(snapshot: Dictionary, id: String) -> Dictionary:
	for part in snapshot.parts:
		if part.id == id: return part
	return {}


func _find(b, id: String):
	for part in b.parts:
		if part.id == id: return part
	return null


func _digest(value: Variant) -> String:
	return var_to_bytes(value).hex_encode().sha256_text()


func _json(value: Variant) -> Variant:
	if value is Vector3: return [value.x, value.y, value.z]
	if value is Vector2: return [value.x, value.y]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
