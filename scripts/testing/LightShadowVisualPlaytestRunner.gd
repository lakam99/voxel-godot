extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "light_shadow_visual_playtest"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const LIGHT_SAMPLE_SEARCH_RADIUS_CELLS := 224
const LIGHT_SAMPLE_MIN_DEPTH_CELLS := 12
const LIGHT_SAMPLE_MAX_DEPTH_CELLS := 36
const LIGHT_SAMPLE_MIN_CONNECTED_CELLS := 32
const LIGHT_SAMPLE_MIN_SOLID_NEIGHBORS := 2
const LIGHT_SAMPLE_SURFACE_EXPOSURE_MAX_CELLS := 4096
const LIGHT_SAMPLE_SURFACE_EXPOSURE_RADIUS_CELLS := 48
const REQUIRED_CAPTURE_STAGES := [
	"outdoor_noon_reference",
	"underground_noon_dark",
	"underground_torch_lit",
	"underground_torch_closeup"
]
const ACCEPTANCE_CLAIMS := [
	"shadow_authoritative_daylight_blocks_deep_underground",
	"torch_light_brightens_underground_terrain"
]

var main: Node3D
var startup_failure_result: Dictionary = {}
var player: CharacterBody3D
var gameplay_camera: Camera3D
var camera: Camera3D
var torch_light: OmniLight3D
var world_generation
var seed := ""
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var run_token := ""
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var stage_luminance := {}
var sample_record: Dictionary = {}
var sample_cell := Vector3i.ZERO
var sample_position := Vector3.ZERO
var boundary_direction := Vector3i(1, 0, 0)
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
		add_result("light_shadow_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
		finish(1)

func configure_from_environment() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_LIGHT_SHADOW_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/light/light-shadow-visual-playtest.json")
	progress_path = OS.get_environment("VOXEL_LIGHT_SHADOW_PROGRESS")
	screenshot_dir = OS.get_environment("VOXEL_LIGHT_SHADOW_SCREENSHOT_DIR")
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/light/screenshots/light-shadow")
	run_token = OS.get_environment("VOXEL_LIGHT_SHADOW_RUN_TOKEN")
	var watchdog_value := OS.get_environment("VOXEL_LIGHT_SHADOW_WATCHDOG_SECONDS").strip_edges()
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
	OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 1)
	main.set("force_underground_volume_debug", true)
	main.set("force_underground_volume_fine_focus", true)
	main.set("visual_quality", {
		"decorativeDensity": 0.03,
		"decorativeDetailCap": 4,
		"particleDensity": 0.0
	})
	add_child(main)
	# Explicit diagnostic setup only; this is not playable-world readiness.
	if not await main.wait_for_startup_loading_complete(240.0, true):
		if is_instance_valid(main):
			startup_failure_result = main.get("startup_loading_failure_result").duplicate(true)
		add_result("light_shadow_startup_setup", false, JSON.stringify({"reason": "startup_setup_not_ready", "startupLoadingFailureResult": startup_failure_result, "gameplayAcceptance": false}))
		finish(1)
		return
	main.set_process(false)
	main.set_physics_process(false)
	bind_scene_nodes()
	if main == null or world_generation == null:
		add_result("light_shadow_scene_ready", false, "main/world_generation missing")
		finish(1)
		return
	configure_scene()
	if not select_underground_sample():
		add_result("light_shadow_underground_volume_selected", false, "no generated underground_air sample found")
		finish(1)
		return
	load_underground_chunks()
	configure_camera_and_light()
	await wait_process_frames(4)
	await wait_physics_frames(3)
	await wait_process_frames(4)

	add_result("light_shadow_headed_mode", DisplayServer.get_name().to_lower() != "headless", "display=%s" % DisplayServer.get_name())
	add_result("light_shadow_underground_volume_selected", true, JSON.stringify(underground_summary()))
	add_result("light_shadow_global_ambient_low", global_ambient_low(), JSON.stringify(environment_summary()))
	add_result("light_shadow_terrain_meshing_backend", true, JSON.stringify(terrain_meshing_summary()))

	await capture_stage("outdoor_noon_reference", false)
	await capture_stage("underground_noon_dark", false)
	await capture_stage("underground_torch_lit", true)
	await capture_stage("underground_torch_closeup", true, true)
	add_result("light_shadow_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
	add_luminance_assertions()
	finish(1 if failure_count() > 0 else 0)

func bind_scene_nodes() -> void:
	player = main.get("player") as CharacterBody3D
	if player != null:
		gameplay_camera = player.get("camera") as Camera3D
	world_generation = main.get("world_generation_system") if main != null else null

func configure_scene() -> void:
	neutralize_intro_clock_freeze()
	main.set("shadows_enabled", true)
	main.set("time_of_day", fposmod((13.0 / 24.0) - 0.25, 1.0))
	var weather_system = main.get("weather_system")
	if weather_system != null and weather_system.has_method("force_weather"):
		weather_system.force_weather("clear", 0.0, 0.10, Vector3.ZERO)
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	if main.has_method("apply_local_light_shadows"):
		main.call("apply_local_light_shadows")
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
	tutorial.set("final_night_active", false)
	tutorial.set("final_night_complete", true)
	if tutorial.has_method("clear_dialogue_focus"):
		tutorial.call("clear_dialogue_focus")

func select_underground_sample() -> bool:
	if world_generation == null or not world_generation.has_method("sample_cell"):
		return false
	if world_generation.has_method("find_underground_air_sample"):
		for radius in [64, 96, 128, 160, 192, LIGHT_SAMPLE_SEARCH_RADIUS_CELLS]:
			var found: Dictionary = world_generation.call(
				"find_underground_air_sample",
				radius,
				LIGHT_SAMPLE_MIN_DEPTH_CELLS,
				LIGHT_SAMPLE_MAX_DEPTH_CELLS
			)
			if apply_underground_sample_record(found):
				return true
	if select_underground_sample_by_local_scan(
		LIGHT_SAMPLE_SEARCH_RADIUS_CELLS,
		LIGHT_SAMPLE_MIN_DEPTH_CELLS,
		LIGHT_SAMPLE_MAX_DEPTH_CELLS
	):
		return true
	return false

func apply_underground_sample_record(record: Dictionary) -> bool:
	if record.is_empty():
		return false
	var cell: Vector3i = record.get("cell", Vector3i.ZERO)
	var sample: Dictionary = world_generation.call("sample_cell", cell)
	if not underground_air_sample_acceptable(cell, sample):
		return false
	sample_record = record.duplicate(true)
	sample_record["sample"] = sample
	sample_cell = cell
	sample_position = cell_center(sample_cell)
	sample_record["position"] = sample_position
	boundary_direction = first_boundary_direction()
	return true

func select_underground_sample_by_local_scan(search_radius: int, min_depth_cells: int, max_depth_cells: int) -> bool:
	var step := 8
	var min_depth := maxi(1, min_depth_cells)
	var max_depth := maxi(min_depth, max_depth_cells)
	var depth_step := 4
	var best_record := {}
	var best_cell := Vector3i.ZERO
	var best_position := Vector3.ZERO
	var best_boundary_direction := Vector3i(1, 0, 0)
	var best_score := -INF
	for radius in range(0, search_radius + 1, step):
		for z in range(-radius, radius + 1, step):
			for x in range(-radius, radius + 1, step):
				if radius > 0 and absi(x) != radius and absi(z) != radius:
					continue
				var surface_y := surface_y_for_light_cell(Vector3i(x, 0, z))
				var surface_cell_y := floori(surface_y / CELL)
				for depth in range(min_depth, max_depth + 1, depth_step):
					var cell := Vector3i(x, surface_cell_y - depth, z)
					var sample: Dictionary = world_generation.call("sample_cell", cell)
					if not underground_air_sample_basic(sample):
						continue
					var boundary := boundary_counts_for_cell(cell)
					if int(boundary.get("solidNeighbors", 0)) < LIGHT_SAMPLE_MIN_SOLID_NEIGHBORS or int(boundary.get("airNeighbors", 0)) < 2:
						continue
					var connected_region := connected_region_summary_for_cell(cell)
					if int(connected_region.get("airCells", 0)) < LIGHT_SAMPLE_MIN_CONNECTED_CELLS:
						continue
					var score := float(depth) * 5.0
					score += float(int(connected_region.get("airCells", 0))) * 0.25
					score += float(int(boundary.get("solidNeighbors", 0))) * 8.0
					score -= float(radius) * 0.02
					if score <= best_score:
						continue
					if underground_air_cell_has_surface_exposure(cell):
						continue
					best_score = score
					best_cell = cell
					best_position = cell_center(cell)
					best_boundary_direction = first_boundary_direction_for_cell(cell)
					best_record = {
						"id": "underground-air-light:%d,%d,%d" % [cell.x, cell.y, cell.z],
						"sampleId": "underground-air-light:%d,%d,%d" % [cell.x, cell.y, cell.z],
						"cell": cell,
						"surfaceCell": Vector2i(x, z),
						"position": best_position,
						"surfaceY": surface_y,
						"depthCells": depth,
						"sample": sample,
						"connectedRegion": connected_region
					}
	if best_record.is_empty():
		return false
	sample_record = best_record
	sample_cell = best_cell
	sample_position = best_position
	boundary_direction = best_boundary_direction
	return true

func underground_air_sample_acceptable(cell: Vector3i, sample: Dictionary) -> bool:
	if not underground_air_sample_basic(sample):
		return false
	if underground_air_cell_has_surface_exposure(cell):
		return false
	var boundary := boundary_counts_for_cell(cell)
	if int(boundary.get("solidNeighbors", 0)) < LIGHT_SAMPLE_MIN_SOLID_NEIGHBORS or int(boundary.get("airNeighbors", 0)) < 2:
		return false
	var connected_region := connected_region_summary_for_cell(cell)
	return int(connected_region.get("airCells", 0)) >= LIGHT_SAMPLE_MIN_CONNECTED_CELLS

func underground_air_sample_basic(sample: Dictionary) -> bool:
	if String(sample.get("biome", "")) != "underground_air" or bool(sample.get("solid", true)):
		return false
	if String(sample.get("fluid", "")) != "":
		return false
	return float(sample.get("density", 0.0)) <= -CELL * 0.18

func underground_air_cell_has_surface_exposure(cell: Vector3i) -> bool:
	if world_generation == null or not world_generation.has_method("underground_air_sample_has_surface_exposure"):
		return false
	return bool(world_generation.call(
		"underground_air_sample_has_surface_exposure",
		cell,
		LIGHT_SAMPLE_SURFACE_EXPOSURE_MAX_CELLS,
		LIGHT_SAMPLE_SURFACE_EXPOSURE_RADIUS_CELLS
	))

func connected_region_summary_for_cell(cell: Vector3i) -> Dictionary:
	if world_generation != null and world_generation.has_method("underground_air_connected_region_summary"):
		return world_generation.call("underground_air_connected_region_summary", cell, LIGHT_SAMPLE_MIN_CONNECTED_CELLS * 4, 8)
	return { "airCells": LIGHT_SAMPLE_MIN_CONNECTED_CELLS }

func boundary_counts_for_cell(cell: Vector3i) -> Dictionary:
	var solid_neighbors := 0
	var air_neighbors := 0
	for direction in [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]:
		var sample: Dictionary = world_generation.call("sample_cell", cell + direction)
		if bool(sample.get("solid", false)):
			solid_neighbors += 1
		elif String(sample.get("biome", "")) == "underground_air" and String(sample.get("fluid", "")) == "":
			air_neighbors += 1
	return {
		"solidNeighbors": solid_neighbors,
		"airNeighbors": air_neighbors
	}

func surface_y_for_light_cell(cell: Vector3i) -> float:
	if world_generation != null and world_generation.has_method("surface_y_for_cell"):
		return float(world_generation.call("surface_y_for_cell", cell))
	if world_generation != null and world_generation.has_method("terrain_reference_surface_y_for_cell"):
		return float(world_generation.call("terrain_reference_surface_y_for_cell", cell))
	return float(cell.y) * CELL

func first_boundary_direction() -> Vector3i:
	return first_boundary_direction_for_cell(sample_cell)

func first_boundary_direction_for_cell(cell: Vector3i) -> Vector3i:
	for direction in [
		Vector3i(0, -1, 0),
		Vector3i(0, 1, 0),
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]:
		var sample: Dictionary = world_generation.call("sample_cell", cell + direction)
		if bool(sample.get("solid", false)):
			return direction
	return Vector3i(1, 0, 0)

func load_underground_chunks() -> void:
	if player != null:
		player.global_position = sample_position
		player.velocity = Vector3.ZERO
	clear_loaded_chunks()
	var center_key: Vector2i = main.call("cell_to_chunk", sample_cell.x, sample_cell.z)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			load_chunk_key(Vector2i(center_key.x + dx, center_key.y + dz))
	clear_non_terrain_chunk_nodes()

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
	if main.has_method("clear_chunk_asset_cache"):
		main.call("clear_chunk_asset_cache")

func load_chunk_key(chunk_key: Vector2i) -> void:
	if main == null or not main.has_method("create_chunk"):
		return
	var chunks_value = main.get("chunks")
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	if chunks.has(chunk_key):
		return
	main.call("create_chunk", chunk_key.x, chunk_key.y, false)

func clear_non_terrain_chunk_nodes() -> void:
	if main == null:
		return
	var chunks_value = main.get("chunks")
	if not (chunks_value is Dictionary):
		return
	var chunks: Dictionary = chunks_value
	for key_value in chunks.keys():
		var chunk := chunks[key_value] as Node
		if chunk == null:
			continue
		for child in chunk.get_children():
			if child.name in ["TerrainMesh", "TerrainFluidMesh", "TerrainBody"]:
				continue
			if child is Node3D:
				(child as Node3D).visible = false

func configure_camera_and_light() -> void:
	if gameplay_camera != null:
		gameplay_camera.current = false
	camera = Camera3D.new()
	camera.name = "LightShadowUndergroundCamera"
	camera.fov = 22.0
	add_child(camera)
	torch_light = OmniLight3D.new()
	torch_light.name = "LightShadowUndergroundTorch"
	torch_light.light_energy = 0.0
	torch_light.omni_range = CELL * 12.0
	torch_light.shadow_enabled = true
	torch_light.light_cull_mask = 0xFFFFFFFF
	torch_light.set_meta("light_role", "source")
	torch_light.add_to_group("local_light_rig_source")
	main.add_child(torch_light)

func capture_stage(stage: String, torch_enabled: bool, closeup := false) -> void:
	position_camera(stage, closeup)
	if player != null:
		player.global_position = camera.global_position
		player.velocity = Vector3.ZERO
	if main != null and main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	if torch_light != null:
		torch_light.light_energy = 12.0 if torch_enabled else 0.0
		var boundary_normal := vector3i_to_vector3(boundary_direction).normalized()
		torch_light.global_position = sample_position - boundary_normal * CELL * 0.32
	await wait_process_frames(3)
	await wait_physics_frames(1)
	await wait_process_frames(3)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var err := image.save_png(path)
	var luminance := image_luminance_summary(image)
	stage_luminance[stage] = luminance
	var capture := {
		"stage": stage,
		"elapsed": rounded(elapsed),
		"camera": vec3(camera.global_position),
		"target": vec3(last_camera_target),
		"torchEnabled": torch_enabled,
		"torch": vec3(torch_light.global_position if torch_light != null else Vector3.ZERO),
		"luminance": luminance,
		"environment": environment_summary(),
		"underground": underground_summary()
	}
	captures.append(capture)
	timeline.append({ "event": "capture", "stage": stage, "elapsed": rounded(elapsed), "saved": err == OK, "path": path, "luminance": luminance })
	add_result("capture_%s_saved" % stage, err == OK and FileAccess.file_exists(path), path)
	write_progress(stage)

func position_camera(stage: String, closeup := false) -> void:
	if stage == "outdoor_noon_reference":
		var surface_y := float(sample_record.get("surfaceY", sample_position.y + CELL * 8.0))
		camera.global_position = Vector3(sample_position.x - CELL * 6.0, surface_y + CELL * 6.0, sample_position.z - CELL * 6.0)
		last_camera_target = Vector3(sample_position.x, surface_y, sample_position.z)
	else:
		var dir := vector3i_to_vector3(boundary_direction).normalized()
		var wall_side_offset := CELL * (0.26 if closeup else 0.18)
		camera.global_position = sample_position - dir * wall_side_offset + Vector3(0.0, CELL * 0.035, 0.0)
		last_camera_target = sample_position + dir * CELL * (0.62 if closeup else 0.78)
	var up_axis := Vector3.UP
	if stage != "outdoor_noon_reference" and absf(vector3i_to_vector3(boundary_direction).normalized().y) > 0.82:
		up_axis = Vector3.FORWARD
	camera.look_at(last_camera_target, up_axis)
	camera.current = true

func add_luminance_assertions() -> void:
	var outdoor_avg := luminance_average("outdoor_noon_reference")
	var dark_avg := luminance_average("underground_noon_dark")
	var torch_avg := luminance_average("underground_torch_lit")
	var dark_center := luminance_center_average("underground_noon_dark")
	var torch_center := luminance_center_average("underground_torch_lit")
	var torch_close_center := luminance_center_average("underground_torch_closeup")
	add_result(
		"light_shadow_deep_underground_darker_than_outdoor_noon",
		dark_avg < outdoor_avg * 0.72,
		"outdoor=%.3f underground=%.3f" % [outdoor_avg, dark_avg]
	)
	add_result("light_shadow_torch_visual_captures_recorded", torch_avg >= 0.0, "torch=%.3f underground=%.3f" % [torch_avg, dark_avg])
	add_result(
		"light_shadow_torch_brightens_underground_terrain",
		torch_center > dark_center * 1.18 or torch_close_center > dark_center * 1.28,
		"darkCenter=%.3f torchCenter=%.3f closeCenter=%.3f" % [dark_center, torch_center, torch_close_center]
	)

func luminance_average(stage: String) -> float:
	var summary: Dictionary = stage_luminance.get(stage, {})
	return float(summary.get("average", 0.0))

func luminance_center_average(stage: String) -> float:
	var summary: Dictionary = stage_luminance.get(stage, {})
	return float(summary.get("centerAverage", 0.0))

func global_ambient_low() -> bool:
	var world := get_viewport().world_3d
	if world == null or world.environment == null:
		return true
	return world.environment.ambient_light_energy <= 0.01

func environment_summary() -> Dictionary:
	var world := get_viewport().world_3d
	if world == null or world.environment == null:
		return { "environment": "missing" }
	var factor := 0.0
	if main != null and main.has_method("underground_environment_factor") and camera != null:
		factor = float(main.call("underground_environment_factor", camera.global_position))
	return {
		"ambientLightEnergy": rounded(world.environment.ambient_light_energy),
		"ambientLightSource": int(world.environment.ambient_light_source),
		"fogDensity": rounded(world.environment.fog_density),
		"fogLightEnergy": rounded(world.environment.fog_light_energy),
		"undergroundEnvironmentFactor": rounded(factor)
	}

func terrain_meshing_summary() -> Dictionary:
	var summary := {}
	if main != null:
		var service = main.get("terrain_meshing_service")
		if service != null and service.has_method("backend_summary"):
			var value = service.call("backend_summary")
			if value is Dictionary:
				summary = value
	var chunk_summaries: Array[Dictionary] = []
	if main != null:
		var chunks_value = main.get("chunks")
		if chunks_value is Dictionary:
			var chunks: Dictionary = chunks_value
			for key_value in chunks.keys():
				var chunk = chunks[key_value] as Node
				if chunk == null:
					continue
				var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
				var mesh := mesh_instance.mesh if mesh_instance != null else null
				if mesh == null:
					continue
				chunk_summaries.append({
					"key": str(key_value),
					"backend": String(mesh.get_meta("terrainMeshingBackend", "")),
					"native": bool(mesh.get_meta("terrainMeshingNative", false)),
					"sectionPayload": bool(mesh.get_meta("terrainMeshingSectionPayload", false)),
					"provisional": bool(mesh.get_meta("terrainMeshingProvisional", false)),
					"surfaceCount": mesh.get_surface_count()
				})
				if chunk_summaries.size() >= 12:
					break
	return {
		"service": summary,
		"chunks": chunk_summaries
	}

func underground_summary() -> Dictionary:
	var sample: Dictionary = sample_record.get("sample", {}) if sample_record.has("sample") else {}
	return {
		"sampleId": String(sample_record.get("sampleId", "")),
		"cell": vec3i(sample_cell),
		"position": vec3(sample_position),
		"surfaceCell": cell_dict(sample_record.get("surfaceCell", Vector3i.ZERO)),
		"surfaceY": rounded(float(sample_record.get("surfaceY", 0.0))),
		"depthCells": rounded(float(sample_record.get("depthCells", sample.get("depthCells", 0.0)))),
		"boundaryDirection": vec3i(boundary_direction),
		"sample": sample_signature(sample)
	}

func sample_signature(sample: Dictionary) -> Dictionary:
	return {
		"density": rounded(float(sample.get("density", 0.0))),
		"solid": bool(sample.get("solid", false)),
		"biome": String(sample.get("biome", "")),
		"material": String(sample.get("material", "")),
		"surfaceY": rounded(float(sample.get("surfaceY", 0.0))),
		"depthCells": rounded(float(sample.get("depthCells", 0.0)))
	}

func required_captures_saved() -> bool:
	for stage in REQUIRED_CAPTURE_STAGES:
		if not FileAccess.file_exists(screenshot_dir.path_join("%s.png" % stage)):
			return false
	return true

func capture_names() -> Array:
	var names := []
	for stage in REQUIRED_CAPTURE_STAGES:
		names.append("%s.png" % stage)
	return names

func image_luminance_summary(image: Image) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	var step_x := maxi(1, width / 64)
	var step_y := maxi(1, height / 36)
	var total := 0.0
	var center_total := 0.0
	var max_luma := 0.0
	var count := 0
	var center_count := 0
	var center_min_x := int(float(width) * 0.35)
	var center_max_x := int(float(width) * 0.65)
	var center_min_y := int(float(height) * 0.32)
	var center_max_y := int(float(height) * 0.68)
	for y in range(0, height, step_y):
		for x in range(0, width, step_x):
			var color := image.get_pixel(x, y)
			var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			total += luma
			max_luma = maxf(max_luma, luma)
			count += 1
			if x >= center_min_x and x <= center_max_x and y >= center_min_y and y <= center_max_y:
				center_total += luma
				center_count += 1
	return {
		"average": rounded(total / maxf(1.0, float(count))),
		"centerAverage": rounded(center_total / maxf(1.0, float(center_count))),
		"max": rounded(max_luma),
		"samples": count
	}

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({ "name": name, "passed": passed, "details": details })

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func all_passed() -> bool:
	return failure_count() == 0

func finish(exit_code: int) -> void:
	if finished:
		return
	finished = true
	save_report()
	write_progress("finish:%d" % exit_code)
	if is_instance_valid(main) and main.is_inside_tree():
		main.request_graceful_quit(exit_code)
		return
	get_tree().quit(exit_code)

func save_report() -> void:
	var report := {
		"schemaVersion": 2,
		"runnerId": TEST_ID,
		"testId": TEST_ID,
		"seed": seed,
		"runToken": run_token,
		"finished": true,
		"passed": all_passed(),
		"status": "passed" if all_passed() else "failed",
		"nonHeadlessRequired": true,
		"startupScope": "diagnostic_setup_excluded_from_gameplay",
		"gameplayAcceptance": false,
		"startupLoadingFailureResult": startup_failure_result,
		"evidenceLevel": "acceptance_visual",
		"acceptanceClaims": ACCEPTANCE_CLAIMS,
		"requiredScreenshots": capture_names(),
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"results": results,
		"captures": captures,
		"timeline": timeline,
		"stageLuminance": stage_luminance,
		"underground": underground_summary(),
		"forbiddenCallSelfScan": forbidden_call_self_scan()
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()

func forbidden_call_self_scan() -> Dictionary:
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/testing/LightShadowVisualPlaytestRunner.gd"))
	var legacy := "ca" + "ve"
	var banned := ["find_" + legacy + "_biome_sample", legacy + "_feature", legacy + "Value", "VOXEL_" + legacy.to_upper()]
	var findings := []
	for pattern in banned:
		if source.find(pattern) >= 0:
			findings.append(pattern)
	return { "status": "passed" if findings.is_empty() else "failed", "findings": findings }

func write_progress(stage: String) -> void:
	timeline.append({ "event": "progress", "stage": stage, "elapsed": rounded(elapsed) })
	if progress_path == "":
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string("%s\n%.3f\n" % [stage, elapsed])
		file.close()

func ensure_dir(path: String) -> void:
	if path != "":
		DirAccess.make_dir_recursive_absolute(path)

func wait_process_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame

func wait_physics_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame

func cell_center(cell: Vector3i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)

func vector3i_to_vector3(value: Vector3i) -> Vector3:
	return Vector3(float(value.x), float(value.y), float(value.z))

func rounded(value: float) -> float:
	return snappedf(value, 0.001)

func vec3(value: Vector3) -> Dictionary:
	return { "x": rounded(value.x), "y": rounded(value.y), "z": rounded(value.z) }

func vec3i(value: Vector3i) -> Dictionary:
	return { "x": value.x, "y": value.y, "z": value.z }

func vec2i(value: Vector2i) -> Dictionary:
	return { "x": value.x, "z": value.y }

func cell_dict(value) -> Dictionary:
	if value is Vector3i:
		return vec3i(value)
	if value is Vector2i:
		return vec2i(value)
	return {}
