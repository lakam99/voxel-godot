extends SceneTree

## SYNTHETIC SOURCE CONTRACT ONLY. The final positive uses the real Blueprint
## validator, but no generated world, publisher, live physics, visual, gameplay
## or NPC/navigation acceptance is claimed. No test scene is required.
const Recipe = preload("res://scripts/buildings/ThresholdBearingSeatRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const MAX_REPORT_BYTES := 262144
var _checks: Array = []
var _cases: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for dependency in [Recipe, Blueprint]:
		if not dependency.can_instantiate():
			push_error("Threshold seat contract dependency failed to compile")
			quit(1)
			return
	var path := OS.get_environment("VOXEL_THRESHOLD_SEAT_REPORT").strip_edges().simplify_path()
	if not _fresh_path(path):
		push_error("VOXEL_THRESHOLD_SEAT_REPORT requires a fresh absolute JSON path")
		quit(1)
		return
	_positive()
	_selection()
	_ineligible()
	_inferred_roles()
	_shape_selectors()
	_patch_cases()
	_unrepresentable()
	_invalid_input()
	var ids: Dictionary = {}
	var unique := true
	for row: Dictionary in _checks:
		unique = unique and not ids.has(row.id)
		ids[row.id] = true
	_check("report:unique_check_ids", unique and not ids.has("report:unique_check_ids"))
	var passed := not _checks.is_empty() and _checks.all(func(row): return row.passed == true)
	var report := {"fixture": "ThresholdBearingSeatContract", "passed": passed,
		"evidenceLevel": "synthetic_source_contract", "checks": _checks, "cases": _cases,
		"doesNotProve": "No full admission, publication, live physics, rendered clearance, gameplay, NPC/navigation or generated-Citadel acceptance."}
	var bytes := JSON.stringify(report, "\t").to_utf8_buffer()
	if bytes.size() > MAX_REPORT_BYTES or not _fresh_path(path):
		quit(1)
		return
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		quit(1)
		return
	output.store_buffer(bytes)
	output.flush()
	var error := output.get_error()
	output.close()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if error != OK or FileAccess.get_file_as_bytes(path) != bytes or not parsed is Dictionary \
			or parsed.get("fixture") != report.fixture or parsed.get("passed") != passed:
		quit(1)
		return
	print("Synthetic threshold seat contract: ", passed, " checks=", _checks.size(), " report=", path)
	quit(0 if passed else 1)


func _fixture() -> Dictionary:
	var b = Blueprint.new("synthetic_seat_source", 17, "stone")
	var threshold = b.add_part({"id": "threshold", "kind": "foundation", "collision": false,
		"physicalIntent": "facade_attachment", "position": Vector3(0, 4.125, 0), "size": Vector3(1, 0.25, 1)})
	return {"source": b, "threshold": threshold, "center": Vector3(0, 2, 0), "size": Vector3(1, 4, 1)}


func _root(b, id: String, height: float = 0.5):
	return b.add_part({"id": id, "kind": "foundation", "collision": true,
		"physicalIntent": "structural_mass", "position": Vector3(0, height * 0.5, 0), "size": Vector3(4, height, 4)})


func _prepare(f: Dictionary, label: String) -> Dictionary:
	# Include caches as well as source/target records: helper may not resolve or
	# validate the live source to obtain convenient physicalRoot annotations.
	var frozen := var_to_bytes([f.source.snapshot(), f.threshold.snapshot(), f.center, f.size,
		f.source.physical_parts_by_id, f.source.structural_support_grid, f.source.invalid_gable_part_ids])
	var result: Dictionary = Recipe.prepare(f.source, f.threshold, f.center, f.size)
	_check(label + ":immutable", frozen == var_to_bytes([f.source.snapshot(), f.threshold.snapshot(), f.center, f.size,
		f.source.physical_parts_by_id, f.source.structural_support_grid, f.source.invalid_gable_part_ids]))
	_check(label + ":typed_result", result.get("ready") is bool and result.get("seated") is bool)
	_cases.append({"case": label, "result": result.duplicate(true)})
	return result


func _positive() -> void:
	var f := _fixture()
	var root = _root(f.source, "root")
	_check("positive:no_cached_root", not root.recipe.get("physicalRoot", false))
	var result := _prepare(f, "positive")
	_check("positive:exact_result", result.get("ready") == true and result.get("seated") == true \
		and result.get("seatId") == "root" and result.get("seatPlane") == 0.5 \
		and result.get("position") == Vector3(0, 2.25, 0) and result.get("size") == Vector3(1, 3.5, 1))
	if not result.get("ready", false) or not result.get("seated", false): return
	_check("positive:independent_patch", _patch_valid(result, root))
	var repeated := _prepare(f, "positive_repeat")
	_check("positive:repeat_byte_exact", var_to_bytes(result) == var_to_bytes(repeated))
	# Normal caller construction, followed by the REAL physical validator.
	var bearer = f.source.add_part({"id": "threshold_bearing", "kind": "foundation", "collision": true,
		"physicalIntent": "structural_mass", "position": result.position, "size": result.size,
		"recipe": {"physicalRequiredSeatPartIds": [result.seatId], "physicalRequiredSeatFacts": [result.seatFact]}})
	f.threshold.recipe["physicalRequiredAnchorPartIds"] = [bearer.id]
	var report: Dictionary = f.source.validate_physical_integrity()
	_check("positive:real_physical_validator", report.get("passed") == true)
	_check("positive:ordinary_bearer_seat", f.source.has_rooted_bearer_seat(bearer, result.seatFact))
	_check("positive:bearer_is_not_ground_root", not f.source.is_grounded_structural_root(bearer) and not bearer.recipe.get("physicalRoot", false))
	_check("positive:exact_scalar_endpoints", float(bearer.position.y) - float(bearer.size.y) * 0.5 == 0.5 \
		and float(bearer.position.y) + float(bearer.size.y) * 0.5 == 4.0)
	var warm := _prepare(f, "positive_warm")
	_check("positive:warm_same_proposal", var_to_bytes(result) == var_to_bytes(warm))


func _selection() -> void:
	var empty := _fixture()
	_check("empty:no_seat", _prepare(empty, "empty") == {"ready": true, "seated": false})
	var f := _fixture()
	_root(f.source, "lower", 0.25)
	_root(f.source, "z_high", 1.0)
	_root(f.source, "a_high", 1.0)
	var result := _prepare(f, "highest")
	_check("highest:top_then_lexical", result.get("seated") == true and result.get("seatId") == "a_high" and result.get("seatPlane") == 1.0)
	f.source.parts.reverse()
	var reversed := _prepare(f, "reversed")
	_check("highest:source_order_independent", var_to_bytes(result) == var_to_bytes(reversed))
	# Exclude the current bearing by its caller-defined identity, even if its
	# geometry and intent would otherwise be an eligible grounded foundation.
	_root(f.source, "threshold_bearing", 2.0)
	f.threshold.collision_enabled = true
	f.threshold.physical_intent = "structural_root"
	f.threshold.position.y = 2.0
	f.threshold.size.y = 4.0
	var excluded := _prepare(f, "excluded_threshold_and_bearing")
	_check("excluded:no_self_seat", excluded == {"ready": true, "seated": false})
	# Restore a target above the current bearing so ID exclusion is independent
	# of the strict top-below-threshold filter.
	f.threshold.position.y = 4.125
	f.threshold.size.y = 0.25
	var bearing_excluded := _prepare(f, "excluded_current_bearing")
	_check("excluded:bearing_id", bearing_excluded.get("seatId") == "a_high")


func _ineligible() -> void:
	for mode: String in ["noncollision", "rotated", "nonfinite", "zero_size", "wrong_kind", "wrong_intent", "fake_root", "elevated", "near_ground", "at_threshold", "above_threshold"]:
		var f := _fixture()
		var part = _root(f.source, "candidate")
		match mode:
			"noncollision": part.collision_enabled = false
			"rotated": part.rotation.y = 0.1
			"nonfinite": part.position.x = NAN
			"zero_size": part.size.z = 0.0
			"wrong_kind": part.kind = "wall"
			"wrong_intent": part.physical_intent = "walkable_surface"
			"fake_root":
				part.position.y = 1.0
				part.recipe["physicalRoot"] = true
				part.physical_intent = "structural_root"
			"elevated":
				part.position.y = 1.0
				part.recipe["physicalRequiredSeatPartIds"] = ["unresolved_lower"]
			"near_ground": part.position.y += 0.03125
			"at_threshold":
				part.position.y = 2.0
				part.size.y = 4.0
			"above_threshold":
				part.position.y = 2.5
				part.size.y = 5.0
		if mode == "near_ground": _check("near_ground:ordinary_predicate_accepts", f.source.is_grounded_structural_root(part))
		var result := _prepare(f, mode)
		_check(mode + ":ineligible", result == {"ready": true, "seated": false})
		if mode == "elevated":
			_check("elevated:retained_collision_source_for_main_admission", f.source.parts.has(part) \
				and part.collision_enabled and part.physical_intent == "structural_mass" \
				and part.position == Vector3(0, 1, 0) and part.size == Vector3(4, 0.5, 4))
			_cases.append({"case": "elevated_blocker_scope", "scope": "Excluded as seat but retained unchanged. Main _candidate must still reject its positive overlap; this helper does not perform admission."})


func _inferred_roles() -> void:
	var f := _fixture()
	var root = _root(f.source, "implicit_root")
	root.physical_intent = ""
	var inferred := _prepare(f, "inferred_role")
	_check("inferred_role:ordinary_taxonomy", f.source.inferred_physical_intent(root) == "structural_mass"
		and inferred.get("ready") == true and inferred.get("seatId") == root.id)
	_check("inferred_role:no_source_classification", root.physical_intent == "" and not root.recipe.has("physicalRoot"))
	root.physical_intent = "structural_mass"
	var explicit := _prepare(f, "explicit_equivalent")
	_check("inferred_role:explicit_equivalence", var_to_bytes(inferred) == var_to_bytes(explicit))
	var wrong = _root(f.source, "higher_wrong_role", 1.0)
	wrong.physical_intent = "walkable_surface"
	wrong.recipe["navigationRole"] = "structural_mass"
	wrong.recipe["physicalRoot"] = true
	var retained := _prepare(f, "higher_wrong_role")
	_check("inferred_role:explicit_wrong_role_not_overridden", retained.get("seatId") == root.id
		and wrong.physical_intent == "walkable_surface")


func _shape_selectors() -> void:
	for key: String in ["masonryApertureSource", "pavingFootingJoints"]:
		for index in range(3):
			var f := _fixture()
			var root = _root(f.source, "shape_modified")
			var values: Array = [null, [], {"unsupported": true}]
			root.recipe[key] = values[index]
			var label := "shape:" + key + ":%d" % index
			_check(label + ":ineligible", _prepare(f, label) == {"ready": true, "seated": false})
	var ordinary := _fixture()
	var plain = _root(ordinary.source, "arbitrary_identity")
	plain.material_id = "painted_brick_cream"
	plain.semantic = "arbitrary_semantic"
	plain.recipe["variation"] = 0.17
	plain.recipe["topSurfaceMaterial"] = "stone_foundation"
	_check("shape:ordinary_visual_recipe_still_full_collision_box", _prepare(ordinary, "shape_ordinary").get("seated") == true)


func _patch_cases() -> void:
	for mode: String in ["narrow_bearer", "narrow_seat", "edge_only", "disjoint"]:
		var f := _fixture()
		var root = _root(f.source, "root")
		match mode:
			"narrow_bearer": f.size.x = 0.0625
			"narrow_seat": root.size.z = 0.0625
			"edge_only": root.position.x = 2.5
			"disjoint": root.position.x = 8.0
		_check(mode + ":no_patch", _prepare(f, mode) == {"ready": true, "seated": false})
	var partial := _fixture()
	var seat = _root(partial.source, "partial")
	seat.position.x = 2.0
	var result := _prepare(partial, "partial")
	_check("partial:positive_inset_patch", result.get("seated") == true and _patch_valid(result, seat))


func _patch_valid(result: Dictionary, seat) -> bool:
	if not result.get("seatFact") is Dictionary: return false
	var fact: Dictionary = result.seatFact
	if fact.get("loadDirection") != "world_down" or fact.get("seatFace") != "max_y" or fact.get("seatId") != seat.id: return false
	var center: Vector3 = fact.localPatchCenter
	var half: Vector2 = fact.localPatchHalfExtents
	if not center.is_finite() or not half.is_finite() or half.x <= 0.0 or half.y <= 0.0 or center.y != -result.size.y * 0.5: return false
	for index in range(2):
		var axis := 0 if index == 0 else 2
		if absf(float(center[axis])) + float(half[index]) > float(result.size[axis]) * 0.5 - 0.05: return false
		var local_to_seat: float = float(result.position[axis]) + float(center[axis]) - float(seat.position[axis])
		if absf(local_to_seat) + float(half[index]) > float(seat.size[axis]) * 0.5 - 0.05: return false
	return true


func _unrepresentable() -> void:
	for mode: String in ["one_ulp", "actual_slab_062"]:
		var f := _fixture()
		var lower = _root(f.source, "lower_exact", 0.25)
		var height := 0.5 + 1.0 / 16777216.0 if mode == "one_ulp" else 0.62
		var selected = _root(f.source, "highest_unrepresentable", height)
		var expected_bottom: float = float(selected.position.y) + float(selected.size.y) * 0.5
		var pair := Vector2((expected_bottom + 4.0) * 0.5, 4.0 - expected_bottom)
		var represented_bottom: float = float(pair.x) - float(pair.y) * 0.5
		var represented_top: float = float(pair.x) + float(pair.y) * 0.5
		_check(mode + ":fixture_not_exact", represented_bottom != expected_bottom or represented_top != 4.0)
		if mode == "actual_slab_062":
			_check(mode + ":actual_float32_endpoint", expected_bottom == 0.62000000476837158203125)
		var result := _prepare(f, mode)
		_check(mode + ":explicit_selected_failure", result.get("ready") == false and result.get("seated") == false \
			and result.get("reason") == "unrepresentable_threshold_seated_bearing" and result.get("seatId") == selected.id)
		_check(mode + ":exact_failure_evidence", result.get("seatPlane") == expected_bottom and result.get("thresholdBottom") == 4.0 \
			and result.get("representedBottom") == represented_bottom and result.get("representedTop") == represented_top)
		f.source.parts.reverse()
		var reversed := _prepare(f, mode + "_reversed")
		_check(mode + ":failure_order_independent", var_to_bytes(result) == var_to_bytes(reversed))
		f.source.parts.erase(selected)
		var fallback_control := _prepare(f, mode + "_lower_control")
		_check(mode + ":lower_was_feasible_but_not_tried", fallback_control.get("seated") == true and fallback_control.get("seatId") == lower.id)
		f.source.parts.erase(lower)
		_check(mode + ":ground_path_was_available_but_not_tried", _prepare(f, mode + "_ground_control") == {"ready": true, "seated": false})


func _invalid_input() -> void:
	var f := _fixture()
	f.size.y = 0.0
	_check("invalid_input:rejected", _prepare(f, "invalid_input").get("reason") == "invalid_threshold_seat_input")
	var duplicate := _fixture()
	_root(duplicate.source, "same")
	_root(duplicate.source, "same")
	_check("duplicate_id:rejected", _prepare(duplicate, "duplicate_id").get("reason") == "invalid_threshold_seat_source_identity")


func _check(id: String, passed: bool) -> void:
	_checks.append({"id": id, "passed": passed})
	if not passed: push_error("Synthetic threshold seat contract failed: " + id)


func _fresh_path(path: String) -> bool:
	return path.is_absolute_path() and not path.contains("://") and path.get_extension().to_lower() == "json" \
		and DirAccess.dir_exists_absolute(path.get_base_dir()) \
		and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)
