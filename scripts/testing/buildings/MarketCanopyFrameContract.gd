extends SceneTree

## Synthetic source/service contract only. No composer, publisher, scenes,
## actors, physics frames, placement or navigation. Prepared without engine run.
## To run later: --headless --path <project> --script <this resource>.
## VOXEL_MARKET_CANOPY_FRAME_REPORT must name a NEW absolute JSON destination.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Frame = preload("res://scripts/buildings/MarketCanopyFrameBuilder.gd")
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
var _checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_MARKET_CANOPY_FRAME_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path):
		printerr("Market canopy contract requires a new absolute report path")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var positive_count := 0
	for scale_value in [0.9, 1.0, 1.25, 1.5]:
		for yaw in [0.0, PI * 0.5, -PI * 0.5, 0.37]:
			for elevated in [false, true]:
				positive_count += 1
				_positive(_fixture(scale_value, yaw, elevated), "shape_%d" % positive_count)
	_record("positive_matrix_complete", positive_count == 32)
	for mode in ["missing_member", "duplicate_member", "missing_ridge", "duplicate_ridge_semantic", "missing_support", "support_is_household", "duplicate_source_id", "nonfinite_member", "zero_member_size", "nonfinite_rotation", "wrong_material", "colliding_knee", "visual_detail_knee", "forged_knee_root", "existing_joint", "tilted_ridge", "shifted_knee", "duplicate_quadrant", "ridge_too_short", "seat_above_knees", "seat_outside_feet", "seat_too_narrow", "noncolliding_support", "forged_support_root", "root_with_unchecked_seat", "undeclared_elevated_support", "undeclared_support_with_neighbor", "missing_declared_support", "malformed_dependency", "malformed_seat", "occupied_output_id", "already_built"]:
		_input_negative(mode)
	var completed := _fixture(1.0, 0.0, true)
	var setup: Dictionary = Frame.add_frame(completed.b, completed.ids, completed.support)
	_record("mutation_positive_precondition", setup.ready)
	var mutation_count := 0
	if setup.ready:
		var authored: Dictionary = completed.b.snapshot()
		for target_id in setup.partIds + [completed.support, "synthetic_ground"]:
			for mode in ["remove", "move", "disable_collision", "break_mandatory_seat"]:
				# A true ground root has no mandatory seat to break.
				if target_id == "synthetic_ground" and mode == "break_mandatory_seat":
					continue
				mutation_count += 1
				_mutation_negative(authored, target_id, mode)
		for part in completed.b.parts:
			if part.semantic not in [Frame.KNEE_SEMANTIC, Frame.RIDGE_SEMANTIC]:
				continue
			for socket_index in range(2):
				for mode in ["missing_anchor", "displaced_socket"]:
					_socket_negative(authored, part.id, socket_index, mode)
	_record("mutation_matrix_complete", mutation_count == 47)
	_schema_grid_counterexamples()
	_ground_wrapper_cases()
	var passed := not _checks.is_empty() and _checks.all(func(c): return bool(c.passed))
	var report := {"fixture": "MarketCanopyFrameContract", "evidenceLevel": "synthetic_source_service_contract",
		"passed": passed, "checks": _checks, "elapsedMsec": Time.get_ticks_msec() - started,
		"doesNotProve": "Actual publisher meshes or aged-ridge contact, cloth/content clearance, frozen citadel source, placement, visual fidelity, live physics, gameplay, NPC/navigation or gate 0 acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("Cannot create canopy contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("Market canopy synthetic contract: %s (%d checks)" % ["PASS" if passed else "FAIL", _checks.size()])
	quit(0 if passed else 1)

func _positive(fixture: Dictionary, label: String) -> void:
	var b = fixture.b
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(p): return p.recipe)
	var result: Dictionary = Frame.add_frame(b, fixture.ids, fixture.support)
	_record(label + ":ready", result.ready, result.get("reason", ""))
	if not result.ready:
		return
	var original_ids: Array = before.parts.map(func(p): return String(p.id))
	_record(label + ":ten_new_members", result.partIds.size() == 10 and b.parts.size() == before.parts.size() + 10 and result.memberIds == fixture.ids + result.partIds)
	var unchanged := true
	for index in range(before.parts.size()):
		var old: Dictionary = before.parts[index]
		var current: Dictionary = b.parts[index].snapshot()
		if old.semantic in [Frame.KNEE_SEMANTIC, Frame.RIDGE_SEMANTIC]:
			for key in ["physicalRequiredAnchorPartIds", "physicalRequiredAnchorFacts"]:
				current.recipe.erase(key)
		unchanged = unchanged and _bytes(old) == _bytes(current) and is_same(aliases[index], b.parts[index]) and is_same(recipes[index], b.parts[index].recipe)
	_record(label + ":all_existing_geometry_contents_and_aliases_preserved", unchanged)
	_record(label + ":no_existing_ridge_straightening", not _find(b, "synthetic_ridge").recipe.has("preserveBearingFaces"))
	_record(label + ":blueprint_header_preserved", b.recipe == before.recipe and b.rooms == before.rooms and b.id == before.id and b.seed == before.seed and b.style == before.style)
	var expected: Dictionary = b.snapshot()
	var reordered = _copy(before)
	var reverse_ids: Array = fixture.ids.duplicate()
	reverse_ids.reverse()
	var reordered_result: Dictionary = Frame.add_frame(reordered, reverse_ids, fixture.support)
	_record(label + ":member_order_independent", reordered_result.ready and _bytes(reordered.snapshot()) == _bytes(expected))
	var validation: Dictionary = b.validate_physical_integrity()
	_record(label + ":all_source_checks_pass", validation.violations.is_empty() and validation.checks.size() == b.parts.size() and validation.checks.all(func(c): return bool(c.passed)), validation.violations)
	var joints_ok := true
	for part in b.parts:
		if result.partIds.has(part.id):
			joints_ok = joints_ok and part.collision_enabled and part.physical_intent == "structural_mass" and not part.recipe.get("physicalRequiredSeatFacts", []).is_empty() and part.recipe.get("preserveBearingFaces", false)
			for fact in part.recipe.get("physicalRequiredSeatFacts", []):
				joints_ok = joints_ok and b.has_rooted_bearer_seat(part, fact)
		if part.semantic in [Frame.KNEE_SEMANTIC, Frame.RIDGE_SEMANTIC]:
			joints_ok = joints_ok and part.recipe.physicalRequiredAnchorPartIds.size() == 2 and part.recipe.physicalRequiredAnchorFacts.size() == 2
			for fact in part.recipe.physicalRequiredAnchorFacts:
				joints_ok = joints_ok and result.partIds.has(fact.anchorId) and _socket_contained(part, fact) and b.has_rooted_attachment_socket(part, fact)
	_record(label + ":all_mandatory_seats_and_two_ended_sockets", joints_ok)
	_record(label + ":original_source_order", b.parts.filter(func(p): return original_ids.has(p.id)).map(func(p): return p.id) == original_ids)

func _input_negative(mode: String) -> void:
	var f := _fixture(1.0, 0.0, mode in ["undeclared_elevated_support", "undeclared_support_with_neighbor", "missing_declared_support", "malformed_dependency", "malformed_seat"])
	var b = f.b
	var knee = _find(b, "synthetic_knee_-1_-1")
	var ridge = _find(b, "synthetic_ridge")
	var support = _find(b, f.support)
	match mode:
		"missing_member": f.ids.append("absent")
		"duplicate_member": f.ids.append(f.ids[0])
		"missing_ridge": f.ids.erase(ridge.id)
		"duplicate_ridge_semantic": _find(b, "synthetic_goods").semantic = Frame.RIDGE_SEMANTIC
		"missing_support": f.support = "absent"
		"support_is_household": f.support = ridge.id
		"duplicate_source_id": b.add_part(support.snapshot())
		"nonfinite_member": knee.position.x = NAN
		"zero_member_size": knee.size.x = 0.0
		"nonfinite_rotation": knee.rotation.z = INF
		"wrong_material": knee.material_id = "stone_foundation"
		"colliding_knee": knee.collision_enabled = true
		"visual_detail_knee": knee.physical_intent = "visual_detail"
		"forged_knee_root": knee.recipe.physicalRoot = true
		"existing_joint": knee.recipe.physicalRequiredAnchorPartIds = [support.id]
		"tilted_ridge": ridge.rotation.z = 0.12
		"shifted_knee": knee.position.y += 0.13
		"duplicate_quadrant": knee.position = _find(b, "synthetic_knee_1_-1").position
		"ridge_too_short": ridge.size.x = 1.0
		"seat_above_knees": support.size.y = 6.0; support.position.y = 3.0
		"seat_outside_feet": support.position.x += 12.0
		"seat_too_narrow": support.size.x = 0.4
		"noncolliding_support": support.collision_enabled = false
		"forged_support_root": support.position.y += 0.5; support.recipe.physicalRoot = true
		"root_with_unchecked_seat": support.recipe.physicalRequiredSeatPartIds = ["missing_seat"]
		"undeclared_elevated_support": support.recipe.clear()
		"undeclared_support_with_neighbor":
			support.recipe.clear()
			# A coincident valid neighbour exists in the source, but no declared
			# upstream path allows the builder to import it as a rescue anchor.
			var neighbor: Dictionary = support.snapshot()
			neighbor.id = "unrequested_neighbor"
			neighbor.size.y = (support.position.y + support.size.y * 0.5) * 2.0
			neighbor.position.y = neighbor.size.y * 0.5
			b.add_part(neighbor)
		"missing_declared_support": b.parts.erase(_find(b, "synthetic_ground"))
		"malformed_dependency": support.recipe.physicalRequiredSeatPartIds = [7]
		"malformed_seat": support.recipe.physicalRequiredSeatFacts = [{"seatId": "synthetic_ground", "loadDirection": "world_down", "localPatchCenter": "bad"}]
		"occupied_output_id":
			var record: Dictionary = _find(b, "synthetic_goods").snapshot()
			record.id = ridge.id + "_frame_ridge_seat_1"
			b.add_part(record)
		"already_built":
			var precondition: Dictionary = Frame.add_frame(b, f.ids, f.support)
			_record("already_built:positive_precondition", precondition.ready)
	var before := _bytes(b.snapshot())
	var aliases: Array = b.parts.duplicate()
	var result: Dictionary = Frame.add_frame(b, f.ids, f.support)
	var aliases_ok: bool = aliases.size() == b.parts.size()
	for index in range(mini(aliases.size(), b.parts.size())):
		aliases_ok = aliases_ok and is_same(aliases[index], b.parts[index])
	_record("input:" + mode, not result.ready and not String(result.reason).is_empty() and result.partIds.is_empty() and before == _bytes(b.snapshot()) and aliases_ok, result.reason)

func _mutation_negative(source: Dictionary, target_id: String, mode: String) -> void:
	var b = _copy(source)
	var positive = _copy(source)
	var precheck: Dictionary = positive.validate_physical_integrity()
	var part = _find(b, target_id)
	match mode:
		"remove": b.parts.erase(part)
		"move": part.position.x += 20.0
		"disable_collision": part.collision_enabled = false
		"break_mandatory_seat":
			# Keep geometry and incidental reachability intact. Only a required
			# declaration fails: the shared final dependency check must propagate it.
			part.recipe.physicalRequiredSeatPartIds[0] = "missing_required_seat"
	var physical: Dictionary = b.validate_physical_integrity()
	var ridge_checks: Array = physical.checks.filter(func(c): return c.partId == "synthetic_ridge")
	_record("mutation:%s:%s" % [target_id, mode], precheck.passed and not physical.passed and ridge_checks.size() == 1 and not ridge_checks[0].passed)

func _socket_negative(source: Dictionary, target_id: String, index: int, mode: String) -> void:
	var positive = _copy(source)
	var precheck: Dictionary = positive.validate_physical_integrity()
	var b = _copy(source)
	var part = _find(b, target_id)
	if mode == "missing_anchor":
		part.recipe.physicalRequiredAnchorPartIds[index] = "missing_anchor"
		part.recipe.physicalRequiredAnchorFacts[index].anchorId = "missing_anchor"
	else:
		part.recipe.physicalRequiredAnchorFacts[index].localMountCenter.y += 1.0
	var physical: Dictionary = b.validate_physical_integrity()
	var rows: Array = physical.checks.filter(func(c): return c.partId == target_id)
	_record("socket:%s:%d:%s" % [target_id, index, mode], precheck.passed and rows.size() == 1 and not rows[0].passed)

func _schema_grid_counterexamples() -> void:
	# Append-only critic controls: retain every existing positive/mutation case.
	# Establish a real valid housed seat before corrupting its schema. The earlier
	# elevated fixtures independently retain valid world_down coverage.
	_positive(_housed_fixture(), "housed_support_control")
	var housed := _housed_fixture()
	var valid: Dictionary = _find(housed.b, housed.support).recipe.physicalRequiredSeatFacts[0]
	var cases: Array = []
	for key in ["localOverlapCenter", "localOverlapHalfExtents"]:
		var missing := valid.duplicate(true)
		missing.erase(key)
		cases.append({"id": "missing_" + key, "fact": missing})
		var invalid_values: Array = [null, "bad", Vector3(NAN, 0.025, 0.035), Vector3(0.065, INF, 0.035)]
		for index in range(invalid_values.size()):
			var malformed := valid.duplicate(true)
			malformed[key] = invalid_values[index]
			cases.append({"id": "%s_invalid_%d" % [key, index], "fact": malformed})
	for half in [Vector3.ZERO, Vector3(-0.065, 0.025, 0.035)]:
		var malformed := valid.duplicate(true)
		malformed.localOverlapHalfExtents = half
		cases.append({"id": "nonpositive_housed_half_%d" % cases.size(), "fact": malformed})
	for key in ["minimumLongitudinalEmbedment", "minimumVerticalOverlap"]:
		for value in ["bad", NAN, INF, -0.01]:
			var malformed := valid.duplicate(true)
			malformed[key] = value
			cases.append({"id": "%s_invalid_%d" % [key, cases.size()], "fact": malformed})
	for axis in [null, 1, "w"]:
		var malformed := valid.duplicate(true)
		malformed.localSpanAxis = axis
		cases.append({"id": "invalid_span_axis_%d" % cases.size(), "fact": malformed})
	for value in ["", " synthetic_ground ", 7]:
		var malformed := valid.duplicate(true)
		malformed.seatId = value
		cases.append({"id": "invalid_seat_id_%d" % cases.size(), "fact": malformed})
	var gravity: Dictionary = Seats.world_down_seat_fact("synthetic_ground", Vector3(0, -0.12, 0), Vector2(2, 2))
	var mixed := valid.duplicate(true)
	mixed.merge(gravity, true)
	cases.append({"id": "mixed_valid_gravity_and_housed_payloads", "fact": mixed})
	var mixed_nan := mixed.duplicate(true)
	mixed_nan.localOverlapCenter = Vector3(NAN, NAN, NAN)
	cases.append({"id": "valid_gravity_cannot_hide_housed_nan", "fact": mixed_nan, "gravityFixture": true})
	var mixed_type := mixed.duplicate(true)
	mixed_type.localOverlapHalfExtents = "bad"
	cases.append({"id": "valid_gravity_cannot_hide_housed_wrong_type", "fact": mixed_type, "gravityFixture": true})
	var gravity_with_housed_field := gravity.duplicate(true)
	gravity_with_housed_field.localOverlapCenter = Vector3.ZERO
	cases.append({"id": "gravity_with_stray_housed_field", "fact": gravity_with_housed_field, "gravityFixture": true})
	var housed_with_gravity_field := valid.duplicate(true)
	housed_with_gravity_field.localPatchCenter = Vector3.ZERO
	cases.append({"id": "housed_with_stray_gravity_field", "fact": housed_with_gravity_field})
	var housed_with_point_mode := valid.duplicate(true)
	housed_with_point_mode.bearingPoint = Vector3.ZERO
	cases.append({"id": "housed_with_point_mode", "fact": housed_with_point_mode})
	for row in cases:
		var fixture := _fixture(1.0, 0.0, true) if row.get("gravityFixture", false) else _housed_fixture()
		_find(fixture.b, fixture.support).recipe.physicalRequiredSeatFacts = [row.fact]
		_atomic_critic_rejection("schema:" + row.id, fixture, "unsupported_support_seat_fact")

	var huge := _fixture(1.0, 0.0, false)
	_find(huge.b, huge.support).size = Vector3(1000000, 0.4, 1000000)
	_atomic_critic_rejection("grid:huge_finite_ground_root", huge, "staged_validation_grid_limit_exceeded", "supports")
	var overflow := _fixture(1.0, 0.0, false)
	var overflow_root = _find(overflow.b, overflow.support)
	overflow_root.size = Vector3(3e38, 0.4, 3e38)
	overflow_root.rotation.y = PI * 0.25
	_atomic_critic_rejection("grid:finite_source_transformed_bounds_overflow", overflow, "invalid_validation_grid_bounds", "supports")
	var coordinate := _fixture(1.0, 0.0, false)
	var coordinate_root = _find(coordinate.b, coordinate.support)
	coordinate_root.position.x = 1e10
	coordinate_root.size.x = 4096
	_atomic_critic_rejection("grid:finite_coordinate_before_integer_conversion", coordinate, "validation_grid_coordinate_limit", "supports")
	var cumulative := _fixture(1.0, 0.0, true)
	var cumulative_support = _find(cumulative.b, cumulative.support)
	cumulative_support.recipe.physicalRequiredSupportPartIds = []
	for index in range(20):
		var record: Dictionary = _find(cumulative.b, "synthetic_ground").snapshot()
		record.id = "additional_root_%02d" % index
		record.size = Vector3(64, 0.4, 64)
		cumulative.b.add_part(record)
		cumulative_support.recipe.physicalRequiredSupportPartIds.append(record.id)
	_atomic_critic_rejection("grid:cumulative_support_coverage", cumulative, "staged_validation_grid_limit_exceeded", "supports")
	var generated := _fixture(1.0, 0.0, false)
	var ridge = _find(generated.b, "synthetic_ridge")
	for part in generated.b.parts:
		if part.semantic == Frame.KNEE_SEMANTIC:
			# Individually tiny knees still derive enormous connecting headers.
			# The small supplied root passes the FIRST full validation. The second
			# guard must reject newly generated coverage before any frame scan.
			part.position.x = ridge.position.x + signf(part.position.x - ridge.position.x) * 10000.0
	var generated_result := _atomic_critic_rejection("grid:generated_header_coverage", generated, "staged_validation_grid_limit_exceeded", "frame")
	_record("grid:generated_member_caused_rejection", String(generated_result.get("partId", "")).begins_with("synthetic_ridge_frame_header_"))
	var frame_sum := _fixture(1.0, 0.0, false)
	_find(frame_sum.b, frame_sum.support).size = Vector3(252, 0.4, 252)
	# The root alone covers exactly 4096 expanded XZ cells at this fixture's
	# origin. The complete frame must be charged again, not reuse the first pass.
	_atomic_critic_rejection("grid:complete_frame_rechecks_cumulative_budget", frame_sum, "staged_validation_grid_limit_exceeded", "frame")

func _housed_fixture() -> Dictionary:
	var fixture := _fixture(1.0, 0.0, true)
	var support = _find(fixture.b, fixture.support)
	support.position.y -= 0.08
	for id in fixture.ids:
		_find(fixture.b, id).position.y -= 0.08
	support.recipe.physicalRequiredSeatFacts = [{"seatId": "synthetic_ground", "contactMode": "housed_overlap",
		"localOverlapCenter": Vector3(0, -0.085, 0), "localOverlapHalfExtents": Vector3(0.065, 0.025, 0.035),
		"localSpanAxis": "x", "minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04}]
	return fixture

func _atomic_critic_rejection(label: String, fixture: Dictionary, reason: String, stage := "") -> Dictionary:
	var b = fixture.b
	var before := _bytes(b.snapshot())
	var members_before := _bytes(fixture.ids)
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(p): return p.recipe)
	var index_before: Dictionary = b.physical_parts_by_id.duplicate()
	var result: Dictionary = Frame.add_frame(b, fixture.ids, fixture.support)
	var aliases_ok: bool = aliases.size() == b.parts.size()
	for index in range(mini(aliases.size(), b.parts.size())):
		aliases_ok = aliases_ok and is_same(aliases[index], b.parts[index]) and is_same(recipes[index], b.parts[index].recipe)
	_record(label, not result.ready and result.reason == reason and result.partIds.is_empty()
		and (stage.is_empty() or result.get("validationStage", "") == stage)
		and before == _bytes(b.snapshot()) and members_before == _bytes(fixture.ids)
		and aliases_ok and index_before == b.physical_parts_by_id, result)
	return result

func _ground_wrapper_cases() -> void:
	for yaw in [0.0, PI * 0.5, 0.37]:
		for surface_kind in ["foundation", "floor"]:
			var fixture := _ground_wrapper_fixture(yaw)
			var surface = _find(fixture.b, fixture.support)
			surface.kind = surface_kind
			_wrapper_positive(fixture, "wrapper:%s:%s" % [surface_kind, str(yaw)])
	var reasons := {"empty_surface": "invalid_ground_selection_input", "missing_surface": "missing_standing_surface",
		"empty_members": "invalid_ground_selection_input", "too_many_members": "invalid_ground_selection_input",
		"too_many_parts": "invalid_ground_selection_input", "missing_member": "invalid_household_membership",
		"duplicate_member": "invalid_household_membership", "surface_in_members": "invalid_household_membership",
		"duplicate_source": "missing_or_duplicate_source_id", "invalid_member_bounds": "invalid_ground_selection_bounds",
		"invalid_unrelated_bounds": "invalid_ground_selection_bounds", "transformed_overflow": "invalid_ground_selection_bounds",
		"surface_wall": "invalid_standing_surface_role", "surface_noncolliding": "invalid_standing_surface_role",
		"surface_rotated": "invalid_standing_surface_role", "surface_bad_intent": "invalid_standing_surface_role",
		"surface_bad_recipe_intent": "invalid_standing_surface_role", "surface_false_root_intent": "invalid_standing_surface_role",
		"surface_too_narrow": "household_outside_standing_surface", "absent_roots": "no_grounded_source_beneath_household",
		"floating_fake_root": "no_grounded_source_beneath_household", "remote_contents": "no_grounded_source_beneath_household",
		"remote_ground_detail": "no_grounded_source_beneath_household", "selected_root_joint_failure": "ground_root_must_not_declare_unchecked_joints",
		"selected_root_grid_failure": "staged_validation_grid_limit_exceeded", "already_built": "attachment_already_has_joint_contract"}
	for mode in reasons:
		var fixture := _ground_wrapper_fixture()
		var b = fixture.b
		var surface = _find(b, fixture.support)
		match mode:
			"empty_surface": fixture.support = ""
			"missing_surface": fixture.support = "missing_surface"
			"empty_members": fixture.ids.clear()
			"too_many_members": fixture.ids.resize(Frame.MAX_MEMBERS + 1)
			"too_many_parts": b.parts.resize(Frame.MAX_SOURCE_PARTS + 1)
			"missing_member": fixture.ids.append("missing_member")
			"duplicate_member": fixture.ids.append(fixture.ids[0])
			"surface_in_members": fixture.ids.append(fixture.support)
			"duplicate_source": b.add_part(_find(b, "root_z").snapshot())
			"invalid_member_bounds": _find(b, fixture.ids[0]).position.x = NAN
			"invalid_unrelated_bounds": _find(b, "too_high_root").size.x = 0.0
			"transformed_overflow":
				var part = _find(b, "root_z")
				part.size = Vector3(3e38, 0.4, 3e38)
				part.rotation.y = PI * 0.25
			"surface_wall": surface.kind = "wall"
			"surface_noncolliding": surface.collision_enabled = false
			"surface_rotated": surface.rotation.y = 0.1
			"surface_bad_intent": surface.physical_intent = "visual_detail"
			"surface_bad_recipe_intent": surface.recipe.physicalIntent = "portal"
			"surface_false_root_intent": surface.physical_intent = "structural_root"
			"surface_too_narrow": surface.size.x = 0.2
			"absent_roots", "floating_fake_root":
				for id in ["synthetic_ground", "root_z"]:
					b.parts.erase(_find(b, id))
				var root = _find(b, "root_a")
				if mode == "absent_roots":
					b.parts.erase(root)
				else:
					root.position.y += 0.025
					# Deliberately beyond the EXISTING 0.06 grounding tolerance.
					root.position.y += 0.075
					root.recipe.physicalRoot = true
			"remote_contents", "remote_ground_detail":
				surface.size.x = 20.0
				var part = _find(b, "synthetic_goods")
				part.position.x += 6.0
				if mode == "remote_ground_detail":
					part.kind = "ground_patch"
					part.semantic = "traffic_wear"
			"selected_root_joint_failure": _find(b, "root_a").recipe.physicalRequiredSeatPartIds = ["missing_seat"]
			"selected_root_grid_failure": _find(b, "root_a").size.x = 1000000.0
			"already_built":
				var setup: Dictionary = Frame.add_frame_on_grounded_support(b, fixture.ids, fixture.support)
				_record("wrapper:already_built_precondition", setup.ready)
		_wrapper_rejection(mode, fixture, reasons[mode])

func _ground_wrapper_fixture(yaw := 0.0) -> Dictionary:
	var fixture := _fixture(1.0, yaw, true)
	# Only household members are rotated. The supplied standing paving and
	# candidate masonry remain in the public wrapper's axis-aligned domain.
	for part in fixture.b.parts:
		if not fixture.ids.has(part.id):
			part.rotation = Vector3.ZERO
	for item in [{"id": "root_z", "top": 0.56, "width": 8.0}, {"id": "root_a", "top": 0.56, "width": 8.0},
		{"id": "too_high_root", "top": 1.0, "width": 8.0}, {"id": "partial_root", "top": 0.6, "width": 0.3}]:
		var record: Dictionary = _find(fixture.b, "synthetic_ground").snapshot()
		record.id = item.id
		record.position.y = float(item.top) * 0.5
		record.size = Vector3(item.width, item.top, 8.0)
		fixture.b.add_part(record)
	return fixture

func _wrapper_positive(fixture: Dictionary, label: String) -> void:
	var b = fixture.b
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(p): return p.recipe)
	var original_members := _bytes(fixture.ids)
	var surface = _find(b, fixture.support)
	var top: float = surface.position.y + surface.size.y * 0.5
	var result: Dictionary = Frame.add_frame_on_grounded_support(b, fixture.ids, fixture.support)
	_record(label + ":ready_and_highest_root_tie", result.get("ready", false) and result.get("supportId", "") == "root_a" and result.get("rootCandidates", []) == ["root_a", "root_z", "synthetic_ground"], result)
	if not result.get("ready", false):
		return
	_record(label + ":surface_and_complete_membership", result.standingSurfaceId == fixture.support and result.standingSurfaceY == top and result.memberIds == fixture.ids + result.partIds and result.partIds.size() == 10 and original_members == _bytes(fixture.ids))
	var expected = _copy(before)
	var direct: Dictionary = Frame.add_frame(expected, fixture.ids, "root_a")
	_record(label + ":exact_existing_add_frame_output", direct.ready and _bytes(b.snapshot()) == _bytes(expected.snapshot()))
	var preserved := true
	for index in range(before.parts.size()):
		var current: Dictionary = b.parts[index].snapshot()
		if current.semantic in [Frame.KNEE_SEMANTIC, Frame.RIDGE_SEMANTIC]:
			current.recipe.erase("physicalRequiredAnchorPartIds")
			current.recipe.erase("physicalRequiredAnchorFacts")
		preserved = preserved and _bytes(before.parts[index]) == _bytes(current) and is_same(aliases[index], b.parts[index]) and is_same(recipes[index], b.parts[index].recipe)
	_record(label + ":source_and_content_preservation", preserved and before.recipe == b.recipe and before.rooms == b.rooms)
	var all_corners := true
	var footprint: Rect2 = result.householdFootprint
	for id in fixture.ids:
		var part = _find(b, id)
		var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
		for x in [-1.0, 1.0]:
			for y in [-1.0, 1.0]:
				for z in [-1.0, 1.0]:
					var corner: Vector3 = transform * (part.size * Vector3(x, y, z) * 0.5)
					all_corners = all_corners and corner.x >= footprint.position.x and corner.x <= footprint.end.x and corner.z >= footprint.position.y and corner.z <= footprint.end.y
	_record(label + ":footprint_contains_all_actual_member_corners", all_corners)
	var reordered = _copy(before)
	reordered.parts.reverse()
	var ids: Array = fixture.ids.duplicate()
	ids.reverse()
	var replay: Dictionary = Frame.add_frame_on_grounded_support(reordered, ids, fixture.support)
	_record(label + ":deterministic_source_and_member_order", replay.get("ready", false) and replay.get("rootCandidates") == result.rootCandidates and replay.get("supportId") == result.supportId and replay.get("householdFootprint") == footprint and _bytes(_sorted_part_records(reordered)) == _bytes(_sorted_part_records(b)))

func _wrapper_rejection(label: String, fixture: Dictionary, reason: String) -> void:
	var b = fixture.b
	var before := _bytes(b.snapshot())
	var members_before := _bytes(fixture.ids)
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(p): return p.recipe if p != null else null)
	var index_before: Dictionary = b.physical_parts_by_id.duplicate()
	var result: Dictionary = Frame.add_frame_on_grounded_support(b, fixture.ids, fixture.support)
	var aliases_ok: bool = aliases.size() == b.parts.size()
	for index in range(mini(aliases.size(), b.parts.size())):
		aliases_ok = aliases_ok and is_same(aliases[index], b.parts[index])
		if b.parts[index] != null:
			aliases_ok = aliases_ok and is_same(recipes[index], b.parts[index].recipe)
	_record("wrapper:reject:" + label, not result.get("ready", false) and result.get("reason") == reason and result.get("partIds", []).is_empty() and before == _bytes(b.snapshot()) and members_before == _bytes(fixture.ids) and aliases_ok and index_before == b.physical_parts_by_id, result)
	if label.begins_with("selected_root_"):
		_record("wrapper:no_lower_root_fallback:" + label, result.get("rootCandidates", []) == ["root_a", "root_z", "synthetic_ground"] and not result.get("ready", false))

func _sorted_part_records(b) -> Array:
	var records: Array = b.part_snapshots()
	records.sort_custom(func(a, c): return String(a.id) < String(c.id))
	return records

func _fixture(scale_value: float, yaw: float, elevated: bool) -> Dictionary:
	var b = Blueprint.new("synthetic_market", 37, "timber")
	b.recipe = {"synthetic": true, "furnitureSeedUnchanged": 991}
	b.rooms = [{"id": "untouched_room", "role": "courtyard"}]
	var horizontal := Vector3(12.0, 0.0, -9.0)
	var ground_height := 0.4
	var basis := Basis(Vector3.UP, yaw)
	b.add_part({"id": "synthetic_ground", "kind": "foundation", "material": "stone_foundation", "position": horizontal + Vector3.UP * ground_height * 0.5,
		"rotation": basis.get_euler(), "size": Vector3(8.0, ground_height, 8.0), "collision": true})
	var support := "synthetic_ground"
	var top := ground_height
	if elevated:
		support = "synthetic_supported_plinth"
		var height := 0.24
		b.add_part({"id": support, "kind": "foundation", "material": "stone_foundation", "position": horizontal + Vector3.UP * (ground_height + height * 0.5),
			"rotation": basis.get_euler(), "size": Vector3(6.0, height, 6.0), "collision": true,
			"recipe": {"physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": ["synthetic_ground"],
				"physicalRequiredSeatFacts": [Seats.world_down_seat_fact("synthetic_ground", Vector3(0, -height * 0.5, 0), Vector2(2, 2))]}})
		top += height
	var pose := Transform3D(basis, horizontal + Vector3.UP * top)
	var ids: Array = []
	for side in [-1, 1]:
		for depth in [-1, 1]:
			var id := "synthetic_knee_%d_%d" % [side, depth]
			ids.append(id)
			b.add_part({"id": id, "kind": "beam", "material": "timber_beam", "position": pose * (Vector3(side * 1.04, 2.14, depth * 0.72) * scale_value),
				"rotation": (basis * Basis(Vector3.BACK, side * deg_to_rad(43.0))).get_euler(), "size": Vector3(0.14, 0.92, 0.14) * scale_value,
				"collision": false, "semantic": Frame.KNEE_SEMANTIC, "recipe": {"variation": 0.1 + float(depth) * 0.01}})
	ids.append("synthetic_ridge")
	b.add_part({"id": "synthetic_ridge", "kind": "beam", "material": "timber_beam", "position": pose * (Vector3(0, 2.68, 0) * scale_value),
		"rotation": basis.get_euler(), "size": Vector3(3.55, 0.14, 0.14) * scale_value, "collision": false, "semantic": Frame.RIDGE_SEMANTIC, "recipe": {"variation": 0.18}})
	# Unchanged contents/cloth proxies are synthetic preservation sentinels,
	# explicitly NOT actual-publisher or cloth-clearance acceptance geometry.
	for content in [{"id": "synthetic_goods", "kind": "pottery", "material": "ceramic_glaze", "position": Vector3(0, 1.1, 0)},
		{"id": "synthetic_cloth", "kind": "decor", "material": "wool_moss", "position": Vector3(0, 2.55, 0.57)},
		{"id": "synthetic_seat", "kind": "decor", "material": "timber_board", "position": Vector3(0, 0.36, -1.6)}]:
		ids.append(content.id)
		b.add_part({"id": content.id, "kind": content.kind, "material": content.material, "position": pose * (content.position * scale_value),
			"rotation": basis.get_euler(), "size": Vector3(0.3, 0.3, 0.3) * scale_value, "collision": false, "recipe": {"variation": 0.23}})
	return {"b": b, "ids": ids, "support": support}

func _copy(source: Dictionary):
	var b = Blueprint.new(source.id, source.seed, source.style)
	b.recipe = source.recipe.duplicate(true)
	b.rooms = source.rooms.duplicate(true)
	for record in source.parts:
		b.add_part(record)
	return b

func _find(b, id: String):
	for part in b.parts:
		if part.id == id:
			return part
	return null

func _socket_contained(part, fact: Dictionary) -> bool:
	for axis in range(3):
		if fact.localMountHalfExtents[axis] <= 0.0 or absf(fact.localMountCenter[axis]) + fact.localMountHalfExtents[axis] >= part.size[axis] * 0.5 - Blueprint.STAIR_HOUSED_JOINT_INSET:
			return false
	return true

func _bytes(value: Variant) -> PackedByteArray:
	return var_to_bytes(value)

func _record(name: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": name, "passed": passed, "detail": detail})
