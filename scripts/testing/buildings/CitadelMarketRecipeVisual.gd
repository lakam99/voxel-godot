extends "res://scripts/testing/buildings/CitadelUrbanPocRunner.gd"

## Headed diagnostic ONLY, launched later through the existing process watchdog.
## Inputs: VOXEL_ROOF_INTEGRATION_BASELINE, VOXEL_CITADEL_URBAN_POC_REPORT,
## VOXEL_CITADEL_URBAN_POC_SCREENSHOT_DIR. No candidate file, coordinates or yaw.
## Source preparation is worker-owned. Scene publication/cameras stay on main.
const FrozenBlueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const TerminalFrame = preload("res://scripts/buildings/TerminalShopFrameBuilder.gd")
const TerminalElevation = preload("res://scripts/buildings/TerminalShopElevationRecipe.gd")
const TerminalGoods = preload("res://scripts/buildings/TerminalShopGoodsPlacementRecipe.gd")
const Batch = preload("res://scripts/buildings/HouseholdLayoutBatchRecipe.gd")
const CanopyFrame = preload("res://scripts/buildings/MarketCanopyFrameBuilder.gd")
const StorageRecipe = preload("res://scripts/buildings/MarketStoragePlacementRecipe.gd")
const WalkPlan = preload("res://scripts/testing/buildings/CitadelMarketWalkPlan.gd")
const LocalWalk = preload("res://scripts/testing/buildings/CitadelMarketLocalWalkWitness.gd")
const ShopRecipe = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const FROZEN_SHA := "7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5"
var _preparation_thread: Thread
var _prepared_blueprint
var _preparation: Dictionary = {}
var _member_ids: Array = []
var _setup_path := ""
var _local_walk
var _walk_result: Dictionary = {}
var _terminal_review_sampling := false
var _market_view_results: Dictionary = {}
var _terminal_view_results: Dictionary = {}


func _ready() -> void:
	read_arguments()
	_setup_path = report_path.get_base_dir().path_join("market-recipe-setup.json")
	var baseline := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE").strip_edges().simplify_path()
	if not report_path.is_absolute_path() or report_path.get_extension().to_lower() != "json" or FileAccess.file_exists(report_path) or FileAccess.file_exists(_setup_path) or not screenshot_dir.is_absolute_path() or not baseline.is_absolute_path():
		push_error("Market recipe diagnostic requires absolute frozen input and fresh report/setup/capture paths")
		get_tree().quit(2)
		return
	if DirAccess.dir_exists_absolute(screenshot_dir) and not DirAccess.get_files_at(screenshot_dir).is_empty():
		push_error("Refusing to replace existing market captures")
		get_tree().quit(2)
		return
	build_world()
	build_hud()
	is_rebuilding = true
	set_loading("Preparing frozen source and shared household recipe")
	await get_tree().process_frame
	_preparation_thread = Thread.new()
	var start_error := _preparation_thread.start(_prepare_frozen_recipe.bind(baseline, true))
	if start_error != OK:
		_preparation_thread = null
		_fail_preparation({"ready": false, "reason": "preparation_thread_start_failed", "error": start_error})
		return
	while _preparation_thread.is_alive():
		await get_tree().process_frame
	var prepared = _preparation_thread.wait_to_finish()
	_preparation_thread = null
	if not prepared is Dictionary or not bool(prepared.get("ready", false)):
		_fail_preparation(prepared if prepared is Dictionary else {"ready": false, "reason": "invalid_worker_result"})
		return
	if not bool(prepared.get("localWalkPlan", {}).get("ready", false)):
		_fail_preparation({"ready": false, "reason": "local_walk_itinerary_not_ready", "plan": prepared.get("localWalkPlan", {})})
		return
	if prepared.localWalkPlan.get("observationObstacles", []).is_empty():
		_fail_preparation({"ready": false, "reason": "missing_observed_clearance_snapshot"})
		return
	_prepared_blueprint = prepared.blueprint
	_prepared_furnishing_plan = prepared.furnishingPlan
	_prepared_interior_program = prepared.interiorProgram.duplicate(true)
	_preparation = prepared.duplicate()
	_preparation.erase("blueprint")
	_preparation.erase("furnishingPlan")
	_preparation.erase("interiorProgram")
	_preparation["planningOffMainThread"] = true
	_member_ids = prepared.memberIds
	selected_seed = int(prepared.fixture.seed)
	selected_citadel_scale = float(prepared.fixture.citadelScale)
	selected_style = String(_prepared_blueprint.style)
	if not _write_setup(_preparation):
		push_error("Cannot write market recipe setup evidence")
		get_tree().quit(2)
		return
	is_rebuilding = false
	await rebuild_fixture(false)
	if blueprint == null:
		return
	spawn_player()
	update_hud()
	call_deferred("write_automated_report")


func _exit_tree() -> void:
	if _local_walk != null:
		_local_walk.cleanup()
	# Keep ownership explicit on early window close. The pure bounded worker
	# cannot be detached while its blueprint is in flight; watchdog remains the
	# outer process limit. Normal completion joins before any publication.
	if _preparation_thread != null and _preparation_thread.is_started():
		_preparation_thread.wait_to_finish()
		_preparation_thread = null


func _unhandled_key_input(_event: InputEvent) -> void:
	# No next-seed/rebuild hotkey for an immutable single frozen-source capture.
	pass


func place_player_at_entry() -> void:
	# Single documented fixture setup, before the act. No retry placements.
	if player != null and bool(_preparation.get("localWalkPlan", {}).get("ready", false)):
		player.position = _preparation.localWalkPlan.start + Vector3(0, 0.04, 0)


func write_automated_report() -> void:
	var readiness := await wait_for_capture_readiness()
	if not bool(readiness.get("ready", false)):
		_fail_preparation({"ready": false, "reason": "publication_not_ready_for_walk", "readiness": readiness})
		return
	# Allow only the normal controller/gravity to settle the pre-act placement.
	for frame in range(30):
		await get_tree().physics_frame
		if frame >= 3 and player.is_on_floor(): break
	if not player.is_on_floor():
		_fail_preparation({"ready": false, "reason": "pre_act_start_not_grounded"})
		return
	_local_walk = LocalWalk.new()
	_walk_result = await _local_walk.run(self, player, _preparation.localWalkPlan.waypoints, screenshot_dir.path_join("local-walk"), _preparation.localWalkPlan.observationObstacles)
	if not bool(_walk_result.get("passed", false)):
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(_serializable({"status": "failed", "scope": "common market courtyard to three market and three terminal fronts", "localWalk": _walk_result}), "\t"))
			file.close()
		get_tree().quit(1)
		return
	# Parent cameras/direct service door setup happen AFTER this act. They are
	# visual diagnostics and never count as player interaction acceptance.
	await super.write_automated_report()


func build_castle_blueprint():
	# Do not call super: it would regenerate and compose a different source.
	if _prepared_blueprint == null:
		return null
	var result = _prepared_blueprint
	_prepared_blueprint = null
	install_generated_city_trees(result)
	install_city_lights(result)
	return result


func prepare_castle_blueprint():
	# This diagnostic already prepared through the shared recipe on its owned
	# frozen-source worker. Never invoke normal generation a second time.
	return build_castle_blueprint()


static func _prepare_frozen_recipe(path: String, include_canopy_frames := false) -> Dictionary:
	var started := Time.get_ticks_usec()
	if FileAccess.get_sha256(path) != FROZEN_SHA:
		return {"ready": false, "reason": "frozen_sha_mismatch"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ready": false, "reason": "frozen_open_failed"}
	var envelope = file.get_var(false)
	var read_ok := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not read_ok or not envelope is Dictionary or not envelope.get("output") is Dictionary:
		return {"ready": false, "reason": "invalid_frozen_envelope"}
	var frozen: Dictionary = envelope.output
	var source: Dictionary = frozen.get("sourceSnapshot", {})
	if source.is_empty():
		return {"ready": false, "reason": "missing_frozen_source"}
	var b = FrozenBlueprint.new(source.id, source.seed, source.style)
	b.recipe = source.recipe.duplicate(true)
	b.rooms = source.rooms.duplicate(true)
	for record in source.parts:
		var part = b.add_part(record)
		if b.physical_parts_by_id.has(part.id):
			return {"ready": false, "reason": "duplicate_source_part"}
		b.physical_parts_by_id[part.id] = part
	var prepared := ShopRecipe.prepare(b, _frozen_furnishing_obstacles(frozen),
		CitadelUrbanPocComposerScript.add_market_stall_household, CitadelUrbanPocComposerScript.add_terminal_shop_row,
		CitadelUrbanPocComposerScript.plan_courtyard_household, CitadelUrbanPocComposerScript.plan_terminal_shop_household,
		include_canopy_frames)
	if not prepared.get("ready", false): return prepared
	var furnishings := CitadelUrbanPocComposerScript.prepare_furnishings(prepared.blueprint, int(frozen.fixture.seed))
	if not furnishings.ready: return furnishings
	prepared["furnishingPlan"] = furnishings.furnishingPlan
	prepared["interiorProgram"] = furnishings.interiorProgram
	if FileAccess.get_sha256(path) != FROZEN_SHA:
		return {"ready": false, "reason": "frozen_input_changed"}
	prepared["fixture"] = frozen.fixture
	prepared["localWalkPlan"] = WalkPlan.extend_to_terminal_fronts(prepared.blueprint, WalkPlan.prepare(prepared.blueprint, prepared.plans), prepared.terminals, _frozen_furnishing_obstacles(frozen)) if include_canopy_frames else {}
	prepared["baselinePath"] = path
	prepared["baselineSha256"] = FROZEN_SHA
	var physical: Dictionary = frozen.get("physicalValidation", {})
	prepared["baselinePhysical"] = {"passed": physical.get("passed", false), "violations": physical.get("violations", [])}
	prepared["preparationUsec"] = Time.get_ticks_usec() - started
	prepared["doesNotProve"] = "No gameplay/NPC access or structural acceptance. Shared recipe preparation on frozen diagnostic input only. Physical failures remain red."
	return prepared


static func _frozen_furnishing_obstacles(frozen: Dictionary) -> Array:
	var obstacles: Array = []
	for record in frozen.furnitureSnapshot.parts:
		var transform := Transform3D(Basis.from_euler(record.rotation), record.position)
		# FurnishingPart origin is the floor centre, unlike BuildingPart's
		# volume-centre convention (same local box as FurnishingPublisher).
		var size: Vector3 = record.occupiedSize
		var bounds: AABB = transform * AABB(Vector3(-size.x * 0.5, 0, -size.z * 0.5), size)
		obstacles.append({"id": "furnishing:" + String(record.id), "bounds": bounds})
	for index in range(frozen.protectedReservations.size()):
		obstacles.append({"id": "furnishing_access:%d" % index, "bounds": frozen.protectedReservations[index]})
	return obstacles


static func _prepare_terminal_frames(source_b, variation: float, furnishing_obstacles: Array = [], placed_households: Array = []) -> Dictionary:
	return ShopRecipe.prepare_terminal_frames(source_b, variation, furnishing_obstacles, placed_households,
		CitadelUrbanPocComposerScript.add_terminal_shop_row, CitadelUrbanPocComposerScript.plan_terminal_shop_household)


func capture_views() -> Array[Dictionary]:
	var views: Array[Dictionary] = []
	for group_index in range(_preparation.plans.size()):
		var placement: Dictionary = _preparation.plans[group_index]
		var bounds := _parts_bounds(placement.memberIds)
		var approach: Rect2 = placement.approach
		var frame_bounds := bounds.merge(AABB(Vector3(approach.position.x, float(placement.standingY), approach.position.y), Vector3(approach.size.x, 0.1, approach.size.y)))
		var target := frame_bounds.get_center()
		var radius := frame_bounds.size.length() * 0.5
		var minimum_distance := radius / sin(deg_to_rad(62.0 * 0.5)) * 1.05
		var preferred_distance := minimum_distance * 1.12
		var front: Vector3 = placement.frontAfter
		var right := Vector3(-front.z, 0.0, front.x)
		for side in [1.0, -1.0]:
			var direction: Vector3 = (front * side + right * 0.65).normalized()
			var direction_index := posmod(roundi(atan2(direction.x, -direction.z) / TAU * 16.0), 16)
			var id := "market_household_%02d_%s" % [group_index, "front" if side > 0.0 else "rear"]
			var view := make_exterior_review_view(id, "complete household and supported approach", target,
				preferred_distance * 1.2, minimum_distance, preferred_distance, radius, direction_index, float(placement.standingY) - 0.18)
			view["householdFrameBounds"] = frame_bounds
			view["householdIndex"] = group_index
			view["householdBounds"] = bounds
			view["memberIds"] = placement.memberIds
			view["front"] = front
			view["requiredSide"] = side
			view["approach"] = approach
			view["standingY"] = placement.standingY
			views.append(view)
	_terminal_review_sampling = true
	for setup in _preparation.terminals.setups:
		var bay_ids: Array = _preparation.terminals.allIds.filter(func(id): return String(id).begins_with(String(setup.prefix) + "_"))
		var terminal_bounds := _parts_bounds(bay_ids)
		var terminal_radius := terminal_bounds.size.length() * 0.5
		var terminal_distance := terminal_radius / sin(deg_to_rad(31.0)) * 1.18
		var terminal_front: Vector3 = blueprint.part_transform(blueprint.find_part(String(setup.prefix) + "_lintel")).basis * Vector3.FORWARD
		var terminal_direction := posmod(roundi(atan2(terminal_front.x, -terminal_front.z) / TAU * 16.0), 16)
		# Pick a camera that meets the same complete-bay requirements audited
		# afterward. No geometry moves and no wider candidate search is added.
		var probe := _make_terminal_review_probe()
		var terminal_view := make_exterior_review_view(String(setup.prefix) + "_complete_review", "complete shared-recipe terminal bay",
			terminal_bounds.get_center(), terminal_distance * 1.2, terminal_distance / 1.12, terminal_distance,
			terminal_radius, terminal_direction, -INF,
			_terminal_camera_rejection.bind(probe, terminal_bounds, terminal_front, bay_ids))
		probe.free()
		terminal_view["householdFrameBounds"] = terminal_bounds
		terminal_view["terminalReview"] = true
		terminal_view["terminalSetup"] = setup
		terminal_view["terminalMemberIds"] = bay_ids
		terminal_view["terminalFront"] = terminal_front
		views.append(terminal_view)
	_terminal_review_sampling = false
	return views


func exterior_support_for_review(horizontal: Vector3, target_y: float, minimum_support_y: float) -> Dictionary:
	if not _terminal_review_sampling:
		return super.exterior_support_for_review(horizontal, target_y, minimum_support_y)
	# Terminal foot height is not an observer-standing requirement. Require an
	# actual ray-hit public paving collider instead; roofs/fallback ground fail.
	if get_world_3d() == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(Vector3(horizontal.x, target_y + 7.0, horizontal.z), Vector3(horizontal.x, target_y - 4.0, horizontal.z))
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or (hit.normal as Vector3).y < 0.72 or (hit.position as Vector3).y > target_y + 0.08:
		return {}
	var body = hit.collider
	var id := ""
	if body is CollisionObject3D and hit.has("shape"):
		var owner = body.shape_owner_get_owner(body.shape_find_owner(int(hit.shape)))
		if owner is Node: id = String(owner.get_meta("building_part_id", ""))
	if id.is_empty() and body is Node: id = String(body.get_meta("building_part_id", ""))
	var part = blueprint.find_part(id)
	if part == null or not part.collision_enabled or not CitadelUrbanPocComposerScript.is_primary_tree_paving(part):
		return {}
	return {"position": (hit.position as Vector3) + Vector3(0, 0.055, 0), "collider": body, "partId": id}


func _household_bounds() -> AABB:
	return _parts_bounds(_member_ids)


func _parts_bounds(ids: Array) -> AABB:
	var bounds := AABB()
	var first := true
	for id in ids:
		var part = blueprint.find_part(id)
		var part_bounds := review_part_bounds(part)
		bounds = part_bounds if first else bounds.merge(part_bounds)
		first = false
	return bounds


func audit_review_camera_contract(view: Dictionary, camera: Camera3D) -> Dictionary:
	var result := super.audit_review_camera_contract(view, camera)
	var bounds: AABB = view.householdFrameBounds
	var frame_ok := _complete_frame_visible(camera, bounds)
	if bool(view.get("terminalReview", false)):
		var terminal_front: Vector3 = view.terminalFront
		var terminal_front_ok := (camera.global_position - bounds.get_center()).dot(terminal_front) > 0.0
		var visibility := _terminal_family_visibility(camera.global_position, view.terminalMemberIds)
		var family_coverage: bool = visibility.complete
		result["completeTerminalBayFramed"] = frame_ok
		result["terminalFrontSide"] = terminal_front_ok
		result["eligibleMemberFamilies"] = visibility.eligible
		result["visibleMemberFamilies"] = visibility.visible
		result["allRequiredFamiliesVisible"] = family_coverage
		result["passed"] = bool(result.passed) and frame_ok and terminal_front_ok and family_coverage
		_terminal_view_results[String(view.terminalSetup.prefix)] = result.duplicate(true)
		result["visibilityScope"] = "Framing and source/physics sightlines only; inspect actual cloth, brackets and sign joints in the image. Not structural or gameplay acceptance."
		return result
	return _audit_market_camera(view, camera, result, bounds, frame_ok)


func _make_terminal_review_probe() -> Camera3D:
	var probe := Camera3D.new()
	probe.fov = 62.0
	probe.near = 0.05
	add_child(probe)
	probe.current = false
	return probe


func _complete_frame_visible(camera: Camera3D, bounds: AABB) -> bool:
	var frame_ok := true
	var viewport_size := get_viewport().get_visible_rect().size
	var margin := viewport_size * 0.025
	var screen_rect := Rect2(margin, viewport_size - margin * 2.0)
	for x in [0.0, 1.0]:
		for y in [0.0, 1.0]:
			for z in [0.0, 1.0]:
				var point := bounds.position + bounds.size * Vector3(x, y, z)
				frame_ok = frame_ok and not camera.is_position_behind(point) and screen_rect.has_point(camera.unproject_position(point))
	return frame_ok


func _terminal_family_visibility(position: Vector3, member_ids: Array) -> Dictionary:
	var families := {"cloth": [], "counter": [], "goods": [], "shelf": [], "tools": [], "sign": [], "posts": [], "rails": [], "brackets": [], "signStandoff": []}
	var eligible: Dictionary = families.duplicate(true)
	for id in member_ids:
		var part = blueprint.find_part(id)
		if part == null:
			return {"complete": false, "visible": families, "eligible": eligible, "missingMember": id}
		var family := _terminal_member_family(part)
		if family.is_empty(): continue
		eligible[family].append(id)
		if review_line_is_clear(position, part.position) and review_visual_line_is_clear(position, part.position):
			families[family].append(id)
	return {"complete": families.values().all(func(ids): return not ids.is_empty()), "visible": families, "eligible": eligible}


func _terminal_camera_rejection(position: Vector3, camera: Camera3D, bounds: AABB, front: Vector3, member_ids: Array) -> String:
	if (position - bounds.get_center()).dot(front) <= 0.0: return "behind_terminal"
	camera.global_position = position
	camera.look_at(bounds.get_center(), Vector3.UP)
	if not _complete_frame_visible(camera, bounds): return "incomplete_terminal_frame"
	if not _terminal_family_visibility(position, member_ids).complete: return "hidden_terminal_family"
	return ""


func _audit_market_camera(view: Dictionary, camera: Camera3D, result: Dictionary, bounds: AABB, frame_ok: bool) -> Dictionary:
	var visible := {"citadel_market_goods": [], "citadel_market_seating": [], "citadel_market_storage": []}
	var eligible := {"citadel_market_goods": [], "citadel_market_seating": [], "citadel_market_storage": []}
	for id in view.memberIds:
		var part = blueprint.find_part(id)
		if not visible.has(part.semantic):
			continue
		eligible[part.semantic].append(id)
		if review_line_is_clear(camera.global_position, part.position) and review_visual_line_is_clear(camera.global_position, part.position):
			visible[part.semantic].append(id)
	var group_bounds: AABB = view.householdBounds
	var front: Vector3 = view.front
	var side_ok := (camera.global_position - group_bounds.get_center()).dot(front) * float(view.requiredSide) > 0.0
	var seating_ok: bool = eligible.citadel_market_seating.is_empty() or not visible.citadel_market_seating.is_empty()
	var details_ok: bool = not visible.citadel_market_goods.is_empty() and seating_ok if float(view.requiredSide) > 0.0 else not visible.citadel_market_storage.is_empty()
	var approach: Rect2 = view.approach
	var approach_target := Vector3(approach.get_center().x, float(view.standingY) + 0.08, approach.get_center().y)
	var approach_visible := review_line_is_clear(camera.global_position, approach_target) and review_visual_line_is_clear(camera.global_position, approach_target)
	result["completeHouseholdAndApproachFramed"] = frame_ok
	result["requiredFrontOrRearSide"] = side_ok
	result["visibleDetailPartIds"] = visible
	result["eligibleDetailPartIds"] = eligible
	result["requiredDetailsVisible"] = details_ok
	result["approachCenterVisible"] = approach_visible
	result["visibilityScope"] = "Camera framing and source/physics sightline checks only; not pedestrian traversal or complete published-mesh occlusion proof. Inspect both images."
	# Complementary pair contract: front proves goods/seating AND approach;
	# rear proves storage and rear framing. Both images remain mandatory.
	var is_front := float(view.requiredSide) > 0.0
	result["approachVisibilityRequiredInThisView"] = is_front
	result["passed"] = bool(result.passed) and frame_ok and side_ok and details_ok and (approach_visible or not is_front)
	var group_index := int(view.householdIndex)
	if not _market_view_results.has(group_index): _market_view_results[group_index] = {}
	_market_view_results[group_index]["front" if is_front else "rear"] = bool(result.passed)
	if is_front: _market_view_results[group_index]["approachVisible"] = approach_visible
	return result


func _terminal_member_family(part) -> String:
	match String(part.semantic):
		"citadel_terminal_shop_awning": return "cloth"
		"citadel_terminal_shop_joinery": return "brackets"
		"terminal_awning_frame": return "rails"
		"terminal_sign_mount": return "signStandoff"
		"citadel_terminal_shop_sign": return "sign" if part.kind == "sign" else ""
		"citadel_terminal_shop_goods": return "goods"
		"citadel_terminal_shop_tools": return "tools"
		"citadel_terminal_shop_frame": return "posts" if String(part.id).contains("_jamb_") else ""
		"citadel_terminal_shop":
			if String(part.id).ends_with("_counter"): return "counter"
			if String(part.id).ends_with("_wall_shelf"): return "shelf"
			return ""
	return ""


func audit_structural_supports() -> Dictionary:
	var result := super.audit_structural_supports()
	var current: Dictionary = building_publisher.physical_integrity if building_publisher != null else {}
	result["marketRecipePrototype"] = _serializable(_preparation)
	result["localMarketWalk"] = _serializable(_walk_result)
	var paired_views: Array = []
	for group_index in range(_preparation.plans.size()):
		var checks: Dictionary = _market_view_results.get(group_index, {})
		paired_views.append({"householdIndex": group_index, "checks": checks,
			"passed": bool(checks.get("front", false)) and bool(checks.get("rear", false)) and bool(checks.get("approachVisible", false))})
	result["complementaryMarketViewPairs"] = paired_views
	var terminal_bays: Array = []
	for setup in _preparation.terminals.setups:
		terminal_bays.append({"prefix": setup.prefix, "review": _terminal_view_results.get(String(setup.prefix), {}),
			"passed": bool(_terminal_view_results.get(String(setup.prefix), {}).get("passed", false))})
	result["terminalBayCoverage"] = terminal_bays
	result["currentPhysicalIntegrity"] = current
	result["baselinePhysicalGateStillRed"] = not bool(_preparation.get("baselinePhysical", {}).get("passed", false))
	result["passed"] = bool(result.passed) and bool(current.get("passed", false)) and not bool(result.baselinePhysicalGateStillRed) and paired_views.size() == _preparation.plans.size() and paired_views.all(func(pair): return pair.passed) and terminal_bays.size() == _preparation.terminals.setups.size() and terminal_bays.all(func(bay): return bay.passed)
	return result


func _fail_preparation(reason: Dictionary) -> void:
	is_rebuilding = false
	set_loading("Market recipe preparation failed; see setup report")
	_write_setup(reason)
	push_error("Market recipe preparation failed: " + String(reason.get("reason", "unknown")))
	get_tree().quit(2)


func _write_setup(value: Dictionary) -> bool:
	var file := FileAccess.open(_setup_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(_serializable(value), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	return error == OK


static func _serializable(value: Variant) -> Variant:
	if value is Transform3D:
		return {"origin": _serializable(value.origin), "basis": [_serializable(value.basis.x), _serializable(value.basis.y), _serializable(value.basis.z)]}
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return [value.x, value.y]
	if value is Rect2 or value is AABB:
		return {"position": _serializable(value.position), "size": _serializable(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _serializable(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _serializable(item))
	return value
