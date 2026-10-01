extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35
const CAPTURE_SIZE := Vector2i(1280, 720)
const REQUIRED_STAGES := [
	"generated_water_exposed",
	"generated_water_enclosed",
	"generated_lava_exposed"
]
const CARDINAL_DIRECTIONS: Array[Vector3i] = [
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.FORWARD,
	Vector3i.BACK
]

var main: Node3D
var startup_failure_result: Dictionary = {}
var world_generation
var player: CharacterBody3D
var camera: Camera3D
var observer_light: OmniLight3D
var seed := ""
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var watchdog_seconds := 120.0
var elapsed := 0.0
var finished := false
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var stage_records := {}
var meshing_evidence: Array[Dictionary] = []

func _ready() -> void:
	configure_from_environment()
	get_tree().root.set("size", CAPTURE_SIZE)
	get_tree().root.set("content_scale_size", CAPTURE_SIZE)
	DisplayServer.window_set_size(CAPTURE_SIZE)
	write_progress("start")
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if elapsed > watchdog_seconds:
		add_result("vox43_fluid_visual_watchdog", false, "watchdog exceeded")
		finish(1)

func configure_from_environment() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-71906947"
	report_path = OS.get_environment("VOXEL_VOX43_FLUID_VISUAL_REPORT")
	progress_path = OS.get_environment("VOXEL_VOX43_FLUID_VISUAL_PROGRESS")
	screenshot_dir = OS.get_environment("VOXEL_VOX43_FLUID_VISUAL_SCREENSHOT_DIR")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vox43/underground-fluid-visual.json")
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/vox43/screenshots/underground-fluid-visual")
	var watchdog_text := OS.get_environment("VOXEL_VOX43_FLUID_VISUAL_WATCHDOG_SECONDS").strip_edges()
	if watchdog_text != "":
		watchdog_seconds = maxf(30.0, float(watchdog_text))
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(screenshot_dir)
	if progress_path != "":
		DirAccess.make_dir_recursive_absolute(progress_path.get_base_dir())

func run() -> void:
	OS.set_environment("VOXEL_TEST_SEED", seed)
	OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 1)
	main.set("visual_quality", {
		"decorativeDensity": 0.0,
		"decorativeDetailCap": 0,
		"particleDensity": 0.0
	})
	add_child(main)
	# Explicit diagnostic setup only; this is not playable-world readiness.
	if not await main.wait_for_startup_loading_complete(240.0, true):
		if is_instance_valid(main):
			startup_failure_result = main.get("startup_loading_failure_result").duplicate(true)
		add_result("vox43_fluid_visual_startup_setup", false, JSON.stringify({"reason": "startup_setup_not_ready", "startupLoadingFailureResult": startup_failure_result, "gameplayAcceptance": false}))
		finish(1)
		return
	main.set_process(false)
	main.set_physics_process(false)
	world_generation = main.get("world_generation_system")
	player = main.get("player") as CharacterBody3D
	if world_generation == null or not world_generation.has_method("sample_cell"):
		add_result("vox43_fluid_visual_scene_ready", false, "world generation unavailable")
		finish(1)
		return
	configure_scene()
	stage_records = find_stage_records()
	for stage in REQUIRED_STAGES:
		add_result(
			"vox43_%s_sample_found" % stage,
			stage_records.has(stage),
			JSON.stringify(sanitize(stage_records.get(stage, {})))
		)
	if failure_count() > 0:
		finish(1)
		return
	write_progress("generated_fluid_samples_selected")
	configure_camera()
	for stage in REQUIRED_STAGES:
		var record: Dictionary = stage_records[stage]
		await load_stage_chunks(record)
		var fluid_cell: Vector3i = record["fluidCell"]
		var fluid_key: Vector2i = main.call("cell_to_chunk", fluid_cell.x, fluid_cell.z)
		var metadata := fluid_mesh_metadata(fluid_key)
		add_result(
			"vox43_%s_exact_fluid_mesh" % stage,
			bool(metadata.get("passed", false)),
			JSON.stringify(metadata)
		)
		await capture_stage(stage, record)
		if not bool(metadata.get("passed", false)):
			break
	add_result("vox43_fluid_visual_required_screenshots_saved", required_captures_saved(), JSON.stringify(REQUIRED_STAGES))
	finish(1 if failure_count() > 0 else 0)

func configure_scene() -> void:
	var gameplay_camera := player.get("camera") as Camera3D if player != null else null
	if gameplay_camera != null:
		gameplay_camera.current = false
	var hud = main.get("hud")
	if hud is CanvasLayer:
		(hud as CanvasLayer).visible = false
	var tutorial = main.get("tutorial_system")
	if tutorial != null:
		tutorial.set("intro_repair_active", false)
		tutorial.set("intro_repair_complete", true)
		tutorial.set("intro_bed_used", true)
	main.set("time_of_day", fposmod((14.0 / 24.0) - 0.25, 1.0))
	var weather = main.get("weather_system")
	if weather != null and weather.has_method("force_weather"):
		weather.call("force_weather", "clear", 0.0, 0.18, Vector3.ZERO)

func find_stage_records() -> Dictionary:
	var found := {}
	var bottom_y := int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
	for radius in [32, 64, 96, 128]:
		for z in range(-radius, radius + 1, 4):
			for x in range(-radius, radius + 1, 4):
				for y in range(bottom_y + 2, 48):
					var cell := Vector3i(x, y, z)
					var sample: Dictionary = world_generation.call("sample_cell", cell)
					if bool(sample.get("solid", false)) or String(sample.get("biome", "")) != "underground_air":
						continue
					var fluid := String(sample.get("fluid", ""))
					if fluid == "water":
						if not found.has("generated_water_exposed"):
							var exposed := exposed_record(cell, fluid)
							if not exposed.is_empty():
								found["generated_water_exposed"] = exposed
						if not found.has("generated_water_enclosed"):
							var enclosed := enclosed_record(cell, fluid)
							if not enclosed.is_empty():
								found["generated_water_enclosed"] = enclosed
					elif fluid == "lava" and not found.has("generated_lava_exposed"):
						var exposed_lava := exposed_record(cell, fluid)
						if not exposed_lava.is_empty():
							found["generated_lava_exposed"] = exposed_lava
					if found.size() == REQUIRED_STAGES.size():
						return found
	return found

func exposed_record(fluid_cell: Vector3i, fluid: String) -> Dictionary:
	for direction in CARDINAL_DIRECTIONS:
		var near_air_cell := fluid_cell + direction
		var camera_cell := fluid_cell + direction * 2
		if dry_air_cell(near_air_cell) \
				and dry_air_cell(camera_cell) \
				and cells_share_chunk([fluid_cell, near_air_cell, camera_cell]) \
				and not cell_has_surface_exposure(camera_cell):
			return {
				"fluid": fluid,
				"fluidCell": fluid_cell,
				"cameraCell": camera_cell,
				"targetCell": fluid_cell,
				"proof": "generated dry-air cell directly exposes generated fluid cell"
			}
	return {}

func enclosed_record(fluid_cell: Vector3i, fluid: String) -> Dictionary:
	for direction in CARDINAL_DIRECTIONS:
		var near_solid_cell := fluid_cell + direction
		var far_solid_cell := fluid_cell + direction * 2
		var camera_cell := fluid_cell + direction * 3
		var near_solid_sample: Dictionary = world_generation.call("sample_cell", near_solid_cell)
		var far_solid_sample: Dictionary = world_generation.call("sample_cell", far_solid_cell)
		if bool(near_solid_sample.get("solid", false)) \
				and bool(far_solid_sample.get("solid", false)) \
				and dry_air_cell(camera_cell) \
				and cells_share_chunk([fluid_cell, near_solid_cell, far_solid_cell, camera_cell]) \
				and not cell_has_surface_exposure(camera_cell):
			return {
				"fluid": fluid,
				"fluidCell": fluid_cell,
				"solidCell": near_solid_cell,
				"solidCells": [near_solid_cell, far_solid_cell],
				"cameraCell": camera_cell,
				"targetCell": fluid_cell,
				"proof": "generated solid cell separates generated dry air from generated fluid"
			}
	return {}

func dry_air_cell(cell: Vector3i) -> bool:
	var sample: Dictionary = world_generation.call("sample_cell", cell)
	return not bool(sample.get("solid", true)) and String(sample.get("fluid", "")) == ""

func cells_share_chunk(cells: Array) -> bool:
	if cells.is_empty():
		return false
	var first: Vector3i = cells[0]
	var expected: Vector2i = main.call("cell_to_chunk", first.x, first.z)
	for value in cells:
		var cell: Vector3i = value
		if main.call("cell_to_chunk", cell.x, cell.z) != expected:
			return false
	return true

func cell_has_surface_exposure(cell: Vector3i) -> bool:
	if not world_generation.has_method("underground_air_sample_has_surface_exposure"):
		return false
	return bool(world_generation.call("underground_air_sample_has_surface_exposure", cell, 1024, 24))

func load_stage_chunks(record: Dictionary) -> void:
	var camera_cell: Vector3i = record["cameraCell"]
	if player != null:
		player.global_position = cell_center(camera_cell)
		player.velocity = Vector3.ZERO
	clear_loaded_chunks()
	await wait_frames(2)
	var required := {}
	for field in ["fluidCell", "cameraCell", "solidCell"]:
		if not record.has(field):
			continue
		var cell: Vector3i = record[field]
		var key: Vector2i = main.call("cell_to_chunk", cell.x, cell.z)
		required[key] = true
	for key_value in required.keys():
		var key: Vector2i = key_value
		main.call("create_chunk", key.x, key.y, true)
		if main.has_method("request_chunk_terrain_mesh_assets"):
			var accepted := bool(main.call("request_chunk_terrain_mesh_assets", key, true, 100))
			meshing_evidence.append({"event": "request", "key": vec2i(key), "accepted": accepted})
	meshing_evidence.append(await drain_meshing(required.keys()))
	write_progress("generated_fluid_chunk_loaded")

func clear_loaded_chunks() -> void:
	var chunks: Dictionary = main.get("chunks")
	for key in chunks.keys().duplicate():
		var chunk := chunks[key] as Node
		if chunk != null and is_instance_valid(chunk):
			chunk.queue_free()
		chunks.erase(key)
	if main.has_method("clear_chunk_asset_cache"):
		main.call("clear_chunk_asset_cache")

func drain_meshing(required_keys: Array) -> Dictionary:
	var service = main.get("terrain_meshing_service")
	if service == null:
		return {"event": "drain", "reason": "service_missing"}
	var last_result := {}
	var frame := 0
	var started_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - started_usec) / 1000.0 < 60000.0:
		frame += 1
		var value = service.call("process_jobs", 2, 4.0, required_keys[0] if not required_keys.is_empty() else Vector2i.ZERO)
		last_result = value if value is Dictionary else {}
		for key_value in required_keys:
			main.call("apply_completed_terrain_meshing_jobs", key_value)
		var all_ready := true
		for key_value in required_keys:
			if not bool(fluid_mesh_metadata(key_value).get("passed", false)):
				all_ready = false
				break
		if all_ready:
			return {
				"event": "drain",
				"frames": frame,
				"ready": true,
				"lastResult": sanitize(last_result),
				"service": sanitize(service.call("payload_progress_summary")) if service.has_method("payload_progress_summary") else {}
			}
		await wait_frames(1)
	return {
		"event": "drain",
		"frames": frame,
		"ready": false,
		"lastResult": sanitize(last_result),
		"service": sanitize(service.call("payload_progress_summary")) if service.has_method("payload_progress_summary") else {}
	}

func fluid_mesh_metadata(key: Vector2i) -> Dictionary:
	var chunks: Dictionary = main.get("chunks")
	var chunk := chunks.get(key) as Node
	var instance := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D if chunk != null else null
	var mesh := instance.mesh if instance != null else null
	var surfaces := mesh.get_surface_count() if mesh != null else 0
	var step := int(mesh.get_meta("nativeFluidStepCells", -1)) if mesh != null else -1
	return {
		"passed": mesh != null and surfaces > 0 and step == 1 and not bool(mesh.get_meta("terrain_fluid_legacy_exact_payload", false)),
		"chunk": vec2i(key),
		"surfaceCount": surfaces,
		"fluidFaces": int(mesh.get_meta("chunk_fluid_faces", 0)) if mesh != null else 0,
		"waterFaces": int(mesh.get_meta("chunk_water_faces", 0)) if mesh != null else 0,
		"lavaFaces": int(mesh.get_meta("chunk_lava_faces", 0)) if mesh != null else 0,
		"nativeFluidStepCells": step,
		"legacyCoarsePayload": bool(mesh.get_meta("terrain_fluid_legacy_exact_payload", false)) if mesh != null else false,
		"collisionSource": String(instance.get_meta("collision_source", "")) if instance != null else ""
	}

func configure_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 42.0
	add_child(camera)
	camera.current = true
	observer_light = OmniLight3D.new()
	observer_light.light_energy = 12.0
	observer_light.omni_range = CELL * 12.0
	observer_light.shadow_enabled = false
	add_child(observer_light)

func capture_stage(stage: String, record: Dictionary) -> void:
	var camera_cell: Vector3i = record["cameraCell"]
	var target_cell: Vector3i = record["targetCell"]
	var eye := cell_center(camera_cell)
	var target := cell_center(target_cell)
	camera.fov = 24.0 if stage == "generated_water_enclosed" else 42.0
	camera.global_position = eye
	camera.look_at(target, Vector3.FORWARD if absf((target - eye).normalized().dot(Vector3.UP)) > 0.92 else Vector3.UP)
	observer_light.global_position = eye
	if player != null:
		player.global_position = eye
		player.velocity = Vector3.ZERO
	await wait_frames(5)
	var ray := collision_ray(eye, target)
	var expected_hit := stage == "generated_water_enclosed"
	add_result(
		"vox43_%s_collision_boundary" % stage,
		bool(ray.get("hit", false)) == expected_hit,
		JSON.stringify(ray)
	)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var err := image.save_png(path)
	var fluid_key: Vector2i = main.call("cell_to_chunk", (record["fluidCell"] as Vector3i).x, (record["fluidCell"] as Vector3i).z)
	var capture := {
		"stage": stage,
		"path": path,
		"saved": err == OK,
		"seed": seed,
		"record": sanitize(record),
		"collisionRay": ray,
		"fluidMesh": fluid_mesh_metadata(fluid_key)
	}
	captures.append(capture)
	timeline.append({"event": "capture", "stage": stage, "path": path, "elapsed": snappedf(elapsed, 0.001)})
	add_result("capture_%s_saved" % stage, err == OK and FileAccess.file_exists(path), path)
	write_progress(stage)

func collision_ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF)
	query.collide_with_areas = false
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	return {
		"hit": not hit.is_empty(),
		"position": vec3(hit.get("position", Vector3.ZERO)) if not hit.is_empty() else {},
		"collider": str(hit.get("collider", "")) if not hit.is_empty() else ""
	}

func required_captures_saved() -> bool:
	for stage in REQUIRED_STAGES:
		if not FileAccess.file_exists(screenshot_dir.path_join("%s.png" % stage)):
			return false
	return true

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, str(details)])

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
	var report := {
		"schemaVersion": 1,
		"runnerId": "vox43_underground_fluid_visual",
		"testId": "vox43_underground_fluid_visual",
		"finished": true,
		"passed": failure_count() == 0,
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"results": results,
		"seed": seed,
		"evidenceLevel": "acceptance_visual",
		"startupScope": "diagnostic_setup_excluded_from_gameplay",
		"gameplayAcceptance": false,
		"startupLoadingFailureResult": startup_failure_result,
		"acceptanceClaims": ["vox43_generated_underground_fluid_visual"],
		"requiredScreenshots": REQUIRED_STAGES.map(func(stage): return "%s.png" % stage),
		"stageRecords": sanitize(stage_records),
		"captures": captures,
		"meshingEvidence": meshing_evidence,
		"forbiddenCallSelfScan": forbidden_call_self_scan(),
		"timeline": timeline
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	write_progress("finish:%d" % exit_code)
	await wait_frames(1)
	if is_instance_valid(main) and main.is_inside_tree():
		main.request_graceful_quit(exit_code)
		return
	get_tree().quit(exit_code)

func forbidden_call_self_scan() -> Dictionary:
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/testing/terrain/Vox43UndergroundFluidVisualRunner.gd"))
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

func write_progress(message: String) -> void:
	if progress_path == "":
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string("%.3f %s" % [elapsed, message])
		file.close()

func wait_frames(count: int) -> void:
	for _index in range(count):
		await get_tree().process_frame

func cell_center(cell: Vector3i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)

func vec3(value: Vector3) -> Dictionary:
	return {"x": snappedf(value.x, 0.001), "y": snappedf(value.y, 0.001), "z": snappedf(value.z, 0.001)}

func vec3i(value: Vector3i) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func vec2i(value: Vector2i) -> Dictionary:
	return {"x": value.x, "z": value.y}

func sanitize(value):
	if value is Vector3i:
		return vec3i(value)
	if value is Vector2i:
		return vec2i(value)
	if value is Vector3:
		return vec3(value)
	if value is Dictionary:
		var output := {}
		for key in value.keys():
			output[str(key)] = sanitize(value[key])
		return output
	if value is Array:
		var output := []
		for item in value:
			output.append(sanitize(item))
		return output
	return value
