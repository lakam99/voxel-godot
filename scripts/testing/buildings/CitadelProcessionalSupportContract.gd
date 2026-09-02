extends SceneTree

## Small synthetic source/service fixture calling the actual public producer.
## Not full-Citadel, published geometry, physics, route or gameplay acceptance.
## VOXEL_PROCESSIONAL_SUPPORT_REPORT: fresh absolute JSON; parent must exist.
## Optional VOXEL_PROCESSIONAL_FULL_CITADEL=1: fresh seed208159, scale1.25.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Landmark = preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const CACHE_KEYS := ["physicalRoot", "physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]
var _checks: Array = []
var _full: Dictionary = {"requested": false}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_PROCESSIONAL_SUPPORT_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	# Ascending and descending variations remain above their actual foundation.
	_transition_recipe_contracts()
	var variations := [Vector2(0.0, 1.8), Vector2(1.8, 3.6), Vector2(2.2, 0.5), Vector2(0.3, 0.9)]
	for index in range(variations.size()):
		_positive(_fixture(index, variations[index]), "producer_%02d" % index)
	for index in range(2):
		# Deliberately below the foundation/ground, not a small supported inset.
		var elevations := Vector2(-4.0, -3.0) if index == 0 else Vector2(0.0, -4.0)
		var fixture := _fixture(20 + index, elevations)
		_clear(fixture.b)
		var physical: Dictionary = fixture.b.validate_physical_integrity()
		_check("negative_elevations_%d:no_valid_complete_staircase" % index, not _complete_pass(fixture, physical), physical.violations)
	var absent := _fixture(30, Vector2(0.0, 1.8), false)
	_clear(absent.b)
	var absent_physical: Dictionary = absent.b.validate_physical_integrity()
	_check("producer_without_foundation:no_valid_complete_staircase", not _complete_pass(absent, absent_physical), absent_physical.violations)
	if OS.get_environment("VOXEL_PROCESSIONAL_FULL_CITADEL") == "1": _full_citadel()
	var passed: bool = not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var report := {"fixture": "CitadelProcessionalSupportContract", "passed": passed, "checks": _checks, "fullCitadel": _full,
		"evidenceLevel": "synthetic_actual_producer_source_service_contract",
		"doesNotProve": "No full Citadel coverage, published mesh preservation, live collision, navigation or gameplay acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("Processional support source contract: %s (%d checks)" % ["PASS" if passed else "FAIL", _checks.size()])
	quit(2 if error != OK else (0 if passed else 1))

func _transition_recipe_contracts() -> void:
	var palace := {"entryApproach": {"routeTerminalZ": 18.0, "rampStartZ": 14.0}}
	for case in [
		{"label": "minimum_width_right", "gateWidth": 12.0, "routeSign": 1.0},
		{"label": "interior_width_left", "gateWidth": 17.0, "routeSign": -1.0},
		{"label": "maximum_width_right", "gateWidth": 24.0, "routeSign": 1.0}
	]:
		var grid: Dictionary = Landmark.castle_courtyard_occupancy_lattice(96.0, 104.0, 30.0, 24.0, 0.18, float(case.gateWidth), 13.0, true, float(case.routeSign), palace)
		var repeated: Dictionary = Landmark.castle_courtyard_occupancy_lattice(96.0, 104.0, 30.0, 24.0, 0.18, float(case.gateWidth), 13.0, true, float(case.routeSign), palace)
		var label := "transition_recipe_" + String(case.label)
		_check(label + ":deterministic", var_to_bytes(grid) == var_to_bytes(repeated))
		var transitions: Array = grid.get("processionalTransitions", []) as Array
		_check(label + ":two_explicit_ordered_transitions", transitions.size() == 2 and int((transitions[0] as Dictionary).get("ordinal", -1)) == 0 and int((transitions[1] as Dictionary).get("ordinal", -1)) == 1)
		if transitions.size() != 2:
			continue
		var terrace_height := float(grid.get("terraceStepHeight", 0.0))
		var first: Dictionary = transitions[0] as Dictionary
		var second: Dictionary = transitions[1] as Dictionary
		_check(label + ":elevation_chain", is_equal_approx(float(first.fromElevation), 0.0) and is_equal_approx(float(first.toElevation), terrace_height) and is_equal_approx(float(second.fromElevation), terrace_height) and is_equal_approx(float(second.toElevation), terrace_height * 2.0))
		var exact_bounds := true
		for transition in transitions:
			var descriptor: Dictionary = transition as Dictionary
			var center_z := float(descriptor.centerZ)
			exact_bounds = exact_bounds and is_equal_approx(float(descriptor.startZ), center_z - 7.0 * 0.48 - 0.26) and is_equal_approx(float(descriptor.endZ), center_z - 0.48 + 0.26) and is_equal_approx(float(descriptor.endZ) - float(descriptor.startZ), 6.0 * 0.48 + 0.52)
		_check(label + ":physical_tread_bounds", exact_bounds)
		var records: Dictionary = {}
		for record_value in grid.get("streetRecords", []) as Array:
			var record: Dictionary = record_value as Dictionary
			records[String(record.id)] = record
		var approach_a: Dictionary = records.get("processional_02a_civic_approach", {}) as Dictionary
		var climb: Dictionary = records.get("processional_02b_civic_climb", {}) as Dictionary
		var approach_b: Dictionary = records.get("processional_04a_palace_approach", {}) as Dictionary
		var intervals_positive := float(approach_a.get("depth", 0.0)) > 0.20 and float(climb.get("depth", 0.0)) > 0.20 and float(approach_b.get("depth", 0.0)) > 0.20
		_check(label + ":positive_unmasked_road_intervals", intervals_positive)
		_check(label + ":roads_meet_physical_stair_bounds", is_equal_approx(float(approach_a.z) + float(approach_a.depth) * 0.5, float(first.startZ)) and is_equal_approx(float(climb.z) - float(climb.depth) * 0.5, float(first.endZ)) and is_equal_approx(float(approach_b.z) + float(approach_b.depth) * 0.5, float(second.startZ)))

func _fixture(index: int, elevations: Vector2, include_foundation := true) -> Dictionary:
	var b := Blueprint.new("processional_source_%02d" % index, 410 + index, "stone")
	var prefix := "processional_%02d" % index
	var center_x := -3.75 + float(index) * 0.31
	var center_z := 8.125 - float(index) * 0.17
	var width := 3.4 + float(index % 3) * 0.7
	var foundation_height := 0.62 + float(index % 3) * 0.13
	var variation := -0.09 + float(index % 4) * 0.04
	var root_id := prefix + "_source_foundation"
	if include_foundation:
		b.add_part({"id": root_id, "kind": "foundation", "material": "stone_foundation",
			"position": Vector3(center_x, foundation_height * 0.5, center_z - 1.92),
			"size": Vector3(width + 2.0, foundation_height, 6.0), "collision": true,
			"semantic": "castle_courtyard_foundation", "physicalIntent": "structural_mass"})
	Castle.add_citadel_processional_steps(b, prefix, center_x, center_z, width, elevations.x, elevations.y, foundation_height, variation)
	return {"b": b, "prefix": prefix, "rootId": root_id, "x": center_x, "z": center_z,
		"width": width, "foundationY": foundation_height, "variation": variation, "elevations": elevations}

func _positive(fixture: Dictionary, label: String) -> void:
	var b = fixture.b
	var original_geometry := _geometry(b)
	_check(label + ":seven_actual_producer_treads", _steps(fixture).size() == 7)
	for index in range(7):
		var part = _find(b, "%s_%02d" % [fixture.prefix, index + 1])
		_check(label + ":tread_%d_exists" % index, part != null)
		if part == null: continue
		# Independent expected producer geometry, not a second call to production.
		var progress := float(index + 1) / 7.0
		var height := lerpf(fixture.elevations.x, fixture.elevations.y, progress) + 0.14 * progress
		var position := Vector3(fixture.x, fixture.foundationY + height * 0.5, fixture.z - 0.48 * float(7 - index))
		var size := Vector3(fixture.width, maxf(0.12, height), 0.48 + 0.04)
		_check(label + ":tread_%d_exact_geometry_and_identity" % index,
			part.position == position and part.size == size and part.rotation == Vector3.ZERO and part.kind == "foundation" and part.material_id == "stone_foundation" and part.semantic == "castle_processional_step" and part.collision_enabled and part.recipe.get("navigationRole") == "walkable_support" and part.recipe.get("variation") == fixture.variation - 0.04)
		_check(label + ":tread_%d_elevated_coverage_contract" % index, part.physical_intent == "structural_mass" and part.recipe.get("physicalAssemblyRole") == "walkable_subfloor" and not part.recipe.get("physicalRoot", false))
	var fresh: Dictionary = b.validate_physical_integrity()
	_check(label + ":fresh_valid", _complete_pass(fixture, fresh), fresh.violations)
	_route_roots(fixture, label + ":fresh")
	var repeated: Dictionary = b.validate_physical_integrity()
	_check(label + ":repeat_same_valid_physical", _complete_pass(fixture, repeated) and _facts(fresh) == _facts(repeated), repeated.violations)
	_clear(b)
	var cleared: Dictionary = b.validate_physical_integrity()
	_check(label + ":cacheclear_same_valid_physical", _complete_pass(fixture, cleared) and _facts(fresh) == _facts(cleared), cleared.violations)
	_route_roots(fixture, label + ":cacheclear")
	_check(label + ":validation_preserves_all_geometry", original_geometry == _geometry(b))
	# Remove a genuinely needed source support AFTER successful resolution; stale
	# dependency/root metadata must not rescue the seven unchanged elevated steps.
	var root = _find(b, fixture.rootId)
	b.parts.erase(root)
	_clear(b)
	var missing: Dictionary = b.validate_physical_integrity()
	var failed_steps: Array = missing.checks.filter(func(check): return String(check.partId).begins_with(fixture.prefix + "_") and not bool(check.passed))
	_check(label + ":removed_foundation_all_seven_fail", _steps(fixture).size() == 7 and not missing.passed and failed_steps.size() == 7, missing.violations)

func _route_roots(fixture: Dictionary, label: String) -> void:
	var b = fixture.b
	for step in _steps(fixture):
		var ids: Variant = step.recipe.get("routeTransitionRootPartIds", [])
		var valid: bool = ids is Array and not ids.is_empty() and not ids.has(step.id)
		var seen: Dictionary = {}
		if ids is Array:
			var sorted_ids: Array = ids.duplicate()
			sorted_ids.sort()
			valid = valid and ids == sorted_ids and ids == step.recipe.get("physicalRequiredSeatPartIds", [])
			for id in ids:
				var root = _find(b, String(id))
				valid = valid and not seen.has(id) and root != null
				seen[id] = true
				if root != null:
					valid = valid and b.is_grounded_structural_root(root) and root.collision_enabled and b.transformed_parts_overlap(step, root, Blueprint.PHYSICAL_CONTACT_MARGIN)
		_check(label + ":actual_nonself_roots:" + step.id, valid)
		# The route query explicitly rejects the outer 0.015m rim. Query its
		# interior domain; structural validation above still covers all 25 edge
		# and interior bearing samples without an inset or changed tolerance.
		var samples_valid := true
		for sample in b.footprint_bottom_samples(step, 3):
			var point: Vector3 = step.position + (sample.position - step.position) * Vector3(0.8, 1.0, 0.8)
			var top_y: float = Castle.part_top_y_at(step, point.x, point.z)
			var support: Dictionary = Castle.transition_root_support_owner_at(b, {"partId": step.id, "topY": top_y}, Vector3(point.x, top_y, point.z))
			samples_valid = samples_valid and support.get("rooted", false) and support.get("collisionEnabled", false) and support.get("partId", "") != step.id
		_check(label + ":route_support_samples:" + step.id, samples_valid)

func _complete_pass(fixture: Dictionary, physical: Dictionary) -> bool:
	return _steps(fixture).size() == 7 and physical.passed and physical.checkedPartCount == fixture.b.parts.size()

func _full_citadel() -> void:
	_full = {"requested": true, "seed": 208159, "scale": 1.25, "passed": false,
		"scope": "Fresh ordinary Castle.build + Urban.compose, not the frozen reviewed shop/roof candidate. Existing unrelated physical failures remain reported, not accepted."}
	var first_check := _checks.size()
	var b = Castle.build(208159, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	if b != null: b = Urban.compose(b, 208159)
	_check("full_citadel_source_exists", b != null)
	if b == null: return
	var stair_ids: Array = []
	for part in b.parts:
		if part.semantic == "castle_processional_step": stair_ids.append(part.id)
	_check("full_citadel_has_actual_staircases", not stair_ids.is_empty() and stair_ids.size() % 7 == 0)
	var geometry_before := _geometry(b)
	var furniture_before = Furniture.build(b, 208159 * 7919 + 37)
	var furniture_bytes := PackedByteArray() if furniture_before == null else var_to_bytes(furniture_before.snapshot())
	_full["furnitureBeforeCount"] = 0 if furniture_before == null else furniture_before.parts.size()
	_check("full_citadel_furniture_154", _full.furnitureBeforeCount == 154)
	var fresh: Dictionary = b.validate_physical_integrity()
	var repeated: Dictionary = b.validate_physical_integrity()
	_clear(b)
	var cleared: Dictionary = b.validate_physical_integrity()
	for phase in [{"name": "fresh", "report": fresh}, {"name": "repeated", "report": repeated}, {"name": "cacheCleared", "report": cleared}]:
		var physical: Dictionary = phase.report
		var stair_checks: Array = physical.checks.filter(func(check): return stair_ids.has(check.partId))
		_full[phase.name] = {"wholePhysicalGatePassed": physical.passed, "failureCount": physical.violations.size(),
			"violations": physical.violations, "stairChecks": stair_checks}
		_check("full_citadel_" + phase.name + "_all_stairs_pass", stair_checks.size() == stair_ids.size() and stair_checks.all(func(check): return bool(check.passed)), physical.violations.filter(func(value): return String(value).begins_with("castle_terrace_stair_")))
	_check("full_citadel_repeat_same_physical", _facts(fresh) == _facts(repeated))
	_check("full_citadel_cacheclear_same_physical", _facts(fresh) == _facts(cleared))
	_check("full_citadel_recipe_has_no_stale_raised_route_coverage", not b.recipe.has("raisedRouteCoverage"))
	# Keep the existing raised-route contract authoritative, including its own
	# detailed failures; no alternate predicate or relaxed seam tolerance.
	var route: Dictionary = Castle.validate_raised_route_coverage(b)
	var repeated_route: Dictionary = Castle.validate_raised_route_coverage(b)
	_full["raisedRouteCoverage"] = route
	_full["streetRecords"] = (((b.recipe.get("castleGrammar", {}) as Dictionary).get("courtyardGrid", {}) as Dictionary).get("streetRecords", []) as Array).duplicate(true)
	_full["routeCollisionParts"] = b.parts.filter(func(part): return part != null and part.collision_enabled and String(part.semantic) in ["castle_route_terrace_walkway", "castle_route_junction", "castle_processional_step", "castle_keep_palace_entry_forecourt"]).map(func(part): return part.snapshot())
	_check("full_citadel_actual_raised_route_coverage", route.get("passed", false) and (route.get("violations", []) as Array).is_empty(), route.get("violations", []))
	_check("full_citadel_repeat_raised_route_coverage_byte_exact", var_to_bytes(route) == var_to_bytes(repeated_route))
	var palace_approach_rows: Array = (route.get("records", []) as Array).filter(
		func(record): return record is Dictionary and String(record.get("streetId", "")) == "processional_04a_palace_approach")
	_check("full_citadel_exactly_one_palace_approach_coverage", palace_approach_rows.size() == 1)
	if palace_approach_rows.size() == 1:
		var palace_approach: Dictionary = palace_approach_rows[0] as Dictionary
		var handoff: Dictionary = palace_approach.get("handoffSeam", {}) as Dictionary
		var roadbed: Dictionary = handoff.get("roadbed", {}) as Dictionary
		var transition: Dictionary = handoff.get("transition", {}) as Dictionary
		_check("full_citadel_palace_approach_handoff_finite_within_existing_limit",
			bool(palace_approach.get("passed", false)) and bool(handoff.get("declared", false)) and bool(handoff.get("passed", false)) \
			and is_finite(float(handoff.get("contactGap", INF))) and float(handoff.get("contactGap", INF)) <= float(handoff.get("contactGapLimit", -INF)))
		_check("full_citadel_palace_approach_exact_generated_owners",
			String(roadbed.get("ownerId", "")) == "castle_district_route_junction_04" \
			and String(transition.get("ownerId", "")) == "castle_terrace_stair_01_01")
		_check("full_citadel_palace_approach_sides_collision_rooted_and_passed",
			[roadbed, transition].all(func(side: Dictionary) -> bool:
				return bool(side.get("passed", false)) and bool(side.get("ownerCollisionEnabled", false)) \
					and bool(side.get("rootSupportCollisionEnabled", false)) and bool(side.get("rootSupportRooted", false))))
	_check("full_citadel_transported_snapshot_recursively_finite", _snapshot_is_finite(b.snapshot()))
	# Read-only historical comparison; never substitutes for the live candidate
	# check above. Keep both failures visible, even if they predate this recipe.
	var reference_path := OS.get_environment("VOXEL_PROCESSIONAL_REVIEWED_BASELINE")
	if not reference_path.is_empty():
		if FileAccess.get_sha256(reference_path) != "e43b972eface80bbcbc015ef55ac0c21a5cb99083dcfa9aabbb5a407f9832038":
			_check("reviewed_baseline_hash", false)
		else:
			var reference_file := FileAccess.open(reference_path, FileAccess.READ)
			var reference: Dictionary = reference_file.get_var(false)
			reference_file.close()
			var historical = preload("res://scripts/buildings/CitadelShopRecipe.gd").copy_source(reference.sourceSnapshot)
			_full["reviewedUnchangedRaisedRouteCoverage"] = Castle.validate_raised_route_coverage(historical)
			_full["raisedRouteViolationsExactlyMatchReviewed"] = route.violations == _full.reviewedUnchangedRaisedRouteCoverage.violations
	var furniture_after = Furniture.build(b, 208159 * 7919 + 37)
	_full["furnitureAfterCount"] = 0 if furniture_after == null else furniture_after.parts.size()
	_check("full_citadel_furniture_exact_after_validation", furniture_after != null and _full.furnitureAfterCount == 154 and furniture_bytes == var_to_bytes(furniture_after.snapshot()))
	_check("full_citadel_validation_preserves_geometry", geometry_before == _geometry(b))
	_full["passed"] = _checks.slice(first_check).all(func(check): return bool(check.passed))

func _steps(fixture: Dictionary) -> Array:
	return fixture.b.parts.filter(func(part): return part.semantic == "castle_processional_step")

func _clear(b) -> void:
	for part in b.parts:
		for key in CACHE_KEYS: part.recipe.erase(key)

func _facts(report: Dictionary) -> PackedByteArray:
	# Classification records inference history, not a physical outcome.
	var copy: Dictionary = report.duplicate(true)
	for check in copy.checks: check.erase("classification")
	return var_to_bytes(copy)

func _geometry(b) -> PackedByteArray:
	var records: Array = []
	for part in b.parts:
		var record: Dictionary = part.snapshot()
		record.erase("physicalIntent")
		record.erase("recipe")
		record["variation"] = part.recipe.get("variation")
		record["navigationRole"] = part.recipe.get("navigationRole")
		records.append(record)
	return var_to_bytes(records)

func _find(b, id: String):
	for part in b.parts:
		if part.id == id: return part
	return null


func _snapshot_is_finite(value: Variant, depth := 0) -> bool:
	if depth > 64:
		return false
	match typeof(value):
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_VECTOR2:
			return (value as Vector2).is_finite()
		TYPE_VECTOR3:
			return (value as Vector3).is_finite()
		TYPE_VECTOR4:
			return (value as Vector4).is_finite()
		TYPE_QUATERNION:
			return (value as Quaternion).is_finite()
		TYPE_COLOR:
			var color: Color = value
			return is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and is_finite(color.a)
		TYPE_RECT2:
			var rect: Rect2 = value
			return rect.position.is_finite() and rect.size.is_finite()
		TYPE_AABB:
			var bounds: AABB = value
			return bounds.position.is_finite() and bounds.size.is_finite()
		TYPE_TRANSFORM2D:
			var transform_2d: Transform2D = value
			return transform_2d.x.is_finite() and transform_2d.y.is_finite() and transform_2d.origin.is_finite()
		TYPE_TRANSFORM3D:
			var transform_3d: Transform3D = value
			return transform_3d.origin.is_finite() and transform_3d.basis.x.is_finite() \
				and transform_3d.basis.y.is_finite() and transform_3d.basis.z.is_finite()
		TYPE_BASIS:
			var basis: Basis = value
			return basis.x.is_finite() and basis.y.is_finite() and basis.z.is_finite()
		TYPE_PLANE:
			var plane: Plane = value
			return plane.normal.is_finite() and is_finite(plane.d)
		TYPE_PROJECTION:
			var projection: Projection = value
			return projection.x.is_finite() and projection.y.is_finite() and projection.z.is_finite() and projection.w.is_finite()
		TYPE_ARRAY:
			for child in value:
				if not _snapshot_is_finite(child, depth + 1):
					return false
		TYPE_DICTIONARY:
			for key in value:
				if not _snapshot_is_finite(key, depth + 1) or not _snapshot_is_finite(value[key], depth + 1):
					return false
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			for number in value:
				if not is_finite(number):
					return false
		TYPE_PACKED_VECTOR2_ARRAY:
			for vector in value:
				if not (vector as Vector2).is_finite():
					return false
		TYPE_PACKED_VECTOR3_ARRAY:
			for vector in value:
				if not (vector as Vector3).is_finite():
					return false
		TYPE_PACKED_VECTOR4_ARRAY:
			for vector in value:
				if not (vector as Vector4).is_finite():
					return false
		TYPE_PACKED_COLOR_ARRAY:
			for color_value in value:
				var packed_color: Color = color_value
				if not is_finite(packed_color.r) or not is_finite(packed_color.g) or not is_finite(packed_color.b) or not is_finite(packed_color.a):
					return false
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return false
	return true

func _check(label: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": label, "passed": passed, "detail": detail})

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
