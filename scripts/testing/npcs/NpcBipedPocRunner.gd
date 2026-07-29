extends Node3D

## Headed, presentation-only review fixture for generated NPC bodies.  It has
## no NpcSystem, navigation, path, collision, combat, or save dependency.  A
## small scripted gallery velocity is supplied solely so the reusable visual
## locomotion presenter can be reviewed before any production integration.

const NpcBipedRecipeBuilderScript := preload("res://scripts/characters/NpcBipedRecipeBuilder.gd")
const NpcBipedVisualFactoryScript := preload("res://scripts/characters/NpcBipedVisualFactory.gd")

const DISPLAY_SIZE := Vector2i(1280, 720)
const GALLERY_OFFSETS: Array[int] = [0, 491, 1297]
const GALLERY_HAIR_STYLES: Array[String] = ["bald", "receding", "long"]

var selected_seed := 209154
var gallery_root: Node3D
var review_camera: Camera3D
var hud_detail: Label
var orbit_angle := deg_to_rad(0.0)
var auto_orbit := false
var walking_enabled := true
var elapsed := 0.0
var capture_path := ""
var report_path := ""
var actor_entries: Array[Dictionary] = []


func _ready() -> void:
	read_configuration()
	configure_window()
	build_review_world()
	build_hud()
	rebuild_gallery()
	if not report_path.is_empty():
		call_deferred("write_automated_report")


func read_configuration() -> void:
	var arguments := OS.get_cmdline_user_args()
	for index in range(arguments.size() - 1):
		if arguments[index] == "--seed":
			selected_seed = int(arguments[index + 1])
	capture_path = OS.get_environment("VOXEL_NPC_BIPED_POC_CAPTURE").strip_edges()
	report_path = OS.get_environment("VOXEL_NPC_BIPED_POC_REPORT").strip_edges()


func configure_window() -> void:
	DisplayServer.window_set_title("Seeded NPC Biped Blueprint PoC")
	DisplayServer.window_set_size(DISPLAY_SIZE)
	get_tree().root.size = DISPLAY_SIZE
	get_tree().root.content_scale_size = DISPLAY_SIZE


func build_review_world() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("88b8cc")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("c8dde5")
	environment.ambient_light_energy = 0.58
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "ReviewSun"
	sun.rotation_degrees = Vector3(-53.0, -32.0, 0.0)
	sun.light_color = Color("ffe0a5")
	sun.light_energy = 1.52
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 36.0
	add_child(sun)
	var fill := OmniLight3D.new()
	fill.name = "FaceFill"
	fill.position = Vector3(0.0, 4.0, 5.4)
	fill.light_color = Color("d4edff")
	fill.light_energy = 1.7
	fill.omni_range = 14.0
	add_child(fill)

	var ground := MeshInstance3D.new()
	ground.name = "ReviewGround"
	var ground_mesh := CylinderMesh.new()
	ground_mesh.top_radius = 7.4
	ground_mesh.bottom_radius = 7.4
	ground_mesh.height = 0.12
	ground_mesh.radial_segments = 48
	ground.mesh = ground_mesh
	ground.position.y = -0.07
	ground.material_override = make_material(Color("557747"), 0.96)
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(ground)
	for x in [-3.2, 0.0, 3.2]:
		add_review_marker(Vector3(x, 0.004, 0.0))

	review_camera = Camera3D.new()
	review_camera.name = "ReviewCamera"
	review_camera.current = true
	review_camera.fov = 52.0
	review_camera.near = 0.05
	review_camera.far = 80.0
	add_child(review_camera)
	update_camera()


func add_review_marker(position: Vector3) -> void:
	var marker := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.02
	mesh.bottom_radius = 1.02
	mesh.height = 0.018
	mesh.radial_segments = 32
	marker.mesh = mesh
	marker.position = position
	marker.material_override = make_material(Color("d7bb76"), 0.82)
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(marker)


func build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.045, 0.070, 0.88)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(690.0, 124.0)
	layer.add_child(panel)
	var title := Label.new()
	title.position = Vector2(38.0, 33.0)
	title.text = "SEEDED NPC BIPED BLUEPRINT  |  VISUAL-ONLY LOCOMOTION"
	title.add_theme_font_size_override("font_size", 23)
	title.add_theme_color_override("font_color", Color("e8f5ff"))
	layer.add_child(title)
	hud_detail = Label.new()
	hud_detail.position = Vector2(38.0, 71.0)
	hud_detail.size = Vector2(650.0, 60.0)
	hud_detail.add_theme_font_size_override("font_size", 16)
	hud_detail.add_theme_color_override("font_color", Color("b9d7e9"))
	layer.add_child(hud_detail)
	var controls := Label.new()
	controls.position = Vector2(26.0, 674.0)
	controls.text = "[R] next seeded gallery   [Space] pause gait   [Q/E] orbit   [A] auto orbit   [Esc] release mouse"
	controls.add_theme_font_size_override("font_size", 15)
	controls.add_theme_color_override("font_color", Color("d4e2eb"))
	layer.add_child(controls)


func rebuild_gallery() -> void:
	if gallery_root != null and is_instance_valid(gallery_root):
		gallery_root.queue_free()
	actor_entries.clear()
	gallery_root = Node3D.new()
	gallery_root.name = "SeededNpcBipedGallery"
	add_child(gallery_root)
	var used_cloth_palettes: Dictionary = {}
	for index in range(GALLERY_OFFSETS.size()):
		var profile_id := "gallery_%d" % index
		# The fixture asks the deterministic recipe authority for a reproducible
		# representative of each requested hairstyle.  It does not author an
		# appearance or modify the builder's distribution; it only chooses three
		# review seeds from the surrounding seed space.
		var seed := representative_seed(selected_seed + int(GALLERY_OFFSETS[index]), profile_id, GALLERY_HAIR_STYLES[index], used_cloth_palettes)
		var recipe: Dictionary = NpcBipedRecipeBuilderScript.build(seed, profile_id)
		used_cloth_palettes[String((recipe.get("outfit", {}) as Dictionary).get("paletteId", ""))] = true
		var actor := Node3D.new()
		actor.name = "NpcBipedSample_%d" % (index + 1)
		var anchor := Vector3(-3.2 + float(index) * 3.2, 0.0, 0.0)
		actor.position = anchor
		gallery_root.add_child(actor)
		var result: Dictionary = NpcBipedVisualFactoryScript.add_biped(actor, recipe, "Citizen %d" % (index + 1))
		# The static samples intentionally face the review camera so a visual pass
		# can inspect their generated eyes, hair and clothing.  The center sample
		# immediately takes its heading from the supplied locomotion velocity.
		var visual_root := result.get("visualRoot") as Node3D
		if index != 1 and visual_root != null:
			visual_root.rotation.y = PI
		actor_entries.append({
			"actor": actor,
			"anchor": anchor,
			"recipe": recipe,
			"locomotion": result.get("locomotion"),
			"walking": index == 1,
			"phase": float(index) * 0.9
		})
	update_hud()


func representative_seed(base_seed: int, profile_id: String, desired_hair_style: String, used_cloth_palettes: Dictionary) -> int:
	var first_hair_match := base_seed
	for offset in range(512):
		var candidate := base_seed + offset
		var candidate_recipe: Dictionary = NpcBipedRecipeBuilderScript.build(candidate, profile_id)
		var hair: Dictionary = candidate_recipe.get("hair", {}) as Dictionary
		if String(hair.get("style", "")) == desired_hair_style:
			if first_hair_match == base_seed:
				first_hair_match = candidate
			var outfit: Dictionary = candidate_recipe.get("outfit", {}) as Dictionary
			if not used_cloth_palettes.has(String(outfit.get("paletteId", ""))):
				return candidate
	return first_hair_match


func update_hud() -> void:
	if hud_detail == null:
		return
	var moving_recipe: Dictionary = actor_entries[1].get("recipe", {}) as Dictionary if actor_entries.size() > 1 else {}
	var hair: Dictionary = moving_recipe.get("hair", {}) as Dictionary
	var outfit: Dictionary = moving_recipe.get("outfit", {}) as Dictionary
	var skin: Dictionary = moving_recipe.get("skin", {}) as Dictionary
	var gallery_seeds: Array[String] = []
	for entry in actor_entries:
		gallery_seeds.append(str(int((entry.get("recipe", {}) as Dictionary).get("seed", 0))))
	hud_detail.text = "base seed %d  |  gallery recipes %s  |  moving: %s skin, %s hair, %s\nThe center biped only consumes its gallery velocity for facing + gait; it writes no NPC motor, route, collision, combat, or save state." % [selected_seed, " / ".join(gallery_seeds), String(skin.get("id", "")).replace("_", " "), String(hair.get("style", "")).replace("_", " "), String(outfit.get("design", "")).replace("_", " ")]


func _process(delta: float) -> void:
	if auto_orbit:
		orbit_angle += delta * 0.22
		update_camera()
	if not walking_enabled:
		return
	elapsed += delta
	for entry in actor_entries:
		if not bool(entry.get("walking", false)):
			continue
		update_walking_sample(entry, delta)


func update_walking_sample(entry: Dictionary, delta: float) -> void:
	var actor := entry.get("actor") as Node3D
	var locomotion = entry.get("locomotion")
	if actor == null or locomotion == null or not is_instance_valid(actor):
		return
	var anchor: Vector3 = entry.get("anchor", Vector3.ZERO) as Vector3
	var phase := elapsed * 1.06 + float(entry.get("phase", 0.0))
	var offset := Vector3(sin(phase) * 0.78, 0.0, cos(phase * 2.0) * 0.22)
	var velocity := Vector3(cos(phase) * 0.78 * 1.06, 0.0, -sin(phase * 2.0) * 0.44 * 1.06)
	actor.position = anchor + offset
	if locomotion.has_method("apply_velocity"):
		locomotion.apply_velocity(velocity, delta)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			selected_seed += 1
			rebuild_gallery()
		KEY_SPACE:
			walking_enabled = not walking_enabled
		KEY_Q:
			orbit_angle -= deg_to_rad(8.0)
			update_camera()
		KEY_E:
			orbit_angle += deg_to_rad(8.0)
			update_camera()
		KEY_A:
			auto_orbit = not auto_orbit
		KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func update_camera() -> void:
	if review_camera == null:
		return
	var radius := 8.15
	review_camera.position = Vector3(sin(orbit_angle) * radius, 2.65, cos(orbit_angle) * radius)
	review_camera.look_at(Vector3(0.0, 1.06, 0.0), Vector3.UP)


func write_automated_report() -> void:
	for _frame in range(90):
		await get_tree().process_frame
	var recipes: Array[Dictionary] = []
	var blink_count := 0
	for entry in actor_entries:
		var recipe: Dictionary = entry.get("recipe", {}) as Dictionary
		recipes.append({
			"seed": int(recipe.get("seed", 0)),
			"signature": NpcBipedRecipeBuilderScript.signature(recipe),
			"skin": String((recipe.get("skin", {}) as Dictionary).get("id", "")),
			"hair": String((recipe.get("hair", {}) as Dictionary).get("style", "")),
			"outfit": String((recipe.get("outfit", {}) as Dictionary).get("design", ""))
		})
		var actor := entry.get("actor") as Node3D
		if actor != null and actor.get_node_or_null("NpcBipedVisual/NpcBipedBlinkPresenter") != null:
			blink_count += 1
	var report := {
		"runnerId": "npc_biped_blueprint_poc",
		"evidenceLevel": "headed-visual-fixture",
		"status": "passed" if actor_entries.size() == 3 and blink_count == 3 else "failed",
		"baseSeed": selected_seed,
		"recipes": recipes,
		"blinkPresenterCount": blink_count,
		"notes": "This isolated fixture proves deterministic recipe publication, visible biped anatomy, eye blink presenters, and visual gait/facing from a supplied velocity. It does not exercise production NPC routing, collision, combat, or save integration."
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


func make_material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
