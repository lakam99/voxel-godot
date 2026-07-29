extends Node3D

## Headed visual gate for the first civic landmark. The scene owns only neutral
## review lighting and a camera; the Town Hall itself is published from the
## same landmark recipe/blueprint/part path future settlements will consume.

const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")

var selected_style := "masonry"
var selected_seed := 208154
var blueprint
var publisher
var town_hall_root: Node3D
var review_camera: Camera3D
var status_label: Label
var orbit_angle := deg_to_rad(-142.0)
var auto_orbit := false
var capture_path := ""
var report_path := ""


func _ready() -> void:
	read_arguments()
	build_review_world()
	build_hud()
	rebuild_town_hall()
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
		selected_style = "masonry"
	capture_path = OS.get_environment("VOXEL_TOWN_HALL_POC_CAPTURE")
	report_path = OS.get_environment("VOXEL_TOWN_HALL_POC_REPORT")


func build_review_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.45, 0.66, 0.73)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.66, 0.75, 0.84)
	environment.ambient_light_energy = 0.72
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "ReviewSun"
	sun.rotation_degrees = Vector3(-52.0, -32.0, 0.0)
	sun.light_color = Color(1.0, 0.84, 0.62)
	sun.light_energy = 1.70
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 76.0
	add_child(sun)

	var ground := MeshInstance3D.new()
	ground.name = "ReviewGround"
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(84.0, 84.0)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.29, 0.43, 0.25)
	ground_material.roughness = 0.94
	ground.material_override = ground_material
	ground.position.y = -0.012
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)

	var hall_light := OmniLight3D.new()
	hall_light.name = "CivicWarmth"
	hall_light.position = Vector3(0.0, 2.60, -1.45)
	hall_light.light_color = Color(1.0, 0.50, 0.18)
	hall_light.light_energy = 2.25
	hall_light.omni_range = 13.0
	hall_light.shadow_enabled = true
	add_child(hall_light)

	review_camera = Camera3D.new()
	review_camera.name = "ReviewCamera"
	review_camera.current = true
	review_camera.fov = 57.0
	add_child(review_camera)
	update_camera()


func build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.045, 0.070, 0.88)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(660.0, 123.0)
	layer.add_child(panel)
	status_label = Label.new()
	status_label.position = Vector2(38.0, 34.0)
	status_label.size = Vector2(625.0, 96.0)
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.add_theme_color_override("font_color", Color("e7eff5"))
	layer.add_child(status_label)


func rebuild_town_hall() -> void:
	if town_hall_root != null and is_instance_valid(town_hall_root):
		town_hall_root.queue_free()
	town_hall_root = Node3D.new()
	town_hall_root.name = "PublishedTownHall_%s" % selected_style.capitalize()
	add_child(town_hall_root)
	blueprint = LandmarkBuildingBlueprintBuilderScript.build(selected_seed, "town_hall", {
		"settlementTier": "town",
		"biome": "temperate",
		"siteKey": "civic-square",
		"style": selected_style
	})
	publisher = BuildingPartPublisherScript.new()
	publisher.publish(blueprint, town_hall_root)
	update_hud()


func update_hud() -> void:
	if status_label == null or blueprint == null or publisher == null:
		return
	var stats: Dictionary = publisher.summary()
	var recipe: Dictionary = blueprint.recipe
	status_label.text = "LANDMARK BUILDING POC  |  TOWN HALL  |  %s\nseed %d  /  %.1fm x %.1fm  /  public hall + archive + steward office\n%d shared blueprint parts  /  %d collision volumes  /  %d visual batches\n[1] timber civic hall   [2] masonry civic hall   [R] new deterministic seed   [Q/E] orbit   [Space] auto orbit" % [selected_style.to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), int(stats.get("publishedPartCount", 0)), int(stats.get("collisionPartCount", 0)), int(stats.get("visualBatchCount", 0))]


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
			rebuild_town_hall()
		KEY_2:
			selected_style = "masonry"
			rebuild_town_hall()
		KEY_R:
			selected_seed += 1
			rebuild_town_hall()
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
	var radius := 29.0
	review_camera.position = Vector3(sin(orbit_angle) * radius, 13.6, cos(orbit_angle) * radius)
	review_camera.look_at(Vector3(0.0, 3.35, 0.0), Vector3.UP)


func write_automated_report() -> void:
	for _frame in range(12):
		await get_tree().process_frame
	var stats: Dictionary = publisher.summary() if publisher != null else {}
	var report := {
		"runnerId": "town_hall_poc",
		"evidenceLevel": "headed-visual-fixture",
		"status": "passed" if blueprint != null and int(stats.get("publishedPartCount", 0)) > 0 and int(stats.get("collisionPartCount", 0)) > 0 else "failed",
		"family": "town_hall",
		"style": selected_style,
		"seed": selected_seed,
		"blueprintSignature": hash(blueprint.deterministic_signature()) if blueprint != null else 0,
		"publication": stats,
		"notes": "The Town Hall is published from LandmarkBuildingRecipeSampler and LandmarkBuildingBlueprintBuilder through the ordinary BuildingPartPublisher. This visual fixture does not yet prove live settlement integration or player walkthrough behavior."
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
