extends SceneTree

## SYNTHETIC actual-Part / existing-Blueprint contract only. No publication,
## generated world, visual, collision, gameplay, admission or navigation proof.
## Main runs this separately; VOXEL_THRESHOLD_HOUSING_REPORT must be fresh.
const RECIPE_PATH := "res://scripts/buildings/ThresholdBearingHousingRecipe.gd"
const BLUEPRINT_PATH := "res://scripts/buildings/BuildingBlueprint.gd"
const MAX_REPORT_BYTES := 262144
const UPPER := 3.875730514526367
const SEAT_TOP := 2.6200000047683716
var _recipe: Script
var _blueprint: Script
var _checks: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_THRESHOLD_HOUSING_REPORT").strip_edges()
	if not _fresh_path(path):
		push_error("VOXEL_THRESHOLD_HOUSING_REPORT requires a fresh absolute JSON path")
		quit(2)
		return
	_recipe = load(RECIPE_PATH) as Script
	_blueprint = load(BLUEPRINT_PATH) as Script
	if _recipe == null or _blueprint == null or not _recipe.can_instantiate() or not _blueprint.can_instantiate():
		push_error("Threshold housing dependency failed compile guard")
		quit(2)
		return
	_positive()
	_refusals()
	_validation_refusals()
	_finish(path)


func _fixture() -> Dictionary:
	var source = _blueprint.new("synthetic_housing", 17, "stone")
	# Ordinary collision-backed root and raised roadbed with real positive
	# overlap. No forged physicalRoot/support cache and no special validator.
	var root = source.add_part({"id": "root", "kind": "foundation", "collision": true,
		"physicalIntent": "structural_mass", "position": Vector3(0, 1.25, 0), "size": Vector3(6, 2.5, 6)})
	var seat = source.add_part({"id": "raised_roadbed", "kind": "foundation", "collision": true,
		"physicalIntent": "structural_mass", "position": Vector3(0, 2.5, 0),
		"size": Vector3(4, 0.24000000953674316, 4),
		"recipe": {"physicalRequiredSeatPartIds": [root.id]}})
	return {"source": source, "seat": seat, "center": Vector3(0, 3, 0), "size": Vector3(0.5, 1, 0.4)}


func _prepare(f: Dictionary, label: String, upper: float = UPPER) -> Dictionary:
	var frozen := var_to_bytes([f.source.snapshot(), f.source.physical_parts_by_id,
		f.source.structural_support_grid, f.source.invalid_gable_part_ids, f.center, f.size])
	var result: Dictionary = _recipe.prepare(f.seat, upper, f.center, f.size)
	_check(label + ":immutable", frozen == var_to_bytes([f.source.snapshot(), f.source.physical_parts_by_id,
		f.source.structural_support_grid, f.source.invalid_gable_part_ids, f.center, f.size]))
	_check(label + ":typed", result.get("ready") is bool)
	return result


func _positive() -> void:
	var f := _fixture()
	_check("fixture:exact_nonrepresentable_seat_top", float(f.seat.position.y) + float(f.seat.size.y) * 0.5 == SEAT_TOP
		and float(Vector3(0, SEAT_TOP, 0).y) != SEAT_TOP)
	var initial: Dictionary = f.source.validate_physical_integrity()
	_check("proof:initial_real_blueprint", initial.get("passed") == true
		and f.source.has_rooted_support_chain(f.seat, {}) and not f.seat.recipe.get("physicalRoot", false))
	var seat_bytes := var_to_bytes(f.seat.snapshot())
	var result := _prepare(f, "positive")
	_check("positive:ready", result.get("ready") == true)
	if not result.get("ready", false): return
	_check("positive:no_proof_or_admission_claim", result.keys().size() == 11 and result.get("seated") == true
		and result.get("contactMode") == "housed_overlap" and result.get("seatId") == f.seat.id
		and result.get("seatPlane") == SEAT_TOP and not result.has("skipAdmission") and not result.has("physicalRoot"))
	_check("positive:repeat_bytes", var_to_bytes(result) == var_to_bytes(_prepare(f, "repeat")))
	var post = f.source.add_part({"id": "new_housed_post", "kind": "foundation", "collision": true,
		"physicalIntent": "structural_mass", "position": result.position, "size": result.size,
		"recipe": {"physicalRequiredSeatPartIds": [result.seatId], "physicalRequiredSeatFacts": [result.seatFact]}})
	_check("actual_part:unclamped", post.position == result.position and post.size == result.size)
	var bottom := float(post.position.y) - float(post.size.y) * 0.5
	_check("actual_part:exact_upper", float(post.position.y) + float(post.size.y) * 0.5 == UPPER)
	_check("actual_part:recipe_defined_center_and_height", post.position.y == Vector3(0, (SEAT_TOP - 0.07 + UPPER) * 0.5, 0).y
		and post.size.y == Vector3(0, 2.0 * (UPPER - float(post.position.y)), 0).y)
	_check("actual_part:bounded_embedment", SEAT_TOP - bottom >= 0.06 and SEAT_TOP - bottom <= 0.08
		and result.actualEmbedment == SEAT_TOP - bottom)
	_check("actual_part:independent_corners", _corners_inside(post, f.seat, result.seatFact))
	var frozen := var_to_bytes([post.snapshot(), f.seat.snapshot(), result])
	var validated: Dictionary = _recipe.validate(post, f.seat, result.seatFact)
	_check("validate:immutable", frozen == var_to_bytes([post.snapshot(), f.seat.snapshot(), result]))
	_check("validate:actual_intersection_and_witness", validated.get("ready") == true
		and validated.get("seated") == true and validated.get("actualEmbedment") == result.actualEmbedment
		and validated.get("contactMode") == "housed_overlap"
		and validated.get("intersectionBounds") == result.intersectionBounds
		and validated.get("witnessBounds") == result.witnessBounds and _bounds_valid(post, f.seat, result))
	_check("proof:existing_housed_validator", f.source.has_rooted_housed_overlap(post, f.seat, result.seatFact))
	_check("proof:existing_bearer_dispatch", f.source.has_rooted_bearer_seat(post, result.seatFact))
	_check("proof:prepare_preserves_initial_seat_bytes", var_to_bytes(f.seat.snapshot()) == seat_bytes)
	var final_report: Dictionary = f.source.validate_physical_integrity()
	_check("proof:complete_real_blueprint", final_report.get("passed") == true
		and f.source.has_rooted_support_chain(post, {}) and not post.recipe.get("physicalRoot", false))
	_minima(f, post, result.seatFact)
	for width: float in [0.4047, 0.5438]:
		var skinny := _fixture()
		skinny.size = Vector3(width, 1, 0.14817)
		var label := "skinny_%s" % str(width)
		var prepared := _prepare(skinny, label)
		_check(label + ":x_span", prepared.get("ready") == true
			and prepared.get("seatFact", {}).get("localSpanAxis") == "x")
		if prepared.get("ready", false):
			var actual = _post(skinny, prepared)
			var proof: Dictionary = skinny.source.validate_physical_integrity()
			_check(label + ":actual_geometry_and_blueprint", _recipe.validate(actual, skinny.seat, prepared.seatFact).get("ready") == true
				and proof.get("passed") == true and _corners_inside(actual, skinny.seat, prepared.seatFact))
	var z_case := _fixture()
	z_case.size = Vector3(0.15, 1, 0.5)
	var z_result := _prepare(z_case, "z_axis")
	_check("z_axis:strongest_span", z_result.get("ready") == true and z_result.get("seatFact", {}).get("localSpanAxis") == "z")
	var unproven := _fixture()
	unproven.source.parts.remove_at(0)
	var proposed := _prepare(unproven, "unproven_geometry")
	_check("unproven:geometry_is_not_root_proof", proposed.get("ready") == true
		and not unproven.source.has_rooted_support_chain(unproven.seat, {}))
	var independent := _prepare(f, "independent_output")
	var source_bytes := var_to_bytes(f.source.snapshot())
	independent.seatFact.localOverlapCenter = Vector3.ZERO
	_check("positive:output_has_no_source_alias", source_bytes == var_to_bytes(f.source.snapshot())
		and var_to_bytes(result) == var_to_bytes(_prepare(f, "after_output_edit")))
	var policy := _recipe.get_script_constant_map()
	_check("policy:fixed_recipe_dimensions", policy.get("EMBEDMENT") == 0.07
		and policy.get("MIN_EMBEDMENT") == 0.06 and policy.get("MAX_EMBEDMENT") == 0.08)
	# World translation changes neither the recipe-defined insertion nor its
	# witness policy. A fresh scene/seed is unnecessary for this geometry check.
	var translated := _fixture()
	translated.seat.position.x = 32.0
	translated.seat.position.z = -64.0
	translated.center.x = 32.0
	translated.center.z = -64.0
	var moved := _prepare(translated, "translated")
	_check("translated:fixed_depth_and_local_fact", moved.get("ready") == true
		and moved.get("actualEmbedment") == result.actualEmbedment and moved.get("seatFact") == result.seatFact)


func _post(f: Dictionary, prepared: Dictionary):
	return f.source.add_part({"id": "housed_post", "kind": "foundation", "collision": true,
		"physicalIntent": "structural_mass", "position": prepared.position, "size": prepared.size,
		"recipe": {"physicalRequiredSeatPartIds": [prepared.seatId], "physicalRequiredSeatFacts": [prepared.seatFact]}})


func _bounds_valid(post, seat, result: Dictionary) -> bool:
	var witness_center: Vector3 = result.seatFact.localOverlapCenter
	var witness_half: Vector3 = result.seatFact.localOverlapHalfExtents
	for axis in [0, 1, 2]:
		var low := maxf(float(post.position[axis]) - float(post.size[axis]) * 0.5,
			float(seat.position[axis]) - float(seat.size[axis]) * 0.5)
		var high := minf(float(post.position[axis]) + float(post.size[axis]) * 0.5,
			float(seat.position[axis]) + float(seat.size[axis]) * 0.5)
		var witness_low := float(post.position[axis]) + float(witness_center[axis]) - float(witness_half[axis])
		var witness_high := float(post.position[axis]) + float(witness_center[axis]) + float(witness_half[axis])
		if result.intersectionBounds.min[axis] != low or result.intersectionBounds.max[axis] != high or low >= high \
				or result.witnessBounds.min[axis] != witness_low or result.witnessBounds.max[axis] != witness_high \
				or witness_low <= low or witness_high >= high or witness_low >= witness_high: return false
	return true


func _corners_inside(post, seat, fact: Dictionary) -> bool:
	var center: Vector3 = fact.localOverlapCenter
	var half: Vector3 = fact.localOverlapHalfExtents
	var axis := 0 if fact.localSpanAxis == "x" else 2
	if not center.is_finite() or not half.is_finite() or half.x <= 0 or half.y <= 0 or half.z <= 0 \
			or float(half[axis]) * 2.0 < 0.12 or float(half.y) * 2.0 < 0.04: return false
	for a in [0, 2]:
		if absf(float(post.position[a]) - float(seat.position[a])) + float(post.size[a]) * 0.5 >= float(seat.size[a]) * 0.5 - 0.005:
			return false
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var signs := [x, y, z]
				var local_point := center + half * Vector3(x, y, z)
				var seat_point: Vector3 = (post.position + local_point) - seat.position
				for a in [0, 1, 2]:
					var local_scalar := float(center[a]) + float(half[a]) * float(signs[a])
					var seat_scalar: float = float(post.position[a]) + local_scalar - float(seat.position[a])
					if absf(local_scalar) > float(post.size[a]) * 0.5 - 0.005 \
							or absf(float(local_point[a])) > float(post.size[a]) * 0.5 - 0.005 \
							or absf(seat_scalar) >= float(seat.size[a]) * 0.5 - 0.005 \
							or absf(float(seat_point[a])) >= float(seat.size[a]) * 0.5 - 0.005: return false
	return true


func _minima(f: Dictionary, post, fact: Dictionary) -> void:
	var constants := _blueprint.get_script_constant_map()
	_check("minima:unchanged_existing_policy", constants.get("STAIR_MIN_HOUSED_EMBEDMENT") == 0.12
		and constants.get("STAIR_MIN_HOUSED_VERTICAL_OVERLAP") == 0.04 and constants.get("STAIR_HOUSED_JOINT_INSET") == 0.005)
	for mode: String in ["vertical", "longitudinal", "bearer_corner", "seat_corner"]:
		var bad := fact.duplicate(true)
		var center: Vector3 = bad.localOverlapCenter
		var half: Vector3 = bad.localOverlapHalfExtents
		match mode:
			"vertical": half.y = 0.019
			"longitudinal": half.x = 0.059
			"bearer_corner": center.x = post.size.x * 0.5
			"seat_corner": center.y = float(f.seat.position.y) + float(f.seat.size.y) * 0.5 - float(post.position.y)
		bad.localOverlapCenter = center
		bad.localOverlapHalfExtents = half
		# Lowering declarations must not lower the existing validator's minima.
		bad.minimumLongitudinalEmbedment = 0.0
		bad.minimumVerticalOverlap = 0.0
		_check("minima:reject_" + mode, not f.source.has_rooted_housed_overlap(post, f.seat, bad))
		_check("minima:geometry_reject_" + mode, _recipe.validate(post, f.seat, bad).get("ready") == false)


func _refusals() -> void:
	for mode: String in ["thin_seat", "short_seat", "narrow_post", "partial_footprint", "inset_violation", "rotation", "rotation_nan",
		"seat_nan", "seat_inf", "center_nan", "size_inf", "negative_size", "clamped_size", "seat_zero_size", "noncollision",
		"wrong_kind", "wrong_intent", "cut_seat", "paving_cut", "empty_id", "below_ground", "coordinate_domain", "size_domain",
		"upper_nan", "upper_inf", "upper_domain", "upper_zero", "upper_at_seat", "upper_below_seat", "unrepresentable_upper"]:
		var f := _fixture()
		var upper := UPPER
		match mode:
			"thin_seat": f.seat.size.y = 0.0625
			"short_seat": f.seat.size.x = 0.125
			"narrow_post": f.size = Vector3(0.24, 1, 0.24)
			"partial_footprint": f.center.x = 1.9
			"inset_violation": f.center.x = 1.75
			"rotation": f.seat.rotation.y = 0.1
			"rotation_nan": f.seat.rotation.y = NAN
			"seat_nan": f.seat.position.x = NAN
			"seat_inf": f.seat.size.y = INF
			"center_nan": f.center.y = NAN
			"size_inf": f.size.z = INF
			"negative_size": f.size.x = -1.0
			"clamped_size": f.size.y = 0.01
			"seat_zero_size": f.seat.size.z = 0.0
			"noncollision": f.seat.collision_enabled = false
			"wrong_kind": f.seat.kind = "stairs"
			"wrong_intent": f.seat.physical_intent = "walkable_surface"
			"cut_seat": f.seat.recipe["masonryApertureSource"] = null
			"paving_cut": f.seat.recipe["pavingFootingJoints"] = []
			"empty_id": f.seat.id = ""
			"below_ground": f.seat.position.y = 0.0
			"coordinate_domain": f.center.x = 10001.0
			"size_domain": f.size.x = 10001.0
			"upper_nan": upper = NAN
			"upper_inf": upper = INF
			"upper_domain": upper = 10001.0
			"upper_zero": upper = 0.0
			"upper_at_seat": upper = SEAT_TOP
			"upper_below_seat": upper = 2.0
			"unrepresentable_upper": upper = UPPER + 1.0 / 1099511627776.0
		var result := _prepare(f, "refuse:" + mode, upper)
		_check("refuse:" + mode + ":closed", result.get("ready") == false and not result.get("reason", "").is_empty()
			and not result.has("seatFact") and not result.has("skipAdmission"))
	_check("refuse:null_seat", _recipe.prepare(null, UPPER, Vector3.ZERO, Vector3.ONE).get("ready") == false)


func _validation_refusals() -> void:
	for mode: String in ["excessive_depth", "shallow_depth", "side_penetration", "footprint_inset", "post_rotation", "seat_rotation",
		"post_modifier", "seat_modifier", "post_nonfinite", "post_domain", "seat_identity", "wrong_contact_mode", "wrong_axis",
		"empty_fact", "mistyped_center", "nan_witness", "zero_witness", "bearer_boundary", "seat_boundary", "nan_minimum", "larger_minimum"]:
		var f := _fixture()
		f.source.validate_physical_integrity()
		var prepared: Dictionary = _recipe.prepare(f.seat, UPPER, f.center, f.size)
		if not prepared.get("ready", false):
			_check("validate_refuse:" + mode + ":setup", false)
			continue
		var post = _post(f, prepared)
		var fact: Dictionary = prepared.seatFact.duplicate(true)
		match mode:
			"excessive_depth": post.position.y -= 0.03125
			"shallow_depth": post.position.y += 0.03125
			"side_penetration": post.position.x = 1.8125
			"footprint_inset": post.position.x = 1.74609375
			"post_rotation": post.rotation.x = 0.1
			"seat_rotation": f.seat.rotation.z = 0.1
			"post_modifier": post.recipe["masonryApertureSource"] = {}
			"seat_modifier": f.seat.recipe["pavingFootingJoints"] = null
			"post_nonfinite": post.position.y = INF
			"post_domain": post.position.z = 10001.0
			"seat_identity": fact.seatId = "other_seat"
			"wrong_contact_mode": fact.contactMode = "world_down"
			"wrong_axis": fact.localSpanAxis = "y"
			"empty_fact": fact = {}
			"mistyped_center": fact.localOverlapCenter = []
			"nan_witness": fact.localOverlapCenter = Vector3(NAN, 0, 0)
			"zero_witness": fact.localOverlapHalfExtents = Vector3.ZERO
			"bearer_boundary": fact.localOverlapCenter = Vector3(post.size.x * 0.5, fact.localOverlapCenter.y, 0)
			"seat_boundary": fact.localOverlapCenter = Vector3(0, SEAT_TOP - float(post.position.y), 0)
			"nan_minimum": fact.minimumVerticalOverlap = NAN
			"larger_minimum": fact.minimumLongitudinalEmbedment = 1.0
		if mode in ["side_penetration", "footprint_inset"]:
			_check("validate_refuse:" + mode + ":small_witness_alone_would_pass",
				f.source.has_rooted_housed_overlap(post, f.seat, fact))
		var frozen := var_to_bytes([post.snapshot(), f.seat.snapshot(), fact])
		var result: Dictionary = _recipe.validate(post, f.seat, fact)
		_check("validate_refuse:" + mode + ":closed", result.get("ready") == false and result.get("seated") == false)
		_check("validate_refuse:" + mode + ":immutable", frozen == var_to_bytes([post.snapshot(), f.seat.snapshot(), fact]))
	_check("validate_refuse:null", _recipe.validate(null, null, {}).get("ready") == false)


func _check(id: String, passed: bool) -> void:
	_checks.append({"id": id, "passed": passed})
	if not passed: push_error("Synthetic threshold housing contract failed: " + id)


func _fresh_path(path: String) -> bool:
	return path.is_absolute_path() and not path.contains("://") and path.get_extension().to_lower() == "json" \
		and DirAccess.dir_exists_absolute(path.get_base_dir()) \
		and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)


func _finish(path: String) -> void:
	var seen: Dictionary = {}
	var unique := true
	for row: Dictionary in _checks:
		unique = unique and not seen.has(row.id)
		seen[row.id] = true
	_check("report:unique_check_ids", unique and not seen.has("report:unique_check_ids"))
	var passed := not _checks.is_empty() and _checks.all(func(row): return row.passed == true)
	var report := {"fixture": "ThresholdBearingHousingContract", "passed": passed, "checks": _checks,
		"evidenceLevel": "synthetic_actual_part_existing_blueprint_contract", "seatPlane": SEAT_TOP, "upper": UPPER,
		"doesNotProve": "No admission, publication, generated world, visual, physics, gameplay or NPC/navigation acceptance."}
	var bytes := JSON.stringify(report, "\t").to_utf8_buffer()
	if bytes.size() > MAX_REPORT_BYTES or not _fresh_path(path):
		quit(2)
		return
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_buffer(bytes)
	output.flush()
	var error := output.get_error()
	output.close()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if error != OK or FileAccess.get_file_as_bytes(path) != bytes or not parsed is Dictionary \
			or parsed.get("fixture") != report.fixture or parsed.get("passed") != passed:
		quit(2)
		return
	print("Synthetic threshold housing contract: ", passed, " checks=", _checks.size(), " report=", path)
	quit(0 if passed else 1)
