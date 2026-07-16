extends Node3D

const BroadleafRecipeBuilderScript := preload("res://scripts/testing/trees/MathematicalTreePocRecipeBuilder.gd")
const ConiferRecipeBuilderScript := preload("res://scripts/testing/trees/MathematicalTreePocConiferRecipeBuilder.gd")
const SavannaRecipeBuilderScript := preload("res://scripts/testing/trees/MathematicalTreePocSavannaRecipeBuilder.gd")
const BushyOakRecipeBuilderScript := preload("res://scripts/testing/trees/MathematicalTreePocBushyOakRecipeBuilder.gd")
const VisualFactoryScript := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")

const CAPTURE_SIZE := Vector2i(1280, 720)
const DEFAULT_SEED := 0x4D415448

var report_path := ""
var screenshot_dir := ""
var selected_species := "broadleaf"
var recipe: Dictionary = {}
var tree_visual: Node3D
var review_camera: Camera3D
var loading_layer: CanvasLayer
var loading_label: Label
var elapsed := 0.0
var loading_elapsed := 0.0
var loading_frames := 0
var loading_message_updates := 0
var captures: Array[Dictionary] = []
var results: Array[Dictionary] = []
var finished := false

func _ready() -> void:
	configure_paths()
	configure_window()
	setup_scene()
	setup_loading_overlay()
	call_deferred("run_review")

func _process(delta: float) -> void:
	elapsed += delta
	RenderingServer.global_shader_parameter_set("environment_wind_time", elapsed)
	if loading_layer != null and loading_layer.visible:
		loading_elapsed += delta
		var dot_count := posmod(floori(loading_elapsed * 2.8), 4)
		var message := "Growing %s tree%s" % [selected_species, ".".repeat(dot_count)]
		if loading_label.text != message:
			loading_label.text = message
			loading_message_updates += 1

func configure_paths() -> void:
	selected_species = OS.get_environment("VOXEL_MATHEMATICAL_TREE_POC_SPECIES").strip_edges().to_lower()
	if selected_species not in ["broadleaf", "conifer", "savanna", "bushy_oak"]:
		selected_species = "broadleaf"
	report_path = OS.get_environment("VOXEL_MATHEMATICAL_TREE_POC_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/mathematical-tree-poc/report.json")
	screenshot_dir = OS.get_environment("VOXEL_MATHEMATICAL_TREE_POC_SCREENSHOT_DIR").strip_edges()
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/vegetation/mathematical-tree-poc/screenshots")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(screenshot_dir)

func configure_window() -> void:
	DisplayServer.window_set_title("Mathematical %s Tree PoC Review" % selected_species.capitalize())
	DisplayServer.window_set_size(CAPTURE_SIZE)
	get_tree().root.size = CAPTURE_SIZE
	get_tree().root.content_scale_size = CAPTURE_SIZE

func setup_scene() -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "MathematicalTreePocEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("9fc1c7")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("d2dfcc")
	environment.ambient_light_energy = 0.55
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	add_child(world_environment)

	var sunlight := DirectionalLight3D.new()
	sunlight.name = "ReviewSun"
	sunlight.light_color = Color("fff0c7")
	sunlight.light_energy = 1.18
	sunlight.shadow_enabled = true
	sunlight.directional_shadow_max_distance = 130.0
	sunlight.rotation_degrees = Vector3(-56.0, -38.0, 0.0)
	add_child(sunlight)

	var fill := DirectionalLight3D.new()
	fill.name = "CoolFill"
	fill.light_color = Color("adc9d2")
	fill.light_energy = 0.22
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-24.0, 132.0, 0.0)
	add_child(fill)

	var floor := MeshInstance3D.new()
	floor.name = "NeutralReviewGround"
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(92.0, 0.28, 92.0)
	floor.mesh = floor_mesh
	floor.position = Vector3(0.0, -0.16, 0.0)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("718654")
	floor_material.roughness = 0.97
	floor.material_override = floor_material
	floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(floor)

	review_camera = Camera3D.new()
	review_camera.name = "MathematicalTreeReviewCamera"
	review_camera.fov = 57.0
	review_camera.near = 0.08
	review_camera.far = 260.0
	review_camera.current = true
	add_child(review_camera)

	RenderingServer.global_shader_parameter_set("environment_wind_direction", Vector3(0.82, 0.0, 0.57).normalized())
	RenderingServer.global_shader_parameter_set("environment_wind_strength", 0.20)
	RenderingServer.global_shader_parameter_set("environment_wind_gust_strength", 0.07)
	RenderingServer.global_shader_parameter_set("environment_wind_gust_frequency", 0.26)

func setup_loading_overlay() -> void:
	loading_layer = CanvasLayer.new()
	loading_layer.name = "ResponsiveGrowthOverlay"
	loading_layer.layer = 20
	add_child(loading_layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.035, 0.030, 0.86)
	panel.position = Vector2(24.0, 24.0)
	panel.size = Vector2(410.0, 76.0)
	loading_layer.add_child(panel)
	loading_label = Label.new()
	loading_label.position = Vector2(48.0, 43.0)
	loading_label.add_theme_font_size_override("font_size", 24)
	loading_label.add_theme_color_override("font_color", Color("f4e2a4"))
	loading_label.text = "Growing %s tree" % selected_species
	loading_layer.add_child(loading_label)

func run_review() -> void:
	var seed := int(OS.get_environment("VOXEL_MATHEMATICAL_TREE_POC_SEED")) if OS.get_environment("VOXEL_MATHEMATICAL_TREE_POC_SEED").is_valid_int() else DEFAULT_SEED
	var maturity_text := OS.get_environment("VOXEL_MATHEMATICAL_TREE_POC_MATURITY").strip_edges()
	var maturity := clampf(float(maturity_text) if maturity_text.is_valid_float() else 0.92, 0.12, 1.0)
	var builder = recipe_builder_for_selected_species()
	var recipe_thread := Thread.new()
	var generation_started := Time.get_ticks_usec()
	var thread_error := recipe_thread.start(Callable(builder, "build_recipe").bind(seed, maturity))
	if thread_error != OK:
		add_result("pure_recipe_worker_started", false, {"error": thread_error})
		finish(1)
		return
	add_result("pure_recipe_worker_started", true, {"seed": seed, "maturity": maturity, "species": selected_species})
	while recipe_thread.is_alive():
		loading_frames += 1
		await get_tree().process_frame
	var generated = recipe_thread.wait_to_finish()
	var generation_milliseconds := float(Time.get_ticks_usec() - generation_started) / 1000.0
	if not (generated is Dictionary):
		add_result("pure_recipe_worker_returned_dictionary", false, {"type": typeof(generated)})
		finish(1)
		return
	recipe = generated as Dictionary
	add_result("pure_recipe_worker_returned_dictionary", not recipe.is_empty(), {
		"generationMilliseconds": generation_milliseconds,
		"framesReturnedWhileGenerating": loading_frames,
		"loadingMessageUpdates": loading_message_updates
	})

	loading_label.text = "Publishing shared branch and foliage instances..."
	await get_tree().process_frame
	var publish_started := Time.get_ticks_usec()
	var factory = VisualFactoryScript.new()
	tree_visual = factory.instantiate_recipe(recipe, "forest", "mathematical-tree-poc:%s:%d" % [selected_species, seed])
	var publication_milliseconds := float(Time.get_ticks_usec() - publish_started) / 1000.0
	if tree_visual == null:
		add_result("one_procedural_tree_published", false, {"publicationMilliseconds": publication_milliseconds})
		finish(1)
		return
	tree_visual.name = "OnlyMathematicallyGeneratedTree"
	tree_visual.set_meta("complete_tree_asset_used", false)
	add_child(tree_visual)
	add_player_scale_reference(float(recipe.get("trunkRadius", 1.0)), float(recipe.get("canopyRadius", 5.0)))
	loading_layer.visible = false
	add_result("one_procedural_tree_published", count_procedural_trees() == 1, {
		"treeCount": count_procedural_trees(),
		"publicationMilliseconds": publication_milliseconds,
		"visualSource": tree_visual.get_meta("visual_source", ""),
		"completeTreeAssetUsed": tree_visual.get_meta("complete_tree_asset_used", true)
	})
	if bool(recipe.get("pocContinuousWood", false)):
		var continuous_wood_result := validate_continuous_wood()
		add_result(
			"entire_wood_graph_uses_one_generated_surface",
			bool(continuous_wood_result.get("passed", false)),
			continuous_wood_result
		)

	await wait_frames(10)
	await capture_whole_tree()
	await capture_rear_whole_tree()
	await capture_player_at_trunk()
	await capture_under_canopy()
	await capture_junction_integrity()
	await capture_lowest_junction_integrity()
	await capture_branch_skeleton()

	var stats: Dictionary = recipe.get("stats", {})
	add_result("seven_review_angles_saved", captures.size() == 7 and all_captures_saved(), captures)
	add_result("recipe_graph_connected", bool(stats.get("connected", false)), stats)
	add_result("pipe_model_area_conserved", float(stats.get("pipeModelMaxRelativeError", 1.0)) <= 0.0001, {
		"maxRelativeError": stats.get("pipeModelMaxRelativeError", 1.0),
		"junctionCount": stats.get("pipeModelJunctionCount", 0)
	})
	add_result("window_returned_frames_during_growth", loading_frames >= 2 and loading_message_updates >= 1, {
		"framesReturned": loading_frames,
		"messageUpdates": loading_message_updates
	})

	var review_seconds_text := OS.get_environment("VOXEL_MATHEMATICAL_TREE_POC_REVIEW_SECONDS").strip_edges()
	var review_seconds := maxf(0.0, float(review_seconds_text) if review_seconds_text.is_valid_float() else 0.0)
	if review_seconds > 0.0:
		await get_tree().create_timer(review_seconds).timeout
	finish(1 if failure_count() > 0 else 0, generation_milliseconds, publication_milliseconds)

func recipe_builder_for_selected_species():
	if selected_species == "conifer":
		return ConiferRecipeBuilderScript.new()
	if selected_species == "savanna":
		return SavannaRecipeBuilderScript.new()
	if selected_species == "bushy_oak":
		return BushyOakRecipeBuilderScript.new()
	return BroadleafRecipeBuilderScript.new()

func add_player_scale_reference(trunk_radius: float, canopy_radius: float) -> void:
	var reference := Node3D.new()
	reference.name = "PlayerScaleReference"
	reference.position = Vector3(-maxf(trunk_radius * 1.55, 4.0), 0.0, minf(canopy_radius * 0.18, 2.8))
	add_child(reference)
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.height = 1.8
	capsule.radius = 0.34
	body.mesh = capsule
	body.position.y = 0.9
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("d99a45")
	material.roughness = 0.88
	body.material_override = material
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	reference.add_child(body)
	var marker := Label3D.new()
	marker.text = "PLAYER 1.8m"
	marker.font_size = 34
	marker.outline_size = 7
	marker.modulate = Color("fff0c4")
	marker.position = Vector3(0.0, 2.35, 0.0)
	marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	reference.add_child(marker)

func capture_whole_tree() -> void:
	review_camera.fov = 56.0
	fit_camera_to_recipe(true, false)
	await capture("whole_tree_three_quarter")

func capture_rear_whole_tree() -> void:
	# The tree must be a complete organism from every world-space azimuth. This
	# is a review camera only; no projected silhouette influences generation.
	review_camera.fov = 56.0
	fit_camera_to_recipe(true, true)
	await capture("whole_tree_rear_three_quarter")

func capture_player_at_trunk() -> void:
	var trunk_radius := float(recipe.get("trunkRadius", 2.0))
	review_camera.fov = 64.0
	position_camera(
		Vector3(trunk_radius * 2.15, 1.72, trunk_radius * 2.35),
		Vector3(0.0, 5.6, 0.0)
	)
	await capture("player_at_trunk")

func capture_under_canopy() -> void:
	var trunk_radius := float(recipe.get("trunkRadius", 2.0))
	var crown_base := float(recipe.get("crownBase", 10.0))
	var crown_height := float(recipe.get("crownHeight", 18.0))
	review_camera.fov = 76.0
	position_camera(
		Vector3(trunk_radius * 1.35, 1.72, trunk_radius * 1.20),
		Vector3(0.0, crown_base + crown_height * 0.48, 0.0)
	)
	await capture("underneath_canopy")

func capture_junction_integrity() -> void:
	await capture_junction("junction_integrity", largest_wood_junction())

func capture_lowest_junction_integrity() -> void:
	await capture_junction("lowest_junction_integrity", lowest_wood_junction())

func capture_junction(stage: String, junction: Dictionary) -> void:
	var foliage_root := tree_visual.get_node_or_null("ProceduralTreeFoliage") as Node3D
	if foliage_root != null:
		foliage_root.visible = false
	var position: Vector3 = junction.get("position", Vector3(0.0, 7.0, 0.0))
	var radius := maxf(0.8, float(junction.get("radius", 1.0)))
	review_camera.fov = 54.0
	position_camera(
		position + Vector3(radius * 2.7, radius * 0.48, radius * 3.1),
		position + Vector3.UP * radius * 0.08
	)
	await capture(stage)
	if foliage_root != null:
		foliage_root.visible = true

func capture_branch_skeleton() -> void:
	var foliage_root := tree_visual.get_node_or_null("ProceduralTreeFoliage") as Node3D
	if foliage_root != null:
		foliage_root.visible = false
	review_camera.fov = 56.0
	fit_camera_to_recipe(false, true)
	await capture("branch_skeleton")
	if foliage_root != null:
		foliage_root.visible = true

func position_camera(eye: Vector3, target: Vector3) -> void:
	review_camera.look_at_from_position(eye, target, Vector3.UP)

func fit_camera_to_recipe(include_foliage: bool, reverse_angle: bool) -> void:
	var bounds := recipe_visual_bounds(include_foliage)
	var minimum: Vector3 = bounds.get("minimum", Vector3(-8.0, 0.0, -8.0))
	var maximum: Vector3 = bounds.get("maximum", Vector3(8.0, 30.0, 8.0))
	var size := maximum - minimum
	var target := minimum.lerp(maximum, 0.5)
	target.y = maxf(target.y, size.y * 0.47)
	var half_vertical := size.y * 0.5
	var half_horizontal := maxf(size.x, size.z) * 0.5
	var framing_extent := maxf(half_vertical, half_horizontal * 0.72)
	var distance := framing_extent / tan(deg_to_rad(review_camera.fov * 0.5)) * 1.20
	var direction := Vector3(-0.72 if reverse_angle else 0.72, 0.10, 0.96).normalized()
	position_camera(target + direction * distance, target)

func recipe_visual_bounds(include_foliage: bool) -> Dictionary:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for branch_value in recipe.get("branches", []):
		if not (branch_value is Dictionary):
			continue
		var branch := branch_value as Dictionary
		var radius := maxf(float(branch.get("radiusStart", 0.1)), float(branch.get("radiusEnd", 0.1)))
		for point_value in [branch.get("start", Vector3.ZERO), branch.get("end", Vector3.ZERO)]:
			var point: Vector3 = point_value
			var padding := Vector3.ONE * radius
			minimum = minimum.min(point - padding)
			maximum = maximum.max(point + padding)
	if include_foliage:
		for anchor_value in recipe.get("foliage", []):
			if not (anchor_value is Dictionary):
				continue
			var anchor := anchor_value as Dictionary
			var point: Vector3 = anchor.get("position", Vector3.ZERO)
			var scale: Vector3 = anchor.get("scale", Vector3.ONE)
			var padding := Vector3(absf(scale.x), absf(scale.y), absf(scale.z)) * 0.72
			minimum = minimum.min(point - padding)
			maximum = maximum.max(point + padding)
	if is_inf(minimum.x) or is_inf(maximum.x):
		minimum = Vector3(-8.0, 0.0, -8.0)
		maximum = Vector3(8.0, 30.0, 8.0)
	minimum.y = minf(minimum.y, 0.0)
	return {"minimum": minimum, "maximum": maximum, "size": maximum - minimum}

func largest_wood_junction() -> Dictionary:
	return select_wood_junction(true)

func lowest_wood_junction() -> Dictionary:
	return select_wood_junction(false)

func select_wood_junction(prefer_largest: bool) -> Dictionary:
	var outgoing := {}
	var incoming := {}
	for branch_value in recipe.get("branches", []):
		if not (branch_value is Dictionary):
			continue
		var branch := branch_value as Dictionary
		var parent := int(branch.get("parentNode", -1))
		var child := int(branch.get("childNode", -1))
		if parent < 0 or child < 0:
			continue
		if not outgoing.has(parent):
			outgoing[parent] = []
		(outgoing[parent] as Array).append(branch)
		incoming[child] = branch
	var result := {"position": Vector3(0.0, 7.0, 0.0), "radius": 1.0}
	var selected_measure := -INF if prefer_largest else INF
	for node_value in outgoing.keys():
		var children: Array = outgoing[node_value]
		if children.size() < 2:
			continue
		var radius := 0.0
		var node := int(node_value)
		if incoming.has(node):
			radius = maxf(radius, float((incoming[node] as Dictionary).get("radiusEnd", 0.0)))
		for child_branch in children:
			radius = maxf(radius, float((child_branch as Dictionary).get("radiusStart", 0.0)))
		var position: Vector3 = (children[0] as Dictionary).get("start", Vector3.ZERO)
		var measure := radius if prefer_largest else position.y
		if (prefer_largest and measure > selected_measure) or (not prefer_largest and measure < selected_measure):
			selected_measure = measure
			result = {"position": position, "radius": radius}
	return result

func capture(stage: String) -> void:
	await wait_frames(7)
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var error := image.save_png(path)
	captures.append({
		"stage": stage,
		"path": path,
		"saved": error == OK,
		"size": {"width": image.get_width(), "height": image.get_height()},
		"averageLuminance": average_luminance(image),
		"exactBlackRatio": exact_black_ratio(image),
		"drawCalls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	})

func count_procedural_trees() -> int:
	var count := 0
	for child in get_children():
		if child is Node3D and String(child.get_meta("visual_source", "")) == "procedural_tree_recipe":
			count += 1
	return count

func validate_continuous_wood() -> Dictionary:
	var wood := tree_visual.get_node_or_null("ProceduralTreeContinuousWood") as MeshInstance3D
	if wood == null or not (wood.mesh is ArrayMesh):
		return {"passed": false, "reason": "continuous_wood_mesh_missing"}
	var mesh := wood.mesh as ArrayMesh
	var vertex_count := 0
	if mesh.get_surface_count() == 1:
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		vertex_count = vertices.size()
	return {
		"passed": String(wood.get_meta("tree_wood_topology", "")) == "single_generated_wood_graph_without_segment_caps" \
			and mesh.get_surface_count() == 1 \
			and not bool(wood.get_meta("tree_wood_uses_cylinder_instances", true)) \
			and int(wood.get_meta("tree_wood_segment_count", 0)) == int(recipe.get("branchCount", -1)) \
			and int(wood.get_meta("tree_wood_tube_count", 0)) > 1 \
			and vertex_count > 0 \
			and tree_visual.get_node_or_null("ProceduralTreeBranches") == null,
		"topology": wood.get_meta("tree_wood_topology", ""),
		"surfaceCount": mesh.get_surface_count(),
		"segmentCount": wood.get_meta("tree_wood_segment_count", 0),
		"tubeCount": wood.get_meta("tree_wood_tube_count", 0),
		"junctionCount": wood.get_meta("tree_wood_junction_count", 0),
		"vertexCount": vertex_count,
		"cylinderInstanceNodePresent": tree_visual.get_node_or_null("ProceduralTreeBranches") != null
	}

func all_captures_saved() -> bool:
	for row in captures:
		if not bool(row.get("saved", false)) or not FileAccess.file_exists(String(row.get("path", ""))):
			return false
		if float(row.get("exactBlackRatio", 1.0)) >= 0.02:
			return false
	return true

func average_luminance(image: Image) -> float:
	if image == null or image.is_empty():
		return 0.0
	var total := 0.0
	var sampled := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var color := image.get_pixel(x, y)
			total += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			sampled += 1
	return total / float(maxi(1, sampled))

func exact_black_ratio(image: Image) -> float:
	if image == null or image.is_empty():
		return 1.0
	var black := 0
	var sampled := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var color := image.get_pixel(x, y)
			if color.r + color.g + color.b < 0.004:
				black += 1
			sampled += 1
	return float(black) / float(maxi(1, sampled))

func wait_frames(count: int) -> void:
	for _index in range(count):
		await get_tree().process_frame

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func failure_count() -> int:
	var failures := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failures += 1
	return failures

func finish(exit_code: int, generation_milliseconds := 0.0, publication_milliseconds := 0.0) -> void:
	if finished:
		return
	finished = true
	var failures := failure_count()
	var report := {
		"schemaVersion": 1,
		"runnerId": "mathematical_tree_poc_visual",
		"linearIssues": ["VOX-138", "VOX-140"] if selected_species == "conifer" else (["VOX-138", "VOX-141"] if selected_species == "savanna" else (["VOX-138", "VOX-142"] if selected_species == "bushy_oak" else ["VOX-138", "VOX-139"])),
		"evidenceLevel": "headed_isolated_visual_fixture",
		"scope": "One deterministic mathematical tree in a standalone headed review scene. This proves neither biome/chunk integration nor gameplay, save, NPC, pathfinding, terrain or broad performance acceptance.",
		"finished": true,
		"passed": failures == 0,
		"failureCount": failures,
		"generationMilliseconds": generation_milliseconds,
		"publicationMilliseconds": publication_milliseconds,
		"framesReturnedWhileGenerating": loading_frames,
		"loadingMessageUpdates": loading_message_updates,
		"recipe": {
			"signature": recipe.get("signature", ""),
			"methodology": recipe.get("methodology", ""),
			"architecture": recipe.get("architecture", ""),
			"speciesGrammar": recipe.get("speciesGrammar", ""),
			"seed": recipe.get("seed", 0),
			"maturity": recipe.get("maturity", 0.0),
			"height": recipe.get("height", 0.0),
			"trunkRadius": recipe.get("trunkRadius", 0.0),
			"canopyRadius": recipe.get("canopyRadius", 0.0),
			"crownHeight": recipe.get("crownHeight", 0.0),
			"branchCount": recipe.get("branchCount", 0),
			"foliageClusterCount": recipe.get("foliageClusterCount", 0),
			"stats": recipe.get("stats", {})
		},
		"captures": captures,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify({
		"runnerId": report.runnerId,
		"passed": report.passed,
		"signature": report.recipe.signature,
		"branchCount": report.recipe.branchCount,
		"foliageClusterCount": report.recipe.foliageClusterCount,
		"captureCount": captures.size(),
		"reportPath": report_path
	}))
	get_tree().quit(exit_code)
