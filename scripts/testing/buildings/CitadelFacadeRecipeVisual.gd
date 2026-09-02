extends "res://scripts/testing/buildings/CitadelChimneyRecipeVisual.gd"

## Reuses only the existing scene/mesh camera inspector. No chimney source,
## cutaway, player act, door act, route service or geometry repair is invoked.
## Headless contracts test source and pure rules separately: dummy instance
## readback cannot prove scene visibility. Every scene launch needs a real
## renderer and an external critic grant; completed images still need review.
const FacadePreparation = preload("res://scripts/testing/buildings/CitadelFacadeVisualPreparation.gd")
const FacadePlan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const NightStyle = preload("res://resources/visual/gamecube_style.tres")
const MeshRay = preload("res://scripts/testing/buildings/CitadelPublishedMeshRay.gd")
const Coverage = preload("res://scripts/testing/buildings/ProjectedReviewCoverage.gd")
const AssemblyPlan = preload("res://scripts/testing/buildings/CitadelAssemblyReviewPlan.gd")
const FACADE_VIEWS := 13
var _facade_preparation
var _facade_prepared: Dictionary = {}
var _headless_preflight := false
var _light_state: Array = []
var _night := false
var _before_state := ""
var _frame_poses: Dictionary = {}
var _max_batch_usec := 0
var _max_frame_gap_msec := 0
var _last_frame := 0
var _cut_meshes: Dictionary = {}
var _triangle_tests := 0
var _visual_identity: Dictionary = {}
var _initial_lighting: Array = []
var _max_candidate_usec := 0
var _max_subject_callback_usec := 0
var _max_ray_query_usec := 0
var _requested_stage := "review"
var _publication_stage_started := 0
var _index_elapsed_msec := 0
var _publication_elapsed_msec := 0
var _coverage_rows: Array = []
var _target_rejection_stage := ""
var _target_rejection_counts: Dictionary = {}
var _target_rejection_examples: Array = []
var _expected_views := FACADE_VIEWS
var _selected_frame_id := ""

func _ready() -> void:
	report_path = OS.get_environment("VOXEL_FACADE_VISUAL_REPORT")
	screenshot_dir = OS.get_environment("VOXEL_FACADE_VISUAL_SCREENSHOT_DIR")
	_headless_preflight = DisplayServer.get_name() == "headless"
	_progress_path = report_path.get_basename() + "-progress.json"
	if not report_path.is_absolute_path() or report_path.get_extension() != "json" or FileAccess.file_exists(report_path) or FileAccess.file_exists(_progress_path) or not DirAccess.dir_exists_absolute(report_path.get_base_dir()):
		get_tree().quit(2)
		return
	_started = Time.get_ticks_msec()
	_visual_identity = _review_code_identity()
	_requested_stage = OS.get_environment("VOXEL_FACADE_VISUAL_STAGE")
	if _requested_stage.is_empty(): _requested_stage = "review"
	if _requested_stage not in _allowed_review_stages():
		_finish("invalid_requested_stage")
		return
	_expected_views = 0 if _requested_stage == "publication_index" else (1 if _requested_stage == "assembly_review" else FACADE_VIEWS)
	_selected_frame_id = OS.get_environment("VOXEL_FACADE_VISUAL_FRAME_ID").strip_edges()
	if (_requested_stage == "assembly_review") != (not _selected_frame_id.is_empty()):
		_finish("invalid_assembly_frame_selection")
		return
	if _headless_preflight:
		_finish("real_instance_readback_requires_renderer")
		return
	if not _headless_preflight:
		if OS.get_environment("VOXEL_FACADE_VISUAL_CRITIC_GRANT").strip_edges().is_empty():
			_finish("missing_external_critic_readiness_grant")
			return
		if _requested_stage != "publication_index" and (not screenshot_dir.is_absolute_path() or DirAccess.dir_exists_absolute(screenshot_dir) or DirAccess.make_dir_recursive_absolute(screenshot_dir) != OK):
			_finish("capture_directory_not_fresh")
			return
	build_world()
	build_hud()
	is_rebuilding = true
	set_loading("Preparing reviewed facade recipe")
	_stage = "worker_preparation"
	_facade_preparation = _new_review_preparation()
	_worker = Thread.new()
	if _worker.start(_review_preparation_callable(_facade_preparation)) != OK:
		_worker = null
		_finish("worker_start_failed")
		return
	while _worker.is_alive(): await get_tree().process_frame
	var result: Variant = _worker.wait_to_finish()
	_worker = null
	_facade_prepared = result if result is Dictionary else {}
	if _finished: return
	if not await _complete_review_preparation():
		_review["preparationFailure"] = _facade_prepared.get("reason", "handoff_rejected")
		_review["preparation"] = _facade_prepared.get("preparation", {})
		_review["preparationStatus"] = _facade_preparation.status()
		_finish("preparation_or_handoff_failed")
		return
	blueprint = _facade_prepared.blueprint
	furnishing_plan = _facade_prepared.furniture
	building_publisher = _facade_prepared.publisher
	cottage_root = _facade_prepared.publicationRoot
	selected_seed = int(_facade_prepared.fixture.seed)
	selected_citadel_scale = float(_facade_prepared.fixture.citadelScale)
	selected_style = String(blueprint.style)
	_review = _prepared_review_metadata()
	configure_walkthrough_ground()
	add_child(cottage_root) # Same worker-prepared owner; no second begin.
	_stage = "main_thread_publication"
	_publication_stage_started = Time.get_ticks_msec()
	set_loading("Publishing reviewed structures and furnishings")
	var index := 0
	while index < blueprint.parts.size() and not _finished:
		var begin := Time.get_ticks_usec()
		var next: int = building_publisher.publish_part_batch(blueprint, cottage_root, index, 6)
		_max_batch_usec = maxi(_max_batch_usec, Time.get_ticks_usec() - begin)
		if next <= index or next > mini(index + 6, blueprint.parts.size()):
			_finish("publication_not_advancing")
			return
		index = next
		await get_tree().process_frame
	if _finished: return
	var published: Dictionary = building_publisher.finish_publication(blueprint, cottage_root)
	if published.publishedPartCount != blueprint.parts.size() or published.get("pavingFootingPublication", {}).get("complete") != true:
		_finish("incomplete_publication")
		return
	_review["physicalViolationCount"] = published.physicalIntegrity.get("violations", []).size()
	furnishing_root = Node3D.new()
	add_child(furnishing_root)
	furnishing_publisher = FurnishingPublisherScript.new()
	await furnishing_publisher.publish_incremental(furnishing_plan, furnishing_root, 6)
	if _finished: return
	if furnishing_publisher.published_parts.size() != furnishing_plan.parts.size() or furnishing_plan.parts.size() != 152:
		_finish("incomplete_furniture_publication")
		return
	_review["publishedBuildingParts"] = building_publisher.published_part_count
	_review["publishedFurnishingParts"] = furnishing_publisher.published_parts.size()
	install_generated_city_trees(blueprint)
	install_city_lights(blueprint)
	_publication_elapsed_msec = Time.get_ticks_msec() - _publication_stage_started
	for part in blueprint.parts:
		if part.collision_enabled and CitadelUrbanPocComposerScript.is_primary_tree_paving(part):
			_paving_ray_bottom = minf(_paving_ray_bottom, blueprint.transformed_part_bounds(part).position.y)
	if not is_finite(_paving_ray_bottom) or not _source_exact():
		_finish("published_source_or_policy_changed")
		return
	is_rebuilding = false
	for frame in range(4): await get_tree().physics_frame
	await write_automated_report()

func _allowed_review_stages() -> Array:
	return ["review", "publication_index", "assembly_review"]

func _new_review_preparation():
	return FacadePreparation.new()

func _review_preparation_callable(provider) -> Callable:
	return provider.prepare

func _complete_review_preparation() -> bool:
	return FacadePreparation.handoff_ready(_facade_prepared)

func _prepared_review_metadata() -> Dictionary:
	return {"preparation": _facade_prepared.preparation, "fixture": _facade_prepared.fixture,
		"dependencyMapping": _facade_prepared.dependencyMapping,
		"groups": _facade_prepared.groups, "bindings": FacadePlan.INPUTS, "headlessPreflight": _headless_preflight,
		"newPartIds": _facade_prepared.newPartIds, "servedPartIds": _facade_prepared.servedPartIds}

func _source_exact() -> bool:
	return blueprint != null and furnishing_plan != null and FacadePlan.inputs_current(_facade_prepared.identity) and FacadePlan.digest(blueprint.snapshot()) == _facade_prepared.expectedPublishedSourceDigest and FacadePlan.digest([furnishing_plan.snapshot(), furnishing_plan.protected_access_reservations]) == _facade_prepared.furnitureDigest and FacadePreparation.geometry_identity(building_publisher) == _facade_prepared.preparedGeometry

func _process(delta: float) -> void:
	if is_rebuilding:
		loading_elapsed += delta
		update_loading_label()
	if _finished or _started == 0: return
	var now := Time.get_ticks_msec()
	if _last_frame > 0: _max_frame_gap_msec = maxi(_max_frame_gap_msec, now - _last_frame)
	_last_frame = now
	if now - _started >= TOTAL_MSEC:
		_finish("whole_review_deadline")
		return
	if now < _next_progress: return
	_next_progress = now + 1000
	if not _write_json(_progress_path, {"stage": _stage, "elapsedMsec": now - _started,
		"worker": _facade_preparation.status() if _facade_preparation != null else {},
		"viewRows": _capture_results.size(), "expectedViews": _expected_views, "activeViewId": _active_view_id,
		"publishedParts": building_publisher.published_part_count if building_publisher != null else 0}): _finish("progress_write_failed")

func write_automated_report() -> void:
	_stage = "index_actual_scene"
	var index_started := Time.get_ticks_msec()
	if not await _index_scene():
		_finish("scene_index_failed")
		return
	if not _index_cut_meshes():
		_finish("published_cut_mesh_binding_failed")
		return
	_index_elapsed_msec = Time.get_ticks_msec() - index_started
	if _requested_stage == "publication_index":
		_review["sourceAndFurnitureUnchanged"] = _source_exact() and _cut_meshes_exact()
		_review["workerToRendererIndexOnly"] = true
		_finish("real_renderer_publication_index_complete" if _review.sourceAndFurnitureUnchanged else "index_source_or_instance_binding_changed")
		return # No camera, candidate evaluation, forced draw or screenshot.
	var specs := _view_specs()
	if specs.size() != _expected_views:
		_finish("incomplete_review_inventory")
		return
	_camera = Camera3D.new() # Camera is not part of the immutable source index.
	_camera.fov = 62.0
	_camera.near = 0.02
	add_child(_camera)
	_camera.current = true
	for child in get_children():
		if child is CanvasLayer: child.visible = false
	_before_state = _live_state_digest()
	_initial_lighting = _lighting_snapshot()
	_review["dayLighting"] = _initial_lighting
	if not _state_error.is_empty():
		_finish(_state_error)
		return
	_stage = "camera_preflight" if _headless_preflight else "capture"
	for spec in specs:
		if _finished: return
		_active_view_id = spec.id
		var start := Time.get_ticks_msec()
		var start_rays := _ray_tests
		var view: Dictionary = await _choose_view(spec)
		if _finished: return
		# A chosen observer must pass the same coverage predicate at capture time.
		if view.get("ok", false):
			_camera.global_position = view.position
			_camera.look_at(view.target, Vector3.UP)
			view["finalCoveragePassed"] = _targets_visible(spec, false)
			view["coverage"] = _coverage_rows.duplicate(true)
			view.ok = view.finalCoveragePassed
		var row := {"id": spec.id, "kind": spec.kind, "frameId": spec.frameId, "targets": spec.targets,
			"bounds": spec.bounds, "camera": view, "cameraPassed": bool(view.get("ok", false)), "captured": false,
			"headless": _headless_preflight, "lighting": "production_style_night_minima_and_recipe_lanterns" if spec.kind == "night" else "unchanged_citadel_daylight",
			"hiddenPartCount": _hidden.size(), "buriedBearingVisualCredit": false}
		if row.cameraPassed:
			var before_lighting := _lighting_snapshot()
			_set_night(spec.kind == "night")
			row["lightingState"] = _lighting_snapshot()
			row["nightValuesApplied"] = spec.kind != "night" or _night_values_applied()
			_camera.global_position = view.position
			_camera.look_at(view.target, Vector3.UP)
			if not _headless_preflight:
				for frame in range(8): await get_tree().process_frame
				if _finished: return
				RenderingServer.force_draw(false)
				var picture := get_viewport().get_texture().get_image()
				var path := screenshot_dir.path_join(spec.id + ".png")
				if not picture.is_empty() and not FileAccess.file_exists(path):
					row.captured = picture.save_png(path) == OK
					if row.captured: row["screenshot"] = path
			_set_night(false)
			row["lightingRestored"] = _lighting_snapshot() == before_lighting
			if not row.nightValuesApplied or not row.lightingRestored: row.cameraPassed = false
		_set_night(false)
		row["work"] = _view_work(start_rays, _ray_tests, start, Time.get_ticks_msec())
		_capture_results.append(row)
		_active_view_id = ""
		await get_tree().process_frame
	_review["liveStateUnchanged"] = _before_state == _live_state_digest() and _state_error.is_empty()
	_review["sourceAndFurnitureUnchanged"] = _source_exact() and _cut_meshes_exact()
	_review["codeAndLightingUnchanged"] = _visual_identity == _review_code_identity() and _lighting_snapshot() == _initial_lighting
	var complete: bool = _capture_results.size() == _expected_views and _capture_results.all(func(row): return row.cameraPassed and (_headless_preflight or row.captured)) and _review.liveStateUnchanged and _review.sourceAndFurnitureUnchanged and _review.codeAndLightingUnchanged
	_finish(("headless_camera_preflight_complete" if _headless_preflight else "captures_complete_awaiting_review") if complete else "incomplete_view_or_parity")

func _view_specs() -> Array:
	if _requested_stage == "assembly_review": return _assembly_view_specs()
	var specs: Array = []
	for group in _facade_prepared.groups:
		var targets: Array = group.partIds + group.servedIds
		var box: AABB = group.bounds
		for id in targets:
			if not _part_visuals.has(id): return []
			box = box.merge(_published_bounds(id))
		# Context grows with actual facade extent; this affects the camera only.
		specs.append({"id": group.id + "_day", "frameId": group.id, "kind": "ordinary", "bounds": box.grow(box.size.length() * 0.12), "targets": targets})
		for foot in group.footInterfaces:
			var foot_targets: Array = [foot.footId] + foot.finishIds
			specs.append({"id": group.id + "_foot_%02d" % group.footInterfaces.find(foot), "frameId": group.id,
				"kind": "foot", "bounds": foot.bounds, "targets": foot_targets, "footId": foot.footId, "supportIds": foot.supportIds})
	for group in _facade_prepared.groups:
		var day: Dictionary = specs.filter(func(spec): return spec.id == group.id + "_day")[0]
		var night: Dictionary = day.duplicate(true)
		night.id = group.id + "_night"
		night.kind = "night"
		specs.append(night)
	return specs

func _assembly_view_specs() -> Array:
	var selected: Array = _facade_prepared.groups.filter(func(group): return group.id == _selected_frame_id)
	if selected.size() != 1: return []
	var group: Dictionary = selected[0]
	var plan: Dictionary = AssemblyPlan.build(blueprint.snapshot(), group)
	_review["assemblyPlan"] = plan
	if not plan.get("ready", false): return []
	# Preserve the complete assembly context. Only the required visibility
	# patches change from whole-member envelopes to declared joint windows.
	var box: AABB = group.bounds
	for id in group.partIds + group.servedIds:
		if not _part_visuals.has(id): return []
		box = box.merge(_published_bounds(id))
	return [{"id": group.id + "_assembly_day", "frameId": group.id, "kind": "assembly",
		"bounds": box.grow(box.size.length() * 0.12), "targets": plan.targets, "assemblyPairs": plan.pairs}]

func _ordinary_rejection(position: Vector3, spec: Dictionary) -> String:
	if not _budget_reason().is_empty(): return _budget_reason()
	_camera.global_position = position
	_camera.look_at(spec.bounds.get_center(), Vector3.UP)
	if not _frame_visible(spec.bounds): return "incomplete_frame_context"
	if not _targets_visible(spec, false): return _target_rejection_stage + ":" + String(_visibility_failure.get("partId", "")) + ":" + String(_visibility_failure.get("reason", "occluded"))
	return ""

func _targets_visible(spec: Dictionary, allow_cutaway: bool) -> bool:
	var started := Time.get_ticks_usec()
	var result: bool = super._targets_visible(spec, allow_cutaway)
	_coverage_rows.clear()
	_target_rejection_stage = "original_target_visibility" if not result else ""
	if result:
		result = _distributed_view_coverage(spec)
		if not result: _target_rejection_stage = "distributed_coverage"
	if not result:
		_target_rejection_counts[_target_rejection_stage] = int(_target_rejection_counts.get(_target_rejection_stage, 0)) + 1
		if _target_rejection_examples.size() < 4:
			_target_rejection_examples.append({"stage": _target_rejection_stage, "position": _camera.global_position, "failure": _visibility_failure.duplicate(true)})
	_max_subject_callback_usec = maxi(_max_subject_callback_usec, Time.get_ticks_usec() - started)
	return result

func _distributed_view_coverage(spec: Dictionary) -> bool:
	# Additional observer-quality checks only. Keep every existing exact target,
	# blocker, framing and budget check; never alter generated geometry to fit.
	if spec.kind == "assembly":
		for pair in spec.assemblyPairs:
			for patch in pair.patches:
				# Keep the source-defined joint window, but sample the actual
				# published surface within it, including its material relief.
				var published: AABB = _published_bounds(patch.partId).intersection(pair.reviewBounds)
				if not _patch_coverage(patch.partId, published): return false
		return not spec.assemblyPairs.is_empty()
	if spec.kind == "foot":
		if not _patch_coverage(spec.footId, _published_bounds(spec.footId)): return false
		var neighbours: Array = spec.targets.slice(1)
		if neighbours.is_empty(): neighbours = spec.supportIds
		if neighbours.is_empty(): return false
		for id in neighbours:
			var patch := _adjacent_support_patch(spec, String(id))
			if patch.size == Vector3.ZERO: return false
			# Project the exposed top, not the buried vertical side of the patch.
			var top := AABB(Vector3(patch.position.x, patch.end.y, patch.position.z), Vector3(patch.size.x, 0, patch.size.z))
			if not _patch_coverage(String(id), patch, top): return false
			var foot := _published_bounds(spec.footId)
			var bottom := maxf(foot.position.y, patch.end.y)
			if bottom >= foot.end.y: return false
			var base_band := AABB(Vector3(foot.position.x, bottom, foot.position.z), Vector3(foot.size.x, (foot.end.y - bottom) * 0.5, foot.size.z))
			var toward := _camera.global_position - foot.get_center()
			var axis := 0 if absf(toward.x) >= absf(toward.z) else 2
			var face := base_band
			if toward[axis] >= 0: face.position[axis] = base_band.end[axis]
			face.size[axis] = 0
			if not _patch_coverage(spec.footId, base_band, face): return false
		return true
	for id in spec.targets:
		var part = blueprint.find_part(id)
		if part == null: return false
		# Served panels and the seat-connected sill/posts must read as an
		# assembly. Diagonal socket braces retain the original exact-hit checks;
		# their rectangular screen envelope is not their visible silhouette.
		if part.semantic == "citadel_urban_facade" or (part.recipe.has("physicalRequiredSeatPartIds") and part.material_id == "timber_beam"):
			if not _patch_coverage(String(id), _published_bounds(String(id))): return false
	return true

func _adjacent_support_patch(spec: Dictionary, id: String) -> AABB:
	var foot := _published_bounds(spec.footId)
	var patch := _published_bounds(id).intersection(spec.bounds)
	if patch.size.x <= 0 or patch.size.z <= 0: return AABB()
	var toward := _camera.global_position - foot.get_center()
	var axis := 0 if absf(toward.x) >= absf(toward.z) else 2
	var lo := patch.position
	var hi := patch.end
	# The strip directly outside the camera-facing base edge must be visible,
	# not another remote part of the same paving owner. Its upper surface is
	# derived from actual published bounds; hidden bearing earns no credit.
	if toward[axis] >= 0: lo[axis] = maxf(lo[axis], foot.end[axis])
	else: hi[axis] = minf(hi[axis], foot.position[axis])
	var tangent := 2 if axis == 0 else 0
	lo[tangent] = maxf(lo[tangent], foot.position[tangent])
	hi[tangent] = minf(hi[tangent], foot.end[tangent])
	# Review the exposed upper finish band, not the buried roadbed side.
	lo.y = maxf(lo.y, hi.y - foot.size.y * 0.25)
	if hi.x <= lo.x or hi.z <= lo.z or hi.y < lo.y: return AABB()
	return AABB(lo, hi - lo)

func _patch_coverage(id: String, bounds: AABB, projection_bounds: Variant = null, exact_primitive: Dictionary = {}) -> bool:
	if not _state_error.is_empty() or not _budget_reason().is_empty(): return false
	var projection: AABB = bounds if projection_bounds == null else projection_bounds
	var rectangle := Rect2()
	for corner in range(8):
		var point := projection.get_endpoint(corner)
		if _camera.is_position_behind(point): return false
		var screen := _camera.unproject_position(point)
		if not screen.is_finite(): return false
		rectangle = Rect2(screen, Vector2.ZERO) if corner == 0 else rectangle.expand(screen)
	var flags: Array = []
	var blockers: Array = []
	var far_distance: float = _camera.global_position.distance_to(bounds.get_center()) + bounds.size.length() * 2.0
	for pixel in Coverage.sample_positions(rectangle):
		if not _state_error.is_empty() or not _budget_reason().is_empty(): return false
		var start := _camera.project_ray_origin(pixel)
		var hit := _first_visual_hit(start, start + _camera.project_ray_normal(pixel) * far_distance)
		var visible: bool = not hit.is_empty() and hit.partId == id and _owned_hit_in_patch(id, hit.point, bounds) and (exact_primitive.is_empty() or same_primitive_identity(hit, exact_primitive))
		flags.append(visible)
		if not visible and blockers.size() < 3:
			blockers.append({"pixel": pixel, "partId": hit.get("partId", ""), "point": hit.get("point")})
	var result: Dictionary = Coverage.evaluate(rectangle, flags)
	result["partId"] = id
	result["bounds"] = bounds
	result["projectionBounds"] = projection
	result["firstBlockers"] = blockers
	_coverage_rows.append(result)
	if not result.passed: _visibility_failure = result.duplicate(true)
	return result.passed and _state_error.is_empty() and _budget_reason().is_empty()

static func same_primitive_identity(hit: Dictionary, expected: Dictionary) -> bool:
	# Part ownership alone cannot prove a cut fragment was seen: mortar and
	# neighbouring bricks share that owner. Match the exact indexed instance.
	return is_instance_valid(expected.get("node")) and hit.get("node") == expected.node and expected.get("index") is int and hit.get("index") == expected.index and expected.get("partId") is String and not expected.partId.is_empty() and hit.get("partId") == expected.partId

func _owned_hit_in_patch(id: String, point: Vector3, patch: AABB) -> bool:
	if not point.is_finite(): return false
	var owner := _published_bounds(id)
	# The actual first-hit owner already proves membership in the whole part.
	# Test only faces introduced by the review crop, avoiding a second rounded
	# world-point comparison at the owner's own surface. No epsilon or widened
	# crop: every interior review boundary remains an exact comparison.
	for axis in range(3):
		if patch.position[axis] > owner.position[axis] and point[axis] < patch.position[axis]: return false
		if patch.end[axis] < owner.end[axis] and point[axis] > patch.end[axis]: return false
	return true

func _choose_view(spec: Dictionary) -> Dictionary:
	if not _budget_reason().is_empty(): return _budget_view_result(_budget_reason(), true)
	_visibility_failure.clear()
	_target_rejection_counts.clear()
	_target_rejection_examples.clear()
	var target: Vector3 = spec.bounds.get_center()
	if spec.kind == "night":
		return _frame_poses.get(spec.frameId, {"ok": false, "reason": "no_approved_day_pose"}).duplicate(true)
	var radius: float = spec.bounds.size.length() * 0.5
	var viewport_size := get_viewport().get_visible_rect().size
	var half_angle := minf(deg_to_rad(31.0), atan(tan(deg_to_rad(31.0)) * viewport_size.x / viewport_size.y))
	var distance := radius / sin(half_angle) * 1.12
	if spec.kind in ["ordinary", "assembly"]:
		# This is only a nearer search heuristic for narrow lanes, NOT a framing
		# certificate. Every actual pose still passes all eight-corner checks.
		var near_search: float = maxf(spec.bounds.size.y, minf(spec.bounds.size.x, spec.bounds.size.z)) * 0.5 / tan(half_angle) * 1.12
		if not is_finite(near_search) or near_search <= _camera.near: return {"ok": false, "reason": "invalid_near_search"}
		var schedule := [distance * 1.4, near_search, lerpf(near_search, distance * 1.4, 0.30), lerpf(near_search, distance * 1.4, 0.64)]
		var positions: Array = []
		for range_value in schedule:
			for direction in range(16):
				var angle := TAU * direction / 16.0
				positions.append(target + Vector3(sin(angle), 0, -cos(angle)) * float(range_value))
		var job := begin_exterior_review_pose(target, near_search, distance * 1.4, radius, 0, -INF, _ordinary_rejection.bind(spec), _ordinary_visibility_target.bind(spec))
		var progress: Dictionary = {}
		var candidate_costs: Array = []
		while not progress.get("complete", false):
			if not _budget_reason().is_empty(): return _budget_view_result(_budget_reason(), true)
			progress = advance_exterior_review_pose(job, 1)
			_max_candidate_usec = maxi(_max_candidate_usec, int(progress.maxCandidateUsec))
			candidate_costs.append_array(progress.candidateUsec)
			if not progress.valid: return {"ok": false, "reason": progress.reason}
			if not progress.complete:
				await get_tree().process_frame
				if _finished: return {"ok": false, "reason": "review_stopped"}
		var view := make_exterior_review_view_from_pose(spec.id, "recipe facade frame and surrounding access context", target, distance * 2.0, progress.pose)
		view["candidateUsec"] = candidate_costs
		view["evaluatedCandidates"] = progress.totalCandidatesEvaluated
		view["distanceSchedule"] = schedule
		view["horizontalProbePositions"] = positions
		if not _budget_reason().is_empty(): return _budget_view_result(_budget_reason(), true)
		var audit: Dictionary = audit_review_camera_contract(view, _camera) if view.cameraPoseOk else {"passed": false}
		var result := {"ok": bool(view.cameraPoseOk) and bool(audit.passed), "position": view.position, "target": target,
			"evidence": view, "audit": audit, "cameraScope": "ordinary_collision_backed_observer", "missingCoverage": _visibility_failure.duplicate(true),
			"targetRejectionCounts": _target_rejection_counts.duplicate(), "targetRejectionExamples": _target_rejection_examples.duplicate(true)}
		if result.ok: _frame_poses[spec.frameId] = result
		return result
	# Foot close observers derive directions and distance from actual bounds.
	# They are not player locations or evidence of a reachable standing surface.
	var last_attempt: Dictionary = {}
	for elevation in [0.35, 0.8]:
		for direction in range(8):
			var angle := TAU * direction / 8.0
			var facing := Vector3(cos(angle), elevation, sin(angle)).normalized()
			_camera.global_position = target + facing * distance
			_camera.look_at(target, Vector3.UP)
			var framed := _frame_visible(spec.bounds)
			var visible := framed and _targets_visible(spec, false)
			last_attempt = {"position": _camera.global_position, "target": target,
				"candidateIndex": direction + (8 if elevation == 0.8 else 0), "framingPassed": framed,
				"coverage": _coverage_rows.duplicate(true) if framed else [],
				"missingCoverage": _visibility_failure.duplicate(true) if framed else {"reason": "incomplete_frame_context"}}
			if visible:
				return {"ok": true, "position": _camera.global_position, "target": target, "cameraScope": "close_observer_not_player_or_access_evidence", "candidateIndex": direction + (8 if elevation == 0.8 else 0)}
			if not _budget_reason().is_empty(): return _budget_view_result(_budget_reason(), true)
			await get_tree().process_frame
	return {"ok": false, "reason": "exposed_foot_or_finish_occluded", "missingCoverage": _visibility_failure.duplicate(true), "lastAttempt": last_attempt}

func _hide_own_occluder(_id: String, _spec: Dictionary) -> bool:
	return false

func _prepared_cut_entries() -> Dictionary:
	var entries: Array = []
	for finish_id in building_publisher._paving_artifacts:
		var artifact: Dictionary = building_publisher._paving_artifacts[finish_id].artifact
		for entry in artifact.entries:
			if entry.has("mesh") and entry.mesh != null:
				entries.append({"partId": finish_id, "mesh": entry.mesh, "original": entry.original})
	return {"ready": true, "entries": entries}

func _index_cut_meshes() -> bool:
	var triangle_count := 0
	var inventory := _prepared_cut_entries()
	if not inventory.get("ready", false): return _cut_failure("invalid_prepared_cut_inventory", {"reason": inventory.get("reason", "")})
	for entry in inventory.entries:
		var finish_id: String = entry.partId
		var mesh: ArrayMesh = entry.mesh
		if _cut_meshes.has(mesh.get_instance_id()): return _cut_failure("repeated_artifact_mesh", {"partId": finish_id})
		var prepared: Dictionary = MeshRay.prepare(mesh, MeshRay.MAX_TRIANGLES - triangle_count)
		if not prepared.valid: return _cut_failure("invalid_prepared_cut_mesh", {"partId": finish_id, "details": prepared})
		triangle_count += int(prepared.triangleCount)
		var actual_nodes: Array = []
		var instances: Array = []
		for visual in _visuals:
			var node = visual.node
			var actual_mesh: Mesh = node.mesh if node is MeshInstance3D else node.multimesh.mesh
			if actual_mesh != mesh: continue
			if visual.partId != finish_id: return _cut_failure("cut_mesh_used_by_other_part", {"partId": finish_id, "actualPartId": visual.partId})
			actual_nodes.append(node)
			for index in range(visual.count):
				var primitive: Dictionary = _primitive(visual, index)
				if primitive.is_empty(): return _cut_failure("invalid_cut_primitive", {"partId": finish_id, "index": index, "stateError": _state_error})
				if primitive.transform != entry.original.transform:
					return _cut_failure("cut_instance_transform_mismatch", {"partId": finish_id, "index": index,
						"expected": _transform_values(entry.original.transform), "actual": _transform_values(primitive.transform)})
				instances.append({"node": node, "index": index, "transform": primitive.transform})
		if actual_nodes.size() != 1 or instances.size() != 1: return _cut_failure("cut_instance_cardinality", {"partId": finish_id, "nodes": actual_nodes.size(), "instances": instances.size()})
		_cut_meshes[mesh.get_instance_id()] = {"mesh": mesh, "prepared": prepared, "nodes": actual_nodes, "instances": instances, "partId": finish_id}
	_review["cutMeshCount"] = _cut_meshes.size()
	_review["cutTriangleCount"] = triangle_count
	return not _cut_meshes.is_empty() and _cut_meshes_exact()

func _cut_failure(reason: String, details: Dictionary) -> bool:
	if not _review.has("cutBindingFailure"):
		_review["cutBindingFailure"] = {"reason": reason, "details": details}
	return false

static func _transform_values(value: Transform3D) -> Dictionary:
	return {"basis": [value.basis.x, value.basis.y, value.basis.z], "origin": value.origin, "exactVariantDigest": FacadePlan.digest(value)}

func _cut_meshes_exact() -> bool:
	for record in _cut_meshes.values():
		if record.nodes.size() != 1 or record.instances.size() != 1: return false
		if not MeshRay.identity_matches(record.mesh, record.prepared): return false
		for node in record.nodes:
			if not is_instance_valid(node): return false
			var mesh: Mesh = node.mesh if node is MeshInstance3D else node.multimesh.mesh
			if mesh != record.mesh: return false
		for instance in record.instances:
			var current: Transform3D = instance.node.global_transform
			if instance.node is MultiMeshInstance3D:
				if instance.node.multimesh.instance_count != 1 or instance.index >= instance.node.multimesh.instance_count: return false
				current = current * instance.node.multimesh.get_instance_transform(instance.index)
			if current != instance.transform: return false
	return true

func _first_visual_hit(from: Vector3, target: Vector3) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result := _cut_refined_first_visual_hit(from, target)
	_max_ray_query_usec = maxi(_max_ray_query_usec, Time.get_ticks_usec() - started)
	return result

func _cut_refined_first_visual_hit(from: Vector3, target: Vector3) -> Dictionary:
	# Same full-scene conservative broad phase as the shared inspector. Only
	# finalized cut ArrayMeshes refine an AABB hit to actual published triangles.
	# Invalid/expired/budget-limited refinement aborts; never exposes a clear ray.
	if not _state_error.is_empty() or not _budget_reason().is_empty(): return {}
	var best: Dictionary = {}
	var distance := INF
	var visited := 0
	for visual in _visuals:
		if visited % 1024 == 0 and not _budget_reason().is_empty(): return {}
		visited += 1
		if not visual.node.is_visible_in_tree() or visual.bounds.intersects_segment(from, target) == null: continue
		for index in range(visual.count):
			if _ray_tests >= MAX_RAY_TESTS: return {}
			_ray_tests += 1
			var primitive := _primitive(visual, index)
			if primitive.is_empty(): return {}
			var inverse: Transform3D = primitive.transform.affine_inverse()
			var hit: Variant = primitive.localBounds.intersects_segment(inverse * from, inverse * target)
			if hit == null: continue
			var world: Vector3 = primitive.transform * hit
			var node = primitive.node
			var mesh: Mesh = node.mesh if node is MeshInstance3D else node.multimesh.mesh
			if _cut_meshes.has(mesh.get_instance_id()):
				var refined: Dictionary = MeshRay.intersect(_cut_meshes[mesh.get_instance_id()].prepared, primitive.transform, from, target, MAX_RAY_TESTS - _ray_tests)
				_ray_tests += int(refined.tests)
				_triangle_tests += int(refined.tests)
				if not refined.valid:
					_state_error = "invalid_or_bounded_cut_mesh_ray:" + String(refined.reason)
					return {}
				if not refined.hit: continue
				world = refined.point
			var squared := from.distance_squared_to(world)
			if squared < distance:
				distance = squared
				best = primitive
				best["point"] = world
	return best

func _set_night(enabled: bool) -> void:
	if enabled == _night: return
	if enabled:
		for node in get_children():
			if node is DirectionalLight3D:
				_light_state.append({"node": node, "energy": node.light_energy})
				node.light_energy = NightStyle.sun_min_energy
			elif node is WorldEnvironment:
				var env: Environment = node.environment
				_light_state.append({"node": node, "ambientEnergy": env.ambient_light_energy, "ambientColor": env.ambient_light_color, "background": env.background_color, "fogEnergy": env.fog_light_energy})
				env.ambient_light_energy = NightStyle.ambient_min_energy
				env.ambient_light_color = NightStyle.ambient_color(0.0, 0.0)
				env.background_color = NightStyle.sky_horizon_color(0.0, 0.0, 0.0)
				env.fog_light_energy = _native_light_value(NightStyle.fog_light_energy_night)
	else:
		for record in _light_state:
			if not is_instance_valid(record.node): continue
			if record.has("energy"): record.node.light_energy = record.energy
			else:
				var env: Environment = record.node.environment
				env.ambient_light_energy = record.ambientEnergy
				env.ambient_light_color = record.ambientColor
				env.background_color = record.background
				env.fog_light_energy = record.fogEnergy
		_light_state.clear()
	_night = enabled

func _lighting_snapshot() -> Array:
	var values: Array = []
	for node in _scene_nodes:
		if node is Light3D:
			values.append([node.get_instance_id(), node.light_energy, node.light_color, node.shadow_enabled, node.visible])
	for node in get_children():
		if node is WorldEnvironment:
			var env: Environment = node.environment
			values.append([node.get_instance_id(), env.get_instance_id(), env.ambient_light_energy, env.ambient_light_color, env.background_color, env.fog_light_energy])
	return values

func _night_values_applied() -> bool:
	if not _night or _light_state.is_empty(): return false
	for record in _light_state:
		if record.has("energy"):
			if record.node.light_energy != NightStyle.sun_min_energy: return false
		else:
			var env: Environment = record.node.environment
			if env.ambient_light_energy != NightStyle.ambient_min_energy or env.ambient_light_color != NightStyle.ambient_color(0.0, 0.0) or env.background_color != NightStyle.sky_horizon_color(0.0, 0.0, 0.0) or env.fog_light_energy != _native_light_value(NightStyle.fog_light_energy_night): return false
	return true

static func _native_light_value(value: float) -> float:
	# Godot's native Environment stores this property as float32, while the
	# scripted style export is float64. Assert its exact native representation;
	# this is not an approximate comparison or a geometry/contact tolerance.
	return float(PackedFloat32Array([value])[0])

func _finish(reason: String) -> void:
	if _finished: return
	_finished = true
	_set_night(false)
	if _facade_preparation != null: _facade_preparation.cancel()
	var completed: bool = reason in ["real_renderer_publication_index_complete", "captures_complete_awaiting_review"]
	var code_unchanged: bool = not _visual_identity.is_empty() and _visual_identity == _review_code_identity()
	var lighting_restored: bool = _initial_lighting.is_empty() or _lighting_snapshot() == _initial_lighting
	completed = completed and code_unchanged and lighting_restored
	var report := {"status": reason, "requestedStageCompleted": completed, "visualAcceptance": false,
		"physicalGatePassed": false, "headlessPreflight": _headless_preflight, "requestedStage": _requested_stage,
		"expectedViews": _expected_views, "selectedFrameId": _selected_frame_id,
		"review": _review, "views": _capture_results, "elapsedMsec": Time.get_ticks_msec() - _started,
		"maxMainBatchUsec": _max_batch_usec, "maxObservedMainFrameGapMsec": _max_frame_gap_msec,
		"publicationElapsedMsec": _publication_elapsed_msec, "indexElapsedMsec": _index_elapsed_msec,
		"renderer": {"method": RenderingServer.get_current_rendering_method(), "driver": RenderingServer.get_current_rendering_driver_name(), "adapter": RenderingServer.get_video_adapter_name(), "display": DisplayServer.get_name()},
		"cutTriangleTests": _triangle_tests, "stateError": _state_error,
		"supportSelectionDiagnostics": _review_support_diagnostics,
		"maxCandidateUsec": _max_candidate_usec, "maxSubjectCallbackUsec": _max_subject_callback_usec, "maxFirstHitQueryUsec": _max_ray_query_usec,
		"codeIdentityBefore": _visual_identity, "codeIdentityAfter": _review_code_identity(), "codeIdentityUnchanged": code_unchanged,
		"finalLightingRestored": lighting_restored,
		"criticGrant": OS.get_environment("VOXEL_FACADE_VISUAL_CRITIC_GRANT"),
		"doesNotProve": "No normal-world integration, structural gate pass, player access, door traversal or NPC/navigation acceptance. Hidden bearing has CPU evidence only. Images require independent inspection; headless views are not visual acceptance."}
	var wrote := _write_json(report_path, _json(report))
	_write_json(_progress_path, {"finished": true, "reason": reason, "elapsedMsec": Time.get_ticks_msec() - _started})
	get_tree().quit((0 if _headless_preflight else 1) if wrote and completed else 2)

func _extra_review_code_identity() -> Dictionary:
	return {}

func _review_code_identity() -> Dictionary:
	var result := _visual_code_identity()
	result.merge(_extra_review_code_identity())
	return result

static func _visual_code_identity() -> Dictionary:
	var result: Dictionary = {}
	for name in ["CitadelFacadeRecipeVisual", "ProjectedReviewCoverage", "CitadelAssemblyReviewPlan", "CitadelFacadeVisualPreparation", "CitadelFacadeVisualPlan", "CitadelFacadeVisualDependencyMap", "CitadelPublishedMeshRay", "CitadelChimneyRecipeVisual", "CitadelUrbanPocRunner", "CastleWalkthroughRunner", "FurnishedCottageWalkthroughRunner"]:
		var path: String = "res://scripts/testing/buildings/" + name + ".gd"
		result[path] = FileAccess.get_sha256(path)
	result["res://resources/visual/gamecube_style.tres"] = FileAccess.get_sha256("res://resources/visual/gamecube_style.tres")
	result["res://scripts/visual/VisualStyle.gd"] = FileAccess.get_sha256("res://scripts/visual/VisualStyle.gd")
	result["res://scenes/testing/buildings/CitadelFacadeRecipeVisual.tscn"] = FileAccess.get_sha256("res://scenes/testing/buildings/CitadelFacadeRecipeVisual.tscn")
	return result

func _exit_tree() -> void:
	_set_night(false)
	if _facade_preparation != null: _facade_preparation.cancel()
	if _worker != null and _worker.is_started():
		var result: Variant = _worker.wait_to_finish()
		if result is Dictionary: _facade_prepared = result
		_worker = null
	var prepared_root = _facade_prepared.get("publicationRoot")
	if is_instance_valid(prepared_root) and prepared_root.get_parent() == null: prepared_root.free()
	super._exit_tree()
