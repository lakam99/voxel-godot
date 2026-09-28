extends "res://scripts/testing/buildings/CitadelUrbanPocRunner.gd"

## Headed inspection, NOT gameplay/structural acceptance. Main must obtain a
## critic readiness grant before launch. No walking, door act, alternate source,
## collision edits, contact exemptions or renderer implementation here.
## Required absolute paths: VOXEL_CHIMNEY_REVIEWED_BASELINE,
## VOXEL_CHIMNEY_PUBLISHED_EVIDENCE (latest complete strict-parity collector),
## VOXEL_CHIMNEY_VISUAL_REPORT, VOXEL_CHIMNEY_VISUAL_SCREENSHOT_DIR.
## VOXEL_CHIMNEY_VISUAL_CRITIC_GRANT records the external launch authorization.
## Optional VOXEL_CHIMNEY_VISUAL_VIEW_IDS: comma-separated exact unique IDs.
## Brick parents expand to their two geometry-derived face children. The full
## 24-parent request now needs 26 images and rejects: select a <=24-image shard.
const ChimneyRecipe = preload("res://scripts/buildings/ChimneyBearingRecipe.gd")
const SourceCopy = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const ReviewFurniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const REVIEW_SHA := "e43b972eface80bbcbc015ef55ac0c21a5cb99083dcfa9aabbb5a407f9832038"
const MAX_INPUT_BYTES := 134217728
const MAX_SOURCE_PARTS := 10000
const MAX_SCENE_NODES := 100000
const MAX_PRIMITIVES := 1000000
const MAX_RAY_TESTS := 8000000
const MAX_HIDDEN_PARTS := 64
const PREPARATION_MSEC := 60000
const TOTAL_MSEC := 180000
const EXPECTED_VIEWS := 24 # 11 exteriors + 11 complete assemblies + 2 brick clusters.
const MAX_DIFF_ROWS := 32
const MAX_DIFF_VISITS := 200000
const MAX_DIFF_DEPTH := 32
var _worker: Thread
var _worker_mutex := Mutex.new()
var _worker_state := {"stage": "not_started", "completedChimneys": 0, "cancel": false}
var _prepared_source
var _review: Dictionary = {}
var _evidence: Dictionary = {}
var _baseline_path := ""
var _evidence_path := ""
var _progress_path := ""
var _started := 0
var _next_progress := 0
var _stage := "setup"
var _finished := false
var _camera: Camera3D
var _visuals: Array = []
var _scene_nodes: Array = []
var _part_visuals: Dictionary = {}
var _hidden: Dictionary = {}
var _ray_tests := 0
var _capture_results: Array = []
var _publication_source_digest := ""
var _publication_furniture_digest := ""
var _expected_publication_source: Dictionary = {}
var _expected_publication_furniture: Array = []
var _state_error := ""
var _paving_ray_bottom := INF
var _review_support_diagnostics := {"queries": 0, "accepted": 0, "rejections": {}, "examples": {}, "views": {}}
var _visibility_failure: Dictionary = {}
var _view_allowlist := ""
var _view_allowlist_present := false
var _selection: Dictionary = {"ready": false, "mode": "unselected", "selectedIds": []}
var _selected_specs: Array = []
var _active_view_id := ""
var _active_view_ray_start := 0
var _active_view_time_start := 0
var _detail_inventory: Array = []


func _ready() -> void:
	read_arguments()
	report_path = OS.get_environment("VOXEL_CHIMNEY_VISUAL_REPORT").strip_edges()
	screenshot_dir = OS.get_environment("VOXEL_CHIMNEY_VISUAL_SCREENSHOT_DIR").strip_edges()
	_baseline_path = OS.get_environment("VOXEL_CHIMNEY_REVIEWED_BASELINE").strip_edges()
	_evidence_path = OS.get_environment("VOXEL_CHIMNEY_PUBLISHED_EVIDENCE").strip_edges()
	_progress_path = report_path.get_basename() + "-progress.json"
	_view_allowlist_present = OS.has_environment("VOXEL_CHIMNEY_VISUAL_VIEW_IDS")
	_view_allowlist = OS.get_environment("VOXEL_CHIMNEY_VISUAL_VIEW_IDS")
	for path in [report_path, screenshot_dir, _baseline_path, _evidence_path]:
		if not path.is_absolute_path():
			push_error("Chimney review requires absolute input/output paths")
			get_tree().quit(2)
			return
	if report_path.get_extension().to_lower() != "json" or FileAccess.file_exists(report_path) or FileAccess.file_exists(_progress_path) or not DirAccess.dir_exists_absolute(report_path.get_base_dir()) or (DirAccess.dir_exists_absolute(screenshot_dir) and (not DirAccess.get_files_at(screenshot_dir).is_empty() or not DirAccess.get_directories_at(screenshot_dir).is_empty())):
		push_error("Chimney review refuses nonfresh output paths")
		get_tree().quit(2)
		return
	_started = Time.get_ticks_msec()
	if OS.get_environment("VOXEL_CHIMNEY_VISUAL_CRITIC_GRANT").strip_edges().is_empty():
		_finish("missing_external_critic_readiness_grant")
		return
	if DirAccess.make_dir_recursive_absolute(screenshot_dir) != OK:
		_finish("capture_directory_failed")
		return
	build_world()
	build_hud()
	is_rebuilding = true
	set_loading("Preparing immutable chimney review source")
	_stage = "preparation"
	_worker = Thread.new()
	if _worker.start(_prepare_review.bind(_baseline_path, _evidence_path)) != OK:
		_worker = null
		_finish("worker_start_failed")
		return
	while _worker.is_alive():
		await get_tree().process_frame
	var prepared: Variant = _worker.wait_to_finish()
	_worker = null
	if _finished: return
	if not prepared is Dictionary or not bool(prepared.get("ready", false)):
		_review = prepared if prepared is Dictionary else {}
		_finish("preparation_failed")
		return
	_prepared_source = prepared.blueprint
	_prepared_furnishing_plan = prepared.furnishingPlan
	_evidence = prepared.evidence
	_publication_source_digest = prepared.expectedPublishedSourceDigest
	_publication_furniture_digest = prepared.furnitureDigest
	_expected_publication_source = prepared.expectedPublishedSourceSnapshot
	_expected_publication_furniture = prepared.expectedFurnitureSnapshot
	_review = prepared.duplicate()
	for key in ["blueprint", "furnishingPlan", "evidence", "expectedPublishedSourceSnapshot", "expectedFurnitureSnapshot"]: _review.erase(key)
	selected_seed = int(prepared.fixture.seed)
	selected_citadel_scale = float(prepared.fixture.citadelScale)
	selected_style = String(_prepared_source.style)
	for part in _prepared_source.parts:
		if part.collision_enabled and CitadelUrbanPocComposerScript.is_primary_tree_paving(part):
			_paving_ray_bottom = minf(_paving_ray_bottom, (_prepared_source.transformed_part_bounds(part) as AABB).position.y)
	if not is_finite(_paving_ray_bottom):
		_finish("no_actual_public_paving_for_exterior_cameras")
		return
	is_rebuilding = false
	_stage = "publication"
	await rebuild_fixture(false) # Existing real incremental building/furniture path.
	if _finished or blueprint == null: return
	await write_automated_report()


func _process(delta: float) -> void:
	# No parent door-service act, player movement or rebuild hotkeys.
	if is_rebuilding:
		loading_elapsed += delta
		update_loading_label()
	if _started == 0 or _finished: return
	var now := Time.get_ticks_msec()
	if now - _started > TOTAL_MSEC:
		_finish("whole_review_deadline")
		return
	if now < _next_progress: return
	_next_progress = now + 1000
	_worker_mutex.lock()
	var worker_status := _worker_state.duplicate()
	_worker_mutex.unlock()
	if not _write_json(_progress_path, {"stage": _stage, "worker": worker_status,
		"elapsedMsec": now - _started, "updatedUnixSeconds": Time.get_unix_time_from_system(),
		"capturesAttempted": _capture_results.filter(func(row): return bool(row.get("attempted", false))).size(),
		"viewRowsCompleted": _capture_results.size(), "expectedViews": EXPECTED_VIEWS, "selection": _selection,
		"activeViewId": _active_view_id,
		"publishedParts": building_publisher.published_part_count if building_publisher != null else 0,
		"rayTests": _ray_tests, "finished": false}):
		_finish("progress_write_failed")


func _unhandled_key_input(_event: InputEvent) -> void:
	pass


func _exit_tree() -> void:
	_restore_visibility()
	_worker_mutex.lock()
	_worker_state.cancel = true
	_worker_mutex.unlock()
	# Bounded source work cannot outlive its owner, including window-close paths.
	if _worker != null and _worker.is_started():
		_worker.wait_to_finish()
		_worker = null
	super._exit_tree()


func prepare_castle_blueprint():
	var result = _prepared_source
	_prepared_source = null
	if result != null:
		install_generated_city_trees(result)
		install_city_lights(result)
	return result


func prepare_castle_furnishings():
	# Already independently regenerated and compared with the immutable oracle.
	# Do not let the base add/rewrite an interior-program annotation here.
	var result = _prepared_furnishing_plan
	_prepared_furnishing_plan = null
	return result


func exterior_support_for_review(horizontal: Vector3, target_y: float, minimum_support_y: float) -> Dictionary:
	_review_support_diagnostics.queries += 1
	_review_support_view().queries += 1
	if not _budget_reason().is_empty(): return {}
	# A tall roof's focus height must not truncate the standing-surface ray above
	# the real courtyard. Only the ray extent changes; the existing solver still
	# owns capsule clearance, sightlines, framing and its 64-candidate budget.
	if get_world_3d() == null or not is_finite(_paving_ray_bottom): return _record_review_support_rejection("missing_world_or_extent", {"horizontal": horizontal})
	var query := PhysicsRayQueryParameters3D.create(Vector3(horizontal.x, target_y + 7.0, horizontal.z), Vector3(horizontal.x, _paving_ray_bottom, horizontal.z))
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return _review_support_hit(hit, horizontal, target_y, minimum_support_y)

func _review_support_hit(hit: Dictionary, horizontal: Vector3, target_y: float, minimum_support_y: float) -> Dictionary:
	var diagnostic := {"horizontal": horizontal, "targetY": target_y, "rayBottom": _paving_ray_bottom}
	if hit.is_empty(): return _record_review_support_rejection("ray_miss", diagnostic)
	diagnostic["hitPosition"] = hit.position
	diagnostic["normal"] = hit.normal
	var body = hit.collider
	var id := ""
	if body is CollisionObject3D and hit.has("shape"):
		var owner = body.shape_owner_get_owner(body.shape_find_owner(int(hit.shape)))
		if owner is Node: id = String(owner.get_meta("building_part_id", ""))
	if id.is_empty() and body is Node: id = String(body.get_meta("building_part_id", ""))
	diagnostic["resolvedPartId"] = id
	# Read-only owner observation precedes rejection, but rejection precedence
	# and all admission predicates remain in their original order.
	if (hit.normal as Vector3).y < 0.72: return _record_review_support_rejection("normal", diagnostic)
	if (hit.position as Vector3).y > target_y + 0.08: return _record_review_support_rejection("above_target", diagnostic)
	if (hit.position as Vector3).y < minimum_support_y: return _record_review_support_rejection("below_minimum", diagnostic)
	var part = blueprint.find_part(id)
	if part == null: return _record_review_support_rejection("unresolved_part_owner", diagnostic)
	diagnostic["kind"] = part.kind
	diagnostic["material"] = part.material_id
	diagnostic["semantic"] = part.semantic
	if not part.collision_enabled: return _record_review_support_rejection("collision_disabled", diagnostic)
	if not CitadelUrbanPocComposerScript.is_primary_tree_paving(part): return _record_review_support_rejection("not_public_paving", diagnostic)
	_review_support_diagnostics.accepted += 1
	_review_support_view().accepted += 1
	return {"position": (hit.position as Vector3) + Vector3(0, 0.055, 0), "collider": body, "partId": id}

func _record_review_support_rejection(reason: String, detail: Dictionary) -> Dictionary:
	for record: Dictionary in [_review_support_diagnostics, _review_support_view()]:
		var counts: Dictionary = record.rejections
		counts[reason] = int(counts.get(reason, 0)) + 1
		var examples: Dictionary = record.examples
		if not examples.has(reason): examples[reason] = []
		if examples[reason].size() < 4: examples[reason].append(detail.duplicate(true))
	return {} # Exactly the original rejected-support result; no retry/fallback.

func _review_support_view() -> Dictionary:
	var id := _active_view_id if not _active_view_id.is_empty() else "unscoped"
	var views: Dictionary = _review_support_diagnostics.views
	if not views.has(id) and views.size() >= 32: id = "overflow"
	if not views.has(id): views[id] = {"queries": 0, "accepted": 0, "rejections": {}, "examples": {}}
	return views[id]


func _worker_continue(stage: String, completed: int, deadline: int) -> bool:
	_worker_mutex.lock()
	_worker_state.stage = stage
	_worker_state.completedChimneys = completed
	var allowed: bool = not _worker_state.cancel and Time.get_ticks_msec() < deadline
	_worker_mutex.unlock()
	return allowed


func _prepare_review(path: String, evidence_path: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + PREPARATION_MSEC
	if not _bounded_file(path) or not _bounded_file(evidence_path) or FileAccess.get_sha256(path) != REVIEW_SHA:
		return {"ready": false, "reason": "invalid_input_or_frozen_sha"}
	var evidence_sha := FileAccess.get_sha256(evidence_path)
	var evidence: Variant = JSON.parse_string(FileAccess.get_file_as_string(evidence_path))
	if not evidence is Dictionary or not bool(evidence.get("diagnosticCompleted", false)) or not bool(evidence.get("immutableInputUnchanged", false)) or not bool(evidence.get("originalSpatialVisualAndCollisionPayloadsExact", false)) or not bool(evidence.get("originalMaterialAndCustomDataPayloadsExact", false)) or not bool(evidence.get("allOriginalPayloadsExact", false)):
		return {"ready": false, "reason": "strict_published_parity_evidence_required"}
	if not evidence.get("constructed") is Array or evidence.constructed.size() != 11 or not evidence.get("blocked") is Array or evidence.blocked.size() != 5 or not evidence.get("jointMatrix") is Array or evidence.jointMatrix.size() != 66 or not evidence.get("contacts") is Array or evidence.contacts.size() > 256:
		return {"ready": false, "reason": "incomplete_published_joint_evidence"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ready": false, "reason": "source_open_failed"}
	var archive: Variant = file.get_var(false)
	var read_ok := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not read_ok or not archive is Dictionary or not archive.get("sourceSnapshot") is Dictionary or not archive.get("furnitureSnapshot") is Dictionary or not archive.get("protectedReservations") is Array or not archive.get("fixture") is Dictionary:
		return {"ready": false, "reason": "invalid_reviewed_envelope"}
	var source: Dictionary = archive.sourceSnapshot
	if not source.get("parts") is Array or source.parts.size() > MAX_SOURCE_PARTS or archive.furnitureSnapshot.get("parts", []).size() != 152:
		return {"ready": false, "reason": "unexpected_source_scope"}
	var candidate = SourceCopy.copy_source(source)
	if _digest(candidate.snapshot()) != _digest(source): return {"ready": false, "reason": "source_copy_not_exact"}
	var furniture_boxes: Dictionary = SourceCopy.furnishing_obstacles(archive.furnitureSnapshot, archive.protectedReservations)
	if not furniture_boxes.ready: return furniture_boxes
	var expected: Dictionary = source.duplicate(true)
	var expected_records: Dictionary = {}
	for record in expected.parts:
		if expected_records.has(record.id): return {"ready": false, "reason": "duplicate_source_id"}
		expected_records[record.id] = record
	var constructed: Array = []
	var blocked: Array = []
	var count := 0
	# Fixture ownership comes from the actual producer's chimney/house namespace,
	# exactly as in the frozen collector. It never supplies a pose or repair rule.
	for record in source.parts:
		if record.semantic != "citadel_urban_chimney": continue
		count += 1
		if count > 16 or not _worker_continue("chimney_recipe", count - 1, deadline):
			return {"ready": false, "reason": "preparation_cancelled_or_bounded"}
		var prefix: String = record.id.trim_suffix("_chimney")
		var gables := [prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"]
		var upstream := [prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"]
		var proposal: Dictionary = ChimneyRecipe.apply(candidate, record.id, gables, upstream, furniture_boxes.obstacles)
		if not proposal.ready:
			blocked.append({"chimneyId": record.id, "reason": proposal.reason})
			continue
		constructed.append({"chimneyId": record.id, "bearerId": proposal.partIds[0], "gableIds": gables})
		expected_records[record.id].recipe = proposal.chimneyRecipe.duplicate(true)
		expected.parts.append(proposal.bearerRecord.duplicate(true))
	if count != 16 or _json(constructed) != evidence.constructed or _json(blocked) != evidence.blocked or _digest(expected) != _digest(candidate.snapshot()):
		return {"ready": false, "reason": "candidate_scope_or_exact_source_changes_differ"}
	if not _worker_continue("furniture_parity", count, deadline): return {"ready": false, "reason": "preparation_deadline"}
	var furniture_before = ReviewFurniture.build(SourceCopy.copy_source(source), int(archive.fixture.furnitureSeed))
	var furniture_after = ReviewFurniture.build(SourceCopy.copy_source(candidate.snapshot()), int(archive.fixture.furnitureSeed))
	for plan in [furniture_before, furniture_after]:
		if plan == null or _digest(plan.snapshot()) != _digest(archive.furnitureSnapshot) or _digest(plan.protected_access_reservations) != _digest(archive.protectedReservations):
			return {"ready": false, "reason": "furniture_or_access_not_exact"}
	# Predict ONLY the existing publisher's validation side effects on a copy.
	# Authored source exactness was checked above; no cache/root is invented.
	if not _worker_continue("publication_validation_copy", count, deadline):
		return {"ready": false, "reason": "validation_budget"}
	var publication_copy = SourceCopy.copy_source(candidate.snapshot())
	var prediction: Dictionary = _predict_publication_validation(publication_copy)
	if not bool(prediction.ready): return prediction
	var physical: Dictionary = prediction.physical
	var expected_publication: Dictionary = publication_copy.snapshot()
	var expected_furniture: Array = [furniture_after.snapshot(), furniture_after.protected_access_reservations.duplicate(true)]
	if not _worker_continue("prepared", count, deadline) or FileAccess.get_sha256(path) != REVIEW_SHA or FileAccess.get_sha256(evidence_path) != evidence_sha:
		return {"ready": false, "reason": "deadline_or_inputs_changed"}
	return {"ready": true, "blueprint": candidate, "furnishingPlan": furniture_after, "evidence": evidence,
		"constructed": constructed, "blocked": blocked, "fixture": archive.fixture,
		"baselineSha256": REVIEW_SHA, "publishedEvidencePath": evidence_path, "publishedEvidenceSha256": evidence_sha,
		"sourceExactExcept11BearersAndMandatoryChimneySeats": true, "regeneratedFurnitureAndAccessExact": true,
		"expectedPublishedSourceDigest": _digest(expected_publication), "expectedPublishedSourceSnapshot": expected_publication,
		"furnitureDigest": _digest(expected_furniture), "expectedFurnitureSnapshot": expected_furniture,
		"expectedPublicationValidationSequence": ["CastleCompoundBlueprintBuilder.validate_raised_route_coverage", "BuildingBlueprint.validate_physical_integrity"],
		"publicationRouteCoveragePassed": bool(prediction.routeCoverage.passed),
		"publicationRouteViolationCount": prediction.routeCoverage.get("violations", []).size(),
		"physicalPassed": bool(physical.passed), "physicalViolationCount": physical.violations.size(),
		"planningOffMainThread": true}


static func _predict_publication_validation(publication_copy) -> Dictionary:
	if not _validation_bounded(publication_copy): return {"ready": false, "reason": "validation_budget"}
	# Same public source validators, in the same order as begin_publication.
	# Route coverage conditionally resolves physical contracts before physical
	# validation resolves again. Do not emulate that with stripped cache fields
	# or a manually assigned resolution marker. Existing route failures remain
	# reported, not converted into route or whole-physical-gate acceptance.
	var route_coverage: Dictionary = CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(publication_copy)
	var physical: Dictionary = publication_copy.validate_physical_integrity()
	return {"ready": true, "routeCoverage": route_coverage, "physical": physical}


static func _bounded_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return false
	var valid := file.get_length() > 0 and file.get_length() <= MAX_INPUT_BYTES
	file.close()
	return valid


static func _validation_bounded(b) -> bool:
	var cells := 0.0
	for part in b.parts:
		if not b.has_finite_positive_bounds(part): return false
		var bounds: AABB = b.transformed_part_bounds(part).grow(b.PHYSICAL_CONTACT_MARGIN * sqrt(3.0))
		if not ChimneyRecipe._bounds_valid(bounds): return false
		var nx := floorf(bounds.end.x / b.PHYSICAL_SUPPORT_GRID_CELL) - floorf(bounds.position.x / b.PHYSICAL_SUPPORT_GRID_CELL) + 1.0
		var nz := floorf(bounds.end.z / b.PHYSICAL_SUPPORT_GRID_CELL) - floorf(bounds.position.z / b.PHYSICAL_SUPPORT_GRID_CELL) + 1.0
		if nx < 1 or nz < 1 or nx > 4096 or nz > 4096: return false
		cells += nx * nz
		if cells > 1000000: return false
	return true


func write_automated_report() -> void:
	var readiness := await wait_for_capture_readiness()
	if _finished: return
	var actual_source: Variant = blueprint.snapshot() if blueprint != null else null
	var actual_furniture: Variant = [furnishing_plan.snapshot(), furnishing_plan.protected_access_reservations] if furnishing_plan != null else null
	var parity: Dictionary = _publication_parity_evidence(readiness, _expected_publication_source, actual_source, _expected_publication_furniture, actual_furniture)
	parity["retainedExpectedDigestsExact"] = parity.source.expectedDigest == _publication_source_digest and parity.furniture.expectedDigest == _publication_furniture_digest
	_review["publicationParity"] = parity
	if not bool(parity.passed) or not bool(parity.retainedExpectedDigestsExact):
		_finish("publication_readiness_or_exact_source_furniture_parity_failed")
		return
	_review["publishedSourceAndFurnitureExact"] = true
	_stage = "index_live_visuals"
	if not await _index_scene():
		_finish("invalid_or_excessive_live_visuals")
		return
	var specs := _view_specs()
	if specs.size() != EXPECTED_VIEWS:
		_finish("incomplete_11_33_8_coverage_inventory")
		return
	# Always construct/validate the entire real 11/33/8 inventory above before
	# selection. A shard is a subset of evidence, never a smaller source world.
	_selection = _select_views(specs, _view_allowlist, _view_allowlist_present)
	if not bool(_selection.ready):
		_finish("invalid_view_selection")
		return
	var available_specs: Array = []
	for spec in specs:
		if spec.kind == "brick_cluster":
			for child in spec.children:
				available_specs.append(child)
				_detail_inventory.append(_detail_fact(child))
		else:
			available_specs.append(spec)
	_selected_specs = available_specs.filter(func(spec): return _selection.selectedIds.has(spec.id))
	_camera = Camera3D.new()
	_camera.name = "ChimneyDiagnosticCamera"
	_camera.fov = 62.0
	_camera.near = 0.05
	add_child(_camera)
	_camera.current = true
	for child in get_children():
		if child is CanvasLayer: child.visible = false
	var before_state := _live_state_digest()
	if not _state_error.is_empty():
		_finish(_state_error)
		return
	_stage = "capture"
	for spec in _selected_specs:
		if _finished: return
		_restore_visibility()
		var budget_reason: String = _budget_reason()
		if not budget_reason.is_empty():
			_capture_results.append(_capture_row(spec, _budget_view_result(budget_reason, false), false, _ray_tests, Time.get_ticks_msec()))
			continue
		_active_view_id = spec.id
		_active_view_ray_start = _ray_tests
		_active_view_time_start = Time.get_ticks_msec()
		var view: Dictionary = await _choose_view(spec)
		if _finished: return
		var row: Dictionary = _capture_row(spec, view, true, _active_view_ray_start, _active_view_time_start)
		if bool(view.get("ok", false)):
			_camera.global_position = view.position
			_camera.look_at(view.target, Vector3.UP)
			for frame in range(8): await get_tree().process_frame
			if _finished: return
			RenderingServer.force_draw(false)
			var image := get_viewport().get_texture().get_image()
			var capture_path := screenshot_dir.path_join(spec.id + ".png")
			if not image.is_empty() and not FileAccess.file_exists(capture_path):
				row.captured = image.save_png(capture_path) == OK
				if row.captured: row.screenshot = capture_path
		_restore_visibility()
		row["visibilityRestored"] = _hidden.is_empty()
		row["work"] = _view_work(_active_view_ray_start, _ray_tests, _active_view_time_start, Time.get_ticks_msec())
		_capture_results.append(row)
		_active_view_id = ""
		await get_tree().process_frame
	var after_state := _live_state_digest()
	_review["liveStateDigestBefore"] = before_state
	_review["liveStateDigestAfter"] = after_state
	_review["liveSpatialMaterialCustomDataAndCollisionStateExact"] = before_state == after_state and _state_error.is_empty()
	_review["postCaptureSourceAndFurnitureExact"] = _digest(blueprint.snapshot()) == _publication_source_digest and _digest([furnishing_plan.snapshot(), furnishing_plan.protected_access_reservations]) == _publication_furniture_digest
	var completion: Dictionary = _selected_completion(_selection, _capture_results)
	var complete: bool = bool(completion.selectedComplete) and bool(_review.liveSpatialMaterialCustomDataAndCollisionStateExact) and bool(_review.postCaptureSourceAndFurnitureExact)
	var success_reason: String = "captures_complete_awaiting_human_review" if _selection.mode == "full" else "shard_captures_complete_awaiting_human_review"
	_finish(success_reason if complete else (_budget_reason() if not _budget_reason().is_empty() else "incomplete_capture_or_parity_failure"))


static func _select_views(specs: Array, allowlist: String, provided: bool) -> Dictionary:
	var invalid: Dictionary = {"ready": false, "mode": "unselected", "selectedIds": [], "reason": "invalid_full_inventory"}
	if specs.size() != EXPECTED_VIEWS: return invalid
	var ids: Array = []
	var available: Array = []
	var parent_children: Dictionary = {}
	for index in range(EXPECTED_VIEWS):
		var kind: String = "brick_cluster" if index >= 22 else ("ordinary" if index % 2 == 0 else "assembly")
		var expected: String = "%02d_%s" % [index, kind]
		if not specs[index] is Dictionary or specs[index].get("id") != expected or specs[index].get("kind") != kind: return invalid
		ids.append(expected)
		if kind == "brick_cluster":
			if not specs[index].get("children") is Array or specs[index].children.size() != 2: return invalid
			var children: Array = []
			for side in range(2):
				var child: Variant = specs[index].children[side]
				var child_id: String = expected + ("_face_negative" if side == 0 else "_face_positive")
				if not child is Dictionary or child.get("id") != child_id or child.get("parentId") != expected or child.get("kind") != "brick_face": return invalid
				children.append(child_id)
				available.append(child_id)
			parent_children[expected] = children
		else:
			available.append(expected)
	invalid["reason"] = "invalid_allowlist"
	if allowlist.length() > 1024 or (provided and allowlist.is_empty()) or (not provided and not allowlist.is_empty()): return invalid
	var requested: Array = []
	if provided:
		var tokens: PackedStringArray = allowlist.split(",", true)
		if tokens.size() > EXPECTED_VIEWS: return invalid
		for token in tokens:
			if not ids.has(token) and not available.has(token): return invalid
			var expanded: Array = parent_children.get(token, [token])
			for id in expanded:
				if requested.has(id): return invalid
				requested.append(id)
	else:
		requested = available.duplicate()
	if requested.size() > EXPECTED_VIEWS:
		return {"ready": false, "mode": "unselected", "selectedIds": [], "reason": "expanded_capture_limit_requires_shard", "fullInventoryValidated": true, "fullInventoryIds": ids, "availableCaptureIds": available, "parentChildren": parent_children}
	var selected: Array = available.filter(func(id): return requested.has(id))
	return {"ready": true, "fullInventoryValidated": true, "mode": "shard",
		"fullInventoryIds": ids, "availableCaptureIds": available, "parentChildren": parent_children,
		"requestedIds": requested, "selectedIds": selected,
		"notSelectedIds": available.filter(func(id): return not requested.has(id)), "reason": ""}


static func _selected_completion(selection: Dictionary, rows: Array) -> Dictionary:
	var complete: bool = bool(selection.get("ready", false)) and not selection.get("selectedIds", []).is_empty() and rows.size() == selection.get("selectedIds", []).size()
	if complete:
		for index in range(rows.size()):
			if not rows[index] is Dictionary or rows[index].get("id") != selection.selectedIds[index] or not bool(rows[index].get("attempted", false)) or not bool(rows[index].get("captured", false)) or not bool(rows[index].get("visibilityRestored", false)):
				complete = false
				break
	return {"selectedComplete": complete, "fullComplete": complete and selection.get("mode") == "full", "shardComplete": complete and selection.get("mode") == "shard"}


static func _view_work(ray_start: int, ray_end: int, time_start: int, time_end: int) -> Dictionary:
	return {"rayTestsStart": ray_start, "rayTestsEnd": ray_end, "rayTestsDelta": ray_end - ray_start,
		"startedTicksMsec": time_start, "endedTicksMsec": time_end, "elapsedMsec": time_end - time_start}


static func _budget_view_result(reason: String, attempted: bool) -> Dictionary:
	return {"ok": false, "reason": reason if attempted else "not_attempted_budget_exhausted", "budgetReason": reason,
		"geometricVisibilityDetermined": false}


func _budget_reason() -> String:
	if _ray_tests >= MAX_RAY_TESTS: return "ray_budget_exhausted"
	if _started > 0 and Time.get_ticks_msec() - _started >= TOTAL_MSEC: return "time_budget_exhausted"
	return ""


func _capture_row(spec: Dictionary, view: Dictionary, attempted: bool, ray_start: int, time_start: int) -> Dictionary:
	return {"id": spec.id, "kind": spec.kind, "bearerId": spec.bearerId,
		"parentId": spec.get("parentId", ""), "externalImageCredit": "not_assessed",
		"interfaceIds": spec.get("interfaceIds", []), "brickPrimitiveIds": spec.get("brickPrimitiveIds", []),
		"bounds": spec.bounds, "camera": view, "hiddenPartIds": _hidden.keys(), "attempted": attempted,
		"captured": false, "screenshot": "", "diagnosticCutaway": spec.kind != "ordinary",
		"visibilityRestored": _hidden.is_empty(), "work": _view_work(ray_start, _ray_tests, time_start, Time.get_ticks_msec() if attempted else time_start)}


func _index_scene() -> bool:
	var pending: Array = [{"node": self, "partId": ""}]
	var count := 0
	var primitives := 0
	while not pending.is_empty():
		var entry: Dictionary = pending.pop_back()
		var node: Node = entry.node
		var id := String(node.get_meta("building_part_id", entry.partId))
		count += 1
		if count > MAX_SCENE_NODES or _finished:
			_review["indexFailure"] = {"reason": "node_limit_or_stopped", "count": count}
			return false
		if node is Node3D: _scene_nodes.append(node)
		if node is MeshInstance3D or node is MultiMeshInstance3D:
			var mesh: Mesh = node.mesh if node is MeshInstance3D else (node.multimesh.mesh if node.multimesh != null else null)
			if mesh == null:
				_review["indexFailure"] = {"reason": "missing_mesh", "partId": id, "node": String(node.get_path())}
				return false
			var instance_count: int = 1 if node is MeshInstance3D else node.multimesh.instance_count
			if node is MultiMeshInstance3D:
				var stride: int = 12 + (4 if node.multimesh.use_colors else 0) + (4 if node.multimesh.use_custom_data else 0)
				if not _instance_buffer_shape_valid(node.multimesh.transform_format, instance_count, node.multimesh.use_colors, node.multimesh.use_custom_data, node.multimesh.buffer.size()):
					_review["indexFailure"] = {"reason": "actual_instance_readback_unavailable", "partId": id, "node": String(node.get_path()), "count": instance_count, "bufferSize": node.multimesh.buffer.size(), "expectedSize": instance_count * stride}
					return false
			primitives += instance_count
			if primitives > MAX_PRIMITIVES:
				_review["indexFailure"] = {"reason": "primitive_limit", "count": primitives}
				return false
			var bounds := AABB()
			# Plane/cloth meshes may have a genuinely zero-thickness AABB. Keep
			# them as occluders, rather than silently omit or thicken them.
			if instance_count <= 0 or not node.global_transform.is_finite() or node.global_transform.basis.determinant() == 0:
				_review["indexFailure"] = {"reason": "empty_instances_or_invalid_transform", "partId": id, "node": String(node.get_path()), "transform": node.global_transform, "count": instance_count}
				return false
			var record := {"node": node, "partId": id, "bounds": bounds, "count": instance_count}
			# Aggregate MultiMesh bounds do not prove each instance is invertible.
			# Check every instance, including ones outside all later sightlines.
			for index in range(instance_count):
				var actual: Dictionary = _primitive(record, index)
				if actual.is_empty():
					_review["indexFailure"] = {"reason": _state_error, "partId": id, "node": String(node.get_path()), "index": index}
					return false
				# Headless RenderingServer may report an empty MultiMesh aggregate.
				# Build the inspection broad phase from EVERY actual mesh/instance,
				# identically in headed/headless mode. Never change renderer bounds.
				var actual_bounds: AABB = actual.transform * actual.localBounds
				bounds = actual_bounds if index == 0 else bounds.merge(actual_bounds)
				if index % 256 == 255:
					await get_tree().process_frame
					if _finished: return false
			record.bounds = bounds
			if not _finite_inspection_bounds(bounds):
				_review["indexFailure"] = {"reason": "nonfinite_merged_instance_bounds", "partId": id, "node": String(node.get_path())}
				return false
			_visuals.append(record)
			if not _part_visuals.has(id): _part_visuals[id] = []
			_part_visuals[id].append(record)
		for child in node.get_children(): pending.append({"node": child, "partId": id})
		if count % 256 == 0: await get_tree().process_frame
	_review["liveSceneNodeCount"] = count
	_review["liveMeshInstanceCount"] = primitives
	_review["inspectionBoundsFromActualPublishedInstances"] = true
	return true

static func _instance_buffer_shape_valid(format: int, count: int, colors: bool, custom: bool, size: int) -> bool:
	return format == MultiMesh.TRANSFORM_3D and count > 0 and count <= MAX_PRIMITIVES and size == count * (12 + (4 if colors else 0) + (4 if custom else 0))

static func _finite_inspection_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.end.is_finite() and bounds.size.is_finite() and bounds.size != Vector3.ZERO and bounds.size.x >= 0 and bounds.size.y >= 0 and bounds.size.z >= 0


func _view_specs() -> Array:
	var specs: Array = []
	var joint_keys: Dictionary = {}
	var bricks: Dictionary = {}
	var brick_clusters: Dictionary = {}
	for construction in _review.constructed:
		var chimney = blueprint.find_part(construction.chimneyId)
		var bearer = blueprint.find_part(construction.bearerId)
		if chimney == null or bearer == null: return []
		var prefix: String = chimney.id.trim_suffix("_chimney")
		var roof_ids := [prefix + "_roof_left", prefix + "_roof_right"]
		var house_bounds: AABB = blueprint.transformed_part_bounds(chimney)
		for id in roof_ids + construction.gableIds:
			var part = blueprint.find_part(id)
			if part == null or not _part_visuals.has(id): return []
			house_bounds = house_bounds.merge(_published_bounds(id))
		house_bounds = house_bounds.merge(_published_bounds(chimney.id))
		var roof_bounds: AABB = _published_bounds(roof_ids[0]).merge(_published_bounds(roof_ids[1]))
		var exposed: AABB = exposed_chimney_window(_published_bounds(chimney.id), roof_bounds)
		if not _finite_box(exposed): return []
		specs.append({"id": "%02d_ordinary" % specs.size(), "kind": "ordinary", "bearerId": bearer.id,
			"prefix": prefix, "bounds": house_bounds, "probeBounds": exposed, "roofIds": roof_ids, "targets": [chimney.id]})
		var interfaces: Array = []
		var interface_ids: Array = []
		var assembly_bounds: AABB = _published_bounds(bearer.id)
		for other_id in construction.gableIds + [chimney.id]:
			var key: String = bearer.id + ":" + other_id
			for channel in ["visual", "collision"]:
				var matches: Array = _evidence.jointMatrix.filter(func(row): return row is Dictionary and row.get("bearerId") == bearer.id and row.get("otherId") == other_id and row.get("channel") == channel)
				if matches.size() != 1 or joint_keys.has(key + channel): return []
				joint_keys[key + channel] = true
			var upper: AABB = blueprint.transformed_part_bounds(chimney if other_id == chimney.id else bearer)
			var lower: AABB = blueprint.transformed_part_bounds(bearer if other_id == chimney.id else blueprint.find_part(other_id))
			var window := joint_perimeter_window(upper, lower)
			if not _finite_box(window): return []
			assembly_bounds = assembly_bounds.merge(window)
			interface_ids.append(key)
			interfaces.append({"bounds": window, "targets": [bearer.id, other_id], "prefix": prefix})
		specs.append({"id": "%02d_assembly" % specs.size(), "kind": "assembly", "bearerId": bearer.id,
			"prefix": prefix, "bounds": assembly_bounds, "interfaces": interfaces, "interfaceIds": interface_ids})
	# These are exact collector candidates, NOT an exemption for a material,
	# owner, numeric penetration range or arbitrary future BrickCourses instance.
	for contact in _evidence.contacts:
		if not contact is Dictionary or contact.get("channel") != "visual": continue
		if not contact.get("measurement") is Dictionary or not contact.measurement.get("candidates") is Array or contact.measurement.candidates.size() > 4096: return []
		for pair in contact.measurement.candidates:
			if not pair is Dictionary or not pair.get("bPrimitive") is Dictionary: return []
			var primitive_id := String(pair.bPrimitive.get("id", ""))
			if primitive_id == "box:0:0": continue # Masonry bed; separately in joint views.
			var ids := primitive_id.split(":")
			if ids.size() != 3 or ids[0] != "box" or ids[1] != "1" or not ids[2].is_valid_int(): return []
			var other_id := String(contact.otherId)
			var key := other_id + ":" + primitive_id
			if bricks.has(key): return []
			var matches: Array = _part_visuals.get(other_id, []).filter(func(row): return String(row.node.name) == "BrickCourses" and row.node is MultiMeshInstance3D)
			if matches.size() != 1: return []
			var index := int(ids[2])
			if index < 0 or index >= matches[0].count: return []
			var primitive := _primitive(matches[0], index)
			if primitive.is_empty(): return []
			# Bind the report's exact ordinal to the real publisher instance. No
			# tolerance or nearest-brick search: float components are reconstructed
			# into the same Godot float32 basis/origin representation.
			if primitive.transform != _reported_transform(pair.bPrimitive.get("transform", {})): return []
			var bearer_id := String(contact.bearerId)
			if not _review.constructed.any(func(row): return row.bearerId == bearer_id and row.gableIds.has(other_id)): return []
			bricks[key] = true
			var group: Dictionary = _brick_review_group(primitive, bearer_id, _published_bounds(bearer_id), bearer_id.trim_suffix("_chimney_bearing"))
			if group.is_empty(): return []
			group["measuredSignedGap"] = pair.get("boxSatGreatestAxisGap")
			group["brickPrimitiveId"] = key
			if not brick_clusters.has(bearer_id):
				brick_clusters[bearer_id] = {"kind": "brick_cluster", "bearerId": bearer_id,
					"prefix": bearer_id.trim_suffix("_chimney_bearing"), "bounds": group.bounds,
					"brickPrimitiveIds": [], "bricks": []}
			var cluster: Dictionary = brick_clusters[bearer_id]
			cluster.bounds = (cluster.bounds as AABB).merge(group.bounds)
			cluster.brickPrimitiveIds.append(key)
			cluster.bricks.append(group)
	if joint_keys.size() != 66 or bricks.size() != 8 or brick_clusters.size() != 2: return []
	for cluster in brick_clusters.values():
		cluster["id"] = "%02d_brick_cluster" % specs.size()
		var wall_id: String = cluster.bricks[0].exactPrimitive.partId
		var wall = blueprint.find_part(wall_id)
		if wall == null or wall.kind != "wall": return []
		var children: Array = _brick_face_children(cluster, Transform3D(Basis.from_euler(wall.rotation), wall.position), wall.size)
		if children.size() != 2: return []
		var bearer_records: Array = _part_visuals.get(cluster.bearerId, [])
		if bearer_records.size() != 1 or bearer_records[0].count != 1: return []
		var bearer_primitive: Dictionary = _primitive(bearer_records[0], 0)
		for child in children:
			child["inspectionCandidate"] = _below_bearer_candidate(child, bearer_primitive)
		cluster["children"] = children
		specs.append(cluster)
	return specs


static func _brick_face_children(cluster: Dictionary, wall_transform: Transform3D, wall_size: Vector3) -> Array:
	# Exact published OBB corners, projected on the owning SOURCE wall's
	# transformed thin-axis normal. Ordinals are identities, never classifiers.
	if not cluster.get("bricks") is Array or cluster.bricks.size() != 4 or not cluster.get("id") is String or not cluster.get("bearerId") is String: return []
	if not _primitive_record_valid({"transform": wall_transform, "localBounds": AABB(-wall_size * 0.5, wall_size)}) or not _finite_box(AABB(Vector3.ZERO, wall_size)): return []
	if wall_size.x == wall_size.z: return []
	var axis: int = 0 if wall_size.x < wall_size.z else 2
	if wall_size[axis] >= wall_size.y: return []
	var normal: Vector3 = wall_transform.basis.inverse().transposed()[axis].normalized()
	var tangent: Vector3 = wall_transform.basis[2 if axis == 0 else 0].normalized()
	if not normal.is_finite() or not tangent.is_finite() or normal.length_squared() == 0.0 or tangent.length_squared() == 0.0: return []
	var partitions: Array = [[], []]
	var identities: Dictionary = {}
	var primitive_indices: Dictionary = {}
	var wall_id: String = ""
	for source_group in cluster.bricks:
		if not source_group is Dictionary or not source_group.get("exactPrimitive") is Dictionary or not source_group.get("brickPrimitiveId") is String: return []
		var primitive: Dictionary = source_group.exactPrimitive
		if not _primitive_record_valid(primitive) or not primitive.get("partId") is String or not primitive.get("index") is int or primitive.index < 0: return []
		if wall_id.is_empty(): wall_id = primitive.partId
		if wall_id.is_empty() or primitive.partId != wall_id or wall_id == cluster.bearerId or source_group.brickPrimitiveId.is_empty() or identities.has(source_group.brickPrimitiveId) or primitive_indices.has(primitive.index): return []
		if source_group.get("targets") != [wall_id, cluster.bearerId] or not source_group.get("bounds") is AABB or not _finite_box(source_group.bounds): return []
		identities[source_group.brickPrimitiveId] = true
		primitive_indices[primitive.index] = true
		var lo: float = INF
		var hi: float = -INF
		for corner in range(8):
			var point: Vector3 = primitive.transform * primitive.localBounds.get_endpoint(corner)
			var projection: float = (point - wall_transform.origin).dot(normal)
			if not is_finite(projection): return []
			lo = minf(lo, projection)
			hi = maxf(hi, projection)
		if lo <= 0.0 and hi >= 0.0: return [] # Straddling/ambiguous is not a face.
		var group: Dictionary = source_group.duplicate()
		group["wallNormalProjection"] = Vector2(lo, hi)
		partitions[0 if hi < 0.0 else 1].append(group)
	if partitions[0].size() != 2 or partitions[1].size() != 2: return []
	var children: Array = []
	for side in range(2):
		var sign_value: float = -1.0 if side == 0 else 1.0
		var groups: Array = partitions[side]
		groups.sort_custom(func(a, b): return String(a.brickPrimitiveId) < String(b.brickPrimitiveId))
		var bounds: AABB = (groups[0].bounds as AABB).merge(groups[1].bounds)
		var outer: float = wall_size[axis] * absf(normal.dot(wall_transform.basis[axis])) * 0.5
		for group in groups:
			var interval: Vector2 = group.wallNormalProjection
			outer = maxf(outer, -interval.x if side == 0 else interval.y)
		if not is_finite(outer) or outer <= 0.0: return []
		children.append({"id": cluster.id + ("_face_negative" if side == 0 else "_face_positive"),
			"kind": "brick_face", "parentId": cluster.id, "bearerId": cluster.bearerId, "wallId": wall_id,
			"prefix": cluster.get("prefix", ""), "bounds": bounds, "bricks": groups,
			"brickPrimitiveIds": groups.map(func(group): return group.brickPrimitiveId),
			"faceNormal": normal * sign_value, "faceTangent": tangent, "wallOrigin": wall_transform.origin,
			"wallTransform": wall_transform, "wallSize": wall_size, "thinAxis": axis, "faceOuterProjection": outer,
			"interfaceIds": [String(cluster.bearerId) + ":" + wall_id]})
	return children


static func _project_primitive(primitive: Dictionary, origin: Vector3, axes: Basis) -> AABB:
	var lo: Vector3 = Vector3(INF, INF, INF)
	var hi: Vector3 = -lo
	for corner in range(8):
		var world: Vector3 = primitive.transform * primitive.localBounds.get_endpoint(corner) - origin
		var point: Vector3 = Vector3(world.dot(axes.x), world.dot(axes.y), world.dot(axes.z))
		lo = lo.min(point)
		hi = hi.max(point)
	return AABB(lo, hi - lo)


static func _below_bearer_candidate(child: Dictionary, bearer: Dictionary) -> Dictionary:
	# A single external inspection pose, not a player pose. Only exposed brick
	# bands and the underside BETWEEN bricks are evidence; buried patches are not.
	var rejected: Dictionary = {"ready": false, "reason": "invalid_lower_band_geometry", "fullSceneVisibilityProven": false}
	if child.get("kind") != "brick_face" or not child.get("bricks") is Array or child.bricks.size() != 2 or not _primitive_record_valid(bearer): return rejected
	if not child.get("faceNormal") is Vector3 or not child.get("faceTangent") is Vector3 or not child.get("wallOrigin") is Vector3 or not child.get("bounds") is AABB: return rejected
	var normal: Vector3 = child.faceNormal
	var tangent: Vector3 = child.faceTangent
	var origin: Vector3 = child.wallOrigin
	if not normal.is_finite() or not tangent.is_finite() or not origin.is_finite() or normal.length_squared() == 0 or tangent.length_squared() == 0 or normal.y != 0 or tangent.y != 0 or not _finite_box(child.bounds): return rejected
	# Current bearer is upright. Do not substitute an AABB underside for a tilted
	# mesh, or interpret a sloping wall as this narrowly supported camera case.
	var beam_transform: Transform3D = bearer.transform
	if beam_transform.basis.x.y != 0 or beam_transform.basis.z.y != 0 or beam_transform.basis.y.x != 0 or beam_transform.basis.y.z != 0: return rejected
	var axes: Basis = Basis(tangent, Vector3.UP, normal)
	var beam: AABB = _project_primitive(bearer, origin, axes)
	if not _finite_box(beam) or bearer.get("partId") != child.get("bearerId"): return rejected
	var rows: Array = []
	for group in child.bricks:
		if not group is Dictionary or not group.get("exactPrimitive") is Dictionary or not _primitive_record_valid(group.exactPrimitive): return rejected
		if group.exactPrimitive.get("partId") != child.get("wallId") or group.get("targets") != [child.get("wallId"), child.get("bearerId")]: return rejected
		var projected: AABB = _project_primitive(group.exactPrimitive, origin, axes)
		if not _finite_box(projected) or projected.position.z <= 0: return rejected
		rows.append({"group": group, "projected": projected})
	rows.sort_custom(func(a, b): return a.projected.position.x < b.projected.position.x)
	var gap_lo: float = maxf(rows[0].projected.end.x, beam.position.x)
	var gap_hi: float = minf(rows[1].projected.position.x, beam.end.x)
	if gap_lo >= gap_hi:
		rejected.reason = "no_actual_inter_brick_gap_under_bearer"
		return rejected
	var samples: Array = []
	var bands: Array = []
	for index in range(2):
		var primitive: Dictionary = rows[index].group.exactPrimitive
		var transform: Transform3D = primitive.transform
		var box: AABB = primitive.localBounds
		var face_axis: int = 0
		var along_axis: int = 0
		for axis in range(1, 3):
			if absf(transform.basis[axis].normalized().dot(normal)) > absf(transform.basis[face_axis].normalized().dot(normal)): face_axis = axis
			if absf(transform.basis[axis].normalized().dot(tangent)) > absf(transform.basis[along_axis].normalized().dot(tangent)): along_axis = axis
		if face_axis == along_axis: return rejected
		var vertical_axis: int = 3 - face_axis - along_axis
		var local: Vector3 = box.get_center()
		local[face_axis] = box.end[face_axis] if transform.basis[face_axis].dot(normal) > 0 else box.position[face_axis]
		var outward: float = -1.0 if index == 0 else 1.0
		local[along_axis] += outward * signf(transform.basis[along_axis].dot(tangent)) * box.size[along_axis] * 0.375
		local[vertical_axis] = box.position[vertical_axis]
		var bottom: Vector3 = transform * local
		local[vertical_axis] = box.end[vertical_axis]
		var top: Vector3 = transform * local
		if bottom.y > top.y:
			var swap: Vector3 = bottom
			bottom = top
			top = swap
		var ceiling: float = minf(top.y, origin.y + beam.position.y)
		if bottom.y >= ceiling:
			rejected.reason = "brick_has_no_exposed_lower_band"
			return rejected
		var point: Vector3 = bottom.lerp(top, ((bottom.y + ceiling) * 0.5 - bottom.y) / (top.y - bottom.y))
		if not point.is_finite() or point.y >= origin.y + beam.position.y or not _inside_closed(rows[index].group.bounds, point): return rejected
		samples.append({"id": rows[index].group.brickPrimitiveId, "point": point})
		bands.append({"id": rows[index].group.brickPrimitiveId, "bottom": bottom, "upperY": ceiling, "sample": point})
	# A positive gap in full projected OBB extents, not merely centre spacing.
	# The normal column must overlap BOTH brick depths and the real underside.
	var normal_lo: float = maxf(beam.position.z, maxf(rows[0].projected.position.z, rows[1].projected.position.z))
	var normal_hi: float = minf(beam.end.z, minf(rows[0].projected.end.z, rows[1].projected.end.z))
	if normal_lo >= normal_hi:
		rejected.reason = "no_shared_underside_column"
		return rejected
	var gap: Vector3 = Vector3((gap_lo + gap_hi) * 0.5, beam.position.y, (normal_lo + normal_hi) * 0.5)
	var seat: Vector3 = origin + axes * gap
	var eye: Vector3 = origin + tangent * gap.x + normal * (float(child.faceOuterProjection) + (child.bounds as AABB).size.length())
	eye.y = minf(samples[0].point.y, samples[1].point.y)
	if not eye.is_finite() or not seat.is_finite() or not _face_camera_allowed(child, eye): return rejected
	for group in child.bricks:
		if not _inside_closed(group.bounds, seat): return rejected
	var primitives: Array = [rows[0].group.exactPrimitive, rows[1].group.exactPrimitive, bearer]
	var points: Array = [samples[0].point, samples[1].point, seat]
	var clear: bool = true
	for target_index in range(3):
		for blocker_index in range(3):
			if blocker_index == target_index: continue
			var blocker: Dictionary = primitives[blocker_index]
			var inverse: Transform3D = blocker.transform.affine_inverse()
			if blocker.localBounds.intersects_segment(inverse * eye, inverse * points[target_index]) != null: clear = false
	return {"ready": clear, "reason": "" if clear else "local_joint_ray_blocked", "position": eye,
		"target": (child.bounds as AABB).get_center(), "brickSamples": samples, "lowerBands": bands,
		"undersideSample": seat, "gapTangentInterval": Vector2(gap_lo, gap_hi), "bearerUndersideY": origin.y + beam.position.y,
		"localJointClearance": {"clear": clear, "pairTests": 6, "scope": "two_exact_bricks_and_bearer_only"},
		"fullSceneVisibilityProven": false, "evidenceScope": "external_visible_brick_bearer_interface_not_buried_internal_patch"}


static func _detail_fact(child: Dictionary) -> Dictionary:
	var facts: Array = []
	for group in child.bricks:
		var primitive: Dictionary = group.exactPrimitive
		var transform: Transform3D = primitive.transform
		var interval: Vector2 = group.wallNormalProjection
		facts.append({"id": group.brickPrimitiveId, "bounds": transform * primitive.localBounds,
			"localMeshBounds": primitive.localBounds, "transform": {"basis": [transform.basis.x, transform.basis.y, transform.basis.z], "origin": transform.origin},
			"wallNormalProjection": [interval.x, interval.y], "interfaceWindow": group.bounds})
	return {"id": child.id, "parentId": child.parentId, "wallId": child.wallId, "bearerId": child.bearerId,
		"bounds": child.bounds, "thinAxis": child.thinAxis, "wallOrigin": child.wallOrigin, "wallSize": child.wallSize,
		"faceNormal": child.faceNormal, "faceOuterProjection": child.faceOuterProjection, "bricks": facts,
		"inspectionCandidate": child.get("inspectionCandidate", {}),
		"parentFulfilled": false, "externalCredit": "not_assessed_both_child_images_required"}


static func _face_camera_allowed(spec: Dictionary, position: Vector3) -> bool:
	return position.is_finite() and (position - (spec.wallOrigin as Vector3)).dot(spec.faceNormal) > float(spec.faceOuterProjection)


static func _brick_review_group(primitive: Dictionary, bearer_id: String, bearer_bounds: AABB, prefix: String) -> Dictionary:
	if not _primitive_record_valid(primitive) or not primitive.get("partId") is String or primitive.partId.is_empty() or bearer_id.is_empty() or bearer_id == primitive.partId: return {}
	var brick_bounds: AABB = primitive.transform * primitive.localBounds
	var context: AABB = joint_perimeter_window(bearer_bounds, brick_bounds)
	if not _finite_box(context): return {}
	# Frame the local bearing interface, not only the brick. Both participants
	# must independently win a visibility ray in this same cluster closeup.
	return {"bounds": brick_bounds.merge(context), "targets": [primitive.partId, bearer_id],
		"exactPrimitive": primitive, "prefix": prefix}


static func interface_window(upper: AABB, lower: AABB) -> AABB:
	# Both adjoining faces plus local context, including genuine positive gaps.
	if not _finite_box(upper) or not _finite_box(lower): return AABB()
	var lo := Vector3(maxf(upper.position.x, lower.position.x), minf(upper.position.y, lower.end.y), maxf(upper.position.z, lower.position.z))
	var hi := Vector3(minf(upper.end.x, lower.end.x), maxf(upper.position.y, lower.end.y), minf(upper.end.z, lower.end.z))
	var context := minf(upper.size.y, lower.size.y) * 0.5
	lo.y -= context
	hi.y += context
	return AABB(lo, hi - lo)


static func joint_perimeter_window(upper: AABB, lower: AABB) -> AABB:
	var window: AABB = interface_window(upper, lower)
	if not _finite_box(window): return AABB()
	# Camera context only: expose the adjoining surface outside the upper
	# member's footprint. This changes neither geometry nor contact tolerances.
	return window.grow(minf(upper.size.x, minf(upper.size.y, upper.size.z)) * 0.5)


static func exposed_chimney_window(chimney: AABB, roof: AABB) -> AABB:
	if not _finite_box(chimney) or not _finite_box(roof): return AABB()
	var lo: Vector3 = chimney.position
	lo.y = maxf(lo.y, roof.end.y)
	return AABB(lo, chimney.end - lo)


func _published_bounds(id: String) -> AABB:
	var result := AABB()
	var first := true
	for row in _part_visuals.get(id, []):
		result = row.bounds if first else result.merge(row.bounds)
		first = false
	return result


func _choose_view(spec: Dictionary) -> Dictionary:
	if not _budget_reason().is_empty(): return _budget_view_result(_budget_reason(), true)
	if not _state_error.is_empty(): return {"ok": false, "reason": _state_error}
	_visibility_failure.clear()
	var bounds: AABB = spec.bounds
	var target := bounds.get_center()
	var radius := bounds.size.length() * 0.5
	var viewport_size := get_viewport().get_visible_rect().size
	var half_angle := minf(deg_to_rad(31.0), atan(tan(deg_to_rad(31.0)) * viewport_size.x / viewport_size.y))
	var distance := radius / sin(half_angle) * 1.12
	if spec.kind == "ordinary":
		var view := make_exterior_review_view(spec.id, "unchanged house roof and chimney exterior", target, distance * 2.0, distance, distance * 1.4, radius, 0, -INF, _ordinary_rejection.bind(spec), _ordinary_visibility_target.bind(spec))
		# The shared solver's callback returns only Vector3. If a probe stops
		# for budget, discard its provisional no-fit/invalid-target diagnosis.
		# No geometric reason or misleading rejection counters escape this row.
		if not _budget_reason().is_empty(): return _budget_view_result(_budget_reason(), true)
		var audit: Dictionary = audit_review_camera_contract(view, _camera) if bool(view.cameraPoseOk) else {"passed": false}
		return {"ok": bool(view.cameraPoseOk) and bool(audit.passed), "position": view.position, "target": target,
			"evidence": view, "audit": audit, "missingCoverage": _visibility_failure.duplicate(true), "cameraScope": "existing_collision_backed_exterior_solver_no_masks"}
	if spec.kind == "brick_face":
		_restore_visibility()
		var candidate: Dictionary = spec.get("inspectionCandidate", {})
		if not bool(candidate.get("ready", false)):
			return {"ok": false, "reason": candidate.get("reason", "missing_lower_band_candidate"), "derivedCandidate": candidate}
		_camera.global_position = candidate.position
		_camera.look_at(target, Vector3.UP)
		var framed: bool = _frame_visible(bounds)
		var visible: bool = framed and _coverage_visible(spec)
		if not _budget_reason().is_empty(): return _budget_view_result(_budget_reason(), true)
		return {"ok": visible, "reason": "" if visible else ("derived_pose_not_framed" if not framed else "derived_exposed_band_occluded"),
			"position": candidate.position, "target": target, "candidateIndex": 0, "candidateCount": 1,
			"derivedCandidate": candidate, "missingCoverage": _visibility_failure.duplicate(true),
			"cameraScope": "external_visible_brick_bearer_interface_not_buried_internal_patch_not_player_pose"}
	# Inspection-camera directions derive from the actual bearer/gable axis.
	# They are not standing/player poses and make no physical access claim.
	var row: Dictionary = _review.constructed.filter(func(item): return item.bearerId == spec.bearerId)[0]
	var along: Vector3 = (blueprint.find_part(row.gableIds[1]).position - blueprint.find_part(row.gableIds[0]).position).normalized()
	var across := along.cross(Vector3.UP).normalized()
	for elevation in [0.35, 0.75]:
		for direction in range(8):
			_restore_visibility()
			var angle := float(direction) * TAU / 8.0
			var facing: Vector3 = (across * cos(angle) + along * sin(angle) + Vector3.UP * float(elevation)).normalized()
			_camera.global_position = target + facing * distance
			_camera.look_at(target, Vector3.UP)
			var visible: bool = _frame_visible(bounds) and _coverage_visible(spec)
			if not _budget_reason().is_empty(): return _budget_view_result(_budget_reason(), true)
			if _finished: return {"ok": false, "reason": "review_stopped"}
			if visible:
				return {"ok": true, "position": _camera.global_position, "target": target,
					"candidateIndex": direction + (8 if elevation == 0.75 else 0), "cameraScope": "diagnostic_cutaway_not_standing_or_gameplay",
					"targetVisibility": "actual mesh-box rays; nonbox AABBs conservative, image inspection still required"}
			await get_tree().process_frame
	_restore_visibility()
	return {"ok": false, "reason": "no_framed_visible_cutaway_in_16_candidates", "missingCoverage": _visibility_failure.duplicate()}


func _coverage_visible(spec: Dictionary) -> bool:
	# ONE view must cover every required interface/brick. Never call a view
	# complete merely because all targets project inside the screenshot.
	var groups: Array = spec.interfaces if spec.kind == "assembly" else spec.bricks
	if spec.kind == "brick_face":
		if groups.size() != 2: return false
		# Retain ALL published nodes of both owning parts, including the
		# opposite-face bricks not selected by this child. No per-instance masks.
		for id in [spec.wallId, spec.bearerId]:
			var records: Array = _part_visuals.get(id, [])
			if records.is_empty() or not records.all(func(record): return record.node.is_visible_in_tree()): return false
	for group in groups:
		var probe_group: Dictionary = group
		if spec.kind == "brick_face" and spec.has("inspectionCandidate"):
			var candidate: Dictionary = spec.inspectionCandidate
			if not bool(candidate.get("ready", false)): return false
			var matches: Array = candidate.brickSamples.filter(func(sample): return sample.id == group.brickPrimitiveId)
			if matches.size() != 1: return false
			probe_group = group.duplicate()
			probe_group["inspectionSamples"] = {spec.wallId: matches[0].point, spec.bearerId: candidate.undersideSample}
		if not _targets_visible(probe_group, true): return false
	return true


func _ordinary_rejection(position: Vector3, spec: Dictionary) -> String:
	if not _budget_reason().is_empty(): return _budget_reason()
	_camera.global_position = position
	_camera.look_at((spec.bounds as AABB).get_center(), Vector3.UP)
	if not _frame_visible(spec.bounds): return "incomplete_house_roof_frame"
	if not _targets_visible(spec, false): return "published_chimney_occluded"
	var roof_seen: bool = false
	for id in spec.roofIds:
		if _targets_visible({"bounds": _published_bounds(id), "targets": [id]}, false):
			roof_seen = true
			break
	if not roof_seen: return "published_roof_occluded"
	return ""


func _ordinary_visibility_target(position: Vector3, spec: Dictionary) -> Vector3:
	if not _budget_reason().is_empty(): return Vector3(NAN, NAN, NAN)
	# The shared solver still frames the house centre. Both of its sightline
	# checks, and its audit, use this actual exposed surface instead.
	var result: Dictionary = _visible_target(String(spec.targets[0]), spec, position, false)
	return result.point if not result.is_empty() else Vector3(NAN, NAN, NAN)


func _frame_visible(bounds: AABB) -> bool:
	var size := get_viewport().get_visible_rect().size
	var screen := Rect2(size * 0.025, size * 0.95)
	for corner in range(8):
		var point := bounds.get_endpoint(corner)
		if _camera.is_position_behind(point) or not screen.has_point(_camera.unproject_position(point)): return false
	return true


func _targets_visible(spec: Dictionary, allow_cutaway: bool) -> bool:
	if not _state_error.is_empty(): return false
	for id in spec.targets:
		if _visible_target(String(id), spec, _camera.global_position, allow_cutaway).is_empty(): return false
	return true


func _visible_target(id: String, spec: Dictionary, camera_position: Vector3, allow_cutaway: bool) -> Dictionary:
	if not _state_error.is_empty() or not _budget_reason().is_empty(): return {}
	var window: AABB = spec.get("probeBounds", spec.bounds)
	var targets: Array = []
	if spec.has("exactPrimitive") and spec.exactPrimitive.get("partId") == id:
		if spec.exactPrimitive.node.is_visible_in_tree(): targets.append(spec.exactPrimitive)
	else:
		for visual in _part_visuals.get(id, []):
			if not visual.node.is_visible_in_tree(): continue
			for index in range(visual.count):
				var primitive: Dictionary = _primitive(visual, index)
				if primitive.is_empty(): return {}
				var bounds: AABB = primitive.transform * primitive.localBounds
				if bounds.intersects(window): targets.append(primitive)
	var center: Vector3 = window.get_center()
	targets.sort_custom(func(a, b): return (a.transform.origin as Vector3).distance_squared_to(center) < (b.transform.origin as Vector3).distance_squared_to(center))
	var failures: Array = []
	for primitive in targets.slice(0, 8):
		if not _primitive_record_valid(primitive):
			_state_error = "invalid_target_primitive_before_inverse"
			return {}
		# At most 15 actual surface probes per primitive (three facing faces,
		# each centre plus four perimeter points), under the SAME global budget.
		var points: Array = _surface_probes(primitive, window, camera_position)
		if spec.has("inspectionSamples"):
			var point: Variant = spec.inspectionSamples.get(id)
			if not point is Vector3 or not _inside_closed(window, point): return {}
			points = [point]
		for point in points:
			var world_bounds: AABB = primitive.transform * primitive.localBounds
			# Continue through the surface, avoiding a rounded endpoint miss.
			# Acceptance still requires the first hit ON the intended primitive
			# inside the local review window; no widened box or contact epsilon.
			var ray_end: Vector3 = point + (point - camera_position).normalized() * world_bounds.size.length()
			var first_blocker: Dictionary = {}
			for attempt in range(MAX_HIDDEN_PARTS + 1):
				var hit: Dictionary = _first_visual_hit(camera_position, ray_end)
				if not _state_error.is_empty() or not _budget_reason().is_empty(): return {}
				if hit.is_empty(): break
				if hit.node == primitive.node and hit.index == primitive.index and _inside_closed(window, hit.point): return hit
				if first_blocker.is_empty():
					first_blocker = {"partId": hit.partId, "primitiveIndex": hit.index, "nodeName": String(hit.node.name), "point": hit.point}
				if not allow_cutaway or not _hide_own_occluder(String(hit.partId), spec): break
			if failures.size() < 8:
				failures.append({"cameraPosition": camera_position, "sample": point, "rayEnd": ray_end,
					"primitiveIndex": primitive.index, "firstBlocker": first_blocker})
	_visibility_failure = {"partId": id, "bounds": window, "candidatePrimitiveCount": targets.size(), "failedSamples": failures,
		"primitiveIndex": int(spec.exactPrimitive.index) if spec.has("exactPrimitive") and spec.exactPrimitive.partId == id else -1}
	return {}


static func _inside_closed(bounds: AABB, point: Vector3) -> bool:
	return point.is_finite() and point.x >= bounds.position.x and point.y >= bounds.position.y and point.z >= bounds.position.z and point.x <= bounds.end.x and point.y <= bounds.end.y and point.z <= bounds.end.z


static func _surface_probes(primitive: Dictionary, window: AABB, camera_position: Vector3) -> Array:
	if not _primitive_record_valid(primitive) or not _finite_box(window) or not camera_position.is_finite(): return []
	var transform: Transform3D = primitive.transform
	var inverse: Transform3D = transform.affine_inverse()
	var box: AABB = primitive.localBounds
	var context: AABB = box.intersection(inverse * window)
	if context.size.x < 0 or context.size.y < 0 or context.size.z < 0: return []
	var camera_local: Vector3 = inverse * camera_position
	var points: Array = []
	for axis in range(3):
		var face: float = box.end[axis] if camera_local[axis] > box.end[axis] else box.position[axis]
		if camera_local[axis] >= box.position[axis] and camera_local[axis] <= box.end[axis]: continue
		if face < context.position[axis] or face > context.end[axis]: continue
		var local: Vector3 = context.get_center()
		local[axis] = face
		var samples: Array[Vector3] = [local]
		for tangent in range(3):
			if tangent == axis: continue
			for fraction in [0.125, 0.875]:
				var perimeter: Vector3 = local
				perimeter[tangent] = context.position[tangent] + context.size[tangent] * float(fraction)
				samples.append(perimeter)
		for sample in samples:
			var world: Vector3 = transform * sample
			if _inside_closed(window, world) and not points.has(world): points.append(world)
	return points


func _first_visual_hit(from: Vector3, target: Vector3) -> Dictionary:
	if not _state_error.is_empty() or not _budget_reason().is_empty(): return {}
	var best: Dictionary = {}
	var distance := INF
	var visited: int = 0
	for visual in _visuals:
		# Probe families must not defer the existing outer deadline until the
		# next yielded camera candidate, including broad-phase-only scans.
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
			var squared := from.distance_squared_to(world)
			if squared < distance:
				distance = squared
				best = primitive
				best["point"] = world
	return best


func _primitive(visual: Dictionary, index: int) -> Dictionary:
	var node = visual.node
	var mesh: Mesh = node.mesh if node is MeshInstance3D else node.multimesh.mesh
	var transform: Transform3D = node.global_transform
	if node is MultiMeshInstance3D: transform = transform * node.multimesh.get_instance_transform(index)
	var record: Dictionary = {"node": node, "index": index, "partId": visual.partId, "transform": transform, "localBounds": mesh.get_aabb()}
	if not _primitive_record_valid(record):
		_state_error = "invalid_individual_published_primitive"
		_visibility_failure = {"partId": visual.partId, "primitiveIndex": index}
		return {}
	return record


static func _primitive_record_valid(record: Dictionary) -> bool:
	if not record.get("transform") is Transform3D or not record.get("localBounds") is AABB: return false
	var transform: Transform3D = record.transform
	var local_bounds: AABB = record.localBounds
	if not transform.is_finite(): return false
	var determinant: float = transform.basis.determinant()
	if not is_finite(determinant) or determinant == 0.0: return false
	if not local_bounds.position.is_finite() or not local_bounds.end.is_finite() or local_bounds.size == Vector3.ZERO or local_bounds.size.x < 0 or local_bounds.size.y < 0 or local_bounds.size.z < 0: return false
	var world_bounds: AABB = transform * local_bounds
	if not world_bounds.position.is_finite() or not world_bounds.end.is_finite(): return false
	# No epsilon determinant cutoff. Reject a nonfinite inverse even when a
	# finite, nonzero determinant survived the guards above.
	return transform.affine_inverse().is_finite()


func _hide_own_occluder(id: String, spec: Dictionary) -> bool:
	if spec.get("targets", []).has(id): return false
	if id.is_empty() or _hidden.has(id) or _hidden.size() >= MAX_HIDDEN_PARTS or not id.begins_with(String(spec.prefix) + "_"): return false
	var part = blueprint.find_part(id)
	if part == null or part.kind not in ["wall", "roof"]: return false
	# All 33 seat participants stay visible, not only this view's target pair.
	for row in _review.constructed:
		if id == row.bearerId or id == row.chimneyId or row.gableIds.has(id): return false
	var restored: Array = []
	for visual in _part_visuals.get(id, []):
		restored.append({"node": visual.node, "visible": visual.node.visible})
		visual.node.visible = false
	if restored.is_empty(): return false
	_hidden[id] = restored
	return true


func _restore_visibility() -> void:
	for records in _hidden.values():
		for record in records:
			if is_instance_valid(record.node): record.node.visible = record.visible
	_hidden.clear()


func _live_state_digest() -> String:
	# Same retained live objects before/after visibility-only review. The external
	# collector separately proves before/candidate publication parity. No generated
	# node-name normalization, resource replacement or material waiver here.
	var state: Array = []
	var resources: Dictionary = {}
	for node in _scene_nodes:
		if not is_instance_valid(node):
			_state_error = "published_node_removed"
			return ""
		var row: Array = [node.get_instance_id(), node.transform, node.visible]
		if node is GeometryInstance3D:
			row.append_array([node.layers, node.cast_shadow, _resource_state(node.material_override, resources), _resource_state(node.material_overlay, resources)])
		if node is MeshInstance3D:
			row.append(node.mesh.get_instance_id())
			for surface in range(node.mesh.get_surface_count()):
				row.append(_resource_state(node.get_surface_override_material(surface), resources))
				row.append(_resource_state(node.mesh.surface_get_material(surface), resources))
		if node is MultiMeshInstance3D:
			row.append_array([node.multimesh.get_instance_id(), node.multimesh.buffer, node.multimesh.visible_instance_count, node.multimesh.custom_aabb])
			for surface in range(node.multimesh.mesh.get_surface_count()): row.append(_resource_state(node.multimesh.mesh.surface_get_material(surface), resources))
		if node is CollisionObject3D: row.append_array([node.collision_layer, node.collision_mask])
		if node is CollisionShape3D: row.append_array([node.disabled, _resource_state(node.shape, resources)])
		state.append(row)
	return _digest(state)


func _resource_state(resource: Resource, cache: Dictionary, depth := 0) -> Variant:
	if resource == null: return null
	if depth > 16 or cache.size() >= 32768:
		_state_error = "live_resource_snapshot_budget"
		return null
	if cache.has(resource): return cache[resource]
	var result := {"id": resource.get_instance_id(), "class": resource.get_class(), "properties": {}}
	cache[resource] = result.id # Cycle/reference marker; retained object is the key.
	for property in resource.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0 and not String(property.name).begins_with("shader_parameter/"): continue
		var value: Variant = resource.get(property.name)
		if value is Resource:
			value = _resource_state(value, cache, depth + 1) if value is Material or value is Shader or value is Shape3D else value.get_instance_id()
		result.properties[property.name] = value
	cache[resource] = _digest(result)
	return cache[resource]


func _finish(reason: String) -> void:
	if _finished: return
	_finished = true
	_restore_visibility()
	var budget_reason: String = _budget_reason()
	if not budget_reason.is_empty():
		reason = budget_reason
		# A deadline can fire during an awaited candidate/capture frame. Keep
		# that partial view and every selected-but-unstarted view explicit.
		for index in range(_capture_results.size(), _selected_specs.size()):
			var spec: Dictionary = _selected_specs[index]
			var attempted: bool = spec.id == _active_view_id
			_capture_results.append(_capture_row(spec, _budget_view_result(budget_reason, attempted), attempted,
				_active_view_ray_start if attempted else _ray_tests, _active_view_time_start if attempted else Time.get_ticks_msec()))
	_worker_mutex.lock()
	_worker_state.cancel = true
	_worker_mutex.unlock()
	var completion: Dictionary = _selected_completion(_selection, _capture_results)
	var requested_complete: bool = reason in ["captures_complete_awaiting_human_review", "shard_captures_complete_awaiting_human_review"] and bool(completion.selectedComplete)
	var final_gate: Dictionary = _completion_gate(requested_complete, FileAccess.get_sha256(_baseline_path), FileAccess.get_sha256(_evidence_path), String(_review.get("publishedEvidenceSha256", "")))
	var complete: bool = bool(final_gate.captureCoverageComplete) and _state_error.is_empty()
	if requested_complete and not complete:
		reason = "final_input_hash_mismatch" if not bool(final_gate.captureCoverageComplete) else _state_error
	var report := {"status": reason, "captureCoverageComplete": complete and bool(completion.fullComplete),
		"fullCaptureCoverageComplete": complete and bool(completion.fullComplete),
		"shardCaptureCoverageComplete": complete and bool(completion.shardComplete), "selectedCaptureCoverageComplete": complete,
		"selection": _selection, "detailInventory": _detail_inventory, "accepted": false, "externalImageCreditsApplied": false,
		"brickParentFulfillment": "uncredited_requires_external_review_of_both_children_per_parent",
		"evidenceLevel": "headed_actual_publisher_chimney_inspection_pending_human_review",
		"criticReadinessGrant": OS.get_environment("VOXEL_CHIMNEY_VISUAL_CRITIC_GRANT"),
		"preparation": _review, "views": _capture_results, "expectedOrdinaryViews": 11,
		"expectedAssemblyCutaways": 11, "expectedCoveredInterfaces": 33, "expectedBrickClusterCloseups": 2, "expectedBrickFaceChildren": 4, "expectedCoveredBrickPrimitives": 8,
		"limits": {"totalMsec": TOTAL_MSEC, "preparationMsec": PREPARATION_MSEC, "captures": EXPECTED_VIEWS,
			"cutawayCandidatesPerView": 16, "exteriorCandidatesPerView": 64, "rayTests": MAX_RAY_TESTS},
		"rayTests": _ray_tests, "elapsedMsec": Time.get_ticks_msec() - _started,
		"visibilityRestored": _hidden.is_empty(), "stateError": _state_error,
		"immutableInputUnchanged": final_gate.immutableInputUnchanged,
		"publishedEvidenceUnchanged": final_gate.publishedEvidenceUnchanged,
		"doesNotProve": "Shard completion covers selected IDs only; previous image credits remain external critic references, never automatic acceptance. Cutaways are visibility-only diagnostic cameras, not accessible attics or player poses. No contact exemption, triangle-level nonbox visibility, engineering capacity, NPC/navigation, movement, external texture pixel parity, general-seed or whole-physical-gate acceptance. Actual images and the strict separated-joint matrix require critic review."}
	var wrote := _write_json(report_path, report)
	_write_json(_progress_path, {"finished": true, "status": reason, "elapsedMsec": Time.get_ticks_msec() - _started,
		"updatedUnixSeconds": Time.get_unix_time_from_system(), "capturesAttempted": _capture_results.filter(func(row): return bool(row.get("attempted", false))).size(),
		"viewRowsCompleted": _capture_results.size(), "selection": _selection, "rayTests": _ray_tests})
	get_tree().quit(0 if wrote and complete else 2)


static func _completion_gate(requested_complete: bool, baseline_sha: String, evidence_sha: String, expected_evidence_sha: String) -> Dictionary:
	var baseline_exact: bool = baseline_sha == REVIEW_SHA
	var evidence_exact: bool = expected_evidence_sha.length() == 64 and evidence_sha == expected_evidence_sha
	return {"immutableInputUnchanged": baseline_exact, "publishedEvidenceUnchanged": evidence_exact,
		"captureCoverageComplete": requested_complete and baseline_exact and evidence_exact}


static func _publication_parity_evidence(readiness: Dictionary, expected_source: Variant, actual_source: Variant, expected_furniture: Variant, actual_furniture: Variant) -> Dictionary:
	var source: Dictionary = {"expectedDigest": _digest(expected_source), "actualDigest": _digest(actual_source)}
	var furniture: Dictionary = {"expectedDigest": _digest(expected_furniture), "actualDigest": _digest(actual_furniture)}
	source["exact"] = source.expectedDigest == source.actualDigest
	furniture["exact"] = furniture.expectedDigest == furniture.actualDigest
	if not bool(source.exact): source["leafDiff"] = _bounded_leaf_diff(expected_source, actual_source)
	if not bool(furniture.exact): furniture["leafDiff"] = _bounded_leaf_diff(expected_furniture, actual_furniture)
	return {"readiness": readiness.duplicate(true), "readinessPassed": bool(readiness.get("ready", false)),
		"source": source, "furniture": furniture,
		"passed": bool(readiness.get("ready", false)) and bool(source.exact) and bool(furniture.exact)}


static func _bounded_leaf_diff(expected: Variant, actual: Variant) -> Dictionary:
	# Diagnosis only. Digest equality above remains the unmodified acceptance
	# rule; hitting a diagnostic limit can never turn a mismatch into a pass.
	var state: Dictionary = {"rows": [], "visited": 0, "truncated": false, "stopReason": "",
		"limits": {"rows": MAX_DIFF_ROWS, "visited": MAX_DIFF_VISITS, "depth": MAX_DIFF_DEPTH}}
	_diff_walk(expected, actual, "$", 0, state)
	return state


static func _diff_walk(expected: Variant, actual: Variant, path: String, depth: int, state: Dictionary) -> void:
	if bool(state.truncated): return
	if state.rows.size() >= MAX_DIFF_ROWS or int(state.visited) >= MAX_DIFF_VISITS or depth > MAX_DIFF_DEPTH:
		state.truncated = true
		state.stopReason = "rows" if state.rows.size() >= MAX_DIFF_ROWS else ("visited" if int(state.visited) >= MAX_DIFF_VISITS else "depth")
		return
	state.visited = int(state.visited) + 1
	if typeof(expected) != typeof(actual):
		_diff_row(state, path, "type", expected, actual)
	elif expected is Dictionary:
		var old_keys: Array = expected.keys()
		var new_keys: Array = actual.keys()
		if var_to_bytes(old_keys) != var_to_bytes(new_keys): _diff_row(state, path + "/@keyOrder", "dictionary_keys_or_order", old_keys, new_keys)
		for key in old_keys:
			if bool(state.truncated): return
			var child_path: String = path + "/" + str(key).left(96)
			if actual.has(key): _diff_walk(expected[key], actual[key], child_path, depth + 1, state)
			else: _diff_row(state, child_path, "missing_actual_key", expected[key], null)
		for key in new_keys:
			if bool(state.truncated): return
			if not expected.has(key): _diff_row(state, path + "/" + str(key).left(96), "added_actual_key", null, actual[key])
	elif expected is Array:
		if expected.size() != actual.size(): _diff_row(state, path + "/@length", "array_length", expected.size(), actual.size())
		for index in range(maxi(expected.size(), actual.size())):
			if bool(state.truncated): return
			var child_path: String = path + "[%d]" % index
			if index < expected.size() and expected[index] is Dictionary and expected[index].get("id") is String:
				child_path += "{" + String(expected[index].id).left(96) + "}"
			if index >= expected.size(): _diff_row(state, child_path, "added_actual_index", null, actual[index])
			elif index >= actual.size(): _diff_row(state, child_path, "missing_actual_index", expected[index], null)
			else: _diff_walk(expected[index], actual[index], child_path, depth + 1, state)
	elif var_to_bytes(expected) != var_to_bytes(actual):
		_diff_row(state, path, "value", expected, actual)


static func _diff_row(state: Dictionary, path: String, kind: String, expected: Variant, actual: Variant) -> void:
	if state.rows.size() >= MAX_DIFF_ROWS:
		state.truncated = true
		state.stopReason = "rows"
		return
	state.rows.append({"path": path, "kind": kind, "expectedType": type_string(typeof(expected)),
		"actualType": type_string(typeof(actual)), "expected": _diff_value(expected), "actual": _diff_value(actual)})


static func _diff_value(value: Variant) -> Variant:
	if value is Array or value is Dictionary: return {"type": type_string(typeof(value)), "count": value.size()}
	if typeof(value) >= TYPE_PACKED_BYTE_ARRAY: return {"type": type_string(typeof(value)), "count": value.size()}
	if value is String: return value.left(256)
	if value is float: return {"value": _json(value), "exactVariantBytes": var_to_bytes(value).hex_encode()}
	if value == null or value is bool or value is int or value is Vector3 or value is AABB: return _json(value)
	return str(value).left(256)


static func _finite_box(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.end.is_finite() and bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.z > 0


static func _reported_transform(value: Dictionary) -> Transform3D:
	if not value.get("basis") is Array or value.basis.size() != 3 or not value.get("origin") is Array or value.origin.size() != 3: return Transform3D(Basis(), Vector3.INF)
	var vectors: Array[Vector3] = []
	for row in value.basis + [value.origin]:
		if not row is Array or row.size() != 3: return Transform3D(Basis(), Vector3.INF)
		for scalar in row:
			if not (scalar is int or scalar is float) or not is_finite(scalar): return Transform3D(Basis(), Vector3.INF)
		vectors.append(Vector3(row[0], row[1], row[2]))
	return Transform3D(Basis(vectors[0], vectors[1], vectors[2]), vectors[3])


static func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()


static func _json(value: Variant) -> Variant:
	if value is Vector3: return [_json(value.x), _json(value.y), _json(value.z)]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is float and not is_finite(value): return str(value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value


static func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(_json(value), "\t"))
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	return ok
