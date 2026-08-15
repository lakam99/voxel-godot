extends "res://scripts/testing/buildings/CastleWalkthroughRunner.gd"

const CitadelUrbanPocComposerScript := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")

var screenshot_dir := ""
var generated_tree_count := 0
var ecology_backed_tree_count := 0
var generated_tree_positions: Array[Vector3] = []
var reused_groundcover_count := 0
var recipe_lantern_light_count := 0


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
			environment.background_color = Color(0.145, 0.165, 0.175)
			environment.ambient_light_color = Color(0.47, 0.49, 0.45)
			environment.ambient_light_energy = 1.02
			environment.ssao_enabled = true
			environment.ssao_radius = 2.1
			environment.ssao_intensity = 1.02
			environment.ssao_power = 1.04
			environment.fog_enabled = true
			environment.fog_light_color = Color(0.38, 0.405, 0.41)
			environment.fog_light_energy = 0.50
			environment.fog_density = 0.0025
			environment.fog_sky_affect = 0.72
			break


func build_castle_blueprint():
	var result = super.build_castle_blueprint()
	CitadelUrbanPocComposerScript.compose(result, selected_seed)
	install_generated_city_trees(result)
	install_city_lights(result)
	return result


func install_generated_city_trees(result) -> void:
	# The PoC composer owns this fixture's open-space plan. Plant at the broad
	# market lane edges, outside its central travel corridor and market stalls.
	var placements := CitadelUrbanPocComposerScript.city_tree_placements(result)
	var tree_service = TreeSpawnServiceScript.new()
	var request_builder = TreeRuntimeRequestBuilderScript.new()
	var environment_catalog = BiomeEnvironmentCatalogScript.new()
	if not environment_catalog.setup():
		return
	var town_profile = environment_catalog.profile_for_biome("town")
	for index in range(placements.size()):
		var tree_position := placements[index] as Vector3
		var tree_id := "citadel-urban-tree-%d:%d,%d:%02d" % [selected_seed, roundi(tree_position.x), roundi(tree_position.z), index]
		var request: Dictionary = request_builder.build(town_profile, "town", tree_id, 6.2 + float(index % 3) * 0.9, Vector2i(roundi(tree_position.x), roundi(tree_position.z)), str(selected_seed))
		request["treeId"] = tree_id
		request["worldSeed"] = str(selected_seed)
		request["biome"] = "town"
		request["presentation"] = "runtime"
		var tree: Node3D = tree_service.spawn_tree(request)
		if tree == null:
			continue
		tree.name = "CitadelGeneratedTree%02d" % index
		tree.position = placements[index] as Vector3
		tree.rotation.y = float(index) * 1.17
		tree.set_meta("citadel_urban_generated_tree", true)
		add_child(tree)
		generated_tree_count += 1
		ecology_backed_tree_count += 1
		generated_tree_positions.append(tree.position)
	install_reused_groundcover(placements)
	install_reused_lane_weeds(result)


func install_reused_groundcover(tree_placements: Array) -> void:
	var registry = VisualAssetRegistryScript.new()
	if not registry.setup():
		return
	var offsets := [Vector3(-0.72, 0.03, 0.44), Vector3(0.62, 0.03, -0.56), Vector3(0.34, 0.03, 0.78), Vector3(-0.42, 0.03, -0.76), Vector3(0.82, 0.03, 0.18)]
	for tree_index in range(tree_placements.size()):
		var tree_position: Vector3 = tree_placements[tree_index] as Vector3
		for offset_index in range(offsets.size()):
			var bush: Node3D = registry.instantiate_family("bush", "citadel-groundcover:%d:%d:%d" % [selected_seed, tree_index, offset_index])
			if bush == null:
				continue
			bush.name = "CitadelGroundcover%02d_%02d" % [tree_index, offset_index]
			bush.position = tree_position + (offsets[offset_index] as Vector3).rotated(Vector3.UP, float(tree_index) * 1.27)
			var scale_value := 0.54 + float((tree_index + offset_index) % 3) * 0.10
			bush.scale = Vector3.ONE * scale_value
			bush.rotation.y = float(tree_index * 3 + offset_index) * 0.71
			bush.set_meta("citadel_urban_reused_groundcover", true)
			add_child(bush)
			reused_groundcover_count += 1


func install_reused_lane_weeds(result) -> void:
	var registry = VisualAssetRegistryScript.new()
	if result == null or not registry.setup():
		return
	var weed_index := 0
	for part in result.parts:
		if part == null:
			continue
		var semantic := String(part.semantic)
		if semantic not in ["citadel_threshold_wear", "citadel_market_drainage", "citadel_terminal_shop_wear", "citadel_civic_drainage", "citadel_lane_edge_age", "citadel_perimeter_alley", "citadel_route_history", "citadel_route_verge", "citadel_route_rut"]:
			continue
		if weed_index % 2 == 1 and semantic in ["citadel_threshold_wear", "citadel_lane_edge_age"]:
			weed_index += 1
			continue
		var weed: Node3D = registry.instantiate_family("bush", "citadel-lane-weed:%d:%s" % [selected_seed, String(part.id)])
		if weed == null:
			continue
		var phase := float(posmod(String(part.id).hash(), 997)) / 997.0
		weed.name = "CitadelLaneWeed%02d" % weed_index
		weed.position = part.position + Vector3(lerpf(-0.42, 0.42, phase), 0.025, lerpf(0.28, -0.28, phase))
		weed.scale = Vector3.ONE * (0.18 + phase * 0.18)
		weed.rotation.y = phase * TAU
		weed.set_meta("citadel_urban_reused_groundcover", true)
		add_child(weed)
		reused_groundcover_count += 1
		weed_index += 1


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
	var review_camera := Camera3D.new()
	review_camera.name = "CitadelUrbanAutomatedReviewCamera"
	review_camera.fov = player.camera.fov if player.camera != null else 74.0
	review_camera.near = 0.05
	add_child(review_camera)
	review_camera.current = true
	for view_value in views:
		var view: Dictionary = view_value as Dictionary
		var view_position := view.get("position", Vector3.ZERO) as Vector3
		var view_target := view.get("target", Vector3.ZERO) as Vector3
		review_camera.global_position = view_position + Vector3(0.0, 1.48, 0.0)
		review_camera.look_at(view_target, Vector3.UP)
		for _frame in range(8):
			await get_tree().process_frame
		RenderingServer.force_draw(false)
		var path := screenshot_dir.path_join("%s.png" % String(view.get("id", "capture")))
		var viewport_texture := get_viewport().get_texture()
		var viewport_image := viewport_texture.get_image() if viewport_texture != null else null
		var save_error := viewport_image.save_png(path) if viewport_image != null else ERR_UNAVAILABLE
		capture_results.append({"id": view.get("id", "capture"), "path": path, "saved": save_error == OK})
		if save_error == OK:
			captures.append(path)
	if player.camera != null:
		player.camera.current = true
	review_camera.queue_free()
	var report := {
		"runnerId": "citadel_urban_poc",
		"evidenceLevel": "headed_empty_environment_walkthrough",
		"status": "passed" if bool(readiness.get("ready", false)) and captures.size() == views.size() and not captures.is_empty() else "failed",
		"seed": selected_seed,
		"citadelScale": selected_citadel_scale,
		"peoplePresent": false,
		"generatedTreeCount": generated_tree_count,
		"ecologyBackedTreeCount": ecology_backed_tree_count,
		"reusedGroundcoverCount": reused_groundcover_count,
		"recipeLanternLightCount": recipe_lantern_light_count,
		"captureReadiness": readiness,
		"buildingPublication": building_publisher.summary() if building_publisher != null else {},
		"urbanLayout": blueprint.recipe.get("urbanPoc", {}).duplicate(true) if blueprint != null else {},
		"architecturalDiagnostics": inspect_architectural_recipe_parts(),
		"marketDiagnostics": inspect_market_recipe_parts(),
		"capturePaths": captures,
		"captureResults": capture_results,
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
		if semantic == "citadel_tree_root_transition":
			counts.treeTransitionCount += 1
	for room_value in blueprint.rooms:
		if room_value is Dictionary and bool((room_value as Dictionary).get("citadelUrbanRoom", false)):
			counts.urbanRoomCount += 1
	var passed := legacy_solid_facades.is_empty() and int(counts.facadeCoreCount) == 0 and int(counts.facadeShellWallCount) > 0 and int(counts.facadePanelCount) > 0 and int(counts.functionalDoorCount) > 0 and int(counts.urbanRoomCount) > 0 and int(counts.warmWindowCount) > 0 and int(counts.coolWindowCount) > 0 and int(counts.householdDetailCount) > 0 and int(counts.pathAgeCount) > 0 and int(counts.treeTransitionCount) > 0
	return {"passed": passed, "counts": counts, "legacySolidFacades": legacy_solid_facades}


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
	var views: Array[Dictionary] = [
		{"id": "outer_approach", "position": Vector3(0.0, 0.08, front_z - gate_depth - 15.0), "target": Vector3(0.0, 4.5, front_z), "pitch": -7.0},
		{"id": "gate_threshold", "position": Vector3(0.0, 0.08, front_z - gate_depth * 0.10), "target": Vector3(1.8, 3.0, front_z + 17.0), "pitch": -3.0},
		{"id": "inner_lane", "position": Vector3(0.2, 0.08, front_z + 12.0), "target": Vector3(3.8, 5.5, front_z + 30.0), "pitch": -10.0},
		{"id": "market_ground", "position": Vector3(market_lane_x, market_ground_y, market_z - 4.5), "target": Vector3(market_lane_x, market_ground_y + 1.0, market_z + 4.0), "pitch": -2.0},
		{"id": "market_release", "position": Vector3(market_lane_x, 10.0, market_z - 9.0), "target": Vector3(market_lane_x, market_ground_y + 0.8, market_z + 0.8), "pitch": -2.0},
		{"id": "civic_overview", "position": Vector3(22.0, 28.0, keep_front_z - 27.0), "target": Vector3(22.0, 8.0, keep_front_z - 4.0), "pitch": -12.0},
		{"id": "civic_commons", "position": Vector3(20.5, 2.0, keep_front_z - 25.0), "target": Vector3(28.0, 2.4, keep_front_z - 17.5), "pitch": -3.0},
		{"id": "perimeter_lane", "position": Vector3(-35.0, 3.2, keep_front_z + 28.0), "target": Vector3(-43.0, 2.8, keep_front_z + 12.0), "pitch": -4.0}
	]
	if generated_tree_positions.size() >= 2:
		var tree_midpoint := (generated_tree_positions[0] + generated_tree_positions[1]) * 0.5
		views.append({"id": "green_market_square", "position": tree_midpoint + Vector3(-10.0, 11.5, -6.5), "target": tree_midpoint + Vector3(0.5, 1.5, 0.5), "pitch": -2.0})
	return views
