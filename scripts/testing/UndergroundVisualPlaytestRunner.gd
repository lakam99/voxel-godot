extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "underground_visual_playtest"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const REQUIRED_CAPTURE_STAGES := [
	"underground_air_reference",
	"underground_wall_boundary",
	"underground_floor_boundary",
	"underground_ceiling_boundary",
	"underground_material_probe",
	"underground_collision_probe"
]
const ACCEPTANCE_CLAIM := "procedural_underground_volume_visual"

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
var sample_record: Dictionary = {}
var sample_cell := Vector3i.ZERO
var sample_position := Vector3.ZERO
var boundary_directions: Array[Vector3i] = []
var air_directions: Array[Vector3i] = []
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
		add_result("underground_visual_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
		finish(1)

func configure_from_environment() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_UNDERGROUND_VISUAL_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/underground/underground-visual-playtest.json")
	progress_path = OS.get_environment("VOXEL_UNDERGROUND_VISUAL_PROGRESS")
	screenshot_dir = OS.get_environment("VOXEL_UNDERGROUND_VISUAL_SCREENSHOT_DIR")
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/underground/screenshots/underground-visual")
	run_token = OS.get_environment("VOXEL_UNDERGROUND_VISUAL_RUN_TOKEN")
	var watchdog_value := OS.get_environment("VOXEL_UNDERGROUND_VISUAL_WATCHDOG_SECONDS").strip_edges()
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
	main.set("visual_quality", {
		"decorativeDensity": 0.03,
		"decorativeDetailCap": 4,
		"foliageSway": 0.0,
		"particleDensity": 0.0
	})
	write_progress("main_instantiated")
	add_child(main)
	main.set_process(false)
	main.set_physics_process(false)
	write_progress("main_added")
	await wait_process_frames(2)
	bind_scene_nodes()
	if main == null or world_generation == null:
		add_result("underground_visual_scene_ready", false, "main/world_generation missing")
		finish(1)
		return
	configure_scene()
	write_progress("scene_configured")
	if not select_underground_sample():
		add_result("underground_visual_volume_selected", false, "no generated underground_air sample found")
		finish(1)
		return
	load_underground_chunks()
	write_progress("underground_chunks_loaded")
	configure_camera_and_light()
	await wait_process_frames(3)
	await wait_physics_frames(3)
	await wait_process_frames(3)

	add_result("underground_visual_volume_selected", true, JSON.stringify(underground_summary()))
	add_result("underground_visual_headed_mode", DisplayServer.get_name().to_lower() != "headless", "display=%s" % DisplayServer.get_name())
	var boundary_summary := generated_boundary_summary()
	add_result("underground_visual_generated_solid_boundaries", bool(boundary_summary.get("passed", false)), JSON.stringify(boundary_summary))
	var geometry := chunk_geometry_summary()
	add_result("underground_visual_mesh_and_collision_loaded", bool(geometry.get("passed", false)), JSON.stringify(geometry))

	await capture_stage("underground_air_reference", stage_direction("air"))
	await capture_stage("underground_wall_boundary", stage_direction("wall"))
	await capture_stage("underground_floor_boundary", stage_direction("floor"))
	await capture_stage("underground_ceiling_boundary", stage_direction("ceiling"))
	await capture_stage("underground_material_probe", stage_direction("material"))
	await capture_stage("underground_collision_probe", stage_direction("collision"))
	add_result("underground_visual_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
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

func select_underground_sample() -> bool:
	if world_generation == null or not world_generation.has_method("find_underground_air_sample"):
		return false
	for radius in [16, 24, 32, 48, 64]:
		var found: Dictionary = world_generation.call("find_underground_air_sample", radius, 4, 30)
		if found.is_empty():
			continue
		var sample: Dictionary = found.get("sample", {}) if found.has("sample") else {}
		if String(sample.get("biome", "")) != "underground_air" or bool(sample.get("solid", true)):
			continue
		sample_record = found
		sample_cell = found.get("cell", Vector3i.ZERO)
		sample_position = found.get("position", cell_center(sample_cell))
		classify_neighbor_directions()
		if boundary_directions.size() >= 2:
			return true
	return false

func classify_neighbor_directions() -> void:
	boundary_directions.clear()
	air_directions.clear()
	for direction in cardinal_directions():
		var sample: Dictionary = world_generation.call("sample_cell", sample_cell + direction)
		if bool(sample.get("solid", false)):
			boundary_directions.append(direction)
		else:
			air_directions.append(direction)

func cardinal_directions() -> Array[Vector3i]:
	return [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]

func load_underground_chunks() -> void:
	if player != null:
		player.global_position = sample_position
		player.velocity = Vector3.ZERO
	clear_loaded_chunks()
	var center_key: Vector2i = main.call("cell_to_chunk", sample_cell.x, sample_cell.z)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			load_chunk_key(Vector2i(center_key.x + dx, center_key.y + dz))

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
	main.call("create_chunk", chunk_key.x, chunk_key.y, true)

func configure_camera_and_light() -> void:
	if gameplay_camera != null:
		gameplay_camera.current = false
	camera = Camera3D.new()
	camera.name = "UndergroundVolumePlaytestCamera"
	camera.fov = 72.0
	add_child(camera)
	observer_light = OmniLight3D.new()
	observer_light.name = "UndergroundVolumePlaytestLight"
	observer_light.light_energy = 2.8
	observer_light.omni_range = CELL * 8.0
	observer_light.light_cull_mask = 3
	add_child(observer_light)

func capture_stage(stage: String, direction: Vector3i) -> void:
	position_camera(stage, direction)
	await wait_process_frames(2)
	await wait_physics_frames(1)
	await wait_process_frames(2)
	await wait_physics_frames(1)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var err := image.save_png(path)
	var luminance := image_luminance_summary(image)
	var line_summary := volume_line_summary(camera.global_position, last_camera_target)
	var sightline := camera_sightline_summary()
	var capture := {
		"stage": stage,
		"elapsed": rounded(elapsed),
		"camera": vec3(camera.global_position),
		"target": vec3(last_camera_target),
		"light": vec3(observer_light.global_position if observer_light != null else Vector3.ZERO),
		"direction": vec3i(direction),
		"volumeLine": line_summary,
		"sightline": sightline,
		"underground": underground_summary(),
		"luminance": luminance
	}
	captures.append(capture)
	timeline.append({
		"event": "capture",
		"stage": stage,
		"elapsed": rounded(elapsed),
		"saved": err == OK,
		"path": path,
		"volumeLine": line_summary,
		"sightline": sightline
	})
	add_result("capture_%s_saved" % stage, err == OK and FileAccess.file_exists(path), path)
	add_result("underground_visual_%s_line_hits_generated_boundary" % stage, int(line_summary.get("solidSamples", 0)) > 0, JSON.stringify(line_summary))
	if stage in ["underground_wall_boundary", "underground_floor_boundary", "underground_ceiling_boundary", "underground_collision_probe"]:
		add_result("underground_visual_%s_raycast_hits_collision" % stage, bool(sightline.get("hit", false)), JSON.stringify(sightline))
	write_progress(stage)

func position_camera(stage: String, direction: Vector3i) -> void:
	var dir := Vector3(float(direction.x), float(direction.y), float(direction.z))
	if dir.length_squared() <= 0.001:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var eye := sample_position - dir * CELL * 0.42 + Vector3(0.0, CELL * 0.12, 0.0)
	if stage == "underground_air_reference" and air_directions.size() > 0:
		var air_dir := vector3i_to_vector3(air_directions[0]).normalized()
		eye = sample_position - air_dir * CELL * 0.25 + Vector3(0.0, CELL * 0.08, 0.0)
		dir = air_dir
	if stage == "underground_material_probe":
		eye = sample_position + Vector3(0.0, CELL * 0.15, 0.0)
	if stage == "underground_collision_probe":
		eye = sample_position - dir * CELL * 0.65 + Vector3(0.0, CELL * 0.05, 0.0)
	last_camera_target = sample_position + dir * CELL * 1.85
	if absf(dir.dot(Vector3.UP)) > 0.92:
		last_camera_target += Vector3(CELL * 0.45, 0.0, 0.0)
	camera.global_position = eye
	camera.look_at(last_camera_target, Vector3.UP)
	camera.current = true
	if observer_light != null:
		observer_light.global_position = eye + Vector3(0.0, CELL * 0.20, 0.0)

func stage_direction(mode: String) -> Vector3i:
	if mode == "floor" and boundary_directions.has(Vector3i(0, -1, 0)):
		return Vector3i(0, -1, 0)
	if mode == "ceiling" and boundary_directions.has(Vector3i(0, 1, 0)):
		return Vector3i(0, 1, 0)
	if mode == "air" and air_directions.size() > 0:
		return air_directions[0]
	var horizontal := first_horizontal_boundary()
	if mode in ["wall", "collision"] and horizontal != Vector3i.ZERO:
		return horizontal
	if mode == "material":
		for direction in boundary_directions:
			if direction != Vector3i(0, 1, 0) and direction != Vector3i(0, -1, 0):
				return direction
	return boundary_directions[0] if boundary_directions.size() > 0 else Vector3i(1, 0, 0)

func first_horizontal_boundary() -> Vector3i:
	for direction in boundary_directions:
		if direction.y == 0:
			return direction
	return Vector3i.ZERO

func generated_boundary_summary() -> Dictionary:
	var solid_neighbors := 0
	var air_neighbors := 0
	var materials := {}
	for direction in cardinal_directions():
		var sample: Dictionary = world_generation.call("sample_cell", sample_cell + direction)
		if bool(sample.get("solid", false)):
			solid_neighbors += 1
			materials[String(sample.get("material", ""))] = true
		else:
			air_neighbors += 1
	return {
		"passed": solid_neighbors >= 2,
		"cell": vec3i(sample_cell),
		"solidNeighbors": solid_neighbors,
		"airNeighbors": air_neighbors,
		"materials": materials.keys()
	}

func chunk_geometry_summary() -> Dictionary:
	var chunks_value = main.get("chunks") if main != null else {}
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk_count := 0
	var mesh_count := 0
	var collision_count := 0
	var volume_faces := 0
	var volume_vertices := 0
	for key in chunks.keys():
		var chunk := chunks[key] as Node
		if chunk == null or not is_instance_valid(chunk):
			continue
		chunk_count += 1
		var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			mesh_count += 1
			volume_faces += int(mesh_instance.mesh.get_meta("chunk_volume_faces", 0))
			volume_vertices += int(mesh_instance.mesh.get_meta("chunk_volume_vertices", 0))
		var body := chunk.get_node_or_null("TerrainBody/TerrainCollision") as CollisionShape3D
		if body != null and body.shape != null:
			collision_count += 1
	return {
		"passed": chunk_count > 0 and mesh_count > 0 and collision_count > 0 and volume_faces > 0,
		"chunkCount": chunk_count,
		"meshCount": mesh_count,
		"collisionCount": collision_count,
		"volumeFaces": volume_faces,
		"volumeVertices": volume_vertices
	}

func volume_line_summary(from: Vector3, to: Vector3) -> Dictionary:
	var steps := 28
	var solid_samples := 0
	var air_samples := 0
	var underground_air_samples := 0
	var materials := {}
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var position := from.lerp(to, t)
		var sample: Dictionary = world_generation.call("sample_world", position)
		if bool(sample.get("solid", false)):
			solid_samples += 1
			materials[String(sample.get("material", ""))] = true
		else:
			air_samples += 1
			if String(sample.get("biome", "")) == "underground_air":
				underground_air_samples += 1
	return {
		"from": vec3(from),
		"to": vec3(to),
		"solidSamples": solid_samples,
		"airSamples": air_samples,
		"undergroundAirSamples": underground_air_samples,
		"materials": materials.keys()
	}

func camera_sightline_summary() -> Dictionary:
	if camera == null:
		return { "hit": false, "reason": "camera_missing" }
	var world := camera.get_world_3d()
	if world == null:
		return { "hit": false, "reason": "world_missing" }
	var space := world.direct_space_state
	var from := camera.global_position
	var to := last_camera_target
	var forward := (to - from).normalized()
	if forward.length_squared() <= 0.001:
		return { "hit": false, "reason": "zero_length_ray" }
	var right := forward.cross(Vector3.UP)
	if right.length_squared() <= 0.001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := right.cross(forward).normalized()
	var offsets := [
		Vector2.ZERO,
		Vector2(CELL * 0.35, 0.0),
		Vector2(-CELL * 0.35, 0.0),
		Vector2(0.0, CELL * 0.35),
		Vector2(0.0, -CELL * 0.35),
		Vector2(CELL * 0.70, CELL * 0.35),
		Vector2(-CELL * 0.70, -CELL * 0.35)
	]
	var attempts := []
	for offset in offsets:
		var start: Vector3 = from + right * offset.x + up * offset.y
		var end: Vector3 = to + forward * CELL * 4.0 + right * offset.x + up * offset.y
		var query := PhysicsRayQueryParameters3D.create(start, end, 2)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := space.intersect_ray(query)
		attempts.append({
			"from": vec3(start),
			"to": vec3(end),
			"hit": not hit.is_empty(),
			"position": vec3(hit.get("position", Vector3.ZERO)) if not hit.is_empty() else {},
			"collider": str(hit.get("collider", "")) if not hit.is_empty() else ""
		})
		if not hit.is_empty():
			return {
				"hit": true,
				"from": vec3(start),
				"to": vec3(end),
				"position": vec3(hit.get("position", Vector3.ZERO)),
				"collider": str(hit.get("collider", "")),
				"attempts": attempts.size()
			}
	return {
		"hit": false,
		"from": vec3(from),
		"to": vec3(to),
		"attempts": attempts
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
		"sample": sample_signature(sample),
		"boundaryDirections": sanitize_array(boundary_directions),
		"airDirections": sanitize_array(air_directions)
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
	var max_luma := 0.0
	var count := 0
	for y in range(0, height, step_y):
		for x in range(0, width, step_x):
			var color := image.get_pixel(x, y)
			var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			total += luma
			max_luma = maxf(max_luma, luma)
			count += 1
	return {
		"average": rounded(total / maxf(1.0, float(count))),
		"max": rounded(max_luma),
		"samples": count
	}

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})

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
	get_tree().quit(exit_code)

func save_report() -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": TEST_ID,
		"testId": TEST_ID,
		"seed": seed,
		"runToken": run_token,
		"finished": true,
		"passed": all_passed(),
		"status": "passed" if all_passed() else "failed",
		"nonHeadlessRequired": true,
		"evidenceLevel": "acceptance_visual",
		"acceptanceClaims": [ACCEPTANCE_CLAIM],
		"requiredScreenshots": capture_names(),
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"results": results,
		"captures": captures,
		"timeline": timeline,
		"underground": underground_summary(),
		"forbiddenCallSelfScan": forbidden_call_self_scan()
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()

func forbidden_call_self_scan() -> Dictionary:
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/testing/UndergroundVisualPlaytestRunner.gd"))
	var legacy := "ca" + "ve"
	var banned := ["find_" + legacy + "_biome_sample", legacy + "_feature", legacy + "Value", "VOXEL_" + legacy.to_upper()]
	var findings := []
	for pattern in banned:
		if source.find(pattern) >= 0:
			findings.append(pattern)
	return {
		"status": "passed" if findings.is_empty() else "failed",
		"findings": findings
	}

func write_progress(stage: String) -> void:
	timeline.append({
		"event": "progress",
		"stage": stage,
		"elapsed": rounded(elapsed)
	})
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

func sanitize_array(values: Array) -> Array:
	var output := []
	for value in values:
		if value is Vector3i:
			output.append(vec3i(value))
		elif value is Vector3:
			output.append(vec3(value))
		else:
			output.append(value)
	return output
