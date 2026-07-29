extends Node3D

## Headed visual gate for the first residential landmark. The manor exists
## only through the shared landmark recipe -> blueprint -> BuildingPartPublisher
## path, so this review scene cannot accidentally become a hand-authored asset.

const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")

var selected_style := "timber"
var selected_seed := 208154
var blueprint
var publisher
var manor_root: Node3D
var review_camera: Camera3D
var status_label: Label
var orbit_angle := deg_to_rad(-138.0)
var auto_orbit := false
var capture_path := ""
var report_path := ""


func _ready() -> void:
	read_arguments()
	build_review_world()
	build_hud()
	rebuild_manor()
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
		elif argument == "--orbit-degrees" and index + 1 < args.size():
			orbit_angle = deg_to_rad(float(String(args[index + 1])))
	if selected_style not in ["timber", "masonry"]:
		selected_style = "timber"
	capture_path = OS.get_environment("VOXEL_MANOR_POC_CAPTURE")
	report_path = OS.get_environment("VOXEL_MANOR_POC_REPORT")


func build_review_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.44, 0.64, 0.72)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.68, 0.75, 0.83)
	environment.ambient_light_energy = 0.76
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "ManorReviewSun"
	sun.rotation_degrees = Vector3(-50.0, -36.0, 0.0)
	sun.light_color = Color(1.0, 0.84, 0.62)
	sun.light_energy = 1.72
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 94.0
	add_child(sun)

	var ground := MeshInstance3D.new()
	ground.name = "ManorReviewGround"
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(112.0, 112.0)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.27, 0.42, 0.24)
	ground_material.roughness = 0.94
	ground.material_override = ground_material
	ground.position.y = -0.012
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)

	var warmth := OmniLight3D.new()
	warmth.name = "ManorWindowWarmth"
	warmth.position = Vector3(-2.8, 4.6, -2.4)
	warmth.light_color = Color(1.0, 0.48, 0.16)
	warmth.light_energy = 2.10
	warmth.omni_range = 16.0
	warmth.shadow_enabled = true
	add_child(warmth)

	review_camera = Camera3D.new()
	review_camera.name = "ManorReviewCamera"
	review_camera.current = true
	review_camera.fov = 55.0
	add_child(review_camera)


func build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.045, 0.070, 0.88)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(700.0, 123.0)
	layer.add_child(panel)
	status_label = Label.new()
	status_label.position = Vector2(38.0, 34.0)
	status_label.size = Vector2(665.0, 96.0)
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.add_theme_color_override("font_color", Color("e7eff5"))
	layer.add_child(status_label)


func rebuild_manor() -> void:
	if manor_root != null and is_instance_valid(manor_root):
		manor_root.queue_free()
	manor_root = Node3D.new()
	manor_root.name = "PublishedManor_%s" % selected_style.capitalize()
	add_child(manor_root)
	blueprint = LandmarkBuildingBlueprintBuilderScript.build(selected_seed, "manor", {
		"settlementTier": "town",
		"biome": "forest",
		"siteKey": "ridge-manor",
		"style": selected_style
	})
	publisher = BuildingPartPublisherScript.new()
	publisher.publish(blueprint, manor_root)
	update_camera()
	update_hud()


func update_hud() -> void:
	if status_label == null or blueprint == null or publisher == null:
		return
	var stats: Dictionary = publisher.summary()
	var recipe: Dictionary = blueprint.recipe
	status_label.text = "LANDMARK BUILDING POC  |  MANOR  |  %s\nseed %d  /  %.1fm x %.1fm  /  %d storeys  /  projected solar + service wing + stair tower\n%d shared blueprint parts  /  %d collision volumes  /  %d visual batches\n[1] timber manor   [2] masonry manor   [R] new deterministic seed   [Q/E] orbit   [Space] auto orbit" % [selected_style.to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), int(recipe.get("floorCount", 0)), int(stats.get("publishedPartCount", 0)), int(stats.get("collisionPartCount", 0)), int(stats.get("visualBatchCount", 0))]


func _process(delta: float) -> void:
	if auto_orbit:
		orbit_angle += delta * 0.18
		update_camera()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_1:
			selected_style = "timber"
			rebuild_manor()
		KEY_2:
			selected_style = "masonry"
			rebuild_manor()
		KEY_R:
			selected_seed += 1
			rebuild_manor()
		KEY_Q:
			orbit_angle -= deg_to_rad(9.0)
			update_camera()
		KEY_E:
			orbit_angle += deg_to_rad(9.0)
			update_camera()
		KEY_SPACE:
			auto_orbit = not auto_orbit


func update_camera() -> void:
	if review_camera == null or blueprint == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var radius := maxf(float(recipe.get("width", 20.0)), float(recipe.get("depth", 15.0))) * 1.52
	var target_y := float(recipe.get("floorHeight", 3.5)) * 1.12
	review_camera.position = Vector3(sin(orbit_angle) * radius, target_y + 8.4, cos(orbit_angle) * radius)
	review_camera.look_at(Vector3(0.0, target_y, 0.0), Vector3.UP)


func write_automated_report() -> void:
	for _frame in range(12):
		await get_tree().process_frame
	var stats: Dictionary = publisher.summary() if publisher != null else {}
	var report := {
		"runnerId": "manor_poc",
		"evidenceLevel": "headed-visual-fixture",
		"status": "passed" if blueprint != null and int(stats.get("publishedPartCount", 0)) > 0 and int(stats.get("collisionPartCount", 0)) > 0 else "failed",
		"family": "manor",
		"style": selected_style,
		"seed": selected_seed,
		"orbitDegrees": rad_to_deg(orbit_angle),
		"blueprintSignature": hash(blueprint.deterministic_signature()) if blueprint != null else 0,
		"publication": stats,
		"notes": "The manor is published from LandmarkBuildingRecipeSampler and LandmarkBuildingBlueprintBuilder through BuildingPartPublisher. This visual fixture verifies the generated silhouette only; it does not yet prove a playable interior or settlement integration."
	}
	if not capture_path.is_empty():
		get_viewport().get_texture().get_image().save_png(capture_path)
		report["capturePath"] = capture_path
	if not report_path.is_empty():
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	get_tree().quit(0 if String(report.get("status", "failed")) == "passed" else 1)
