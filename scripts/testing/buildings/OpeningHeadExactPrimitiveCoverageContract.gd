extends SceneTree

## Synthetic first-hit identity and readability policy, not actual visibility.
const Inspector = preload("res://scripts/testing/buildings/CitadelFacadeRecipeVisual.gd")
const Coverage = preload("res://scripts/testing/buildings/ProjectedReviewCoverage.gd")
const Head = preload("res://scripts/testing/buildings/CitadelOpeningHeadRecipeVisual.gd")

class MockHitHead extends "res://scripts/testing/buildings/CitadelOpeningHeadRecipeVisual.gd":
	var mock_hit: Dictionary = {}
	var mock_calls := 0
	var mock_bounds: Dictionary = {}
	func _ready() -> void: pass # No renderer fixture launch; named synthetic wiring only.
	func _first_visual_hit(_from: Vector3, _target: Vector3) -> Dictionary:
		mock_calls += 1
		return mock_hit
	func _published_bounds(id: String) -> AABB: return mock_bounds.get(id, AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE))
	func _cut_meshes_exact() -> bool: return true # Resource binding tested separately.

class MockCloseHead extends "res://scripts/testing/buildings/CitadelOpeningHeadRecipeVisual.gd":
	var visibility := true
	var visibility_calls := 0
	var cutaway_requested := false
	func _ready() -> void: pass # Synthetic observer dispatch, not live visibility.
	func _frame_visible(_bounds: AABB) -> bool: return true
	func _targets_visible(_spec: Dictionary, allow_cutaway: bool) -> bool:
		visibility_calls += 1
		cutaway_requested = cutaway_requested or allow_cutaway
		return visibility

class MockDiagnosticHead extends MockCloseHead:
	var expire_at := ""
	var expired := false
	var image_reads := 0
	func _budget_reason() -> String: return "synthetic_expiration" if expired else ""
	func _source_exact() -> bool:
		if expire_at == "validation": expired = true
		return true # Named synthetic binding, never real candidate evidence.
	func _cut_meshes_exact() -> bool: return true
	func _live_state_digest() -> String: return ""
	func _review_code_identity() -> Dictionary: return {}
	func _lighting_snapshot() -> Array: return []
	func _read_diagnostic_image() -> Image:
		image_reads += 1
		if expire_at == "readback": expired = true
		return Image.create(8, 8, false, Image.FORMAT_RGBA8) # Synthetic pixels only.

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_EXACT_PRIMITIVE_COVERAGE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var cut := MeshInstance3D.new()
	var mortar := MeshInstance3D.new()
	var exact := {"node": cut, "index": 0, "partId": "shared_wall_owner"}
	var checks := {}
	checks.exact_cut_hit = Inspector.same_primitive_identity(exact, exact)
	checks.same_owner_mortar_rejects = not Inspector.same_primitive_identity({"node": mortar, "index": 0, "partId": "shared_wall_owner"}, exact)
	checks.other_instance_rejects = not Inspector.same_primitive_identity({"node": cut, "index": 1, "partId": "shared_wall_owner"}, exact)
	checks.other_owner_rejects = not Inspector.same_primitive_identity({"node": cut, "index": 0, "partId": "other"}, exact)
	checks.empty_hit_rejects = not Inspector.same_primitive_identity({}, exact)
	checks.empty_expectation_rejects = not Inspector.same_primitive_identity(exact, {})
	var all_hits: Array = []
	var occluded_hits: Array = []
	for sample in range(9):
		all_hits.append(Inspector.same_primitive_identity(exact, exact))
		occluded_hits.append(Inspector.same_primitive_identity({"node": mortar, "index": 0, "partId": "shared_wall_owner"}, exact))
	checks.readable_exact_hits = Coverage.evaluate(Rect2(0, 0, 40, 40), all_hits).passed
	checks.neighbour_cannot_supply_readability = not Coverage.evaluate(Rect2(0, 0, 40, 40), occluded_hits).passed
	checks.undersized_exact_hits_reject = not Coverage.evaluate(Rect2(0, 0, 3, 3), all_hits).passed
	checks.incomplete_budget_reject = not Coverage.evaluate(Rect2(0, 0, 40, 40), all_hits.slice(0, 8)).passed
	var fixture := MockHitHead.new()
	root.add_child(fixture)
	fixture._camera = Camera3D.new()
	fixture.add_child(fixture._camera)
	fixture._camera.position = Vector3(0, 0, 5)
	fixture._camera.look_at(Vector3.ZERO)
	var spec := {"exactCutKey": "synthetic_cut", "exactPrimitive": exact, "cutBounds": AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)}
	fixture.mock_hit = {"node": mortar, "index": 0, "partId": "shared_wall_owner", "point": Vector3(0, 0, 0.5)}
	checks.mocked_adapter_rejects_same_owner_mortar = not fixture._distributed_view_coverage(spec) and fixture.mock_calls == 9
	fixture.mock_hit = {"node": cut, "index": 0, "partId": "shared_wall_owner", "point": Vector3(0, 0, 0.5)}
	fixture.mock_calls = 0
	checks.mocked_adapter_accepts_exact_cut = fixture._distributed_view_coverage(spec) and fixture.mock_calls == 9
	var source_bounds := AABB(Vector3.ZERO, Vector3.ONE)
	var relief := AABB(Vector3(-0.2, 0, 0), Vector3(1.2, 1, 1))
	var peer := AABB(Vector3(0, 2, 0), Vector3.ONE)
	fixture._part_visuals = {"header": [], "peer": []}
	fixture.mock_bounds = {"header": relief, "peer": peer}
	var context := {"bounds": source_bounds}
	checks.mocked_context_expands_for_actual_relief = fixture._merge_published_context(context, ["header"]) and context.bounds == source_bounds.merge(relief) and context.bounds != source_bounds
	context = {"bounds": source_bounds}
	checks.mocked_context_includes_every_closure_member = fixture._merge_published_context(context, ["header", "peer"]) and context.bounds == source_bounds.merge(relief).merge(peer)
	context = {"bounds": source_bounds}
	checks.mocked_missing_published_member_rejects_atomically = not fixture._merge_published_context(context, ["header", "missing"]) and context.bounds == source_bounds
	fixture.mock_bounds.peer = AABB(Vector3(NAN, 0, 0), Vector3.ONE)
	checks.mocked_invalid_published_bounds_reject_atomically = not fixture._merge_published_context(context, ["header", "peer"]) and context.bounds == source_bounds
	checks.mocked_empty_closure_rejects = not fixture._merge_published_context(context, [])
	fixture._part_visuals.clear()
	var diagnostic := {"point": Vector3.ONE}
	var rejection_unchanged := true
	for sample in range(9): rejection_unchanged = rejection_unchanged and fixture._record_review_support_rejection("ray_miss", diagnostic).is_empty()
	diagnostic.point = Vector3.ZERO
	checks.support_telemetry_preserves_rejection = rejection_unchanged
	checks.support_telemetry_examples_bounded = fixture._review_support_diagnostics.rejections.ray_miss == 9 and fixture._review_support_diagnostics.examples.ray_miss.size() == 4
	checks.support_telemetry_details_detached = fixture._review_support_diagnostics.examples.ray_miss[0].point == Vector3.ONE
	var roof := Node3D.new()
	roof.set_meta("building_part_id", "synthetic_roof_owner")
	for view_id: String in ["context", "detail"]:
		fixture._active_view_id = view_id
		for sample in range(7):
			fixture._review_support_hit({"collider": roof, "normal": Vector3.UP, "position": Vector3(0, 10, 0)}, Vector3.ZERO, 5, -INF)
		var observed: Dictionary = fixture._review_support_diagnostics.views[view_id]
		checks[view_id + ":early_height_owner_retained"] = observed.examples.above_target[0].resolvedPartId == "synthetic_roof_owner"
		checks[view_id + ":independent_example_cap"] = observed.rejections.above_target == 7 and observed.examples.above_target.size() == 4
	fixture._review_support_hit({"collider": roof, "normal": Vector3.RIGHT, "position": Vector3(0, 10, 0)}, Vector3.ZERO, 5, -INF)
	fixture._review_support_hit({"collider": roof, "normal": Vector3.UP, "position": Vector3.ZERO}, Vector3.ZERO, 5, 1)
	checks.other_early_owner_rejections_retained = fixture._review_support_diagnostics.views.detail.examples.normal[0].resolvedPartId == "synthetic_roof_owner" and fixture._review_support_diagnostics.views.detail.examples.below_minimum[0].resolvedPartId == "synthetic_roof_owner"
	roof.free()
	fixture._camera = null
	fixture.free()
	cut.free()
	checks.freed_expected_node_rejects = not Inspector.same_primitive_identity(exact, exact)
	mortar.free()
	var observer := MockCloseHead.new()
	root.add_child(observer)
	observer._camera = Camera3D.new()
	observer.add_child(observer._camera)
	var detail_spec := {"id": "synthetic_detail", "kind": "close_inspection", "role": "cut_detail", "bounds": source_bounds, "targets": ["synthetic_cut"]}
	var detail_result: Dictionary = await observer._choose_view(detail_spec)
	checks.explicit_detail_uses_existing_close_observer = detail_result.get("ok", false) and detail_result.get("cameraScope") == "close_observer_not_player_or_access_evidence" and observer.visibility_calls == 1
	checks.close_observer_has_no_support_or_access_credit = observer._review_support_diagnostics.queries == 0 and not observer.cutaway_requested
	observer.visibility = false
	observer.visibility_calls = 0
	detail_result = await observer._choose_view(detail_spec)
	checks.occluded_detail_exhausts_bounded_candidates = not detail_result.get("ok", false) and observer.visibility_calls == 16 and not observer.cutaway_requested
	checks.rejected_pose_is_last_actual_attempt = Head.diagnostic_pose_valid(detail_result.get("lastAttempt", {})) and detail_result.lastAttempt.candidateIndex == 15 and detail_result.lastAttempt.position == observer._camera.global_position and detail_result.lastAttempt.target == source_bounds.get_center()
	checks.invalid_source_never_captures_diagnostic = not detail_result.has("rejectedDiagnostic") and not observer._diagnostic_state_valid()
	checks.missing_diagnostic_pose_rejects = not Head.diagnostic_pose_valid({})
	var bad_pose: Dictionary = detail_result.lastAttempt.duplicate(true)
	bad_pose.position = Vector3(NAN, 0, 0)
	checks.nonfinite_diagnostic_pose_rejects = not Head.diagnostic_pose_valid(bad_pose)
	bad_pose = detail_result.lastAttempt.duplicate(true)
	bad_pose.target = bad_pose.position
	checks.degenerate_diagnostic_pose_rejects = not Head.diagnostic_pose_valid(bad_pose)
	bad_pose = detail_result.lastAttempt.duplicate(true)
	bad_pose.candidateIndex = 16
	checks.unbounded_diagnostic_pose_rejects = not Head.diagnostic_pose_valid(bad_pose)
	observer._camera = null
	observer.free()
	for expire_at: String in ["validation", "readback", "never"]:
		var diagnostic_observer := MockDiagnosticHead.new()
		root.add_child(diagnostic_observer)
		diagnostic_observer.visibility = false
		diagnostic_observer.expire_at = expire_at
		diagnostic_observer.screenshot_dir = path.get_base_dir()
		diagnostic_observer._camera = Camera3D.new()
		diagnostic_observer.add_child(diagnostic_observer._camera)
		var diagnostic_spec: Dictionary = detail_spec.duplicate(true)
		diagnostic_spec.id = "SYNTHETIC_DIAGNOSTIC_" + expire_at
		var diagnostic_result: Dictionary = await diagnostic_observer._choose_view(diagnostic_spec)
		var synthetic_path := path.get_base_dir().path_join(diagnostic_spec.id + "_REJECTED_DIAGNOSTIC.png")
		checks[expire_at + ":diagnostic_never_earns_acceptance"] = not diagnostic_result.get("ok", false) and not diagnostic_result.has("captured") and not diagnostic_result.has("cameraPassed")
		if expire_at == "never":
			checks.synthetic_rejected_image_path_exercised = diagnostic_result.has("rejectedDiagnostic") and diagnostic_result.rejectedDiagnostic.accepted == false and FileAccess.file_exists(synthetic_path) and diagnostic_observer.image_reads == 1
		else:
			checks[expire_at + ":expired_diagnostic_not_saved_or_recorded"] = not diagnostic_result.has("rejectedDiagnostic") and not FileAccess.file_exists(synthetic_path) and diagnostic_observer.image_reads == (1 if expire_at == "readback" else 0)
		diagnostic_observer._camera = null
		diagnostic_observer.free()
	_contact_controls(path.get_base_dir(), checks)
	var passed: bool = not checks.values().has(false)
	var report := {"passed": passed, "checks": checks, "evidence": "synthetic_exact_primitive_identity_and_projection_policy", "limitations": "No real scene occlusion, camera feasibility, GPU, appearance or gameplay proof."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)

func _contact_controls(folder: String, checks: Dictionary) -> void:
	var path := OS.get_environment("VOXEL_OPENING_HEAD_CONTACT_INPUT")
	var sha := OS.get_environment("VOXEL_OPENING_HEAD_CONTACT_SHA256")
	var candidate := OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT_SHA256")
	var bound: Dictionary = Head.read_review_contacts(path, sha, candidate)
	checks.actual_contact_and_clearance_binding = bound.get("ready", false) and bound.get("contacts", []).size() == 341
	checks.wrong_classifier_sha_rejects = Head.read_review_contacts(path, "0".repeat(64), candidate).is_empty()
	checks.wrong_candidate_binding_rejects = Head.read_review_contacts(path, sha, "0".repeat(64)).is_empty()
	if not bound.get("ready", false): return
	var original: Dictionary = Head._read_bound_review_json(path, sha)
	for mode: String in ["missing_row", "duplicate_row", "modified_input", "wrong_clearance", "wrong_identity"]:
		var altered: Dictionary = original.duplicate(true)
		match mode:
			"missing_row": altered.contacts.pop_back()
			"duplicate_row": altered.contacts.append(altered.contacts[0])
			"modified_input": altered.contacts[0].inputRow.obstacleId += "_changed"
			"wrong_clearance": altered.inputs.clearance.sha256 = "0".repeat(64)
			"wrong_identity": altered.contacts[0].rowId += "_changed"
		var test_path := folder.path_join(mode + ".json")
		var file := FileAccess.open(test_path, FileAccess.WRITE)
		if file == null:
			checks[mode] = false
			continue
		file.store_string(JSON.stringify(altered))
		file.close()
		checks[mode + ":same_candidate_new_hash_still_rejects"] = Head.read_review_contacts(test_path, FileAccess.get_sha256(test_path), candidate).is_empty()
