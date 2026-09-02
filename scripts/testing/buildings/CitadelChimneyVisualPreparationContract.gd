extends SceneTree

## Source/preparation contract ONLY. Does not add the visual fixture to a tree,
## publish production geometry, read GPU buffers or capture images. Small box
## nodes below exercise source-service visibility, not renderer acceptance.
## Actual preparation additionally calls real begin_publication on a private
## source/tree parent, without publishing any part, to diagnose prediction drift.
## New absolute output: VOXEL_CHIMNEY_VISUAL_PREPARATION_REPORT.
## Optional full preparation (once): VOXEL_CHIMNEY_REVIEWED_BASELINE and
## VOXEL_CHIMNEY_PUBLISHED_EVIDENCE, same inputs as the headed fixture.
## Main owns the existing 100-second headless outer watchdog and all launches.
const Visual = preload("res://scripts/testing/buildings/CitadelChimneyRecipeVisual.gd")
const PreflightPublisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const PreflightCopy = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const PredictionBlueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
var _checks: Array = []
var _thread: Thread
var _fixture


class VisibilityRequirementProbe:
	extends "res://scripts/testing/buildings/CitadelChimneyRecipeVisual.gd"
	# Synthetic coverage decision only: no scene/camera/renderer visibility claim.
	var visible_ids: Array = []
	func _targets_visible(spec: Dictionary, _allow_cutaway: bool) -> bool:
		return spec.targets.all(func(id): return visible_ids.has(id))


class DetailRequirementProbe:
	extends "res://scripts/testing/buildings/CitadelChimneyRecipeVisual.gd"
	# Synthetic coverage orchestration, NOT renderer visibility evidence.
	var visible_indices: Array = []
	var bearer_seen: bool = true
	func _targets_visible(spec: Dictionary, _allow_cutaway: bool) -> bool:
		return bearer_seen and visible_indices.has(spec.exactPrimitive.index)


class CameraSolverProbe:
	extends "res://scripts/testing/buildings/CitadelUrbanPocRunner.gd"
	# Mock support/clearance and box sightlines; exercise the REAL shared solver
	# and audit without a physics world or a claim of public standing support.
	var physics_targets: Array = []
	var visual_targets: Array = []
	var physical_allowed: bool = true
	var visual_allowed: bool = true
	var blocker: AABB = AABB()
	func exterior_support_for_review(horizontal: Vector3, _target_y: float, _minimum_support_y: float) -> Dictionary:
		return {"position": Vector3(horizontal.x, 0, horizontal.z)}
	func review_capsule_clearance(_feet: Vector3, _support_collider) -> Dictionary:
		return {"clear": true}
	func review_visual_volume_is_clear(_feet: Vector3) -> bool:
		return true
	func review_line_is_clear(from: Vector3, target: Vector3) -> bool:
		physics_targets.append(target)
		return physical_allowed and (blocker.size == Vector3.ZERO or blocker.intersects_segment(from, target) == null)
	func review_visual_line_is_clear(from: Vector3, target: Vector3) -> bool:
		visual_targets.append(target)
		return visual_allowed and (blocker.size == Vector3.ZERO or blocker.intersects_segment(from, target) == null)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_CHIMNEY_VISUAL_PREPARATION_REPORT").strip_edges()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	_check("agreed_24_view_ceiling", Visual.EXPECTED_VIEWS == 24)
	_check("preparation_below_100_second_outer", Visual.PREPARATION_MSEC > 0 and Visual.PREPARATION_MSEC < 100000)
	_check("total_below_210_second_outer", Visual.TOTAL_MSEC > Visual.PREPARATION_MSEC and Visual.TOTAL_MSEC < 210000)
	var lower := AABB(Vector3(-2, 0, -2), Vector3(4, 2, 0.4))
	var upper := AABB(Vector3(-0.5, 2, -2), Vector3(1, 0.4, 4))
	var window: AABB = Visual.interface_window(upper, lower)
	_check("interface_is_local_positive_context", Visual._finite_box(window) and window.size.x == upper.size.x and window.position.z == lower.position.z and window.end.z == lower.end.z and window.size.y > 0)
	_check("both_actual_faces_in_context", window.position.y < lower.end.y and window.end.y > upper.position.y)
	var shifted_upper := upper
	shifted_upper.position.y += 0.0000005
	var separated: AABB = Visual.interface_window(shifted_upper, lower)
	_check("positive_represented_gap_retained", shifted_upper.position.y > lower.end.y and separated.position.y <= lower.end.y and separated.end.y >= shifted_upper.position.y)
	_check("inputs_not_mutated", upper.position == Vector3(-0.5, 2, -2) and lower.position == Vector3(-2, 0, -2))
	_check("disjoint_x_rejects", not Visual._finite_box(Visual.interface_window(AABB(Vector3(8, 2, -2), upper.size), lower)))
	_check("disjoint_z_rejects", not Visual._finite_box(Visual.interface_window(AABB(Vector3(-0.5, 2, 8), upper.size), lower)))
	_check("zero_volume_rejects", not Visual._finite_box(Visual.interface_window(AABB(), lower)))
	_check("nan_source_rejects", not Visual._finite_box(Visual.interface_window(AABB(Vector3(NAN, 2, -2), upper.size), lower)))
	_check("infinite_source_rejects", not Visual._finite_box(Visual.interface_window(AABB(Vector3.INF, upper.size), lower)))
	var matrix := {"basis": [[1, 0, 0], [0, 2, 0], [0, 0, 3]], "origin": [-7.25, 2.5, 13.75]}
	var expected := Transform3D(Basis(Vector3.RIGHT, Vector3.UP * 2, Vector3.BACK * 3), Vector3(-7.25, 2.5, 13.75))
	_check("report_transform_exact_float32_reconstruction", Visual._reported_transform(matrix) == expected)
	for invalid in [{}, {"basis": [], "origin": [0, 0, 0]}, {"basis": [[1, 0], [0, 1, 0], [0, 0, 1]], "origin": [0, 0, 0]}, {"basis": [[1, 0, 0], [0, INF, 0], [0, 0, 1]], "origin": [0, 0, 0]}, {"basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "origin": [0, "bad", 0]}]:
		_check("malformed_report_transform_%d" % _checks.size(), not Visual._reported_transform(invalid).origin.is_finite())
	_critic_blocker_controls()
	_parity_diagnostic_controls()
	_two_pass_prediction_controls()
	_camera_surface_controls()
	await _shard_controls()
	_brick_face_controls()
	_below_bearer_controls()
	var baseline := OS.get_environment("VOXEL_CHIMNEY_REVIEWED_BASELINE").strip_edges()
	var evidence := OS.get_environment("VOXEL_CHIMNEY_PUBLISHED_EVIDENCE").strip_edges()
	var requested := not baseline.is_empty() or not evidence.is_empty()
	var preparation: Dictionary = {"requested": requested, "ready": false, "reason": "not_requested"}
	var publication_preflight: Dictionary = {"requested": requested, "completed": false, "passed": false}
	if requested:
		_fixture = Visual.new() # Not added to root: _ready/publication cannot run.
		_thread = Thread.new()
		var start_error := _thread.start(_fixture._prepare_review.bind(baseline, evidence))
		if start_error == OK:
			while _thread.is_alive(): await process_frame
			var result: Variant = _thread.wait_to_finish()
			_thread = null
			preparation = result if result is Dictionary else {"ready": false, "reason": "invalid_worker_result"}
			preparation["requested"] = true
			if bool(preparation.get("ready", false)):
				_check("actual_preparation_11_constructed_5_unchanged", preparation.constructed.size() == 11 and preparation.blocked.size() == 5)
				_check("actual_authored_source_exact", bool(preparation.sourceExactExcept11BearersAndMandatoryChimneySeats))
				_check("actual_regenerated_furniture_access_exact", bool(preparation.regeneratedFurnitureAndAccessExact) and preparation.furnishingPlan.parts.size() == 152)
				_check("actual_immutable_input_exact", FileAccess.get_sha256(baseline) == Visual.REVIEW_SHA)
				_check("actual_published_evidence_unchanged", FileAccess.get_sha256(evidence) == preparation.publishedEvidenceSha256)
				publication_preflight = _begin_publication_preflight(preparation)
				preparation["brickDetailPreflight"] = _actual_brick_detail_preflight(preparation)
				_check("actual_exact_eight_bricks_four_face_children", bool(preparation.brickDetailPreflight.ready))
			for key in ["blueprint", "furnishingPlan", "evidence", "expectedPublishedSourceSnapshot", "expectedFurnitureSnapshot"]: preparation.erase(key)
		else:
			preparation = {"requested": true, "ready": false, "reason": "worker_start_failed", "error": start_error}
		_cleanup_worker()
	var controls_passed: bool = _checks.all(func(check): return bool(check.passed))
	var ready: bool = requested and bool(preparation.get("ready", false))
	var report := {"evidenceLevel": "synthetic_camera_math_and_optional_actual_source_preparation_contract",
		"contractPassed": controls_passed, "actualSourceReady": ready, "preparation": preparation,
		"publicationPreflight": publication_preflight,
		"passed": controls_passed and (not requested or (ready and bool(publication_preflight.passed))), "checks": _checks,
		"headedCaptureReadinessProven": false, "visualAcceptance": false, "elapsedMsec": Time.get_ticks_msec() - started,
		"doesNotProve": "No part publication, live camera fit, all-target visibility, buffer readback cost, screenshots, physical movement, navigation or whole-citadel acceptance. Real begin_publication is a source-service diagnostic only. Its prediction mismatch remains red independently of preparation readiness. Headed launch still requires a new critic readiness grant."}
	var wrote: bool = Visual._write_json(path, report)
	quit(0 if wrote and bool(report.passed) else 1)


func _check(label: String, passed: bool) -> void:
	_checks.append({"name": label, "passed": passed})


func _shard_controls() -> void:
	# Synthetic inventory/selection only. Full live geometry still comes from
	# _view_specs before the production selection call; no acceptance credit.
	var specs: Array = []
	for index in range(24):
		var kind: String = "brick_cluster" if index >= 22 else ("ordinary" if index % 2 == 0 else "assembly")
		specs.append({"id": "%02d_%s" % [index, kind], "kind": kind, "bearerId": "synthetic_bearer", "bounds": AABB(Vector3.ZERO, Vector3.ONE)})
		if kind == "brick_cluster":
			var parent_id: String = specs[index].id
			specs[index]["children"] = [
				{"id": parent_id + "_face_negative", "parentId": parent_id, "kind": "brick_face"},
				{"id": parent_id + "_face_positive", "parentId": parent_id, "kind": "brick_face"}]
	var before: PackedByteArray = var_to_bytes(specs)
	var selection: Dictionary = Visual._select_views(specs, "19_assembly,21_assembly,22_brick_cluster,23_brick_cluster", true)
	var selected_ids: Array = ["19_assembly", "21_assembly", "22_brick_cluster_face_negative", "22_brick_cluster_face_positive", "23_brick_cluster_face_negative", "23_brick_cluster_face_positive"]
	_check("shard_parents_expand_exact_children_full_inventory_retained", bool(selection.ready) and bool(selection.fullInventoryValidated) and selection.mode == "shard" and selection.selectedIds == selected_ids and selection.fullInventoryIds.size() == 24 and selection.notSelectedIds.size() == 20)
	var reordered: Dictionary = Visual._select_views(specs, "23_brick_cluster,19_assembly,22_brick_cluster,21_assembly", true)
	_check("shard_canonical_inventory_order_not_env_order", bool(reordered.ready) and reordered.selectedIds == selected_ids)
	var full: Dictionary = Visual._select_views(specs, "", false)
	_check("full_parent_inventory_does_not_inflate_24_capture_limit", not bool(full.ready) and full.reason == "expanded_capture_limit_requires_shard" and full.fullInventoryIds.size() == 24 and full.availableCaptureIds.size() == 26)
	var detail_only: Dictionary = Visual._select_views(specs, "22_brick_cluster,23_brick_cluster", true)
	_check("detail_only_selects_four_not_existing_assemblies", bool(detail_only.ready) and detail_only.selectedIds == selected_ids.slice(2))
	var direct_children: Dictionary = Visual._select_views(specs, ",".join(PackedStringArray(selected_ids.slice(2))), true)
	_check("explicit_child_ids_match_parent_expansion", bool(direct_children.ready) and direct_children.selectedIds == detail_only.selectedIds)
	for bad in ["", "19_assembly,19_assembly", "19_assembly,", ",19_assembly", "19_assembly,,21_assembly", "19", "19_ordinary", "24_assembly", "19_assembly, 21_assembly", "19_assembly\n", "*", "x".repeat(1025), "19_assembly,".repeat(25), "22_brick_cluster,22_brick_cluster_face_negative", "22_brick_cluster_face_unknown"]:
		_check("shard_strict_invalid_allowlist_%d" % _checks.size(), not bool(Visual._select_views(specs, bad, true).ready))
	_check("shard_inconsistent_absent_env_rejects", not bool(Visual._select_views(specs, "19_assembly", false).ready))
	_check("shard_short_inventory_rejects_before_selection", not bool(Visual._select_views(specs.slice(0, 23), "19_assembly", true).ready))
	var broken: Array = specs.duplicate(true)
	broken[0].id = "unexpected_unselected_id"
	_check("shard_invalid_unselected_inventory_rejects", not bool(Visual._select_views(broken, "19_assembly", true).ready))
	broken = specs.duplicate(true)
	broken[0].kind = "assembly"
	_check("shard_invalid_unselected_kind_rejects", not bool(Visual._select_views(broken, "19_assembly", true).ready))
	broken = specs.duplicate(true)
	broken[22].children.pop_back()
	_check("shard_missing_unselected_face_child_rejects", not bool(Visual._select_views(broken, "19_assembly", true).ready))
	broken = specs.duplicate(true)
	broken[23].children[0].parentId = "22_brick_cluster"
	_check("shard_cross_parent_child_rejects", not bool(Visual._select_views(broken, "19_assembly", true).ready))
	_check("shard_selection_never_mutates_inventory", var_to_bytes(specs) == before)
	var rows: Array = []
	for id in selected_ids:
		rows.append({"id": id, "attempted": true, "captured": true, "visibilityRestored": true})
	var completion: Dictionary = Visual._selected_completion(selection, rows)
	_check("shard_complete_is_not_full_complete", bool(completion.selectedComplete) and bool(completion.shardComplete) and not bool(completion.fullComplete))
	_check("shard_rows_cannot_complete_full_run", not bool(Visual._selected_completion(full, rows).selectedComplete))
	var full_rows: Array = []
	for id in full.fullInventoryIds:
		full_rows.append({"id": id, "attempted": true, "captured": true, "visibilityRestored": true})
	completion = Visual._selected_completion(full, full_rows)
	_check("parent_capture_flags_cannot_fulfill_uncredited_children", not bool(completion.fullComplete) and not bool(completion.selectedComplete))
	for field in ["attempted", "captured", "visibilityRestored"]:
		var incomplete: Array = rows.duplicate(true)
		incomplete[0][field] = false
		_check("shard_mandatory_row_%s" % field, not bool(Visual._selected_completion(selection, incomplete).selectedComplete))
	var duplicate: Array = rows.duplicate(true)
	duplicate[1] = duplicate[0].duplicate()
	_check("shard_duplicate_credit_rejects", not bool(Visual._selected_completion(selection, duplicate).selectedComplete))
	var work: Dictionary = Visual._view_work(101, 137, 2000, 2055)
	_check("view_work_exact_delta_no_counter_reset", work.rayTestsStart == 101 and work.rayTestsEnd == 137 and work.rayTestsDelta == 36 and work.elapsedMsec == 55)
	var fixture = Visual.new() # No tree, scene, renderer or actual camera setup.
	fixture._ray_tests = Visual.MAX_RAY_TESTS
	_check("ray_limit_exactly_exhausted", fixture._budget_reason() == "ray_budget_exhausted")
	var exhausted: Dictionary = await fixture._choose_view({})
	_check("budget_precedes_camera_or_geometry_classification", not bool(exhausted.ok) and exhausted.reason == "ray_budget_exhausted" and not bool(exhausted.geometricVisibilityDetermined) and not exhausted.has("evidence"))
	_check("budget_blocks_callback_without_new_tests", not fixture._ordinary_visibility_target(Vector3.ZERO, {}).is_finite() and fixture._ray_tests == Visual.MAX_RAY_TESTS)
	_check("budget_blocks_first_hit_without_new_tests", fixture._first_visual_hit(Vector3.ZERO, Vector3.ONE).is_empty() and fixture._ray_tests == Visual.MAX_RAY_TESTS)
	var skipped: Dictionary = fixture._capture_row(specs[19], Visual._budget_view_result("ray_budget_exhausted", false), false, fixture._ray_tests, 42)
	_check("budget_unstarted_view_explicit_zero_work", not bool(skipped.attempted) and skipped.camera.reason == "not_attempted_budget_exhausted" and skipped.camera.budgetReason == "ray_budget_exhausted" and skipped.work.rayTestsDelta == 0 and skipped.work.elapsedMsec == 0)
	var timed: Dictionary = Visual._budget_view_result("time_budget_exhausted", true)
	_check("time_exhaustion_not_geometric_failure", timed.reason == "time_budget_exhausted" and not bool(timed.geometricVisibilityDetermined))
	fixture.free()


func _synthetic_face_cluster(transform: Transform3D, separation: float = 0.6, brick_height: float = 1.0) -> Dictionary:
	var groups: Array = []
	var bearer_bounds: AABB = transform * AABB(Vector3(-0.36, 1, -0.15), Vector3(0.72, 0.4, 4))
	for index in range(4):
		var local: Vector3 = Vector3(-separation * 0.5 if index % 2 == 0 else separation * 0.5, brick_height, -0.16 if index < 2 else 0.16)
		var primitive: Dictionary = {"partId": "synthetic_wall", "index": [41, 7, 123, 2][index],
			"transform": transform * Transform3D(Basis.from_scale(Vector3(0.6, 0.04, 0.08)), local),
			"localBounds": AABB(Vector3.ONE * -0.5, Vector3.ONE)}
		var group: Dictionary = Visual._brick_review_group(primitive, "synthetic_bearer", bearer_bounds, "synthetic")
		group["brickPrimitiveId"] = "opaque_geometry_%d" % index
		groups.append(group)
	return {"id": "synthetic_parent", "bearerId": "synthetic_bearer", "prefix": "synthetic", "bricks": groups}


func _below_bearer_controls() -> void:
	# Pure geometry controls, not a renderer or a claim about the frozen scene.
	var wall: Transform3D = Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	var bearer: Dictionary = {"partId": "synthetic_bearer", "index": 0, "transform": wall,
		"localBounds": AABB(Vector3(-0.36, 1, -0.15), Vector3(0.72, 0.4, 4))}
	var children: Array = Visual._brick_face_children(_synthetic_face_cluster(wall, 0.64), wall, Vector3(4, 2, 0.3))
	_check("below_bearer_control_has_two_faces", children.size() == 2)
	if children.size() != 2: return
	var child: Dictionary = children[1]
	var before: PackedByteArray = var_to_bytes([child, bearer])
	var candidate: Dictionary = Visual._below_bearer_candidate(child, bearer)
	_check("below_bearer_exposed_bands_and_real_gap_ready", bool(candidate.get("ready", false)))
	if not bool(candidate.get("ready", false)): return
	_check("below_bearer_one_pose_below_both_bands_and_seat", candidate.position.y < candidate.bearerUndersideY and candidate.brickSamples.size() == 2 and candidate.brickSamples.all(func(sample): return sample.point.y < candidate.bearerUndersideY))
	_check("below_bearer_local_six_pairs_not_full_scene_proof", candidate.localJointClearance.pairTests == 6 and bool(candidate.localJointClearance.clear) and not bool(candidate.fullSceneVisibilityProven) and String(candidate.evidenceScope).contains("not_buried_internal_patch"))
	_check("below_bearer_source_preserved", before == var_to_bytes([child, bearer]))
	var reversed: Dictionary = child.duplicate(true)
	reversed.bricks.reverse()
	_check("below_bearer_order_stable", var_to_bytes(candidate) == var_to_bytes(Visual._below_bearer_candidate(reversed, bearer)))
	var wrong: Dictionary = child.duplicate(true)
	wrong.faceNormal = -(wrong.faceNormal as Vector3)
	_check("below_bearer_wrong_face_band_rejects", not bool(Visual._below_bearer_candidate(wrong, bearer).ready))
	for separation in [0.6, 0.5]:
		var false_gap: Array = Visual._brick_face_children(_synthetic_face_cluster(wall, float(separation)), wall, Vector3(4, 2, 0.3))
		_check("below_bearer_touching_or_overlapping_not_gap_%s" % separation, false_gap.size() == 2 and not bool(Visual._below_bearer_candidate(false_gap[1], bearer).ready))
	var covered: Array = Visual._brick_face_children(_synthetic_face_cluster(wall, 0.64, 1.1), wall, Vector3(4, 2, 0.3))
	_check("below_bearer_entire_band_above_underside_rejects", covered.size() == 2 and Visual._below_bearer_candidate(covered[1], bearer).reason == "brick_has_no_exposed_lower_band")
	var tilted: Dictionary = bearer.duplicate(true)
	tilted.transform = Transform3D(Basis(Vector3.RIGHT, 0.1), wall.origin)
	_check("below_bearer_tilted_mesh_not_aabb_underside", not bool(Visual._below_bearer_candidate(child, tilted).ready))
	var displaced: Dictionary = bearer.duplicate(true)
	displaced.transform = Transform3D(Basis.IDENTITY, wall.origin + Vector3(3, 0, 0))
	_check("below_bearer_gap_not_under_bearer_rejects", not bool(Visual._below_bearer_candidate(child, displaced).ready))
	# Real-node synthetic first-hit controls keep the original full-scene query,
	# and show that a derived target cannot turn a covering mesh into evidence.
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var fixture = Visual.new()
	var camera: Camera3D = Camera3D.new()
	parent.add_child(camera)
	fixture._camera = camera
	camera.position = candidate.position
	var brick: Dictionary = _synthetic_visual_box(fixture, parent, "synthetic_wall", Vector3(-0.32, 2, 0.16), Vector3(0.6, 0.04, 0.08))
	var primitive: Dictionary = fixture._primitive(brick, 0)
	var target_point: Vector3 = candidate.brickSamples[0].point
	var spec: Dictionary = {"bounds": child.bounds, "targets": ["synthetic_wall"], "exactPrimitive": primitive,
		"inspectionSamples": {"synthetic_wall": target_point}, "prefix": "synthetic"}
	_check("below_bearer_actual_surface_first_hit_required", fixture._targets_visible(spec, false))
	var invalid: Dictionary = spec.duplicate()
	invalid.inspectionSamples = {"synthetic_wall": Vector3(0, 20, 0)}
	_check("below_bearer_wrong_review_band_rejects", not fixture._targets_visible(invalid, false))
	_synthetic_visual_box(fixture, parent, "foreign_band_cover", (camera.position + target_point) * 0.5, Vector3(4, 1, 0.1))
	_check("below_bearer_cover_still_blocks_real_first_hit", not fixture._targets_visible(spec, false))
	_check("below_bearer_cover_reported_not_hidden", fixture._visibility_failure.get("failedSamples", []).size() > 0 and fixture._visibility_failure.failedSamples[0].firstBlocker.get("partId") == "foreign_band_cover" and fixture._hidden.is_empty())
	fixture.free()
	parent.free()


func _brick_face_controls() -> void:
	var wall: Transform3D = Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	var size: Vector3 = Vector3(4, 2, 0.3)
	var cluster: Dictionary = _synthetic_face_cluster(wall)
	var before: PackedByteArray = var_to_bytes(cluster)
	var children: Array = Visual._brick_face_children(cluster, wall, size)
	_check("face_partition_two_children_from_four_exact_bricks", children.size() == 2)
	if children.size() != 2: return
	_check("face_partition_uses_geometry_not_ordinal_ranges", children[0].brickPrimitiveIds == ["opaque_geometry_0", "opaque_geometry_1"] and children[1].brickPrimitiveIds == ["opaque_geometry_2", "opaque_geometry_3"])
	_check("face_normals_opposed_and_parent_retained", children[0].faceNormal == Vector3.FORWARD and children[1].faceNormal == Vector3.BACK and children.all(func(child): return child.parentId == "synthetic_parent" and child.bricks.size() == 2 and child.interfaceIds == ["synthetic_bearer:synthetic_wall"]))
	_check("face_grouping_never_mutates_source", var_to_bytes(cluster) == before)
	var reversed: Dictionary = cluster.duplicate(true)
	reversed.bricks.reverse()
	_check("face_grouping_input_order_stable", var_to_bytes(Visual._brick_face_children(reversed, wall, size)) == var_to_bytes(children))
	var rotated: Transform3D = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(8, 3, -7))
	var rotated_children: Array = Visual._brick_face_children(_synthetic_face_cluster(rotated), rotated, size)
	_check("face_grouping_rotated_translated_source", rotated_children.size() == 2 and rotated_children[0].brickPrimitiveIds == children[0].brickPrimitiveIds and (rotated_children[1].faceNormal as Vector3).dot(rotated.basis.z) > 0.99)
	var thin_x: Array = Visual._brick_face_children(cluster, Transform3D(Basis(Vector3.UP, PI * 0.5), wall.origin), Vector3(0.3, 2, 4))
	_check("face_axis_derived_not_assumed_local_z", thin_x.size() == 2 and thin_x[0].thinAxis == 0 and thin_x[0].brickPrimitiveIds == children[1].brickPrimitiveIds)
	for bad_size in [Vector3(1, 2, 1), Vector3(4, 0.1, 0.3), Vector3(4, 2, 0), Vector3(NAN, 2, 0.3)]:
		_check("face_invalid_wall_bounds_%d" % _checks.size(), Visual._brick_face_children(cluster, wall, bad_size).is_empty())
	_check("face_singular_wall_transform_rejects", Visual._brick_face_children(cluster, Transform3D(Basis.from_scale(Vector3(1, 0, 1)), Vector3.ZERO), size).is_empty())
	var broken: Dictionary = cluster.duplicate(true)
	broken.bricks.pop_back()
	_check("face_missing_exact_brick_rejects", Visual._brick_face_children(broken, wall, size).is_empty())
	broken = cluster.duplicate(true)
	broken.bricks[1].exactPrimitive.index = broken.bricks[0].exactPrimitive.index
	_check("face_duplicate_primitive_different_label_rejects", Visual._brick_face_children(broken, wall, size).is_empty())
	broken = cluster.duplicate(true)
	broken.bricks[0].exactPrimitive.partId = "foreign_wall"
	_check("face_foreign_owner_rejects", Visual._brick_face_children(broken, wall, size).is_empty())
	broken = cluster.duplicate(true)
	var straddling: Transform3D = broken.bricks[0].exactPrimitive.transform
	straddling.origin.z = 0
	broken.bricks[0].exactPrimitive.transform = straddling
	_check("face_brick_straddling_wall_midplane_rejects", Visual._brick_face_children(broken, wall, size).is_empty())
	broken = cluster.duplicate(true)
	var wrong_side: Transform3D = broken.bricks[0].exactPrimitive.transform
	wrong_side.origin.z *= -1
	broken.bricks[0].exactPrimitive.transform = wrong_side
	_check("face_unbalanced_partition_rejects", Visual._brick_face_children(broken, wall, size).is_empty())
	_check("face_camera_wrong_side_rejects", not Visual._face_camera_allowed(children[0], Vector3(0, 2.5, 2)) and Visual._face_camera_allowed(children[0], Vector3(0, 2.5, -2)))
	_check("face_camera_nonfinite_rejects", not Visual._face_camera_allowed(children[0], Vector3(NAN, 0, 0)))
	var fact: Dictionary = Visual._detail_fact(children[0])
	_check("face_inventory_no_automatic_parent_credit", not bool(fact.parentFulfilled) and fact.bricks.size() == 2 and fact.externalCredit == "not_assessed_both_child_images_required")
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var wall_node: Node3D = Node3D.new()
	var bearer_node: Node3D = Node3D.new()
	var opposite_bricks: Node3D = Node3D.new()
	for node in [wall_node, bearer_node, opposite_bricks]: parent.add_child(node)
	var probe = DetailRequirementProbe.new()
	probe._part_visuals = {"synthetic_wall": [{"node": wall_node}, {"node": opposite_bricks}], "synthetic_bearer": [{"node": bearer_node}]}
	probe.visible_indices = [41]
	_check("face_child_one_exact_brick_insufficient", not probe._coverage_visible(children[0]))
	probe.visible_indices = [41, 7]
	_check("face_child_both_exact_bricks_and_bearer_required", probe._coverage_visible(children[0]))
	probe.bearer_seen = false
	_check("face_child_missing_bearing_interface_rejects", not probe._coverage_visible(children[0]))
	probe.bearer_seen = true
	for node in [wall_node, bearer_node, opposite_bricks]:
		node.visible = false
		_check("face_hidden_participant_or_opposite_bricks_reject_%d" % _checks.size(), not probe._coverage_visible(children[0]))
		node.visible = true
	probe.free()
	parent.free()


func _synthetic_visual_box(fixture, parent: Node3D, id: String, center: Vector3, size: Vector3) -> Dictionary:
	var node: MeshInstance3D = MeshInstance3D.new()
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.name = id
	parent.add_child(node)
	node.position = center
	var record: Dictionary = {"node": node, "partId": id, "count": 1, "bounds": node.global_transform * mesh.get_aabb()}
	fixture._visuals.append(record)
	fixture._part_visuals[id] = [record]
	return record


func _camera_surface_controls() -> void:
	# Synthetic boxes only. Run production probe/first-hit code against these
	# real node transforms; no publisher, physics simulation or GPU readback.
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var camera: Camera3D = Camera3D.new()
	parent.add_child(camera)
	var fixture = Visual.new() # Never enters tree / never invokes _ready.
	fixture._camera = camera
	var house: Dictionary = _synthetic_visual_box(fixture, parent, "synthetic_house", Vector3(0, 1.5, 0), Vector3(4, 3, 4))
	var chimney: Dictionary = _synthetic_visual_box(fixture, parent, "synthetic_chimney", Vector3(0, 4.5, 0), Vector3(0.6, 1, 0.6))
	camera.position = Vector3(0, 1.58, -8)
	var framing_center: Vector3 = Vector3(0, 1.5, 0)
	var old_hit: Dictionary = fixture._first_visual_hit(camera.position, framing_center)
	_check("synthetic_old_house_center_hits_solid_house", not old_hit.is_empty() and old_hit.partId == house.partId)
	var roof: AABB = AABB(Vector3(-2, 2.5, -2), Vector3(4, 1.5, 4))
	var exposed: AABB = Visual.exposed_chimney_window(chimney.bounds, roof)
	var ordinary: Dictionary = {"bounds": (house.bounds as AABB).merge(chimney.bounds), "probeBounds": exposed, "targets": [chimney.partId]}
	var surface: Vector3 = fixture._ordinary_visibility_target(camera.position, ordinary)
	_check("synthetic_exposed_actual_chimney_surface_visible", surface.is_finite() and Visual._inside_closed(exposed, surface) and fixture._targets_visible(ordinary, false))
	_check("synthetic_roof_above_chimney_no_exposed_window", not Visual._finite_box(Visual.exposed_chimney_window(chimney.bounds, AABB(Vector3(-2, 0, -2), Vector3(4, 6, 4)))))
	var primitive: Dictionary = fixture._primitive(chimney, 0)
	var probes: Array = Visual._surface_probes(primitive, exposed, camera.position)
	_check("surface_probes_bounded_and_actual_faces", not probes.is_empty() and probes.size() <= 15 and probes.all(func(point):
		var local: Vector3 = primitive.transform.affine_inverse() * point
		var box: AABB = primitive.localBounds
		return Visual._inside_closed(exposed, point) and (local.x == box.position.x or local.x == box.end.x or local.y == box.position.y or local.y == box.end.y or local.z == box.position.z or local.z == box.end.z)))
	_check("surface_probes_invalid_camera_failclosed", Visual._surface_probes(primitive, exposed, Vector3(NAN, 0, 0)).is_empty())
	_shared_camera_callback_controls(camera, framing_center, surface)
	fixture._visuals.clear()
	fixture._part_visuals.clear()
	house.node.free()
	chimney.node.free()
	var gable: Dictionary = _synthetic_visual_box(fixture, parent, "synthetic_gable", Vector3(0, 1, 0), Vector3(4, 2, 0.4))
	var bearer: Dictionary = _synthetic_visual_box(fixture, parent, "synthetic_bearer", Vector3(0, 2.2, 0), Vector3(1, 0.4, 4))
	camera.position = Vector3(4, 4, -5)
	var joint: Dictionary = {"bounds": Visual.joint_perimeter_window(bearer.bounds, gable.bounds), "targets": [gable.partId, bearer.partId], "prefix": "synthetic"}
	_check("synthetic_joint_perimeter_both_participants_visible", fixture._targets_visible(joint, true))
	_check("synthetic_joint_participant_cannot_be_hidden", not fixture._hide_own_occluder(gable.partId, joint) and not fixture._hide_own_occluder(bearer.partId, joint))
	bearer.node.visible = false
	_check("synthetic_hidden_bearer_rejects", not fixture._targets_visible(joint, true))
	bearer.node.visible = true
	joint["exactPrimitive"] = fixture._primitive(gable, 0)
	gable.node.visible = false
	_check("synthetic_hidden_exact_joint_primitive_rejects", not fixture._targets_visible(joint, true))
	gable.node.visible = true
	_check("synthetic_restored_exact_pair_visible", fixture._targets_visible(joint, true))
	_synthetic_visual_box(fixture, parent, "foreign_blocker", Vector3(2, 3, -2.5), Vector3(20, 20, 0.5))
	_check("synthetic_foreign_occlusion_still_rejects", not fixture._targets_visible(joint, true))
	var failure: Dictionary = fixture._visibility_failure
	_check("synthetic_failed_sample_first_blocker_diagnostic", failure.get("failedSamples", []).size() > 0 and failure.failedSamples.size() <= 8 and failure.failedSamples[0].firstBlocker.get("partId") == "foreign_blocker" and failure.failedSamples[0].sample is Vector3)
	_check("synthetic_visibility_tests_never_mask_participants", fixture._hidden.is_empty() and gable.node.visible and bearer.node.visible)
	fixture.free()
	parent.free()


func _shared_camera_callback_controls(camera: Camera3D, framing_center: Vector3, surface: Vector3) -> void:
	if not surface.is_finite():
		_check("shared_callback_controls_require_actual_finite_surface", false)
		return
	var solver = CameraSolverProbe.new() # Not in tree: mocked support/line services.
	var default_view: Dictionary = solver.make_exterior_review_view("synthetic", "mock_camera", framing_center, 20, 8, 8, 3, 0)
	var explicit_none: Dictionary = solver.make_exterior_review_view("synthetic", "mock_camera", framing_center, 20, 8, 8, 3, 0, -INF, Callable(), Callable())
	_check("shared_callback_none_preserves_exact_default_output", bool(default_view.cameraPoseOk) and var_to_bytes(default_view) == var_to_bytes(explicit_none) and not default_view.has("cameraPoseSightlineTarget"))
	_check("shared_default_both_line_services_use_framing_target", solver.physics_targets.all(func(point): return point == framing_center) and solver.visual_targets.all(func(point): return point == framing_center))
	solver.physics_targets.clear()
	solver.visual_targets.clear()
	var callback: Callable = func(_position: Vector3) -> Vector3: return surface
	var view: Dictionary = solver.make_exterior_review_view("synthetic", "mock_camera", framing_center, 20, 8, 8, 3, 0, -INF, Callable(), callback)
	_check("shared_callback_actual_surface_both_line_services", bool(view.cameraPoseOk) and view.target == framing_center and view.cameraPoseSightlineTarget == surface and solver.physics_targets == [surface] and solver.visual_targets == [surface])
	if not bool(view.cameraPoseOk):
		solver.free()
		return
	camera.position = view.position
	camera.look_at(framing_center, Vector3.UP)
	solver.physics_targets.clear()
	var audit: Dictionary = solver.audit_review_camera_contract(view, camera)
	_check("shared_audit_uses_recorded_surface_not_frame_center", bool(audit.passed) and solver.physics_targets == [surface])
	var invalid_view: Dictionary = view.duplicate(true)
	invalid_view.cameraPoseSightlineTarget = Vector3(NAN, 0, 0)
	_check("shared_audit_nonfinite_recorded_surface_rejects", not bool(solver.audit_review_camera_contract(invalid_view, camera).passed))
	for invalid in [Vector3(NAN, 0, 0), Vector3(INF, 0, 0), "wrong_type"]:
		solver.physics_targets.clear()
		solver.visual_targets.clear()
		var invalid_callback: Callable = func(_position: Vector3): return invalid
		var rejected: Dictionary = solver.make_exterior_review_view("synthetic", "mock_camera", framing_center, 20, 8, 8, 3, 0, -INF, Callable(), invalid_callback)
		_check("shared_invalid_callback_failclosed_%d" % _checks.size(), not bool(rejected.cameraPoseOk) and not rejected.has("cameraPoseSightlineTarget") and solver.physics_targets.is_empty() and solver.visual_targets.is_empty())
	solver.blocker = AABB(Vector3(-2, 0, -2), Vector3(4, 3, 4))
	var blocked: Dictionary = solver.make_exterior_review_view("synthetic", "mock_camera", framing_center, 20, 8, 8, 3, 0)
	var exposed: Dictionary = solver.make_exterior_review_view("synthetic", "mock_camera", framing_center, 20, 8, 8, 3, 0, -INF, Callable(), callback)
	_check("shared_synthetic_old_center_blocked_actual_surface_clear", not bool(blocked.cameraPoseOk) and bool(exposed.cameraPoseOk))
	solver.blocker = AABB(Vector3(-3, 0, -3), Vector3(6, 6, 6))
	blocked = solver.make_exterior_review_view("synthetic", "mock_camera", framing_center, 20, 8, 8, 3, 0, -INF, Callable(), callback)
	_check("shared_callback_does_not_waive_geometry_occlusion", not bool(blocked.cameraPoseOk) and int(blocked.cameraPoseRejections.physicsSightline) == 64)
	solver.blocker = AABB()
	solver.visual_allowed = false
	blocked = solver.make_exterior_review_view("synthetic", "mock_camera", framing_center, 20, 8, 8, 3, 0, -INF, Callable(), callback)
	_check("shared_callback_visual_line_independently_rejects", not bool(blocked.cameraPoseOk) and int(blocked.cameraPoseRejections.visualSightline) == 64)
	solver.free()


func _begin_publication_preflight(preparation: Dictionary) -> Dictionary:
	var candidate = PreflightCopy.copy_source(preparation.blueprint.snapshot())
	if not Visual._validation_bounded(candidate):
		return {"requested": true, "completed": false, "passed": false, "reason": "validation_budget"}
	var started: int = Time.get_ticks_msec()
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var publisher = PreflightPublisher.new()
	# Public owner, normal options, real tree parent. Do not reproduce its route
	# or physical mutation logic here, and do not publish/render any part.
	var begun: bool = publisher.begin_publication(candidate, parent)
	var actual_furniture: Array = [preparation.furnishingPlan.snapshot(), preparation.furnishingPlan.protected_access_reservations]
	var result: Dictionary = Visual._publication_parity_evidence(
		{"ready": begun, "scope": "real_begin_publication_only_not_capture_readiness"},
		preparation.expectedPublishedSourceSnapshot, candidate.snapshot(), preparation.expectedFurnitureSnapshot, actual_furniture)
	result["requested"] = true
	result["completed"] = begun
	result["partPublicationCount"] = publisher.published_part_count
	result["parentChildCount"] = parent.get_child_count()
	result["elapsedMsec"] = Time.get_ticks_msec() - started
	_check("begin_publication_preflight_publishes_no_parts", publisher.published_part_count == 0 and parent.get_child_count() == 0)
	parent.free()
	return result


func _reported_box_record(value: Dictionary, owner: String) -> Dictionary:
	if value.get("type") != "box" or not value.get("id") is String or not value.get("transform") is Dictionary or not value.get("localMeshBounds") is Dictionary: return {}
	var labels: PackedStringArray = value.id.split(":")
	if labels.size() != 3 or labels[0] != "box" or not labels[2].is_valid_int() or int(labels[2]) < 0: return {}
	var vectors: Array[Vector3] = []
	for key in ["position", "size"]:
		var components: Variant = value.localMeshBounds.get(key)
		if not components is Array or components.size() != 3: return {}
		for number in components:
			if not (number is float or number is int) or not is_finite(number): return {}
		vectors.append(Vector3(components[0], components[1], components[2]))
	var record: Dictionary = {"partId": owner, "index": int(labels[2]), "transform": Visual._reported_transform(value.transform), "localBounds": AABB(vectors[0], vectors[1])}
	return record if Visual._primitive_record_valid(record) else {}


func _actual_brick_detail_preflight(preparation: Dictionary) -> Dictionary:
	# Frozen real publisher evidence + private actual producer source. This
	# predicts grouping only, NOT live visibility or credit for prior images.
	var rejected: Dictionary = {"ready": false, "reason": "invalid_exact_brick_face_inventory", "visualReadinessProven": false}
	var evidence: Dictionary = preparation.evidence
	if not evidence.get("contacts") is Array or evidence.contacts.size() > 4096 or not evidence.get("relevantPayloads") is Dictionary: return rejected
	var before: String = Visual._digest(preparation.blueprint.snapshot())
	var clusters: Dictionary = {}
	var exact_ids: Dictionary = {}
	for contact in evidence.contacts:
		if not contact is Dictionary: return rejected
		if contact.get("channel") != "visual": continue
		if not contact.get("measurement") is Dictionary or not contact.measurement.get("candidates") is Array or contact.measurement.candidates.size() > 4096: return rejected
		for pair in contact.measurement.candidates:
			if not pair is Dictionary or not pair.get("bPrimitive") is Dictionary: return rejected
			var reported: Dictionary = pair.bPrimitive
			if reported.get("id") == "box:0:0": continue
			if not String(reported.get("id", "")).begins_with("box:1:"): return rejected
			var wall_id: String = String(contact.get("otherId", ""))
			var bearer_id: String = String(contact.get("bearerId", ""))
			var primitive: Dictionary = _reported_box_record(reported, wall_id)
			var payload: Variant = evidence.relevantPayloads.get(bearer_id, {}).get("visual", {})
			if primitive.is_empty() or not payload is Dictionary or not payload.get("primitives") is Array or payload.primitives.size() != 1: return rejected
			var bearer: Dictionary = _reported_box_record(payload.primitives[0], bearer_id)
			if bearer.is_empty(): return rejected
			var identity: String = wall_id + ":" + String(reported.id)
			if exact_ids.has(identity): return rejected
			exact_ids[identity] = true
			var group: Dictionary = Visual._brick_review_group(primitive, bearer_id, bearer.transform * bearer.localBounds, bearer_id.trim_suffix("_chimney_bearing"))
			if group.is_empty(): return rejected
			group["brickPrimitiveId"] = identity
			if not clusters.has(bearer_id):
				clusters[bearer_id] = {"id": "%02d_brick_cluster" % (22 + clusters.size()), "bearerId": bearer_id, "bricks": [], "bearerPrimitive": bearer}
			clusters[bearer_id].bricks.append(group)
			if exact_ids.size() > 8 or clusters.size() > 2: return rejected
	if exact_ids.size() != 8 or clusters.size() != 2: return rejected
	var details: Array = []
	for cluster in clusters.values():
		var wall_id: String = cluster.bricks[0].exactPrimitive.partId
		var wall = preparation.blueprint.find_part(wall_id)
		if wall == null or wall.kind != "wall": return rejected
		var children: Array = Visual._brick_face_children(cluster, Transform3D(Basis.from_euler(wall.rotation), wall.position), wall.size)
		if children.size() != 2: return rejected
		for child in children:
			child["inspectionCandidate"] = Visual._below_bearer_candidate(child, cluster.bearerPrimitive)
			details.append(Visual._detail_fact(child))
	var unchanged: bool = before == Visual._digest(preparation.blueprint.snapshot())
	return {"ready": unchanged and details.size() == 4, "sourceUnchanged": unchanged, "exactBrickCount": exact_ids.size(),
		"detailInventory": details, "visualReadinessProven": false, "parentFulfilled": false, "priorImagesCredited": false,
		"evidenceScope": "fresh_geometry_projection_of_frozen_real_publisher_boxes_not_live_camera_proof"}


func _parity_diagnostic_controls() -> void:
	var source: Dictionary = {"parts": [{"id": "synthetic_part", "position": Vector3(1, 2, 3), "recipe": {"physicalIntentResolution": "building_part_taxonomy"}}]}
	var actual: Dictionary = source.duplicate(true)
	actual.parts[0].recipe.physicalIntentResolution = "recipe"
	var diagnostic: Dictionary = Visual._publication_parity_evidence({"ready": true}, source, actual, [], [])
	_check("source_parity_diff_not_waived_as_metadata", not bool(diagnostic.passed) and not bool(diagnostic.source.exact) and bool(diagnostic.furniture.exact) and bool(diagnostic.readinessPassed))
	_check("recursive_leaf_identifies_part_and_fact", diagnostic.source.leafDiff.rows.size() == 1 and String(diagnostic.source.leafDiff.rows[0].path).contains("synthetic_part") and String(diagnostic.source.leafDiff.rows[0].path).ends_with("/physicalIntentResolution"))
	_check("recursive_leaf_retains_actual_expected_values", diagnostic.source.leafDiff.rows[0].expected == "building_part_taxonomy" and diagnostic.source.leafDiff.rows[0].actual == "recipe")
	actual.parts[0].position.x += 1
	diagnostic = Visual._publication_parity_evidence({"ready": true}, source, actual, [], [])
	_check("geometry_mismatch_still_rejected_and_reported", not bool(diagnostic.passed) and diagnostic.source.leafDiff.rows.any(func(row): return String(row.path).ends_with("/position")))
	diagnostic = Visual._publication_parity_evidence({"ready": false, "timedOut": true}, source, source, [], [])
	_check("readiness_failure_independent_of_exact_snapshots", not bool(diagnostic.passed) and bool(diagnostic.source.exact) and bool(diagnostic.furniture.exact) and bool(diagnostic.readiness.timedOut))
	diagnostic = Visual._publication_parity_evidence({"ready": true}, source, source, ["old_material"], ["new_material"])
	_check("furniture_failure_independent_of_source", not bool(diagnostic.passed) and bool(diagnostic.source.exact) and not bool(diagnostic.furniture.exact))
	var many_old: Array = []
	var many_new: Array = []
	for index in range(Visual.MAX_DIFF_ROWS + 8):
		many_old.append(index)
		many_new.append(-index - 1)
	var bounded: Dictionary = Visual._bounded_leaf_diff(many_old, many_new)
	_check("leaf_diff_row_budget_explicit", bounded.rows.size() == Visual.MAX_DIFF_ROWS and bool(bounded.truncated))
	var nested_old: Variant = 0
	var nested_new: Variant = 1
	for index in range(Visual.MAX_DIFF_DEPTH + 2):
		nested_old = [nested_old]
		nested_new = [nested_new]
	bounded = Visual._bounded_leaf_diff(nested_old, nested_new)
	_check("leaf_diff_depth_budget_explicit", bool(bounded.truncated) and bounded.stopReason == "depth")
	var reordered: Dictionary = {"b": 2, "a": 1}
	bounded = Visual._bounded_leaf_diff({"a": 1, "b": 2}, reordered)
	_check("serialization_key_order_difference_visible", bounded.rows.size() == 1 and bounded.rows[0].kind == "dictionary_keys_or_order")
	bounded = Visual._bounded_leaf_diff({}, {"new": "leaf"})
	_check("added_leaf_visible", bounded.rows.any(func(row): return row.kind == "added_actual_key" and row.actual == "leaf"))


func _two_pass_prediction_controls() -> void:
	# Small source-service fixture: no generated world, part publication or
	# route acceptance. Empty street records deliberately remain route-unready.
	var source = PredictionBlueprint.new("synthetic_prediction", 1, "timber")
	source.recipe = {"castleGrammar": {"courtyardGrid": {"mode": "district_grid", "streetRecords": []}}}
	source.add_part({"id": "synthetic_foundation", "kind": "foundation", "collision": true,
		"position": Vector3(0, 0.25, 0), "size": Vector3(4, 0.5, 4)})
	source.add_part({"id": "synthetic_wall", "kind": "wall", "collision": true,
		"position": Vector3(0, 1, 0), "size": Vector3(1, 1, 0.2)})
	var original: Dictionary = source.snapshot()
	var single = PreflightCopy.copy_source(original)
	single.validate_physical_integrity()
	var predicted = PreflightCopy.copy_source(original)
	var prediction: Dictionary = Visual._predict_publication_validation(predicted)
	_check("two_pass_prediction_ready_but_not_route_acceptance", bool(prediction.ready) and not bool(prediction.routeCoverage.passed))
	_check("two_pass_resolution_not_single_pass", single.parts[0].recipe.physicalIntentResolution == "building_part_taxonomy" and predicted.parts[0].recipe.physicalIntentResolution == "recipe" and var_to_bytes(single.snapshot()) != var_to_bytes(predicted.snapshot()))
	var actual = PreflightCopy.copy_source(original)
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var publisher = PreflightPublisher.new()
	var begun: bool = publisher.begin_publication(actual, parent)
	var expected: Dictionary = predicted.snapshot()
	var actual_snapshot: Dictionary = actual.snapshot()
	_check("two_pass_complete_snapshot_matches_real_begin", begun and var_to_bytes(expected) == var_to_bytes(actual_snapshot))
	_check("two_pass_source_input_unchanged", var_to_bytes(original) == var_to_bytes(source.snapshot()))
	_check("two_pass_control_no_part_publication", publisher.published_part_count == 0 and parent.get_child_count() == 0)
	parent.free()
	var furniture: Array = [{"id": "synthetic_storage", "position": Vector3(1, 0, 1), "material": "cloth", "contents": ["grain"]}]
	var moved: Dictionary = actual_snapshot.duplicate(true)
	moved.parts[1].position = (moved.parts[1].position as Vector3) + Vector3(0.125, 0, 0)
	var parity: Dictionary = Visual._publication_parity_evidence({"ready": true}, expected, moved, furniture, furniture)
	_check("two_pass_prediction_still_rejects_geometry_change", not bool(parity.passed) and not bool(parity.source.exact) and bool(parity.furniture.exact))
	var changed_furniture: Array = furniture.duplicate(true)
	changed_furniture[0].contents[0] = "coal"
	parity = Visual._publication_parity_evidence({"ready": true}, expected, actual_snapshot, furniture, changed_furniture)
	_check("two_pass_prediction_still_rejects_furniture_contents_change", not bool(parity.passed) and bool(parity.source.exact) and not bool(parity.furniture.exact))


func _critic_blocker_controls() -> void:
	var box: AABB = AABB(Vector3.ONE * -0.5, Vector3.ONE)
	_check("primitive_identity_valid", Visual._primitive_record_valid({"transform": Transform3D.IDENTITY, "localBounds": box}))
	_check("primitive_nonuniform_valid", Visual._primitive_record_valid({"transform": Transform3D(Basis.from_scale(Vector3(1, 2, 3)), Vector3(4, 5, 6)), "localBounds": box}))
	_check("zero_thickness_plane_still_retained", Visual._primitive_record_valid({"transform": Transform3D.IDENTITY, "localBounds": AABB(Vector3.ZERO, Vector3(1, 0, 1))}))
	var bad_transforms: Array[Transform3D] = [
		Transform3D(Basis(Vector3.ZERO, Vector3.UP, Vector3.BACK), Vector3.ZERO),
		Transform3D(Basis(Vector3.RIGHT, Vector3.RIGHT, Vector3.BACK), Vector3.ZERO),
		Transform3D(Basis(Vector3(NAN, 0, 0), Vector3.UP, Vector3.BACK), Vector3.ZERO),
		Transform3D(Basis.IDENTITY, Vector3(INF, 0, 0))]
	for index in range(bad_transforms.size()):
		_check("individual_instance_rejects_before_inverse_%d" % index, not Visual._primitive_record_valid({"transform": bad_transforms[index], "localBounds": box}))
	_check("malformed_primitive_rejects", not Visual._primitive_record_valid({"transform": "not_transform", "localBounds": box}))
	_check("nonfinite_local_bounds_rejects", not Visual._primitive_record_valid({"transform": Transform3D.IDENTITY, "localBounds": AABB(Vector3(NAN, 0, 0), Vector3.ONE)}))
	_check("negative_local_bounds_rejects", not Visual._primitive_record_valid({"transform": Transform3D.IDENTITY, "localBounds": AABB(Vector3.ZERO, Vector3(-1, 1, 1))}))
	_check("overflowed_world_bounds_rejects", not Visual._primitive_record_valid({"transform": Transform3D(Basis.IDENTITY, Vector3(3.0e38, 0, 0)), "localBounds": AABB(Vector3.ZERO, Vector3(2.0e38, 1, 1))}))
	var brick: Dictionary = {"partId": "synthetic_gable", "transform": Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)), "localBounds": AABB(Vector3(-0.5, -0.02, -0.1), Vector3(1, 0.04, 0.2))}
	var bearer: AABB = AABB(Vector3(-0.3, 2, -1), Vector3(0.6, 0.4, 2))
	var group: Dictionary = Visual._brick_review_group(brick, "synthetic_bearer", bearer, "synthetic")
	_check("brick_closeup_requires_both_participants", not group.is_empty() and group.targets == ["synthetic_gable", "synthetic_bearer"])
	if not group.is_empty():
		_check("brick_closeup_has_bearer_context", (group.bounds as AABB).intersects(bearer) and group.exactPrimitive == brick)
		var probe: VisibilityRequirementProbe = VisibilityRequirementProbe.new()
		var spec: Dictionary = {"kind": "brick_cluster", "bricks": [group]}
		probe.visible_ids = ["synthetic_gable"]
		_check("synthetic_visible_brick_obscured_bearer_rejects", not probe._coverage_visible(spec))
		probe.visible_ids = ["synthetic_bearer"]
		_check("synthetic_visible_bearer_obscured_brick_rejects", not probe._coverage_visible(spec))
		probe.visible_ids = ["synthetic_gable", "synthetic_bearer"]
		_check("synthetic_both_visible_satisfies_requirement", probe._coverage_visible(spec))
		probe.free()
	_check("brick_missing_bearer_context_rejects", Visual._brick_review_group(brick, "synthetic_bearer", AABB(Vector3(10, 2, 10), Vector3.ONE), "synthetic").is_empty())
	var evidence_sha: String = "a".repeat(64)
	_check("final_matching_hashes_allow_requested_completion", bool(Visual._completion_gate(true, Visual.REVIEW_SHA, evidence_sha, evidence_sha).captureCoverageComplete))
	_check("final_changed_baseline_blocks_completion", not bool(Visual._completion_gate(true, "b".repeat(64), evidence_sha, evidence_sha).captureCoverageComplete))
	_check("final_changed_evidence_blocks_completion", not bool(Visual._completion_gate(true, Visual.REVIEW_SHA, "b".repeat(64), evidence_sha).captureCoverageComplete))
	_check("final_missing_expected_evidence_blocks_completion", not bool(Visual._completion_gate(true, Visual.REVIEW_SHA, "", "").captureCoverageComplete))
	_check("matching_hashes_do_not_upgrade_incomplete_views", not bool(Visual._completion_gate(false, Visual.REVIEW_SHA, evidence_sha, evidence_sha).captureCoverageComplete))


func _cleanup_worker() -> void:
	if _fixture != null:
		_fixture._worker_mutex.lock()
		_fixture._worker_state.cancel = true
		_fixture._worker_mutex.unlock()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	if _fixture != null:
		_fixture.free()
		_fixture = null


func _finalize() -> void:
	_cleanup_worker()
