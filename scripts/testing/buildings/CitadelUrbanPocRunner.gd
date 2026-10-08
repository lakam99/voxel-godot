extends "res://scripts/testing/buildings/CastleWalkthroughRunner.gd"

const CitadelUrbanPocComposerScript := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const CitadelRecipePreparationScript := preload("res://scripts/buildings/CitadelRecipePreparation.gd")
const BuildingInteriorProgramScript := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const CertifiedTreeRequestFixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")
const MIN_REVIEW_SUBJECT_FRAME_FRACTION := 0.18
const MAX_REVIEW_SUBJECT_FRAME_FRACTION := 0.82
const MAX_NEAR_FIELD_BLOCKED_SAMPLES := 4
const MAX_PERIMETER_REVIEW_SOURCES := 8
const MAX_REVIEW_CAMERA_CANDIDATES := 64
const PERIMETER_REVIEW_CANDIDATES_PER_FRAME := 4
const REVIEW_CAMERA_PHASES := ["support", "capsule", "visualVolume", "visibilityTarget", "physicsSightline", "visualSightline", "frameChecks", "nearFieldComposition", "subjectReadability"]
const REVIEW_CAMERA_VISIT_KEYS := ["parts", "segments", "samples", "queries"]
const MAX_REVIEW_STAGE_REJECTION_EVIDENCE := 4
const MAX_PERIMETER_COMPOSITION_SUBJECTS := 512
const REVIEW_VISUAL_INDEX_CELL_SIZE := 8.0
const MAX_REVIEW_VISUAL_SOURCE_PARTS := 10000
const MAX_REVIEW_VISUAL_CELLS_PER_RECORD := 4096
const MAX_REVIEW_VISUAL_INDEX_ENTRIES := 1000000

var screenshot_dir := ""
var generated_tree_count := 0
var ecology_backed_tree_count := 0
var generated_tree_positions: Array[Vector3] = []
var reused_groundcover_count := 0
var recipe_lantern_light_count := 0
var tree_contact_diagnostics: Dictionary = {}
var _generation_thread: Thread
var _prepared_furnishing_plan
var _prepared_interior_program: Dictionary = {}
var camera_physics_replay := false
var camera_stage_progress: Dictionary = {}
var camera_source_derivation_usec := 0
var _active_camera_telemetry_job: Variant
var _active_camera_telemetry_phase := ""
var _review_visual_snapshot: Dictionary = {}
var _review_visual_snapshot_epoch := 0


func read_arguments() -> void:
	selected_citadel_scale = 1.25
	super.read_arguments()
	report_path = OS.get_environment("VOXEL_CITADEL_URBAN_POC_REPORT")
	screenshot_dir = OS.get_environment("VOXEL_CITADEL_URBAN_POC_SCREENSHOT_DIR")
	camera_physics_replay = OS.get_environment("VOXEL_CITADEL_CAMERA_PHYSICS_REPLAY") == "1"


func build_world() -> void:
	super.build_world()
	for child in get_children():
		if child is WorldEnvironment:
			var environment := (child as WorldEnvironment).environment
			environment.background_color = Color(0.265, 0.295, 0.305)
			environment.ambient_light_color = Color(0.60, 0.62, 0.58)
			environment.ambient_light_energy = 1.18
			environment.ssao_enabled = true
			environment.ssao_radius = 2.1
			environment.ssao_intensity = 1.02
			environment.ssao_power = 1.04
			environment.fog_enabled = true
			environment.fog_light_color = Color(0.52, 0.54, 0.51)
			environment.fog_light_energy = 0.42
			environment.fog_density = 0.0014
			environment.fog_sky_affect = 0.56
			break
	var review_fill := DirectionalLight3D.new()
	review_fill.name = "CitadelUrbanReviewFill"
	review_fill.rotation_degrees = Vector3(-34.0, 138.0, 0.0)
	review_fill.light_color = Color(0.70, 0.75, 0.72)
	review_fill.light_energy = 0.48
	review_fill.shadow_enabled = false
	add_child(review_fill)


static func _generate_citadel(seed: int, scale: float):
	return CitadelRecipePreparationScript.prepare(seed, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": scale})


func prepare_castle_blueprint():
	if _generation_thread != null:
		push_error("Citadel generation already has an owner")
		return null
	_generation_thread = Thread.new()
	var error := _generation_thread.start(_generate_citadel.bind(selected_seed, selected_citadel_scale))
	if error != OK:
		_generation_thread = null
		push_error("Unable to start citadel generation worker")
		return null
	while _generation_thread.is_alive():
		await get_tree().process_frame
	var prepared = _generation_thread.wait_to_finish()
	_generation_thread = null
	if not prepared is Dictionary or not prepared.get("ready", false):
		return null
	_prepared_furnishing_plan = prepared.furnishingPlan
	_prepared_interior_program = prepared.interiorProgram.duplicate(true)
	var result = prepared.blueprint
	install_generated_city_trees(result)
	install_city_lights(result)
	return result


func prepare_castle_furnishings():
	if _prepared_furnishing_plan == null: return null
	var result = _prepared_furnishing_plan
	_prepared_furnishing_plan = null
	# Preserve the old annotation timing: after structure publication, before
	# furniture publication. Consume prepared data, never rebuild the plan.
	blueprint.recipe["interiorProgram"] = _prepared_interior_program.duplicate(true)
	_prepared_interior_program.clear()
	return result


func _exit_tree() -> void:
	if _generation_thread != null and _generation_thread.is_started():
		_generation_thread.wait_to_finish()
		_generation_thread = null


func install_generated_city_trees(result) -> void:
	# The PoC composer owns this fixture's open-space plan. Plant at the broad
	# market lane edges, outside its central travel corridor and market stalls.
	var placements: Array = (result.recipe.get("urbanPoc", {}) as Dictionary).get("treePlacements", []) as Array
	var tree_service = TreeSpawnServiceScript.new()
	var request_builder = TreeRuntimeRequestBuilderScript.new()
	var environment_catalog = BiomeEnvironmentCatalogScript.new()
	if not environment_catalog.setup():
		return
	var town_profile = environment_catalog.profile_for_biome("town")
	for index in range(placements.size()):
		if not placements[index] is Dictionary:
			continue
		var placement: Dictionary = placements[index] as Dictionary
		var tree_position: Vector3 = placement.get("position", Vector3.ZERO) as Vector3
		var tree_id := String(placement.get("id", "citadel-urban-tree-%d" % index))
		var request: Dictionary = placement.get("treeRequest", {}) as Dictionary
		if request.is_empty():
			request = request_builder.build(town_profile, "town", tree_id, 6.2 + float(index % 3) * 0.9, Vector2i(roundi(tree_position.x), roundi(tree_position.z)), str(selected_seed))
			request["treeId"] = tree_id
			request["worldSeed"] = str(selected_seed)
			request["biome"] = "town"
			request["presentation"] = "runtime"
			request["worldPosition"] = tree_position
			request["worldRotationY"] = float(placement.get("rotationY", 0.0))
		request = CertifiedTreeRequestFixture.prepare_or_fail(request)
		if request.is_empty():
			continue
		var tree_recipe: Dictionary = tree_service.build_recipe(request)
		if tree_recipe.is_empty():
			continue
		var tree: Node3D = tree_service.instantiate_recipe(tree_recipe, "town", tree_id)
		if tree == null:
			continue
		tree.name = "CitadelGeneratedTree%02d" % index
		tree.position = tree_position
		tree.rotation.y = float(placement.get("rotationY", 0.0))
		tree.set_meta("citadel_urban_generated_tree", true)
		add_child(tree)
		generated_tree_count += 1
		ecology_backed_tree_count += 1
		generated_tree_positions.append(tree.position)


func install_city_lights(result) -> void:
	for part in result.parts:
		if part == null or String(part.semantic) != "citadel_urban_lantern_flame":
			continue
		var light := OmniLight3D.new()
		light.name = "CitadelRecipeLantern%02d" % recipe_lantern_light_count
		light.position = part.position
		light.light_color = Color(1.0, 0.62, 0.34)
		light.light_energy = 1.95
		light.omni_range = 7.2
		light.shadow_enabled = recipe_lantern_light_count % 4 == 0
		add_child(light)
		recipe_lantern_light_count += 1


func write_automated_report() -> void:
	var readiness := await wait_for_capture_readiness()
	for canvas in get_children():
		if canvas is CanvasLayer:
			(canvas as CanvasLayer).visible = false
	if bool(readiness.get("ready", false)) and front_door != null and door_service != null and player != null:
		door_service.request_door_state(front_door, true, player, "player", {"actors": [player]})
		for _frame in range(12):
			door_service.process(0.1, [player])
			await get_tree().process_frame
	if not camera_physics_replay:
		DirAccess.make_dir_recursive_absolute(screenshot_dir)
	var views: Array = await capture_views() if bool(readiness.get("ready", false)) else []
	var captures: Array[String] = []
	var capture_results: Array[Dictionary] = []
	var review_contracts: Array[Dictionary] = []
	var review_camera := Camera3D.new()
	review_camera.name = "CitadelUrbanAutomatedReviewCamera"
	review_camera.fov = 62.0
	review_camera.near = 0.05
	add_child(review_camera)
	review_camera.current = true
	for view_value in views:
		var view: Dictionary = view_value as Dictionary
		if view.has("cameraPoseOk") and not bool(view.get("cameraPoseOk", false)):
			var rejected_contract := audit_review_camera_contract(view, review_camera)
			review_contracts.append(rejected_contract)
			capture_results.append({"id": view.get("id", "capture"), "path": "", "saved": false, "reviewContract": rejected_contract})
			continue
		var view_position := view.get("position", Vector3.ZERO) as Vector3
		var view_target := view.get("target", Vector3.ZERO) as Vector3
		review_camera.global_position = view_position
		review_camera.look_at(view_target, Vector3.UP)
		var review_contract := audit_review_camera_contract(view, review_camera)
		review_contracts.append(review_contract)
		if camera_physics_replay:
			capture_results.append({"id": view.get("id", "capture"), "path": "", "saved": false, "reviewContract": review_contract, "headlessReplay": true})
			continue
		for _frame in range(8):
			await get_tree().process_frame
		RenderingServer.force_draw(false)
		var path := screenshot_dir.path_join("%s.png" % String(view.get("id", "capture")))
		var viewport_texture := get_viewport().get_texture()
		var viewport_image := viewport_texture.get_image() if viewport_texture != null else null
		var save_error := viewport_image.save_png(path) if viewport_image != null else ERR_UNAVAILABLE
		capture_results.append({"id": view.get("id", "capture"), "path": path, "saved": save_error == OK, "reviewContract": review_contract})
		if save_error == OK:
			captures.append(path)
	if player.camera != null:
		player.camera.current = true
	review_camera.queue_free()
	var window_interior_program := BuildingInteriorProgramScript.audit_plan(blueprint, furnishing_plan)
	var structural_support := audit_structural_supports()
	var camera_gate_passed := not views.is_empty() and review_contracts.size() == views.size() and review_contracts.all(func(contract): return bool((contract as Dictionary).get("passed", false)))
	var evidence_complete := camera_gate_passed if camera_physics_replay else captures.size() == views.size() and not captures.is_empty() and camera_gate_passed
	var report := {
		"runnerId": "citadel_urban_poc",
		"evidenceLevel": "unheaded_real_publication_physics_camera_replay" if camera_physics_replay else "headed_empty_environment_walkthrough",
		"status": "passed" if bool(readiness.get("ready", false)) and evidence_complete and bool(window_interior_program.get("passed", false)) and bool(structural_support.get("passed", false)) else "failed",
		"seed": selected_seed,
		"citadelScale": selected_citadel_scale,
		"peoplePresent": false,
		"generatedTreeCount": generated_tree_count,
		"ecologyBackedTreeCount": ecology_backed_tree_count,
		"reusedGroundcoverCount": reused_groundcover_count,
		"recipeLanternLightCount": recipe_lantern_light_count,
		"captureReadiness": readiness,
		"buildingPublication": building_publisher.summary() if building_publisher != null else {},
		"furnishingPublication": furnishing_publisher.summary() if furnishing_publisher != null else {},
		"windowInteriorProgram": window_interior_program,
		"urbanLayout": blueprint.recipe.get("urbanPoc", {}).duplicate(true) if blueprint != null else {},
		"architecturalDiagnostics": inspect_architectural_recipe_parts(),
		"structuralSupport": structural_support,
		"marketDiagnostics": inspect_market_recipe_parts(),
		"treeContactDiagnostics": tree_contact_diagnostics,
		"capturePaths": captures,
		"captureResults": capture_results,
		"reviewCameraContracts": review_contracts,
		"reviewVisualSnapshot": review_visual_snapshot_summary(),
		"cameraStageProgress": camera_stage_progress.duplicate(true),
		"visualReviewRequired": not camera_physics_replay,
		"doesNotProve": "Rendered image quality, visual composition, gameplay or NPC behavior." if camera_physics_replay else "Gameplay or NPC behavior."
	}
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	get_tree().quit(0 if report.status == "passed" else 1)


func inspect_architectural_recipe_parts() -> Dictionary:
	var counts := {
		"facadeCoreCount": 0,
		"facadeShellWallCount": 0,
		"facadePanelCount": 0,
		"functionalDoorCount": 0,
		"urbanRoomCount": 0,
		"warmWindowCount": 0,
		"coolWindowCount": 0,
		"householdDetailCount": 0,
		"pathAgeCount": 0,
		"treeTransitionCount": 0
	}
	var legacy_solid_facades: Array[String] = []
	if blueprint == null:
		return {"passed": false, "counts": counts, "legacySolidFacades": legacy_solid_facades}
	for part in blueprint.parts:
		if part == null:
			continue
		var part_id := String(part.id)
		var semantic := String(part.semantic)
		var material := String(part.material_id)
		if part_id.ends_with("_upper") and semantic == "citadel_urban_facade":
			legacy_solid_facades.append(part_id)
		if part_id.contains("_facade_") and semantic in ["citadel_urban_facade", "citadel_urban_stone_base"]:
			counts.facadePanelCount += 1
		elif part_id.ends_with("_core") and semantic.ends_with("_core"):
			counts.facadeCoreCount += 1
		elif part_id.contains("_shell_") and semantic.ends_with("_shell"):
			counts.facadeShellWallCount += 1
		if String(part.kind) == "door" and semantic == "citadel_urban_door":
			counts.functionalDoorCount += 1
		if material == "window_warm_glass":
			counts.warmWindowCount += 1
		elif material == "window_glass":
			counts.coolWindowCount += 1
		if semantic.begins_with("citadel_household_") or semantic in ["citadel_shopfront", "citadel_shopfront_goods"]:
			counts.householdDetailCount += 1
		if semantic in ["citadel_lane_edge_age", "citadel_route_verge", "citadel_route_rut", "citadel_threshold_wear", "citadel_market_compaction"]:
			counts.pathAgeCount += 1
	var urban_poc: Dictionary = blueprint.recipe.get("urbanPoc", {}) as Dictionary
	counts.treeTransitionCount = (urban_poc.get("treePlacements", []) as Array).size()
	for room_value in blueprint.rooms:
		if room_value is Dictionary and bool((room_value as Dictionary).get("citadelUrbanRoom", false)):
			counts.urbanRoomCount += 1
	var passed := legacy_solid_facades.is_empty() and int(counts.facadeCoreCount) == 0 and int(counts.facadeShellWallCount) > 0 and int(counts.facadePanelCount) > 0 and int(counts.functionalDoorCount) > 0 and int(counts.urbanRoomCount) > 0 and int(counts.warmWindowCount) > 0 and int(counts.coolWindowCount) > 0 and int(counts.householdDetailCount) > 0 and int(counts.pathAgeCount) > 0 and int(counts.treeTransitionCount) > 0
	return {"passed": passed, "counts": counts, "legacySolidFacades": legacy_solid_facades}


func audit_structural_supports() -> Dictionary:
	var failures: Array[String] = []
	var parts_by_id := {}
	var house_floor_count := 0
	var grounded_house_foundation_count := 0
	var artificial_exterior_parts: Array[String] = []
	if blueprint == null:
		return {"passed": false, "failures": ["missing_blueprint"]}
	for part in blueprint.parts:
		if part != null:
			parts_by_id[String(part.id)] = part
	for part in blueprint.parts:
		if part == null:
			continue
		var part_id := String(part.id)
		var semantic := String(part.semantic)
		var bounds := review_part_bounds(part)
		if part_id.ends_with("_interior_floor") and part_id.begins_with("urban_"):
			house_floor_count += 1
			var foundation_id := "%s_foundation" % part_id.trim_suffix("_interior_floor")
			var foundation = parts_by_id.get(foundation_id, null)
			if foundation == null:
				failures.append("missing_house_foundation:%s" % foundation_id)
			elif not bool(foundation.collision_enabled):
				failures.append("non_collision_house_foundation:%s" % foundation_id)
			else:
				var foundation_bounds := review_part_bounds(foundation)
				if foundation_bounds.position.y > 0.02 or absf(foundation_bounds.end.y - bounds.position.y) > 0.04:
					failures.append("unsupported_house_floor:%s" % part_id)
				else:
					grounded_house_foundation_count += 1
		if semantic in ["citadel_street_climb", "citadel_urban_terrace", "citadel_urban_stair"] \
				or part_id.begins_with("urban_market_plaza_retaining") or part_id.begins_with("urban_upper_lane"):
			artificial_exterior_parts.append(part_id)
	var market_paving = parts_by_id.get("urban_market_plaza", null)
	if market_paving == null:
		failures.append("missing_market_paving")
	else:
		var market_paving_bounds := review_part_bounds(market_paving)
		var foundation_height := float(blueprint.recipe.get("foundationHeight", 0.62))
		if bool(market_paving.collision_enabled) or String(market_paving.kind) != "ground_patch" \
				or absf(market_paving_bounds.position.y - (foundation_height + 0.14)) > 0.03:
			failures.append("market_plaza_is_not_visual_finish_on_shared_ground")
	var tower = parts_by_id.get("urban_civic_tower", null)
	var tower_foundation = parts_by_id.get("urban_civic_tower_foundation", null)
	if tower == null or tower_foundation == null:
		failures.append("missing_civic_tower_foundation")
	else:
		var tower_bounds := review_part_bounds(tower)
		var tower_foundation_bounds := review_part_bounds(tower_foundation)
		if not bool(tower_foundation.collision_enabled) or tower_foundation_bounds.position.y > 0.02 or absf(tower_foundation_bounds.end.y - tower_bounds.position.y) > 0.02:
			failures.append("unsupported_civic_tower")
	var passed := failures.is_empty() and artificial_exterior_parts.is_empty() and house_floor_count > 0 and grounded_house_foundation_count == house_floor_count
	return {
		"passed": passed,
		"failures": failures,
		"houseFloorCount": house_floor_count,
		"groundedHouseFoundationCount": grounded_house_foundation_count,
		"artificialExteriorPartIds": artificial_exterior_parts,
		"marketPlazaIsVisualFinish": market_paving != null and not bool(market_paving.collision_enabled)
	}


func wait_for_capture_readiness() -> Dictionary:
	var deadline_msec := Time.get_ticks_msec() + 240000
	while Time.get_ticks_msec() < deadline_msec:
		var publication: Dictionary = building_publisher.summary() if building_publisher != null else {}
		var expected_part_count: int = blueprint.parts.size() if blueprint != null else 0
		var published_part_count := int(publication.get("publishedPartCount", 0))
		if not is_rebuilding and blueprint != null and cottage_root != null and front_door != null and registered_door_count >= 2 and expected_part_count > 0 and published_part_count == expected_part_count:
			set_loading_visible(false)
			for _frame in range(4):
				await get_tree().process_frame
			return {
				"ready": loading_overlay == null or not loading_overlay.visible,
				"isRebuilding": is_rebuilding,
				"expectedPartCount": expected_part_count,
				"publishedPartCount": published_part_count,
				"registeredDoorCount": registered_door_count,
				"loadingVisible": loading_overlay.visible if loading_overlay != null else false
			}
		await get_tree().process_frame
	var timed_out_publication: Dictionary = building_publisher.summary() if building_publisher != null else {}
	return {
		"ready": false,
		"timedOut": true,
		"isRebuilding": is_rebuilding,
		"expectedPartCount": blueprint.parts.size() if blueprint != null else 0,
		"publishedPartCount": int(timed_out_publication.get("publishedPartCount", 0)),
		"registeredDoorCount": registered_door_count,
		"loadingVisible": loading_overlay.visible if loading_overlay != null else false
	}


func inspect_market_recipe_parts() -> Dictionary:
	var records: Array[Dictionary] = []
	var overlaps: Array[Dictionary] = []
	var plaza_bounds := AABB()
	for part in blueprint.parts:
		if part != null and String(part.id) == "urban_market_plaza":
			plaza_bounds = AABB(part.position - part.size * 0.5, part.size)
			break
	for part in blueprint.parts:
		if part == null:
			continue
		var part_id := String(part.id)
		var part_bounds := AABB(part.position - part.size * 0.5, part.size)
		var horizontal_overlap := plaza_bounds.size.x > 0.0 and part_bounds.position.x < plaza_bounds.end.x and part_bounds.end.x > plaza_bounds.position.x and part_bounds.position.z < plaza_bounds.end.z and part_bounds.end.z > plaza_bounds.position.z
		if horizontal_overlap and not part_id.begins_with("urban_market_"):
			overlaps.append({"id": part_id, "kind": String(part.kind), "material": String(part.material_id), "position": part.position, "size": part.size})
		if not part_id.begins_with("urban_market_"):
			continue
		records.append({
			"id": part_id,
			"kind": String(part.kind),
			"material": String(part.material_id),
			"position": part.position,
			"size": part.size
		})
	return {"partCount": records.size(), "parts": records, "nonMarketFootprintOverlaps": overlaps}


func capture_views() -> Array[Dictionary]:
	var snapshot := build_review_visual_snapshot()
	if not bool(snapshot.get("valid", false)):
		return [failed_exterior_review_view("visual_snapshot", "review visual snapshot", String(snapshot.get("reason", "review_visual_snapshot_failed")))]
	var market_subject := market_review_subject()
	var tree_subject := green_market_tree_subject(market_subject)
	var civic_roof_subject := generated_review_subject_family("citadel_civic_roof", "urban_civic_roof_", 2, [], ["citadel_civic_landmark", "citadel_civic_blind_recess", "citadel_civic_banner", "citadel_civic_roof_bearing", "citadel_civic_roof_framing", "citadel_civic_gable_closure"], "roof", civic_roof_context_part_ids())
	var civic_commons_subject := generated_review_subject_family("citadel_civic_commons_seating", "urban_civic_commons_bench", 6, ["urban_civic_commons_bench", "urban_civic_commons_bench_back"], ["citadel_civic_commons_stone"], "decor")
	var perimeter_view: Dictionary = await perimeter_lane_review_view(22.0, 4.8, 12.0, 3.2, 0)
	var tree_contact_view := select_tree_contact_view()
	if tree_contact_view.is_empty():
		tree_contact_view = failed_exterior_review_view("tree_contact_paving", "tree canopy paving transition", "no generated tree has an unobstructed paved canopy-edge contact")
	var views: Array[Dictionary] = [
		make_part_review_view("outer_approach", "gatehouse", "castle_gatehouse_lintel", "", 30.0, 8.0, 18.0, 4.5, 0),
		gate_threshold_review_view(),
		make_part_review_view("inner_lane", "lane route", "castle_district_processional_00_gate_lane_roadbed_", "", 25.0, 5.0, 14.0, 3.0, 0),
		make_subject_review_view("market_ground", "market storefront", market_subject, 15.0, 4.8, 10.8, 2.25, 0),
		make_subject_review_view("market_release", "market storefront", market_subject, 18.0, 5.8, 12.0, 3.8, 2),
		{"id": "civic_overview"},
		{"id": "civic_commons"},
		perimeter_view,
		make_subject_review_view("green_market_square", "tree root and path edge", tree_subject, 13.0, 4.6, 9.6, 2.4, 1),
		tree_contact_view
	]
	return replace_civic_review_views(views,
		make_subject_review_view("civic_overview", "civic roofline", civic_roof_subject, 34.0, 8.0, 22.0, 0.01, 0),
		make_subject_review_view("civic_commons", "civic commons", civic_commons_subject, 16.0, 4.5, 10.0, 0.01, 0))


func replace_civic_review_views(views: Array[Dictionary], civic_overview: Dictionary, civic_commons: Dictionary) -> Array[Dictionary]:
	var expected_ids := ["outer_approach", "gate_threshold", "inner_lane", "market_ground", "market_release", "civic_overview", "civic_commons", "perimeter_lane", "green_market_square", "tree_contact_paving"]
	if views.size() != expected_ids.size():
		return []
	var result: Array[Dictionary] = []
	for index in range(views.size()):
		if String(views[index].get("id", "")) != expected_ids[index]:
			return []
		if index == 5:
			result.append(civic_overview)
		elif index == 6:
			result.append(civic_commons)
		else:
			result.append(views[index])
	return result


func gate_threshold_review_view() -> Dictionary:
	if front_door == null:
		return failed_exterior_review_view("gate_threshold", "gate passage", "missing generated gate door subject")
	return make_exterior_review_view("gate_threshold", "gate passage", front_door.global_position + Vector3(0.0, 1.24, 0.0), 24.0, 6.0, 12.0, 2.8, 0)


func failed_exterior_review_view(id: String, subject: String, reason: String) -> Dictionary:
	return make_exterior_review_view_from_pose(id, subject, Vector3.ZERO, 0.0, {"ok": false, "reason": reason})


func make_part_review_view(id: String, subject: String, id_prefix: String, semantic: String, maximum_distance: float, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int) -> Dictionary:
	var part = deterministic_review_part(id_prefix, semantic)
	if part == null:
		return failed_exterior_review_view(id, subject, "missing generated review subject")
	var bounds := review_part_bounds(part)
	var target := generated_review_focus(part, bounds)
	var radial := generated_subject_radial_domain(bounds, maximum_distance, minimum_distance, preferred_distance, subject_radius)
	var view := make_exterior_review_view(id, subject, target, float(radial.maximumDistance), float(radial.minimumDistance), float(radial.preferredDistance), float(radial.subjectRadius), preferred_direction_index, -INF, Callable(self, "generated_subject_readability_rejection").bind([String(part.id)], target), Callable(self, "generated_part_visible_surface").bind(String(part.id)))
	view["cameraSubjectIds"] = [String(part.id)]
	view["cameraSubjectBounds"] = bounds
	view["cameraCandidateDomain"] = {"type": "bounded_radial_generated_bounds", "count": 64, "minimumDistance": radial.minimumDistance, "preferredDistance": radial.preferredDistance, "subjectRadius": radial.subjectRadius}
	return view


func make_subject_review_view(id: String, subject: String, source: Dictionary, maximum_distance: float, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int) -> Dictionary:
	if not bool(source.get("valid", false)):
		return failed_exterior_review_view(id, subject, String(source.get("reason", "missing generated review subject")))
	var subject_ids: Array = source.get("subjectIds", []) as Array
	var readability_mode := String(source.get("readabilityMode", "all"))
	var required_visible_ids: Array = source.get("requiredVisiblePartIds", []) as Array
	var composition_subject_ids: Array = source.get("compositionSubjectIds", subject_ids) as Array
	var rejection := Callable(self, "generated_family_readability_rejection").bind(subject_ids, required_visible_ids, composition_subject_ids, source.focus) if not required_visible_ids.is_empty() else (Callable(self, "generated_any_subject_readability_rejection").bind(subject_ids, [], source.focus) if readability_mode == "any" and not subject_ids.is_empty() else (Callable(self, "generated_subject_readability_rejection").bind(subject_ids, source.focus) if not subject_ids.is_empty() else Callable()))
	var visibility_ids: Array = source.get("visibilityPartIds", []) as Array
	var visibility := Callable(self, "generated_subject_visible_surface").bind(visibility_ids) if not visibility_ids.is_empty() else (Callable(self, "generated_part_visible_surface").bind(String(source.get("visibilityPartId", ""))) if not String(source.get("visibilityPartId", "")).is_empty() else Callable())
	var candidates: Array = source.get("candidatePositions", []) as Array
	var source_bounds: AABB = source.get("bounds", AABB()) as AABB
	var radial := generated_subject_radial_domain(source_bounds, maximum_distance, minimum_distance, preferred_distance, subject_radius)
	var effective_radius := float(source.get("subjectRadius", radial.subjectRadius))
	var effective_maximum := float(source.get("maximumDistance", radial.maximumDistance))
	var pose := solve_exterior_review_pose_from_candidates(source.focus as Vector3, candidates, effective_radius, float(source.get("minimumSupportY", -INF)), rejection, visibility) if not candidates.is_empty() else solve_exterior_review_pose(source.focus as Vector3, float(radial.minimumDistance), float(radial.preferredDistance), effective_radius, preferred_direction_index, float(source.get("minimumSupportY", -INF)), rejection, visibility)
	var view := make_exterior_review_view_from_pose(id, subject, source.focus as Vector3, effective_maximum, pose)
	view["cameraSubjectIds"] = subject_ids
	view["cameraSubjectBounds"] = source.get("bounds", AABB())
	if not required_visible_ids.is_empty():
		view["cameraRequiredVisiblePartIds"] = required_visible_ids
		view["cameraCompositionSubjectIds"] = composition_subject_ids
		view["cameraSubjectFamilySignature"] = String(source.get("familySignature", ""))
		view["cameraRequiredVisibleBounds"] = source.get("requiredVisibleBounds")
		view["cameraRequiresExactRequiredVisibleTarget"] = bool(source.get("requiresExactRequiredVisibleTarget", false))
	view["cameraCandidateDomain"] = source.get("candidateDomain", {"type": "bounded_radial", "count": 64, "minimumDistance": minimum_distance, "preferredDistance": preferred_distance})
	view["cameraDeclaredSupportIds"] = source.get("supportIds", [String(source.get("supportId", ""))])
	return view


func generated_review_focus(part, bounds: AABB) -> Vector3:
	var focus := bounds.get_center()
	if String(part.kind) in ["foundation", "floor", "ground_patch", "ramp", "stair_tread"]:
		focus.y = bounds.end.y + 1.25
	elif String(part.kind) == "beam":
		focus.y = bounds.get_center().y
	elif String(part.kind) == "decor":
		focus.y = minf(bounds.end.y + 0.85, bounds.position.y + 1.55)
	else:
		focus.y = bounds.position.y + minf(5.0, bounds.size.y * 0.35)
	return focus


func generated_subject_radial_domain(bounds: AABB, maximum_distance: float, minimum_distance: float, preferred_distance: float, subject_radius: float) -> Dictionary:
	var bounds_radius := generated_subject_frame_radius(bounds, subject_radius)
	var effective_radius := maxf(subject_radius, bounds_radius)
	var required_distance := effective_radius / tan(MAX_REVIEW_SUBJECT_FRAME_FRACTION * deg_to_rad(62.0) * 0.5)
	var bounded_maximum := maxf(maximum_distance, required_distance * 1.32)
	var bounded_preferred := minf(bounded_maximum * 0.92, maxf(preferred_distance, required_distance * 1.18))
	var bounded_minimum := minf(bounded_preferred, maxf(minimum_distance, required_distance * 1.02))
	return {"minimumDistance": bounded_minimum, "preferredDistance": bounded_preferred, "maximumDistance": bounded_maximum, "subjectRadius": effective_radius}


func generated_subject_frame_radius(bounds: AABB, fallback_radius: float) -> float:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return fallback_radius
	return maxf(fallback_radius, maxf(bounds.size.y, maxf(bounds.size.x, bounds.size.z) * 0.5))


func clear_review_visual_snapshot() -> void:
	_review_visual_snapshot_epoch += 1
	_review_visual_snapshot = {}


func review_visual_snapshot_binding() -> String:
	return String(_review_visual_snapshot.get("binding", ""))


func review_visual_snapshot_summary() -> Dictionary:
	return {"valid": bool(_review_visual_snapshot.get("valid", false)), "reason": String(_review_visual_snapshot.get("reason", "")), "binding": String(_review_visual_snapshot.get("binding", "")), "epoch": _review_visual_snapshot_epoch, "blueprintId": String(_review_visual_snapshot.get("blueprintId", "")), "sourcePartCount": int(_review_visual_snapshot.get("sourcePartCount", 0)), "recordCount": int(_review_visual_snapshot.get("recordCount", 0)), "buildUsec": int(_review_visual_snapshot.get("buildUsec", 0)), "entryCount": int(_review_visual_snapshot.get("entryCount", 0)), "cellSize": float(_review_visual_snapshot.get("cellSize", REVIEW_VISUAL_INDEX_CELL_SIZE)), "canonicalSignature": String(_review_visual_snapshot.get("canonicalSignature", ""))}


func build_review_visual_snapshot() -> Dictionary:
	_review_visual_snapshot_epoch += 1
	var started_usec := Time.get_ticks_usec()
	if blueprint == null:
		_review_visual_snapshot = {"valid": false, "reason": "missing_blueprint"}
		return _review_visual_snapshot.duplicate(true)
	var source_parts: Array = blueprint.parts as Array
	if source_parts.is_empty() or source_parts.size() > MAX_REVIEW_VISUAL_SOURCE_PARTS:
		_review_visual_snapshot = {"valid": false, "reason": "invalid_visual_source_part_count", "sourcePartCount": source_parts.size()}
		return _review_visual_snapshot.duplicate(true)
	var records: Array[Dictionary] = []
	var canonical: Array[Dictionary] = []
	var by_id: Dictionary = {}
	var cells: Dictionary = {}
	var entry_count := 0
	for ordinal in range(source_parts.size()):
		var part = source_parts[ordinal]
		if part == null or not part.position is Vector3 or not part.rotation is Vector3 or not part.size is Vector3 or not part.position.is_finite() or not part.rotation.is_finite() or not part.size.is_finite() or part.size.x <= 0.0 or part.size.y <= 0.0 or part.size.z <= 0.0:
			_review_visual_snapshot = {"valid": false, "reason": "invalid_visual_source_record", "sourceOrdinal": ordinal}
			return _review_visual_snapshot.duplicate(true)
		var part_id := String(part.id)
		if part_id.is_empty() or by_id.has(part_id):
			_review_visual_snapshot = {"valid": false, "reason": "duplicate_or_empty_visual_source_id", "sourceOrdinal": ordinal, "partId": part_id}
			return _review_visual_snapshot.duplicate(true)
		var basis := Basis.from_euler(part.rotation)
		var transform := Transform3D(basis, part.position)
		var bounds := review_part_bounds(part)
		var visual := bool(part.recipe.get("visual", true))
		var record := {"sourceOrdinal": ordinal, "id": part_id, "kind": String(part.kind), "semantic": String(part.semantic), "visualEligible": visual, "collisionEnabled": bool(part.collision_enabled), "position": part.position, "rotation": part.rotation, "size": part.size, "transform": transform, "inverse": transform.affine_inverse(), "localBounds": AABB(-part.size * 0.5, part.size), "worldBounds": bounds}
		records.append(record)
		by_id[part_id] = record
		canonical.append({"sourceOrdinal": ordinal, "id": part_id, "kind": String(part.kind), "semantic": String(part.semantic), "visualEligible": visual, "collisionEnabled": bool(part.collision_enabled), "position": part.position, "rotation": part.rotation, "size": part.size})
		var indexed_bounds := bounds.grow(0.0001)
		var minimum := Vector3i(floori(indexed_bounds.position.x / REVIEW_VISUAL_INDEX_CELL_SIZE), floori(indexed_bounds.position.y / REVIEW_VISUAL_INDEX_CELL_SIZE), floori(indexed_bounds.position.z / REVIEW_VISUAL_INDEX_CELL_SIZE))
		var maximum_position := indexed_bounds.end - Vector3.ONE * 0.000001
		var maximum := Vector3i(floori(maximum_position.x / REVIEW_VISUAL_INDEX_CELL_SIZE), floori(maximum_position.y / REVIEW_VISUAL_INDEX_CELL_SIZE), floori(maximum_position.z / REVIEW_VISUAL_INDEX_CELL_SIZE))
		var cell_count := (maximum.x - minimum.x + 1) * (maximum.y - minimum.y + 1) * (maximum.z - minimum.z + 1)
		if cell_count < 1 or cell_count > MAX_REVIEW_VISUAL_CELLS_PER_RECORD or entry_count + cell_count > MAX_REVIEW_VISUAL_INDEX_ENTRIES:
			_review_visual_snapshot = {"valid": false, "reason": "visual_spatial_index_overflow", "sourceOrdinal": ordinal, "cellCount": cell_count}
			return _review_visual_snapshot.duplicate(true)
		for x in range(minimum.x, maximum.x + 1):
			for y in range(minimum.y, maximum.y + 1):
				for z in range(minimum.z, maximum.z + 1):
					var key := "%d,%d,%d" % [x, y, z]
					var values: Array = cells.get(key, []) as Array
					values.append(ordinal)
					cells[key] = values
					entry_count += 1
	var stable_records: Array = records.duplicate(false)
	stable_records.sort_custom(func(a: Dictionary, b: Dictionary): return String(a.id) < String(b.id))
	var stable_rank_by_ordinal: Dictionary = {}
	for stable_rank in range(stable_records.size()):
		stable_rank_by_ordinal[int((stable_records[stable_rank] as Dictionary).sourceOrdinal)] = stable_rank
	var blueprint_id := String(blueprint.id)
	var binding := "%s:%s" % [blueprint_id, JSON.stringify(canonical).sha256_text()]
	_review_visual_snapshot = {"valid": true, "binding": binding, "blueprintId": blueprint_id, "sourcePartCount": source_parts.size(), "recordCount": records.size(), "buildUsec": Time.get_ticks_usec() - started_usec, "records": records, "stableRecords": stable_records, "stableRankByOrdinal": stable_rank_by_ordinal, "byId": by_id, "cells": cells, "cellSize": REVIEW_VISUAL_INDEX_CELL_SIZE, "entryCount": entry_count, "canonicalSignature": JSON.stringify(canonical).sha256_text()}
	return {"valid": true, "binding": binding, "blueprintId": blueprint_id, "sourcePartCount": source_parts.size(), "recordCount": records.size(), "buildUsec": int(_review_visual_snapshot.buildUsec), "entryCount": entry_count, "canonicalSignature": String(_review_visual_snapshot.canonicalSignature)}


func review_visual_snapshot_candidates(envelope: AABB, stable_order: bool = false, expected_binding: String = "") -> Dictionary:
	if not bool(_review_visual_snapshot.get("valid", false)) or envelope.size.x < 0.0 or envelope.size.y < 0.0 or envelope.size.z < 0.0 or not envelope.position.is_finite() or not envelope.size.is_finite():
		return {"valid": false, "reason": "missing_or_invalid_visual_snapshot", "records": []}
	var binding := String(_review_visual_snapshot.get("binding", ""))
	if expected_binding.is_empty() or expected_binding != binding:
		return {"valid": false, "reason": "stale_visual_snapshot_binding", "records": []}
	var indexed_envelope := envelope.grow(0.0001)
	var minimum := Vector3i(floori(indexed_envelope.position.x / REVIEW_VISUAL_INDEX_CELL_SIZE), floori(indexed_envelope.position.y / REVIEW_VISUAL_INDEX_CELL_SIZE), floori(indexed_envelope.position.z / REVIEW_VISUAL_INDEX_CELL_SIZE))
	var maximum_position := indexed_envelope.end - Vector3.ONE * 0.000001
	var maximum := Vector3i(floori(maximum_position.x / REVIEW_VISUAL_INDEX_CELL_SIZE), floori(maximum_position.y / REVIEW_VISUAL_INDEX_CELL_SIZE), floori(maximum_position.z / REVIEW_VISUAL_INDEX_CELL_SIZE))
	var cell_count := (maximum.x - minimum.x + 1) * (maximum.y - minimum.y + 1) * (maximum.z - minimum.z + 1)
	if cell_count < 1 or cell_count > MAX_REVIEW_VISUAL_INDEX_ENTRIES:
		return {"valid": false, "reason": "visual_query_overflow", "records": []}
	var ordinals: Dictionary = {}
	var cells: Dictionary = _review_visual_snapshot.cells as Dictionary
	for x in range(minimum.x, maximum.x + 1):
		for y in range(minimum.y, maximum.y + 1):
			for z in range(minimum.z, maximum.z + 1):
				for ordinal_value in cells.get("%d,%d,%d" % [x, y, z], []):
					ordinals[int(ordinal_value)] = true
	var selected_ordinals: Array = ordinals.keys()
	if stable_order:
		var ranks: Dictionary = _review_visual_snapshot.stableRankByOrdinal as Dictionary
		selected_ordinals.sort_custom(func(a, b): return int(ranks.get(int(a), -1)) < int(ranks.get(int(b), -1)))
	else:
		selected_ordinals.sort()
	var records: Array = _review_visual_snapshot.records as Array
	var result: Array[Dictionary] = []
	for ordinal_value in selected_ordinals:
		var record: Dictionary = records[int(ordinal_value)] as Dictionary
		if (record.worldBounds as AABB).grow(0.0001).intersects(envelope.grow(0.0001)):
			result.append(record)
	return {"valid": true, "binding": binding, "records": result, "candidateCount": result.size(), "cellCount": cell_count}


func review_visual_snapshot_reference_candidates(envelope: AABB, stable_order: bool = false, expected_binding: String = "") -> Dictionary:
	if not bool(_review_visual_snapshot.get("valid", false)) or expected_binding.is_empty() or expected_binding != review_visual_snapshot_binding():
		return {"valid": false, "reason": "missing_or_stale_visual_snapshot_binding", "records": []}
	var source: Array = _review_visual_snapshot.stableRecords if stable_order else _review_visual_snapshot.records
	var result: Array[Dictionary] = []
	for record_value in source:
		var record: Dictionary = record_value
		if (record.worldBounds as AABB).grow(0.0001).intersects(envelope.grow(0.0001)):
			result.append(record)
	return {"valid": true, "binding": expected_binding, "records": result, "candidateCount": result.size()}


func generated_part_visible_surface(camera_position: Vector3, part_id: String) -> Variant:
	_review_camera_phase_visit("parts")
	if not bool(_review_visual_snapshot.get("valid", false)):
		return Vector3.INF
	var record: Dictionary = (_review_visual_snapshot.get("byId", {}) as Dictionary).get(part_id, {}) as Dictionary
	if record.is_empty() or not bool(record.get("visualEligible", false)):
		return Vector3.INF
	var transform: Transform3D = record.transform
	var local_camera := transform.affine_inverse() * camera_position
	var half: Vector3 = (record.size as Vector3) * 0.5
	var samples: Array[Vector2] = [Vector2.ZERO, Vector2(-0.34, 0.0), Vector2(0.34, 0.0), Vector2(0.0, -0.34), Vector2(0.0, 0.34), Vector2(-0.34, -0.34), Vector2(0.34, -0.34), Vector2(-0.34, 0.34), Vector2(0.34, 0.34)]
	var x_face := absf(local_camera.x / maxf(half.x, 0.01)) >= absf(local_camera.z / maxf(half.z, 0.01))
	for sample in samples:
		_review_camera_phase_visit("samples")
		var local_surface: Vector3
		if x_face:
			local_surface = Vector3(half.x * signf(local_camera.x), half.y * sample.y, half.z * sample.x)
		else:
			local_surface = Vector3(half.x * sample.x, half.y * sample.y, half.z * signf(local_camera.z))
		var surface := transform * local_surface
		if review_line_is_clear(camera_position, surface) and review_visual_line_is_clear(camera_position, surface):
			return surface
	return Vector3.INF


func generated_subject_visible_surface(camera_position: Vector3, part_ids: Array) -> Variant:
	var evidence := generated_subject_visible_surface_evidence(camera_position, part_ids)
	return evidence.get("surface", Vector3.INF) if bool(evidence.get("valid", false)) else Vector3.INF


func generated_subject_visible_surface_evidence(camera_position: Vector3, part_ids: Array) -> Dictionary:
	var ordered: Array = part_ids.duplicate()
	ordered.sort_custom(func(a, b): return String(a) < String(b))
	for id_value in ordered:
		_review_camera_phase_visit("parts")
		var record: Dictionary = (_review_visual_snapshot.get("byId", {}) as Dictionary).get(String(id_value), {}) as Dictionary
		if record.is_empty() or not bool(record.get("visualEligible", false)):
			continue
		var surface: Variant = generated_part_visible_surface(camera_position, String(id_value))
		if surface is Vector3 and surface.is_finite():
			return {"valid": true, "partId": String(id_value), "surface": surface}
	return {"valid": false, "reason": "no_published_visible_subject_member"}


func generated_part_has_published_visual(part) -> bool:
	return part != null and bool(part.recipe.get("visual", true)) and part.size is Vector3 and part.size.is_finite() and part.size.x > 0.0 and part.size.y > 0.0 and part.size.z > 0.0


func generated_subject_readability_rejection(camera_position: Vector3, subject_ids: Array, camera_target: Variant = null) -> String:
	if subject_ids.is_empty():
		return "missing_subject_family"
	var subject_bounds := generated_subject_bounds(subject_ids)
	var framing_reason := generated_upper_framing_rejection(camera_position, subject_bounds, camera_target)
	if not framing_reason.is_empty():
		_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "upperFrame", "reason": framing_reason, "selectedVisibleMember": "", "blockers": []})
		return framing_reason
	var composition_reason := generated_cached_near_camera_visual_composition_rejection(camera_position, subject_bounds, subject_ids, "")
	if not composition_reason.is_empty():
		return composition_reason
	for id_value in subject_ids:
		var surface: Variant = generated_part_visible_surface(camera_position, String(id_value))
		if not surface is Vector3 or not surface.is_finite() or not review_line_is_clear(camera_position, surface) or not review_visual_line_is_clear(camera_position, surface):
			return "generated_subject_not_readable:%s" % String(id_value)
	return ""


func generated_any_subject_readability_rejection(camera_position: Vector3, subject_ids: Array, composition_subject_ids: Array = [], camera_target: Variant = null) -> String:
	if subject_ids.is_empty():
		return "missing_subject_family"
	var composition_ids: Array = composition_subject_ids if not composition_subject_ids.is_empty() else subject_ids
	var subject_bounds := generated_subject_bounds(subject_ids)
	var framing_reason := generated_upper_framing_rejection(camera_position, subject_bounds, camera_target)
	if not framing_reason.is_empty():
		_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "upperFrame", "reason": framing_reason, "selectedVisibleMember": "", "blockers": []})
		return framing_reason
	var evidence := generated_subject_visible_surface_evidence(camera_position, subject_ids)
	if not bool(evidence.get("valid", false)):
		_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "noReadableMember", "reason": String(evidence.get("reason", "generated_subject_family_not_readable")), "selectedVisibleMember": "", "blockers": []})
		return "generated_subject_family_not_readable"
	var selected_id := String(evidence.get("partId", ""))
	var composition_reason := generated_cached_near_camera_visual_composition_rejection(camera_position, subject_bounds, composition_ids, selected_id)
	if not composition_reason.is_empty():
		return composition_reason
	return ""


func generated_family_readability_rejection(camera_position: Vector3, subject_ids: Array, required_visible_ids: Array, composition_subject_ids: Array, camera_target: Variant = null) -> String:
	if subject_ids.is_empty() or required_visible_ids.is_empty():
		return "missing_subject_family"
	var subject_identity: Dictionary = {}
	for id_value in subject_ids:
		subject_identity[String(id_value)] = true
	for id_value in required_visible_ids:
		if not subject_identity.has(String(id_value)):
			return "ambiguous_subject_family"
	var subject_bounds := generated_subject_bounds(subject_ids)
	var framing_reason := generated_upper_framing_rejection(camera_position, subject_bounds, camera_target)
	if not framing_reason.is_empty():
		_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "upperFrame", "reason": framing_reason, "selectedVisibleMember": "", "blockers": []})
		return framing_reason
	var ordered_required: Array = required_visible_ids.duplicate()
	ordered_required.sort_custom(func(a, b): return String(a) < String(b))
	var selected_id := ""
	for id_value in ordered_required:
		var id := String(id_value)
		var surface: Variant = generated_part_visible_surface(camera_position, id)
		if not surface is Vector3 or not surface.is_finite() or not review_line_is_clear(camera_position, surface) or not review_visual_line_is_clear(camera_position, surface):
			var reason := "generated_required_subject_not_readable:%s" % id
			_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "noReadableMember", "reason": reason, "selectedVisibleMember": id, "blockers": []})
			return reason
		if selected_id.is_empty():
			selected_id = id
	var composition_ids: Array = composition_subject_ids if not composition_subject_ids.is_empty() else subject_ids
	var composition_reason := generated_cached_near_camera_visual_composition_rejection(camera_position, subject_bounds, composition_ids, selected_id)
	if not composition_reason.is_empty():
		return composition_reason
	return ""


func generated_subject_bounds(subject_ids: Array) -> AABB:
	var result := AABB()
	var has_bounds := false
	for id_value in subject_ids:
		_review_camera_phase_visit("parts")
		var record: Dictionary = (_review_visual_snapshot.get("byId", {}) as Dictionary).get(String(id_value), {}) as Dictionary
		if record.is_empty():
			return AABB()
		var bounds: AABB = record.worldBounds
		result = bounds if not has_bounds else result.merge(bounds)
		has_bounds = true
	return result


func generated_foreground_bounds(subject_ids: Array) -> Array[AABB]:
	var result: Array[AABB] = []
	if not bool(_review_visual_snapshot.get("valid", false)):
		return result
	var excluded: Dictionary = {}
	for id_value in subject_ids:
		excluded[String(id_value)] = true
	for record_value in _review_visual_snapshot.get("stableRecords", []):
		_review_camera_phase_visit("parts")
		var record: Dictionary = record_value
		if not bool(record.visualEligible) or excluded.has(String(record.id)) or String(record.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
			continue
		result.append(record.worldBounds as AABB)
	return result


func generated_upper_framing_rejection(camera_position: Vector3, subject_bounds: AABB, camera_target: Variant = null) -> String:
	if not _review_family_bounds_are_valid(subject_bounds):
		return "missing_subject_bounds"
	var target: Variant = subject_bounds.get_center() if camera_target == null else camera_target
	if not target is Vector3 or not target.is_finite():
		return "invalid_camera_aim"
	var direction: Vector3 = target - camera_position
	if not camera_position.is_finite() or direction.length_squared() <= 0.0001 or direction.cross(Vector3.UP).length_squared() <= 0.0001:
		return "invalid_camera_aim"
	# Capture looks at the subject, not the horizon. Test the complete bounds
	# in that pitched camera frame, including the nearer top corners.
	return generated_upper_framing_for_transform(Transform3D(Basis.looking_at(direction, Vector3.UP), camera_position), subject_bounds)


func generated_upper_framing_for_transform(camera_transform: Transform3D, subject_bounds: AABB, vertical_fov := 62.0) -> String:
	if not _review_family_bounds_are_valid(subject_bounds):
		return "missing_subject_bounds"
	if not camera_transform.origin.is_finite() or not camera_transform.basis.is_finite() or absf(camera_transform.basis.determinant()) <= 0.0001 or not is_finite(vertical_fov) or vertical_fov <= 0.0 or vertical_fov >= 180.0:
		return "invalid_camera_aim"
	var inverse := camera_transform.affine_inverse()
	var upper_limit := tan(deg_to_rad(vertical_fov) * 0.5)
	for index in range(8):
		var local: Vector3 = inverse * subject_bounds.get_endpoint(index)
		var depth := -local.z
		if depth <= 0.05:
			return "subject_crosses_camera_plane"
		if local.y > depth * upper_limit:
			return "upper_frame_clipped"
	return ""


func generated_near_camera_visual_composition_rejection(camera_position: Vector3, subject_bounds: AABB, foreground_bounds: Array) -> String:
	if subject_bounds.size.x <= 0.0 or subject_bounds.size.y <= 0.0 or subject_bounds.size.z <= 0.0:
		return "missing_subject_bounds"
	if foreground_bounds.is_empty():
		return "missing_foreground_bounds"
	var forward := subject_bounds.get_center() - camera_position
	if forward.length_squared() <= 0.0001:
		return "near_camera_visual_volume"
	forward = forward.normalized()
	var ordered: Array = foreground_bounds.duplicate()
	ordered.sort_custom(func(a, b):
		if not a is AABB or not b is AABB:
			return str(a) < str(b)
		var a_bounds: AABB = a
		var b_bounds: AABB = b
		return "%0.4f:%0.4f:%0.4f" % [a_bounds.position.x, a_bounds.position.y, a_bounds.position.z] < "%0.4f:%0.4f:%0.4f" % [b_bounds.position.x, b_bounds.position.y, b_bounds.position.z])
	for value in ordered:
		_review_camera_phase_visit("parts")
		if not value is AABB:
			return "invalid_foreground_bounds"
		var bounds: AABB = value
		var closest := Vector3(clampf(camera_position.x, bounds.position.x, bounds.end.x), clampf(camera_position.y, bounds.position.y, bounds.end.y), clampf(camera_position.z, bounds.position.z, bounds.end.z))
		var offset := closest - camera_position
		var distance := offset.length()
		var angular_span := 2.0 * atan(maxf(bounds.size.x, bounds.size.y) * 0.5 / maxf(distance, 0.01))
		if distance < 1.25 and angular_span > deg_to_rad(24.0) and (distance <= 0.01 or offset.normalized().dot(forward) > -0.10):
			return "near_camera_visual_volume"
	return ""


func generated_cached_near_camera_visual_composition_rejection(camera_position: Vector3, subject_bounds: AABB, subject_ids: Array, selected_visible_member: String = "") -> String:
	if subject_bounds.size.x <= 0.0 or subject_bounds.size.y <= 0.0 or subject_bounds.size.z <= 0.0:
		return "missing_subject_bounds"
	if not bool(_review_visual_snapshot.get("valid", false)):
		return "missing_foreground_bounds"
	var excluded: Dictionary = {}
	for id_value in subject_ids:
		excluded[String(id_value)] = true
	var has_foreground := false
	for record_value in _review_visual_snapshot.get("stableRecords", []):
		var record: Dictionary = record_value
		if bool(record.visualEligible) and not excluded.has(String(record.id)) and String(record.kind) not in ["foundation", "floor", "ground_patch", "ramp"]:
			has_foreground = true
			break
	if not has_foreground:
		return "missing_foreground_bounds"
	var forward := subject_bounds.get_center() - camera_position
	if forward.length_squared() <= 0.0001:
		_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "nearCameraComposition", "reason": "near_camera_visual_volume", "selectedVisibleMember": selected_visible_member, "blockers": []})
		return "near_camera_visual_volume"
	forward = forward.normalized()
	var envelope := AABB(camera_position - Vector3.ONE * 1.2501, Vector3.ONE * 2.5002)
	var query := review_visual_snapshot_candidates(envelope, true, review_visual_snapshot_binding())
	if not bool(query.get("valid", false)):
		_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "nearCameraComposition", "reason": "near_camera_visual_volume", "selectedVisibleMember": selected_visible_member, "blockers": []})
		return "near_camera_visual_volume"
	for record_value in query.get("records", []):
		_review_camera_phase_visit("parts")
		var record: Dictionary = record_value
		if not bool(record.visualEligible) or excluded.has(String(record.id)) or String(record.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
			continue
		var bounds: AABB = record.worldBounds
		var closest := Vector3(clampf(camera_position.x, bounds.position.x, bounds.end.x), clampf(camera_position.y, bounds.position.y, bounds.end.y), clampf(camera_position.z, bounds.position.z, bounds.end.z))
		var offset := closest - camera_position
		var distance := offset.length()
		var angular_span := 2.0 * atan(maxf(bounds.size.x, bounds.size.y) * 0.5 / maxf(distance, 0.01))
		if distance < 1.25 and angular_span > deg_to_rad(24.0) and (distance <= 0.01 or offset.normalized().dot(forward) > -0.10):
			_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "nearCameraComposition", "reason": "near_camera_visual_volume", "selectedVisibleMember": selected_visible_member, "blockers": [_review_record_rejection_provenance(record, subject_ids)]})
			return "near_camera_visual_volume"
	return ""


func deterministic_review_part(id_prefix: String, semantic: String):
	var selected = null
	for part in blueprint.parts:
		if part == null:
			continue
		var matches := (not id_prefix.is_empty() and String(part.id).begins_with(id_prefix)) or (not semantic.is_empty() and String(part.semantic) == semantic)
		if matches and (selected == null or String(part.id) < String(selected.id)):
			selected = part
	return selected


func market_review_subject() -> Dictionary:
	var counter = deterministic_review_part("urban_market_counter_", "")
	if counter == null:
		return {"valid": false, "reason": "missing generated market counter"}
	var bounds := review_part_bounds(counter)
	for part in blueprint.parts:
		if part == null or not String(part.id).begins_with("urban_market_") or part.position.distance_to(counter.position) > 6.0:
			continue
		bounds = bounds.merge(review_part_bounds(part))
	var focus := Vector3(bounds.get_center().x, minf(bounds.end.y - 0.25, bounds.position.y + 1.55), bounds.get_center().z)
	var support := generated_support_near(focus)
	if support.is_empty():
		return {"valid": false, "reason": "generated market has no collision-backed public support"}
	return {"valid": true, "focus": focus, "minimumSupportY": float(support.topY) - 0.18, "supportId": support.id, "supportIds": [support.id], "bounds": bounds}


func civic_roof_context_part_ids() -> Array[String]:
	var ids: Array[String] = ["urban_civic_banner", "urban_civic_recess_118", "urban_civic_recess_42", "urban_civic_recess_80", "urban_civic_roof_bearing_-1", "urban_civic_roof_bearing_1", "urban_civic_roof_eave_-1", "urban_civic_roof_eave_1", "urban_civic_roof_ridge", "urban_civic_tower"]
	for side in [-1, 1]:
		for level in range(4):
			ids.append("urban_civic_roof_gable_%d_%02d" % [side, level])
	ids.sort()
	return ids


func generated_review_subject_family(required_semantic: String, required_id_prefix: String, expected_count: int, required_visible_ids: Array, context_semantics: Array, focus_kind: String, required_context_ids: Array = []) -> Dictionary:
	if not bool(_review_visual_snapshot.get("valid", false)) or required_semantic.is_empty() or required_id_prefix.is_empty() or expected_count <= 0:
		return {"valid": false, "reason": "invalid_generated_subject_family_request"}
	var subject_ids: Array[String] = []
	var context_ids: Array[String] = []
	var by_id: Dictionary = _review_visual_snapshot.get("byId", {}) as Dictionary
	for record_value in _review_visual_snapshot.get("stableRecords", []):
		var record: Dictionary = record_value as Dictionary
		var record_id := String(record.get("id", ""))
		var semantic := String(record.get("semantic", ""))
		if semantic == required_semantic:
			if not record_id.begins_with(required_id_prefix) or not bool(record.get("visualEligible", false)):
				return {"valid": false, "reason": "ambiguous_generated_subject_family"}
			subject_ids.append(record_id)
		elif context_semantics.has(semantic) and bool(record.get("visualEligible", false)):
			context_ids.append(record_id)
	subject_ids.sort()
	context_ids.sort()
	if subject_ids.size() != expected_count:
		return {"valid": false, "reason": "invalid_generated_subject_family_count", "actualCount": subject_ids.size(), "expectedCount": expected_count}
	if not required_context_ids.is_empty():
		var expected_context_ids: Array = required_context_ids.duplicate()
		expected_context_ids.sort_custom(func(a, b): return String(a) < String(b))
		if context_ids != expected_context_ids:
			return {"valid": false, "reason": "invalid_generated_subject_family_context", "actualContextIds": context_ids, "expectedContextIds": expected_context_ids}
	var visible_ids: Array = required_visible_ids.duplicate()
	visible_ids.sort_custom(func(a, b): return String(a) < String(b))
	if visible_ids.is_empty():
		visible_ids = subject_ids.duplicate()
	var seen_visible: Dictionary = {}
	for id_value in visible_ids:
		var id := String(id_value)
		if id.is_empty() or seen_visible.has(id) or not subject_ids.has(id):
			return {"valid": false, "reason": "ambiguous_generated_visible_subject_family"}
		seen_visible[id] = true
	var composition_ids: Array = subject_ids.duplicate()
	for id_value in context_ids:
		if not composition_ids.has(String(id_value)):
			composition_ids.append(String(id_value))
	composition_ids.sort_custom(func(a, b): return String(a) < String(b))
	var bounds := generated_subject_bounds(subject_ids)
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return {"valid": false, "reason": "missing_generated_subject_family_bounds"}
	var required_visible_bounds := generated_subject_bounds(visible_ids)
	if required_visible_bounds.size.x <= 0.0 or required_visible_bounds.size.y <= 0.0 or required_visible_bounds.size.z <= 0.0:
		return {"valid": false, "reason": "missing_generated_visible_subject_family_bounds"}
	var focus := bounds.get_center()
	if focus_kind == "decor":
		focus = required_visible_bounds.get_center()
	elif focus_kind != "roof":
		return {"valid": false, "reason": "invalid_generated_subject_focus_kind"}
	var signature_context := {"subjectIds": subject_ids, "requiredVisiblePartIds": visible_ids, "compositionSubjectIds": composition_ids, "bounds": bounds, "requiredVisibleBounds": required_visible_bounds, "focus": focus}
	return {"valid": true, "focus": focus, "minimumSupportY": -INF, "supportIds": [], "bounds": bounds, "requiredVisibleBounds": required_visible_bounds, "requiresExactRequiredVisibleTarget": focus_kind == "decor", "subjectIds": subject_ids, "requiredVisiblePartIds": visible_ids, "visibilityPartIds": visible_ids, "compositionSubjectIds": composition_ids, "readabilityMode": "family_required_visible", "subjectRadius": generated_subject_frame_radius(bounds, 0.01), "familySignature": Marshalls.raw_to_base64(var_to_bytes(signature_context)).sha256_text()}


func green_market_tree_subject(market_subject: Dictionary) -> Dictionary:
	if not bool(market_subject.get("valid", false)):
		return {"valid": false, "reason": "market subject unavailable for deterministic tree selection"}
	var focus: Vector3 = market_subject.focus as Vector3
	var placements: Array = (blueprint.recipe.get("urbanPoc", {}) as Dictionary).get("treePlacements", []) as Array
	var selected: Dictionary = {}
	var selected_distance := INF
	for value in placements:
		if not value is Dictionary:
			continue
		var placement: Dictionary = value as Dictionary
		var position: Vector3 = placement.get("position", Vector3.INF) as Vector3
		if not position.is_finite():
			continue
		var distance := Vector2(position.x, position.z).distance_to(Vector2(focus.x, focus.z))
		if distance < selected_distance - 0.0001 or (is_equal_approx(distance, selected_distance) and String(placement.get("id", "")) < String(selected.get("id", ""))):
			selected = placement
			selected_distance = distance
	if selected.is_empty():
		return {"valid": false, "reason": "no generated tree placement near market"}
	var tree_position: Vector3 = selected.position as Vector3
	var support := generated_support_near(tree_position)
	if support.is_empty():
		return {"valid": false, "reason": "selected generated market tree has no collision-backed support"}
	return {"valid": true, "focus": tree_position + Vector3(0.0, 1.18, 0.0), "minimumSupportY": float(support.topY) - 0.18, "supportId": support.id, "supportIds": [support.id], "treeId": String(selected.get("id", ""))}


func perimeter_lane_review_subject(preferred_distance: float = 12.0, maximum_distance: float = 22.0) -> Dictionary:
	var collection := generated_perimeter_review_sources(preferred_distance, maximum_distance)
	if not bool(collection.get("valid", false)):
		return {"valid": false, "reason": String(collection.get("reason", "missing generated perimeter alley")), "sourceLimit": MAX_PERIMETER_REVIEW_SOURCES, "sourceCount": int(collection.get("sourceCount", 0))}
	var sources: Array = collection.get("sources", []) as Array
	return sources[0] if not sources.is_empty() else {"valid": false, "reason": "generated perimeter alleys have no bounded collision-clear camera domain"}


func generated_perimeter_review_sources(preferred_distance: float = 12.0, maximum_distance: float = 22.0) -> Dictionary:
	var alleys: Array = []
	for record_value in _review_visual_snapshot.get("stableRecords", []):
		var record: Dictionary = record_value
		if String(record.semantic) == "citadel_perimeter_alley":
			alleys.append(record)
	alleys.sort_custom(func(a, b): return String(a.id) < String(b.id))
	if alleys.is_empty():
		return {"valid": false, "reason": "missing_generated_perimeter_alley", "sourceCount": 0, "sources": []}
	if alleys.size() > MAX_PERIMETER_REVIEW_SOURCES:
		return {"valid": false, "reason": "perimeter_review_source_limit_exceeded", "sourceCount": alleys.size(), "sourceLimit": MAX_PERIMETER_REVIEW_SOURCES, "sources": []}
	var sources: Array[Dictionary] = []
	for alley in alleys:
		var source := perimeter_lane_review_subject_for_alley(alley, preferred_distance, maximum_distance)
		if bool(source.get("valid", false)):
			sources.append(source)
	return {"valid": not sources.is_empty(), "reason": "" if not sources.is_empty() else "generated_perimeter_sources_have_no_bounded_domain", "sourceCount": alleys.size(), "sourceLimit": MAX_PERIMETER_REVIEW_SOURCES, "sources": sources}


func perimeter_lane_review_view(maximum_distance: float, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int) -> Dictionary:
	var source_derivation_started := Time.get_ticks_usec()
	camera_source_derivation_usec = 0
	_write_camera_stage_progress("perimeter_source_derivation_begin", {}, 0)
	var collection := generated_perimeter_review_sources(preferred_distance, maximum_distance)
	camera_source_derivation_usec = Time.get_ticks_usec() - source_derivation_started
	_write_camera_stage_progress("perimeter_source_derivation_complete", {"sourceDerivationUsec": camera_source_derivation_usec}, int(collection.get("sourceCount", 0)))
	if not bool(collection.get("valid", false)):
		var failed := failed_exterior_review_view("perimeter_lane", "perimeter lane", String(collection.get("reason", "missing generated perimeter source")))
		failed["cameraSourceAttempts"] = 0
		failed["cameraSourceCount"] = int(collection.get("sourceCount", 0))
		failed["cameraSourceLimit"] = MAX_PERIMETER_REVIEW_SOURCES
		failed["cameraSourceFailureReason"] = String(collection.get("reason", "missing generated perimeter source"))
		return failed
	var sources: Array = collection.get("sources", []) as Array
	var job := begin_bounded_perimeter_review_job(sources)
	var progress := _perimeter_review_job_progress(job, 0, -1, 0)
	_write_camera_stage_progress("perimeter_review_begin", progress, sources.size())
	while not bool(progress.get("complete", false)):
		progress = advance_bounded_perimeter_review_job(job, PERIMETER_REVIEW_CANDIDATES_PER_FRAME)
		_write_camera_stage_progress("perimeter_review_complete" if bool(progress.get("complete", false)) else "perimeter_review_advance", progress, sources.size())
		if not bool(progress.get("complete", false)):
			await get_tree().process_frame
	return _perimeter_review_view_from_selection(progress.get("result", {}) as Dictionary, sources, maximum_distance, minimum_distance, preferred_distance, subject_radius, preferred_direction_index)


func select_perimeter_review_view_from_sources(source_values: Array, maximum_distance: float, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int) -> Dictionary:
	var selection := choose_bounded_perimeter_review_view(source_values)
	return _perimeter_review_view_from_selection(selection, source_values, maximum_distance, minimum_distance, preferred_distance, subject_radius, preferred_direction_index)


func _perimeter_review_view_from_selection(selection: Dictionary, source_values: Array, maximum_distance: float, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int) -> Dictionary:
	if not bool(selection.get("valid", false)):
		var aggregate: Dictionary = {}
		var examples: Array[Dictionary] = []
		for row_value in selection.get("sourceTelemetry", []):
			var row: Dictionary = row_value
			for key in row.get("rejectedCandidates", {}):
				aggregate[key] = int(aggregate.get(key, 0)) + int((row.rejectedCandidates as Dictionary).get(key, 0))
			for example_value in row.get("rejectionExamples", []):
				if examples.size() == 8:
					break
				var example: Dictionary = (example_value as Dictionary).duplicate(true)
				example["alleyId"] = String(row.get("sourceId", ""))
				examples.append(example)
		return _failed_perimeter_source_selection(String(selection.get("reason", "no_generated_perimeter_camera_pose")), int(selection.get("sourceTelemetry", []).size()), source_values.size(), aggregate, examples)
	var source: Dictionary = selection.get("selectedSource", {}) as Dictionary
	var pose: Dictionary = selection.get("pose", {}) as Dictionary
	var source_bounds: AABB = source.get("bounds", AABB()) as AABB
	var radial := generated_subject_radial_domain(source_bounds, maximum_distance, minimum_distance, preferred_distance, subject_radius)
	var view := make_exterior_review_view_from_pose("perimeter_lane", "perimeter lane", source.get("focus", Vector3.ZERO) as Vector3, float(source.get("maximumDistance", radial.maximumDistance)), pose)
	view["cameraSubjectIds"] = source.get("subjectIds", [])
	view["cameraSubjectBounds"] = source_bounds
	view["cameraCandidateDomain"] = source.get("candidateDomain", {})
	view["cameraDeclaredSupportIds"] = source.get("supportIds", [])
	view["cameraSourceAttempts"] = int(selection.get("sourceTelemetry", []).size())
	view["cameraSourceCount"] = source_values.size()
	view["cameraSourceLimit"] = MAX_PERIMETER_REVIEW_SOURCES
	view["cameraSourceAlleyId"] = String(source.get("alleyId", source.get("sourceId", "")))
	view["cameraSourceFacadeId"] = String(source.get("facadeId", ""))
	view["cameraSourceSupportIds"] = source.get("supportIds", [])
	view["cameraCompositionSourceAlleyIds"] = (source.get("compositionSourceAlleyIds", []) as Array).duplicate()
	view["cameraCompositionSubjectCount"] = int(source.get("compositionSubjectCount", 0))
	view["cameraCompositionSubjectSignature"] = String(source.get("compositionSubjectSignature", ""))
	view["cameraSourceTelemetry"] = selection.get("sourceTelemetry", [])
	return view


func _write_camera_stage_progress(stage: String, progress: Dictionary, source_count: int) -> void:
	camera_stage_progress = {"schemaVersion": 1, "stage": stage, "sourceCount": source_count, "sourceLimit": MAX_PERIMETER_REVIEW_SOURCES, "candidateLimitPerSource": MAX_REVIEW_CAMERA_CANDIDATES, "candidatesPerFrame": PERIMETER_REVIEW_CANDIDATES_PER_FRAME, "reviewVisualSnapshot": review_visual_snapshot_summary(), "sourceDerivationUsec": int(progress.get("sourceDerivationUsec", camera_source_derivation_usec)), "activeSourceIndex": int(progress.get("activeSourceIndex", -1)), "completedSourceCount": int(progress.get("completedSourceCount", 0)), "candidatesEvaluatedThisFrame": int(progress.get("candidatesEvaluated", 0)), "totalCandidatesEvaluated": int(progress.get("totalCandidatesEvaluated", 0)), "maxCandidateUsec": int(progress.get("maxCandidateUsec", 0)), "phaseTelemetry": (progress.get("phaseTelemetry", {}) as Dictionary).duplicate(true), "complete": bool(progress.get("complete", false)), "valid": bool(progress.get("valid", false))}
	if report_path.is_empty() or not report_path.is_absolute_path():
		return
	var progress_path := report_path.get_base_dir().path_join("camera-stage-progress.json")
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(camera_stage_progress, "\t"))
		file.close()


func choose_bounded_perimeter_review_view(eligible_sources: Array) -> Dictionary:
	var job := begin_bounded_perimeter_review_job(eligible_sources)
	var progress := advance_bounded_perimeter_review_job(job, MAX_REVIEW_CAMERA_CANDIDATES)
	while bool(progress.get("valid", false)) and not bool(progress.get("complete", false)):
		progress = advance_bounded_perimeter_review_job(job, MAX_REVIEW_CAMERA_CANDIDATES)
	return progress.get("result", {}) as Dictionary


func begin_bounded_perimeter_review_job(eligible_sources: Array) -> PerimeterReviewJob:
	var job := PerimeterReviewJob.new()
	job._owner_id = get_instance_id()
	job._phase_global = _empty_review_camera_phase_rows()
	job._phase_latest = _empty_review_camera_phase_rows()
	for source_value in eligible_sources:
		var source: Dictionary = source_value
		var source_binding := String(source.get("visualSnapshotBinding", ""))
		var source_epoch := int(source.get("visualSnapshotEpoch", 0))
		if source_binding.is_empty():
			continue
		if job._visual_snapshot_binding.is_empty():
			job._visual_snapshot_binding = source_binding
			job._visual_snapshot_epoch = source_epoch
		elif job._visual_snapshot_binding != source_binding or job._visual_snapshot_epoch != source_epoch:
			job._complete = true
			job._result = {"valid": false, "reason": "mixed_visual_snapshot_bindings", "sceneWorkStarted": false, "sourceTelemetry": [], "totalCandidatesEvaluated": 0}
			return job
	if eligible_sources.size() > MAX_PERIMETER_REVIEW_SOURCES:
		job._complete = true
		job._result = {"valid": false, "reason": "perimeter_review_source_cap_exceeded", "sceneWorkStarted": false, "sourceTelemetry": [], "totalCandidatesEvaluated": 0}
		return job
	if eligible_sources.is_empty():
		job._complete = true
		job._result = {"valid": false, "reason": "no_perimeter_review_source_has_valid_full_pose", "sceneWorkStarted": false, "sourceTelemetry": [], "totalCandidatesEvaluated": 0}
		return job
	job._sources = eligible_sources.duplicate(false)
	job._sources.sort_custom(func(a: Dictionary, b: Dictionary): return String(a.get("sourceId", a.get("alleyId", ""))) < String(b.get("sourceId", b.get("alleyId", ""))))
	return job


func advance_bounded_perimeter_review_job(value: Variant, max_candidates: int = 4) -> Dictionary:
	if not value is PerimeterReviewJob:
		return _perimeter_review_job_error("invalid_perimeter_review_job")
	var job: PerimeterReviewJob = value
	if job._owner_id != get_instance_id() or job._busy:
		return _perimeter_review_job_error("foreign_or_busy_perimeter_review_job")
	if max_candidates < 1 or max_candidates > MAX_REVIEW_CAMERA_CANDIDATES:
		return _perimeter_review_job_error("invalid_perimeter_review_step")
	if not job._visual_snapshot_binding.is_empty() and (job._visual_snapshot_binding != review_visual_snapshot_binding() or job._visual_snapshot_epoch != _review_visual_snapshot_epoch):
		job._error = "stale_perimeter_visual_snapshot_binding"
		job._complete = true
		job._result = {"valid": false, "reason": job._error, "sceneWorkStarted": false, "sourceTelemetry": job._telemetry.duplicate(true), "totalCandidatesEvaluated": job._total_candidates}
		job._phase_latest = _empty_review_camera_phase_rows()
		return _perimeter_review_job_progress(job, 0, job._source_index, 0)
	if job._complete:
		job._phase_latest = _empty_review_camera_phase_rows()
		return _perimeter_review_job_progress(job, 0, -1, 0)
	job._busy = true
	var evaluated := 0
	var active_source_index := job._source_index
	var maximum_candidate_usec := 0
	while job._source_index < job._sources.size():
		var source: Dictionary = job._sources[job._source_index] as Dictionary
		var candidates: Array = source.get("candidatePositions", []) as Array
		if not bool(source.get("recipeClear", true)) or candidates.is_empty() or candidates.size() > MAX_REVIEW_CAMERA_CANDIDATES:
			job._telemetry.append(_perimeter_source_telemetry(source, {}, 0, {}, "invalidRecipeOrCandidateDomain", {"phaseOrder": REVIEW_CAMERA_PHASES.duplicate(), "visitKeys": REVIEW_CAMERA_VISIT_KEYS.duplicate(), "runGlobal": _empty_review_camera_phase_rows(), "runGlobalMaxCandidateUsec": 0}))
			job._source_index += 1
			active_source_index = job._source_index
			break
		if job._active_camera_job == null:
			job._active_camera_job = _begin_perimeter_source_camera_job(source)
		active_source_index = job._source_index
		var progress := advance_exterior_review_pose(job._active_camera_job, max_candidates)
		if not bool(progress.get("valid", false)):
			job._error = String(progress.get("reason", "invalid_perimeter_source_camera_job"))
			job._complete = true
			job._result = {"valid": false, "reason": job._error, "sceneWorkStarted": job._total_candidates > 0, "sourceTelemetry": job._telemetry.duplicate(true), "totalCandidatesEvaluated": job._total_candidates}
			break
		evaluated = int(progress.get("candidatesEvaluated", 0))
		maximum_candidate_usec = int(progress.get("maxCandidateUsec", 0))
		_accumulate_perimeter_review_phase_telemetry(job, progress)
		job._total_candidates += evaluated
		if bool(progress.get("complete", false)):
			var pose: Dictionary = progress.get("pose", {}) as Dictionary
			var row := _perimeter_source_telemetry(source, pose, int(progress.get("totalCandidatesEvaluated", 0)), _current_perimeter_predicate_counts(source), _perimeter_rejected_stage(pose), progress.get("phaseTelemetry", {}) as Dictionary)
			job._telemetry.append(row)
			if bool(pose.get("ok", false)):
				job._complete = true
				job._result = {"valid": true, "reason": "", "selectedSourceId": String(source.get("sourceId", source.get("alleyId", ""))), "selectedSource": source, "pose": pose.duplicate(true), "sourceTelemetry": job._telemetry.duplicate(true), "totalCandidatesEvaluated": job._total_candidates, "sceneWorkStarted": true}
			else:
				job._source_index += 1
				job._active_camera_job = null
				if job._source_index >= job._sources.size():
					job._complete = true
					job._result = {"valid": false, "reason": "no_perimeter_review_source_has_valid_full_pose", "sceneWorkStarted": job._total_candidates > 0, "sourceTelemetry": job._telemetry.duplicate(true), "totalCandidatesEvaluated": job._total_candidates}
			break
		break
	job._busy = false
	return _perimeter_review_job_progress(job, evaluated, active_source_index, maximum_candidate_usec)


func _begin_perimeter_source_camera_job(source: Dictionary) -> ReviewCameraJob:
	if has_method("reset_predicate_counts"):
		call("reset_predicate_counts", source)
	var subject_ids: Array = source.get("subjectIds", []) as Array
	var composition_ids: Array = source.get("compositionSubjectIds", subject_ids) as Array
	var composition_error := ""
	if source.has("compositionSubjectIds"):
		var validation := validated_review_composition_subject_context(composition_ids, subject_ids)
		if not bool(validation.get("valid", false)):
			composition_error = String(validation.get("reason", "invalid_composition_subject_context"))
		elif int(source.get("compositionSubjectCount", -1)) != int(validation.count) or String(source.get("compositionSubjectSignature", "")) != String(validation.signature):
			composition_error = "composition_subject_context_telemetry_mismatch"
		else:
			composition_ids = validation.ids as Array
	var synthetic_readability: bool = has_method("chooser_subject_readability_rejection") and source.has("readabilityAllowed")
	var readability_mode := String(source.get("readabilityMode", "all"))
	var rejection := Callable(self, "chooser_subject_readability_rejection") if synthetic_readability else (Callable(self, "generated_any_subject_readability_rejection").bind(subject_ids, composition_ids, source.get("focus", Vector3.ZERO)) if readability_mode == "any" else Callable(self, "generated_subject_readability_rejection").bind(subject_ids, source.get("focus", Vector3.ZERO)))
	var visibility_ids: Array = source.get("visibilityPartIds", []) as Array
	var visibility := Callable(self, "generated_subject_visible_surface").bind(visibility_ids) if not visibility_ids.is_empty() else (Callable(self, "generated_part_visible_surface").bind(String(source.get("visibilityPartId", ""))) if not String(source.get("visibilityPartId", "")).is_empty() else Callable())
	if synthetic_readability:
		visibility = Callable(self, "_chooser_synthetic_visible_surface")
	var source_bounds: AABB = source.get("bounds", AABB()) as AABB
	var radius := float(source.get("subjectRadius", generated_subject_frame_radius(source_bounds, 2.0)))
	var job := begin_exterior_review_pose_from_candidates(source.get("focus", Vector3.ZERO) as Vector3, source.get("candidatePositions", []) as Array, radius, float(source.get("minimumSupportY", -INF)), rejection, visibility)
	for id_value in composition_ids:
		job._declared_subject_ids.append(String(id_value))
	job._visual_snapshot_binding = String(source.get("visualSnapshotBinding", ""))
	job._visual_snapshot_epoch = int(source.get("visualSnapshotEpoch", 0))
	if not composition_error.is_empty():
		job._error = composition_error
		job._complete = true
		job._pose = {"ok": false, "reason": composition_error}
	return job


func _current_perimeter_predicate_counts(source: Dictionary) -> Dictionary:
	var synthetic: bool = has_method("chooser_subject_readability_rejection") and source.has("readabilityAllowed")
	var value: Variant = get("predicate_counts") if synthetic else {}
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func _perimeter_rejected_stage(pose: Dictionary) -> String:
	if bool(pose.get("ok", false)):
		return ""
	var rejected: Dictionary = pose.get("rejectedCandidates", {}) as Dictionary
	if int(rejected.get("nearFieldComposition", 0)) > 0:
		return "nearFieldComposition"
	if int(rejected.get("subjectRequirements", 0)) > 0:
		return "subjectReadability"
	return String(pose.get("reason", "unknown"))


func _perimeter_source_telemetry(source: Dictionary, pose: Dictionary, candidates_evaluated: int, predicate_counts: Dictionary, rejected_stage: String, phase_telemetry: Dictionary) -> Dictionary:
	var rejected: Dictionary = pose.get("rejectedCandidates", {}) as Dictionary
	var frame_checked := bool(pose.get("ok", false)) or int(rejected.get("frameCoverage", 0)) > 0 or int(rejected.get("frameDominance", 0)) > 0 or int(rejected.get("nearFieldComposition", 0)) > 0 or int(rejected.get("subjectRequirements", 0)) > 0
	return {"sourceId": String(source.get("sourceId", source.get("alleyId", ""))), "poseOk": bool(pose.get("ok", false)), "candidateCount": (source.get("candidatePositions", []) as Array).size(), "candidatesEvaluated": candidates_evaluated, "rejectedStage": rejected_stage, "rejectedCandidates": rejected.duplicate(true), "rejectionExamples": pose.get("rejectionExamples", []).duplicate(true), "stageRejectionEvidence": (pose.get("stageRejectionEvidence", {}) as Dictionary).duplicate(true), "compositionSourceAlleyIds": (source.get("compositionSourceAlleyIds", []) as Array).duplicate(), "compositionSubjectCount": int(source.get("compositionSubjectCount", 0)), "compositionSubjectSignature": String(source.get("compositionSubjectSignature", "")), "predicateCounts": predicate_counts.duplicate(true), "phaseTelemetry": phase_telemetry.duplicate(true), "frameFloorChecked": frame_checked, "frameCeilingChecked": frame_checked}


func _accumulate_perimeter_review_phase_telemetry(job: PerimeterReviewJob, progress: Dictionary) -> void:
	job._phase_latest = _empty_review_camera_phase_rows()
	var telemetry: Dictionary = progress.get("phaseTelemetry", {}) as Dictionary
	var latest: Dictionary = telemetry.get("latestAdvance", {}) as Dictionary
	for phase_value in REVIEW_CAMERA_PHASES:
		var phase := String(phase_value)
		var source_row: Dictionary = latest.get(phase, {}) as Dictionary
		var latest_row: Dictionary = job._phase_latest.get(phase, {}) as Dictionary
		var global_row: Dictionary = job._phase_global.get(phase, {}) as Dictionary
		latest_row["count"] = int(source_row.get("count", 0))
		latest_row["totalUsec"] = int(source_row.get("totalUsec", 0))
		latest_row["maxUsec"] = int(source_row.get("maxUsec", 0))
		global_row["count"] = int(global_row.get("count", 0)) + int(source_row.get("count", 0))
		global_row["totalUsec"] = int(global_row.get("totalUsec", 0)) + int(source_row.get("totalUsec", 0))
		global_row["maxUsec"] = maxi(int(global_row.get("maxUsec", 0)), int(source_row.get("maxUsec", 0)))
		var latest_visits: Dictionary = latest_row.get("visits", {}) as Dictionary
		var global_visits: Dictionary = global_row.get("visits", {}) as Dictionary
		var source_visits: Dictionary = source_row.get("visits", {}) as Dictionary
		for visit_value in REVIEW_CAMERA_VISIT_KEYS:
			var visit := String(visit_value)
			latest_visits[visit] = int(source_visits.get(visit, 0))
			global_visits[visit] = int(global_visits.get(visit, 0)) + int(source_visits.get(visit, 0))
		latest_row["visits"] = latest_visits
		global_row["visits"] = global_visits
		job._phase_latest[phase] = latest_row
		job._phase_global[phase] = global_row
	job._global_max_candidate_usec = maxi(job._global_max_candidate_usec, int(telemetry.get("runGlobalMaxCandidateUsec", 0)))


func _perimeter_review_job_progress(job: PerimeterReviewJob, evaluated: int, source_index: int, maximum_candidate_usec: int) -> Dictionary:
	return {"valid": job._error.is_empty(), "complete": job._complete, "candidatesEvaluated": evaluated, "totalCandidatesEvaluated": job._total_candidates, "activeSourceIndex": source_index, "completedSourceCount": job._telemetry.size(), "sourceTelemetry": job._telemetry.duplicate(true), "maxCandidateUsec": maximum_candidate_usec, "phaseTelemetry": {"phaseOrder": REVIEW_CAMERA_PHASES.duplicate(), "visitKeys": REVIEW_CAMERA_VISIT_KEYS.duplicate(), "latestAdvance": job._phase_latest.duplicate(true), "runGlobal": job._phase_global.duplicate(true), "runGlobalMaxCandidateUsec": job._global_max_candidate_usec}, "result": job._result.duplicate(true)}


func _perimeter_review_job_error(reason: String) -> Dictionary:
	return {"valid": false, "complete": true, "reason": reason, "candidatesEvaluated": 0, "totalCandidatesEvaluated": 0, "activeSourceIndex": -1, "completedSourceCount": 0, "sourceTelemetry": [], "maxCandidateUsec": 0, "result": {"valid": false, "reason": reason}}


func _chooser_synthetic_visible_surface(_camera_position: Vector3) -> Vector3:
	return Vector3(0.25, 1.58, 0.5)


func _failed_perimeter_source_selection(reason: String, attempts: int, source_count: int, aggregate: Dictionary, examples: Array) -> Dictionary:
	var failed := failed_exterior_review_view("perimeter_lane", "perimeter lane", reason)
	failed["cameraPoseRejections"] = aggregate.duplicate(true)
	failed["cameraPoseRejectionExamples"] = examples.duplicate(true)
	failed["cameraSourceAttempts"] = attempts
	failed["cameraSourceCount"] = source_count
	failed["cameraSourceLimit"] = MAX_PERIMETER_REVIEW_SOURCES
	failed["cameraSourceFailureReason"] = reason
	return failed


func perimeter_lane_review_subject_for_alley(alley, preferred_distance: float = 12.0, maximum_distance: float = 22.0) -> Dictionary:
	var alley_bounds := review_part_bounds(alley)
	var facade: Dictionary = generated_perimeter_adjacent_facade(alley)
	if facade.is_empty():
		return {"valid": false, "reason": "generated perimeter alley has no adjacent facade"}
	var facade_bounds := review_part_bounds(facade)
	var focus := Vector3((alley_bounds.get_center().x + facade_bounds.get_center().x) * 0.5, minf(facade_bounds.end.y - 0.25, facade_bounds.position.y + 2.8), (alley_bounds.get_center().z + facade_bounds.get_center().z) * 0.5)
	var support := generated_support_under_bounds(alley_bounds)
	if support.is_empty():
		return {"valid": false, "reason": "generated perimeter alley has no collision-backed support"}
	var support_record: Dictionary = (_review_visual_snapshot.get("byId", {}) as Dictionary).get(String(support.id), {}) as Dictionary
	if support_record.is_empty():
		return {"valid": false, "reason": "generated perimeter support is absent from bound snapshot"}
	var support_part: Dictionary = support_record
	var support_bounds := review_part_bounds(support_part)
	var local_candidates := perimeter_recipe_clear_candidates(longitudinal_candidate_positions(alley, support_part))
	if local_candidates.is_empty():
		return {"valid": false, "reason": "generated perimeter alley has no bounded supported camera domain"}
	var facade_family := generated_perimeter_facade_family(facade, facade_bounds)
	if facade_family.is_empty():
		return {"valid": false, "reason": "generated perimeter facade has no published visual family"}
	var family_bounds := generated_subject_bounds(facade_family).merge(alley_bounds)
	var radial := generated_subject_radial_domain(family_bounds, maximum_distance, 4.8, preferred_distance, 3.2)
	var domain := aligned_perimeter_candidate_domain(alley, focus, float(radial.preferredDistance), float(radial.maximumDistance), facade_family)
	if not bool(domain.get("valid", false)):
		return {"valid": false, "reason": String(domain.get("reason", "invalid aligned perimeter composition context"))}
	var candidates: Array = domain.get("candidates", []) as Array
	if candidates.is_empty():
		return {"valid": false, "reason": "generated perimeter alley has no aligned bounded supported camera domain"}
	var support_ids: Array = domain.get("supportIds", [support.id]) as Array
	return {"valid": true, "visualSnapshotBinding": review_visual_snapshot_binding(), "visualSnapshotEpoch": _review_visual_snapshot_epoch, "focus": focus, "minimumSupportY": float(domain.get("minimumSupportY", float(support.topY) - 0.18)), "supportId": support.id, "supportIds": support_ids, "alleyId": alley.id, "facadeId": facade.id, "visibilityPartIds": facade_family, "subjectIds": facade_family, "compositionSourceAlleyIds": (domain.compositionSourceAlleyIds as Array).duplicate(), "compositionSubjectIds": (domain.compositionSubjectIds as Array).duplicate(), "compositionSubjectCount": int(domain.compositionSubjectCount), "compositionSubjectSignature": String(domain.compositionSubjectSignature), "readabilityMode": "any", "bounds": family_bounds, "subjectRadius": radial.subjectRadius, "maximumDistance": radial.maximumDistance, "candidatePositions": candidates, "candidateDomain": {"type": "aligned_generated_perimeter_supports", "count": candidates.size(), "preferredDistance": radial.preferredDistance, "maximumDistance": radial.maximumDistance, "sourceAlleyCount": int(domain.get("sourceAlleyCount", 0)), "alleyBounds": alley_bounds, "supportBounds": support_bounds}}


func generated_perimeter_adjacent_facade(alley) -> Dictionary:
	if alley == null:
		return {}
	var facade: Dictionary = {}
	var best_distance := INF
	for record_value in _review_visual_snapshot.get("records", []):
		var record: Dictionary = record_value
		if not String(record.id).begins_with("urban_perimeter_") or not bool(record.collisionEnabled) or String(record.kind) != "wall" or String(record.semantic) not in ["citadel_urban_facade", "citadel_urban_stone_base"]:
			continue
		var distance := Vector2(record.position.x, record.position.z).distance_to(Vector2(alley.position.x, alley.position.z))
		if distance < best_distance - 0.0001 or (is_equal_approx(distance, best_distance) and (facade.is_empty() or String(record.id) < String(facade.id))):
			facade = record
			best_distance = distance
	return facade


func generated_perimeter_facade_family(facade, facade_bounds: AABB) -> Array[String]:
	var result: Array[String] = []
	if not bool(_review_visual_snapshot.get("valid", false)) or facade == null:
		return result
	var neighborhood := facade_bounds.grow(1.50)
	var query := review_visual_snapshot_candidates(neighborhood, true, review_visual_snapshot_binding())
	if not bool(query.get("valid", false)):
		return result
	for record_value in query.get("records", []):
		var record: Dictionary = record_value
		if not bool(record.visualEligible) or not String(record.id).begins_with("urban_perimeter_") or String(record.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
			continue
		result.append(String(record.id))
	if String(facade.id) not in result:
		result.append(String(facade.id))
	result.sort()
	return result


func aligned_perimeter_candidate_domain(subject_alley, focus: Vector3, preferred_distance: float, maximum_distance: float, primary_subject_ids: Array = []) -> Dictionary:
	var alleys: Array = []
	for record_value in _review_visual_snapshot.get("stableRecords", []):
		var record: Dictionary = record_value
		if String(record.semantic) == "citadel_perimeter_alley":
			alleys.append(record)
	alleys.sort_custom(func(a, b): return String(a.id) < String(b.id))
	var subject_long_z: bool = subject_alley.size.z >= subject_alley.size.x
	var records: Array[Dictionary] = []
	var support_ids: Array[String] = []
	var minimum_support_y := INF
	var source_count := 0
	for candidate_alley in alleys:
		var candidate_long_z: bool = candidate_alley.size.z >= candidate_alley.size.x
		if candidate_long_z != subject_long_z:
			continue
		var lateral_delta := absf(candidate_alley.position.x - subject_alley.position.x) if subject_long_z else absf(candidate_alley.position.z - subject_alley.position.z)
		var lateral_span := maxf(subject_alley.size.x, candidate_alley.size.x) if subject_long_z else maxf(subject_alley.size.z, candidate_alley.size.z)
		if lateral_delta > lateral_span * 0.75:
			continue
		var candidate_bounds := review_part_bounds(candidate_alley)
		var candidate_support := generated_support_under_bounds(candidate_bounds)
		if candidate_support.is_empty():
			continue
		var support_record: Dictionary = (_review_visual_snapshot.get("byId", {}) as Dictionary).get(String(candidate_support.id), {}) as Dictionary
		var candidate_support_part: Dictionary = support_record
		if candidate_support_part.is_empty():
			continue
		var supported := perimeter_recipe_clear_candidates(longitudinal_candidate_positions(candidate_alley, candidate_support_part))
		if supported.is_empty():
			continue
		source_count += 1
		var support_id := String(candidate_support.id)
		if support_id not in support_ids:
			support_ids.append(support_id)
		minimum_support_y = minf(minimum_support_y, float(candidate_support.topY) - 0.18)
		for candidate_value in supported:
			var candidate: Vector3 = candidate_value
			var distance := Vector2(candidate.x, candidate.z).distance_to(Vector2(focus.x, focus.z))
			if distance <= maximum_distance + 0.001:
				records.append({"position": candidate, "fitness": absf(distance - preferred_distance), "alleyId": String(candidate_alley.id)})
	records.sort_custom(func(a: Dictionary, b: Dictionary):
		var fitness_delta := float(a.fitness) - float(b.fitness)
		if absf(fitness_delta) > 0.0001:
			return fitness_delta < 0.0
		var a_position: Vector3 = a.position
		var b_position: Vector3 = b.position
		return "%0.4f:%0.4f:%0.4f" % [a_position.x, a_position.y, a_position.z] < "%0.4f:%0.4f:%0.4f" % [b_position.x, b_position.y, b_position.z])
	var candidates: Array[Vector3] = []
	var selected_keys: Dictionary = {}
	var contributor_sets_by_key: Dictionary = {}
	for record in records:
		var position: Vector3 = record.position
		var key := "%0.4f:%0.4f:%0.4f" % [position.x, position.y, position.z]
		if selected_keys.has(key):
			var existing_contributors: Dictionary = contributor_sets_by_key.get(key, {}) as Dictionary
			existing_contributors[String(record.alleyId)] = true
			contributor_sets_by_key[key] = existing_contributors
			continue
		if candidates.size() == MAX_REVIEW_CAMERA_CANDIDATES:
			continue
		selected_keys[key] = true
		var initial_contributors: Dictionary = {}
		initial_contributors[String(record.alleyId)] = true
		contributor_sets_by_key[key] = initial_contributors
		candidates.append(position)
	var selected_alley_set: Dictionary = {}
	for contributor_set_value in contributor_sets_by_key.values():
		var contributor_set: Dictionary = contributor_set_value
		for alley_id_value in contributor_set.keys():
			selected_alley_set[String(alley_id_value)] = true
	var selected_alley_ids: Array = selected_alley_set.keys()
	selected_alley_ids.sort()
	var by_id: Dictionary = _review_visual_snapshot.get("byId", {}) as Dictionary
	var composition_subject_set: Dictionary = {}
	for primary_id_value in primary_subject_ids:
		composition_subject_set[String(primary_id_value)] = true
	for alley_id_value in selected_alley_ids:
		var candidate_alley: Dictionary = by_id.get(String(alley_id_value), {}) as Dictionary
		if candidate_alley.is_empty():
			return {"valid": false, "reason": "selected_perimeter_candidate_missing_alley_source", "candidates": []}
		var candidate_facade := generated_perimeter_adjacent_facade(candidate_alley)
		if candidate_facade.is_empty():
			return {"valid": false, "reason": "aligned_perimeter_alley_missing_adjacent_facade", "candidates": []}
		var candidate_family := generated_perimeter_facade_family(candidate_facade, review_part_bounds(candidate_facade))
		if candidate_family.is_empty():
			return {"valid": false, "reason": "aligned_perimeter_facade_missing_visual_family", "candidates": []}
		for id_value in candidate_family:
			composition_subject_set[String(id_value)] = true
	var composition_ids: Array = composition_subject_set.keys()
	composition_ids.sort()
	var composition_validation := validated_review_composition_subject_context(composition_ids, primary_subject_ids)
	if not bool(composition_validation.get("valid", false)):
		return {"valid": false, "reason": String(composition_validation.get("reason", "invalid_composition_subject_context")), "candidates": []}
	return {"valid": true, "candidates": candidates, "supportIds": support_ids, "minimumSupportY": minimum_support_y, "sourceAlleyCount": source_count, "compositionSourceAlleyIds": selected_alley_ids, "compositionSubjectIds": composition_validation.ids, "compositionSubjectCount": composition_validation.count, "compositionSubjectSignature": composition_validation.signature}


func validated_review_composition_subject_context(values: Array, primary_subject_ids: Array) -> Dictionary:
	if values.is_empty() or primary_subject_ids.is_empty() or values.size() > MAX_PERIMETER_COMPOSITION_SUBJECTS:
		return {"valid": false, "reason": "empty_or_oversized_composition_subject_context"}
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for id_value in values:
		var id := String(id_value)
		if id.is_empty() or seen.has(id):
			return {"valid": false, "reason": "invalid_or_duplicate_composition_subject_id"}
		seen[id] = true
		ids.append(id)
	var sorted_ids: Array[String] = ids.duplicate()
	sorted_ids.sort()
	if ids != sorted_ids:
		return {"valid": false, "reason": "nondeterministic_composition_subject_order"}
	for primary_id_value in primary_subject_ids:
		if not seen.has(String(primary_id_value)):
			return {"valid": false, "reason": "composition_subject_context_missing_primary_family"}
	var by_id: Dictionary = _review_visual_snapshot.get("byId", {}) as Dictionary
	for id in ids:
		var record: Dictionary = by_id.get(id, {}) as Dictionary
		if record.is_empty() or not bool(record.get("visualEligible", false)):
			return {"valid": false, "reason": "composition_subject_context_missing_snapshot_member"}
	var signature := JSON.stringify(ids).sha256_text()
	return {"valid": true, "reason": "", "ids": ids, "count": ids.size(), "signature": signature}


func perimeter_recipe_clear_candidates(candidates: Array[Vector3]) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for candidate in candidates:
		var feet := candidate + Vector3(0.0, 0.055, 0.0)
		var blocked := false
		var envelope := AABB(feet + Vector3(-0.24, 0.0, -0.24), Vector3(0.48, 1.62, 0.48))
		var query := review_visual_snapshot_candidates(envelope, false, review_visual_snapshot_binding())
		if not bool(query.get("valid", false)):
			return []
		for record_value in query.get("records", []):
			var record: Dictionary = record_value
			if not bool(record.collisionEnabled):
				continue
			var bounds: AABB = record.worldBounds
			if String(record.kind) in ["foundation", "floor", "ground_patch", "ramp", "stair_tread"] and bounds.end.y <= feet.y + 0.08:
				continue
			if review_record_intersects_capsule(record, feet, 0.24, 1.62):
				blocked = true
				break
		if not blocked:
			result.append(candidate)
	return result


func longitudinal_candidate_positions(alley, support_part) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var inset := 0.30
	if alley == null or support_part == null or alley.size.x <= inset * 2.0 or alley.size.z <= inset * 2.0:
		return result
	var alley_transform := Transform3D(Basis.from_euler(alley.rotation), alley.position)
	var support_inverse := Transform3D(Basis.from_euler(support_part.rotation), support_part.position).affine_inverse()
	var support_half: Vector3 = support_part.size * 0.5
	for longitudinal_index in range(16):
		var local_z := lerpf(-alley.size.z * 0.5 + inset, alley.size.z * 0.5 - inset, float(longitudinal_index) / 15.0)
		for lateral_index in range(4):
			var local_x := lerpf(-alley.size.x * 0.5 + inset, alley.size.x * 0.5 - inset, float(lateral_index) / 3.0)
			var candidate := alley_transform * Vector3(local_x, alley.size.y * 0.5, local_z)
			var support_local := support_inverse * candidate
			if absf(support_local.x) > support_half.x - inset or absf(support_local.z) > support_half.z - inset:
				continue
			result.append(candidate)
	return result


func generated_support_under_bounds(subject_bounds: AABB) -> Dictionary:
	var selected: Dictionary = {}
	var selected_overlap := 0.0
	var subject_footprint := AABB(Vector3(subject_bounds.position.x, 0.0, subject_bounds.position.z), Vector3(subject_bounds.size.x, 0.01, subject_bounds.size.z))
	for record_value in _review_visual_snapshot.get("records", []):
		var record: Dictionary = record_value
		if not bool(record.collisionEnabled) or String(record.kind) not in ["foundation", "stair_tread"]:
			continue
		var bounds: AABB = record.worldBounds
		if bounds.end.y > subject_bounds.position.y + 0.08:
			continue
		var footprint := AABB(Vector3(bounds.position.x, 0.0, bounds.position.z), Vector3(bounds.size.x, 0.01, bounds.size.z))
		if not footprint.intersects(subject_footprint):
			continue
		var overlap := footprint.intersection(subject_footprint)
		var overlap_area := overlap.size.x * overlap.size.z
		var subject_area := subject_footprint.size.x * subject_footprint.size.z
		if subject_area <= 0.0 or overlap_area < subject_area * 0.95:
			continue
		if overlap_area > selected_overlap + 0.0001 or (is_equal_approx(overlap_area, selected_overlap) and (selected.is_empty() or String(record.id) < String(selected.id))):
			selected = {"id": String(record.id), "topY": bounds.end.y, "overlapArea": overlap_area}
			selected_overlap = overlap_area
	return selected


func generated_support_near(point: Vector3) -> Dictionary:
	var selected: Dictionary = {}
	var selected_score := INF
	for record_value in _review_visual_snapshot.get("records", []):
		var record: Dictionary = record_value
		if not bool(record.collisionEnabled) or String(record.kind) not in ["foundation", "stair_tread"]:
			continue
		var bounds: AABB = record.worldBounds
		if bounds.end.y > point.y + 0.35:
			continue
		var nearest_x := clampf(point.x, bounds.position.x, bounds.end.x)
		var nearest_z := clampf(point.z, bounds.position.z, bounds.end.z)
		var distance := Vector2(point.x, point.z).distance_to(Vector2(nearest_x, nearest_z))
		var score := distance * 1000.0 + maxf(0.0, point.y - bounds.end.y)
		if score < selected_score - 0.0001 or (is_equal_approx(score, selected_score) and (selected.is_empty() or String(record.id) < String(selected.id))):
			selected = {"id": String(record.id), "topY": bounds.end.y, "distance": distance}
			selected_score = score
	return selected if not selected.is_empty() and float(selected.distance) <= 4.0 else {}


func select_tree_contact_view() -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	tree_contact_diagnostics = {"treeCount": generated_tree_positions.size(), "directionSamples": 0, "rejections": {"missingPaving": 0, "blockedPaving": 0, "cameraPose": 0, "physicsSightline": 0, "visualSightline": 0}, "acceptedCameraPoses": 0, "examples": []}
	for tree_index in range(generated_tree_positions.size()):
		var tree := generated_tree_positions[tree_index]
		for direction_index in range(8):
			tree_contact_diagnostics["directionSamples"] = int(tree_contact_diagnostics.get("directionSamples", 0)) + 1
			var direction := Vector3(cos(float(direction_index) * TAU / 8.0), 0.0, sin(float(direction_index) * TAU / 8.0))
			var shaded := nearest_paving_position(tree + direction * 2.1)
			var open := nearest_paving_position(tree + direction * 6.2)
			if shaded == Vector3.INF or open == Vector3.INF or shaded.distance_to(open) < 2.4:
				record_tree_contact_rejection("missingPaving", tree_index, direction_index)
				continue
			if not paving_sample_is_visually_clear(shaded) or not paving_sample_is_visually_clear(open):
				record_tree_contact_rejection("blockedPaving", tree_index, direction_index)
				continue
			var target := tree.lerp((shaded + open) * 0.5, 0.54) + Vector3(0.0, 0.72, 0.0)
			var found_camera_pose := false
			for camera_index in range(8):
				var pose := solve_exterior_review_pose(target, 4.8, 7.4, 2.5, camera_index * 2, -INF)
				if not bool(pose.get("ok", false)):
					record_tree_contact_rejection("cameraPose", tree_index, direction_index)
					continue
				found_camera_pose = true
				var camera: Vector3 = pose.get("cameraPosition", Vector3.ZERO) as Vector3
				if not review_line_is_clear(camera, tree + Vector3(0.0, 1.0, 0.0)) or not review_line_is_clear(camera, open + Vector3(0.0, 0.06, 0.0)):
					record_tree_contact_rejection("physicsSightline", tree_index, direction_index)
					continue
				if not review_visual_line_is_clear(camera, tree + Vector3(0.0, 1.0, 0.0)) or not review_visual_line_is_clear(camera, open + Vector3(0.0, 0.06, 0.0)):
					record_tree_contact_rejection("visualSightline", tree_index, direction_index)
					continue
				tree_contact_diagnostics["acceptedCameraPoses"] = int(tree_contact_diagnostics.get("acceptedCameraPoses", 0)) + 1
				var score := shaded.distance_to(tree) * -1.0 + open.distance_to(tree) + shaded.distance_to(open)
				if score > best_score:
					best_score = score
					best = {"id": "tree_contact_paving", "subject": "tree canopy paving transition", "position": camera, "target": target, "maxDistance": 16.0, "requiresClear": true, "cameraPoseOk": true, "cameraPoseSupport": pose.get("supportPosition", Vector3.ZERO), "cameraPoseFrameFraction": pose.get("subjectFrameFraction", 0.0)}
			if not found_camera_pose:
				record_tree_contact_rejection("cameraPose", tree_index, direction_index)
	return best


func record_tree_contact_rejection(reason: String, tree_index: int, direction_index: int) -> void:
	var rejections: Dictionary = tree_contact_diagnostics.get("rejections", {}) as Dictionary
	rejections[reason] = int(rejections.get(reason, 0)) + 1
	tree_contact_diagnostics["rejections"] = rejections
	var examples: Array = tree_contact_diagnostics.get("examples", []) as Array
	if examples.size() < 12:
		examples.append({"reason": reason, "treeIndex": tree_index, "directionIndex": direction_index})
		tree_contact_diagnostics["examples"] = examples


func nearest_paving_position(point: Vector3) -> Vector3:
	var nearest := Vector3.INF
	var distance_squared := INF
	if blueprint == null:
		return nearest
	for part in blueprint.parts:
		if not is_primary_review_paving(part):
			continue
		var half: Vector3 = part.size * 0.5
		var candidate := Vector3(
			clampf(point.x, part.position.x - half.x, part.position.x + half.x),
			part.position.y + half.y + 0.04,
			clampf(point.z, part.position.z - half.z, part.position.z + half.z)
		)
		var candidate_distance := Vector2(candidate.x - point.x, candidate.z - point.z).length_squared()
		if candidate_distance < distance_squared and candidate_distance <= 30.25:
			distance_squared = candidate_distance
			nearest = candidate
	return nearest


func is_primary_review_paving(part) -> bool:
	if part == null or String(part.kind) != "foundation" or String(part.material_id) not in ["cobblestone", "worn_cobble"]:
		return false
	return String(part.semantic) in ["castle_courtyard_paving", "citadel_market_plaza", "citadel_perimeter_alley"]


func paving_sample_is_visually_clear(point: Vector3) -> bool:
	if blueprint == null:
		return false
	var sample_bounds := AABB(point - Vector3(0.72, 0.02, 0.72), Vector3(1.44, 2.40, 1.44))
	for part in blueprint.parts:
		if part == null or String(part.kind) in ["foundation", "floor", "ground_patch", "ramp", "stair_tread"]:
			continue
		if not bool(part.recipe.get("visual", true)):
			continue
		if review_part_bounds(part).intersects(sample_bounds):
			return false
	return true


func find_part_position(id_prefix: String) -> Vector3:
	if blueprint == null:
		return Vector3.ZERO
	for part in blueprint.parts:
		if part != null and String(part.id).begins_with(id_prefix):
			return part.position
	return Vector3.ZERO


## Opaque, single-runner camera job. Advance only on the main/physics-owning
## thread against a stable publication; yielding does not snapshot scene physics.
class ReviewCameraJob extends RefCounted:
	var _owner_id: int = 0
	var _visual_snapshot_binding: String = ""
	var _visual_snapshot_epoch: int = 0
	var _target: Vector3
	var _minimum_support_y: float
	var _subject_radius: float
	var _preferred_direction_index: int
	var _directions: Array[Vector3] = []
	var _distances: Array = []
	var _candidate_positions: Array[Vector3] = []
	var _candidate_rejection: Callable
	var _visibility_target: Callable
	var _requires_candidate_callback: bool = false
	var _requires_visibility_callback: bool = false
	var _uses_bounded_surface_probe: bool = false
	var _cursor: int = 0
	var _busy: bool = false
	var _complete: bool = false
	var _error: String = ""
	var _pose: Dictionary = {}
	var _rejected: Dictionary = {"support": 0, "capsule": 0, "visualVolume": 0, "nearFieldComposition": 0, "physicsSightline": 0, "visualSightline": 0, "frameCoverage": 0, "frameDominance": 0}
	var _examples: Array[Dictionary] = []
	var _phase_global: Dictionary = {}
	var _phase_latest: Dictionary = {}
	var _global_max_candidate_usec: int = 0
	var _declared_subject_ids: Array[String] = []
	var _stage_rejection_evidence: Dictionary = {"visualVolume": [], "nearFieldComposition": [], "subjectRequirements": []}


class PerimeterReviewJob extends RefCounted:
	var _owner_id: int = 0
	var _visual_snapshot_binding: String = ""
	var _visual_snapshot_epoch: int = 0
	var _sources: Array = []
	var _source_index: int = 0
	var _active_camera_job: Variant
	var _telemetry: Array[Dictionary] = []
	var _total_candidates: int = 0
	var _busy: bool = false
	var _complete: bool = false
	var _error: String = ""
	var _result: Dictionary = {}
	var _phase_global: Dictionary = {}
	var _phase_latest: Dictionary = {}
	var _global_max_candidate_usec: int = 0


func make_exterior_review_view(id: String, subject: String, target: Vector3, maximum_distance: float, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int, minimum_support_y := -INF, candidate_rejection: Callable = Callable(), visibility_target: Callable = Callable()) -> Dictionary:
	var pose := solve_exterior_review_pose(target, minimum_distance, preferred_distance, subject_radius, preferred_direction_index, minimum_support_y, candidate_rejection, visibility_target)
	return make_exterior_review_view_from_pose(id, subject, target, maximum_distance, pose)


func make_exterior_review_view_from_pose(id: String, subject: String, target: Vector3, maximum_distance: float, pose: Dictionary) -> Dictionary:
	var view := {
		"id": id,
		"subject": subject,
		"position": pose.get("cameraPosition", Vector3.ZERO),
		"target": target,
		"maxDistance": maximum_distance,
		"requiresClear": true,
		"cameraPoseOk": bool(pose.get("ok", false)),
		"cameraPoseReason": String(pose.get("reason", "")),
		"cameraPoseSupport": pose.get("supportPosition", Vector3.ZERO),
		"cameraPoseRejections": pose.get("rejectedCandidates", {}),
		"cameraPoseRejectionExamples": pose.get("rejectionExamples", []),
		"cameraPoseFrameFraction": float(pose.get("subjectFrameFraction", 0.0))
	}
	if pose.has("sightlineTarget") and bool(pose.get("ok", false)):
		view["cameraPoseSightlineTarget"] = pose.sightlineTarget
	return view


func solve_exterior_review_pose(target: Vector3, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int, minimum_support_y: float, candidate_rejection: Callable = Callable(), visibility_target: Callable = Callable()) -> Dictionary:
	var job := begin_exterior_review_pose(target, minimum_distance, preferred_distance, subject_radius, preferred_direction_index, minimum_support_y, candidate_rejection, visibility_target)
	var progress := advance_exterior_review_pose(job, 64)
	return progress.pose


func solve_exterior_review_pose_from_candidates(target: Vector3, candidate_positions: Array, subject_radius: float, minimum_support_y: float, candidate_rejection: Callable = Callable(), visibility_target: Callable = Callable()) -> Dictionary:
	var job := begin_exterior_review_pose_from_candidates(target, candidate_positions, subject_radius, minimum_support_y, candidate_rejection, visibility_target)
	var progress := advance_exterior_review_pose(job, 64)
	return progress.pose


func begin_exterior_review_pose(target: Vector3, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int, minimum_support_y: float, candidate_rejection: Callable = Callable(), visibility_target: Callable = Callable()) -> ReviewCameraJob:
	var job := ReviewCameraJob.new()
	_initialize_review_camera_phase_telemetry(job)
	job._owner_id = get_instance_id()
	job._target = target
	job._minimum_support_y = minimum_support_y
	job._subject_radius = subject_radius
	job._preferred_direction_index = preferred_direction_index
	job._candidate_rejection = candidate_rejection
	job._visibility_target = visibility_target
	job._requires_candidate_callback = candidate_rejection.is_valid()
	job._requires_visibility_callback = visibility_target.is_valid()
	for direction_index in range(16):
		var angle := TAU * float(direction_index) / 16.0
		job._directions.append(Vector3(sin(angle), 0.0, -cos(angle)))
	job._distances = [preferred_distance, minimum_distance, lerpf(minimum_distance, preferred_distance, 0.30), lerpf(minimum_distance, preferred_distance, 0.64)]
	for distance in job._distances:
		for candidate_index in range(16):
			var direction_index: int = int(posmod(preferred_direction_index + candidate_index, job._directions.size()))
			job._candidate_positions.append(target + (job._directions[direction_index] as Vector3).normalized() * float(distance))
	return job


func begin_exterior_review_pose_from_candidates(target: Vector3, candidate_positions: Array, subject_radius: float, minimum_support_y: float, candidate_rejection: Callable = Callable(), visibility_target: Callable = Callable()) -> ReviewCameraJob:
	var job := ReviewCameraJob.new()
	_initialize_review_camera_phase_telemetry(job)
	job._owner_id = get_instance_id()
	job._target = target
	job._minimum_support_y = minimum_support_y
	job._subject_radius = subject_radius
	job._candidate_rejection = candidate_rejection
	job._visibility_target = visibility_target
	job._requires_candidate_callback = candidate_rejection.is_valid()
	job._requires_visibility_callback = visibility_target.is_valid()
	job._uses_bounded_surface_probe = true
	if candidate_positions.is_empty() or candidate_positions.size() > 64:
		job._error = "invalid_camera_candidate_domain"
		job._complete = true
		job._pose = {"ok": false, "reason": job._error}
		return job
	for value in candidate_positions:
		if not value is Vector3 or not value.is_finite():
			job._error = "invalid_camera_candidate_domain"
			job._complete = true
			job._pose = {"ok": false, "reason": job._error}
			return job
		job._candidate_positions.append(value)
	return job


func _initialize_review_camera_phase_telemetry(job: ReviewCameraJob) -> void:
	job._phase_global = _empty_review_camera_phase_rows()
	job._phase_latest = _empty_review_camera_phase_rows()


func _empty_review_camera_phase_rows() -> Dictionary:
	var rows: Dictionary = {}
	for phase_value in REVIEW_CAMERA_PHASES:
		var visits: Dictionary = {}
		for visit_value in REVIEW_CAMERA_VISIT_KEYS:
			visits[String(visit_value)] = 0
		rows[String(phase_value)] = {"count": 0, "totalUsec": 0, "maxUsec": 0, "visits": visits}
	return rows


func _begin_review_camera_phase(job: ReviewCameraJob, phase: String) -> int:
	_active_camera_telemetry_job = job
	_active_camera_telemetry_phase = phase
	return Time.get_ticks_usec()


func _finish_review_camera_phase(job: ReviewCameraJob, phase: String, started_usec: int) -> void:
	var elapsed_usec := maxi(0, Time.get_ticks_usec() - started_usec)
	for rows_value in [job._phase_latest, job._phase_global]:
		var rows: Dictionary = rows_value
		var row: Dictionary = rows.get(phase, {}) as Dictionary
		row["count"] = int(row.get("count", 0)) + 1
		row["totalUsec"] = int(row.get("totalUsec", 0)) + elapsed_usec
		row["maxUsec"] = maxi(int(row.get("maxUsec", 0)), elapsed_usec)
		rows[phase] = row
	_active_camera_telemetry_job = null
	_active_camera_telemetry_phase = ""


func _review_camera_phase_visit(kind: String, amount: int = 1) -> void:
	if not _active_camera_telemetry_job is ReviewCameraJob or _active_camera_telemetry_phase.is_empty() or kind not in REVIEW_CAMERA_VISIT_KEYS:
		return
	var job: ReviewCameraJob = _active_camera_telemetry_job
	for rows_value in [job._phase_latest, job._phase_global]:
		var rows: Dictionary = rows_value
		var row: Dictionary = rows.get(_active_camera_telemetry_phase, {}) as Dictionary
		var visits: Dictionary = row.get("visits", {}) as Dictionary
		visits[kind] = int(visits.get(kind, 0)) + amount
		row["visits"] = visits
		rows[_active_camera_telemetry_phase] = row


func _review_record_rejection_provenance(record: Dictionary, subject_ids: Array = []) -> Dictionary:
	var id := String(record.get("id", ""))
	return {"blockerId": id, "sourceOrdinal": int(record.get("sourceOrdinal", -1)), "kind": String(record.get("kind", "")), "semantic": String(record.get("semantic", "")), "bounds": record.get("worldBounds", AABB()), "belongsToDeclaredSubjectFamily": id in subject_ids}


func _append_review_stage_rejection_evidence(stage: String, row: Dictionary) -> void:
	if not _active_camera_telemetry_job is ReviewCameraJob or stage not in ["visualVolume", "nearFieldComposition", "subjectRequirements"]:
		return
	var job: ReviewCameraJob = _active_camera_telemetry_job
	var rows: Array = job._stage_rejection_evidence.get(stage, []) as Array
	if rows.size() >= MAX_REVIEW_STAGE_REJECTION_EVIDENCE:
		return
	rows.append(row.duplicate(true))
	job._stage_rejection_evidence[stage] = rows


func _active_review_declared_subject_ids() -> Array:
	if _active_camera_telemetry_job is ReviewCameraJob:
		return (_active_camera_telemetry_job as ReviewCameraJob)._declared_subject_ids
	return []


func _review_camera_phase_telemetry(job: ReviewCameraJob) -> Dictionary:
	return {"phaseOrder": REVIEW_CAMERA_PHASES.duplicate(), "visitKeys": REVIEW_CAMERA_VISIT_KEYS.duplicate(), "latestAdvance": job._phase_latest.duplicate(true), "runGlobal": job._phase_global.duplicate(true), "runGlobalMaxCandidateUsec": job._global_max_candidate_usec, "stageRejectionEvidence": job._stage_rejection_evidence.duplicate(true)}


## A candidate is atomic: its existing prerequisite/callback sequence is never
## split across frames. Timings belong to progress, not the legacy pose schema.
func advance_exterior_review_pose(value: Variant, max_candidates: int = 1) -> Dictionary:
	if not value is ReviewCameraJob:
		return _review_camera_job_error("invalid_camera_job")
	var job: ReviewCameraJob = value
	if job._owner_id != get_instance_id() or job._busy:
		return _review_camera_job_error("foreign_or_busy_camera_job")
	var candidate_count := job._candidate_positions.size()
	if max_candidates < 1 or max_candidates > 64 or candidate_count < 1 or candidate_count > 64 or job._cursor < 0 or job._cursor > candidate_count:
		return _review_camera_job_error("invalid_camera_job_state_or_step")
	if not job._visual_snapshot_binding.is_empty() and (job._visual_snapshot_binding != review_visual_snapshot_binding() or job._visual_snapshot_epoch != _review_visual_snapshot_epoch):
		job._error = "stale_camera_visual_snapshot_binding"
		job._complete = true
		job._pose = {"ok": false, "reason": job._error}
		job._phase_latest = _empty_review_camera_phase_rows()
		return {"valid": false, "complete": true, "reason": job._error, "pose": job._pose.duplicate(true), "candidatesEvaluated": 0, "totalCandidatesEvaluated": job._cursor, "candidateUsec": [], "maxCandidateUsec": 0, "phaseTelemetry": _review_camera_phase_telemetry(job)}
	var candidate_usec: Array[int] = []
	var maximum_usec: int = 0
	job._phase_latest = _empty_review_camera_phase_rows()
	if not job._complete:
		job._busy = true
		for _step in range(mini(max_candidates, candidate_count - job._cursor)):
			# Never silently turn an expired required callback into a default.
			if (job._requires_candidate_callback and not job._candidate_rejection.is_valid()) or (job._requires_visibility_callback and not job._visibility_target.is_valid()):
				job._error = "camera_job_callback_expired"
				job._complete = true
				job._pose = {"ok": false, "reason": job._error}
				break
			var started_usec: int = Time.get_ticks_usec()
			var result := _review_camera_job_candidate(job)
			var elapsed_usec: int = Time.get_ticks_usec() - started_usec
			candidate_usec.append(elapsed_usec)
			maximum_usec = maxi(maximum_usec, elapsed_usec)
			job._global_max_candidate_usec = maxi(job._global_max_candidate_usec, elapsed_usec)
			job._cursor += 1
			if not result.is_empty():
				job._pose = result
				job._complete = true
				break
		job._busy = false
		if job._cursor == candidate_count and not job._complete:
			job._pose = {"ok": false, "reason": "no_standable_exterior_camera_pose", "rejectedCandidates": job._rejected, "rejectionExamples": job._examples, "stageRejectionEvidence": job._stage_rejection_evidence.duplicate(true)}
			job._complete = true
	return {"valid": job._error.is_empty(), "complete": job._complete, "reason": job._error, "pose": job._pose.duplicate(true), "candidatesEvaluated": candidate_usec.size(), "totalCandidatesEvaluated": job._cursor, "candidateUsec": candidate_usec, "maxCandidateUsec": maximum_usec, "phaseTelemetry": _review_camera_phase_telemetry(job)}


func _review_camera_job_error(reason: String) -> Dictionary:
	return {"valid": false, "complete": true, "reason": reason, "pose": {"ok": false, "reason": reason}, "candidatesEvaluated": 0, "totalCandidatesEvaluated": 0, "candidateUsec": [], "maxCandidateUsec": 0}


func _review_camera_job_candidate(job: ReviewCameraJob) -> Dictionary:
	var target: Vector3 = job._target
	var minimum_support_y: float = job._minimum_support_y
	var subject_radius: float = job._subject_radius
	var candidate_rejection: Callable = job._candidate_rejection
	var visibility_target: Callable = job._visibility_target
	var rejected: Dictionary = job._rejected
	var rejection_examples: Array[Dictionary] = job._examples
	var candidate_position: Vector3 = job._candidate_positions[job._cursor]
	var phase_started := _begin_review_camera_phase(job, "support")
	var support := bounded_exterior_support_for_review(candidate_position, minimum_support_y) if job._uses_bounded_surface_probe else exterior_support_for_review(candidate_position, target.y, minimum_support_y)
	_finish_review_camera_phase(job, "support", phase_started)
	if support.is_empty():
		rejected["support"] = int(rejected.get("support", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "support", candidate_position)
		return {}
	var feet := support.get("position", Vector3.ZERO) as Vector3
	var camera_position := feet + Vector3(0.0, 1.58, 0.0)
	phase_started = _begin_review_camera_phase(job, "capsule")
	var capsule_clearance := review_capsule_clearance(feet, support.get("collider", null))
	_finish_review_camera_phase(job, "capsule", phase_started)
	if not bool(capsule_clearance.get("clear", false)):
		rejected["capsule"] = int(rejected.get("capsule", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "capsule:%s" % String(capsule_clearance.get("collider", capsule_clearance.get("reason", "blocked"))), camera_position)
		return {}
	phase_started = _begin_review_camera_phase(job, "visualVolume")
	var visual_volume_clear := review_visual_volume_is_clear(feet)
	_finish_review_camera_phase(job, "visualVolume", phase_started)
	if not visual_volume_clear:
		rejected["visualVolume"] = int(rejected.get("visualVolume", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "visual_volume", camera_position)
		return {}
	# A framing centre can lie inside the subject. Optional inspection
	# endpoints select an actual surface, never waive either sightline.
	phase_started = _begin_review_camera_phase(job, "visibilityTarget")
	var sightline_target: Variant = visibility_target.call(camera_position) if visibility_target.is_valid() else target
	_finish_review_camera_phase(job, "visibilityTarget", phase_started)
	if not sightline_target is Vector3 or not sightline_target.is_finite():
		rejected["invalidVisibilityTarget"] = int(rejected.get("invalidVisibilityTarget", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "invalid_visibility_target", camera_position)
		return {}
	phase_started = _begin_review_camera_phase(job, "physicsSightline")
	var physics_sightline_clear := review_line_is_clear(camera_position, sightline_target)
	var physics_blocker := {} if physics_sightline_clear else review_physics_line_blocker(camera_position, sightline_target)
	_finish_review_camera_phase(job, "physicsSightline", phase_started)
	if not physics_sightline_clear:
		rejected["physicsSightline"] = int(rejected.get("physicsSightline", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "physics_sightline", camera_position, physics_blocker)
		return {}
	phase_started = _begin_review_camera_phase(job, "visualSightline")
	var visual_sightline_clear := review_visual_line_is_clear(camera_position, sightline_target)
	var visual_blocker := {} if visual_sightline_clear else review_visual_line_blocker(camera_position, sightline_target)
	_finish_review_camera_phase(job, "visualSightline", phase_started)
	if not visual_sightline_clear:
		rejected["visualSightline"] = int(rejected.get("visualSightline", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "visual_sightline", camera_position, visual_blocker)
		return {}
	phase_started = _begin_review_camera_phase(job, "frameChecks")
	var target_distance := camera_position.distance_to(target)
	var frame_fraction := (2.0 * atan(subject_radius / maxf(target_distance, 0.01))) / deg_to_rad(62.0)
	_finish_review_camera_phase(job, "frameChecks", phase_started)
	if frame_fraction < MIN_REVIEW_SUBJECT_FRAME_FRACTION:
		rejected["frameCoverage"] = int(rejected.get("frameCoverage", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "frame_coverage", camera_position)
		return {}
	if frame_fraction > MAX_REVIEW_SUBJECT_FRAME_FRACTION:
		rejected["frameDominance"] = int(rejected.get("frameDominance", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "frame_dominance", camera_position)
		return {}
	phase_started = _begin_review_camera_phase(job, "nearFieldComposition")
	var near_field := review_near_camera_visual_composition(camera_position, target)
	_finish_review_camera_phase(job, "nearFieldComposition", phase_started)
	if not bool(near_field.get("clear", false)):
		rejected["nearFieldComposition"] = int(rejected.get("nearFieldComposition", 0)) + 1
		append_camera_pose_rejection(rejection_examples, "near_field_composition", camera_position, near_field)
		return {}
	# Optional diagnostic subject requirements refine this SAME bounded
	# candidate set. They cannot waive support, clearance or sightlines.
	if candidate_rejection.is_valid():
		phase_started = _begin_review_camera_phase(job, "subjectReadability")
		var reason: Variant = candidate_rejection.call(camera_position)
		_finish_review_camera_phase(job, "subjectReadability", phase_started)
		if not reason is String or not reason.is_empty():
			rejected["subjectRequirements"] = int(rejected.get("subjectRequirements", 0)) + 1
			append_camera_pose_rejection(rejection_examples, "subject:%s" % str(reason), camera_position)
			return {}
	var result := {
		"ok": true,
		"cameraPosition": camera_position,
		"supportPosition": feet,
		"supportCollider": review_collider_id(support.get("collider", null)),
		"targetDistance": target_distance,
		"subjectFrameFraction": frame_fraction,
		"rejectedCandidates": rejected,
		"rejectionExamples": rejection_examples,
		"stageRejectionEvidence": job._stage_rejection_evidence.duplicate(true)
	}
	if visibility_target.is_valid(): result["sightlineTarget"] = sightline_target
	return result


func append_camera_pose_rejection(examples: Array[Dictionary], reason: String, position: Vector3, detail: Dictionary = {}) -> void:
	if examples.size() >= 8:
		return
	var example := {"reason": reason, "position": "(%.2f, %.2f, %.2f)" % [position.x, position.y, position.z]}
	if not detail.is_empty():
		example["blocker"] = detail
	examples.append(example)


func review_collider_id(collider) -> String:
	var node := collider as Node
	return String(node.name) if node != null else str(collider)


func exterior_support_for_review(horizontal: Vector3, target_y: float, minimum_support_y: float) -> Dictionary:
	if get_world_3d() == null:
		return {}
	var origin := Vector3(horizontal.x, target_y + 7.0, horizontal.z)
	var query := PhysicsRayQueryParameters3D.create(origin, Vector3(horizontal.x, target_y - 24.0, horizontal.z))
	query.collide_with_areas = false
	query.collide_with_bodies = true
	_review_camera_phase_visit("queries")
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var normal: Vector3 = hit.get("normal", Vector3.ZERO) as Vector3
	var position: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
	if normal.y < 0.72 or position.y > target_y + 0.08 or position.y < minimum_support_y:
		return {}
	return {"position": position + Vector3(0.0, 0.055, 0.0), "collider": hit.get("collider", null)}


func bounded_exterior_support_for_review(surface_candidate: Vector3, minimum_support_y: float) -> Dictionary:
	if get_world_3d() == null:
		return {}
	# The bounded domain already names the expected generated surface. Probe its
	# pedestrian headroom, not the roof/eave column many metres above it.
	var origin := surface_candidate + Vector3(0.0, 0.30, 0.0)
	var query := PhysicsRayQueryParameters3D.create(origin, surface_candidate - Vector3(0.0, 2.50, 0.0))
	query.collide_with_areas = false
	query.collide_with_bodies = true
	_review_camera_phase_visit("queries")
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var normal: Vector3 = hit.get("normal", Vector3.ZERO) as Vector3
	var position: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
	if normal.y < 0.72 or position.y > surface_candidate.y + 0.08 or position.y < minimum_support_y:
		return {}
	return {"position": position + Vector3(0.0, 0.055, 0.0), "collider": hit.get("collider", null)}


func review_capsule_clearance(feet: Vector3, support_collider) -> Dictionary:
	if get_world_3d() == null:
		return {"clear": false, "reason": "missing_world"}
	var shape := CapsuleShape3D.new()
	shape.radius = 0.24
	shape.height = 1.68
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, feet + Vector3(0.0, shape.height * 0.5, 0.0))
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.margin = 0.02
	_review_camera_phase_visit("queries")
	var hits: Array = get_world_3d().direct_space_state.intersect_shape(query, 12)
	for hit_value in hits:
		_review_camera_phase_visit("samples")
		var hit: Dictionary = hit_value as Dictionary
		var collider = hit.get("collider", null)
		if collider == support_collider or review_collider_is_underfoot_support(collider, feet):
			continue
		var collider_node := collider as Node
		return {"clear": false, "reason": "occupied_capsule", "collider": collider_node.name if collider_node != null else str(collider)}
	return {"clear": true}


func review_collider_is_underfoot_support(collider, feet: Vector3) -> bool:
	var node := collider as Node
	if node == null or not node.has_meta("building_part_record"):
		return false
	var record: Variant = node.get_meta("building_part_record")
	if not record is Dictionary or String(record.get("kind", "")) not in ["foundation", "floor", "ground_patch", "ramp", "stair_tread"]:
		return false
	var position: Variant = record.get("position")
	var rotation: Variant = record.get("rotation")
	var size: Variant = record.get("size")
	if not position is Vector3 or not rotation is Vector3 or not size is Vector3 or not position.is_finite() or not rotation.is_finite() or not size.is_finite():
		return false
	var local_feet := Transform3D(Basis.from_euler(rotation), position).affine_inverse() * feet
	var half: Vector3 = size * 0.5
	if absf(local_feet.x) > half.x + 0.03 or absf(local_feet.z) > half.z + 0.03:
		return false
	var top_y := review_record_bounds(position, rotation, size).end.y
	return top_y <= feet.y + 0.08 and top_y >= feet.y - 0.18


func review_record_bounds(position: Vector3, rotation: Vector3, size: Vector3) -> AABB:
	var basis := Basis.from_euler(rotation)
	var extent := Vector3(
		absf(basis.x.x) * size.x + absf(basis.y.x) * size.y + absf(basis.z.x) * size.z,
		absf(basis.x.y) * size.x + absf(basis.y.y) * size.y + absf(basis.z.y) * size.z,
		absf(basis.x.z) * size.x + absf(basis.y.z) * size.y + absf(basis.z.z) * size.z)
	return AABB(position - extent * 0.5, extent)


func review_visual_volume_is_clear(feet: Vector3) -> bool:
	var envelope := AABB(feet + Vector3(-0.24, 0.0, -0.24), Vector3(0.48, 1.62, 0.48))
	var query := review_visual_snapshot_candidates(envelope, false, review_visual_snapshot_binding())
	if not bool(query.get("valid", false)):
		return false
	for record_value in query.get("records", []):
		_review_camera_phase_visit("parts")
		var record: Dictionary = record_value
		if not bool(record.visualEligible) or String(record.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
			continue
		if review_record_intersects_capsule(record, feet, 0.24, 1.62):
			_append_review_stage_rejection_evidence("visualVolume", {"subreason": "capsuleIntersection", "reason": "visual_volume", "selectedVisibleMember": "", "blockers": [_review_record_rejection_provenance(record, _active_review_declared_subject_ids())]})
			return false
	return true


func review_visual_line_is_clear(from: Vector3, target: Vector3) -> bool:
	var ray_bounds := AABB(from, Vector3.ZERO).expand(target).grow(0.04)
	var query := review_visual_snapshot_candidates(ray_bounds, false, review_visual_snapshot_binding())
	if not bool(query.get("valid", false)):
		return false
	for record_value in query.get("records", []):
		_review_camera_phase_visit("parts")
		var record: Dictionary = record_value
		if not bool(record.visualEligible) or String(record.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
			continue
		_review_camera_phase_visit("segments")
		if review_record_intersects_segment(record, from, target):
			return false
	return true


func review_near_camera_visual_composition(camera_position: Vector3, target: Vector3) -> Dictionary:
	if not bool(_review_visual_snapshot.get("valid", false)):
		return {"clear": false, "reason": "missing_blueprint"}
	var forward := target - camera_position
	var target_distance := forward.length()
	if target_distance <= 0.01:
		return {"clear": false, "reason": "invalid_target_distance"}
	forward /= target_distance
	var right := forward.cross(Vector3.UP)
	if right.length_squared() <= 0.0001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := right.cross(forward).normalized()
	var depth := minf(3.20, maxf(1.20, target_distance * 0.35))
	var half_height := tan(deg_to_rad(31.0)) * depth
	var half_width := half_height * (16.0 / 9.0)
	var offsets := [Vector2(-0.78, -0.72), Vector2(0.0, -0.72), Vector2(0.78, -0.72), Vector2(-0.78, 0.0), Vector2(0.78, 0.0), Vector2(-0.78, 0.72), Vector2(0.0, 0.72), Vector2(0.78, 0.72)]
	var envelope := AABB(camera_position, Vector3.ZERO)
	for offset_value in offsets:
		var offset: Vector2 = offset_value
		envelope = envelope.expand(camera_position + forward * depth + right * half_width * offset.x + up * half_height * offset.y)
	envelope = envelope.grow(0.06)
	var query := review_visual_snapshot_candidates(envelope, true, review_visual_snapshot_binding())
	if not bool(query.get("valid", false)):
		return {"clear": false, "reason": String(query.get("reason", "invalid_visual_snapshot_query"))}
	var ordered: Array = query.get("records", []) as Array
	var blocked_samples := 0
	var blocker_ids: Array[String] = []
	for offset_value in offsets:
		_review_camera_phase_visit("samples")
		var offset: Vector2 = offset_value
		var endpoint := camera_position + forward * depth + right * half_width * offset.x + up * half_height * offset.y
		for record_value in ordered:
			_review_camera_phase_visit("parts")
			var record: Dictionary = record_value
			if not bool(record.visualEligible) or String(record.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
				continue
			_review_camera_phase_visit("segments")
			if review_record_intersects_near_segment(record, camera_position, endpoint):
				blocked_samples += 1
				var blocker_id := String(record.id)
				if blocker_id not in blocker_ids and blocker_ids.size() < 4:
					blocker_ids.append(blocker_id)
				break
	if blocked_samples > MAX_NEAR_FIELD_BLOCKED_SAMPLES:
		var by_id: Dictionary = _review_visual_snapshot.get("byId", {}) as Dictionary
		var subject_ids := _active_review_declared_subject_ids()
		for blocker_id in blocker_ids:
			var blocker_record: Dictionary = by_id.get(blocker_id, {}) as Dictionary
			if not blocker_record.is_empty():
				_append_review_stage_rejection_evidence("nearFieldComposition", {"subreason": "blockedNearFrustum", "reason": "near_field_composition", "selectedVisibleMember": "", "blockedSamples": blocked_samples, "sampleCount": offsets.size(), "blockers": [_review_record_rejection_provenance(blocker_record, subject_ids)]})
	return {"clear": blocked_samples <= MAX_NEAR_FIELD_BLOCKED_SAMPLES, "blockedSamples": blocked_samples, "sampleCount": offsets.size(), "blockerIds": blocker_ids}


func review_part_intersects_near_segment(part, from: Vector3, target: Vector3) -> bool:
	var inverse := Transform3D(Basis.from_euler(part.rotation), part.position).affine_inverse()
	var local_bounds := AABB(-part.size * 0.5, part.size).grow(0.06)
	var local_from := inverse * from
	var local_target := inverse * target
	return local_bounds.has_point(local_from) or local_bounds.intersects_segment(local_from, local_target) != null


func review_visual_line_blocker(from: Vector3, target: Vector3) -> Dictionary:
	var ray_bounds := AABB(from, Vector3.ZERO).expand(target).grow(0.04)
	var query := review_visual_snapshot_candidates(ray_bounds, false, review_visual_snapshot_binding())
	if not bool(query.get("valid", false)):
		return {"id": String(query.get("reason", "missing_visual_snapshot"))}
	for record_value in query.get("records", []):
		_review_camera_phase_visit("parts")
		var record: Dictionary = record_value
		if not bool(record.visualEligible) or String(record.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
			continue
		var bounds: AABB = record.worldBounds
		_review_camera_phase_visit("segments")
		if review_record_intersects_segment(record, from, target):
			return {"id": String(record.id), "position": bounds.get_center()}
	return {}


func review_part_bounds(part) -> AABB:
	var size: Vector3 = part.size
	var basis := Basis.from_euler(part.rotation)
	var extent := Vector3(
		absf(basis.x.x) * size.x + absf(basis.y.x) * size.y + absf(basis.z.x) * size.z,
		absf(basis.x.y) * size.x + absf(basis.y.y) * size.y + absf(basis.z.y) * size.z,
		absf(basis.x.z) * size.x + absf(basis.y.z) * size.y + absf(basis.z.z) * size.z
	)
	return AABB(part.position - extent * 0.5, extent)


func review_record_intersects_capsule(record: Dictionary, feet: Vector3, radius: float, height: float) -> bool:
	var inverse: Transform3D = record.inverse
	var bounds: AABB = (record.localBounds as AABB).grow(radius)
	for fraction in [0.10, 0.50, 0.90]:
		_review_camera_phase_visit("samples")
		if bounds.has_point(inverse * (feet + Vector3(0.0, height * float(fraction), 0.0))):
			return true
	return false


func review_record_intersects_segment(record: Dictionary, from: Vector3, target: Vector3) -> bool:
	var inverse: Transform3D = record.inverse
	var local_bounds: AABB = record.localBounds
	var local_from := inverse * from
	var local_target := inverse * target
	if local_bounds.grow(0.12).has_point(local_target):
		return false
	return local_bounds.intersects_segment(local_from, local_target) != null


func review_record_intersects_near_segment(record: Dictionary, from: Vector3, target: Vector3) -> bool:
	var inverse: Transform3D = record.inverse
	var local_bounds: AABB = (record.localBounds as AABB).grow(0.06)
	var local_from := inverse * from
	var local_target := inverse * target
	return local_bounds.has_point(local_from) or local_bounds.intersects_segment(local_from, local_target) != null


func review_part_intersects_capsule(part, feet: Vector3, radius: float, height: float) -> bool:
	var inverse := Transform3D(Basis.from_euler(part.rotation), part.position).affine_inverse()
	var bounds := AABB(-part.size * 0.5, part.size).grow(radius)
	for fraction in [0.10, 0.50, 0.90]:
		_review_camera_phase_visit("samples")
		var sample := feet + Vector3(0.0, height * float(fraction), 0.0)
		if bounds.has_point(inverse * sample):
			return true
	return false


func review_part_intersects_segment(part, from: Vector3, target: Vector3) -> bool:
	var inverse := Transform3D(Basis.from_euler(part.rotation), part.position).affine_inverse()
	var local_bounds := AABB(-part.size * 0.5, part.size)
	var local_from := inverse * from
	var local_target := inverse * target
	if local_bounds.grow(0.12).has_point(local_target):
		return false
	return local_bounds.intersects_segment(local_from, local_target) != null


func audit_review_camera_contract(view: Dictionary, review_camera: Camera3D) -> Dictionary:
	var target: Vector3 = view.get("target", Vector3.ZERO) as Vector3
	var maximum_distance := float(view.get("maxDistance", 24.0))
	var requires_clear := bool(view.get("requiresClear", false))
	var target_distance := review_camera.global_position.distance_to(target)
	var target_in_front := not review_camera.is_position_behind(target)
	var sightline_target: Variant = view.get("cameraPoseSightlineTarget", target)
	var sightline_valid: bool = sightline_target is Vector3 and sightline_target.is_finite()
	var target_clear: bool = sightline_valid and review_line_is_clear(review_camera.global_position, sightline_target)
	var pose_is_required := view.has("cameraPoseOk")
	var pose_ok := pose_is_required and bool(view.get("cameraPoseOk", false))
	var support_value: Variant = view.get("cameraPoseSupport")
	var support_valid: bool = support_value is Vector3 and (support_value as Vector3).is_finite()
	var frame_is_required := view.has("cameraPoseFrameFraction")
	var subject_frame_fraction := float(view.get("cameraPoseFrameFraction", 0.0))
	var result := {
		"id": String(view.get("id", "capture")),
		"subject": String(view.get("subject", "scene")),
		"targetDistance": target_distance,
		"maximumDistance": maximum_distance,
		"requiresClear": requires_clear,
		"targetInFront": target_in_front,
		"targetClear": target_clear,
		"cameraPose": {
			"ok": pose_ok,
			"reason": String(view.get("cameraPoseReason", "")),
			"support": view.get("cameraPoseSupport", Vector3.ZERO),
			"rejectedCandidates": view.get("cameraPoseRejections", {}),
			"rejectionExamples": view.get("cameraPoseRejectionExamples", [])
		},
		"subjectFrameFraction": subject_frame_fraction,
		"passed": requires_clear and sightline_valid and pose_ok and support_valid and frame_is_required and target_in_front and target_clear and target_distance <= maximum_distance and subject_frame_fraction >= MIN_REVIEW_SUBJECT_FRAME_FRACTION and subject_frame_fraction <= MAX_REVIEW_SUBJECT_FRAME_FRACTION
	}
	# Recheck against the camera actually used to capture, rather than trusting
	# candidate metadata or assuming its final target remained at bounds centre.
	if view.get("cameraSubjectBounds") is AABB:
		var framing_reason := generated_upper_framing_for_transform(review_camera.global_transform, view.cameraSubjectBounds as AABB, review_camera.fov)
		result["cameraUpperFramingReason"] = framing_reason
		result["passed"] = bool(result.passed) and framing_reason.is_empty()
	if not view.has("cameraRequiredVisiblePartIds"):
		return result
	var subject_ids_value: Variant = view.get("cameraSubjectIds")
	var required_ids_value: Variant = view.get("cameraRequiredVisiblePartIds")
	var composition_ids_value: Variant = view.get("cameraCompositionSubjectIds")
	var subject_bounds_value: Variant = view.get("cameraSubjectBounds")
	var required_bounds_value: Variant = view.get("cameraRequiredVisibleBounds")
	var signature_value: Variant = view.get("cameraSubjectFamilySignature")
	var exact_target_value: Variant = view.get("cameraRequiresExactRequiredVisibleTarget")
	var subject_ids: Array = []
	if subject_ids_value is Array:
		subject_ids = subject_ids_value as Array
	var required_ids: Array = []
	if required_ids_value is Array:
		required_ids = required_ids_value as Array
	var composition_ids: Array = []
	if composition_ids_value is Array:
		composition_ids = composition_ids_value as Array
	var subject_bounds := AABB()
	if subject_bounds_value is AABB:
		subject_bounds = subject_bounds_value
	var required_bounds := AABB()
	if required_bounds_value is AABB:
		required_bounds = required_bounds_value
	var exact_target_is_bool: bool = exact_target_value is bool
	var exact_target_required: bool = false
	if exact_target_is_bool:
		exact_target_required = bool(exact_target_value)
	var subject_ids_valid: bool = _review_family_ids_are_sorted_unique(subject_ids)
	var required_ids_valid: bool = _review_family_ids_are_sorted_unique(required_ids)
	var composition_ids_valid: bool = _review_family_ids_are_sorted_unique(composition_ids)
	var bounds_valid: bool = _review_family_bounds_are_valid(subject_bounds) and _review_family_bounds_are_valid(required_bounds)
	var signature_valid: bool = signature_value is String
	if signature_valid:
		signature_valid = not String(signature_value).is_empty()
	var family_valid: bool = subject_ids_valid and required_ids_valid and composition_ids_valid
	if family_valid:
		for id_value in required_ids:
			if not subject_ids.has(String(id_value)):
				family_valid = false
				break
	family_valid = family_valid and bounds_valid and signature_valid and exact_target_is_bool
	if family_valid and exact_target_required:
		family_valid = target.is_finite() and required_bounds.has_point(target)
	var required_member_evidence: Array[Dictionary] = []
	if family_valid:
		for id_value in required_ids:
			var id := String(id_value)
			var surface: Variant = generated_part_visible_surface(review_camera.global_position, id)
			var surface_valid: bool = false
			var physics_clear: bool = false
			var visual_clear: bool = false
			if surface is Vector3:
				var typed_surface: Vector3 = surface as Vector3
				surface_valid = typed_surface.is_finite()
				if surface_valid:
					physics_clear = review_line_is_clear(review_camera.global_position, typed_surface)
					visual_clear = review_visual_line_is_clear(review_camera.global_position, typed_surface)
			var member_passed: bool = surface_valid and physics_clear and visual_clear
			required_member_evidence.append({"id": id, "surface": surface, "surfaceValid": surface_valid, "physicsClear": physics_clear, "visualClear": visual_clear, "passed": member_passed})
			family_valid = family_valid and member_passed
	result["cameraTarget"] = view.get("target")
	result["cameraSightlineTarget"] = view.get("cameraPoseSightlineTarget") if view.has("cameraPoseSightlineTarget") else view.get("target")
	result["cameraSubjectIds"] = subject_ids_value
	result["cameraRequiredVisiblePartIds"] = required_ids_value
	result["cameraCompositionSubjectIds"] = composition_ids_value
	result["cameraSubjectBounds"] = subject_bounds_value
	result["cameraRequiredVisibleBounds"] = required_bounds_value
	result["cameraSubjectFamilySignature"] = signature_value
	result["cameraRequiresExactRequiredVisibleTarget"] = exact_target_value
	result["cameraRequiredVisibleEvidence"] = required_member_evidence
	result["cameraFamilyEvidenceValid"] = family_valid
	result["passed"] = bool(result.passed) and family_valid
	return result


func _review_family_ids_are_sorted_unique(value: Array) -> bool:
	if value.is_empty():
		return false
	var previous := ""
	for index in range(value.size()):
		if not value[index] is String:
			return false
		var id := String(value[index])
		if id.is_empty() or (index > 0 and (id == previous or id < previous)):
			return false
		previous = id
	return true


func _review_family_bounds_are_valid(value: AABB) -> bool:
	return value.position.is_finite() and value.size.is_finite() and value.size.x > 0.0 and value.size.y > 0.0 and value.size.z > 0.0


func review_line_is_clear(from: Vector3, target: Vector3) -> bool:
	if get_world_3d() == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(from, target)
	query.collide_with_areas = false
	_review_camera_phase_visit("queries")
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var hit_position: Vector3 = hit.get("position", from) as Vector3
	return hit_position.distance_to(target) <= 0.72


func review_physics_line_blocker(from: Vector3, target: Vector3) -> Dictionary:
	# Synthetic contracts can override the acceptance ray without attaching the
	# runner to a World3D. Telemetry must stay silent in that explicit context.
	if not is_inside_tree():
		return {}
	if get_world_3d() == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(from, target)
	query.collide_with_areas = false
	_review_camera_phase_visit("queries")
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var hit_position: Vector3 = hit.get("position", from) as Vector3
	if hit_position.distance_to(target) <= 0.72:
		return {}
	return {"id": review_collider_id(hit.get("collider", null)), "position": hit_position}
