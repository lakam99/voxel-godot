extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35
const CAPTURE_SIZE := Vector2i(1280, 720)

var main: Node3D
var startup_failure_result: Dictionary = {}
var world_generation
var voxel_runtime
var camera: Camera3D
var light: OmniLight3D
var seed := ""
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var results: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var capture := {}
var elapsed := 0.0
var finished := false

func _ready() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	report_path = OS.get_environment("VOXEL_VOX43_CAVE_REPORT")
	progress_path = OS.get_environment("VOXEL_VOX43_CAVE_PROGRESS")
	screenshot_dir = OS.get_environment("VOXEL_VOX43_CAVE_SCREENSHOT_DIR")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(screenshot_dir)
	get_tree().root.set("size", CAPTURE_SIZE)
	get_tree().root.set("content_scale_size", CAPTURE_SIZE)
	DisplayServer.window_set_size(CAPTURE_SIZE)
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if elapsed > 150.0:
		add_result("vox43_surface_cave_watchdog", false, {"elapsed": elapsed})
		finish()

func run() -> void:
	OS.set_environment("VOXEL_TEST_SEED", seed)
	OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 1)
	main.set("force_underground_volume_debug", true)
	main.set("visual_quality", {"decorativeDensity": 0.0, "decorativeDetailCap": 0, "particleDensity": 0.0})
	add_child(main)
	# Explicit diagnostic setup only; this is not playable-world readiness.
	if not await main.wait_for_startup_loading_complete(240.0, true):
		if is_instance_valid(main):
			startup_failure_result = main.get("startup_loading_failure_result").duplicate(true)
		add_result("vox43_surface_cave_startup_setup", false, JSON.stringify({"reason": "startup_setup_not_ready", "startupLoadingFailureResult": startup_failure_result, "gameplayAcceptance": false}))
		finish()
		return
	world_generation = main.get("world_generation_system")
	if world_generation == null:
		add_result("vox43_surface_cave_scene_ready", false, {"reason": "world_generation_missing"})
		finish()
		return
	configure_scene()
	var entrance := find_open_surface_cave()
	add_result("vox43_surface_cave_entrance_found", not entrance.is_empty(), sanitize(entrance))
	if entrance.is_empty():
		finish()
		return
	var authority_result: Dictionary = await main.call("reinitialize_voxel_terrain_authority_staged")
	if authority_result.get("status") != "ready":
		add_result("vox43_surface_cave_terrain_authority_ready", false, authority_result)
		finish()
		return
	voxel_runtime = main.get("voxel_terrain_runtime")
	if voxel_runtime == null or voxel_runtime.get("terrain") == null:
		add_result("vox43_surface_cave_terrain_authority_ready", false, {"reason": "voxel_terrain_runtime_missing", "authorityResult": authority_result})
		finish()
		return
	add_result("vox43_surface_cave_terrain_authority_ready", true, authority_result)
	await load_entrance_chunk(entrance)
	configure_camera(entrance)
	var geometry := await wait_for_authoritative_geometry(entrance)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("fresh_surface_cave_entrance.png")
	var error := image.save_png(path)
	var line := volume_line_summary(camera.global_position, entrance.get("targetPosition", Vector3.ZERO))
	var camera_surface_y := float(world_generation.call("terrain_deformed_surface_y_at", camera.global_position))
	var camera_clearance := camera.global_position.y - camera_surface_y
	capture = {
		"stage": "fresh_surface_cave_entrance",
		"path": path,
		"saved": error == OK,
		"seed": seed,
		"entrance": sanitize(entrance),
		"cameraPosition": vec3(camera.global_position),
		"cameraTerrainSurfaceY": snappedf(camera_surface_y, 0.001),
		"cameraSurfaceClearance": snappedf(camera_clearance, 0.001),
		"volumeLine": line,
		"geometry": geometry
	}
	timeline.append({"event": "capture", "stage": "fresh_surface_cave_entrance", "elapsed": snappedf(elapsed, 0.001), "path": path})
	add_result("vox43_surface_cave_volume_line_open", int(line.get("undergroundAirSamples", 0)) > 0 and int(line.get("airSamples", 0)) > int(line.get("solidSamples", 0)), line)
	add_result("vox43_surface_cave_camera_outside_terrain", camera_clearance >= CELL * 3.0,
		{"cameraPosition": vec3(camera.global_position), "terrainSurfaceY": snappedf(camera_surface_y, 0.001),
		"clearance": snappedf(camera_clearance, 0.001), "minimum": CELL * 3.0})
	add_result("vox43_surface_cave_volume_geometry_loaded", bool(geometry.get("passed", false)), geometry)
	add_result("capture_fresh_surface_cave_entrance_saved", error == OK and FileAccess.file_exists(path), {"path": path})
	finish()

func configure_scene() -> void:
	var player := main.get("player") as CharacterBody3D
	if player != null:
		player.set_process(false)
		player.set_physics_process(false)
		var gameplay_camera := player.get("camera") as Camera3D
		if gameplay_camera != null:
			gameplay_camera.current = false
	var hud = main.get("hud")
	if hud is CanvasLayer:
		(hud as CanvasLayer).visible = false
	main.set("time_of_day", fposmod((14.0 / 24.0) - 0.25, 1.0))
	var weather = main.get("weather_system")
	if weather != null and weather.has_method("force_weather"):
		weather.call("force_weather", "clear", 0.0, 0.18, Vector3.ZERO)

func find_open_surface_cave() -> Dictionary:
	# Search the generated portal itself at terrain-cell resolution before the
	# coarse world scan. A narrow, deliberately player-clear arch can fall between
	# the old four-cell diagnostic probes even though its authoritative volume is
	# open and connected to daylight.
	for region_z in range(-1, 2):
		for region_x in range(-1, 2):
			var recipe: Dictionary = world_generation.call("cave_recipe_for_region", Vector2i(region_x, region_z))
			if recipe.is_empty():
				continue
			var entry: Vector3 = recipe.entry
			var entry_cell_x := floori(entry.x / CELL)
			var entry_cell_z := floori(entry.z / CELL)
			for z in range(entry_cell_z - 4, entry_cell_z + 5):
				for x in range(entry_cell_x - 4, entry_cell_x + 5):
					var candidate := find_open_surface_cell(x, z)
					if candidate.is_empty():
						continue
					candidate["recipeRegion"] = recipe.region
					candidate["recipeEntry"] = entry
					return candidate
	for radius in range(8, 161, 4):
		for z in range(-radius, radius + 1, 4):
			for x in range(-radius, radius + 1, 4):
				if absi(x) != radius and absi(z) != radius:
					continue
				var candidate := find_open_surface_cell(x, z)
				if not candidate.is_empty():
					return candidate
	return {}

func find_open_surface_cell(x: int, z: int) -> Dictionary:
	var surface_y := float(world_generation.call("surface_y_for_cell", Vector3i(x, 0, z)))
	var surface_cell_y := floori(surface_y / CELL)
	for depth in range(1, 10):
		var target := Vector3i(x, surface_cell_y - depth, z)
		var sample: Dictionary = world_generation.call("sample_cell", target)
		if bool(sample.get("solid", true)) or String(sample.get("biome", "")) != "underground_air" or String(sample.get("fluid", "")) != "":
			continue
		if not vertical_column_is_open(target, surface_cell_y + 2):
			continue
		var chunk: Vector2i = main.call("cell_to_chunk", x, z)
		return {
			"cell": target,
			"surfaceCell": Vector2i(x, z),
			"surfaceCellY": surface_cell_y,
			"depthCells": depth,
			"chunk": chunk,
			"sample": sample,
			"targetPosition": cell_center(target)
		}
	return {}

func vertical_column_is_open(target: Vector3i, top_y: int) -> bool:
	for y in range(target.y, top_y + 1):
		var sample: Dictionary = world_generation.call("sample_cell", Vector3i(target.x, y, target.z))
		if bool(sample.get("solid", false)) or String(sample.get("fluid", "")) != "":
			return false
	return true

func load_entrance_chunk(entrance: Dictionary) -> void:
	var target: Vector3 = entrance.get("targetPosition", Vector3.ZERO)
	var player := main.get("player") as CharacterBody3D
	var spawn_position := camera_approach_position(entrance)
	if player != null:
		player.global_position = spawn_position
		player.velocity = Vector3.ZERO
	# This runner is diagnostic, but terrain demand still uses the production
	# Main -> runtime -> VoxelViewer lifecycle. Only actor motion is paused.
	main.set_process(true)
	main.set_physics_process(true)
	main.call("update_chunks", true)

func wait_for_authoritative_geometry(entrance: Dictionary) -> Dictionary:
	var target: Vector3 = entrance.get("targetPosition", Vector3.ZERO)
	var key: Vector2i = entrance.get("chunk", Vector2i.ZERO)
	var started := Time.get_ticks_msec()
	var last_state := {}
	while float(Time.get_ticks_msec() - started) / 1000.0 < 60.0:
		var terrain = voxel_runtime.get("terrain")
		var published_value = voxel_runtime.get("published_gameplay_chunks")
		var published: Dictionary = published_value if published_value is Dictionary else {}
		var receipt_value = published.get(key, {})
		var receipt: Dictionary = receipt_value if receipt_value is Dictionary else {}
		var mesh_state: Dictionary = voxel_runtime.call("collision_mesh_ready_for_world_position", target, CELL * 2.0)
		var area: AABB = mesh_state.get("area", AABB())
		var mesh_ready: bool = terrain != null and bool(mesh_state.get("passed", false)) \
				and terrain.is_area_meshed(area)
		last_state = {
			"chunk": vec2i(key),
			"published": not receipt.is_empty(),
			"receipt": receipt,
			"meshReady": mesh_ready,
			"meshState": mesh_state,
			"terrainAuthority": "VoxelTerrainAuthority" if terrain != null else ""
		}
		if not receipt.is_empty() and mesh_ready:
			last_state["passed"] = true
			return last_state
		await get_tree().physics_frame
	last_state["passed"] = false
	last_state["reason"] = "voxel_terrain_publication_timeout"
	return last_state

func configure_camera(entrance: Dictionary) -> void:
	var target: Vector3 = entrance.get("targetPosition", Vector3.ZERO)
	camera = Camera3D.new()
	camera.fov = 55.0
	add_child(camera)
	camera.global_position = camera_approach_position(entrance)
	camera.look_at(target + Vector3(0.0, CELL * 0.5, 0.0), Vector3.UP)
	camera.current = true
	light = OmniLight3D.new()
	light.light_energy = 8.0
	light.omni_range = CELL * 16.0
	light.shadow_enabled = false
	add_child(light)
	var entrance_surface_y := float(world_generation.call("terrain_deformed_surface_y_at", target))
	light.global_position = Vector3(target.x, entrance_surface_y + CELL * 2.0, target.z)

func camera_approach_position(entrance: Dictionary) -> Vector3:
	var target: Vector3 = entrance.get("targetPosition", Vector3.ZERO)
	var position := Vector3(target.x + CELL * 10.0, target.y, target.z + CELL * 10.0)
	var surface_y := float(world_generation.call("terrain_deformed_surface_y_at", position))
	position.y = surface_y + CELL * 4.0
	return position

func volume_line_summary(from: Vector3, to: Vector3) -> Dictionary:
	var solid := 0
	var air := 0
	var underground := 0
	for index in range(41):
		var sample: Dictionary = world_generation.call("sample_world", from.lerp(to, float(index) / 40.0))
		if bool(sample.get("solid", false)):
			solid += 1
		else:
			air += 1
			if String(sample.get("biome", "")) == "underground_air":
				underground += 1
	return {"solidSamples": solid, "airSamples": air, "undergroundAirSamples": underground, "from": vec3(from), "to": vec3(to)}

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, JSON.stringify(details)])

func finish() -> void:
	if finished:
		return
	finished = true
	var failures := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failures += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "vox43_surface_cave_visual",
		"testId": "vox43_surface_cave_visual",
		"runToken": OS.get_environment("VOXEL_VOX43_CAVE_RUN_TOKEN"),
		"finished": true,
		"passed": failures == 0,
		"failureCount": failures,
		"resultCount": results.size(),
		"results": results,
		"seed": seed,
		"evidenceLevel": "acceptance_visual",
		"startupScope": "diagnostic_setup_excluded_from_gameplay",
		"gameplayAcceptance": false,
		"startupLoadingFailureResult": startup_failure_result,
		"acceptanceClaims": ["vox43_fresh_surface_cave_visual"],
		"requiredScreenshots": ["fresh_surface_cave_entrance.png"],
		"captures": [capture] if not capture.is_empty() else [],
		"timeline": timeline,
		"forbiddenCallSelfScan": forbidden_call_self_scan()
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	if progress_path != "":
		var progress := FileAccess.open(progress_path, FileAccess.WRITE)
		if progress != null:
			progress.store_string("finished:%s" % str(report.passed))
			progress.close()
	await wait_frames(1)
	if is_instance_valid(main) and main.is_inside_tree():
		main.request_graceful_quit(0 if bool(report.passed) else 1)
		return
	get_tree().quit(0 if bool(report.passed) else 1)

func forbidden_call_self_scan() -> Dictionary:
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/testing/terrain/Vox43SurfaceCaveVisualRunner.gd"))
	var banned := [
		"interact_" + "with(",
		"on_door_" + "opened(",
		"on_block_" + "placed(",
		"sleep_at_" + "bed(",
		"move_" + "npc(",
		"request_door_" + "state(",
		"request_" + "crossing("
	]
	var findings := []
	for pattern in banned:
		if source.find(pattern) >= 0:
			findings.append(pattern)
	return {"status": "passed" if findings.is_empty() else "failed", "findings": findings}

func wait_frames(count: int) -> void:
	for _index in range(count):
		await get_tree().process_frame

func cell_center(cell: Vector3i) -> Vector3:
	return Vector3((cell.x + 0.5) * CELL, (cell.y + 0.5) * CELL, (cell.z + 0.5) * CELL)

func vec3(value: Vector3) -> Dictionary:
	return {"x": snappedf(value.x, 0.001), "y": snappedf(value.y, 0.001), "z": snappedf(value.z, 0.001)}

func vec3i(value: Vector3i) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func vec2i(value: Vector2i) -> Dictionary:
	return {"x": value.x, "z": value.y}

func sanitize(value):
	if value is Vector3i: return vec3i(value)
	if value is Vector2i: return vec2i(value)
	if value is Vector3: return vec3(value)
	if value is Dictionary:
		var output := {}
		for key in value.keys(): output[str(key)] = sanitize(value[key])
		return output
	if value is Array:
		var output := []
		for item in value: output.append(sanitize(item))
		return output
	return value
