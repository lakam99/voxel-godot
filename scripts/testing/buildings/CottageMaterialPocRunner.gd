extends Node3D

## Headed review fixture for VOX-207. The scene creates only neutral review
## lighting/camera; the cottage itself comes from the shared pure blueprint and
## BuildingPartPublisher used by future runtime structure publication.

const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const CottageFurnishingPlannerScript := preload("res://scripts/buildings/CottageFurnishingPlanner.gd")
const BuildingInteriorProgramScript := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const FurnishingPublisherScript := preload("res://scripts/buildings/FurnishingPublisher.gd")
const ConstructionMaterialCatalogScript := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")

var selected_style := "timber"
var selected_seed := 207154
var blueprint
var publisher
var cottage_root: Node3D
var furnishing_plan
var furnishing_publisher
var furnishing_root: Node3D
var review_camera: Camera3D
var status_label: Label
var orbit_angle := deg_to_rad(-152.0)
var auto_orbit := false
var capture_path := ""
var report_path := ""
var generated_tree_count := 0
var ecology_backed_tree_count := 0
var reused_groundcover_count := 0


func _ready() -> void:
	read_arguments()
	build_review_world()
	build_hud()
	rebuild_cottage()
	if not report_path.is_empty():
		call_deferred("write_automated_report")


func read_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		var argument := String(args[index])
		if argument == "--style" and index + 1 < args.size():
			selected_style = String(args[index + 1]).strip_edges().to_lower()
		elif argument == "--seed" and index + 1 < args.size():
			selected_seed = int(String(args[index + 1]))
	if selected_style not in ["timber", "masonry"]:
		selected_style = "timber"
	capture_path = OS.get_environment("VOXEL_COTTAGE_POC_CAPTURE")
	report_path = OS.get_environment("VOXEL_COTTAGE_POC_REPORT")


func build_review_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.36, 0.40, 0.40)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.64, 0.66, 0.62)
	environment.ambient_light_energy = 0.82
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "ReviewSun"
	sun.rotation_degrees = Vector3(-54.0, -28.0, 0.0)
	sun.light_color = Color(0.96, 0.79, 0.60)
	sun.light_energy = 1.38
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 44.0
	add_child(sun)

	var ground := MeshInstance3D.new()
	ground.name = "ReviewGround"
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(42.0, 42.0)
	ground.mesh = ground_mesh
	ground.material_override = ConstructionMaterialCatalogScript.create_material("wall_growth", -0.035)
	ground.position.y = -0.012
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	add_review_path_and_trees()

	var interior_light := OmniLight3D.new()
	interior_light.name = "CottageWarmth"
	interior_light.position = Vector3(-1.75, 2.45, 0.48)
	interior_light.light_color = Color(1.0, 0.53, 0.22)
	interior_light.light_energy = 2.4
	interior_light.omni_range = 8.5
	interior_light.shadow_enabled = true
	add_child(interior_light)

	review_camera = Camera3D.new()
	review_camera.name = "ReviewCamera"
	review_camera.current = true
	review_camera.fov = 58.0
	add_child(review_camera)
	update_camera()


func add_review_path_and_trees() -> void:
	var path := MeshInstance3D.new()
	path.name = "CottageCobbleApproach"
	var path_mesh := BoxMesh.new()
	path_mesh.size = Vector3(2.8, 0.10, 9.4)
	path.mesh = path_mesh
	path.position = Vector3(-2.32, 0.035, -7.7)
	path.material_override = ConstructionMaterialCatalogScript.create_material("cobblestone", -0.035)
	add_child(path)
	add_review_path_history()
	var tree_service = TreeSpawnServiceScript.new()
	var request_builder = TreeRuntimeRequestBuilderScript.new()
	var environment_catalog = BiomeEnvironmentCatalogScript.new()
	if not environment_catalog.setup():
		return
	var town_profile = environment_catalog.profile_for_biome("town")
	var placements := [Vector3(-7.2, 0.0, -0.4), Vector3(6.8, 0.0, 1.4)]
	for index in range(placements.size()):
		add_tree_contact_patch(placements[index] as Vector3, index)
		var tree_position := placements[index] as Vector3
		var tree_id := "cottage-review-%d:%d,%d:%02d" % [selected_seed, roundi(tree_position.x), roundi(tree_position.z), index]
		var request: Dictionary = request_builder.build(town_profile, "town", tree_id, 6.4 + float(index) * 0.8, Vector2i(roundi(tree_position.x), roundi(tree_position.z)), str(selected_seed))
		request["treeId"] = tree_id
		request["worldSeed"] = str(selected_seed)
		request["biome"] = "town"
		request["presentation"] = "runtime"
		var tree: Node3D = tree_service.spawn_tree(request)
		if tree == null:
			continue
		tree.name = "CottageGeneratedTree%02d" % index
		tree.position = placements[index] as Vector3
		tree.rotation.y = float(index) * 1.31
		add_child(tree)
		generated_tree_count += 1
		ecology_backed_tree_count += 1
	add_reused_tree_groundcover(placements)
	add_reused_path_groundcover()


func add_review_path_history() -> void:
	for patch_index in range(10):
		var phase := fposmod(sin(float(patch_index + 1) * 17.17 + float(selected_seed) * 0.013) * 23171.7, 1.0)
		var side := -1.0 if patch_index % 2 == 0 else 1.0
		var patch := MeshInstance3D.new()
		patch.name = "CottagePathHistory%02d" % patch_index
		var patch_mesh := CylinderMesh.new()
		var radius := 0.11 + phase * 0.14
		patch_mesh.top_radius = radius
		patch_mesh.bottom_radius = radius * 1.04
		patch_mesh.height = 0.008
		patch_mesh.radial_segments = 9 + patch_index % 4
		patch.mesh = patch_mesh
		patch.position = Vector3(-2.32 + side * (1.46 + phase * 0.20), 0.093 + float(patch_index % 3) * 0.001, -11.7 + float(patch_index / 2) * 1.18 + (phase - 0.5) * 0.28)
		patch.scale.z = 0.68 + phase * 0.34
		patch.rotation.y = phase * TAU
		var material_id := "wall_growth" if patch_index % 4 in [0, 1] else ("ground_soil" if patch_index % 4 == 2 else "leaf_litter")
		patch.material_override = ConstructionMaterialCatalogScript.create_material(material_id, -0.05 + phase * 0.035)
		patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(patch)


func add_tree_contact_patch(center: Vector3, index: int) -> void:
	var offsets := [Vector3.ZERO, Vector3(-0.42, 0.0, 0.18), Vector3(0.38, 0.0, -0.24), Vector3(0.16, 0.0, 0.46), Vector3(-0.20, 0.0, -0.44)]
	for patch_index in range(offsets.size()):
		var patch := MeshInstance3D.new()
		patch.name = "CottageTreeContact%02d_%02d" % [index, patch_index]
		var patch_mesh := CylinderMesh.new()
		var radius := 0.38 + float((index + patch_index * 2) % 3) * 0.09
		patch_mesh.top_radius = radius
		patch_mesh.bottom_radius = radius * 1.02
		patch_mesh.height = 0.006
		patch_mesh.radial_segments = 9 + (patch_index % 3)
		patch.mesh = patch_mesh
		patch.position = center + (offsets[patch_index] as Vector3).rotated(Vector3.UP, float(index) * 0.71) + Vector3(0.0, 0.003 + float(patch_index) * 0.001, 0.0)
		patch.scale.z = 0.68 + float((patch_index + 1) % 3) * 0.11
		patch.rotation.y = float(index * 5 + patch_index) * 0.79
		var patch_material := "ground_soil" if patch_index < 2 else ("leaf_litter" if patch_index < 4 else "wall_growth")
		patch.material_override = ConstructionMaterialCatalogScript.create_material(patch_material, -0.04 + float(patch_index) * 0.012)
		patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(patch)


func add_reused_tree_groundcover(tree_placements: Array) -> void:
	var registry = VisualAssetRegistryScript.new()
	if not registry.setup():
		return
	var offsets := [Vector3(-0.62, 0.02, 0.35), Vector3(0.54, 0.02, -0.48), Vector3(0.22, 0.02, 0.68), Vector3(-0.34, 0.02, -0.72), Vector3(0.76, 0.02, 0.14)]
	for tree_index in range(tree_placements.size()):
		var tree_position: Vector3 = tree_placements[tree_index] as Vector3
		for offset_index in range(offsets.size()):
			var bush: Node3D = registry.instantiate_family("bush", "cottage-groundcover:%d:%d:%d" % [selected_seed, tree_index, offset_index])
			if bush == null:
				continue
			bush.name = "CottageGroundcover%02d_%02d" % [tree_index, offset_index]
			bush.position = tree_position + (offsets[offset_index] as Vector3).rotated(Vector3.UP, float(tree_index) * 1.31)
			bush.scale = Vector3.ONE * (0.48 + float((tree_index + offset_index) % 3) * 0.08)
			bush.rotation.y = float(tree_index * 4 + offset_index) * 0.73
			add_child(bush)
			reused_groundcover_count += 1


func add_reused_path_groundcover() -> void:
	var registry = VisualAssetRegistryScript.new()
	if not registry.setup():
		return
	for index in range(6):
		var bush: Node3D = registry.instantiate_family("bush", "cottage-path-edge:%d:%d" % [selected_seed, index])
		if bush == null:
			continue
		var side := -1.0 if index % 2 == 0 else 1.0
		bush.name = "CottagePathEdgeGrowth%02d" % index
		bush.position = Vector3(-2.32 + side * (1.48 + float(index % 3) * 0.08), 0.02, -10.8 + float(index) * 1.18)
		bush.scale = Vector3.ONE * (0.20 + float(index % 3) * 0.045)
		bush.rotation.y = float(index) * 1.07
		add_child(bush)
		reused_groundcover_count += 1


func build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.045, 0.070, 0.88)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(570.0, 123.0)
	layer.add_child(panel)
	status_label = Label.new()
	status_label.position = Vector2(38.0, 34.0)
	status_label.size = Vector2(530.0, 96.0)
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.add_theme_color_override("font_color", Color("e7eff5"))
	layer.add_child(status_label)


func rebuild_cottage() -> void:
	if cottage_root != null and is_instance_valid(cottage_root):
		cottage_root.queue_free()
	if furnishing_root != null and is_instance_valid(furnishing_root):
		furnishing_root.queue_free()
	cottage_root = Node3D.new()
	cottage_root.name = "PublishedCottage_%s" % selected_style.capitalize()
	add_child(cottage_root)
	blueprint = CottageBlueprintBuilderScript.build(selected_seed, selected_style)
	publisher = BuildingPartPublisherScript.new()
	publisher.publish(blueprint, cottage_root)
	furnishing_plan = CottageFurnishingPlannerScript.build(blueprint, selected_seed * 7919 + 37)
	furnishing_root = Node3D.new()
	furnishing_root.name = "PublishedCottageFurnishings"
	add_child(furnishing_root)
	furnishing_publisher = FurnishingPublisherScript.new()
	furnishing_publisher.publish(furnishing_plan, furnishing_root)
	update_hud()


func update_hud() -> void:
	if status_label == null or blueprint == null or publisher == null:
		return
	var stats: Dictionary = publisher.summary()
	var furnishing_count: int = furnishing_plan.parts.size() if furnishing_plan != null else 0
	status_label.text = "CONSTRUCTION-MATERIAL COTTAGE  |  %s\nseed %d  •  2 rooms  •  %d shell parts  •  %d furnished records  •  %d collision volumes\n[1] timber frame + planks   [2] brick masonry   [R] new deterministic seed   [Q/E] orbit   [Space] auto orbit" % [selected_style.to_upper(), selected_seed, int(stats.get("publishedPartCount", 0)), furnishing_count, int(stats.get("collisionPartCount", 0))]


func _process(delta: float) -> void:
	if auto_orbit:
		orbit_angle += delta * 0.24
		update_camera()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_1:
			selected_style = "timber"
			rebuild_cottage()
		KEY_2:
			selected_style = "masonry"
			rebuild_cottage()
		KEY_R:
			selected_seed += 1
			rebuild_cottage()
		KEY_Q:
			orbit_angle -= deg_to_rad(9.0)
			update_camera()
		KEY_E:
			orbit_angle += deg_to_rad(9.0)
			update_camera()
		KEY_SPACE:
			auto_orbit = not auto_orbit


func update_camera() -> void:
	if review_camera == null:
		return
	var radius := 15.8
	review_camera.position = Vector3(sin(orbit_angle) * radius, 8.2, cos(orbit_angle) * radius)
	review_camera.look_at(Vector3(0.0, 2.35, 0.0), Vector3.UP)


func write_automated_report() -> void:
	for child in get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false
	for _frame in range(12):
		await get_tree().process_frame
	var stats: Dictionary = publisher.summary() if publisher != null else {}
	var furnishing_stats: Dictionary = furnishing_publisher.summary() if furnishing_publisher != null else {}
	var window_sightlines := BuildingInteriorProgramScript.audit_plan(blueprint, furnishing_plan)
	var capture_saved := false
	if not capture_path.is_empty():
		var viewport_texture := get_viewport().get_texture()
		var viewport_image := viewport_texture.get_image() if viewport_texture != null else null
		capture_saved = viewport_image != null and viewport_image.save_png(capture_path) == OK
	var publication_passed := blueprint != null and int(stats.get("publishedPartCount", 0)) > 0 and int(stats.get("collisionPartCount", 0)) > 0 and bool(window_sightlines.get("passed", false))
	var report := {
		"runnerId": "cottage_material_poc",
		"evidenceLevel": "headed_visual_capture" if capture_saved else "recipe_publication_without_visual_acceptance",
		"status": "passed" if publication_passed and (capture_path.is_empty() or capture_saved) else "failed",
		"style": selected_style,
		"seed": selected_seed,
		"generatedTreeCount": generated_tree_count,
		"ecologyBackedTreeCount": ecology_backed_tree_count,
		"reusedGroundcoverCount": reused_groundcover_count,
		"captureRequested": not capture_path.is_empty(),
		"captureSaved": capture_saved,
		"blueprintSignature": hash(blueprint.deterministic_signature()) if blueprint != null else 0,
		"publication": stats,
		"furnishingPublication": furnishing_stats,
		"windowSightlines": window_sightlines,
		"notes": "The fixture publishes its cottage shell and room-derived furnishing plan through their shared authorities. Visual review still determines whether the architecture reads well."
	}
	if capture_saved:
		report["capturePath"] = capture_path
	if not report_path.is_empty():
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	get_tree().quit(0 if String(report.get("status", "failed")) == "passed" else 1)
