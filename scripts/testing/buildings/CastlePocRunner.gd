extends Node3D

## Headed exterior review fixture for the first composed fortress. It consumes
## the same deterministic castle compound and shared construction publisher
## intended for later city placement; this scene supplies only review lighting
## and an orbit camera.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")

var selected_seed := 208154
var selected_citadel_scale := 0.0
var blueprint
var publisher
var castle_root: Node3D
var review_camera: Camera3D
var status_label: Label
var orbit_angle := deg_to_rad(-138.0)
var review_distance_scale := 1.34
var review_height_scale := 1.10
var review_focus_x := 0.0
var review_focus_z := 0.0
var auto_orbit := false
var capture_path := ""
var report_path := ""
var review_ground: MeshInstance3D


func _ready() -> void:
	read_arguments()
	build_review_world()
	build_hud()
	rebuild_castle()
	if not report_path.is_empty():
		call_deferred("write_automated_report")


func read_arguments() -> void:
	for index in range(OS.get_cmdline_user_args().size()):
		var args := OS.get_cmdline_user_args()
		var argument := String(args[index])
		if argument == "--seed" and index + 1 < args.size():
			selected_seed = int(String(args[index + 1]))
		elif argument == "--citadel-scale" and index + 1 < args.size():
			selected_citadel_scale = clampf(float(String(args[index + 1])), 0.0, 6.0)
		elif argument == "--orbit-degrees" and index + 1 < args.size():
			orbit_angle = deg_to_rad(float(String(args[index + 1])))
		elif argument == "--review-distance-scale" and index + 1 < args.size():
			review_distance_scale = clampf(float(String(args[index + 1])), 0.20, 2.00)
		elif argument == "--review-height-scale" and index + 1 < args.size():
			review_height_scale = clampf(float(String(args[index + 1])), 0.05, 2.00)
		elif argument == "--review-focus-x" and index + 1 < args.size():
			review_focus_x = float(String(args[index + 1]))
		elif argument == "--review-focus-z" and index + 1 < args.size():
			review_focus_z = float(String(args[index + 1]))
	capture_path = OS.get_environment("VOXEL_CASTLE_POC_CAPTURE")
	report_path = OS.get_environment("VOXEL_CASTLE_POC_REPORT")


func build_review_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.39, 0.60, 0.70)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.63, 0.72, 0.82)
	environment.ambient_light_energy = 0.72
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-49.0, -36.0, 0.0)
	sun.light_color = Color(1.0, 0.84, 0.64)
	sun.light_energy = 1.76
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 180.0
	add_child(sun)
	review_ground = MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(180.0, 180.0)
	review_ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.23, 0.39, 0.22)
	ground_material.roughness = 0.96
	review_ground.material_override = ground_material
	review_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(review_ground)
	var warmth := OmniLight3D.new()
	warmth.position = Vector3(0.0, 7.5, -16.0)
	warmth.light_color = Color(1.0, 0.42, 0.14)
	warmth.light_energy = 4.0
	warmth.omni_range = 35.0
	add_child(warmth)
	review_camera = Camera3D.new()
	review_camera.current = true
	review_camera.fov = 54.0
	add_child(review_camera)


func build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.045, 0.070, 0.88)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(760.0, 122.0)
	layer.add_child(panel)
	status_label = Label.new()
	status_label.position = Vector2(38.0, 34.0)
	status_label.size = Vector2(720.0, 96.0)
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.add_theme_color_override("font_color", Color("e7eff5"))
	layer.add_child(status_label)


func rebuild_castle() -> void:
	if castle_root != null and is_instance_valid(castle_root):
		castle_root.queue_free()
	castle_root = Node3D.new()
	castle_root.name = "PublishedCastle"
	add_child(castle_root)
	blueprint = CastleCompoundBlueprintBuilderScript.build(selected_seed, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": selected_citadel_scale})
	publisher = BuildingPartPublisherScript.new()
	publisher.publish(blueprint, castle_root)
	update_camera()
	update_hud()


func update_camera() -> void:
	if review_camera == null or blueprint == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var span := maxf(float(recipe.get("width", 42.0)), float(recipe.get("depth", 42.0)))
	if review_ground != null and review_ground.mesh is PlaneMesh:
		var ground_mesh: PlaneMesh = review_ground.mesh as PlaneMesh
		ground_mesh.size = Vector2(span * 1.40, span * 1.40)
	var radius := span * review_distance_scale
	var target_y := float(recipe.get("wallHeight", 15.0)) * 0.48
	var target := Vector3(review_focus_x, target_y, review_focus_z)
	# Larger compounded footprints need a proportionally higher survey position;
	# otherwise valid courtyard buildings disappear behind their own curtain wall.
	# This is an exterior survey camera only: the actual construction remains the
	# shared blueprint and publisher path, not a separate review-only layout.
	review_camera.position = target + Vector3(sin(orbit_angle) * radius, maxf(14.0, radius * review_height_scale), cos(orbit_angle) * radius)
	review_camera.look_at(target, Vector3.UP)


func update_hud() -> void:
	if status_label == null or blueprint == null or publisher == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var stats: Dictionary = publisher.summary()
	var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
	var courtyard_program: Array = grammar.get("courtyardProgram", []) as Array
	var program_kinds: Array[String] = []
	for building_value in courtyard_program:
		if building_value is Dictionary:
			program_kinds.append(String((building_value as Dictionary).get("kind", "building")))
	status_label.text = "COMPOUND BUILDING POC  |  CASTLE\nseed %d  /  %s  /  scale %.2fx  /  %.1fm x %.1fm  /  %d towers + curtain walls + gatehouse + keep\ncourtyard: %.1fm x %.1fm  /  %d seed-derived buildings: %s\n%d shared blueprint parts  /  %d collision volumes  /  %d visual batches\n[R] new deterministic seed  [Q/E] orbit  [Space] auto orbit" % [selected_seed, String(grammar.get("profile", "fortress")).replace("_", " ").to_upper(), float(grammar.get("grandScale", 1.0)), float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), int(recipe.get("towerCount", 4)), float(grammar.get("courtyardWidth", 0.0)), float(grammar.get("courtyardDepth", 0.0)), courtyard_program.size(), ", ".join(program_kinds), int(stats.get("publishedPartCount", 0)), int(stats.get("collisionPartCount", 0)), int(stats.get("visualBatchCount", 0))]


func _process(delta: float) -> void:
	if auto_orbit:
		orbit_angle += delta * 0.16
		update_camera()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			selected_seed += 1
			rebuild_castle()
		KEY_Q:
			orbit_angle -= deg_to_rad(9.0)
			update_camera()
		KEY_E:
			orbit_angle += deg_to_rad(9.0)
			update_camera()
		KEY_SPACE:
			auto_orbit = not auto_orbit


func write_automated_report() -> void:
	for _frame in range(12):
		await get_tree().process_frame
	var stats: Dictionary = publisher.summary() if publisher != null else {}
	var report := {
		"runnerId": "castle_poc",
		"evidenceLevel": "headed-visual-fixture",
		"status": "passed" if blueprint != null and int(stats.get("publishedPartCount", 0)) > 0 and int(stats.get("collisionPartCount", 0)) > 0 else "failed",
		"family": "castle",
		"seed": selected_seed,
		"orbitDegrees": rad_to_deg(orbit_angle),
		"recipe": blueprint.recipe if blueprint != null else {},
		"blueprintSignature": hash(blueprint.deterministic_signature()) if blueprint != null else 0,
		"publication": stats,
		"notes": "The castle is composed from the deterministic member recipe list through CastleCompoundBlueprintBuilder and BuildingPartPublisher. This fixture verifies the exterior compound silhouette only; it does not prove an accessible castle interior or settlement integration."
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
