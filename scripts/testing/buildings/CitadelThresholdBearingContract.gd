extends SceneTree

## SYNTHETIC SOURCE CONTRACT ONLY: private, unwired prepare() proposals and the
## real BuildingBlueprint physical validator. No publication, physics frames,
## player/NPC movement, visual acceptance or production integration is proven.
## Main runs/reviews later; VOXEL_THRESHOLD_BEARING_REPORT must be a fresh,
## absolute .json path in an existing directory. No default or overwrite.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Recipe = preload("res://scripts/buildings/CitadelThresholdBearingRecipe.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Door = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const MAX_REPORT_BYTES := 1048576
var checks: Array = []
var evidence: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for dependency in [Blueprint, Recipe, Copy, Door, Admission]:
		if not dependency.can_instantiate():
			push_error("Threshold bearing contract dependency failed to compile")
			quit(2)
			return
	var path := OS.get_environment("VOXEL_THRESHOLD_BEARING_REPORT").strip_edges()
	if not _fresh_path(path):
		push_error("VOXEL_THRESHOLD_BEARING_REPORT requires a fresh absolute JSON path")
		quit(2)
		return
	var prior_path := ProjectSettings.globalize_path("res://artifacts/citadel-visual-reset/threshold-bearing-contract-01/report.json")
	_check("original_full_footprint_refusal_evidence_unchanged", FileAccess.get_sha256(prior_path) == "5665b6c0f7e77b585d7fe5fe0550202de6b5144cd8ba0029a129190e55b7f35b")
	for index in range(6):
		_positive(_fixture(index), "positive_%d" % index)
	_no_op()
	_identity_controls()
	_production_door_control()
	_rotated_obstacle_control()
	_swing_controls()
	_normalization_controls()
	var passed := not checks.is_empty() and checks.all(func(row): return row.passed == true)
	var report := {"fixture": "CitadelThresholdBearingContract", "passed": passed,
		"evidenceLevel": "synthetic_source_contract", "checks": checks, "cases": evidence,
		"doesNotProve": "No live physics, rendered clearance, gameplay, NPC/navigation or production integration. Production-shaped fitting is not a complete generated Citadel repair."}
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
	if error != OK or FileAccess.get_file_as_bytes(path) != bytes:
		quit(2)
		return
	print("Synthetic threshold bearing contract: ", passed, " checks=", checks.size(), " report=", path)
	quit(0 if passed else 1)


func _fixture(index: int = 0, production_door: bool = false) -> Dictionary:
	var prefix := "synthetic_threshold_%d" % index
	var side := -1.0 if index % 2 else 1.0
	var height := 0.62 + float(index / 2) * 0.47
	var width := 4.0 + float(index / 2) * 0.8
	var depth := 5.0 + float(index / 2) * 0.6
	var gap := 0.30 + float(index / 2) * 0.04
	var thickness := 0.14 + float(index / 2) * 0.02
	var threshold_size := Vector3(0.92 + float(index / 2) * 0.12, thickness, 1.58 + float(index / 2) * 0.2)
	var threshold_x := side * (width * 0.5 + gap + threshold_size.x * 0.5)
	var b = Blueprint.new("synthetic_threshold_source", 917 + index, "stone")
	b.set_recipe({"contractMarker": {"preserve": [17, "source", true]}})
	b.add_part({"id": prefix + "_foundation", "kind": "foundation", "material": "stone_foundation",
		"position": Vector3(0, height * 0.5, 0), "size": Vector3(width, height, depth),
		"collision": true, "semantic": "citadel_urban_house_foundation", "physicalIntent": "structural_mass"})
	# The ONLY synthetic clearance privilege is horizontal separation of the
	# positive door. Its upright geometry and bottom height remain ordinary.
	b.add_part({"id": prefix + "_door", "kind": "door", "material": "painted_door",
		"position": Vector3(threshold_x - side * 0.53, height + 1.25, 0 if production_door else depth + 3.0),
		"size": Vector3(0.14, 2.5, 1.25), "collision": true,
		"semantic": "citadel_urban_door", "physicalIntent": "portal", "recipe": {"roomId": prefix + "_interior"}})
	b.add_part({"id": prefix + "_door_threshold", "kind": "foundation", "material": "worn_cobble",
		"position": Vector3(threshold_x, height + thickness * 0.5, 0), "size": threshold_size,
		"collision": false, "semantic": "citadel_threshold_wear", "physicalIntent": "facade_attachment",
		"recipe": {"variation": -0.04}})
	b.set_room_records([{"id": prefix + "_interior", "citadelUrbanRoom": true,
		"bounds": AABB(Vector3(-width * 0.5 + 0.34, height + 0.18, -depth * 0.5 + 0.34), Vector3(width - 0.68, 3.0, depth - 0.68)),
		"accesses": [], "wallMountInset": 0.30}])
	return {"snapshot": b.snapshot(), "ownership": {"producerPrefix": prefix,
		"roomId": prefix + "_interior", "doorId": prefix + "_door",
		"threshold": {"id": prefix + "_door_threshold", "foundationId": prefix + "_foundation"}}}


func _prepare(f: Dictionary, label: String, furniture: Array = []) -> Dictionary:
	var before := var_to_bytes([f.snapshot, f.ownership, furniture])
	var result: Dictionary = Recipe.prepare(f.snapshot, f.ownership, furniture)
	_check(label + ":inputs_immutable", before == var_to_bytes([f.snapshot, f.ownership, furniture]))
	_check(label + ":boolean_result", result.get("ready") is bool and result.get("changed") is bool)
	if result.get("ready", false):
		_check(label + ":snapshot_result", result.get("afterSnapshot") is Dictionary)
	else:
		_check(label + ":reason_on_failure", result.get("reason") is String and not String(result.get("reason", "")).strip_edges().is_empty())
		_check(label + ":failure_not_changed", not result.get("changed", false))
	var numerical: Dictionary = {}
	var normalized: Dictionary = result.get("normalization", {})
	for key: String in ["oldHeight", "newHeight", "proposedHeight", "correction", "roundingBound", "roundingTerms", "absoluteCeiling",
		"oldBottom", "newBottom", "oldTop", "newTop", "bottomDisplacement", "topDisplacement", "foundationTop", "exactSharedPlane", "addedVolumes"]:
		if normalized.has(key): numerical[key] = normalized[key]
	var attempts: Array = result.get("fitAttempts", [])
	_check(label + ":attempt_evidence_bounded", attempts.size() <= 64)
	evidence.append({"case": label, "ready": result.get("ready", false), "changed": result.get("changed", false),
		"bearingId": result.get("bearingId", ""), "partId": result.get("partId", ""), "reason": String(result.get("reason", "")).left(2048),
		"normalization": numerical, "contact": result.get("contact", {}),
		"fullFootprintRejection": result.get("fullFootprintRejection", {}), "fitAttempts": attempts.slice(0, 64),
		"attemptsTruncated": attempts.size() > 64})
	return result


func _positive(f: Dictionary, label: String) -> void:
	var before_b = Copy.copy_blueprint(f.snapshot)
	var foundation = before_b.find_part(f.ownership.threshold.foundationId)
	var threshold = before_b.find_part(f.ownership.threshold.id)
	var door = before_b.find_part(f.ownership.doorId)
	_check(label + ":actual_source_planes", is_equal_approx(foundation.position.y + foundation.size.y * 0.5, threshold.position.y - threshold.size.y * 0.5)
		and is_equal_approx(door.position.y - door.size.y * 0.5, threshold.position.y - threshold.size.y * 0.5))
	_check(label + ":grounded_foundation_real_gap", before_b.is_grounded_structural_root(foundation)
		and not before_b.transformed_parts_overlap(foundation, threshold, Blueprint.PHYSICAL_CONTACT_MARGIN)
		and door.rotation == Vector3.ZERO and not threshold.collision_enabled)
	var before := _validate(before_b)
	_check(label + ":baseline_threshold_fails", not _row(before, threshold.id).get("passed", true))
	var result := _prepare(f, label)
	_check(label + ":proposal_ready_changed", result.get("ready", false) and result.get("changed", false))
	if not result.get("ready", false) or not result.get("afterSnapshot") is Dictionary:
		return
	var bearing_id := String(result.get("bearingId", ""))
	_check(label + ":new_bearing_identity", not bearing_id.is_empty() and before_b.find_part(bearing_id) == null)
	var after: Dictionary = result.afterSnapshot
	_check(label + ":only_bearing_and_required_anchor_added", _preserved(f.snapshot, after, threshold.id, bearing_id))
	var b = Copy.copy_blueprint(after)
	var bearing = b.find_part(bearing_id)
	_check(label + ":bearing_exists", bearing != null)
	if bearing == null: return
	_check(label + ":ordinary_root_not_forced", bearing.collision_enabled and bearing.kind == "foundation"
		and b.is_grounded_structural_root(bearing) and not bool(bearing.recipe.get("physicalRoot", false)))
	_check(label + ":door_frame_and_sweep_clear", _door_clear(b, bearing))
	_check(label + ":independent_exact_contact_and_planes", _exact_construction(f.snapshot, after, threshold.id, bearing_id, result))
	var physical := _validate(b)
	_check(label + ":real_physical_validator_passes", physical.get("passed", false))
	_check(label + ":threshold_requires_bearing", _row(physical, threshold.id).get("requiredAnchorPartIds", []).has(bearing_id))
	var repeat := _prepare(f, label + "_repeat")
	_check(label + ":repeat_byte_exact", var_to_bytes(result) == var_to_bytes(repeat))
	var repeated_validation: Dictionary = b.validate_physical_integrity()
	_check(label + ":warm_validator_same_decisions", _decisions(physical) == _decisions(repeated_validation))
	_check(label + ":cleared_validator_same_decisions", _decisions(physical) == _decisions(_validate(b)))
	var warm := {"snapshot": before_b.snapshot(), "ownership": f.ownership.duplicate(true)}
	var cached := _prepare(warm, label + "_warm_source")
	_check(label + ":cached_source_same_proposal", cached.get("ready", false) and cached.get("changed", false)
		and cached.get("bearingId", "") == bearing_id and _bearing_record(cached, bearing_id) == _bearing_record(result, bearing_id))
	var again := _prepare({"snapshot": after, "ownership": f.ownership}, label + "_already_proposed")
	_check(label + ":reprepare_no_op", again.get("ready", false) and not again.get("changed", true)
		and var_to_bytes(again.get("afterSnapshot")) == var_to_bytes(after))
	if label == "positive_0":
		_bearing_controls(after, f.ownership, bearing_id)
		_furniture_controls(f, bearing)


func _preserved(before: Dictionary, after: Dictionary, threshold_id: String, bearing_id: String) -> bool:
	if not after.get("parts") is Array or after.parts.size() != before.parts.size() + 1: return false
	var restored := after.duplicate(true)
	var added: Array = restored.parts.filter(func(part): return part.id == bearing_id)
	if added.size() != 1: return false
	restored.parts.erase(added[0])
	for index in range(before.parts.size()):
		if restored.parts[index].id != before.parts[index].id: return false
		if restored.parts[index].id != threshold_id: continue
		var anchors: Variant = restored.parts[index].recipe.get("physicalRequiredAnchorPartIds")
		if not anchors is Array or anchors != [bearing_id]: return false
		restored.parts[index].recipe.erase("physicalRequiredAnchorPartIds")
		var old_size: Vector3 = before.parts[index].size
		var new_size: Vector3 = restored.parts[index].size
		if new_size.x != old_size.x or new_size.z != old_size.z or absf(float(new_size.y) - float(old_size.y)) > 0.000001: return false
		restored.parts[index].size = old_size
	return var_to_bytes(restored) == var_to_bytes(before)

func _exact_construction(before: Dictionary, after: Dictionary, threshold_id: String, bearing_id: String, result: Dictionary) -> bool:
	var original = Copy.copy_blueprint(before)
	var built = Copy.copy_blueprint(after)
	var old = original.find_part(threshold_id)
	var threshold = built.find_part(threshold_id)
	var bearing = built.find_part(bearing_id)
	var foundation = built.find_part(threshold_id.trim_suffix("_door_threshold") + "_foundation")
	if old == null or threshold == null or bearing == null or foundation == null: return false
	var lower: float = float(threshold.position.y) - float(threshold.size.y) * 0.5
	var upper: float = float(bearing.position.y) + float(bearing.size.y) * 0.5
	var ground: float = float(bearing.position.y) - float(bearing.size.y) * 0.5
	var foundation_top: float = float(foundation.position.y) + float(foundation.size.y) * 0.5
	var width: float = minf(float(threshold.position.x) + float(threshold.size.x) * 0.5, float(bearing.position.x) + float(bearing.size.x) * 0.5) \
		- maxf(float(threshold.position.x) - float(threshold.size.x) * 0.5, float(bearing.position.x) - float(bearing.size.x) * 0.5)
	var depth: float = minf(float(threshold.position.z) + float(threshold.size.z) * 0.5, float(bearing.position.z) + float(bearing.size.z) * 0.5) \
		- maxf(float(threshold.position.z) - float(threshold.size.z) * 0.5, float(bearing.position.z) - float(bearing.size.z) * 0.5)
	var delta := float(threshold.size.y) - float(old.size.y)
	var bound := 2.0 * (_ulp_from_exponent(old.position.y) + _ulp_from_exponent(foundation.position.y) + 0.5 * _ulp_from_exponent(foundation.size.y)) + _ulp_from_exponent(old.size.y)
	var normalization: Dictionary = result.get("normalization", {})
	return lower == upper and lower == foundation_top and ground == 0.0 and width > 0.0 and depth > 0.0 \
		and bearing.position.y == foundation.position.y and bearing.size.y == foundation.size.y \
		and absf(delta) <= bound and absf(delta) <= 0.000001 and normalization.get("roundingBound") == bound \
		and result.get("contact", {}).get("verticalGap") == 0.0 and result.contact.contactArea == width * depth \
		and normalization.get("oldHeight") == float(old.size.y) and normalization.get("newHeight") == float(threshold.size.y)

func _ulp_from_exponent(value: float) -> float:
	var bytes := PackedFloat32Array([absf(value)]).to_byte_array()
	var exponent: int = int((bytes.decode_u32(0) >> 23) & 255)
	return pow(2.0, -149.0 if exponent == 0 else float(exponent - 127 - 23))

func _normalization_controls() -> void:
	var excessive := _fixture()
	excessive.snapshot.parts[2].size.y -= 0.000004
	var rejected := _prepare(excessive, "excessive_plane_correction")
	_check("excessive_plane_correction:rejected", not rejected.ready and rejected.reason == "unrepresentable_threshold_construction_plane")
	var ieee := _fixture()
	ieee.snapshot.parts[2].size.y -= 0.0000006
	var ieee_rejected := _prepare(ieee, "ieee_only_excessive_correction")
	var numbers: Dictionary = ieee_rejected.get("normalization", {})
	_check("ieee_only_excessive_correction:independent_gate", not ieee_rejected.ready
		and ieee_rejected.reason == "unrepresentable_threshold_construction_plane"
		and absf(float(numbers.get("correction", INF))) <= 0.000001
		and absf(float(numbers.get("correction", 0.0))) > float(numbers.get("roundingBound", INF)))
	for owner: String in ["source", "reserved"]:
		var bad_bounds := _fixture()
		bad_bounds.snapshot.parts[2].size.y -= 0.0000001
		var protected: Array = []
		if owner == "source":
			var obstacle = Blueprint.BuildingPartScript.new({"id": "out_of_range_source", "kind": "decor", "collision": false,
				"physicalIntent": "visual_detail", "position": Vector3(100001, 1, 0), "size": Vector3(4, 1, 1)})
			bad_bounds.snapshot.parts.append(obstacle.snapshot())
		else:
			protected.append({"id": "out_of_range_reserved", "bounds": AABB(Vector3(99999, 0, 0), Vector3(4, 1, 1))})
		var blocked := _prepare(bad_bounds, "normalization_bad_" + owner + "_bounds", protected)
		_check("normalization_bad_" + owner + "_bounds:explicit_rejection", not blocked.ready
			and blocked.reason == "unsupported_threshold_normalization_" + owner + "_bounds")
	for face: String in ["bottom", "top"]:
		var f := _fixture()
		# A slightly undersized stored threshold requires growth at BOTH faces.
		f.snapshot.parts[2].size.y -= 0.0000001
		var threshold: Dictionary = f.snapshot.parts[2]
		var y: float = threshold.position.y + (threshold.size.y * 0.5 if face == "top" else -threshold.size.y * 0.5)
		var obstacle := [{"id": "changed_" + face, "bounds": AABB(Vector3(threshold.position.x - 0.1, y - 0.01, -0.1), Vector3(0.2, 0.02, 0.2))}]
		var blocked := _prepare(f, "changed_face_" + face, obstacle)
		_check("changed_face_" + face + ":admission_required", not blocked.ready and blocked.reason == "threshold_normalization_reserved_overlap"
			and blocked.get("partId") == "changed_" + face)


func _bearing_controls(after: Dictionary, ownership: Dictionary, bearing_id: String) -> void:
	for mode in ["missing", "disabled", "displaced", "ungrounded"]:
		var b = Copy.copy_blueprint(after)
		# Warm first: removing derived caches must not remove required declarations.
		b.validate_physical_integrity()
		var bearing = b.find_part(bearing_id)
		match mode:
			"missing": b.parts.erase(bearing)
			"disabled": bearing.collision_enabled = false
			"displaced": bearing.position.x += 20.0
			"ungrounded":
				# Translate the whole small assembly: all relative contact remains,
				# but no actual foundation bottom is on the ground plane anymore.
				for part in b.parts: part.position.y += 2.0
		var physical := _validate(b)
		var row := _row(physical, ownership.threshold.id)
		_check(mode + ":required_declaration_retained", row.get("requiredAnchorPartIds", []).has(bearing_id))
		_check(mode + ":dependent_rejected_by_real_validator", not row.get("passed", true) and not physical.get("passed", true))
		if mode == "ungrounded":
			_check(mode + ":contact_preserved_without_root", b.transformed_parts_overlap(bearing, b.find_part(ownership.threshold.id), Blueprint.PHYSICAL_CONTACT_MARGIN)
				and not b.is_grounded_structural_root(bearing) and not b.has_rooted_support_chain(bearing, {}))
		evidence.append({"case": mode, "violations": physical.get("violations", []).slice(0, 12)})


func _furniture_controls(f: Dictionary, bearing) -> void:
	# This API consumes already resolved reservation bounds, not furnishing parts.
	var furniture := [{"id": "synthetic_obstruction", "bounds": AABB(bearing.position - bearing.size * 0.5, bearing.size).grow(0.2)}]
	var blocked := _prepare(f, "furniture_blocked", furniture)
	_check("furniture_blocked:rejected", not blocked.get("ready", true) and blocked.get("partId") == "synthetic_obstruction")
	var clear_bounds: AABB = furniture[0].bounds
	clear_bounds.position.x += 30.0
	furniture[0].bounds = clear_bounds
	var clear := _prepare(f, "furniture_clear", furniture)
	_check("furniture_clear:ready", clear.get("ready", false) and clear.get("changed", false))
	var malformed := _prepare(f, "furniture_malformed", [{"position": Vector3.ZERO}])
	_check("furniture_malformed:rejected", not malformed.get("ready", true))


func _no_op() -> void:
	var f := _fixture()
	# An already rooted finish needs no additional geometry or declaration.
	f.snapshot.parts[2].position.x = 1.8
	var physical := _validate(Copy.copy_blueprint(f.snapshot))
	_check("already_valid:real_baseline_passes", physical.get("passed", false))
	var result := _prepare(f, "already_valid")
	_check("already_valid:exact_no_op", result.get("ready", false) and not result.get("changed", true)
		and var_to_bytes(result.get("afterSnapshot")) == var_to_bytes(f.snapshot))


func _identity_controls() -> void:
	for mode in ["empty_ownership", "wrong_prefix", "wrong_room", "wrong_door", "wrong_threshold", "wrong_foundation", "malformed_threshold",
		"foundation_semantic", "threshold_semantic", "door_semantic", "door_kind", "source_room_id", "missing_room", "duplicate_source_id",
		"room_not_urban", "duplicate_room", "missing_foundation", "ungrounded_foundation", "elevation_mismatch", "existing_obligation", "room_reserved", "access_reserved"]:
		var f := _fixture()
		match mode:
			"empty_ownership": f.ownership = {}
			"wrong_prefix": f.ownership.producerPrefix = "other_producer"
			"wrong_room": f.ownership.roomId = "other_interior"
			"wrong_door": f.ownership.doorId = f.ownership.threshold.id
			"wrong_threshold": f.ownership.threshold.id = f.ownership.threshold.foundationId
			"wrong_foundation": f.ownership.threshold.foundationId = f.ownership.doorId
			"malformed_threshold": f.ownership.threshold = "not_a_declaration"
			"foundation_semantic": f.snapshot.parts[0].semantic = "unrelated_foundation"
			"threshold_semantic": f.snapshot.parts[2].semantic = "unrelated_finish"
			"door_semantic": f.snapshot.parts[1].semantic = "unrelated_door"
			"door_kind": f.snapshot.parts[1].kind = "decor"
			"source_room_id": f.snapshot.parts[1].recipe.roomId = "other_interior"
			"missing_room": f.snapshot.rooms.clear()
			"duplicate_source_id": f.snapshot.parts.append(f.snapshot.parts[2].duplicate(true))
			"room_not_urban": f.snapshot.rooms[0].citadelUrbanRoom = false
			"duplicate_room": f.snapshot.rooms.append(f.snapshot.rooms[0].duplicate(true))
			"missing_foundation": f.snapshot.parts.remove_at(0)
			"ungrounded_foundation": f.snapshot.parts[0].position.y += 0.5
			"elevation_mismatch": f.snapshot.parts[2].position.y += 0.1
			"existing_obligation": f.snapshot.parts[2].recipe["physicalRequiredAnchorPartIds"] = ["missing_required_anchor"]
			"room_reserved": f.snapshot.rooms[0].bounds = AABB(Vector3(2, 0, -2), Vector3(2, 2, 4))
			"access_reserved": f.snapshot.rooms[0].accesses = [{"id": "blocked_entry", "position": Vector3(2.76, 0, 0), "size": Vector3(2, 2, 3)}]
		var result := _prepare(f, mode)
		_check(mode + ":rejected", not result.get("ready", true))


func _production_door_control() -> void:
	for index in range(2):
		var f := _fixture(index, true)
		var label := "production_shaped_door_%d" % index
		var result := _prepare(f, label)
		# Production dimensions/relative offsets, NOT an actual generated house.
		# Retain the old full-footprint refusal; the fitted proposal must actually
		# clear the same unchanged frame and complete sweep with exact contact.
		var expected_name := "frameRight" if index == 0 else "frameLeft"
		var primitive_id: String = "door:" + f.ownership.doorId + ":" + expected_name
		var refusal: Dictionary = result.get("fullFootprintRejection", {})
		_check(label + ":actual_frame_refusal_retained", refusal.get("reason") == "threshold_bearing_reserved_overlap" and refusal.get("partId") == primitive_id)
		_check(label + ":fitting_succeeds", result.get("ready", false) and result.get("changed", false))
		if result.get("ready", false):
			var fitted = Copy.copy_blueprint(result.afterSnapshot)
			_check(label + ":fitted_clear_exact_preserved", _door_clear(fitted, fitted.find_part(result.bearingId))
				and _preserved(f.snapshot, result.afterSnapshot, f.ownership.threshold.id, result.bearingId)
				and _exact_construction(f.snapshot, result.afterSnapshot, f.ownership.threshold.id, result.bearingId, result)
				and _validate(fitted).get("passed", false))
			var repeated := _prepare(f, label + "_repeat")
			_check(label + ":fitting_repeat_exact", var_to_bytes(result) == var_to_bytes(repeated))
		var b = Copy.copy_blueprint(f.snapshot)
		var door = b.find_part(f.ownership.doorId)
		var pieces: Array = Door.ordinary_sweep_bounds(door.size, b.part_transform(door))
		_check(label + ":named_primitive_exists", pieces.any(func(piece): return piece.name == expected_name and not piece.moving))


func _rotated_obstacle_control() -> void:
	var f := _fixture()
	var threshold: Dictionary = f.snapshot.parts[2]
	var obstacle = Blueprint.BuildingPartScript.new({"id": "rotated_elongated_obstacle", "kind": "decor", "collision": false,
		"physicalIntent": "visual_detail", "position": Vector3(threshold.position.x + 1.7, 0.31, 0),
		"size": Vector3(0.12, 0.12, 4.0), "rotation": Vector3(0, PI * 0.5, 0)})
	f.snapshot.parts.append(obstacle.snapshot())
	var result := _prepare(f, "rotated_elongated_obstacle")
	var refusal: Dictionary = result.get("fullFootprintRejection", {})
	_check("rotated_elongated_obstacle:source_geometry_rejected", refusal.get("ready") == false
		and refusal.get("reason") == "threshold_bearing_source_overlap" and refusal.get("partId") == obstacle.id)
	_check("rotated_elongated_obstacle:clear_reduced_fit", result.get("ready") == true)
	if result.get("ready", false):
		var fitted = Copy.copy_blueprint(result.afterSnapshot)
		var bearing = fitted.find_part(result.bearingId)
		var actual_obstacle = fitted.find_part(obstacle.id)
		var measurement := Admission.measure(fitted.part_transform(bearing), fitted.part_transform(actual_obstacle))
		_check("rotated_elongated_obstacle:actual_fit_clear", measurement.valid and measurement.clear
			and result.contact.contactArea > 0.0 and result.contact.contactArea < float(threshold.size.x) * float(threshold.size.z)
			and _door_clear(fitted, bearing) and _validate(fitted).get("passed", false))
		_check("rotated_elongated_obstacle:source_preserved", _preserved(f.snapshot, result.afterSnapshot, f.ownership.threshold.id, result.bearingId)
			and _exact_construction(f.snapshot, result.afterSnapshot, f.ownership.threshold.id, result.bearingId, result))
		_check("rotated_elongated_obstacle:deterministic", var_to_bytes(result) == var_to_bytes(_prepare(f, "rotated_obstacle_repeat")))
	# Cover the entire footprint with the same rotated source family: no fit
	# may turn this genuine obstruction into an accepted proposal.
	f.snapshot.parts[-1].size = Vector3(4.0, 0.12, 4.0)
	f.snapshot.parts[-1].position.x = threshold.position.x
	var blocked := _prepare(f, "rotated_full_cover")
	_check("rotated_full_cover:rejected", blocked.get("ready") == false and not blocked.has("afterSnapshot")
		and blocked.get("reason") == "threshold_bearing_source_overlap" and blocked.get("partId") == obstacle.id)


func _swing_controls() -> void:
	var f := _fixture()
	var threshold: Dictionary = f.snapshot.parts[2]
	# This auxiliary upright door swings away by default, but the opposite
	# declared swing enters the plinth. Closed geometry is clear in both cases.
	var door = Blueprint.BuildingPartScript.new({"id": "swing_obstacle", "kind": "door", "collision": true,
		"physicalIntent": "portal", "position": Vector3(threshold.position.x + 0.7, 1.25, threshold.size.z * 0.5 + 0.35),
		"size": Vector3(1.4, 2.5, 0.1), "recipe": {"openSwing": Door.DEFAULT_OPEN_SWING}})
	f.snapshot.parts.append(door.snapshot())
	var away := _prepare(f, "declared_default_swing")
	_check("declared_default_swing:ready", away.get("ready", false) and away.get("changed", false))
	if away.get("ready", false):
		var b = Copy.copy_blueprint(away.afterSnapshot)
		_check("declared_default_swing:independent_clearance", _door_clear(b, b.find_part(away.bearingId)))
	f.snapshot.parts[-1].recipe.openSwing = -Door.DEFAULT_OPEN_SWING
	var toward := _prepare(f, "opposite_declared_swing")
	var rejected_full: Dictionary = toward.get("fullFootprintRejection", toward)
	_check("opposite_declared_swing:original_candidate_rejected", rejected_full.get("reason") == "threshold_bearing_reserved_overlap"
		and String(rejected_full.get("partId", "")).begins_with("door:swing_obstacle:DoorBoard_"))
	if toward.get("ready", false):
		var fitted = Copy.copy_blueprint(toward.afterSnapshot)
		_check("opposite_declared_swing:fitted_candidate_clear_exact", _door_clear(fitted, fitted.find_part(toward.bearingId))
			and _exact_construction(f.snapshot, toward.afterSnapshot, f.ownership.threshold.id, toward.bearingId, toward))
	else:
		_check("opposite_declared_swing:no_fit_explicit", toward.get("noFeasibleFit", false))
	var malformed: Array = [null, "1.0", true, {}, INF, NAN, PI + 0.01]
	for index in range(malformed.size()):
		f.snapshot.parts[-1].recipe.openSwing = malformed[index]
		var rejected := _prepare(f, "malformed_swing_%d" % index)
		_check("malformed_swing_%d:rejected" % index, not rejected.get("ready", true) and rejected.get("reason") == "invalid_threshold_door_swing")


func _door_clear(b, bearing) -> bool:
	if bearing == null: return false
	var pose := Transform3D(Basis.from_euler(bearing.rotation) * Basis.from_scale(bearing.size), bearing.position)
	for part in b.parts:
		if part.kind != "door": continue
		var primitives: Array = Door.closed_primitives(part.size, b.part_transform(part))
		var swing: Variant = part.recipe.get("openSwing", Door.DEFAULT_OPEN_SWING)
		if not (swing is float or swing is int) or not is_finite(float(swing)) or absf(float(swing)) > PI: return false
		primitives.append_array(Door.ordinary_sweep_bounds(part.size, b.part_transform(part), float(swing)))
		if primitives.is_empty(): return false
		for primitive in primitives:
			var bounds: AABB = primitive.bounds
			var measured := Admission.measure(pose, Transform3D(Basis.from_scale(bounds.size), bounds.get_center()))
			if not measured.valid or not measured.clear: return false
	return true


func _bearing_record(result: Dictionary, bearing_id: String) -> Array:
	return result.get("afterSnapshot", {}).get("parts", []).filter(func(part): return part.id == bearing_id)


func _validate(b) -> Dictionary:
	Copy.clear_caches(b)
	return b.validate_physical_integrity()


func _row(report: Dictionary, id: String) -> Dictionary:
	for row in report.get("checks", []):
		if row.get("partId", "") == id: return row
	return {}


func _decisions(report: Dictionary) -> PackedByteArray:
	var copy := report.duplicate(true)
	# Classification provenance changes on revalidation; physical facts may not.
	for row in copy.get("checks", []): row.erase("classification")
	return var_to_bytes(copy)


func _fresh_path(path: String) -> bool:
	return path.is_absolute_path() and not path.contains("://") and path.get_extension().to_lower() == "json" \
		and DirAccess.dir_exists_absolute(path.get_base_dir()) \
		and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)


func _check(id: String, passed: bool) -> void:
	checks.append({"id": id, "passed": passed})
	if not passed: push_error("Threshold bearing contract failed: " + id)
