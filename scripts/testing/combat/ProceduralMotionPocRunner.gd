extends Node3D

const MotionRecipeBuilderScript := preload("res://scripts/combat/motion/MotionRecipeBuilder.gd")
const MotionInstanceScript := preload("res://scripts/combat/motion/MotionInstance.gd")
const MotionStackScript := preload("res://scripts/combat/motion/MotionStack.gd")
const MotionAfterimageRendererScript := preload("res://scripts/combat/presentation/MotionAfterimageRenderer.gd")
const MotionVolumeRecipeBuilderScript := preload("res://scripts/combat/contact/MotionVolumeRecipeBuilder.gd")
const MotionVolumeSamplerScript := preload("res://scripts/combat/contact/MotionVolumeSampler.gd")
const MotionVolumeRendererScript := preload("res://scripts/combat/poc/MotionVolumeRenderer.gd")
const PassiveContactSphereScript := preload("res://scripts/combat/contact/PassiveContactSphere.gd")
const MotionContactResolverScript := preload("res://scripts/combat/contact/MotionContactResolver.gd")
const MotionContactResolutionRendererScript := preload("res://scripts/combat/poc/MotionContactResolutionRenderer.gd")

const CAPTURE_SIZE := Vector2i(1280, 720)
const PRIMARY_SEED := 1543
const SECONDARY_SEED := 7651

var report_path := ""
var screenshot_dir := ""
var automated_review := false
var auto_play := false
var review_seconds := 0.0
var review_camera: Camera3D
var afterimages
var volume_renderer
var resolution_renderer
var title_label: Label
var detail_label: Label
var current_stack
var current_volume_recipe
var current_passive_geometries: Array = []
var current_resolutions: Array = []
var current_time := 0.92
var current_mode := "single"
var current_seed := PRIMARY_SEED
var paused := false
var elapsed := 0.0
var playback_rate := 1.0
var show_volume_overlay := true
var captures: Array[Dictionary] = []
var results: Array[Dictionary] = []


func _ready() -> void:
	configure_paths()
	configure_window()
	setup_scene()
	if afterimages == null or volume_renderer == null or resolution_renderer == null:
		add_result("afterimage_presentation_adapter_loaded", false, {"reason": "MotionAfterimageRenderer did not instantiate"})
		finish(1)
		return
	set_case("single", PRIMARY_SEED, 0.0 if auto_play else 0.50)
	if auto_play:
		paused = false
	if automated_review:
		call_deferred("run_capture_review")


func _process(delta: float) -> void:
	if automated_review or paused or afterimages == null:
		return
	elapsed += delta * playback_rate
	current_time = fposmod(elapsed * 0.38, 1.0)
	refresh_presentation_at(current_time)


func _unhandled_key_input(event: InputEvent) -> void:
	if automated_review or not event.is_pressed() or event.is_echo():
		return
	if event.keycode == KEY_1:
		select_case("single", PRIMARY_SEED)
	elif event.keycode == KEY_2:
		select_case("single", SECONDARY_SEED)
	elif event.keycode == KEY_3:
		select_case("stack_synchronized", PRIMARY_SEED)
	elif event.keycode == KEY_4:
		select_case("stack_staggered", PRIMARY_SEED)
	elif event.keycode == KEY_SPACE:
		paused = not paused
	elif event.keycode == KEY_LEFT:
		scrub_time(-0.04)
	elif event.keycode == KEY_RIGHT:
		scrub_time(0.04)
	elif event.keycode == KEY_COMMA:
		playback_rate = maxf(0.20, playback_rate / 1.35)
		update_overlay()
	elif event.keycode == KEY_PERIOD:
		playback_rate = minf(3.20, playback_rate * 1.35)
		update_overlay()
	elif event.keycode == KEY_R:
		elapsed = 0.0
		current_time = 0.0
		refresh_presentation_at(current_time)
		update_overlay()
	elif event.keycode == KEY_V:
		show_volume_overlay = not show_volume_overlay
		refresh_presentation_at(current_time)
		update_overlay()


func configure_paths() -> void:
	automated_review = OS.get_environment("VOXEL_PROCEDURAL_MOTION_POC_AUTORUN").strip_edges() == "1"
	auto_play = OS.get_environment("VOXEL_PROCEDURAL_MOTION_POC_AUTOPLAY").strip_edges() == "1"
	var requested_playback_rate := OS.get_environment("VOXEL_PROCEDURAL_MOTION_POC_PLAYBACK_RATE").strip_edges()
	if requested_playback_rate.is_valid_float():
		playback_rate = clampf(float(requested_playback_rate), 0.05, 3.20)
	report_path = OS.get_environment("VOXEL_PROCEDURAL_MOTION_POC_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/combat/procedural-motion-poc/report.json")
	screenshot_dir = OS.get_environment("VOXEL_PROCEDURAL_MOTION_POC_SCREENSHOT_DIR").strip_edges()
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/combat/procedural-motion-poc/screenshots")
	review_seconds = maxf(0.0, float(OS.get_environment("VOXEL_PROCEDURAL_MOTION_POC_REVIEW_SECONDS")) if OS.get_environment("VOXEL_PROCEDURAL_MOTION_POC_REVIEW_SECONDS").is_valid_float() else 0.0)
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(screenshot_dir)


func configure_window() -> void:
	DisplayServer.window_set_title("Procedural Motion Afterimage PoC")
	DisplayServer.window_set_size(CAPTURE_SIZE)
	get_tree().root.size = CAPTURE_SIZE
	get_tree().root.content_scale_size = CAPTURE_SIZE


func setup_scene() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("101827")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("8ca4c5")
	environment.ambient_light_energy = 0.46
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	add_child(world_environment)

	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color("d9ecff")
	key_light.light_energy = 1.14
	key_light.rotation_degrees = Vector3(-49.0, -30.0, 0.0)
	key_light.shadow_enabled = true
	add_child(key_light)
	var rim_light := OmniLight3D.new()
	rim_light.light_color = Color("5ed8ff")
	rim_light.light_energy = 3.6
	rim_light.omni_range = 12.0
	rim_light.position = Vector3(-3.2, 4.8, 2.0)
	add_child(rim_light)

	var ground := MeshInstance3D.new()
	var ground_mesh := CylinderMesh.new()
	ground_mesh.top_radius = 6.2
	ground_mesh.bottom_radius = 6.2
	ground_mesh.height = 0.12
	ground_mesh.radial_segments = 48
	ground.mesh = ground_mesh
	ground.position.y = -0.08
	ground.material_override = ground_material()
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(ground)
	add_local_axes()

	review_camera = Camera3D.new()
	review_camera.fov = 52.0
	review_camera.near = 0.06
	review_camera.far = 80.0
	review_camera.current = true
	add_child(review_camera)
	# Automated captures set their own angle. This default keeps the interactive
	# slow-motion tool framed at a gameplay-height view from its very first frame.
	review_camera.look_at_from_position(Vector3(0.0, 1.68, 4.8), Vector3(0.0, 1.04, -1.05), Vector3.UP)

	afterimages = MotionAfterimageRendererScript.new()
	afterimages.name = "MotionAfterimagePresentation"
	add_child(afterimages)
	volume_renderer = MotionVolumeRendererScript.new()
	volume_renderer.name = "MotionContactVolumePresentation"
	add_child(volume_renderer)
	resolution_renderer = MotionContactResolutionRendererScript.new()
	resolution_renderer.name = "MotionContactResolutionPresentation"
	add_child(resolution_renderer)
	setup_overlay()


func setup_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 4
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.04, 0.07, 0.84)
	panel.position = Vector2(22.0, 22.0)
	panel.size = Vector2(530.0, 122.0)
	layer.add_child(panel)
	title_label = Label.new()
	title_label.position = Vector2(43.0, 39.0)
	title_label.add_theme_font_size_override("font_size", 25)
	title_label.add_theme_color_override("font_color", Color("e1f1ff"))
	layer.add_child(title_label)
	detail_label = Label.new()
	detail_label.position = Vector2(43.0, 77.0)
	detail_label.add_theme_font_size_override("font_size", 16)
	detail_label.add_theme_color_override("font_color", Color("a8c6df"))
	layer.add_child(detail_label)
	var controls := Label.new()
	controls.position = Vector2(30.0, 671.0)
	controls.add_theme_font_size_override("font_size", 15)
	controls.add_theme_color_override("font_color", Color("b6c7dd"))
	controls.text = "[1] Seed 1543  [2] Seed 7651  [3] together  [4] staggered  [V] volumes  [←/→] scrub  [,/.] speed  [Space] pause  [R] replay"
	layer.add_child(controls)


func set_case(mode: String, seed: int, preview_time: float) -> void:
	current_mode = mode
	current_seed = seed
	current_time = preview_time
	elapsed = current_time / 0.38
	paused = true
	current_stack = build_stack(mode, seed)
	current_volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(seed)
	current_passive_geometries = build_passive_geometries()
	afterimages.set_stack(current_stack)
	volume_renderer.set_stack(current_stack)
	volume_renderer.set_volume_recipe(current_volume_recipe)
	refresh_presentation_at(current_time)
	update_overlay()


func select_case(mode: String, seed: int) -> void:
	var preview_time := 0.0 if auto_play else (0.56 if mode == "stack_staggered" else 0.50)
	set_case(mode, seed, preview_time)
	if auto_play:
		paused = false


func build_stack(mode: String, seed: int):
	var primary_recipe = MotionRecipeBuilderScript.build_side_arc(seed)
	var first = MotionInstanceScript.new({
		"instanceId": "motion_a",
		"recipe": primary_recipe,
		"anchorId": "anchor_left",
		"anchorOffset": Vector3(-0.58 if mode.begins_with("stack") else 0.0, 0.0, 0.0),
		"direction": 1.0
	})
	if mode == "single":
		return MotionStackScript.new("single_side_arc", [first])
	var second = MotionInstanceScript.new({
		"instanceId": "motion_b",
		"recipe": MotionRecipeBuilderScript.build_side_arc(seed + 6108),
		"anchorId": "anchor_right",
		"anchorOffset": Vector3(0.58, 0.0, 0.0),
		"direction": -1.0,
		"startOffset": 0.14 if mode == "stack_staggered" else 0.0,
		"timeScale": 0.82 if mode == "stack_staggered" else 1.0
	})
	return MotionStackScript.new(mode, [first, second])


func build_passive_geometries() -> Array:
	# This static sphere is test-fixture geometry only. Its role is to make the
	# shared sampled motion visibly resolve against an inspectable passive shape;
	# it is not a game enemy, item, or a target-selection rule.
	return [
		PassiveContactSphereScript.new({
			"geometryId": "review_orb",
			"center": Vector3(1.04, 1.00, -1.62),
			"radius": 0.32
		})
	]


func refresh_presentation_at(time: float) -> void:
	afterimages.render_at(time, 17)
	if show_volume_overlay:
		volume_renderer.render_at(time)
	else:
		volume_renderer.clear_visuals()
	current_resolutions = current_resolutions_at(time)
	resolution_renderer.render_geometries(current_passive_geometries, current_resolutions)


func current_resolutions_at(time: float) -> Array:
	var resolutions: Array = []
	if current_stack == null or current_volume_recipe == null:
		return resolutions
	for volume in MotionVolumeSamplerScript.samples_for_stack(current_stack, current_volume_recipe, time):
		for passive_geometry in current_passive_geometries:
			var resolution = MotionContactResolverScript.resolve_volume(volume, passive_geometry)
			if resolution.resolved:
				resolutions.append(resolution)
	return resolutions


func update_overlay() -> void:
	var instance_count := (current_stack.instances as Array).size() if current_stack != null else 0
	title_label.text = "SIDE ARC MOTION  |  %s" % current_mode.to_upper()
	var plane_tilt: float = 0.0
	if current_stack != null and not (current_stack.instances as Array).is_empty():
		var first_instance = (current_stack.instances as Array)[0]
		if first_instance != null and first_instance.recipe != null:
			plane_tilt = float(first_instance.recipe.parameters.get("attackPlaneTiltDegrees", 0.0))
	detail_label.text = "seed %d  •  %d independent motion object%s  •  white motion / amber capsule / blue-resolves-warm orb  •  plane %+.0f°  •  %.2fx" % [current_seed, instance_count, "" if instance_count == 1 else "s", plane_tilt, playback_rate]


func scrub_time(delta: float) -> void:
	paused = true
	current_time = clampf(current_time + delta, 0.0, 1.0)
	elapsed = current_time / 0.38
	refresh_presentation_at(current_time)


func run_capture_review() -> void:
	var review_cases := [
		{"name": "single_seed_1543_windup_gameplay_height", "mode": "single", "seed": PRIMARY_SEED, "time": 0.14, "eye": Vector3(0.0, 1.68, 4.8), "target": Vector3(0.0, 1.04, -1.05)},
		{"name": "single_seed_1543_front", "mode": "single", "seed": PRIMARY_SEED, "time": 0.50, "eye": Vector3(5.8, 4.0, 9.8), "target": Vector3(0.0, 1.05, -0.7)},
		{"name": "single_seed_1543_gameplay_height", "mode": "single", "seed": PRIMARY_SEED, "time": 0.50, "eye": Vector3(0.0, 1.68, 4.8), "target": Vector3(0.0, 1.04, -1.05)},
		{"name": "single_seed_7651_front", "mode": "single", "seed": SECONDARY_SEED, "time": 0.50, "eye": Vector3(5.8, 4.0, 9.8), "target": Vector3(0.0, 1.05, -0.7)},
		{"name": "single_seed_1543_side", "mode": "single", "seed": PRIMARY_SEED, "time": 0.50, "eye": Vector3(10.6, 3.0, 1.1), "target": Vector3(0.0, 1.00, -0.8)},
		{"name": "stack_synchronized", "mode": "stack_synchronized", "seed": PRIMARY_SEED, "time": 0.50, "eye": Vector3(6.4, 4.6, 10.8), "target": Vector3(0.0, 1.00, -0.8)},
		{"name": "stack_staggered", "mode": "stack_staggered", "seed": PRIMARY_SEED, "time": 0.56, "eye": Vector3(6.4, 4.6, 10.8), "target": Vector3(0.0, 1.00, -0.8)},
		{"name": "stack_staggered_elevated", "mode": "stack_staggered", "seed": PRIMARY_SEED, "time": 0.56, "eye": Vector3(-6.7, 8.0, 7.7), "target": Vector3(0.0, 0.92, -0.8)}
	]
	for review_case in review_cases:
		set_case(String(review_case.get("mode", "single")), int(review_case.get("seed", PRIMARY_SEED)), float(review_case.get("time", 0.92)))
		review_camera.look_at_from_position(review_case.get("eye", Vector3(6.0, 4.0, 10.0)), review_case.get("target", Vector3.ZERO), Vector3.UP)
		await capture(String(review_case.get("name", "motion_review")))
	add_result("full_motion_contact_and_passive_geometry_review_saved", captures.size() == review_cases.size() and all_captures_saved() and captures_have_visible_volumes() and capture_includes_windup_preview() and capture_includes_resolution_contrast(), {"captures": captures})
	add_result("review_covers_two_seeds_stack_timings_gameplay_height_windup_and_resolution", captures.size() == 8, {"seeds": [PRIMARY_SEED, SECONDARY_SEED], "modes": ["single", "stack_synchronized", "stack_staggered"], "includesGameplayHeight": true, "includesWindup": true, "includesResolution": true})
	if review_seconds > 0.0:
		await get_tree().create_timer(review_seconds).timeout
	finish(0 if failure_count() == 0 else 1)


func capture(name: String) -> void:
	await wait_frames(4)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % name)
	var error := image.save_png(path)
	var active_volumes: Array = MotionVolumeSamplerScript.samples_for_stack(current_stack, current_volume_recipe, current_time) if current_stack != null and current_volume_recipe != null else []
	var visible_volumes: Array = MotionVolumeSamplerScript.geometry_samples_for_stack(current_stack, current_volume_recipe, current_time) if current_stack != null and current_volume_recipe != null else []
	captures.append({
		"name": name,
		"path": path,
		"saved": error == OK,
		"size": {"width": image.get_width(), "height": image.get_height()},
		"mode": current_mode,
		"seed": current_seed,
		"normalizedTime": current_time,
		"recipe": current_stack.snapshot() if current_stack != null else {},
		"volumeRecipe": current_volume_recipe.snapshot() if current_volume_recipe != null else {},
		"volumeOverlay": show_volume_overlay,
		"activeVolumeCount": active_volumes.size(),
		"visibleVolumeCount": visible_volumes.size(),
		"passiveGeometries": snapshots_for(current_passive_geometries),
		"resolutionCount": current_resolutions.size(),
		"resolutions": snapshots_for(current_resolutions)
	})


func wait_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().process_frame


func all_captures_saved() -> bool:
	for capture_data in captures:
		if not bool(capture_data.get("saved", false)):
			return false
	return true


func captures_have_visible_volumes() -> bool:
	for capture_data in captures:
		if not bool(capture_data.get("volumeOverlay", false)) or int(capture_data.get("visibleVolumeCount", 0)) <= 0:
			return false
	return true


func capture_includes_windup_preview() -> bool:
	for capture_data in captures:
		if String(capture_data.get("name", "")) == "single_seed_1543_windup_gameplay_height":
			return int(capture_data.get("activeVolumeCount", -1)) == 0 and int(capture_data.get("visibleVolumeCount", 0)) > 0
	return false


func capture_includes_resolution_contrast() -> bool:
	var windup_is_clear := false
	var arc_resolves := false
	for capture_data in captures:
		if String(capture_data.get("name", "")) == "single_seed_1543_windup_gameplay_height":
			windup_is_clear = int(capture_data.get("resolutionCount", -1)) == 0
		elif String(capture_data.get("name", "")) == "single_seed_1543_front":
			arc_resolves = int(capture_data.get("resolutionCount", 0)) > 0
	return windup_is_clear and arc_resolves


func snapshots_for(samples: Array) -> Array:
	var snapshots: Array = []
	for sample in samples:
		if sample != null and sample.has_method("snapshot"):
			snapshots.append(sample.snapshot())
	return snapshots


func add_result(name: String, passed: bool, details: Dictionary = {}) -> void:
	results.append({"name": name, "passed": passed, "details": details})


func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count


func finish(exit_code: int) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report := {
		"schemaVersion": 1,
		"runnerId": "procedural_motion_poc",
		"evidenceLevel": "visual_poc",
		"passed": exit_code == 0,
		"resultCount": results.size(),
		"failureCount": failure_count(),
		"captures": captures,
		"results": results,
		"scope": "isolated motion/contact-volume/passive-geometry proof only; no engine physics query, damage, AI, rig, save, or live-game integration"
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	get_tree().quit(exit_code)


func ground_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("182b3b")
	material.metallic = 0.18
	material.roughness = 0.48
	return material


func add_local_axes() -> void:
	var axes := [
		{"direction": Vector3.RIGHT, "color": Color("ff6576")},
		{"direction": Vector3.UP, "color": Color("7fe58d")},
		{"direction": Vector3.FORWARD, "color": Color("5cbcff")}
	]
	for axis in axes:
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.025
		mesh.bottom_radius = 0.025
		mesh.height = 2.0
		mesh.radial_segments = 5
		var marker := MeshInstance3D.new()
		marker.mesh = mesh
		marker.material_override = axis_material(axis.get("color", Color.WHITE))
		var direction: Vector3 = axis.get("direction", Vector3.UP)
		marker.position = direction
		marker.basis = Basis(Quaternion(Vector3.UP, direction.normalized()))
		marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(marker)


func axis_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color * 0.45
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material
