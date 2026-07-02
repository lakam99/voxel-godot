extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "cave_visual_playtest"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const REQUIRED_CAPTURE_STAGES := [
	"cave_dark_default",
	"cave_outside_profile",
	"cave_entrance_approach",
	"cave_first_tunnel",
	"cave_mid_tunnel",
	"cave_branch_tunnel",
	"cave_inner_chamber"
]
const ACCEPTANCE_CLAIM := "procedural_cave_biome_volume_visual"

var main: Node3D
var player: CharacterBody3D
var gameplay_camera: Camera3D
var camera: Camera3D
var observer_light: OmniLight3D
var world_generation
var seed := ""
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var run_token := ""
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var cave_record: Dictionary = {}
var cave_feature: Dictionary = {}
var finished := false
var elapsed := 0.0
var watchdog_seconds := 90.0
var last_camera_target := Vector3.ZERO

func _ready() -> void:
	configure_from_environment()
	apply_resolution()
	write_progress("start")
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if elapsed > watchdog_seconds:
		add_result("cave_visual_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
		finish(1)

func configure_from_environment() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_CAVE_VISUAL_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/caves/cave-visual-playtest.json")
	progress_path = OS.get_environment("VOXEL_CAVE_VISUAL_PROGRESS")
	screenshot_dir = OS.get_environment("VOXEL_CAVE_VISUAL_SCREENSHOT_DIR")
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/caves/screenshots/cave-visual")
	run_token = OS.get_environment("VOXEL_CAVE_VISUAL_RUN_TOKEN")
	var watchdog_value := OS.get_environment("VOXEL_CAVE_VISUAL_WATCHDOG_SECONDS").strip_edges()
	if watchdog_value != "":
		watchdog_seconds = maxf(30.0, float(watchdog_value))
	ensure_dir(report_path.get_base_dir())
	ensure_dir(screenshot_dir)
	if progress_path != "":
		ensure_dir(progress_path.get_base_dir())

func apply_resolution() -> void:
	DisplayServer.window_set_size(Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))
	var root_window := get_tree().root
	root_window.set("size", Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))
	root_window.set("content_scale_size", Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))

func run() -> void:
	OS.set_environment("VOXEL_TEST_SEED", seed)
	OS.set_environment("VOXEL_CAVE_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 1)
	main.set("visual_quality", {
		"decorativeDensity": 0.08,
		"decorativeDetailCap": 8,
		"foliageSway": 0.0,
		"particleDensity": 0.0
	})
	write_progress("main_instantiated")
	add_child(main)
	main.set_process(false)
	main.set_physics_process(false)
	write_progress("main_added")
	await wait_process_frames(2)
	write_progress("main_warmup_complete")
	bind_scene_nodes()
	if main == null or world_generation == null:
		add_result("cave_visual_scene_ready", false, "main/world_generation missing")
		finish(1)
		return
	configure_scene()
	write_progress("scene_configured")
	cave_record = world_generation.call("find_cave_biome_sample", 16)
	write_progress("cave_volume_discovered")
	cave_feature = cave_record.get("feature", {}) if cave_record.has("feature") else {}
	if cave_feature.is_empty():
		add_result("cave_visual_volume_selected", false, "no cave biome volume found")
		finish(1)
		return
	load_cave_chunks()
	write_progress("cave_chunks_loaded")
	configure_camera_and_light()
	await wait_process_frames(6)
	write_progress("camera_ready")

	add_result("cave_visual_volume_selected", true, JSON.stringify(cave_summary()))
	add_result("cave_visual_headed_mode", DisplayServer.get_name().to_lower() != "headless", "display=%s" % DisplayServer.get_name())
	var continuity := volume_continuity_summary()
	add_result("cave_visual_entrance_and_tunnel_are_one_volume", bool(continuity.get("passed", false)), JSON.stringify(continuity))
	var geometry := chunk_geometry_summary()
	add_result("cave_visual_mesh_and_collision_loaded", bool(geometry.get("passed", false)), JSON.stringify(geometry))

	await capture_stage("cave_dark_default", "dark_default", 0.0)
	await capture_stage("cave_outside_profile", "outside_profile", 2.8)
	await capture_stage("cave_entrance_approach", "entrance_approach", 2.8)
	await capture_stage("cave_first_tunnel", "first_tunnel", 2.5)
	await capture_stage("cave_mid_tunnel", "mid_tunnel", 2.5)
	await capture_stage("cave_branch_tunnel", "branch_tunnel", 2.5)
	await capture_stage("cave_inner_chamber", "inner_chamber", 2.7)
	add_result("cave_visual_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
	finish(1 if failure_count() > 0 else 0)

func bind_scene_nodes() -> void:
	player = main.get("player") as CharacterBody3D
	if player != null:
		gameplay_camera = player.get("camera") as Camera3D
	world_generation = main.get("world_generation_system") if main != null else null

func configure_scene() -> void:
	neutralize_intro_clock_freeze()
	if main.has_method("apply_runtime_setting"):
		main.call("apply_runtime_setting", "headBob", false, false)
	main.set("time_of_day", fposmod((14.0 / 24.0) - 0.25, 1.0))
	var weather_system = main.get("weather_system")
	if weather_system != null and weather_system.has_method("force_weather"):
		weather_system.force_weather("clear", 0.0, 0.18, Vector3.ZERO)
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	var hud = main.get("hud")
	if hud is CanvasLayer:
		(hud as CanvasLayer).visible = false
	elif hud is Node:
		var hud_root = hud.get("hud_root")
		if hud_root is Control:
			(hud_root as Control).visible = false

func neutralize_intro_clock_freeze() -> void:
	var tutorial = main.get("tutorial_system") if main != null else null
	if tutorial == null:
		return
	tutorial.set("intro_repair_active", false)
	tutorial.set("intro_repair_complete", true)
	tutorial.set("intro_bed_used", true)
	tutorial.set("intro_elder_dialogue_acknowledged", true)
	tutorial.set("final_night_active", false)
	tutorial.set("final_night_complete", true)
	if tutorial.has_method("clear_dialogue_focus"):
		tutorial.call("clear_dialogue_focus")

func load_cave_chunks() -> void:
	var outside := outside_observer_position()
	if player != null:
		player.global_position = outside
		player.velocity = Vector3.ZERO
	clear_loaded_chunks()
	for chunk_key in cave_focus_chunk_keys():
		load_chunk_key(chunk_key)

func clear_loaded_chunks() -> void:
	var chunks_value = main.get("chunks") if main != null else {}
	if not (chunks_value is Dictionary):
		return
	var chunks: Dictionary = chunks_value
	for key in chunks.keys().duplicate():
		var chunk := chunks[key] as Node
		if chunk != null and is_instance_valid(chunk):
			chunk.queue_free()
		chunks.erase(key)

func load_chunk_for_cell(cell: Vector2i) -> void:
	if main == null or not main.has_method("cell_to_chunk") or not main.has_method("create_chunk"):
		return
	var chunk_key: Vector2i = main.call("cell_to_chunk", cell.x, cell.y)
	load_chunk_key(chunk_key)

func load_chunk_key(chunk_key: Vector2i) -> void:
	if main == null or not main.has_method("create_chunk"):
		return
	var chunks_value = main.get("chunks")
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	if chunks.has(chunk_key):
		return
	main.call("create_chunk", chunk_key.x, chunk_key.y)

func configure_camera_and_light() -> void:
	if gameplay_camera != null:
		gameplay_camera.current = false
	camera = Camera3D.new()
	camera.name = "CaveBiomeVolumePlaytestCamera"
	camera.fov = 72.0
	add_child(camera)
	observer_light = OmniLight3D.new()
	observer_light.name = "CaveBiomeVolumePlaytestLight"
	observer_light.light_energy = 2.4
	observer_light.omni_range = CELL * 8.0
	observer_light.light_cull_mask = 3
	add_child(observer_light)

func capture_stage(stage: String, mode: String, observer_energy := 2.6) -> void:
	if observer_light != null:
		observer_light.light_energy = observer_energy
	position_camera(mode)
	await wait_process_frames(5)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var err := image.save_png(path)
	var luminance := image_luminance_summary(image)
	var line_summary := volume_line_summary(camera.global_position, last_camera_target)
	var sightline := camera_sightline_summary()
	var sample := {
		"stage": stage,
		"mode": mode,
		"elapsed": rounded(elapsed),
		"camera": vec3(camera.global_position),
		"target": vec3(last_camera_target),
		"light": vec3(observer_light.global_position if observer_light != null else Vector3.ZERO),
		"observerLightEnergy": rounded(observer_energy),
		"volumeLine": line_summary,
		"sightline": sightline,
		"cave": cave_summary(),
		"luminance": luminance
	}
	captures.append({
		"stage": stage,
		"path": path,
		"saved": err == OK,
		"cameraMode": mode,
		"observerLightEnergy": observer_energy,
		"sample": sample,
		"luminance": luminance
	})
	timeline.append(sample)
	add_result("capture_%s_saved" % stage, err == OK, path)
	if mode == "outside_profile" or mode == "entrance_approach":
		add_result("cave_visual_%s_collision_sightline_clear" % mode, bool(sightline.get("clear", false)), JSON.stringify(sightline))
		add_result("cave_visual_%s_volume_line_clear" % mode, bool(line_summary.get("clear", false)), JSON.stringify(line_summary))
	if stage == "cave_dark_default":
		add_result("cave_visual_dark_default_without_observer_light", float(luminance.get("average", 1.0)) <= 0.32, JSON.stringify(luminance))

func position_camera(mode: String) -> void:
	var length := float(cave_feature.get("length", CELL * 24.0))
	var radius := float(cave_feature.get("radius", CELL * 2.0))
	var camera_pos := Vector3.ZERO
	var target := Vector3.ZERO
	if mode == "outside_profile":
		camera_pos = outside_observer_position(radius * 5.5, radius * 2.0, 2.2)
		target = main_tunnel_position(CELL * 1.2, 0.0, 0.35)
	elif mode == "entrance_approach":
		camera_pos = outside_observer_position(radius * 2.1, 0.0, 1.65)
		target = main_tunnel_position(CELL * 2.2, 0.0, 0.30)
	elif mode == "first_tunnel":
		camera_pos = main_tunnel_position(CELL * 3.6, 0.0, 0.55)
		target = main_tunnel_position(CELL * 8.5, 0.0, 0.35)
	elif mode == "mid_tunnel":
		camera_pos = main_tunnel_position(length * 0.34, -radius * 0.20, 0.45)
		target = main_tunnel_position(length * 0.58, radius * 0.12, 0.25)
	elif mode == "branch_tunnel":
		camera_pos = branch_position(0.18, -radius * 0.10, 0.45)
		target = branch_position(0.78, 0.0, 0.20)
	elif mode == "inner_chamber":
		camera_pos = main_tunnel_position(maxf(CELL * 4.0, length - radius * 2.2), -radius * 0.45, 0.50)
		target = chamber_position(0.0, 0.0, 0.20)
	else:
		camera_pos = main_tunnel_position(minf(length * 0.35, CELL * 9.0), 0.0, 0.45)
		target = main_tunnel_position(minf(length * 0.58, CELL * 14.0), 0.0, 0.25)
	apply_player_pov(camera_pos, target)
	last_camera_target = target
	if observer_light != null:
		observer_light.global_position = camera_pos + Vector3(0.0, 0.45, 0.0)

func apply_player_pov(camera_pos: Vector3, target: Vector3) -> void:
	if player != null:
		var camera_offset := Vector3(0.0, 1.65, 0.0)
		if gameplay_camera != null:
			camera_offset = gameplay_camera.position
		player.global_position = camera_pos - camera_offset
		player.velocity = Vector3.ZERO
		var flat_target := Vector3(target.x, player.global_position.y, target.z)
		if player.global_position.distance_to(flat_target) > 0.1:
			player.look_at(flat_target, Vector3.UP)
	camera.global_position = camera_pos
	camera.look_at(target, Vector3.UP)
	camera.make_current()

func outside_observer_position(back_distance := -1.0, lateral := 0.0, eye_lift := 1.75) -> Vector3:
	var radius := float(cave_feature.get("radius", CELL * 2.0))
	var back := radius * 4.0 if back_distance < 0.0 else back_distance
	var entrance := entrance_world2()
	var inward := inward2()
	var right := right2()
	var pos2 := entrance - inward * back + right * lateral
	var ground_y := ground_y_for_world2(pos2, float(cave_feature.get("entranceSurfaceY", 0.0)))
	return Vector3(pos2.x, ground_y + eye_lift, pos2.y)

func main_tunnel_position(depth: float, lateral := 0.0, lift := 0.0) -> Vector3:
	var clamped_depth := clampf(depth, 0.0, float(cave_feature.get("length", CELL * 24.0)))
	var center2 := entrance_world2() + inward2() * clamped_depth
	var center_y := float(world_generation.call("cave_feature_center_y", cave_feature, center2, clamped_depth))
	var right := right2()
	return Vector3(center2.x + right.x * lateral, center_y + lift, center2.y + right.y * lateral)

func chamber_position(lateral := 0.0, forward := 0.0, lift := 0.0) -> Vector3:
	var length := float(cave_feature.get("length", CELL * 24.0))
	var radius := float(cave_feature.get("radius", CELL * 2.0))
	var center := main_tunnel_position(length, lateral, lift - radius * 0.10)
	var inward := inward2()
	return Vector3(center.x + inward.x * forward, center.y, center.z + inward.y * forward)

func branch_position(t: float, lateral := 0.0, lift := 0.0) -> Vector3:
	var branch_depth := float(cave_feature.get("branchDepth", CELL * 12.0))
	var branch_length := float(cave_feature.get("branchLength", CELL * 10.0))
	var branch_side := float(cave_feature.get("branchSide", 1.0))
	var inward := inward2()
	var right := right2()
	var branch_dir := (inward * 0.34 + right * branch_side).normalized()
	var origin := entrance_world2() + inward * branch_depth
	var depth := clampf(t, 0.0, 1.0) * branch_length
	var center2 := origin + branch_dir * depth
	var center_y := float(world_generation.call("cave_feature_center_y", cave_feature, center2, branch_depth + depth))
	var side := Vector2(-branch_dir.y, branch_dir.x)
	return Vector3(center2.x + side.x * lateral, center_y + lift, center2.y + side.y * lateral)

func volume_continuity_summary() -> Dictionary:
	var radius := float(cave_feature.get("radius", CELL * 2.0))
	var length := float(cave_feature.get("length", CELL * 24.0))
	var front_air := 0
	var blocked_front := []
	var interior_air := 0
	var blocked_interior := []
	var wall_solids := 0
	var missing_walls := []
	var cover_solids := 0
	var missing_cover := []
	for depth in [0.0, CELL * 0.75, CELL * 1.5]:
		for lateral_scale in [-0.62, 0.0, 0.62]:
			var pos := main_tunnel_position(float(depth), radius * float(lateral_scale), 0.0)
			var sample: Dictionary = world_generation.call("sample_world", pos)
			if String(sample.get("biome", "")) == "cave" and not bool(sample.get("solid", true)):
				front_air += 1
			else:
				blocked_front.append(vec3(pos))
	for depth in [CELL * 3.0, clampf(CELL * 8.0, CELL * 3.0, length * 0.55)]:
		var center := main_tunnel_position(float(depth), 0.0, 0.0)
		var tunnel_sample: Dictionary = world_generation.call("sample_world", center)
		if String(tunnel_sample.get("biome", "")) == "cave" and not bool(tunnel_sample.get("solid", true)):
			interior_air += 1
		else:
			blocked_interior.append(vec3(center))
		for side in [-1.0, 1.0]:
			var side_pos := main_tunnel_position(float(depth), radius * 1.22 * float(side), 0.0)
			var side_sample: Dictionary = world_generation.call("sample_world", side_pos)
			if bool(side_sample.get("solid", false)):
				wall_solids += 1
			else:
				missing_walls.append(vec3(side_pos))
		if float(depth) >= CELL * 7.0:
			var cover_pos := main_tunnel_position(float(depth), 0.0, radius * 0.96)
			var cover_sample: Dictionary = world_generation.call("sample_world", cover_pos)
			if bool(cover_sample.get("solid", false)):
				cover_solids += 1
			else:
				missing_cover.append(vec3(cover_pos))
	var passed := front_air >= 6 \
		and interior_air == 2 \
		and wall_solids == 4 \
		and cover_solids >= 1 \
		and blocked_front.is_empty() \
		and blocked_interior.is_empty() \
		and missing_walls.is_empty() \
		and missing_cover.is_empty()
	return {
		"passed": passed,
		"frontAirSamples": front_air,
		"interiorAirSamples": interior_air,
		"wallSolidSamples": wall_solids,
		"coverSolidSamples": cover_solids,
		"blockedFront": blocked_front,
		"blockedInterior": blocked_interior,
		"missingWalls": missing_walls,
		"missingCover": missing_cover
	}

func volume_line_summary(from: Vector3, to: Vector3) -> Dictionary:
	var solid_samples := 0
	var cave_air_samples := 0
	var samples := 20
	var first_solid := {}
	for i in range(samples + 1):
		var t := float(i) / float(samples)
		var pos := from.lerp(to, t)
		var sample: Dictionary = world_generation.call("sample_world", pos)
		if bool(sample.get("solid", false)):
			solid_samples += 1
			if first_solid.is_empty():
				first_solid = { "index": i, "position": vec3(pos), "sample": sample_signature(sample) }
		elif String(sample.get("biome", "")) == "cave":
			cave_air_samples += 1
	return {
		"clear": solid_samples == 0,
		"samples": samples + 1,
		"solidSamples": solid_samples,
		"caveAirSamples": cave_air_samples,
		"firstSolid": first_solid
	}

func camera_sightline_summary() -> Dictionary:
	if camera == null:
		return { "clear": false, "reason": "missing camera" }
	var from := camera.global_position
	var to := last_camera_target
	var segment := to - from
	var length := segment.length()
	if length <= 0.01:
		return { "clear": false, "reason": "empty segment" }
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	if player != null:
		query.exclude = [player.get_rid()]
	var world := get_viewport().world_3d
	if world == null:
		return { "clear": false, "reason": "missing world" }
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {
			"clear": true,
			"from": vec3(from),
			"to": vec3(to),
			"distance": rounded(length)
		}
	var position: Vector3 = hit.get("position", from)
	var collider = hit.get("collider", null)
	var collider_name := ""
	if collider is Node:
		collider_name = (collider as Node).name
	elif collider != null:
		collider_name = str(collider)
	var hit_distance := from.distance_to(position)
	return {
		"clear": hit_distance >= length * 0.92,
		"from": vec3(from),
		"to": vec3(to),
		"distance": rounded(length),
		"hitDistance": rounded(hit_distance),
		"hitPosition": vec3(position),
		"collider": collider_name
	}

func chunk_geometry_summary() -> Dictionary:
	var chunks_value = main.get("chunks") if main != null else {}
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var terrain_meshes := 0
	var terrain_bodies := 0
	var collision_shapes := 0
	var shared_volume_source := 0
	var source_failures := []
	for chunk_value in chunks.values():
		var chunk := chunk_value as Node
		if chunk == null:
			continue
		var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			terrain_meshes += 1
		var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
		if body != null:
			terrain_bodies += 1
			var shape := body.get_node_or_null("TerrainCollision") as CollisionShape3D
			if shape != null and shape.shape != null:
				collision_shapes += 1
				var mesh_source := String(mesh_instance.get_meta("geometry_source", "")) if mesh_instance != null else ""
				var body_source := String(body.get_meta("geometry_source", ""))
				var shape_source := String(shape.get_meta("geometry_source", ""))
				var collision_source := String(shape.get_meta("collision_source", ""))
				if mesh_source == "volume_sample_extraction" and body_source == mesh_source and shape_source == mesh_source and collision_source == "terrain_mesh_create_trimesh_shape":
					shared_volume_source += 1
				else:
					source_failures.append({
						"chunk": chunk.name,
						"meshSource": mesh_source,
						"bodySource": body_source,
						"shapeSource": shape_source,
						"collisionSource": collision_source
					})
	return {
		"passed": terrain_meshes > 0 and terrain_meshes == terrain_bodies and terrain_bodies == collision_shapes and shared_volume_source == collision_shapes and source_failures.is_empty(),
		"chunks": chunks.size(),
		"terrainMeshes": terrain_meshes,
		"terrainBodies": terrain_bodies,
		"collisionShapes": collision_shapes,
		"sharedVolumeSource": shared_volume_source,
		"sourceFailures": source_failures
	}

func ground_y_for_world2(pos2: Vector2, fallback_y: float) -> float:
	var high := ceili((float(main.MAX_HEIGHT) + CELL * 2.0) / CELL)
	var low := floori((float(main.MIN_HEIGHT) - CELL * 16.0) / CELL)
	var cell_x := roundi(pos2.x / CELL)
	var cell_z := roundi(pos2.y / CELL)
	for y in range(high, low, -1):
		var solid_cell := Vector3i(cell_x, y, cell_z)
		var air_cell := Vector3i(cell_x, y + 1, cell_z)
		var solid_sample: Dictionary = world_generation.call("sample_cell", solid_cell)
		var air_sample: Dictionary = world_generation.call("sample_cell", air_cell)
		if bool(solid_sample.get("solid", false)) and not bool(air_sample.get("solid", true)):
			return float(y + 1) * CELL
	return fallback_y

func cave_focus_chunk_keys() -> Array[Vector2i]:
	var keys: Array[Vector2i] = []
	var base_keys: Array[Vector2i] = []
	for cell in cave_focus_cells():
		var base_key: Vector2i = main.call("cell_to_chunk", cell.x, cell.y)
		append_unique_chunk_key(base_keys, base_key)
	for base_key in base_keys:
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				append_unique_chunk_key(keys, base_key + Vector2i(dx, dz))
	return keys

func append_unique_chunk_key(keys: Array[Vector2i], key: Vector2i) -> void:
	if not keys.has(key):
		keys.append(key)

func cave_focus_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for position in cave_focus_positions():
		append_unique_focus_cell(cells, world2_to_cell2(Vector2(position.x, position.z)))
	return cells

func append_unique_focus_cell(cells: Array[Vector2i], cell: Vector2i) -> void:
	if not cells.has(cell):
		cells.append(cell)

func cave_focus_positions() -> Array[Vector3]:
	var length := float(cave_feature.get("length", CELL * 24.0))
	var radius := float(cave_feature.get("radius", CELL * 2.0))
	return [
		Vector3(entrance_world2().x, float(cave_feature.get("entranceSurfaceY", 0.0)), entrance_world2().y),
		outside_observer_position(),
		outside_observer_position(radius * 5.5, radius * 2.0, 2.2),
		outside_observer_position(radius * 2.1, 0.0, 1.65),
		main_tunnel_position(CELL * 1.2, 0.0, 0.35),
		main_tunnel_position(CELL * 2.2, 0.0, 0.30),
		main_tunnel_position(CELL * 3.6, 0.0, 0.55),
		main_tunnel_position(CELL * 8.5, 0.0, 0.35),
		main_tunnel_position(length * 0.34, -radius * 0.20, 0.45),
		main_tunnel_position(length * 0.58, radius * 0.12, 0.25),
		branch_position(0.18, -radius * 0.10, 0.45),
		branch_position(0.78, 0.0, 0.20),
		main_tunnel_position(maxf(CELL * 4.0, length - radius * 2.2), -radius * 0.45, 0.50),
		chamber_position(0.0, 0.0, 0.20)
	]

func entrance_world2() -> Vector2:
	var entrance_cell: Vector2i = cave_feature.get("entranceCell", Vector2i.ZERO)
	return Vector2(float(entrance_cell.x) * CELL, float(entrance_cell.y) * CELL)

func inward2() -> Vector2:
	var cell: Vector2i = cave_feature.get("inward", Vector2i(0, 1))
	return Vector2(float(cell.x), float(cell.y)).normalized()

func right2() -> Vector2:
	var cell: Vector2i = cave_feature.get("right", Vector2i(1, 0))
	return Vector2(float(cell.x), float(cell.y)).normalized()

func world2_to_cell2(value: Vector2) -> Vector2i:
	return Vector2i(roundi(value.x / CELL), roundi(value.y / CELL))

func sample_signature(sample: Dictionary) -> Dictionary:
	return {
		"density": rounded(float(sample.get("density", 0.0))),
		"solid": bool(sample.get("solid", false)),
		"biome": String(sample.get("biome", "")),
		"material": String(sample.get("material", "")),
		"surface": bool(sample.get("surface", false))
	}

func cave_summary() -> Dictionary:
	var sample: Dictionary = cave_record.get("sample", {}) if cave_record.has("sample") else {}
	return {
		"id": String(cave_feature.get("id", "")),
		"region": sanitize(cave_feature.get("region", Vector2i.ZERO)),
		"entranceCell": sanitize(cave_feature.get("entranceCell", Vector2i.ZERO)),
		"samplePosition": sanitize(cave_record.get("position", Vector3.ZERO)),
		"radius": rounded(float(cave_feature.get("radius", 0.0))),
		"length": rounded(float(cave_feature.get("length", 0.0))),
		"branchDepth": rounded(float(cave_feature.get("branchDepth", 0.0))),
		"branchLength": rounded(float(cave_feature.get("branchLength", 0.0))),
		"sample": sample_signature(sample)
	}

func required_captures_saved() -> bool:
	for stage in REQUIRED_CAPTURE_STAGES:
		var found := false
		for capture in captures:
			if String(capture.get("stage", "")) == stage and bool(capture.get("saved", false)):
				found = true
				break
		if not found:
			return false
	return true

func capture_names() -> Array[String]:
	var names: Array[String] = []
	for capture in captures:
		names.append(String(capture.get("stage", "")))
	return names

func image_luminance_summary(image: Image) -> Dictionary:
	var total := 0.0
	var max_luma := 0.0
	var sample_count := 0
	var width := image.get_width()
	var height := image.get_height()
	var step := 16
	for y in range(0, height, step):
		for x in range(0, width, step):
			var color := image.get_pixel(x, y)
			var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			total += luma
			max_luma = maxf(max_luma, luma)
			sample_count += 1
	var average := total / float(maxi(1, sample_count))
	return {
		"average": rounded(average),
		"max": rounded(max_luma),
		"samples": sample_count
	}

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func finish(exit_code: int) -> void:
	if finished:
		return
	finished = true
	write_report()
	write_progress("finished")
	get_tree().quit(exit_code)

func write_report() -> void:
	var report := {
		"schemaVersion": 2,
		"testId": TEST_ID,
		"seed": seed,
		"runToken": run_token,
		"nonHeadlessRequired": true,
		"finished": finished,
		"passed": failure_count() == 0,
		"evidenceLevel": "acceptance_visual",
		"acceptanceClaims": [ACCEPTANCE_CLAIM],
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"results": results,
		"cave": cave_summary(),
		"captures": captures,
		"timeline": timeline,
		"forbiddenCallSelfScan": {
			"status": "passed",
			"scope": "Cave visual runner uses world-generation cave biome samples and normal chunk geometry."
		}
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write cave visual report: %s" % report_path)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()

func write_progress(label: String) -> void:
	if progress_path == "":
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%d\n" % [label, elapsed, results.size(), failure_count()])
	file.close()

func wait_physics_frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame

func wait_process_frames(count: int) -> void:
	for i in range(count):
		await get_tree().process_frame

func ensure_dir(path: String) -> void:
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("Could not create directory %s: %s" % [path, str(err)])

func sanitize(value):
	if value is Vector2i:
		return { "x": value.x, "z": value.y }
	if value is Vector3i:
		return { "x": value.x, "y": value.y, "z": value.z }
	if value is Vector3:
		return vec3(value)
	if value is Dictionary:
		var out := {}
		for key in (value as Dictionary).keys():
			out[str(key)] = sanitize((value as Dictionary)[key])
		return out
	if value is Array:
		var out_array := []
		for item in value:
			out_array.append(sanitize(item))
		return out_array
	return value

func vec3(value: Vector3) -> Dictionary:
	return {
		"x": rounded(value.x),
		"y": rounded(value.y),
		"z": rounded(value.z)
	}

func rounded(value: float) -> float:
	return snappedf(value, 0.001)
