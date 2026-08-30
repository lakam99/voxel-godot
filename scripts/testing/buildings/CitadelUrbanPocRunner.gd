extends "res://scripts/testing/buildings/CastleWalkthroughRunner.gd"

const CitadelUrbanPocComposerScript := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const BuildingInteriorProgramScript := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")

var screenshot_dir := ""
var generated_tree_count := 0
var ecology_backed_tree_count := 0
var generated_tree_positions: Array[Vector3] = []
var reused_groundcover_count := 0
var recipe_lantern_light_count := 0
var tree_contact_diagnostics: Dictionary = {}


func read_arguments() -> void:
	selected_citadel_scale = 1.25
	super.read_arguments()
	report_path = OS.get_environment("VOXEL_CITADEL_URBAN_POC_REPORT")
	screenshot_dir = OS.get_environment("VOXEL_CITADEL_URBAN_POC_SCREENSHOT_DIR")


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


func build_castle_blueprint():
	var result = super.build_castle_blueprint()
	CitadelUrbanPocComposerScript.compose(result, selected_seed)
	install_generated_city_trees(result)
	install_city_lights(result)
	return result


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
	DirAccess.make_dir_recursive_absolute(screenshot_dir)
	var views := capture_views() if bool(readiness.get("ready", false)) else []
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
	var report := {
		"runnerId": "citadel_urban_poc",
		"evidenceLevel": "headed_empty_environment_walkthrough",
		"status": "passed" if bool(readiness.get("ready", false)) and captures.size() == views.size() and not captures.is_empty() and review_contracts.all(func(contract): return bool((contract as Dictionary).get("passed", false))) and bool(window_interior_program.get("passed", false)) and bool(structural_support.get("passed", false)) else "failed",
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
		"visualReviewRequired": true
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
	var grounded_street_climb_count := 0
	var grounded_terrace_count := 0
	var grounded_terrace_stair_count := 0
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
		if semantic == "citadel_street_climb":
			if bounds.position.y > 0.02:
				failures.append("floating_street_climb:%s" % part_id)
			else:
				grounded_street_climb_count += 1
		elif semantic == "citadel_urban_terrace":
			if bounds.position.y > 0.02:
				failures.append("floating_terrace:%s" % part_id)
			else:
				grounded_terrace_count += 1
		elif semantic == "citadel_urban_stair":
			if bounds.position.y > 0.02:
				failures.append("floating_terrace_stair:%s" % part_id)
			else:
				grounded_terrace_stair_count += 1
	var market_support = parts_by_id.get("urban_market_plaza_retaining", null)
	var market_paving = parts_by_id.get("urban_market_plaza", null)
	if market_support == null or market_paving == null:
		failures.append("missing_market_support")
	else:
		var market_support_bounds := review_part_bounds(market_support)
		var market_paving_bounds := review_part_bounds(market_paving)
		if not bool(market_support.collision_enabled) or market_support_bounds.position.y > 0.02 or market_support_bounds.end.y < market_paving_bounds.position.y - 0.03:
			failures.append("unsupported_market_plaza")
	var tower = parts_by_id.get("urban_civic_tower", null)
	var tower_foundation = parts_by_id.get("urban_civic_tower_foundation", null)
	if tower == null or tower_foundation == null:
		failures.append("missing_civic_tower_foundation")
	else:
		var tower_bounds := review_part_bounds(tower)
		var tower_foundation_bounds := review_part_bounds(tower_foundation)
		if not bool(tower_foundation.collision_enabled) or tower_foundation_bounds.position.y > 0.02 or absf(tower_foundation_bounds.end.y - tower_bounds.position.y) > 0.02:
			failures.append("unsupported_civic_tower")
	var passed := failures.is_empty() and house_floor_count > 0 and grounded_house_foundation_count == house_floor_count and grounded_street_climb_count > 0 and grounded_terrace_count == 3 and grounded_terrace_stair_count == 12
	return {
		"passed": passed,
		"failures": failures,
		"houseFloorCount": house_floor_count,
		"groundedHouseFoundationCount": grounded_house_foundation_count,
		"groundedStreetClimbCount": grounded_street_climb_count,
		"groundedTerraceCount": grounded_terrace_count,
		"groundedTerraceStairCount": grounded_terrace_stair_count
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
	var grammar: Dictionary = blueprint.recipe.get("castleGrammar", {}) as Dictionary
	var courtyard_depth := float(grammar.get("courtyardDepth", 84.0))
	var gate_depth := float(grammar.get("gateDepth", 11.0))
	var keep_depth := float(grammar.get("keepDepth", 28.0))
	var keep_center_z := courtyard_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14))
	var front_z := -courtyard_depth * 0.5
	var keep_front_z := keep_center_z - keep_depth * 0.5
	var usable_depth := maxf(42.0, keep_front_z - front_z - 5.0)
	var segment_depth := usable_depth / 4.0
	var market_z := front_z + segment_depth * 2.62
	var urban_poc: Dictionary = blueprint.recipe.get("urbanPoc", {}) as Dictionary
	var market_lane_x := float(urban_poc.get("marketLaneX", CitadelUrbanPocComposerScript.MARKET_LANE_X))
	var market_terrace_rise := float(urban_poc.get("marketTerraceRise", CitadelUrbanPocComposerScript.MARKET_TERRACE_RISE))
	var market_ground_y := float(blueprint.recipe.get("foundationHeight", 0.62)) + market_terrace_rise + 0.32
	var market_anchor := find_part_position("urban_market_counter_")
	if market_anchor == Vector3.ZERO:
		market_anchor = Vector3(market_lane_x, market_ground_y + 0.85, market_z)
	var foliage_anchor := generated_tree_positions[0] if not generated_tree_positions.is_empty() else Vector3(market_lane_x - 7.0, market_ground_y, market_z + 3.0)
	var market_focus := market_anchor + Vector3(0.0, 1.05, 0.0)
	var foliage_focus := foliage_anchor + Vector3(0.0, 1.18, 0.0)
	var gate_focus := front_door.global_position + Vector3(0.0, 1.24, 0.0) if front_door != null else Vector3(0.0, 2.7, front_z + 16.0)
	var tree_contact_view := select_tree_contact_view()
	if tree_contact_view.is_empty():
		tree_contact_view = {"id": "tree_contact_paving", "subject": "tree canopy paving transition", "position": Vector3.ZERO, "target": Vector3.ZERO, "maxDistance": 0.0, "requiresClear": true, "cameraPoseOk": false, "cameraPoseReason": "no generated tree has an unobstructed paved canopy-edge contact"}
	var views: Array[Dictionary] = [
		{"id": "outer_approach", "subject": "gatehouse", "position": Vector3(0.0, 1.78, front_z - gate_depth - 13.0), "target": Vector3(0.0, 4.1, front_z + 1.5), "maxDistance": 30.0, "requiresClear": false},
		make_exterior_review_view("gate_threshold", "gate passage", gate_focus, 24.0, 6.0, 12.0, 2.8, 0),
		{"id": "inner_lane", "subject": "lane route", "position": Vector3(0.8, 1.76, front_z + 9.8), "target": Vector3(2.6, 2.35, front_z + 30.0), "maxDistance": 25.0, "requiresClear": false},
		make_exterior_review_view("market_ground", "market storefront", market_focus, 15.0, 4.8, 10.8, 2.25, 0, market_ground_y - 0.18),
		make_exterior_review_view("market_release", "market storefront", market_focus, 15.0, 5.8, 12.0, 2.25, 2, market_ground_y - 0.18),
		{"id": "civic_overview", "subject": "civic roofline", "position": Vector3(22.0, 15.0, keep_front_z - 25.0), "target": Vector3(22.0, 5.8, keep_front_z - 4.0), "maxDistance": 34.0, "requiresClear": false},
		{"id": "civic_commons", "subject": "civic commons", "position": Vector3(20.5, 1.76, keep_front_z - 25.0), "target": Vector3(28.0, 2.4, keep_front_z - 17.5), "maxDistance": 16.0, "requiresClear": false},
		{"id": "perimeter_lane", "subject": "perimeter lane", "position": Vector3(-35.0, 1.76, keep_front_z + 28.0), "target": Vector3(-43.0, 2.8, keep_front_z + 12.0), "maxDistance": 22.0, "requiresClear": false},
		make_exterior_review_view("green_market_square", "tree root and path edge", foliage_focus, 13.0, 4.6, 9.6, 2.4, 1, market_ground_y - 0.18),
		tree_contact_view
	]
	return views


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


func make_exterior_review_view(id: String, subject: String, target: Vector3, maximum_distance: float, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int, minimum_support_y := -INF) -> Dictionary:
	var pose := solve_exterior_review_pose(target, minimum_distance, preferred_distance, subject_radius, preferred_direction_index, minimum_support_y)
	return {
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


func solve_exterior_review_pose(target: Vector3, minimum_distance: float, preferred_distance: float, subject_radius: float, preferred_direction_index: int, minimum_support_y: float) -> Dictionary:
	var directions: Array[Vector3] = []
	for direction_index in range(16):
		var angle := TAU * float(direction_index) / 16.0
		directions.append(Vector3(sin(angle), 0.0, -cos(angle)))
	var distances := [preferred_distance, minimum_distance, lerpf(minimum_distance, preferred_distance, 0.30), lerpf(minimum_distance, preferred_distance, 0.64)]
	var rejected := {"support": 0, "capsule": 0, "visualVolume": 0, "physicsSightline": 0, "visualSightline": 0, "frameCoverage": 0}
	var rejection_examples: Array[Dictionary] = []
	for distance_value in distances:
		var distance := float(distance_value)
		for offset_index in range(directions.size()):
			var direction_index := int(posmod(preferred_direction_index + offset_index, directions.size()))
			var direction: Vector3 = (directions[direction_index] as Vector3).normalized()
			var support := exterior_support_for_review(target + direction * distance, target.y, minimum_support_y)
			if support.is_empty():
				rejected["support"] = int(rejected.get("support", 0)) + 1
				append_camera_pose_rejection(rejection_examples, "support", target + direction * distance)
				continue
			var feet := support.get("position", Vector3.ZERO) as Vector3
			var camera_position := feet + Vector3(0.0, 1.58, 0.0)
			var capsule_clearance := review_capsule_clearance(feet, support.get("collider", null))
			if not bool(capsule_clearance.get("clear", false)):
				rejected["capsule"] = int(rejected.get("capsule", 0)) + 1
				append_camera_pose_rejection(rejection_examples, "capsule:%s" % String(capsule_clearance.get("collider", capsule_clearance.get("reason", "blocked"))), camera_position)
				continue
			if not review_visual_volume_is_clear(feet):
				rejected["visualVolume"] = int(rejected.get("visualVolume", 0)) + 1
				append_camera_pose_rejection(rejection_examples, "visual_volume", camera_position)
				continue
			if not review_line_is_clear(camera_position, target):
				rejected["physicsSightline"] = int(rejected.get("physicsSightline", 0)) + 1
				append_camera_pose_rejection(rejection_examples, "physics_sightline", camera_position)
				continue
			if not review_visual_line_is_clear(camera_position, target):
				rejected["visualSightline"] = int(rejected.get("visualSightline", 0)) + 1
				append_camera_pose_rejection(rejection_examples, "visual_sightline", camera_position)
				continue
			var target_distance := camera_position.distance_to(target)
			var frame_fraction := (2.0 * atan(subject_radius / maxf(target_distance, 0.01))) / deg_to_rad(62.0)
			if frame_fraction < 0.18:
				rejected["frameCoverage"] = int(rejected.get("frameCoverage", 0)) + 1
				append_camera_pose_rejection(rejection_examples, "frame_coverage", camera_position)
				continue
			return {
				"ok": true,
				"cameraPosition": camera_position,
				"supportPosition": feet,
				"supportCollider": str(support.get("collider", "")),
				"targetDistance": target_distance,
				"subjectFrameFraction": frame_fraction
			}
	return {"ok": false, "reason": "no_standable_exterior_camera_pose", "rejectedCandidates": rejected, "rejectionExamples": rejection_examples}


func append_camera_pose_rejection(examples: Array[Dictionary], reason: String, position: Vector3) -> void:
	if examples.size() >= 8:
		return
	examples.append({"reason": reason, "position": "(%.2f, %.2f, %.2f)" % [position.x, position.y, position.z]})


func exterior_support_for_review(horizontal: Vector3, target_y: float, minimum_support_y: float) -> Dictionary:
	if get_world_3d() == null:
		return {}
	var origin := Vector3(horizontal.x, target_y + 7.0, horizontal.z)
	var query := PhysicsRayQueryParameters3D.create(origin, Vector3(horizontal.x, target_y - 4.0, horizontal.z))
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var normal: Vector3 = hit.get("normal", Vector3.ZERO) as Vector3
	var position: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
	if normal.y < 0.72 or position.y > target_y + 0.08 or position.y < minimum_support_y:
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
	var hits: Array = get_world_3d().direct_space_state.intersect_shape(query, 12)
	for hit_value in hits:
		var hit: Dictionary = hit_value as Dictionary
		var collider = hit.get("collider", null)
		if collider == support_collider:
			continue
		var collider_node := collider as Node
		return {"clear": false, "reason": "occupied_capsule", "collider": collider_node.name if collider_node != null else str(collider)}
	return {"clear": true}


func review_visual_volume_is_clear(feet: Vector3) -> bool:
	if blueprint == null:
		return false
	for part in blueprint.parts:
		if part == null or String(part.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
			continue
		if review_part_intersects_capsule(part, feet, 0.24, 1.62):
			return false
	return true


func review_visual_line_is_clear(from: Vector3, target: Vector3) -> bool:
	if blueprint == null:
		return false
	var ray_bounds := AABB(from, Vector3.ZERO).expand(target).grow(0.04)
	for part in blueprint.parts:
		if part == null or String(part.kind) in ["foundation", "floor", "ground_patch", "ramp"]:
			continue
		if not review_part_bounds(part).grow(0.04).intersects(ray_bounds):
			continue
		if review_part_intersects_segment(part, from, target):
			return false
	return true


func review_part_bounds(part) -> AABB:
	var size: Vector3 = part.size
	var basis := Basis.from_euler(part.rotation)
	var extent := Vector3(
		absf(basis.x.x) * size.x + absf(basis.y.x) * size.y + absf(basis.z.x) * size.z,
		absf(basis.x.y) * size.x + absf(basis.y.y) * size.y + absf(basis.z.y) * size.z,
		absf(basis.x.z) * size.x + absf(basis.y.z) * size.y + absf(basis.z.z) * size.z
	)
	return AABB(part.position - extent * 0.5, extent)


func review_part_intersects_capsule(part, feet: Vector3, radius: float, height: float) -> bool:
	var inverse := Transform3D(Basis.from_euler(part.rotation), part.position).affine_inverse()
	var bounds := AABB(-part.size * 0.5, part.size).grow(radius)
	for fraction in [0.10, 0.50, 0.90]:
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
	var target_clear := review_line_is_clear(review_camera.global_position, target)
	var pose_is_required := view.has("cameraPoseOk")
	var pose_ok := not pose_is_required or bool(view.get("cameraPoseOk", false))
	var subject_frame_fraction := float(view.get("cameraPoseFrameFraction", 1.0))
	return {
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
		"passed": pose_ok and target_in_front and (not requires_clear or target_clear) and target_distance <= maximum_distance and subject_frame_fraction >= 0.18
	}


func review_line_is_clear(from: Vector3, target: Vector3) -> bool:
	if get_world_3d() == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(from, target)
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var hit_position: Vector3 = hit.get("position", from) as Vector3
	return hit_position.distance_to(target) <= 0.72
