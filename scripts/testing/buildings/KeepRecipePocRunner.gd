extends "res://scripts/testing/buildings/CastleWalkthroughRunner.gd"

## Focused review fixture for the production citadel-palace recipe. It publishes
## only the keep blueprint, while using the same sampler, builder, collision,
## player and door service as the complete generated castle.

var keep_review_capture_dir := ""
const BuildingInteriorProgramScript := preload("res://scripts/buildings/BuildingInteriorProgram.gd")


func read_arguments() -> void:
	super.read_arguments()
	keep_review_capture_dir = OS.get_environment("VOXEL_KEEP_RECIPE_POC_SCREENSHOT_DIR")
	capture_path = OS.get_environment("VOXEL_KEEP_RECIPE_POC_CAPTURE")
	report_path = OS.get_environment("VOXEL_KEEP_RECIPE_POC_REPORT")


func build_castle_blueprint():
	return CastleCompoundBlueprintBuilderScript.build_keep_poc(selected_seed, {
		"biome": "forest",
		"siteKey": "citadel-palace-poc",
		"citadelScale": selected_citadel_scale
	})


func configure_walkthrough_ground() -> void:
	if blueprint == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var span := maxf(float(recipe.get("width", 40.0)), float(recipe.get("depth", 36.0))) * 3.2
	if walkthrough_ground_shape != null and walkthrough_ground_shape.shape is BoxShape3D:
		(walkthrough_ground_shape.shape as BoxShape3D).size = Vector3(span, 0.50, span)
	if walkthrough_ground_mesh != null:
		walkthrough_ground_mesh.size = Vector2(span, span)


func find_front_door() -> StaticBody3D:
	if cottage_root == null:
		return null
	for child in cottage_root.get_children():
		if child is StaticBody3D and String((child as StaticBody3D).get_meta("building_part_id", "")) == "castle_keep_entry_door":
			return child as StaticBody3D
	return null


func place_player_at_entry() -> void:
	if player == null or blueprint == null:
		return
	var depth := float(blueprint.recipe.get("depth", 24.0))
	player.position = Vector3(0.0, 0.04, -depth * 0.5 - 10.0)
	player.rotation.y = PI
	if player.camera_pitch != null:
		player.camera_pitch.rotation.x = deg_to_rad(-8.0)


func update_loading_label() -> void:
	if loading_label == null:
		return
	var dot_count := int(floor(loading_elapsed * 4.0)) % 4
	loading_label.text = "LOADING SEEDED KEEP RECIPE\n%s%s\n\nPublishing the production palace blueprint" % [loading_message, ".".repeat(dot_count)]


func update_hud() -> void:
	if status_label == null:
		return
	var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
	var palace_grammar: Dictionary = recipe.get("palaceGrammar", {}) as Dictionary
	status_label.text = "KEEP RECIPE PoC  |  %s\nseed %d  -  %.1fm x %.1fm  -  %d storeys  -  scale %.2fx\n[WASD] move  [Shift] sprint  [Space] jump  [E] use entry  [R] next seed  [Shift+R] previous  [Esc] release mouse\nProduction recipe only: no curtain wall, city blocks, or authored showcase placement." % [String(palace_grammar.get("planFamily", "palace")).replace("_", " ").to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), int(recipe.get("floorCount", 0)), selected_citadel_scale]


func write_automated_report() -> void:
	install_entry_material_review_lights()
	for _frame in range(4):
		await get_tree().process_frame
	var captures := await capture_keep_review_views()
	var palace_grammar: Dictionary = blueprint.recipe.get("palaceGrammar", {}) as Dictionary if blueprint != null else {}
	var circulation_audit := audit_internal_circulation()
	var entry_platform_collision_audit: Dictionary = await BuildingCollisionProbeScript.audit_keep_entry_supports(self, cottage_root, blueprint.parts)
	player.set_physics_process(true)
	var entry_apron_seam_audit: Dictionary = await BuildingCollisionProbeScript.audit_player_keep_entry_apron_seams(self, player, cottage_root, blueprint.parts)
	var window_lighting_audit := audit_window_lighting()
	var window_sightline_audit := audit_civic_window_sightlines()
	var window_interior_audit := BuildingInteriorProgramScript.audit_plan(blueprint, furnishing_plan)
	var masonry_repair_audit := audit_masonry_repair_clusters(captures)
	var captures_saved := not captures.is_empty()
	for capture in captures:
		if not bool((capture as Dictionary).get("saved", false)):
			captures_saved = false
			break
	var report := {
		"runnerId": "keep_recipe_poc",
		"evidenceLevel": "headed_production_recipe_capture" if captures_saved else "recipe_publication_without_visual_acceptance",
		"status": "passed" if blueprint != null and front_door != null and not palace_grammar.is_empty() and bool(circulation_audit.get("passed", false)) and bool(entry_platform_collision_audit.get("passed", false)) and bool(entry_apron_seam_audit.get("passed", false)) and bool(window_lighting_audit.get("passed", false)) and bool(window_sightline_audit.get("passed", false)) and bool(window_interior_audit.get("passed", false)) and bool(masonry_repair_audit.get("passed", false)) and captures_saved and not is_rebuilding else "failed",
		"seed": selected_seed,
		"citadelScale": selected_citadel_scale,
		"recipe": blueprint.recipe if blueprint != null else {},
		"buildingPublication": building_publisher.summary() if building_publisher != null else {},
		"registeredDoorCount": registered_door_count,
		"interiorCirculation": circulation_audit,
		"entryPlatformCollision": entry_platform_collision_audit,
		"entryApronSeams": entry_apron_seam_audit,
		"windowLighting": window_lighting_audit,
		"windowSightlines": window_sightline_audit,
		"windowInteriorProgram": window_interior_audit,
		"masonryRepair": masonry_repair_audit,
		"reviewCaptures": captures,
		"notes": "Publishes only the keep through the production deterministic castle palace grammar. It proves recipe publication, bounded interior stairs/storey floors, real-player step-apron collision seams, and visual review views; it does not automate the full entry traversal."
	}
	if not capture_path.is_empty():
		get_viewport().get_texture().get_image().save_png(capture_path)
		report["capturePath"] = capture_path
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	get_tree().quit(0 if String(report.get("status", "failed")) == "passed" else 1)


func audit_window_lighting() -> Dictionary:
	var warm_window_count := 0
	var cool_window_count := 0
	if blueprint == null:
		return {"passed": false, "warmWindowCount": warm_window_count, "coolWindowCount": cool_window_count}
	for part in blueprint.parts:
		if part == null or String(part.kind) != "window":
			continue
		var material := String(part.material_id)
		if material == "window_warm_glass":
			warm_window_count += 1
		elif material == "window_glass":
			cool_window_count += 1
	return {"passed": warm_window_count > 0 and cool_window_count > 0, "warmWindowCount": warm_window_count, "coolWindowCount": cool_window_count}


func audit_civic_window_sightlines() -> Dictionary:
	var facade_windows: Array = []
	var shell_segments: Array = []
	var violations: Array[String] = []
	if blueprint == null:
		return {"passed": false, "facadeWindowCount": 0, "violations": ["keep blueprint is unavailable"]}
	for part in blueprint.parts:
		if part == null:
			continue
		if String(part.semantic) == "castle_keep_civic_facade_window":
			facade_windows.append(part)
			if not bool(part.recipe.get("openingBacked", false)):
				violations.append("%s is not backed by a real wall opening" % String(part.id))
		elif String(part.id) in ["castle_keep_front_-1", "castle_keep_front_1"]:
			shell_segments.append(part)
	for window_part in facade_windows:
		var opening_bounds := AABB(window_part.position - window_part.size * 0.5, window_part.size).grow(0.02)
		for shell_part in shell_segments:
			var shell_bounds := AABB(shell_part.position - shell_part.size * 0.5, shell_part.size)
			if opening_bounds.intersects(shell_bounds):
				violations.append("%s is blocked by shell segment %s" % [String(window_part.id), String(shell_part.id)])
	return {"passed": facade_windows.size() > 0 and violations.is_empty(), "facadeWindowCount": facade_windows.size(), "violations": violations}


func audit_masonry_repair_clusters(captures: Array[Dictionary]) -> Dictionary:
	var publication: Dictionary = building_publisher.summary() if building_publisher != null else {}
	var cluster_count := int(publication.get("masonryRepairClusterCount", 0))
	var capture_saved := false
	for capture in captures:
		if String((capture as Dictionary).get("id", "")) == "10_masonry_repair_cluster" and bool((capture as Dictionary).get("saved", false)):
			capture_saved = true
			break
	return {"passed": cluster_count > 0 and capture_saved, "clusterCount": cluster_count, "captureSaved": capture_saved}


func install_entry_material_review_lights() -> void:
	if blueprint == null or get_node_or_null("KeepEntryMaterialLights") != null:
		return
	var entry_position := Vector3(0.0, 2.0, -float(blueprint.recipe.get("depth", 24.0)) * 0.5)
	for part in blueprint.parts:
		if part != null and String(part.id) == "castle_keep_entry_door":
			entry_position = part.position
			break
	var lights := Node3D.new()
	lights.name = "KeepEntryMaterialLights"
	add_child(lights)
	var review_fill := DirectionalLight3D.new()
	review_fill.name = "KeepMaterialReviewFill"
	review_fill.rotation_degrees = Vector3(-38.0, 132.0, 0.0)
	review_fill.light_color = Color(0.72, 0.79, 0.82)
	review_fill.light_energy = 0.62
	review_fill.shadow_enabled = false
	lights.add_child(review_fill)
	var placements := [
		entry_position + Vector3(-2.5, 1.25, -1.15),
		entry_position + Vector3(2.5, 1.25, -1.15),
		entry_position + Vector3(0.0, 1.35, 1.45)
	]
	for index in range(placements.size()):
		var light := OmniLight3D.new()
		light.name = "KeepEntrySconce%02d" % index
		light.position = placements[index] as Vector3
		light.light_color = Color(1.0, 0.67, 0.40)
		light.light_energy = 2.4 if index < 2 else 2.0
		light.omni_range = 8.0
		light.shadow_enabled = index == 2
		lights.add_child(light)


func audit_internal_circulation() -> Dictionary:
	var violations: Array[String] = []
	var checked_part_count := 0
	var elevated_exterior_platform_count := 0
	if blueprint == null:
		return {"passed": false, "checkedPartCount": checked_part_count, "elevatedExteriorPlatformCount": elevated_exterior_platform_count, "violations": ["keep blueprint is unavailable"]}
	var keep_bounds := AABB()
	for room_value in blueprint.rooms:
		if room_value is Dictionary and String((room_value as Dictionary).get("id", "")) == "castle_keep":
			keep_bounds = (room_value as Dictionary).get("bounds", AABB()) as AABB
			break
	if keep_bounds.size.x <= 0.0 or keep_bounds.size.z <= 0.0:
		return {"passed": false, "checkedPartCount": checked_part_count, "elevatedExteriorPlatformCount": elevated_exterior_platform_count, "violations": ["keep room has no enclosed footprint"]}
	var interior_bounds := AABB(keep_bounds.position + Vector3(0.72, 0.0, 0.72), keep_bounds.size - Vector3(1.44, 0.0, 1.44))
	var hall_storeys := int((blueprint.recipe.get("palaceGrammar", {}) as Dictionary).get("hallStoreys", 4))
	var hall_roof_y := float(blueprint.recipe.get("foundationHeight", 0.62)) + float(blueprint.recipe.get("floorHeight", 3.6)) * float(hall_storeys)
	for part in blueprint.parts:
		if part == null:
			continue
		var part_id := String(part.id)
		if String(part.kind) == "foundation" and part.position.y > hall_roof_y:
			elevated_exterior_platform_count += 1
			violations.append("%s is an elevated exterior platform instead of enclosed roof geometry" % part_id)
		if not part_id.begins_with("castle_keep_stair_") and not part_id.begins_with("castle_keep_storey_"):
			continue
		checked_part_count += 1
		var bounds := AABB(part.position - part.size * 0.5, part.size)
		if bounds.position.x < interior_bounds.position.x - 0.08 or bounds.end.x > interior_bounds.end.x + 0.08 or bounds.position.z < interior_bounds.position.z - 0.08 or bounds.end.z > interior_bounds.end.z + 0.08:
			violations.append("%s protrudes beyond the enclosed keep footprint" % part_id)
	return {"passed": violations.is_empty() and checked_part_count > 0, "checkedPartCount": checked_part_count, "elevatedExteriorPlatformCount": elevated_exterior_platform_count, "violations": violations}


func capture_keep_review_views() -> Array[Dictionary]:
	var captures: Array[Dictionary] = []
	if keep_review_capture_dir.is_empty() or player == null or blueprint == null:
		return captures
	DirAccess.make_dir_recursive_absolute(keep_review_capture_dir)
	player.set_physics_process(false)
	set_loading_visible(false)
	var hidden_layers: Array[CanvasLayer] = []
	for child in get_children():
		if child is CanvasLayer and child.visible:
			hidden_layers.append(child as CanvasLayer)
			child.visible = false
	var width := float(blueprint.recipe.get("width", 32.0))
	var depth := float(blueprint.recipe.get("depth", 28.0))
	var height := float(blueprint.recipe.get("wallHeight", 24.0))
	var crown_height := height + maxf(10.0, height * 0.52)
	var front_z := -depth * 0.5
	var front_distance := maxf(15.0, width * 0.72)
	var flank_distance := maxf(17.0, width * 0.76)
	var views: Array[Dictionary] = [
		{"id": "01_front_approach", "position": Vector3(-width * 0.14, 5.0, front_z - front_distance * 0.72), "target": Vector3(0.0, crown_height * 0.40, -depth * 0.12)},
		{"id": "02_front_left", "position": Vector3(-flank_distance * 0.72, 5.4, front_z - front_distance * 0.58), "target": Vector3(-width * 0.08, crown_height * 0.43, -depth * 0.08)},
		{"id": "03_front_right", "position": Vector3(flank_distance * 0.72, 5.4, front_z - front_distance * 0.58), "target": Vector3(width * 0.08, crown_height * 0.43, -depth * 0.08)},
		{"id": "04_side_profile", "position": Vector3(-flank_distance, 5.2, 0.0), "target": Vector3(0.0, height * 0.46, 0.0)},
		{"id": "05_rear_quarter", "position": Vector3(flank_distance * 0.70, 6.2, depth * 0.5 + front_distance * 0.54), "target": Vector3(0.0, height * 0.50, depth * 0.10)},
		{"id": "06_roofscape", "position": Vector3(-width * 0.38, crown_height * 0.92, front_z - front_distance * 0.42), "target": Vector3(0.0, crown_height * 0.48, 0.0)},
		{"id": "07_entrance_material", "position": Vector3(-width * 0.18, 2.8, front_z - 10.8), "target": Vector3(0.0, 3.7, front_z - 0.18)},
		{"id": "08_wing_material", "position": Vector3(-width * 0.56, 4.40, front_z - 7.20), "target": Vector3(-width * 0.45, 4.10, front_z + 1.10)}
	]
	for part in blueprint.parts:
		if part == null or String(part.semantic) != "castle_keep_civic_facade_window":
			continue
		views.append({"id": "09_window_sightline", "position": part.position + Vector3(0.0, 0.0, -2.20), "target": part.position + Vector3(0.0, 0.06, 4.80)})
		break
	var repair_view := masonry_repair_review_view()
	if not repair_view.is_empty():
		views.append(repair_view)
	var review_camera := Camera3D.new()
	review_camera.name = "KeepRecipeAutomatedReviewCamera"
	review_camera.fov = 52.0
	review_camera.near = 0.05
	add_child(review_camera)
	review_camera.current = true
	for view_value in views:
		var view: Dictionary = view_value as Dictionary
		review_camera.global_position = view.get("position", Vector3.ZERO) as Vector3
		review_camera.look_at(view.get("target", Vector3.ZERO) as Vector3, Vector3.UP)
		for _frame in range(4):
			await get_tree().process_frame
		RenderingServer.force_draw(false)
		var path := keep_review_capture_dir.path_join("%s.png" % String(view.get("id", "review")))
		var viewport_texture := get_viewport().get_texture()
		var viewport_image := viewport_texture.get_image() if viewport_texture != null else null
		var has_visual_detail := capture_has_visual_detail(viewport_image)
		var error := viewport_image.save_png(path) if viewport_image != null else ERR_UNAVAILABLE
		captures.append({"id": view.get("id", "review"), "path": path, "saved": error == OK and has_visual_detail, "hasVisualDetail": has_visual_detail})
	if player.camera != null:
		player.camera.current = true
	review_camera.queue_free()
	for layer in hidden_layers:
		layer.visible = true
	return captures


func capture_has_visual_detail(image: Image) -> bool:
	if image == null or image.is_empty():
		return false
	var min_luminance := INF
	var max_luminance := -INF
	var sample_count := 0
	for y_index in range(1, 12):
		for x_index in range(1, 20):
			var pixel := image.get_pixel(image.get_width() * x_index / 20, image.get_height() * y_index / 12)
			var luminance := pixel.r * 0.2126 + pixel.g * 0.7152 + pixel.b * 0.0722
			min_luminance = minf(min_luminance, luminance)
			max_luminance = maxf(max_luminance, luminance)
			sample_count += 1
	return sample_count > 0 and max_luminance - min_luminance >= 0.055


func masonry_repair_review_view() -> Dictionary:
	if blueprint == null or building_publisher == null:
		return {}
	var publication: Dictionary = building_publisher.summary()
	var clusters: Array = publication.get("masonryRepairClusters", []) as Array
	var keep_depth := float(blueprint.recipe.get("depth", 28.0))
	for cluster_value in clusters:
		var cluster: Dictionary = cluster_value as Dictionary
		var part_id := String(cluster.get("partId", ""))
		if not part_id.begins_with("castle_keep_") or int(cluster.get("face", -1)) != 0:
			continue
		for part in blueprint.parts:
			if part == null or String(part.id) != part_id:
				continue
			if part.position.z > -keep_depth * 0.24:
				continue
			var face := int(cluster.get("face", 0))
			var outward: Vector3 = [Vector3(0.0, 0.0, -1.0), Vector3(0.0, 0.0, 1.0), Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0)][face] as Vector3
			var along_axis: Vector3 = Vector3.RIGHT if face < 2 else Vector3.FORWARD
			var along_span: float = part.size.x if face < 2 else part.size.z
			var depth_span: float = part.size.z if face < 2 else part.size.x
			if along_span < 5.0 or part.size.y < 3.0:
				continue
			var target: Vector3 = part.position + along_axis * ((float(cluster.get("centerAlong", 0.5)) - 0.5) * along_span) + Vector3.UP * ((float(cluster.get("centerY", 0.5)) - 0.5) * part.size.y) + outward * (depth_span * 0.5 + 0.10)
			return {"id": "10_masonry_repair_cluster", "position": target + outward * 7.20 + Vector3.UP * 0.80, "target": target + Vector3.UP * 0.05}
	return {}
