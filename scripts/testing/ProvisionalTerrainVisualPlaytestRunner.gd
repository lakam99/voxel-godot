extends "res://scripts/testing/UndergroundVisualPlaytestRunner.gd"

const PROVISIONAL_TEST_ID := "provisional_terrain_visual_playtest"
const PROVISIONAL_CAPTURE_STAGE := "provisional_volume_streaming"
const PROVISIONAL_ACCEPTANCE_CLAIM := "provisional_streaming_terrain_does_not_render_solid_slabs"

var provisional_chunk_key := Vector2i.ZERO
var provisional_mesh_summary := {}

func run() -> void:
	OS.set_environment("VOXEL_TEST_SEED", seed)
	OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 1)
	main.set("force_underground_volume_debug", false)
	main.set("force_underground_volume_fine_focus", false)
	main.set("visual_quality", {
		"decorativeDensity": 0.0,
		"decorativeDetailCap": 0,
		"particleDensity": 0.0
	})
	add_child(main)
	# Explicit diagnostic setup only; use the inherited failure report/cleanup.
	if not await main.wait_for_startup_loading_complete(240.0, true):
		if is_instance_valid(main):
			startup_failure_result = main.get("startup_loading_failure_result").duplicate(true)
		add_result("provisional_visual_startup_setup", false, JSON.stringify({"reason": "startup_setup_not_ready", "startupLoadingFailureResult": startup_failure_result, "gameplayAcceptance": false}))
		finish(1)
		return
	main.set_process(false)
	main.set_physics_process(false)
	bind_scene_nodes()
	if main == null or world_generation == null:
		add_result("provisional_visual_scene_ready", false, "main/world_generation missing")
		finish(1)
		return
	configure_scene()
	main.set("force_underground_volume_debug", false)
	main.set("force_underground_volume_fine_focus", false)
	if not select_underground_sample():
		add_result("provisional_visual_volume_selected", false, "no generated underground_air sample found")
		finish(1)
		return
	create_provisional_volume_chunk()
	configure_camera_and_light()
	await capture_provisional_stage()
	add_result("provisional_visual_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
	finish(1 if failure_count() > 0 else 0)

func create_provisional_volume_chunk() -> void:
	if player != null:
		player.global_position = sample_position
		player.velocity = Vector3.ZERO
	clear_loaded_chunks()
	provisional_chunk_key = main.call("cell_to_chunk", sample_cell.x, sample_cell.z)
	var should_queue := false
	if main.has_method("chunk_should_queue_terrain_meshing"):
		should_queue = bool(main.call("chunk_should_queue_terrain_meshing", provisional_chunk_key.x, provisional_chunk_key.y))
	add_result("provisional_visual_chunk_requires_queued_volume_mesh", should_queue, "chunk=%s" % str(provisional_chunk_key))
	main.call("create_chunk", provisional_chunk_key.x, provisional_chunk_key.y, true, true)
	clear_non_terrain_chunk_nodes()
	provisional_mesh_summary = mesh_summary_for_chunk(provisional_chunk_key)
	add_result("provisional_visual_uses_exterior_surface_placeholder", String(provisional_mesh_summary.get("backend", "")) == "provisional_exterior_surface", JSON.stringify(provisional_mesh_summary))
	add_result("provisional_visual_placeholder_has_surface", int(provisional_mesh_summary.get("surfaceCount", 0)) > 0, JSON.stringify(provisional_mesh_summary))
	var pending_jobs := 0
	var service = main.get("terrain_meshing_service")
	if service != null and service.has_method("pending_job_count"):
		pending_jobs = int(service.call("pending_job_count"))
	add_result("provisional_visual_authoritative_mesh_still_pending", pending_jobs > 0, "pendingJobs=%d" % pending_jobs)

func mesh_summary_for_chunk(chunk_key: Vector2i) -> Dictionary:
	var chunks_value = main.get("chunks") if main != null else {}
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk := chunks.get(chunk_key) as Node
	if chunk == null:
		return { "chunk": str(chunk_key), "missing": true }
	var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
	var mesh := mesh_instance.mesh if mesh_instance != null else null
	if mesh == null:
		return { "chunk": str(chunk_key), "missingMesh": true }
	return {
		"chunk": str(chunk_key),
		"backend": String(mesh.get_meta("terrainMeshingBackend", "")),
		"native": bool(mesh.get_meta("terrainMeshingNative", false)),
		"provisional": bool(mesh.get_meta("terrainMeshingProvisional", false)),
		"surfaceCount": mesh.get_surface_count()
	}

func capture_provisional_stage() -> void:
	position_provisional_camera()
	if player != null:
		player.global_position = camera.global_position
		player.velocity = Vector3.ZERO
	if main != null and main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	configure_capture_terrain_material()
	if main != null and main.has_method("update_terrain_local_light_uniforms"):
		main.call("update_terrain_local_light_uniforms")
	await wait_process_frames(2)
	await wait_physics_frames(1)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % PROVISIONAL_CAPTURE_STAGE)
	var err := image.save_png(path)
	var sky_leak := image_sky_leak_summary(image)
	var luminance := image_luminance_summary(image)
	var solid_slab_backend := String(provisional_mesh_summary.get("backend", "")).find("solid_volume_placeholder") >= 0
	var capture := {
		"stage": PROVISIONAL_CAPTURE_STAGE,
		"elapsed": rounded(elapsed),
		"camera": vec3(camera.global_position),
		"target": vec3(last_camera_target),
		"underground": underground_summary(),
		"mesh": provisional_mesh_summary,
		"luminance": luminance,
		"skyLeak": sky_leak
	}
	captures.append(capture)
	timeline.append({
		"event": "capture",
		"stage": PROVISIONAL_CAPTURE_STAGE,
		"elapsed": rounded(elapsed),
		"saved": err == OK,
		"path": path,
		"skyLeak": sky_leak
	})
	add_result("capture_%s_saved" % PROVISIONAL_CAPTURE_STAGE, err == OK and FileAccess.file_exists(path), path)
	add_result("provisional_visual_no_solid_slab_placeholder", not solid_slab_backend, JSON.stringify(provisional_mesh_summary))
	write_progress(PROVISIONAL_CAPTURE_STAGE)

func position_provisional_camera() -> void:
	camera.fov = 58.0
	var surface_y := surface_y_for_visual_cell(Vector3i(sample_cell.x, 0, sample_cell.z))
	var surface_position := Vector3(sample_position.x, surface_y, sample_position.z)
	camera.global_position = surface_position + Vector3(-CELL * 9.0, CELL * 3.2, -CELL * 8.0)
	last_camera_target = surface_position + Vector3(CELL * 4.0, CELL * 0.25, CELL * 3.0)
	camera.look_at(last_camera_target, Vector3.UP)
	camera.current = true
	if observer_light != null:
		observer_light.global_position = camera.global_position + Vector3(0.0, CELL * 0.25, 0.0)
	if target_light != null:
		target_light.global_position = last_camera_target

func required_captures_saved() -> bool:
	return FileAccess.file_exists(screenshot_dir.path_join("%s.png" % PROVISIONAL_CAPTURE_STAGE))

func capture_names() -> Array:
	return ["%s.png" % PROVISIONAL_CAPTURE_STAGE]

func save_report() -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": PROVISIONAL_TEST_ID,
		"testId": PROVISIONAL_TEST_ID,
		"seed": seed,
		"runToken": run_token,
		"finished": true,
		"passed": all_passed(),
		"status": "passed" if all_passed() else "failed",
		"nonHeadlessRequired": true,
		"evidenceLevel": "acceptance_visual",
		"acceptanceClaims": [PROVISIONAL_ACCEPTANCE_CLAIM],
		"requiredScreenshots": capture_names(),
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"results": results,
		"captures": captures,
		"timeline": timeline,
		"underground": underground_summary(),
		"provisionalMesh": provisional_mesh_summary,
		"forbiddenCallSelfScan": forbidden_call_self_scan()
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()

func forbidden_call_self_scan() -> Dictionary:
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/testing/ProvisionalTerrainVisualPlaytestRunner.gd"))
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
