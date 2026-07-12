extends Node

const CELL := 1.35
const CHUNK_SIZE := 28
const OBSERVATION_SECONDS := [0.0, 5.0, 15.0, 30.0, 60.0, 120.0]

var elapsed := 0.0
var finished := false
var menu: Node
var main: Node3D
var player: CharacterBody3D
var player_camera: Camera3D
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var runtime_samples: Array[Dictionary] = []
var startup_steps: Array[Dictionary] = []
var startup_signals_connected := false

func _ready() -> void:
	configure_paths()
	get_viewport().size = Vector2i(1280, 720)
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += maxf(delta, 0.0)
	if elapsed > watchdog_seconds():
		add_result("vox55_survey_watchdog", false, {"elapsed": rounded(elapsed)})
		finish()

func configure_paths() -> void:
	report_path = OS.get_environment("VOXEL_VOX55_TERRAIN_SURVEY_REPORT").strip_edges()
	progress_path = OS.get_environment("VOXEL_VOX55_TERRAIN_SURVEY_PROGRESS").strip_edges()
	screenshot_dir = OS.get_environment("VOXEL_VOX55_TERRAIN_SURVEY_SCREENSHOT_DIR").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vox55/terrain-scope-survey.json")
	if progress_path == "":
		progress_path = ProjectSettings.globalize_path("res://artifacts/vox55/terrain-scope-survey-progress.txt")
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/vox55/screenshots/terrain-scope-survey")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(progress_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(screenshot_dir)

func run() -> void:
	mark_progress("start")
	var forbidden := forbidden_environment_summary()
	add_result("vox55_gameplay_flags_unset", bool(forbidden.get("passed", false)), forbidden)
	if not bool(forbidden.get("passed", false)):
		finish()
		return
	menu = get_parent()
	await wait_process_frames(4)
	var continue_button := menu.get("continue_button") as Button if menu != null else null
	var button_ready := continue_button != null and is_instance_valid(continue_button) and continue_button.visible and not continue_button.disabled
	add_result("vox55_continue_button_ready", button_ready, control_summary(continue_button))
	if not button_ready:
		finish()
		return
	dispatch_mouse_button_at(continue_button.get_global_rect().get_center(), true)
	dispatch_mouse_button_at(continue_button.get_global_rect().get_center(), false)
	mark_progress("continue_clicked")
	if not await wait_for_main_load(150.0):
		finish()
		return
	bind_scene_nodes()
	var loaded := main != null and player != null and player_camera != null
	add_result("vox55_main_loaded", loaded, scene_summary())
	if not loaded:
		finish()
		return
	await wait_process_frames(12)
	var observation_start := elapsed
	var capture_index := 0
	var next_sample := 0.0
	while elapsed - observation_start < OBSERVATION_SECONDS[-1] + 0.25:
		var observation_elapsed := elapsed - observation_start
		if observation_elapsed + 0.001 >= next_sample:
			runtime_samples.append(runtime_snapshot(observation_elapsed))
			next_sample += 1.0
		if capture_index < OBSERVATION_SECONDS.size() and observation_elapsed + 0.001 >= float(OBSERVATION_SECONDS[capture_index]):
			var seconds := int(OBSERVATION_SECONDS[capture_index])
			await capture_stage("live_saved_pose_%02ds" % seconds, player_camera, {
				"observationSeconds": seconds,
				"runtime": runtime_snapshot(observation_elapsed),
				"rayGrid": camera_ray_grid(player_camera)
			})
			capture_index += 1
		await get_tree().process_frame
	var daylight_state := await enable_diagnostic_daylight()
	await capture_saved_position_ring()
	var candidates := survey_candidates()
	add_result("vox55_scope_candidates_found", candidates.size() >= 3, {"candidates": candidates})
	await capture_scope_candidates(candidates)
	restore_diagnostic_time(daylight_state)
	add_result("vox55_diagnostic_survey_completed", true, {
		"seed": String(main.get("seed_text")),
		"runtimeSamples": runtime_samples.size(),
		"captures": captures.size(),
		"playerUnmovedByRunner": true
	})
	finish()

func wait_for_main_load(timeout_seconds: float) -> bool:
	var max_frames := ceili(timeout_seconds * 60.0)
	for frame in range(max_frames):
		var active_value = menu.get("active_main") if menu != null else null
		if active_value is Node3D:
			main = active_value
			connect_startup_signals()
		if main != null and is_instance_valid(main) and not bool(main.get("startup_loading_active")):
			mark_progress("continue_loaded")
			return true
		if frame % 60 == 0:
			mark_progress("waiting_for_continue:%d" % frame)
		await get_tree().process_frame
	add_result("vox55_continue_load", false, {"reason": "timeout", "seconds": timeout_seconds})
	return false

func connect_startup_signals() -> void:
	if startup_signals_connected or main == null:
		return
	var callback := Callable(self, "_on_startup_loading_step")
	if main.has_signal("startup_loading_step") and not main.is_connected("startup_loading_step", callback):
		main.connect("startup_loading_step", callback)
		startup_signals_connected = true

func _on_startup_loading_step(message: String) -> void:
	startup_steps.append({"time": rounded(elapsed), "message": message})
	if startup_steps.size() > 200:
		startup_steps.pop_front()
	mark_progress("startup:%s" % message)

func bind_scene_nodes() -> void:
	player = main.get("player") as CharacterBody3D if main != null else null
	player_camera = player.get("camera") as Camera3D if player != null else null
	if player_camera != null:
		player_camera.make_current()

func runtime_snapshot(observation_seconds: float) -> Dictionary:
	var chunk_rows := loaded_chunk_rows()
	var counts := {
		"loaded": chunk_rows.size(),
		"provisional": 0,
		"streamingLod": 0,
		"native": 0,
		"requiresVolume": 0,
		"townEdge": 0,
		"terrainEdits": 0,
		"generatedExposure": 0,
		"step1": 0,
		"step14": 0
	}
	var backend_counts := {}
	for row in chunk_rows:
		var backend := String(row.get("backend", "missing"))
		backend_counts[backend] = int(backend_counts.get(backend, 0)) + 1
		for key in ["provisional", "streamingLod", "native", "requiresVolume", "townEdge", "terrainEdits", "generatedExposure"]:
			if bool(row.get(key, false)):
				counts[key] = int(counts.get(key, 0)) + 1
		var step := int(row.get("meshStepCells", 0))
		if step == 1:
			counts["step1"] = int(counts["step1"]) + 1
		elif step == 14:
			counts["step14"] = int(counts["step14"]) + 1
	var service = main.get("terrain_meshing_service") if main != null else null
	var service_summary: Dictionary = {}
	var payload_summary: Dictionary = {}
	if service != null and service.has_method("backend_summary"):
		service_summary = service.call("backend_summary")
	if service != null and service.has_method("payload_progress_summary"):
		payload_summary = service.call("payload_progress_summary")
	var player_key := world_to_chunk(player.global_position) if player != null else Vector2i.ZERO
	return {
		"observationSeconds": rounded(observation_seconds),
		"gameElapsed": rounded(elapsed),
		"player": player_summary(),
		"playerChunk": chunk_row(player_key),
		"centerRay": camera_center_ray(player_camera),
		"counts": counts,
		"backendCounts": backend_counts,
		"terrainService": sanitize(service_summary),
		"payloadProgress": sanitize(payload_summary),
		"pendingTerrainRefreshes": dictionary_size(main.get("pending_chunk_terrain_refreshes")),
		"pendingCollisionRefreshes": dictionary_size(main.get("pending_chunk_collision_refreshes")),
		"pendingExposureScans": dictionary_size(main.get("pending_generated_volume_exposure_scans")),
		"chunks": chunk_rows
	}

func loaded_chunk_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var chunks_value = main.get("chunks") if main != null else null
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	for key_value in chunks.keys():
		if key_value is Vector2i:
			rows.append(chunk_row(key_value))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ac: Array = a.get("chunk", [0, 0])
		var bc: Array = b.get("chunk", [0, 0])
		return int(ac[1]) < int(bc[1]) or (int(ac[1]) == int(bc[1]) and int(ac[0]) < int(bc[0]))
	)
	return rows

func chunk_row(key: Vector2i) -> Dictionary:
	var chunks_value = main.get("chunks") if main != null else null
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk := chunks.get(key) as Node3D
	var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D if chunk != null else null
	var mesh: Mesh = mesh_instance.mesh if mesh_instance != null else null
	var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D if chunk != null else null
	var collision := body.get_node_or_null("TerrainCollision") as CollisionShape3D if body != null else null
	var start_x := key.x * CHUNK_SIZE
	var start_z := key.y * CHUNK_SIZE
	var materials := []
	if mesh != null:
		for surface in range(mesh.get_surface_count()):
			materials.append(material_summary(mesh.surface_get_material(surface)))
	return {
		"chunk": [key.x, key.y],
		"found": chunk != null,
		"backend": String(mesh.get_meta("terrainMeshingBackend", "")) if mesh != null else "",
		"native": bool(mesh.get_meta("terrainMeshingNative", false)) if mesh != null else false,
		"provisional": bool(mesh.get_meta("terrainMeshingProvisional", false)) if mesh != null else false,
		"streamingLod": bool(mesh.get_meta("terrainStreamingLod", false)) if mesh != null else false,
		"sectionPayload": bool(mesh.get_meta("terrainMeshingSectionPayload", false)) if mesh != null else false,
		"solidPlaceholder": bool(mesh.get_meta("terrainProvisionalSolidPlaceholder", false)) if mesh != null else false,
		"volumeFaces": int(mesh.get_meta("chunk_volume_faces", 0)) if mesh != null else 0,
		"volumeVertices": int(mesh.get_meta("chunk_volume_vertices", 0)) if mesh != null else 0,
		"surfaceCount": mesh.get_surface_count() if mesh != null else 0,
		"aabb": aabb_summary(mesh.get_aabb()) if mesh != null else {},
		"materials": materials,
		"collisionPresent": collision != null and collision.shape != null,
		"collisionClass": collision.shape.get_class() if collision != null and collision.shape != null else "",
		"terrainEdits": bool(main.call("chunk_has_terrain_volume_edits", start_x, start_z)),
		"townEdge": bool(main.call("chunk_has_town_surface_volume_edge", start_x, start_z)),
		"generatedExposure": bool(main.call("chunk_has_generated_surface_volume_exposure", start_x, start_z)),
		"requiresVolume": bool(main.call("chunk_needs_generated_underground_volume_mesh", start_x, start_z)),
		"meshStepCells": int(main.call("underground_volume_mesh_step_for_chunk", start_x, start_z)),
		"signature": String(main.call("chunk_asset_signature", key)) if main.has_method("chunk_asset_signature") else ""
	}

func survey_candidates() -> Array[Dictionary]:
	var rows := loaded_chunk_rows()
	var town: Dictionary = main.call("town_region", 1, 0) if main.has_method("town_region") else {}
	var center := Vector2(float(town.get("centerX", 0)), float(town.get("centerZ", 0)))
	var radius := float(town.get("radius", 0))
	var selected := {}
	var current_key := world_to_chunk(player.global_position)
	selected["saved_pose_chunk"] = candidate_for_key("saved_pose_chunk", current_key, center, radius)
	var perimeter_score := INF
	var exposure_score := INF
	var heightfield_score := INF
	for row in rows:
		var encoded: Array = row.get("chunk", [0, 0])
		var key := Vector2i(int(encoded[0]), int(encoded[1]))
		var chunk_center := Vector2(float(key.x * CHUNK_SIZE + CHUNK_SIZE / 2), float(key.y * CHUNK_SIZE + CHUNK_SIZE / 2))
		var distance := chunk_center.distance_to(center)
		var perimeter_delta := absf(distance - radius)
		if perimeter_delta < perimeter_score:
			perimeter_score = perimeter_delta
			selected["town_perimeter"] = candidate_for_key("town_perimeter", key, center, radius)
		if distance > radius + 8.0 and bool(row.get("generatedExposure", false)) and bool(row.get("requiresVolume", false)):
			var score := distance
			if score < exposure_score:
				exposure_score = score
				selected["outside_generated_exposure"] = candidate_for_key("outside_generated_exposure", key, center, radius)
		if distance > radius + 8.0 and not bool(row.get("requiresVolume", false)):
			var score := distance
			if score < heightfield_score:
				heightfield_score = score
				selected["outside_heightfield"] = candidate_for_key("outside_heightfield", key, center, radius)
	var result: Array[Dictionary] = []
	for category in ["saved_pose_chunk", "town_perimeter", "outside_generated_exposure", "outside_heightfield"]:
		if selected.has(category):
			result.append(selected[category])
	return result

func candidate_for_key(category: String, key: Vector2i, town_center: Vector2, town_radius: float) -> Dictionary:
	var target := steepest_target_in_chunk(key)
	var center_cell := Vector2(float(key.x * CHUNK_SIZE + CHUNK_SIZE / 2), float(key.y * CHUNK_SIZE + CHUNK_SIZE / 2))
	return {
		"category": category,
		"chunk": [key.x, key.y],
		"townDistanceCells": rounded(center_cell.distance_to(town_center)),
		"townRadiusCells": rounded(town_radius),
		"target": sanitize(target),
		"chunkState": chunk_row(key)
	}

func steepest_target_in_chunk(key: Vector2i) -> Dictionary:
	var best_cell := Vector2i(key.x * CHUNK_SIZE + CHUNK_SIZE / 2, key.y * CHUNK_SIZE + CHUNK_SIZE / 2)
	var best_height := surface_y(best_cell)
	var best_delta := -INF
	for z in range(key.y * CHUNK_SIZE + 2, (key.y + 1) * CHUNK_SIZE - 2, 2):
		for x in range(key.x * CHUNK_SIZE + 2, (key.x + 1) * CHUNK_SIZE - 2, 2):
			var cell := Vector2i(x, z)
			var height := surface_y(cell)
			var local_min := height
			var local_max := height
			for offset in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2)]:
				var neighbor := surface_y(cell + offset)
				local_min = minf(local_min, neighbor)
				local_max = maxf(local_max, neighbor)
			var delta := local_max - local_min
			if delta > best_delta:
				best_delta = delta
				best_cell = cell
				best_height = height
	return {"cell": [best_cell.x, best_cell.y], "height": rounded(best_height), "localHeightDelta": rounded(best_delta)}

func capture_scope_candidates(candidates: Array[Dictionary]) -> void:
	if main == null or player_camera == null:
		return
	var diagnostic_camera := Camera3D.new()
	diagnostic_camera.name = "Vox55ScopeSurveyCamera"
	diagnostic_camera.fov = player_camera.fov
	main.add_child(diagnostic_camera)
	for candidate in candidates:
		var target_data: Dictionary = candidate.get("target", {})
		var encoded: Array = target_data.get("cell", [0, 0])
		var cell := Vector2i(int(encoded[0]), int(encoded[1]))
		var target := Vector3((float(cell.x) + 0.5) * CELL, float(target_data.get("height", 0.0)), (float(cell.y) + 0.5) * CELL)
		var town: Dictionary = main.call("town_region", 1, 0) if main.has_method("town_region") else {}
		var town_center := Vector2(float(town.get("centerX", cell.x)), float(town.get("centerZ", cell.y)))
		var outward := Vector2(float(cell.x), float(cell.y)) - town_center
		if outward.length_squared() < 0.01:
			outward = Vector2(1.0, 0.0)
		outward = outward.normalized()
		diagnostic_camera.global_position = target - Vector3(outward.x, 0.0, outward.y) * CELL * 7.0 + Vector3.UP * CELL * 5.0
		diagnostic_camera.look_at(target - Vector3.UP * CELL * 0.4, Vector3.UP)
		diagnostic_camera.make_current()
		await capture_stage("survey_%s" % String(candidate.get("category", "unknown")), diagnostic_camera, {
			"candidate": candidate,
			"camera": vec3(diagnostic_camera.global_position),
			"target": vec3(target),
			"rayGrid": camera_ray_grid(diagnostic_camera)
		})
	player_camera.make_current()
	diagnostic_camera.queue_free()

func capture_saved_position_ring() -> void:
	if main == null or player_camera == null:
		return
	var diagnostic_camera := Camera3D.new()
	diagnostic_camera.name = "Vox55SavedPositionRingCamera"
	diagnostic_camera.fov = player_camera.fov
	main.add_child(diagnostic_camera)
	diagnostic_camera.global_position = player_camera.global_position
	for yaw_degrees in range(0, 360, 45):
		diagnostic_camera.global_rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(float(yaw_degrees)), 0.0)
		diagnostic_camera.make_current()
		await capture_stage("saved_position_yaw_%03d" % yaw_degrees, diagnostic_camera, {
			"diagnosticCameraOnly": true,
			"yawDegrees": yaw_degrees,
			"pitchDegrees": -35.0,
			"rayGrid": camera_ray_grid(diagnostic_camera)
		})
	player_camera.make_current()
	diagnostic_camera.queue_free()

func enable_diagnostic_daylight() -> Dictionary:
	var tutorial = main.get("tutorial_system")
	var state := {
		"timeOfDay": float(main.get("time_of_day")),
		"introRepairActive": bool(tutorial.get("intro_repair_active")) if tutorial != null else false,
		"introBedUsed": bool(tutorial.get("intro_bed_used")) if tutorial != null else false,
		"finalNightActive": bool(tutorial.get("final_night_active")) if tutorial != null else false,
		"finalNightComplete": bool(tutorial.get("final_night_complete")) if tutorial != null else false
	}
	if tutorial != null:
		tutorial.set("intro_repair_active", false)
		tutorial.set("final_night_active", false)
	main.set("time_of_day", fposmod((13.0 / 24.0) - 0.25, 1.0))
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	for _frame in range(12):
		await get_tree().process_frame
	add_result("vox55_daylight_survey_pose", true, {
		"diagnosticOnly": true,
		"originalTimeOfDay": rounded(float(state.get("timeOfDay", 0.0))),
		"surveyTimeOfDay": rounded(float(main.get("time_of_day"))),
		"introClockFreezeTemporarilySuspended": true,
		"weatherUnchanged": true
	})
	return state

func restore_diagnostic_time(state: Dictionary) -> void:
	var tutorial = main.get("tutorial_system")
	if tutorial != null:
		tutorial.set("intro_repair_active", bool(state.get("introRepairActive", false)))
		tutorial.set("intro_bed_used", bool(state.get("introBedUsed", false)))
		tutorial.set("final_night_active", bool(state.get("finalNightActive", false)))
		tutorial.set("final_night_complete", bool(state.get("finalNightComplete", false)))
	main.set("time_of_day", float(state.get("timeOfDay", 0.86)))
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)

func capture_stage(stage: String, camera: Camera3D, details := {}) -> void:
	for _frame in range(3):
		await RenderingServer.frame_post_draw
	var path := screenshot_dir.path_join("%s.png" % stage)
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	var row := {
		"stage": stage,
		"path": path,
		"saved": error == OK,
		"camera": vec3(camera.global_position) if camera != null else {},
		"details": details,
		"time": rounded(elapsed)
	}
	captures.append(row)
	mark_progress("capture:%s" % stage)

func camera_center_ray(camera: Camera3D) -> Dictionary:
	if camera == null:
		return {"hit": false, "reason": "missing_camera"}
	return ray_from_screen(camera, get_viewport().get_visible_rect().size * 0.5)

func camera_ray_grid(camera: Camera3D) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var size := get_viewport().get_visible_rect().size
	for fy in [0.2, 0.5, 0.8]:
		for fx in [0.2, 0.5, 0.8]:
			var row := ray_from_screen(camera, Vector2(size.x * fx, size.y * fy))
			row["screenFraction"] = [fx, fy]
			rows.append(row)
	return rows

func ray_from_screen(camera: Camera3D, screen_position: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 180.0)
	query.exclude = [player.get_rid()] if player != null else []
	query.collide_with_areas = false
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"hit": false, "from": vec3(origin), "direction": vec3(direction)}
	var collider := hit.get("collider") as Node
	var chunk := collider.get_parent() if collider != null else null
	var key := Vector2i(999999, 999999)
	if chunk != null:
		var key_value = chunk.get_meta("chunk", Vector2i(999999, 999999))
		if key_value is Vector2i:
			key = key_value
	return {
		"hit": true,
		"position": vec3(hit.get("position", Vector3.ZERO)),
		"normal": vec3(hit.get("normal", Vector3.ZERO)),
		"collider": String(collider.get_path()) if collider != null else "",
		"chunk": [key.x, key.y] if key != Vector2i(999999, 999999) else [],
		"chunkState": chunk_row(key) if key != Vector2i(999999, 999999) else {}
	}

func material_summary(material: Material) -> Dictionary:
	if material == null:
		return {"present": false}
	var result := {"present": true, "class": material.get_class(), "resourcePath": material.resource_path}
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		result["shaderPath"] = shader_material.shader.resource_path if shader_material.shader != null else ""
		result["alphaBase"] = sanitize(shader_material.get_shader_parameter("alpha_base"))
	elif material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		result["transparency"] = base.transparency
		result["albedoAlpha"] = rounded(base.albedo_color.a)
	return result

func player_summary() -> Dictionary:
	return {
		"position": vec3(player.global_position) if player != null else {},
		"rotationY": rounded(player.rotation.y) if player != null else 0.0,
		"pitch": rounded(float(player.get("pitch"))) if player != null else 0.0,
		"camera": vec3(player_camera.global_position) if player_camera != null else {},
		"cell": vec2i(flat_cell(player.global_position)) if player != null else {}
	}

func scene_summary() -> Dictionary:
	return {
		"seed": String(main.get("seed_text")) if main != null else "",
		"player": player_summary(),
		"savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE"),
		"realBootAttachedToMainMenu": menu != null,
		"clickedContinueViaViewportInput": true,
		"runnerMovesPlayer": false
	}

func forbidden_environment_summary() -> Dictionary:
	var names := ["VOXEL_PLAYTEST", "VOXEL_TEST_SEED", "VOXEL_GOD_MODE", "VOXEL_REAL_TUTORIAL_GOD_MODE", "VOXEL_RUNTIME_PERF_FAST_BOOT", "VOXEL_UNDERGROUND_VISUAL_FAST_BOOT"]
	var values := {}
	var passed := true
	for name in names:
		var value := OS.get_environment(name).strip_edges()
		values[name] = {"present": value != "", "valueLength": value.length()}
		if value != "":
			passed = false
	return {"passed": passed, "values": values}

func forbidden_call_self_scan() -> Dictionary:
	var path := ProjectSettings.globalize_path("res://scripts/testing/terrain/Vox55TerrainScopeSurveyRunner.gd")
	var source := FileAccess.get_file_as_string(path)
	var banned := [
		"player.global_" + "position =",
		"interact_" + "with(",
		"on_door_" + "opened(",
		"on_block_" + "placed(",
		"move_" + "npc(",
		"request_door_" + "state("
	]
	var findings := []
	for pattern in banned:
		if source.find(pattern) >= 0:
			findings.append(pattern)
	return {"status": "passed" if findings.is_empty() else "failed", "findings": findings}

func finish() -> void:
	if finished:
		return
	finished = true
	var report := {
		"schemaVersion": 1,
		"runnerId": "vox55_terrain_scope_survey",
		"testId": "vox55_terrain_scope_survey",
		"runToken": OS.get_environment("VOXEL_VOX55_TERRAIN_SURVEY_RUN_TOKEN"),
		"diagnosticOnly": true,
		"evidenceLevel": "diagnostic",
		"acceptanceClaims": [],
		"finished": true,
		"passed": all_passed(),
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"seed": String(main.get("seed_text")) if main != null else "",
		"scope": "Normal main-menu Continue and untouched saved player pose, followed by a synthetic camera-only survey of already loaded chunks.",
		"playerMovedByRunner": false,
		"results": results,
		"captures": captures,
		"runtimeSamples": runtime_samples,
		"startupSteps": startup_steps,
		"timeline": captures,
		"forbiddenCallSelfScan": forbidden_call_self_scan()
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(sanitize(report), "  "))
		file.close()
	mark_progress("finished:%s" % str(report.passed))
	get_tree().quit(0 if bool(report.passed) else 1)

func add_result(name: String, passed: bool, details = {}) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func all_passed() -> bool:
	for result in results:
		if not bool(result.get("passed", false)):
			return false
	return not results.is_empty()

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func dispatch_mouse_button_at(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	event.global_position = position
	Input.parse_input_event(event)
	get_viewport().push_input(event)

func control_summary(control: Control) -> Dictionary:
	if control == null:
		return {"found": false}
	return {"found": true, "visible": control.visible, "disabled": control.disabled, "text": control.text}

func surface_y(cell: Vector2i) -> float:
	return float(main.call("chunk_bound_surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))

func flat_cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL), floori(position.z / CELL))

func world_to_chunk(position: Vector3) -> Vector2i:
	var cell := flat_cell(position)
	return Vector2i(floori(float(cell.x) / CHUNK_SIZE), floori(float(cell.y) / CHUNK_SIZE))

func dictionary_size(value) -> int:
	return (value as Dictionary).size() if value is Dictionary else 0

func mark_progress(message: String) -> void:
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string("%.3f %s" % [elapsed, message])
		file.close()

func watchdog_seconds() -> float:
	return maxf(120.0, float(OS.get_environment("VOXEL_VOX55_TERRAIN_SURVEY_WATCHDOG_SECONDS").to_int()))

func wait_process_frames(count: int) -> void:
	for _index in range(maxi(0, count)):
		await get_tree().process_frame

func rounded(value: float) -> float:
	return snappedf(value, 0.001)

func vec2i(value: Vector2i) -> Dictionary:
	return {"x": value.x, "z": value.y}

func vec3(value: Vector3) -> Dictionary:
	return {"x": rounded(value.x), "y": rounded(value.y), "z": rounded(value.z)}

func aabb_summary(value: AABB) -> Dictionary:
	return {"position": vec3(value.position), "size": vec3(value.size), "end": vec3(value.end)}

func sanitize(value):
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return {"x": rounded(value.x), "y": rounded(value.y)}
	if value is Vector3:
		return vec3(value)
	if value is AABB:
		return aabb_summary(value)
	if value is Dictionary:
		var result := {}
		for key in value.keys():
			result[String(key)] = sanitize(value[key])
		return result
	if value is Array:
		var result := []
		for item in value:
			result.append(sanitize(item))
		return result
	if value is PackedStringArray:
		return Array(value)
	return value
