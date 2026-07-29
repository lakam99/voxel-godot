extends Node3D

## Headed review fixture for VOX-207. The scene creates only neutral review
## lighting/camera; the cottage itself comes from the shared pure blueprint and
## BuildingPartPublisher used by future runtime structure publication.

const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")

var selected_style := "timber"
var selected_seed := 207154
var blueprint
var publisher
var cottage_root: Node3D
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
	environment.background_color = Color(0.49, 0.68, 0.74)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.68, 0.76, 0.84)
	environment.ambient_light_energy = 0.72
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "ReviewSun"
	sun.rotation_degrees = Vector3(-54.0, -28.0, 0.0)
	sun.light_color = Color(1.0, 0.84, 0.63)
	sun.light_energy = 1.65
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 44.0
	add_child(sun)

	var ground := MeshInstance3D.new()
	ground.name = "ReviewGround"
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(42.0, 42.0)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.31, 0.46, 0.28)
	ground_material.roughness = 0.94
	ground.material_override = ground_material
	ground.position.y = -0.012
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)

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
	cottage_root = Node3D.new()
	cottage_root.name = "PublishedCottage_%s" % selected_style.capitalize()
	add_child(cottage_root)
	blueprint = CottageBlueprintBuilderScript.build(selected_seed, selected_style)
	publisher = BuildingPartPublisherScript.new()
	publisher.publish(blueprint, cottage_root)
	update_hud()


func update_hud() -> void:
	if status_label == null or blueprint == null or publisher == null:
		return
	var stats: Dictionary = publisher.summary()
	status_label.text = "CONSTRUCTION-MATERIAL COTTAGE  |  %s\nseed %d  •  2 rooms  •  %d authoritative parts  •  %d collision volumes  •  %d visual batches\n[1] timber frame + planks   [2] brick masonry   [R] new deterministic seed   [Q/E] orbit   [Space] auto orbit" % [selected_style.to_upper(), selected_seed, int(stats.get("publishedPartCount", 0)), int(stats.get("collisionPartCount", 0)), int(stats.get("visualBatchCount", 0))]


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
	for _frame in range(12):
		await get_tree().process_frame
	var stats: Dictionary = publisher.summary() if publisher != null else {}
	var report := {
		"runnerId": "cottage_material_poc",
		"evidenceLevel": "headed-visual-fixture",
		"status": "passed" if blueprint != null and int(stats.get("publishedPartCount", 0)) > 0 and int(stats.get("collisionPartCount", 0)) > 0 else "failed",
		"style": selected_style,
		"seed": selected_seed,
		"blueprintSignature": hash(blueprint.deterministic_signature()) if blueprint != null else 0,
		"publication": stats,
		"notes": "The fixture publishes its cottage through the reusable material-aware blueprint and part publisher. Visual review still determines whether the architecture reads well."
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
