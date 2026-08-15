extends "res://scripts/testing/buildings/CastleWalkthroughRunner.gd"

## Focused review fixture for the production citadel-palace recipe. It publishes
## only the keep blueprint, while using the same sampler, builder, collision,
## player and door service as the complete generated castle.

var keep_review_capture_dir := ""


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
	var window_lighting_audit := audit_window_lighting()
	var captures_saved := not captures.is_empty()
	for capture in captures:
		if not bool((capture as Dictionary).get("saved", false)):
			captures_saved = false
			break
	var report := {
		"runnerId": "keep_recipe_poc",
		"evidenceLevel": "headed_production_recipe_capture" if captures_saved else "recipe_publication_without_visual_acceptance",
		"status": "passed" if blueprint != null and front_door != null and not palace_grammar.is_empty() and bool(circulation_audit.get("passed", false)) and bool(window_lighting_audit.get("passed", false)) and captures_saved and not is_rebuilding else "failed",
		"seed": selected_seed,
		"citadelScale": selected_citadel_scale,
		"recipe": blueprint.recipe if blueprint != null else {},
		"buildingPublication": building_publisher.summary() if building_publisher != null else {},
		"registeredDoorCount": registered_door_count,
		"interiorCirculation": circulation_audit,
		"windowLighting": window_lighting_audit,
		"reviewCaptures": captures,
		"notes": "Publishes only the keep through the production deterministic castle palace grammar. It proves recipe publication, bounded interior stairs/storey floors, and visual review views; it does not automate player traversal."
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
	var radius := maxf(width, depth) * 1.72
	var views: Array[Dictionary] = [
		{"id": "01_front_approach", "position": Vector3(0.0, 1.2, -radius), "target": Vector3(0.0, crown_height * 0.42, 0.0)},
		{"id": "02_front_left", "position": Vector3(-radius * 0.78, 3.0, -radius * 0.72), "target": Vector3(0.0, crown_height * 0.44, 0.0)},
		{"id": "03_front_right", "position": Vector3(radius * 0.78, 3.0, -radius * 0.72), "target": Vector3(0.0, crown_height * 0.44, 0.0)},
		{"id": "04_side_profile", "position": Vector3(-radius, 3.0, 0.0), "target": Vector3(0.0, height * 0.45, 0.0)},
		{"id": "05_rear_quarter", "position": Vector3(radius * 0.74, 4.0, radius * 0.72), "target": Vector3(0.0, height * 0.48, 0.0)},
		{"id": "06_roofscape", "position": Vector3(0.0, crown_height * 1.12, -radius * 1.18), "target": Vector3(0.0, crown_height * 0.34, 0.0)},
		{"id": "07_entrance_material", "position": Vector3(0.0, 1.15, -depth * 0.5 - 9.5), "target": Vector3(0.0, 4.2, -depth * 0.5 + 1.2)},
		{"id": "08_wing_material", "position": Vector3(-radius * 0.62, 3.1, -depth * 0.74), "target": Vector3(-width * 0.34, 5.0, -depth * 0.10)}
	]
	for view_value in views:
		var view: Dictionary = view_value as Dictionary
		player.global_position = view.get("position", Vector3.ZERO) as Vector3
		player.look_at(view.get("target", Vector3.ZERO) as Vector3, Vector3.UP)
		if player.camera_pitch != null:
			player.camera_pitch.rotation.x = 0.0
		await get_tree().process_frame
		RenderingServer.force_draw(false)
		var path := keep_review_capture_dir.path_join("%s.png" % String(view.get("id", "review")))
		var viewport_texture := get_viewport().get_texture()
		var viewport_image := viewport_texture.get_image() if viewport_texture != null else null
		var error := viewport_image.save_png(path) if viewport_image != null else ERR_UNAVAILABLE
		captures.append({"id": view.get("id", "review"), "path": path, "saved": error == OK})
	for layer in hidden_layers:
		layer.visible = true
	return captures
