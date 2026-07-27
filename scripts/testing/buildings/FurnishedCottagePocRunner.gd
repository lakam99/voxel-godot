extends Node3D

## Headed visual gate for room-aware furniture and decor. The cottage shell,
## room records and furnishings all come from production-shaped data builders;
## the dollhouse view only hides already-published visual children for review.

const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const CottageFurnishingPlannerScript := preload("res://scripts/buildings/CottageFurnishingPlanner.gd")
const FurnishingPublisherScript := preload("res://scripts/buildings/FurnishingPublisher.gd")

var selected_style := "timber"
var selected_seed := 207154
var review_view := "dollhouse"
var blueprint
var furnishing_plan
var building_publisher
var furnishing_publisher
var cottage_root: Node3D
var furnishing_root: Node3D
var review_camera: Camera3D
var status_label: Label
var orbit_angle := deg_to_rad(-152.0)
var auto_orbit := false
var capture_path := ""
var report_path := ""


func _ready() -> void:
	read_arguments()
	build_review_world()
	build_hud()
	rebuild_fixture()
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
		elif argument == "--view" and index + 1 < args.size():
			review_view = String(args[index + 1]).strip_edges().to_lower()
	if selected_style not in ["timber", "masonry"]:
		selected_style = "timber"
	if review_view not in ["exterior", "dollhouse", "hearth", "sleeping"]:
		review_view = "dollhouse"
	capture_path = OS.get_environment("VOXEL_FURNISHED_COTTAGE_POC_CAPTURE")
	report_path = OS.get_environment("VOXEL_FURNISHED_COTTAGE_POC_REPORT")


func build_review_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.38, 0.56, 0.63)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.66, 0.74, 0.82)
	environment.ambient_light_energy = 0.76
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "ReviewSun"
	sun.rotation_degrees = Vector3(-54.0, -28.0, 0.0)
	sun.light_color = Color(1.0, 0.84, 0.63)
	sun.light_energy = 1.55
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 44.0
	add_child(sun)

	var ground := MeshInstance3D.new()
	ground.name = "ReviewGround"
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(42.0, 42.0)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.27, 0.40, 0.24)
	ground_material.roughness = 0.94
	ground.material_override = ground_material
	ground.position.y = -0.012
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)

	var hearth_light := OmniLight3D.new()
	hearth_light.name = "HearthWarmth"
	hearth_light.position = Vector3(-3.28, 1.55, 2.20)
	hearth_light.light_color = Color(1.0, 0.37, 0.09)
	hearth_light.light_energy = 2.7
	hearth_light.omni_range = 8.0
	hearth_light.shadow_enabled = true
	add_child(hearth_light)

	var sleeping_light := OmniLight3D.new()
	sleeping_light.name = "SleepingCandleWarmth"
	sleeping_light.position = Vector3(1.72, 1.72, 1.30)
	sleeping_light.light_color = Color(1.0, 0.64, 0.30)
	sleeping_light.light_energy = 0.95
	sleeping_light.omni_range = 4.0
	add_child(sleeping_light)

	review_camera = Camera3D.new()
	review_camera.name = "ReviewCamera"
	review_camera.current = true
	review_camera.fov = 62.0
	add_child(review_camera)


func build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.045, 0.070, 0.88)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(680.0, 148.0)
	layer.add_child(panel)
	status_label = Label.new()
	status_label.position = Vector2(38.0, 34.0)
	status_label.size = Vector2(645.0, 122.0)
	status_label.add_theme_font_size_override("font_size", 17)
	status_label.add_theme_color_override("font_color", Color("e7eff5"))
	layer.add_child(status_label)


func rebuild_fixture() -> void:
	if cottage_root != null and is_instance_valid(cottage_root):
		cottage_root.queue_free()
	if furnishing_root != null and is_instance_valid(furnishing_root):
		furnishing_root.queue_free()
	blueprint = CottageBlueprintBuilderScript.build(selected_seed, selected_style)
	cottage_root = Node3D.new()
	cottage_root.name = "PublishedCottage_%s" % selected_style.capitalize()
	add_child(cottage_root)
	building_publisher = BuildingPartPublisherScript.new()
	building_publisher.publish(blueprint, cottage_root)
	furnishing_plan = CottageFurnishingPlannerScript.build(blueprint, selected_seed * 7919 + 37)
	furnishing_root = Node3D.new()
	furnishing_root.name = "PublishedFurnishings"
	add_child(furnishing_root)
	furnishing_publisher = FurnishingPublisherScript.new()
	furnishing_publisher.publish(furnishing_plan, furnishing_root)
	apply_review_view()
	update_hud()


func apply_review_view() -> void:
	var cutaway := review_view == "dollhouse"
	if cottage_root != null:
		for child in cottage_root.get_children():
			if not child is StaticBody3D:
				continue
			var part_id := String((child as StaticBody3D).get_meta("building_part_id", ""))
			var hide_part := cutaway and (part_id.begins_with("front_") or part_id.begins_with("roof_") or part_id == "ridge" or part_id == "chimney" or part_id == "frame_0" or part_id == "frame_1")
			for visual in child.get_children():
				if visual is VisualInstance3D:
					(visual as VisualInstance3D).visible = not hide_part
	update_camera()


func update_hud() -> void:
	if status_label == null or blueprint == null or furnishing_plan == null:
		return
	var building_stats: Dictionary = building_publisher.summary() if building_publisher != null else {}
	var furnishing_stats: Dictionary = furnishing_publisher.summary() if furnishing_publisher != null else {}
	var recipe: Dictionary = blueprint.recipe
	call_deferred("apply_seeded_recipe_hud")
	status_label.text = "FURNISHED COTTAGE  |  %s  |  %s VIEW\nseed %d  -  %.1fm x %.1fm  -  %.1fm walls / %.1fm roof  -  %s\n%d structure parts  -  %d furnishing records  -  %d furnishing collision volumes\n[1] exterior  [2] dollhouse  [3] hearth room  [4] sleeping room  [R] next seed  [Q/E] orbit  [Space] auto" % [selected_style.to_upper(), review_view.to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), float(recipe.get("wallHeight", 0.0)), float(recipe.get("roofRise", 0.0)), String(recipe.get("furnishingProfile", "")), int(building_stats.get("publishedPartCount", 0)), furnishing_plan.parts.size(), int(furnishing_stats.get("collisionPartCount", 0))]
	status_label.text = "FURNISHED COTTAGE  |  %s  |  %s VIEW\nseed %d  â€¢  %d structure parts  â€¢  %d furnishing records  â€¢  %d furnishing collision volumes\n[1] exterior  [2] dollhouse  [3] hearth room  [4] sleeping room  [R] seed  [Q/E] orbit  [Space] auto" % [selected_style.to_upper(), review_view.to_upper(), selected_seed, int(building_stats.get("publishedPartCount", 0)), furnishing_plan.parts.size(), int(furnishing_stats.get("collisionPartCount", 0))]


func apply_seeded_recipe_hud() -> void:
	if status_label == null or blueprint == null or furnishing_plan == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var building_stats: Dictionary = building_publisher.summary() if building_publisher != null else {}
	var furnishing_stats: Dictionary = furnishing_publisher.summary() if furnishing_publisher != null else {}
	status_label.text = "FURNISHED COTTAGE  |  %s  |  %s VIEW\nseed %d  -  %.1fm x %.1fm  -  %.1fm walls / %.1fm roof  -  %s\n%d structure parts  -  %d furnishing records  -  %d furnishing collision volumes\n[1] exterior  [2] dollhouse  [3] hearth room  [4] sleeping room  [R] next seed  [Q/E] orbit  [Space] auto" % [selected_style.to_upper(), review_view.to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), float(recipe.get("wallHeight", 0.0)), float(recipe.get("roofRise", 0.0)), String(recipe.get("furnishingProfile", "")), int(building_stats.get("publishedPartCount", 0)), furnishing_plan.parts.size(), int(furnishing_stats.get("collisionPartCount", 0))]


func _process(delta: float) -> void:
	if auto_orbit and review_view in ["exterior", "dollhouse"]:
		orbit_angle += delta * 0.24
		update_camera()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_1:
			review_view = "exterior"
			apply_review_view()
			update_hud()
		KEY_2:
			review_view = "dollhouse"
			apply_review_view()
			update_hud()
		KEY_3:
			review_view = "hearth"
			apply_review_view()
			update_hud()
		KEY_4:
			review_view = "sleeping"
			apply_review_view()
			update_hud()
		KEY_R:
			selected_seed += 1
			rebuild_fixture()
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
	match review_view:
		"hearth":
			review_camera.position = Vector3(-3.78, 2.15, -2.65)
			review_camera.look_at(Vector3(-1.82, 1.08, 0.22), Vector3.UP)
		"sleeping":
			review_camera.position = Vector3(3.96, 2.12, -2.62)
			review_camera.look_at(Vector3(2.16, 1.04, 0.62), Vector3.UP)
		_:
			var radius := 15.8
			review_camera.position = Vector3(sin(orbit_angle) * radius, 8.2, cos(orbit_angle) * radius)
			review_camera.look_at(Vector3(0.0, 2.05, 0.18), Vector3.UP)


func write_automated_report() -> void:
	for _frame in range(12):
		await get_tree().process_frame
	var building_stats: Dictionary = building_publisher.summary() if building_publisher != null else {}
	var furnishing_stats: Dictionary = furnishing_publisher.summary() if furnishing_publisher != null else {}
	var report := {
		"runnerId": "furnished_cottage_poc",
		"evidenceLevel": "headed-visual-fixture",
		"status": "passed" if blueprint != null and furnishing_plan != null and not furnishing_plan.parts.is_empty() else "failed",
		"style": selected_style,
		"seed": selected_seed,
		"view": review_view,
		"blueprintSignature": hash(blueprint.deterministic_signature()) if blueprint != null else 0,
		"furnishingSignature": hash(furnishing_plan.deterministic_signature()) if furnishing_plan != null else 0,
		"buildingPublication": building_stats,
		"furnishingPublication": furnishing_stats,
		"notes": "Furniture and decor derive from the cottage room records through the reusable furnishing planner and publisher. Dollhouse view only hides published shell visuals for inspection."
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
