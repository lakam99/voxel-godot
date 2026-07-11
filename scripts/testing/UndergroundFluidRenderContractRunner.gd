extends SceneTree

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35

var main: Node3D
var world_generation
var seed := ""
var report_path := ""
var results: Array[Dictionary] = []
var selected_sample := {}
var selected_cell := Vector3i.ZERO
var selected_chunk := Vector2i.ZERO
var async_mesh_frames := 0
var async_mesh_applied := false
var async_mesh_last_result := {}
var async_mesh_request_accepted := false
var async_mesh_initial_pending := 0
var async_mesh_timeline := []
var edit_refresh_evidence := {}

func _init() -> void:
	call_deferred("run")

func run() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_UNDERGROUND_FLUID_RENDER_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/underground/underground-fluid-render-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	OS.set_environment("VOXEL_TEST_SEED", seed)
	OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 1)
	main.set("visual_quality", {
		"decorativeDensity": 0.0,
		"decorativeDetailCap": 0,
		"foliageSway": 0.0,
		"particleDensity": 0.0
	})
	root.add_child(main)
	main.set_process(false)
	main.set_physics_process(false)
	await process_frame
	await process_frame
	world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null:
		add_result("underground_fluid_render_scene_ready", false, "world_generation missing")
		finish()
		return
	selected_sample = find_underground_fluid_sample()
	if selected_sample.is_empty():
		add_result("underground_fluid_render_sample_found", false, "no generated underground fluid sample found")
		finish()
		return
	selected_cell = selected_sample.get("cell", Vector3i.ZERO)
	var sample_position := cell_center(selected_cell)
	var player := main.get("player") as CharacterBody3D
	if player != null:
		player.global_position = sample_position
		player.velocity = Vector3.ZERO
		player.set_physics_process(false)
	selected_chunk = main.call("cell_to_chunk", selected_cell.x, selected_cell.z)
	add_result("underground_fluid_render_sample_found", true, JSON.stringify(sample_signature(selected_sample)))
	await load_runtime_chunk(selected_chunk)
	await process_frame
	await process_frame
	var geometry := fluid_geometry_summary(selected_chunk)
	add_result("underground_fluid_runtime_mesh_loaded", bool(geometry.get("passed", false)), JSON.stringify(geometry))
	edit_refresh_evidence = await exercise_runtime_fluid_edit_refresh(selected_chunk, geometry)
	add_result(
		"underground_fluid_runtime_edit_refresh",
		bool(edit_refresh_evidence.get("passed", false)),
		JSON.stringify(edit_refresh_evidence)
	)
	finish()

func find_underground_fluid_sample() -> Dictionary:
	if world_generation == null:
		return {}
	var bottom_y := int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
	for radius in [32, 64, 96]:
		for z in range(-radius, radius + 1, 4):
			for x in range(-radius, radius + 1, 4):
				for y in range(bottom_y + 2, 48):
					var cell := Vector3i(x, y, z)
					var sample: Dictionary = world_generation.call("sample_cell", cell) if world_generation.has_method("sample_cell") else world_generation.call("sample_world", cell_center(cell))
					var fluid_id := String(sample.get("fluid", ""))
					if fluid_id == "":
						continue
					if bool(sample.get("solid", false)):
						continue
					if String(sample.get("biome", "")) != "underground_air":
						continue
					sample["cell"] = cell
					return sample
	return {}

func load_runtime_chunk(chunk_key: Vector2i) -> void:
	if main == null or not main.has_method("create_chunk"):
		return
	var chunks_value = main.get("chunks")
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	if chunks.has(chunk_key) and main.has_method("rebuild_chunk"):
		main.call("rebuild_chunk", chunk_key.x, chunk_key.y, true)
	else:
		main.call("create_chunk", chunk_key.x, chunk_key.y, true)
	if not main.has_method("request_chunk_terrain_mesh_assets"):
		return
	async_mesh_request_accepted = bool(main.call("request_chunk_terrain_mesh_assets", chunk_key, true, 100))
	var service = main.get("terrain_meshing_service")
	if service == null or not service.has_method("process_jobs"):
		return
	async_mesh_initial_pending = int(service.call("pending_job_count")) if service.has_method("pending_job_count") else -1
	var async_started_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - async_started_usec) / 1000.0 < 60000.0:
		async_mesh_frames += 1
		var process_value = service.call("process_jobs", 1, 3.0, chunk_key)
		async_mesh_last_result = process_value if process_value is Dictionary else {}
		if async_mesh_timeline.size() < 24 and (async_mesh_frames <= 3 \
			or int(async_mesh_last_result.get("payloadCells", 0)) > 0 \
			or int(async_mesh_last_result.get("dropped", 0)) > 0 \
			or int(async_mesh_last_result.get("processed", 0)) > 0):
			async_mesh_timeline.append(async_mesh_last_result.duplicate(true))
		if service.has_method("completed_job_count") and int(service.call("completed_job_count")) > 0:
			if main.has_method("apply_completed_terrain_meshing_jobs"):
				async_mesh_applied = int(main.call("apply_completed_terrain_meshing_jobs", chunk_key)) > 0
			break
		var pending_count := int(service.call("pending_job_count")) if service.has_method("pending_job_count") else 1
		if async_mesh_frames > 1 and pending_count <= 0:
			break
		if async_mesh_frames % 100 == 0:
			write_async_progress(service)
		await process_frame
	write_async_progress(service)

func write_async_progress(service) -> void:
	var progress := {
		"frames": async_mesh_frames,
		"requestAccepted": async_mesh_request_accepted,
		"initialPending": async_mesh_initial_pending,
		"applied": async_mesh_applied,
		"lastResult": async_mesh_last_result,
		"service": service.call("payload_progress_summary") if service != null and service.has_method("payload_progress_summary") else {}
	}
	var progress_file := FileAccess.open(report_path + ".progress.json", FileAccess.WRITE)
	if progress_file != null:
		progress_file.store_string(JSON.stringify(progress, "  "))
		progress_file.close()

func exercise_runtime_fluid_edit_refresh(chunk_key: Vector2i, initial_geometry: Dictionary) -> Dictionary:
	var initial_signature := String(initial_geometry.get("terrainSignature", ""))
	var initial_revision := int(initial_geometry.get("fluidPayloadRevision", -1))
	var edit_result: Dictionary = world_generation.call(
		"set_cell_state",
		selected_cell,
		fluid_state("lava"),
		"underground_fluid_render_contract_edit"
	)
	var edited_sample: Dictionary = world_generation.call("sample_cell", selected_cell)
	var queued_refreshes := int(main.call("queue_dirty_terrain_volume_chunk_refreshes")) \
		if main.has_method("queue_dirty_terrain_volume_chunk_refreshes") else 0
	var processed_refreshes := int(main.call("process_pending_chunk_terrain_refreshes", chunk_key)) \
		if main.has_method("process_pending_chunk_terrain_refreshes") else 0
	await process_frame
	var stale_mesh_cleared := not chunk_has_fluid_mesh(chunk_key)
	var async_result := await wait_for_async_mesh_refresh(chunk_key)
	var replacement_geometry := fluid_geometry_summary(chunk_key)
	var replacement_signature := String(replacement_geometry.get("terrainSignature", ""))
	var replacement_revision := int(replacement_geometry.get("fluidPayloadRevision", -1))
	var passed := String(edited_sample.get("fluid", "")) == "lava" \
		and queued_refreshes > 0 \
		and processed_refreshes > 0 \
		and stale_mesh_cleared \
		and bool(async_result.get("applied", false)) \
		and bool(replacement_geometry.get("passed", false)) \
		and int(replacement_geometry.get("lavaFaces", 0)) > 0 \
		and replacement_revision > initial_revision \
		and replacement_signature != "" \
		and replacement_signature != initial_signature
	return {
		"passed": passed,
		"editResult": edit_result,
		"editedSample": sample_signature(edited_sample),
		"queuedRefreshes": queued_refreshes,
		"processedRefreshes": processed_refreshes,
		"staleMeshClearedBeforeReplacement": stale_mesh_cleared,
		"initialTerrainSignature": initial_signature,
		"replacementTerrainSignature": replacement_signature,
		"initialFluidPayloadRevision": initial_revision,
		"replacementFluidPayloadRevision": replacement_revision,
		"async": async_result,
		"replacementGeometry": replacement_geometry
	}

func wait_for_async_mesh_refresh(chunk_key: Vector2i) -> Dictionary:
	var service = main.get("terrain_meshing_service") if main != null else null
	if service == null or not service.has_method("process_jobs"):
		return {"applied": false, "reason": "terrain meshing service missing"}
	var frames := 0
	var applied := false
	var last_result := {}
	var timeline := []
	var initial_pending := int(service.call("pending_job_count")) if service.has_method("pending_job_count") else -1
	var started_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - started_usec) / 1000.0 < 60000.0:
		frames += 1
		var process_value = service.call("process_jobs", 1, 3.0, chunk_key)
		last_result = process_value if process_value is Dictionary else {}
		if timeline.size() < 24 and (frames <= 3 \
			or int(last_result.get("payloadCells", 0)) > 0 \
			or int(last_result.get("fluidPayloadCells", 0)) > 0 \
			or int(last_result.get("dropped", 0)) > 0 \
			or int(last_result.get("processed", 0)) > 0):
			timeline.append(last_result.duplicate(true))
		if service.has_method("completed_job_count") and int(service.call("completed_job_count")) > 0:
			if main.has_method("apply_completed_terrain_meshing_jobs"):
				applied = int(main.call("apply_completed_terrain_meshing_jobs", chunk_key)) > 0
			if applied:
				break
		var pending_count := int(service.call("pending_job_count")) if service.has_method("pending_job_count") else 1
		if frames > 1 and pending_count <= 0:
			break
		await process_frame
	return {
		"applied": applied,
		"frames": frames,
		"initialPending": initial_pending,
		"lastResult": last_result,
		"timeline": timeline,
		"service": service.call("payload_progress_summary") if service.has_method("payload_progress_summary") else {}
	}

func chunk_has_fluid_mesh(chunk_key: Vector2i) -> bool:
	var chunks_value = main.get("chunks") if main != null else {}
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk := chunks.get(chunk_key, null) as Node3D
	var fluid_instance := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D if chunk != null else null
	return fluid_instance != null and fluid_instance.mesh != null and fluid_instance.mesh.get_surface_count() > 0

func fluid_geometry_summary(chunk_key: Vector2i) -> Dictionary:
	var chunks_value = main.get("chunks") if main != null else {}
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk := chunks.get(chunk_key, null) as Node3D
	if chunk == null:
		return {
			"passed": false,
			"reason": "chunk not loaded",
			"chunk": vec2i(chunk_key)
		}
	var fluid_instance := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D
	var mesh := fluid_instance.mesh if fluid_instance != null else null
	var surface_count := mesh.get_surface_count() if mesh != null else 0
	var fluid_faces := int(mesh.get_meta("chunk_fluid_faces", 0)) if mesh != null else 0
	var water_faces := int(mesh.get_meta("chunk_water_faces", 0)) if mesh != null else 0
	var lava_faces := int(mesh.get_meta("chunk_lava_faces", 0)) if mesh != null else 0
	var fluid_step := int(mesh.get_meta("nativeFluidStepCells", -1)) if mesh != null else -1
	var legacy_exact_payload := bool(mesh.get_meta("terrainFluidLegacyExactPayload", false)) if mesh != null else false
	var forbidden_coarse_payload := bool(mesh.get_meta("forbiddenCoarseFluidPayload", false)) if mesh != null else false
	var terrain_signature := String(mesh.get_meta("terrainSignature", "")) if mesh != null else ""
	var fluid_payload_revision := int(mesh.get_meta("fluidPayloadRevision", -1)) if mesh != null else -1
	var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
	return {
		"passed": fluid_instance != null and surface_count > 0 and fluid_faces > 0 and body != null and fluid_step == 1 and not forbidden_coarse_payload,
		"chunk": vec2i(chunk_key),
		"sampleCell": vec3i(selected_cell),
		"fluid": String(selected_sample.get("fluid", "")),
		"fluidMeshPresent": fluid_instance != null,
		"surfaceCount": surface_count,
		"fluidFaces": fluid_faces,
		"waterFaces": water_faces,
		"lavaFaces": lava_faces,
		"nativeFluidStepCells": fluid_step,
		"terrainFluidLegacyExactPayload": legacy_exact_payload,
		"forbiddenCoarseFluidPayload": forbidden_coarse_payload,
		"terrainSignature": terrain_signature,
		"fluidPayloadRevision": fluid_payload_revision,
		"collisionBodyPresent": body != null,
		"fluidCollisionSource": String(fluid_instance.get_meta("collision_source", "")) if fluid_instance != null else "",
		"asyncMeshFrames": async_mesh_frames,
		"asyncMeshApplied": async_mesh_applied,
		"asyncMeshLastResult": async_mesh_last_result,
		"asyncMeshRequestAccepted": async_mesh_request_accepted,
		"asyncMeshInitialPending": async_mesh_initial_pending,
		"asyncMeshTimeline": async_mesh_timeline
	}

func cell_center(cell: Vector3i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)

func fluid_state(fluid_id: String) -> Dictionary:
	return {
		"blockId": fluid_id,
		"material": fluid_id,
		"solid": false,
		"density": 0.0,
		"air": false,
		"fluid": fluid_id,
		"biome": "underground_air"
	}

func sample_signature(sample: Dictionary) -> Dictionary:
	return {
		"cell": vec3i(sample.get("cell", Vector3i.ZERO)),
		"biome": String(sample.get("biome", "")),
		"material": String(sample.get("material", "")),
		"fluid": String(sample.get("fluid", "")),
		"solid": bool(sample.get("solid", false)),
		"density": snappedf(float(sample.get("density", 0.0)), 0.001)
	}

func vec2i(value: Vector2i) -> Dictionary:
	return { "x": value.x, "z": value.y }

func vec3i(value: Vector3i) -> Dictionary:
	return { "x": value.x, "y": value.y, "z": value.z }

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func all_passed() -> bool:
	for result in results:
		if not bool(result.get("passed", false)):
			return false
	return true

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func finish() -> void:
	save_report()
	if main != null:
		var service = main.get("terrain_meshing_service")
		if service != null and service.has_method("clear_jobs"):
			service.call("clear_jobs", true)
		main.queue_free()
	quit(0 if all_passed() else 1)

func save_report() -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": "underground_fluid_render_contract",
		"testId": "underground_fluid_render_contract",
		"seed": seed,
		"finished": true,
		"passed": all_passed(),
		"evidenceLevel": "integration",
		"scope": "Real Main.tscn chunk creation check that generated terrain fluid states produce a non-collision TerrainFluidMesh; not headed visual acceptance.",
		"resultCount": results.size(),
		"failureCount": failure_count(),
		"selectedChunk": vec2i(selected_chunk),
		"selectedSample": sample_signature(selected_sample) if not selected_sample.is_empty() else {},
		"asyncMeshFrames": async_mesh_frames,
		"asyncMeshApplied": async_mesh_applied,
		"asyncMeshLastResult": async_mesh_last_result,
		"asyncMeshRequestAccepted": async_mesh_request_accepted,
		"asyncMeshInitialPending": async_mesh_initial_pending,
		"asyncMeshTimeline": async_mesh_timeline,
		"editRefreshEvidence": edit_refresh_evidence,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify(report, "  "))
